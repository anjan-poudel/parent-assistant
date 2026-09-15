import Foundation

/// The loop's user-visible state (T-054 §5.3). Two of these are the
/// indicator's words and two are the honest refusal states T-054 §5.3.2
/// adds to T-053's string set — without them a loop that is ON and not
/// sending would display "ON", which is the dishonest reading T-053
/// §5.4.6 exists to forbid.
///
/// The design's transient dialog states (S1 CONSENTING, S3 REVOKING) are
/// not stored anywhere: T-054 §5.1 fixes that a cancelled consent "must
/// not leave a minted salt or a written handle", and the only way to
/// guarantee that is for the dialog state to be view state.
enum LearningLoopStatus: Equatable {
    /// S0 (and S4, whose user-visible surface is S0's).
    case off
    /// S2 — sharing counts and codes.
    case on
    /// S2 with the salt unavailable: nothing is captured and nothing is
    /// sent (T-054 §3.4, fail closed). Never displayed as simply "on".
    case egressPending
    /// S2 under a payload version this build no longer ships: egress is
    /// refused rather than shipping a narrower or wider payload silently
    /// (T-054 §3.3).
    case egressNeedsUpdate
}

/// The capture half of the continuous-learning loop (T-056 Phase A):
/// consent, salt, handle minting and the encrypted content store. It
/// owns NO capture path of its own — the loop writes from the existing
/// confirm-tier seam at verdict time (C-16), so the always-on collection
/// is unchanged in shape and in volume.
///
/// **What this type is not.** It is not the egress client: there is no
/// network code, no envelope, no cursor and no scheduling here. What it
/// produces is the two things egress would consume — `utteranceHandle`
/// on the records, and `handle → sanitised transcript` in the content
/// store — and the loop-owned state (L-3 consent, L-4 salt) that gates
/// both.
///
/// **C-7 in one line:** with the consent off, `handle(forTranscript:)`
/// returns nil without touching the salt or the content store, so the
/// appended record is field-for-field the shipped record.
final class LearningLoopCapture {

    private let consentStore: LearningLoopConsentStore
    private let intentLogStore: IntentLogStore
    let contentStore: LearningLoopContentStore
    let salt: LearningLoopSalt

    /// The consent record, cached. Nil until the first read.
    private var consent: LearningLoopConsent?
    private var didLoadConsent = false
    private let lock = NSLock()

    init(storage: EncryptedLocalStorage, intentLogStore: IntentLogStore) {
        self.consentStore = LearningLoopConsentStore(storage: storage)
        self.intentLogStore = intentLogStore
        self.contentStore = LearningLoopContentStore(storage: storage)
        self.salt = LearningLoopSalt(storage: storage)
    }

    // MARK: - State

    /// The persisted consent, loaded once. IO happens on first access,
    /// never in `init` (the `NoIOInInitTests` contract every store in the
    /// app keeps).
    private var currentConsent: LearningLoopConsent? {
        lock.lock()
        defer { lock.unlock() }
        if !didLoadConsent {
            didLoadConsent = true
            consent = consentStore.load()
        }
        return consent
    }

    private func storeConsent(_ record: LearningLoopConsent?) {
        lock.lock()
        defer { lock.unlock() }
        didLoadConsent = true
        consent = record
    }

    /// True while a consent is live — the gate every capture passes
    /// through (C-7).
    var isOn: Bool { currentConsent?.isActive == true }

    /// What the Settings card and the family review surface display, and
    /// what the egress gate would consult. Computed on demand (one
    /// Keychain read at most, cached by `LearningLoopSalt`), so it is
    /// refreshed by the caller rather than polled.
    var status: LearningLoopStatus {
        guard let record = currentConsent, record.isActive else { return .off }
        guard record.payloadVersion == LearningLoopSchema.payloadVersion,
              record.schemaSha8 == LearningLoopSchema.schemaSha8 else {
            return .egressNeedsUpdate
        }
        guard salt.current() != nil else { return .egressPending }
        return .on
    }

    // MARK: - Consent transitions (T-054 §5.1)

    /// S1 → S2. Ordered so a crash leaves the CLOSED state: mint the salt
    /// FIRST, write the consent record SECOND, and only then can any
    /// handle be written. A crash between the two leaves no handle and no
    /// egress — recoverable, and it re-enters S1.
    ///
    /// Returns false when the salt could not be minted or the record
    /// could not be written; no partial state is left behind either way.
    @discardableResult
    func enable(at now: Date = Date()) -> Bool {
        guard salt.mintIfAbsent() else { return false }
        let record = LearningLoopConsent(payloadVersion: LearningLoopSchema.payloadVersion,
                                         schemaSha8: LearningLoopSchema.schemaSha8,
                                         acceptedAt: now)
        guard consentStore.save(record) else {
            // Consent without a durable record is not consent: destroy
            // the salt rather than leave half of the transition behind.
            salt.destroy()
            return false
        }
        storeConsent(record)
        return true
    }

    /// S3 → S4. The design's order, and it is an order rather than a set:
    /// strip the handles FIRST, delete the content store SECOND, destroy
    /// the salt LAST. A crash at any point leaves egress already stopped
    /// and the most sensitive artifact (the content) already gone.
    ///
    /// The consent record is RETAINED with `revokedAt` set — kept as the
    /// record that a consent existed and was withdrawn (T-054 §3.8). The
    /// withdrawal marker is written last on purpose: if it fails, the
    /// loop reports a refusing state instead of claiming a revocation it
    /// did not finish.
    @discardableResult
    func disable(at now: Date = Date()) -> Bool {
        intentLogStore.stripUtteranceHandles()
        contentStore.deleteAll()
        salt.destroy()
        guard var record = currentConsent else { return true }
        record.revokedAt = now
        guard consentStore.save(record) else { return false }
        storeConsent(record)
        return true
    }

    // MARK: - The capture seam

    /// Resolves one transcript to its on-device handle and stores the
    /// text behind it, returning the handle the record should carry —
    /// or nil, in which case the record is appended with the shipped
    /// fields and no handle key at all (never a null).
    ///
    /// Nil means one of: the opt-in is off; the action carries no
    /// transcript (the calendar paths are deliberately speech-free); the
    /// transcript is empty after sanitisation; or the salt is unavailable.
    /// The last is the fail-closed branch of T-054 §3.4 — no handle, no
    /// content entry, and the state is visible as `egressPending`.
    ///
    /// The content entry is written BEFORE the caller appends the record,
    /// so a handle on disk always resolves (T-054 §2.3).
    func handle(forTranscript transcript: String?, at now: Date = Date()) -> String? {
        guard let transcript else { return nil }
        // T-053 §2.2 row 1: what the loop keeps on-device is the SANITISED
        // utterance text — the same `InputSanitiser` boundary every other
        // consumer of a transcript sits behind. The handle and the stored
        // text are derived from the SAME sanitised string, so the word the
        // miner reads is the word the key groups on.
        let sanitised = InputSanitiser.sanitise(transcript)
        guard !sanitised.isEmpty else { return nil }
        guard let record = currentConsent, record.isActive else { return nil }
        guard let key = salt.current() else { return nil }
        let handle = LearningLoopSalt.digest(NepaliTextNormalizer.normalize(sanitised),
                                             salt: key)
        contentStore.record(handle: handle, text: sanitised, at: now)
        return handle
    }

    // MARK: - Launch

    /// The launch half of the 90-day sweep (T-054 §3.8: "opportunistically
    /// on write and on launch"). Cheap and idempotent — with nothing
    /// expired it is one read and no write. Called from the coordinator's
    /// boot queue, never from `init`.
    func sweepExpiredContent(now: Date = Date()) {
        guard isOn else { return }
        contentStore.sweepExpired(now: now)
    }
}
