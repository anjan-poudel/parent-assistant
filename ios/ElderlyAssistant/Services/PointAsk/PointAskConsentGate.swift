import Foundation

// C09's shape for point & ask — `PointAskConsentGate`, a deliberate mirror
// of `LiveTranslateConsentGate` (T-014) with the feature's own key and
// version stamp.
//
// The feature's compliance basis: no crop of the camera picture leaves the
// device without a recorded grant for the disclosure copy that was shown.
// This file exists to make five properties structural rather than
// aspirational:
//
//  - **Fail closed, always.** `granted` is the only decision that allows
//    egress. `notRecorded`, `denied` and `unreadable` all deny, each with
//    its own name, and `unreadable` never collapses into either of the
//    others — a corrupt record is a different failure with a different
//    owner action (a bug to fix) from "the elder has not decided". Absent,
//    corrupt, stale-version and scope-mismatched records are all
//    non-granted states; there is no default-on path and no configuration
//    value anywhere in this file that can produce a grant.
//  - **One writer.** `record(granted:)` is the only code in the app that
//    writes the record, and `revoke()` is the only code that deletes it.
//    Both are reached only from the consent prompt and the revocation
//    control; no configuration, family-setting or remote path has a reason
//    to call either, and none does.
//  - **A grant is a proof, not a boolean.** `authorize()` returns a `Grant`
//    whose initialiser is private to this file, so the request builder —
//    `GeminiClient.identifyPointAsk` — requires the proof as a parameter
//    and a caller that forgot to consult the gate is a compile error rather
//    than a review finding (AM-7).
//  - **Revocation takes effect in memory before storage (AM-4).** A
//    revocation whose write fails still denies — immediately and on every
//    later read — and the failure is *reported* as a failure rather than
//    leaving a grant the elder believes they withdrew.
//  - **Withdrawal is immediate and total (AM-1).** `revoke()` flips the
//    in-memory deny first, then cancels every registered in-flight
//    request, then deletes the record and verifies the delete by reading
//    back. The pipeline re-reads `authorize()` before every attempt
//    including the retry, so a withdrawal between attempts blocks the
//    retry.
//
// Threading: one `NSLock` guards the in-memory deny flag, the in-flight
// registry and every storage access. Reads are read-through (there is no
// cached grant that could survive a re-read check); the only thing held in
// memory is a *deny* the elder established during this process lifetime.
// Event emission happens outside the lock path that storage can block on
// only where noted — the emitter is a plain bus call with no re-entrancy
// into this type.

final class PointAskConsentGate {

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

        /// Whether the cloud tier may proceed. `granted` is the only yes.
        var allowsEgress: Bool { self == .granted }
    }

    // MARK: - Record

    /// The stored record: exactly three fields and no more — the granted
    /// flag, the timestamp and the disclosure version. No free-form text, no
    /// user identifier, no device identifier (T-014 scenario 7).
    struct ConsentRecord: Codable, Equatable {
        let granted: Bool
        let recordedAt: Date
        let disclosureVersion: String
    }

    /// Why a write path failed. Codes are stable tokens (T-002's rule): the
    /// user-readable cause never travels.
    enum ConsentError: Error, Equatable, LogSafeErrorCode {
        /// The write reported success but the record could not be read back.
        case recordUnreadable
        /// The write (or the verified delete) did not take effect.
        case writeFailed

        var logSafeErrorCode: String {
            switch self {
            case .recordUnreadable: return "pointask_consent_record_unreadable"
            case .writeFailed: return "pointask_consent_write_failed"
            }
        }
    }

    /// AM-7 — the consent proof the request builder requires.
    ///
    /// The initialiser is `fileprivate` — private to this file — so
    /// `authorize()` is the only way one can exist. `identifyPointAsk`
    /// takes a `Grant` and therefore cannot be reached without passing
    /// through the gate; a missing check is a compile error, not a
    /// remembered discipline.
    ///
    /// A `Grant` is a statement about the read that produced it, not a
    /// standing permission: the pipeline mints one per attempt (AM-1), and
    /// a revocation cancels whatever is in flight through
    /// `registerInFlight(_:)`.
    struct Grant: Equatable {
        let disclosureVersion: String

        fileprivate init(disclosureVersion: String) {
            self.disclosureVersion = disclosureVersion
        }
    }

    // MARK: - Storage

    /// The one key this gate owns. `StoragePlacementPolicy` places it on the
    /// encrypted file channel: it is not in the keychain-resident allow-list,
    /// which is exactly the placement the design requires. Deleting the key
    /// is revocation; nothing else in the feature touches it.
    static let storageKey = "plugin.point_ask.consent.v1"

    // MARK: - Dependencies

    private let storage: EncryptedLocalStorage
    private let config: PointAskConfig
    private let events: PointAskEvents
    private let now: () -> Date

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    /// The elder's live decision when storage cannot be trusted to carry it:
    /// set *before* a decline or revocation is written, cleared only by a
    /// grant whose record was written **and read back**. It only ever holds
    /// a deny — a grant is never mirrored, because a mirrored grant would
    /// survive a re-read check that no longer returns one.
    private var deniesInMemory = false
    /// Cancellation hooks for in-flight VLM work, keyed by registration.
    private var inFlight: [UUID: () -> Void] = [:]

    // MARK: - Init

    init(storage: EncryptedLocalStorage,
         config: PointAskConfig = .default,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.config = config
        self.events = PointAskEvents(bus: observabilityBus, config: config)
        self.now = now
    }

    // MARK: - Reading the decision

    /// The decision in force **right now**. Read-through: every call
    /// re-derives from storage, so nothing here can hand back a grant a
    /// re-read would not.
    ///
    /// The one exception is the in-memory deny: once the elder has revoked
    /// (or declined) in this process, storage is not consulted, because
    /// storage may still hold the granted record the revocation could not
    /// delete. The elder's decision outranks a stale record (AM-4).
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
    /// record — so the prompt re-appears and the elder can decide again
    /// under the new copy (C09's hook).
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

    // MARK: - Authorization (AM-7)

    /// The pipeline's per-attempt entry point: consult the gate, and receive
    /// either a proof to hand the request builder or the taxonomy's reason
    /// for the refusal.
    ///
    /// This is the only producer of `Grant` in the app.
    func authorize() -> Result<Grant, PointAskError> {
        switch currentDecision() {
        case .granted:
            return .success(Grant(disclosureVersion: config.disclosureVersion))
        case .notRecorded:
            return .failure(.consentNotRecorded)
        case .denied:
            return .failure(.consentDenied)
        case .unreadable:
            return .failure(.consentRecordUnreadable)
        }
    }

    // MARK: - Writing a decision

    /// The **only** writer of the record. Reached from the consent prompt
    /// (grant or decline) and from the revocation control; no configuration
    /// path calls it.
    ///
    /// A decline denies in memory before storage, exactly as a revocation
    /// does: the deny-first rule covers both ways of saying no, and a decline
    /// whose write fails must still stop egress.
    ///
    /// A grant is confirmed by reading the record back — "the write returned
    /// success" is not the same claim as "the record is there" — and only a
    /// confirmed grant clears the in-memory deny. A failure is returned as a
    /// failure and recorded as one.
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

    // MARK: - Revocation (AM-1, AM-4)

    /// Withdraws consent, immediately and totally.
    ///
    /// The order is the requirement, not an implementation detail:
    ///
    /// 1. **Deny in memory first (AM-4).** Before any storage call — so a
    ///    failed delete cannot leave egress running — the in-memory state
    ///    becomes `denied` and every registered in-flight request is
    ///    cancelled (AM-1: cancellation is what closes the withdrawal-then-
    ///    retry window, together with the pipeline's per-attempt re-read).
    /// 2. **Delete the record, then verify by reading back (AM-4).** The
    ///    read-back is the real check: `delete` returning success is the
    ///    store's claim, not the elder's.
    /// 3. **If a granted record survived the delete — or the read-back could
    ///    not be taken — overwrite it with a deny record** through the same
    ///    single writer, and verify again. This is what stops a relaunch from
    ///    silently re-granting from a record the elder believes they
    ///    withdrew; the record path itself is under `record(granted: false)`.
    /// 4. **If a granted record still survives, or still cannot be checked,
    ///    fail loudly (AM-4).** The in-memory deny stands (so nothing leaves
    ///    the device this session) and the caller receives `.failure`, never
    ///    a success. A relaunch in that state reads the surviving grant —
    ///    which is why the failure is surfaced to the elder instead of
    ///    swallowed: the withdrawal did not take effect, and they are told
    ///    so.
    @discardableResult
    func revoke() -> Result<Void, ConsentError> {
        // 1. In memory first, and out of reach of any storage failure.
        let cancellations = withLock { () -> [() -> Void] in
            deniesInMemory = true
            let hooks = Array(inFlight.values)
            inFlight.removeAll()
            return hooks
        }
        // Cancelled outside the lock: a cancellation hook re-enters this
        // type through its registration's release().
        for cancel in cancellations { cancel() }

        // 2. Delete, then verify — the read-back is the authority.
        withLock { _ = storage.delete(key: Self.storageKey) }

        // 3. If a granted record survived the delete, overwrite it with a
        //    deny record through the one write path, then verify again.
        //    An *unverifiable* read-back takes the same route: "the delete
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
        //    of this process; the caller gets a failure, never a success.
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

    /// What the post-revocation verification read found (AM-4 part 2),
    /// deliberately taken from storage rather than from the in-memory deny.
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

    // MARK: - In-flight registration (AM-1)

    /// Registers in-flight VLM work so a revocation can cancel it. The
    /// pipeline holds the returned registration for the duration of an
    /// attempt and releases it on every exit path; a revocation cancels
    /// whatever is registered at that moment.
    ///
    /// Registration is a *cancellation* seam, not a consent check: a request
    /// that is already in flight was authorized before it started, and a
    /// revocation ends it rather than retrying it.
    func registerInFlight(cancel: @escaping () -> Void) -> InFlightRegistration {
        let id = UUID()
        withLock { inFlight[id] = cancel }
        return InFlightRegistration(onCancel: cancel, onRelease: { [weak self] in
            guard let self else { return }
            _ = self.withLock { self.inFlight.removeValue(forKey: id) }
        })
    }

    /// How many in-flight registrations are outstanding. Evidence for tests;
    /// the pipeline is the only thing that registers.
    var inFlightRegistrationCount: Int {
        withLock { inFlight.count }
    }

    /// A held registration. `release()` is idempotent and `deinit` releases,
    /// so an attempt that returns early, throws or is cancelled cannot leave
    /// a stale cancellation hook behind.
    final class InFlightRegistration {
        private let lock = NSLock()
        private let onCancel: () -> Void
        private var onRelease: (() -> Void)?
        /// Guarded by the lock; true once `cancel()` has fired so a second
        /// revocation cannot cancel the same attempt twice.
        private var wasCancelled = false

        fileprivate init(onCancel: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onCancel = onCancel
            self.onRelease = onRelease
        }

        /// The gate's half of a revocation: cancel the attempt this
        /// registration stands for. Idempotent; does not unregister (the
        /// holder's `release()` does that on its normal exit path).
        func cancelNow() {
            lock.lock()
            let alreadyCancelled = wasCancelled
            wasCancelled = true
            lock.unlock()
            guard !alreadyCancelled else { return }
            onCancel()
        }

        /// The holder's exit path. Idempotent.
        func release() {
            lock.lock()
            let release = onRelease
            onRelease = nil
            lock.unlock()
            release?()
        }

        deinit { release() }
    }

    // MARK: - Plumbing

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
