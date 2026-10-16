import Contacts
import CryptoKit
import Foundation

// MARK: - System-contact photo write seam (family-contacts-unify T-154)
//
// The ONE place in the app that writes into the system address book
// (design-l1 §9.2, design-l2 §1.4/§6.2; FR-FCU-008, FR-FCU-010,
// NFR-FCU-002). Everything else in the feature READS contacts; this write
// exists so the photo an owner picks for a family contact can also be the
// person's own system-contact photo.
//
// Confinement is enforced three ways (design-l2 §6.2):
//  1. file-local construction — `CNSaveRequest`/`CNMutableContact` are
//     constructed in this file and NOWHERE else (pinned by the
//     module-wide source-scan test in this unit's suite, registered for
//     the T-155 release-gate check);
//  2. the intent record — `PhotoWriteIntent` is built before the save,
//     its field set is asserted to be exactly `[.photo]`, and the write
//     assigns ONLY `imageData` on the mutable copy (pinned by the F1
//     source-level assertion test next to this file);
//  3. read-back byte verification — `.written` requires the re-fetched
//     bytes to equal the written bytes exactly; anything else is
//     `.failed(.readBackMismatch)`, never a false success.
//
// Failure discipline: no `try!`, no force casts (the `mutableCopy()` cast
// is a checked `as?`), no retries, no backoff, no timeouts (design-l2
// §4.5). Actor isolation makes writes strictly serial. Diagnostics leave
// through the injected `ObservabilityBus` with the closed §5.2 vocabulary
// only — this file writes NOTHING to the console (it is a feature-role
// file for the Release log-safety gate, T-155), and the failure RAW
// VALUES are the log reason codes: no name, number, identifier or photo
// byte ever enters an event field (F7 — the codes are fixed strings).
//
// The real store write cannot be exercised at unit level (`CNContactStore`
// is not constructible or fakeable in unit tests; security design review
// §5/F1 accepts that residual): the evidence set is the source-level
// assertion test in this unit's suite plus the confinement scan, with the
// DV-3/DV-4 device gates on top.
//
// Layering, same as the read glue in `AddressBookDirectory.swift`: the
// pure decisions live in `SystemContactWriteDecision` (exhaustive,
// CNContact-free, fully unit-testable) and the actor is the thin glue
// that calls them around the `CNContactStore` calls it alone can make.

/// App-facing WRITE authorization state, derived from the already-mapped
/// read access (`ContactsAccess`).
///
/// One gate, one mapping: `.allowed` (the book is fully granted) is the
/// only "full" state, `.limited` (iOS 18+ "Select Contacts") is its own
/// state — it may ATTEMPT a write (the record may be inside the granted
/// selection; a record outside it fails and is detected), while `.denied`
/// and `.notDetermined` mean no attempt at all. The iOS-18 availability
/// gate itself lives in `ContactsAccess.from` and is NOT duplicated here
/// (pinned by `ContactsAccessTests`).
enum SystemContactWriteAccess: Equatable {
    case notDetermined
    case denied
    /// iOS 18+ "Select Contacts" — a granted subset; attempts are made.
    case limited
    /// The whole book is granted (`ContactsAccess.allowed`).
    case full

    /// Pure mapping — `.allowed → .full`, `.limited → .limited`,
    /// `.denied → .denied`, `.notDetermined → .notDetermined`.
    static func from(_ access: ContactsAccess) -> SystemContactWriteAccess {
        switch access {
        case .notDetermined: return .notDetermined
        case .allowed: return .full
        case .denied: return .denied
        case .limited: return .limited
        }
    }

    /// May the writer ATTEMPT a store call? `.full` and `.limited` only.
    /// A limited grant still attempts — the picked record may be inside
    /// the selection, and only the store's own answer can tell.
    var allowsWriting: Bool { self == .full || self == .limited }

    /// The closed `state` metadata token of the §5.2 event row. Never
    /// user-visible, never PII.
    var logToken: String {
        switch self {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .limited: return "limited"
        case .full: return "full"
        }
    }
}

/// Why a write attempt did not land. The RAW VALUES are the log reason
/// codes (§5.2) — fixed strings, so a code can never carry content.
enum SystemContactWriteFailure: String, Equatable {
    /// The fetch itself threw (access has not been revoked — this is the
    /// store failing, not the authorization gate).
    case fetchFailed = "fetch_failed"
    /// Under `.limited` access the record is not inside the granted
    /// selection (the fetch throws, or simply does not return it) — a
    /// granted-subset fact, never a denial claim.
    case notInGrantedSelection = "not_in_granted_selection"
    /// `execute` threw, or the mutable copy could not be made: the save
    /// did not land.
    case saveRejected = "save_rejected"
    /// The save appeared to succeed but the bytes read back were not the
    /// bytes written (or could not be read) — never reported as success.
    case readBackMismatch = "read_back_mismatch"
}

/// The closed outcome vocabulary of one write attempt.
enum SystemContactPhotoWriteOutcome: Equatable {
    /// Saved AND verified by read-back byte equality.
    case written
    /// No verified link: NO attempt (produced by the caller's pre-flight —
    /// see `SystemContactWriteDecision.preAttemptOutcome` — so today's
    /// unlinked behaviour is unchanged).
    case skippedNoLink
    /// Access does not permit an attempt: no store call was made.
    case skippedNoAuthorization(SystemContactWriteAccess)
    /// The identifier no longer resolves to a record.
    case recordGone
    /// The fingerprint re-check failed at attempt time: the identifier now
    /// points at a different person. Prevented, not detected — no request
    /// is ever built.
    case identityMismatch
    /// The attempt was made and failed; the payload is the reason code.
    case failed(SystemContactWriteFailure)

    /// Closed log vocabulary (observability only — never user-visible).
    var logToken: String {
        switch self {
        case .written: return "written"
        case .skippedNoLink: return "skipped_no_link"
        case .skippedNoAuthorization: return "skipped_no_authorization"
        case .recordGone: return "record_gone"
        case .identityMismatch: return "identity_mismatch"
        case .failed: return "failed"
        }
    }

    /// The reason code of a failed attempt — the failure's raw value —
    /// and nil for every other outcome (§5.2's `errorCode` column).
    var failureReasonCode: String? {
        if case .failed(let failure) = self { return failure.rawValue }
        return nil
    }

    /// The §5.2 metadata for this outcome: the access `state` token for
    /// `.skippedNoAuthorization` (the one case where "which access" is
    /// the diagnostic), and nothing otherwise. Only allow-listed keys.
    var metadata: [String: String] {
        if case .skippedNoAuthorization(let access) = self {
            return ["state": access.logToken]
        }
        return [:]
    }
}

/// The field a write intent claims to change. Exactly one case today —
/// and the intent's field set is asserted (and source-pinned) to be
/// exactly `[.photo]`, so a second writable field would have to be added
/// here, in the intent, and in the source assertion at once.
enum PhotoWriteField: Hashable {
    case photo
}

/// The confinement record built immediately BEFORE the save: which record
/// (identifier + fingerprint), which field, and a HASH of the payload —
/// never the payload. In-memory only; never persisted, never emitted.
struct PhotoWriteIntent: Equatable {
    /// The target record's `CNContact.identifier`.
    let identifier: String
    /// The fingerprint the record had to still carry (see `SystemContactLink`).
    let numberKey: String
    /// Invariant: `[.photo]`.
    let fields: Set<PhotoWriteField>
    /// 16-hex sha256 prefix of the bytes being assigned — never the bytes.
    /// Empty string for a clear (a clear assigns `nil`, so there is no
    /// payload to hash).
    let imageBytesHash: String

    /// The invariant, as a value: the intent changes the photo field only.
    var isPhotoConfined: Bool { fields == [.photo] }
}

/// The read-back re-fetch's honest two-state result (design-l2 §1.4
/// step 4). The distinction matters: "read back and it is nil" (a
/// successful clear) is NOT the same as "could not read it back" — only
/// the former may ever be reported as `.written`.
enum PhotoReadBack: Equatable {
    /// The record was re-read; its current photo is the payload (nil =
    /// the record carries no photo).
    case bytes(Data?)
    /// The re-fetch failed or found no record: the save's effect is
    /// UNKNOWN, so no success may be claimed.
    case unverifiable
}

/// The write seam the coordinator (and the wizard behind it) holds.
/// `AnyObject` — the real implementation is an actor and the test double
/// is a reference, so identity-based injection stays possible.
protocol SystemContactPhotoWriting: AnyObject {
    /// The CURRENT write access, detected from the store, never assumed.
    /// Never prompts: asking is a deliberate user action in the editor
    /// (design-l1 §9.3).
    func writeAccess() async -> SystemContactWriteAccess
    /// One confined photo write. Returns the closed outcome above.
    func writePhoto(_ jpeg: Data, to link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
    /// One confined photo CLEAR (assigns `imageData = nil`) — same
    /// sequence, same outcomes.
    func clearPhoto(from link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
}

/// The editor's photo outcome states (design-l2 §1.5), consumed by the
/// wizard's post-save step. Placement note: the enum lives with the
/// write seam because its totality is a seam property; the label KEYS are
/// resolved only in the view (`SettingsView.swift`), never here.
enum FamilyPhotoEditorState: Equatable {
    /// The system photo now is (byte-verified) the family photo —
    /// rendered as `family.photo.state.updatedInSystem` (F4: the design
    /// shows the label; the design-doc comment alignment is T-165's).
    case updatedInSystem
    /// The photo was kept in this app only — `family.photo.state.keptOnPhone`.
    case keptOnPhone
    /// Same, plus the access-denied explanation
    /// (`family.photo.state.keptOnPhone` + `family.photo.accessDeniedBody`).
    case keptOnPhoneAccessDenied
    /// The remove flow cleared OUR bytes but the record still carries a
    /// photo — `family.photo.state.systemPhotoRemains`. NOT produced by
    /// `from(_:)`: the remove flow decides it after a clear (design-l2
    /// §2.6 — a clear that returns `.written` is followed by a display
    /// precedence check, and a system photo still present maps here).
    case systemPhotoRemains

    /// TOTAL mapping from every write outcome; `nil` = "no label, today's
    /// UX" (unlinked/unverified — the only silent case).
    ///
    /// Exhaustive switches, no `default`: a new outcome case or a new
    /// failure case must decide its UI consequence at compile time
    /// (design-l1 §10.3 totality). `.failed(.fetchFailed)` is not in the
    /// §1.5 table's row list but is total by the table's own rule — the
    /// photo stays on the phone — and is enumerated explicitly here so
    /// the totality is visible, not implied.
    static func from(_ outcome: SystemContactPhotoWriteOutcome) -> FamilyPhotoEditorState? {
        switch outcome {
        case .written:
            return .updatedInSystem
        case .skippedNoLink:
            return nil
        case .skippedNoAuthorization(let access):
            switch access {
            case .denied:
                return .keptOnPhoneAccessDenied
            case .notDetermined, .limited:
                return .keptOnPhone
            case .full:
                // Contradictory (full access always attempts) — fail
                // closed to the honest fallback rather than claiming a
                // system update that never happened.
                return .keptOnPhone
            }
        case .recordGone, .identityMismatch:
            return .keptOnPhone
        case .failed(let failure):
            switch failure {
            case .fetchFailed, .notInGrantedSelection, .saveRejected, .readBackMismatch:
                return .keptOnPhone
            }
        }
    }
}

/// The pure decision core of the write attempt (design-l2 §1.4): every
/// decision the actor makes EXCEPT the `CNContactStore` calls themselves,
/// so the whole matrix — the no-attempt gate, the fetch classification,
/// the fingerprint precondition, the read-back equality — is unit-testable
/// without touching the store (design-l1 §9.4: no test touches
/// `CNContactStore`). The actor calls these and nothing else.
enum SystemContactWriteDecision {

    /// The decision taken BEFORE any store call; nil = the attempt
    /// proceeds. `hasVerifiedLink` is `true` for the actor itself (its
    /// protocol demands a link) and comes from the verified snapshot for
    /// the coordinator's `syncSystemPhoto` pre-flight, which is the other
    /// producer of `.skippedNoLink`.
    static func preAttemptOutcome(hasVerifiedLink: Bool,
                                  access: SystemContactWriteAccess) -> SystemContactPhotoWriteOutcome? {
        guard hasVerifiedLink else { return .skippedNoLink }
        guard access.allowsWriting else { return .skippedNoAuthorization(access) }
        return nil
    }

    /// Step 1, the throw arm: a fetch that throws is `notInGrantedSelection`
    /// under limited access (the record is outside the granted selection)
    /// and `fetchFailed` otherwise. The `.denied`/`.notDetermined` arms are
    /// unreachable behind `preAttemptOutcome`, but the function stays total.
    static func fetchFailedOutcome(access: SystemContactWriteAccess) -> SystemContactPhotoWriteOutcome {
        access == .limited ? .failed(.notInGrantedSelection) : .failed(.fetchFailed)
    }

    /// Step 1, the empty arm: nothing came back. Under limited access that
    /// is the granted-subset fact; otherwise the record is gone.
    static func recordMissingOutcome(access: SystemContactWriteAccess) -> SystemContactPhotoWriteOutcome {
        access == .limited ? .failed(.notInGrantedSelection) : .recordGone
    }

    /// Step 2 — the fingerprint precondition, re-checked AT ATTEMPT TIME:
    /// the record's CURRENT numbers must still contain one matching the
    /// link's `numberKey` (the shared trailing-digit rule). No match, or no
    /// numbers at all, means the identifier now points at a different
    /// person — the wrong-contact write is PREVENTED, not detected: no
    /// request is built.
    static func fingerprintHolds(_ link: SystemContactLink, currentNumbers: [String]) -> Bool {
        currentNumbers.contains { MissedCallContactResolver.matches(link.numberKey, $0) }
    }

    /// Step 3 — the intent record, built before the save. `jpeg == nil`
    /// (a clear) carries an empty hash: there is no payload.
    static func intent(for link: SystemContactLink, assigning jpeg: Data?) -> PhotoWriteIntent {
        PhotoWriteIntent(identifier: link.identifier,
                         numberKey: link.numberKey,
                         fields: [.photo],
                         imageBytesHash: jpeg.map { SystemContactPhotoWriter.imageBytesHash(of: $0) } ?? "")
    }

    /// Step 4 — read-back byte equality. A write must read back EXACTLY the
    /// bytes assigned; a clear must read back no bytes; a read-back that
    /// could not happen (`unverifiable`) never counts as success.
    static func readBackVerified(assigned: Data?, readBack: PhotoReadBack) -> Bool {
        if case .bytes(let stored) = readBack { return assigned == stored }
        return false
    }
}

/// The confined real glue (design-l1 §9.2). The ONLY file in the tree
/// permitted to construct `CNSaveRequest`/`CNMutableContact`.
///
/// Serialization: actor isolation makes saves strictly serial (one write
/// at a time; ≤12 linked contacts, typically one per Save). No retries, no
/// backoff, no timeouts — a failed attempt simply returns its outcome and
/// the next trigger re-runs.
actor SystemContactPhotoWriter: SystemContactPhotoWriting {

    /// The exact §1.4 fetch key set: identity + the fingerprint's source +
    /// the photo fields (the read-back re-fetch narrows to the photo key).
    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactImageDataKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]

    private let store: CNContactStore
    private let observabilityBus: ObservabilityBus?

    init(store: CNContactStore = CNContactStore(), observabilityBus: ObservabilityBus? = nil) {
        self.store = store
        self.observabilityBus = observabilityBus
    }

    // MARK: - The seam

    /// Current access, detected from the store. Reads only — never prompts.
    func writeAccess() async -> SystemContactWriteAccess {
        currentWriteAccess()
    }

    func writePhoto(_ jpeg: Data, to link: SystemContactLink) async -> SystemContactPhotoWriteOutcome {
        perform(assigning: jpeg, to: link)
    }

    /// The same sequence with no payload: `imageData = nil`.
    func clearPhoto(from link: SystemContactLink) async -> SystemContactPhotoWriteOutcome {
        perform(assigning: nil, to: link)
    }

    // MARK: - The attempt (§1.4, once for both write and clear)

    private func perform(assigning jpeg: Data?, to link: SystemContactLink) -> SystemContactPhotoWriteOutcome {
        let startedAt = Date()
        let access = currentWriteAccess()

        // Pre-attempt gate: no link / no write permission → no store call.
        if let preAttempt = SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true, access: access) {
            return emit(preAttempt, startedAt: startedAt)
        }

        // Step 1 — fetch the linked record by identifier.
        let fetched: [CNContact]
        do {
            fetched = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [link.identifier]),
                keysToFetch: Self.fetchKeys)
        } catch {
            return emit(SystemContactWriteDecision.fetchFailedOutcome(access: access), startedAt: startedAt)
        }
        guard let contact = fetched.first else {
            return emit(SystemContactWriteDecision.recordMissingOutcome(access: access), startedAt: startedAt)
        }

        // Step 2 — fingerprint re-check AT ATTEMPT TIME. A mismatch stops
        // here: no request is built, so nothing can be written to a person
        // this link no longer means.
        let currentNumbers = contact.phoneNumbers.map { $0.value.stringValue }
        guard SystemContactWriteDecision.fingerprintHolds(link, currentNumbers: currentNumbers) else {
            return emit(.identityMismatch, startedAt: startedAt)
        }

        // Step 3 — the intent record, then the confined single-property
        // assignment. `imageData` is the ONLY property ever assigned.
        let intent = SystemContactWriteDecision.intent(for: link, assigning: jpeg)
        assert(intent.isPhotoConfined, "the write intent must be the photo field only")
        guard let mutable = contact.mutableCopy() as? CNMutableContact else {
            return emit(.failed(.saveRejected), startedAt: startedAt)
        }
        mutable.imageData = jpeg
        let request = CNSaveRequest()
        request.update(mutable)
        do {
            try store.execute(request)
        } catch {
            return emit(.failed(.saveRejected), startedAt: startedAt)
        }

        // Step 4 — read-back byte equality; `.written` requires it.
        let readBack = readBackImageData(identifier: link.identifier)
        guard SystemContactWriteDecision.readBackVerified(assigned: jpeg, readBack: readBack) else {
            return emit(.failed(.readBackMismatch), startedAt: startedAt)
        }
        return emit(.written, startedAt: startedAt)
    }

    // MARK: - Store glue

    private func currentWriteAccess() -> SystemContactWriteAccess {
        SystemContactWriteAccess.from(ContactsAccess.from(CNContactStore.authorizationStatus(for: .contacts)))
    }

    /// Re-fetch of `CNContactImageDataKey` only — the verification step's
    /// reader. A throw or an empty result is `.unverifiable` (the save's
    /// effect is unknown), never silently "no photo".
    private func readBackImageData(identifier: String) -> PhotoReadBack {
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [identifier]),
                keysToFetch: [CNContactImageDataKey as CNKeyDescriptor])
            guard let contact = contacts.first else { return .unverifiable }
            return .bytes(contact.imageData)
        } catch {
            return .unverifiable
        }
    }

    // MARK: - Diagnostics (§5.2 row: contacts_photo / write)

    /// Emits the one closed event of this seam and returns the outcome, so
    /// every exit reads as `return emit(...)`. Content-free by
    /// construction: log token, raw failure code, the access state token —
    /// nothing else (no identifier, no number, no byte).
    private func emit(_ outcome: SystemContactPhotoWriteOutcome,
                      startedAt: Date) -> SystemContactPhotoWriteOutcome {
        observabilityBus?.emit(ObservabilityEvent(
            component: "contacts_photo",
            eventType: "write",
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            outcome: outcome.logToken,
            errorCode: outcome.failureReasonCode,
            metadata: outcome.metadata))
        return outcome
    }

    // MARK: - Hashing

    /// The 16-hex sha256 prefix of the bytes being assigned — the only
    /// payload-derived value this seam ever records (design-l1 §9.4:
    /// "a hash by construction"; §5.2 keeps it to fakes and DEBUG
    /// assertions — it is never emitted in an event).
    static func imageBytesHash(of jpeg: Data) -> String {
        SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
