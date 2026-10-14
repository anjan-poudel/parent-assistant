import Foundation

// C09's shape for cloud chat — `CloudChatConsentGate` (T-172): the third
// feature to carry the shipped consent-gate mechanism (the
// `LiveTranslateConsentGate` precedent, then `PointAskConsentGate`), the
// mechanism reused rather than forked (design-l1 §8.3, §12; the "consent
// store seam" row of the Deferred-work table).
//
// The feature's compliance basis: no chat turn's content leaves the device
// without a recorded grant for the disclosure copy the elder was shown, and
// this record is the single source of truth for "may chat egress" — the
// Settings toggle and the voice revocation path write through this gate, so
// there is no second preference that could disagree with it (design §12,
// FR-CNR-009). This file exists to make five properties structural rather
// than aspirational:
//
//  - **Fail closed, always.** `granted` is the only decision that allows
//    egress. `notRecorded`, `denied` and `unreadable` all refuse, each with
//    its own name, and `unreadable` never collapses into either of the
//    others — a corrupt record is a different failure with a different owner
//    action (a bug to fix) from "the elder has not decided". Absent, corrupt
//    and stale-version records are all non-granted states; there is no
//    default-on path and no configuration value anywhere in this file that
//    can produce a grant.
//  - **One writer.** `record(granted:)` is the only code in the app that
//    writes the record, and `revoke()` is the only code that deletes it.
//    Both are reached only from the consent prompt and the revocation
//    control (T-176, T-177); no configuration, Settings default or remote
//    path has a reason to call either, and none does.
//  - **Revocation takes effect in memory before storage.** A revocation
//    whose write fails still denies — immediately and on every later read in
//    this process — and the failure is *reported* as a failure rather than
//    leaving a grant the elder believes they withdrew (design §8.6:
//    revocation takes effect at the next turn's routing decision; the
//    shipped AM-4 ordering).
//  - **The decision is read per turn; no grant is ever cached.** Every read
//    re-derives from storage, so a revocation between two turns changes the
//    second turn's route (T-173 reads this per turn; there is no cached
//    route). The only thing held in memory is a *deny* the elder
//    established during this process lifetime, and it only ever holds "no".
//  - **Evidence is classification-only.** The consent events below carry the
//    disclosure version stamp or nothing at all; no transcript, no reply
//    text, no key material and no user or device identifier can travel
//    through the typed emitters (NFR-CNR-006, NFR-CNR-011).
//
// Threading: one `NSLock` guards the in-memory deny flag and every storage
// access; the write path is synchronous. Event emission happens while the
// lock is held on the read path — the emitter is a plain bus call with no
// re-entrancy into this type.

final class CloudChatConsentGate {

    // MARK: - Decisions

    /// The four states a consent read can return. Three of them deny.
    enum Decision: Equatable, CaseIterable {
        /// A record granted for the current disclosure version.
        case granted
        /// No record for the current disclosure version exists.
        case notRecorded
        /// A record exists and says no — the elder declined, or revoked.
        case denied
        /// A record exists but could not be read or understood. Fail closed:
        /// never collapsed into `notRecorded` or `denied`.
        case unreadable

        /// Whether a chat turn may egress. `granted` is the only yes, and
        /// this is the property the routing decision consumes (T-173).
        var allowsEgress: Bool { self == .granted }
    }

    // MARK: - Record

    /// The stored record: exactly three fields and no more — the granted
    /// flag, the timestamp and the disclosure version. No free-form text, no
    /// user identifier, no device identifier, no transcript.
    struct ConsentRecord: Codable, Equatable {
        let granted: Bool
        let recordedAt: Date
        let disclosureVersion: String
    }

    /// Why a write path failed. Codes are stable tokens (the shipped
    /// `LogSafeErrorCode` rule): the user-readable cause never travels.
    enum ConsentError: Error, Equatable, LogSafeErrorCode {
        /// The write reported success but the record could not be read back.
        case recordUnreadable
        /// The write (or the verified delete) did not take effect.
        case writeFailed

        var logSafeErrorCode: String {
            switch self {
            case .recordUnreadable: return "cloudchat_consent_record_unreadable"
            case .writeFailed: return "cloudchat_consent_write_failed"
            }
        }
    }

    // MARK: - Configuration

    /// The consent-side constants, held as one substitutable value so a test
    /// (and a later copy-review change) can move the version stamp without
    /// touching the gate — the `LiveTranslateConfig` / `PointAskConfig`
    /// disclosure pattern, scaled to the one constant this unit owns.
    ///
    /// It is deliberately a *nested* type: this unit declares the constant
    /// with the gate that enforces it, so the version a record carries and
    /// the version a read compares against cannot drift apart into two
    /// files. It holds no consent-shaped knob — `disclosureVersion` is the
    /// only member, and a knob that could grant would be a consent the elder
    /// never gave.
    struct Config: Equatable {

        /// The version stamp carried by consent records and by the consent
        /// events. Bumping this invalidates every grant recorded under the
        /// old stamp (a stale grant reads as `notRecorded`, so the disclosure
        /// is shown again under the new copy) rather than letting it be
        /// silently inherited.
        ///
        /// `draft.` is deliberate: the disclosure copy and its review are
        /// T-176's (design §8.4 defers final en/ne copy to implementation),
        /// and the stamp says so until that review lands. The stamp is not a
        /// literal date run (`2026-10-14`): the shipped `LogSanitiser`
        /// scrubs digit runs of eight or more with common separators, which
        /// would redact the value out of the consent events the evidence
        /// depends on. `14oct2026` carries the same meaning and survives the
        /// bus intact (the `pointask.disclosure.19sep2026.r1` precedent).
        var disclosureVersion: String = "cloudchat.disclosure.draft.14oct2026.r1"

        static let `default` = Config()
    }

    // MARK: - Storage

    /// The one key this gate owns. `StoragePlacementPolicy` places it on the
    /// shared encrypted-at-rest consent channel (it is not in the
    /// keychain-resident allow-list, which is exactly the placement the
    /// design requires: the same mechanism the LiveTranslate consent record
    /// uses, under this feature's own key). Deleting the key is revocation;
    /// nothing else in the feature touches it.
    static let storageKey = "plugin.cloud_chat.consent.v1"

    // MARK: - Event schema (classification only)

    /// The consent events this gate emits, declared here so the schema and
    /// its emitter cannot drift — the pinned-key-set convention the shipped
    /// gates use (`LiveTranslateEventCatalogue`, `PointAskEventCatalogue`).
    ///
    /// Every metadata key below is a member of the shipped
    /// `LogSanitiser.allowedKeys` set (`disclosureVersion`), and there is no
    /// parameter anywhere in `Events` through which a transcript, a reply or
    /// any other content could travel: the API is typed and the value is the
    /// version stamp or nothing.
    enum EventCatalogue {

        /// The observability component every event below is emitted on.
        static let component = "cloud_chat"

        struct Entry: Equatable {
            /// Every outcome value this event may carry. Fixed vocabulary.
            let outcomes: Set<String>
            /// Every metadata key this event may carry.
            let metadataKeys: Set<String>
        }

        /// Event type → schema. One entry per emitter in `Events`.
        static let entries: [String: Entry] = [
            // The elder's recorded "yes".
            "consent_recorded": Entry(outcomes: ["success"],
                                      metadataKeys: ["disclosureVersion"]),
            // The elder's recorded "no" (decline or revocation tombstone).
            "consent_denied": Entry(outcomes: ["success"],
                                    metadataKeys: ["disclosureVersion"]),
            // A completed withdrawal.
            "consent_revoked": Entry(outcomes: ["success"],
                                     metadataKeys: ["disclosureVersion"]),
            // Bytes exist at the key and the store will not decode them.
            "consent_unreadable": Entry(outcomes: ["failure"], metadataKeys: []),
            // A grant or a revocation whose write did not take effect.
            "consent_write_failed": Entry(outcomes: ["failure"], metadataKeys: []),
        ]

        static var allEventTypes: Set<String> { Set(entries.keys) }
    }

    /// The gate's typed emitters — one method per event, so an emitter that
    /// produces a type the catalogue does not declare is a test failure.
    struct Events {

        enum MetadataKey: String {
            case disclosureVersion
        }

        let bus: ObservabilityBus
        let config: Config

        func consentRecorded() {
            emit("consent_recorded", outcome: "success",
                 metadata: [.disclosureVersion: config.disclosureVersion])
        }

        func consentDenied() {
            emit("consent_denied", outcome: "success",
                 metadata: [.disclosureVersion: config.disclosureVersion])
        }

        func consentRevoked() {
            emit("consent_revoked", outcome: "success",
                 metadata: [.disclosureVersion: config.disclosureVersion])
        }

        func consentUnreadable() {
            emit("consent_unreadable", outcome: "failure")
        }

        func consentWriteFailed() {
            emit("consent_write_failed", outcome: "failure",
                 errorCode: ConsentError.writeFailed.logSafeErrorCode)
        }

        private func emit(_ eventType: String,
                          outcome: String,
                          errorCode: String? = nil,
                          metadata: [MetadataKey: String] = [:]) {
            bus.emit(ObservabilityEvent(
                component: EventCatalogue.component,
                eventType: eventType,
                durationMs: nil,
                outcome: outcome,
                errorCode: errorCode,
                metadata: Dictionary(uniqueKeysWithValues:
                    metadata.map { ($0.key.rawValue, $0.value) })))
        }
    }

    // MARK: - Dependencies

    private let storage: EncryptedLocalStorage
    private let config: Config
    private let events: Events
    private let now: () -> Date

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    /// The elder's live decision when storage cannot be trusted to carry it:
    /// set *before* a decline or revocation is written, cleared only by a
    /// grant whose record was written **and read back**. It only ever holds
    /// a deny — a grant is never mirrored, because a mirrored grant would
    /// survive a re-read check that no longer returns one.
    private var deniesInMemory = false

    // MARK: - Init

    init(storage: EncryptedLocalStorage,
         config: Config = .default,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.config = config
        self.events = Events(bus: observabilityBus, config: config)
        self.now = now
    }

    // MARK: - Reading the decision

    /// The decision in force **right now**. Read-through: every call
    /// re-derives from storage, so nothing here can hand back a grant a
    /// re-read would not — the routing decision reads this per turn (T-173),
    /// and that read is the only egress policy.
    ///
    /// The one exception is the in-memory deny: once the elder has revoked
    /// (or declined) in this process, storage is not consulted, because
    /// storage may still hold the granted record the revocation could not
    /// delete. The elder's decision outranks a stale record.
    func currentDecision() -> Decision {
        withLock {
            if deniesInMemory { return .denied }
            return readStoredDecision()
        }
    }

    /// Reads the stored record and maps it onto a decision. Fail closed on
    /// every path: an absent record is `notRecorded`, an undecodable one is
    /// `unreadable`, a record that says no is `denied`, and a grant is only
    /// a grant when its version stamp matches the disclosure copy that was
    /// shown. A stale grant is `notRecorded` — the current version has no
    /// record — so the disclosure reappears and the elder can decide again
    /// under the new copy (design §8.3).
    ///
    /// Must be called with the lock held.
    private func readStoredDecision() -> Decision {
        switch storage.read(key: Self.storageKey, type: ConsentRecord.self) {
        case .success(let record):
            guard record.granted else { return .denied }
            guard record.disclosureVersion == config.disclosureVersion else {
                return .notRecorded
            }
            return .granted

        case .failure:
            // An absent record and an unreadable one are the same failure
            // through `EncryptedLocalStorage`; the raw channel tells them
            // apart (the shipped file store conforms to both). A store that
            // cannot answer is treated as holding nothing — a fresh install
            // — which is the fail-closed reading: it denies and it prompts.
            guard payloadExistsOnDisk() else { return .notRecorded }
            events.consentUnreadable()
            return .unreadable
        }
    }

    /// Whether the store itself holds bytes at this key.
    private func payloadExistsOnDisk() -> Bool {
        guard let raw = storage as? RawEncryptedStorage else { return false }
        return raw.readRawData(key: Self.storageKey) != nil
    }

    // MARK: - Writing a decision

    /// The **only** writer of the record. Reached from the consent prompt
    /// (grant or decline, T-176) and from the revocation control (T-177); no
    /// configuration path calls it.
    ///
    /// A decline denies in memory before storage, exactly as a revocation
    /// does: the deny-first rule covers both ways of saying no, and a decline
    /// whose write fails must still stop egress.
    ///
    /// A grant is confirmed by reading the record back — "the write returned
    /// success" is not the same claim as "the record is there" — and only a
    /// confirmed grant clears the in-memory deny. A failure is returned as a
    /// failure and recorded as one; no code path reports success for a
    /// record that is not on disk.
    @discardableResult
    func record(granted: Bool) -> Result<Void, ConsentError> {
        let result = persistDecision(granted: granted)
        switch result {
        case .success:
            if granted { events.consentRecorded() } else { events.consentDenied() }
        case .failure:
            events.consentWriteFailed()
        }
        return result
    }

    /// The write itself, shared by the prompt's API (`record(granted:)`) and
    /// the revocation's tombstone step (`revoke()`). Those two callers are
    /// exactly the two controls the design sanctions; both are in this file,
    /// and the storage write is a single site — the app has one place that
    /// can put a consent record on disk.
    ///
    /// The caller owns event emission so a revocation never reports itself as
    /// a decline.
    private func persistDecision(granted: Bool) -> Result<Void, ConsentError> {
        // The elder's "no" is in force before storage is touched: a decline
        // or a revocation that cannot be written must still stop egress.
        if !granted {
            withLock { deniesInMemory = true }
        }

        let record = ConsentRecord(granted: granted,
                                   recordedAt: now(),
                                   disclosureVersion: config.disclosureVersion)
        let writeResult = withLock { write(record) }
        if case .failure(let error) = writeResult {
            return .failure(error)
        }

        if granted {
            // "The write returned success" is the store's claim; "the record
            // reads back as a grant" is the fact. Only the read-back clears
            // the in-memory deny.
            let confirmation = withLock { readStoredDecision() }
            guard confirmation == .granted else {
                return .failure(confirmation == .unreadable ? .recordUnreadable : .writeFailed)
            }
            withLock { deniesInMemory = false }
        }
        return .success(())
    }

    /// Encodes and writes the whole record — the one storage write site.
    /// Must be called with the lock held.
    private func write(_ record: ConsentRecord) -> Result<Void, ConsentError> {
        switch storage.write(key: Self.storageKey, value: record) {
        case .success: return .success(())
        case .failure: return .failure(.writeFailed)
        }
    }

    // MARK: - Revocation

    /// Withdraws consent, immediately and totally.
    ///
    /// The order is the requirement, not an implementation detail:
    ///
    /// 1. **Deny in memory first.** Before any storage call — so a failed
    ///    delete cannot leave egress running — the in-memory state becomes
    ///    `denied`. That is what makes a revocation whose write fails still
    ///    deny on every later read in this process.
    /// 2. **Delete the record, then verify by reading back.** The read-back
    ///    is the real check: `delete` returning success is the store's claim,
    ///    not the elder's.
    /// 3. **If a granted record survived the delete — or the read-back could
    ///    not be taken — overwrite it with a deny record** through the same
    ///    single writer, and verify again. This is what stops a relaunch from
    ///    silently re-granting from a record the elder believes they
    ///    withdrew.
    /// 4. **If a granted record still survives, or still cannot be checked,
    ///    fail loudly.** The in-memory deny stands (so nothing leaves the
    ///    device this session) and the caller receives `.failure`, never a
    ///    success. A relaunch in that state reads the surviving grant — which
    ///    is why the failure is surfaced to the elder instead of swallowed:
    ///    the withdrawal did not take effect, and they are told so.
    ///
    /// Revocation is a record state, not a separate preference flag: this is
    /// the same writer the prompt's "no" uses, and no Settings value is
    /// consulted (design §12 — one source of truth for "may chat egress").
    @discardableResult
    func revoke() -> Result<Void, ConsentError> {
        // 1. In memory first, and out of reach of any storage failure.
        withLock { deniesInMemory = true }

        // 2. Delete, then verify — the read-back is the authority. A
        //    `delete` that reports failure while the record is genuinely
        //    gone has still revoked; a `delete` that reports success while
        //    the record survives has not.
        withLock { _ = storage.delete(key: Self.storageKey) }

        // 3. If a granted record survived the delete, overwrite it with a
        //    deny record through the one write path, then verify again. An
        //    *unverifiable* read-back takes the same route: "the delete
        //    returned success" is the store's claim, and a claim that cannot
        //    be checked is not a revocation that can be reported as done.
        var tombstoneFailure: ConsentError?
        switch grantEvidence() {
        case .noGrant:
            events.consentRevoked()
            return .success(())
        case .granted, .unverifiable:
            if case .failure(let error) = persistDecision(granted: false) {
                tombstoneFailure = error
            }
        }

        // 4. The record is still in force, or still cannot be checked. The
        //    in-memory deny stands, so nothing leaves the device for the rest
        //    of this process; the caller gets a failure, never a success, and
        //    the elder is told the withdrawal did not take effect.
        switch grantEvidence() {
        case .noGrant:
            events.consentRevoked()
            return .success(())
        case .granted:
            events.consentWriteFailed()
            return .failure(tombstoneFailure ?? .writeFailed)
        case .unverifiable:
            events.consentWriteFailed()
            return .failure(tombstoneFailure ?? .recordUnreadable)
        }
    }

    /// What the post-revocation verification read found, deliberately taken
    /// from storage rather than from the in-memory deny.
    private enum GrantEvidence {
        /// Absent, declined or stale-version: nothing on this channel can
        /// produce a `granted` decision on any later read.
        case noGrant
        /// A granted record for the current disclosure version is still there.
        case granted
        /// There are bytes at the key and the store will not decode them —
        /// so the record cannot be shown to be gone.
        case unverifiable
    }

    private func grantEvidence() -> GrantEvidence {
        withLock {
            switch storage.read(key: Self.storageKey, type: ConsentRecord.self) {
            case .success(let record):
                return record.granted && record.disclosureVersion == config.disclosureVersion
                    ? .granted : .noGrant
            case .failure:
                // A store that cannot answer is not the same as a store that
                // answers "nothing", and the raw channel tells them apart.
                // Bytes that are there but cannot be read are the case that
                // matters: the record may be a grant that reads back fine on
                // a later launch, so it is never counted as a completed
                // withdrawal.
                return payloadExistsOnDisk() ? .unverifiable : .noGrant
            }
        }
    }

    // MARK: - Plumbing

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
