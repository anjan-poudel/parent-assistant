import Foundation

/// L-3 — the consent record (T-054 §2.2, §5.1). "The artifact **is** the
/// gate": the loop is ON exactly when this record exists and has not been
/// withdrawn. There is no separate boolean flag to drift out of sync with
/// it, because a flag is what would let a crashed consent step leave the
/// switch on with nothing behind it.
///
/// `schemaSha8` is why the record exists at all: it answers "what did the
/// user actually agree to" at audit time without trusting a code comment
/// (T-053 §3.2, §3.6). A build whose shipped schema no longer matches the
/// recorded one refuses egress and says so in words rather than silently
/// shipping a wider payload under an older consent.
struct LearningLoopConsent: Codable, Equatable {

    /// The accepted `payload_version` (T-054 §3.3).
    let payloadVersion: String
    /// The `<sha8>` of the accepted schema artifact.
    let schemaSha8: String
    /// The lower bound of egress eligibility (T-054 §3.8, F-9): a record
    /// captured before this instant can never become eligible by the
    /// opt-in being switched on afterwards — that would be a retrospective
    /// consent the copy does not describe.
    let acceptedAt: Date
    /// When the consent was withdrawn, nil while it is live.
    ///
    /// FLAGGED against T-054 §2.2's three-field shape: S4 requires "the
    /// consent record showing a withdrawal" (T-054 §5.1), and with
    /// `{payloadVersion, schemaSha8, acceptedAt}` alone a withdrawn record
    /// is indistinguishable from a live one — so `isActive` would have to
    /// be re-derived from a second artifact, which is exactly the drift
    /// the same design refuses elsewhere. The field is additive and
    /// carries no new value space, so it re-triggers no consent.
    var revokedAt: Date?

    var isActive: Bool { revokedAt == nil }

    init(payloadVersion: String, schemaSha8: String, acceptedAt: Date,
         revokedAt: Date? = nil) {
        self.payloadVersion = payloadVersion
        self.schemaSha8 = schemaSha8
        self.acceptedAt = acceptedAt
        self.revokedAt = revokedAt
    }
}

/// Key + coding for L-3. Deliberately NOT in
/// `StoragePlacementPolicy.keychainResidentKeys`: this is a small
/// structured payload, and the encrypted file channel is the placement
/// T-054 §2.2 gives it ("encrypted channel, same class" as L-1).
final class LearningLoopConsentStore {

    static let storageKey = "learningLoop.consent"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored record, or nil when there has never been a consent (S0)
    /// or the payload is unreadable — fail closed in both directions.
    func load() -> LearningLoopConsent? {
        guard case .success(let record) = storage.read(key: Self.storageKey,
                                                       type: LearningLoopConsent.self) else {
            return nil
        }
        return record
    }

    @discardableResult
    func save(_ record: LearningLoopConsent) -> Bool {
        if case .success = storage.write(key: Self.storageKey, value: record) {
            return true
        }
        return false
    }

    func clear() {
        _ = storage.delete(key: Self.storageKey)
    }
}
