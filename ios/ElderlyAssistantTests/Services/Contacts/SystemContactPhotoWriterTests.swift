import Foundation
import XCTest
@testable import ElderlyAssistant

/// Unit tests for the confined system-contact photo write seam
/// (`SystemContactPhotoWriter`, family-contacts-unify T-154 — design-l1
/// §9.2/§9.4/§10.3, design-l2 §1.4/§1.5/§5.2/§6.2/§6.4; FR-FCU-008,
/// FR-FCU-010, NFR-FCU-002).
///
/// What this suite can and cannot prove, honestly:
///  - The real store write is NOT unit-testable (`CNContactStore` is not
///    constructible or fakeable in the test process — security design
///    review §5 accepts that residual), so nothing here touches it. The
///    seam is pinned in the three ways the design names for that case:
///    (a) the PURE decision core (`SystemContactWriteDecision`) is
///    exercised completely over its matrix — the actor calls these and
///    nothing else; (b) the F1 SOURCE-LEVEL assertions scan the writer's
///    own source (only `imageData` is assigned on the mutable contact;
///    the save request is update-only; the fingerprint re-check and the
///    read-back precede their claims); (c) the module-wide CONFINEMENT
///    scan proves `CNSaveRequest`/`CNMutableContact` live in this one
///    file (the F1 evidence set registered for T-155's release-gate
///    check).
///  - The outcome vocabulary is pinned as the closed §5.2 log vocabulary:
///    log tokens, raw-value reason codes, and the one metadata key.
///  - The §1.5 mapping is pinned total: every outcome (each failure raw
///    value included) maps into `FamilyPhotoEditorState`, and the one
///    state the mapping deliberately never produces
///    (`.systemPhotoRemains`) is named.
///  - `FakeSystemContactPhotoWriter` is the shared scripted double
///    (design-l1 §9.4) injected through `SystemContactPhotoWriting` by
///    the coordinator suites; its records make the no-attempt matrix and
///    the photo-only intent invariant observable.
final class SystemContactPhotoWriterTests: XCTestCase {

    // MARK: - Fixtures

    private let linkedRecord = SystemContactLink(identifier: "ABRecord-42",
                                                 numberKey: "9841234567")

    /// The processed JPEG bytes the seam is handed (T-146 `processedJPEG`
    /// output shape — the seam never re-encodes, so any bytes work here;
    /// the hash is over exactly these).
    private var jpeg: Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) }

    // MARK: - Access mapping (the single gate, · §9.3)

    /// `.allowed` is the only full state; `.limited` stays its own state
    /// (it may ATTEMPT), and denial/nagging keys on `.denied`/
    /// `.notDetermined` only. The iOS-18 availability gate itself is NOT
    /// re-checked here (single-gate pin lives in `ContactsAccessTests`).
    func testWriteAccessMappingIsExhaustive() {
        XCTAssertEqual(SystemContactWriteAccess.from(.allowed), .full)
        XCTAssertEqual(SystemContactWriteAccess.from(.limited), .limited)
        XCTAssertEqual(SystemContactWriteAccess.from(.denied), .denied)
        XCTAssertEqual(SystemContactWriteAccess.from(.notDetermined), .notDetermined)
    }

    /// Exactly `.full` and `.limited` may attempt a store call: a limited
    /// grant is readable AND writable for the records inside it, so the
    /// attempt happens and the store's own answer decides.
    func testAllowsWritingIsFullAndLimitedOnly() {
        XCTAssertTrue(SystemContactWriteAccess.full.allowsWriting)
        XCTAssertTrue(SystemContactWriteAccess.limited.allowsWriting)
        XCTAssertFalse(SystemContactWriteAccess.denied.allowsWriting)
        XCTAssertFalse(SystemContactWriteAccess.notDetermined.allowsWriting)
    }

    /// The `state` metadata vocabulary of §5.2 is closed and unambiguous.
    func testAccessLogTokensAreTheClosedStateVocabulary() {
        let tokens = [SystemContactWriteAccess.notDetermined, .denied, .limited, .full]
            .map(\.logToken)
        XCTAssertEqual(tokens, ["not_determined", "denied", "limited", "full"])
        XCTAssertEqual(Set(tokens).count, tokens.count, "state tokens must be distinct")
    }

    // MARK: - No-attempt matrix (§1.4 pre-attempt gate)

    /// Unlinked/unverified ⇒ `.skippedNoLink`, for every access state:
    /// no store call is made, today's behaviour stands (FR-FCU-010).
    func testNoVerifiedLinkSkipsForEveryAccess() {
        let accesses: [SystemContactWriteAccess] = [.notDetermined, .denied, .limited, .full]
        for access in accesses {
            XCTAssertEqual(
                SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: false, access: access),
                .skippedNoLink,
                "an unverified link must never attempt a write (access \(access.logToken))")
        }
    }

    /// Denied / not-determined ⇒ `.skippedNoAuthorization(<the access>)`
    /// — the payload names the access the caller must show copy for, and
    /// is identity-equal to the state it was given (the mapping never
    /// re-derives or mutates it).
    func testDeniedAndNotDeterminedSkipWithTheirOwnAccessPayload() {
        XCTAssertEqual(
            SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true, access: .denied),
            .skippedNoAuthorization(.denied))
        XCTAssertEqual(
            SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true, access: .notDetermined),
            .skippedNoAuthorization(.notDetermined))
    }

    /// `.full` and `.limited` proceed to the attempt (nil = attempt).
    /// A limited grant must not be treated as denial: the record may be
    /// inside the granted selection.
    func testFullAndLimitedAccessProceedToTheAttempt() {
        XCTAssertNil(SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true, access: .full))
        XCTAssertNil(SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true, access: .limited))
    }

    /// …and the gate and the readable-states rule agree end to end: every
    /// access that may attempt is exactly one the write mapping allows.
    func testThePreAttemptGateAgreesWithAllowsWriting() {
        let accesses: [SystemContactWriteAccess] = [.notDetermined, .denied, .limited, .full]
        for access in accesses {
            let proceeds = SystemContactWriteDecision
                .preAttemptOutcome(hasVerifiedLink: true, access: access) == nil
            XCTAssertEqual(proceeds, access.allowsWriting,
                           "gate and allowsWriting disagree for \(access.logToken)")
        }
    }

    // MARK: - Fetch classification (§1.4 step 1)

    /// A throwing fetch is the granted-subset fact under limited access
    /// (the record is outside the selection) and `fetch_failed`
    /// otherwise. `.denied`/`.notDetermined` cannot reach here behind the
    /// pre-attempt gate; the function stays total for them.
    func testFetchFailureClassification() {
        XCTAssertEqual(SystemContactWriteDecision.fetchFailedOutcome(access: .limited),
                       .failed(.notInGrantedSelection))
        XCTAssertEqual(SystemContactWriteDecision.fetchFailedOutcome(access: .full),
                       .failed(.fetchFailed))
        XCTAssertEqual(SystemContactWriteDecision.fetchFailedOutcome(access: .denied),
                       .failed(.fetchFailed))
        XCTAssertEqual(SystemContactWriteDecision.fetchFailedOutcome(access: .notDetermined),
                       .failed(.fetchFailed))
    }

    /// An empty fetch is `record_gone` under full access and the
    /// granted-subset fact under limited access — never a claim that the
    /// book is off.
    func testEmptyFetchClassification() {
        XCTAssertEqual(SystemContactWriteDecision.recordMissingOutcome(access: .limited),
                       .failed(.notInGrantedSelection))
        XCTAssertEqual(SystemContactWriteDecision.recordMissingOutcome(access: .full),
                       .recordGone)
        XCTAssertEqual(SystemContactWriteDecision.recordMissingOutcome(access: .denied),
                       .recordGone)
        XCTAssertEqual(SystemContactWriteDecision.recordMissingOutcome(access: .notDetermined),
                       .recordGone)
    }

    // MARK: - Fingerprint precondition (§1.4 step 2 — no request on mismatch)

    /// The trailing-digit rule decides: a differently formatted spelling
    /// of the SAME number holds; a different number, an empty list, or
    /// unusable entries do not. False means `.identityMismatch`, and no
    /// request is ever built (the source-order pin below proves the
    /// ordering; this pins the rule).
    func testFingerprintPreconditionUsesTheSharedTrailingDigitRule() {
        XCTAssertTrue(SystemContactWriteDecision.fingerprintHolds(
            linkedRecord, currentNumbers: ["+977-9841 23 45 67"]))
        XCTAssertTrue(SystemContactWriteDecision.fingerprintHolds(
            linkedRecord, currentNumbers: ["01-234", "9841234567"]))
        XCTAssertFalse(SystemContactWriteDecision.fingerprintHolds(
            linkedRecord, currentNumbers: ["9851000000"]))
        XCTAssertFalse(SystemContactWriteDecision.fingerprintHolds(
            linkedRecord, currentNumbers: []))
        XCTAssertFalse(SystemContactWriteDecision.fingerprintHolds(
            linkedRecord, currentNumbers: ["", "not a number"]))
    }

    /// A link whose `numberKey` is empty can never hold: nothing matches
    /// nothing (a corrupt/empty fingerprint fails closed instead of
    /// matching every record).
    func testFingerprintNeverHoldsForAnEmptyNumberKey() {
        let corrupt = SystemContactLink(identifier: "ABRecord-42", numberKey: "")
        XCTAssertFalse(SystemContactWriteDecision.fingerprintHolds(
            corrupt, currentNumbers: ["+977-9841 23 45 67"]))
    }

    // MARK: - Read-back verification (§1.4 step 4)

    /// Byte-equality matrix: a write must read back EXACTLY the bytes
    /// assigned; a clear must read back no bytes; any difference — and
    /// any read-back that could not happen — is not success (never a
    /// false "updated in system").
    func testReadBackVerificationMatrix() {
        XCTAssertTrue(SystemContactWriteDecision.readBackVerified(
            assigned: jpeg, readBack: .bytes(jpeg)))
        XCTAssertFalse(SystemContactWriteDecision.readBackVerified(
            assigned: jpeg, readBack: .bytes(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x11]))))
        XCTAssertFalse(SystemContactWriteDecision.readBackVerified(
            assigned: jpeg, readBack: .bytes(nil)))
        XCTAssertTrue(SystemContactWriteDecision.readBackVerified(
            assigned: nil, readBack: .bytes(nil)),
                      "a clear that reads back no bytes succeeded")
        XCTAssertFalse(SystemContactWriteDecision.readBackVerified(
            assigned: nil, readBack: .bytes(jpeg)),
                      "a clear whose photo remained did not")
    }

    /// `unverifiable` is never success — for a write or for a clear. The
    /// save's effect is unknown, so the honest outcome is the mismatch
    /// reason code.
    func testUnverifiableReadBackIsNeverSuccess() {
        XCTAssertFalse(SystemContactWriteDecision.readBackVerified(
            assigned: jpeg, readBack: .unverifiable))
        XCTAssertFalse(SystemContactWriteDecision.readBackVerified(
            assigned: nil, readBack: .unverifiable))
    }

    // MARK: - Intent confinement (§1.4 step 3, §6.2 layer 2)

    /// The intent built before every save claims the photo field only,
    /// carries the record handle and the fingerprint, and carries a HASH
    /// of the payload — never the payload.
    func testIntentIsPhotoFieldOnly() {
        let intent = SystemContactWriteDecision.intent(for: linkedRecord, assigning: jpeg)
        XCTAssertEqual(intent.fields, [.photo])
        XCTAssertTrue(intent.isPhotoConfined)
        XCTAssertEqual(intent.identifier, linkedRecord.identifier)
        XCTAssertEqual(intent.numberKey, linkedRecord.numberKey)
        XCTAssertEqual(intent.imageBytesHash, SystemContactPhotoWriter.imageBytesHash(of: jpeg))
    }

    /// A clear's intent is still the photo field, with an EMPTY hash: a
    /// clear assigns `nil`, so there are no bytes to hash (and the hash
    /// field never has to pretend otherwise).
    func testClearIntentIsPhotoFieldOnlyWithNoPayloadHash() {
        let intent = SystemContactWriteDecision.intent(for: linkedRecord, assigning: nil)
        XCTAssertTrue(intent.isPhotoConfined)
        XCTAssertEqual(intent.imageBytesHash, "")
    }

    /// The hash is a stable 16-hex sha256 prefix: deterministic for the
    /// same bytes, different for different bytes, and never a rendering of
    /// the bytes themselves.
    func testImageBytesHashIsAStableSha256Prefix() {
        let hash = SystemContactPhotoWriter.imageBytesHash(of: jpeg)
        XCTAssertEqual(hash.count, 16)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(hash, SystemContactPhotoWriter.imageBytesHash(of: jpeg))
        XCTAssertNotEqual(hash, SystemContactPhotoWriter.imageBytesHash(of: Data([0x01])))
        XCTAssertNotEqual(hash, String(data: jpeg, encoding: .utf8))
    }

    /// Structural pin: `PhotoWriteIntent` stores the handle, the
    /// fingerprint, the field set and the hash — and NOTHING of type
    /// `Data`. The "never the bytes" claim is a property of the record's
    /// shape, not of a promise.
    func testPhotoWriteIntentCarriesNoBytes() {
        let intent = SystemContactWriteDecision.intent(for: linkedRecord, assigning: jpeg)
        let mirror = Mirror(reflecting: intent)
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)),
                       ["identifier", "numberKey", "fields", "imageBytesHash"])
        for child in mirror.children {
            XCTAssertFalse(child.value is Data,
                           "PhotoWriteIntent must never store image bytes (\(child.label ?? "?"))")
        }
    }

    // MARK: - Outcome vocabulary (§5.2, closed)

    /// Log tokens are the closed §5.2 vocabulary — a new outcome case
    /// cannot slip an unlisted token into the event stream.
    func testOutcomeLogTokensAreTheClosedVocabulary() {
        let tokens = [
            SystemContactPhotoWriteOutcome.written,
            .skippedNoLink,
            .skippedNoAuthorization(.denied),
            .recordGone,
            .identityMismatch,
            .failed(.fetchFailed),
        ].map(\.logToken)
        XCTAssertEqual(tokens, ["written", "skipped_no_link", "skipped_no_authorization",
                                "record_gone", "identity_mismatch", "failed"])
        XCTAssertEqual(Set(tokens).count, tokens.count, "tokens must be distinct")
    }

    /// The failure raw values ARE the reason codes (§5.2's `errorCode`
    /// column), they are fixed strings (no content can enter them, F7),
    /// and no other outcome carries one.
    func testFailureReasonCodesAreTheRawValuesAndOnlyOnFailed() {
        XCTAssertEqual(SystemContactWriteFailure.fetchFailed.rawValue, "fetch_failed")
        XCTAssertEqual(SystemContactWriteFailure.notInGrantedSelection.rawValue,
                       "not_in_granted_selection")
        XCTAssertEqual(SystemContactWriteFailure.saveRejected.rawValue, "save_rejected")
        XCTAssertEqual(SystemContactWriteFailure.readBackMismatch.rawValue, "read_back_mismatch")

        let noCode: [SystemContactPhotoWriteOutcome] = [
            .written, .skippedNoLink, .skippedNoAuthorization(.denied),
            .recordGone, .identityMismatch,
        ]
        for outcome in noCode {
            XCTAssertNil(outcome.failureReasonCode,
                         "only .failed carries a reason code (\(outcome.logToken))")
        }
        XCTAssertEqual(SystemContactPhotoWriteOutcome.failed(.saveRejected).failureReasonCode,
                       "save_rejected")
    }

    /// Metadata carries the allow-listed `state` key exactly once — for
    /// `.skippedNoAuthorization`, which is the case where the access is
    /// the diagnostic — and nothing otherwise.
    func testMetadataIsStateOnlyForSkippedNoAuthorization() {
        XCTAssertEqual(SystemContactPhotoWriteOutcome.skippedNoAuthorization(.limited).metadata,
                       ["state": "limited"])
        XCTAssertEqual(SystemContactPhotoWriteOutcome.skippedNoAuthorization(.notDetermined).metadata,
                       ["state": "not_determined"])
        let withoutMetadata: [SystemContactPhotoWriteOutcome] = [
            .written, .skippedNoLink, .recordGone, .identityMismatch, .failed(.readBackMismatch),
        ]
        for outcome in withoutMetadata {
            XCTAssertTrue(outcome.metadata.isEmpty,
                          "no metadata outside skipped_no_authorization (\(outcome.logToken))")
        }
    }

    // MARK: - Outcome → editor state, total (§1.5)

    /// The §1.5 table, row for row: the success case, both skip families,
    /// the degraded record cases and every failure raw value. Totality is
    /// compile-enforced by the no-`default` switches in
    /// `FamilyPhotoEditorState.from`; this test pins each row's value.
    func testFromMapsEveryOutcomeRowOfTheTable() {
        XCTAssertEqual(FamilyPhotoEditorState.from(.written), .updatedInSystem)
        XCTAssertNil(FamilyPhotoEditorState.from(.skippedNoLink))

        XCTAssertEqual(FamilyPhotoEditorState.from(.skippedNoAuthorization(.notDetermined)),
                       .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.skippedNoAuthorization(.denied)),
                       .keptOnPhoneAccessDenied)
        XCTAssertEqual(FamilyPhotoEditorState.from(.skippedNoAuthorization(.limited)),
                       .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.skippedNoAuthorization(.full)),
                       .keptOnPhone,
                       "contradictory state fails closed — never a claimed system update")

        XCTAssertEqual(FamilyPhotoEditorState.from(.recordGone), .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.identityMismatch), .keptOnPhone)

        XCTAssertEqual(FamilyPhotoEditorState.from(.failed(.notInGrantedSelection)), .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.failed(.saveRejected)), .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.failed(.readBackMismatch)), .keptOnPhone)
        XCTAssertEqual(FamilyPhotoEditorState.from(.failed(.fetchFailed)), .keptOnPhone,
                       "a failed fetch keeps the photo on the phone (never a false success)")
    }

    /// Each failure raw value maps — and maps into a KEPT state, never
    /// into "updated in system": the honest direction for every failure
    /// path (scenario: read-back mismatch or save error never claims a
    /// system update).
    func testEveryFailureRawValueMapsToAKeptState() {
        let failures: [SystemContactWriteFailure] = [.fetchFailed, .notInGrantedSelection,
                                                     .saveRejected, .readBackMismatch]
        for failure in failures {
            let state = FamilyPhotoEditorState.from(.failed(failure))
            XCTAssertEqual(state, .keptOnPhone, "\(failure.rawValue) must map to keptOnPhone")
            XCTAssertNotEqual(state, .updatedInSystem)
        }
    }

    /// `.systemPhotoRemains` exists in the vocabulary but is NEVER
    /// produced by the outcome mapping: the remove flow decides it after
    /// a clear (design-l2 §2.6), because a write outcome alone cannot
    /// tell a write from a clear. Pinned so the mapping cannot start
    /// claiming that state for a failure.
    func testSystemPhotoRemainsIsNotProducedByTheOutcomeMapping() {
        let outcomes: [SystemContactPhotoWriteOutcome] = [
            .written, .skippedNoLink,
            .skippedNoAuthorization(.notDetermined), .skippedNoAuthorization(.denied),
            .skippedNoAuthorization(.limited), .skippedNoAuthorization(.full),
            .recordGone, .identityMismatch,
            .failed(.fetchFailed), .failed(.notInGrantedSelection),
            .failed(.saveRejected), .failed(.readBackMismatch),
        ]
        for outcome in outcomes {
            XCTAssertNotEqual(FamilyPhotoEditorState.from(outcome), .systemPhotoRemains,
                              "\(outcome.logToken) must not claim the remove-flow state")
        }
        XCTAssertNotEqual(FamilyPhotoEditorState.systemPhotoRemains, .keptOnPhone,
                          "the remove-flow state stays a distinct vocabulary entry")
    }

    // MARK: - The fake double (design-l1 §9.4)

    /// Scripted access is reported and counted — the callers' ask-Access
    /// bookkeeping stays observable.
    func testFakeReportsScriptedAccessAndCountsRequests() async {
        let fake = FakeSystemContactPhotoWriter()
        fake.access = .limited
        let first = await fake.writeAccess()
        let second = await fake.writeAccess()
        XCTAssertEqual(first, .limited)
        XCTAssertEqual(second, .limited)
        XCTAssertEqual(fake.accessRequests, 2)
    }

    /// No-attempt matrix at the double: for unlinked and for every
    /// no-authorization access, a write leaves NO intent and NO payload —
    /// there was nothing to confine. (The real seam decides this in
    /// `preAttemptOutcome`; the double must model the same contract so
    /// the coordinator suites cannot observe an attempt that the seam
    /// would never make.)
    func testFakeRecordsNoIntentForNoAttemptOutcomes() async {
        let noAttempts: [SystemContactPhotoWriteOutcome] = [
            .skippedNoLink,
            .skippedNoAuthorization(.notDetermined),
            .skippedNoAuthorization(.denied),
            .skippedNoAuthorization(.limited),
            .skippedNoAuthorization(.full),
        ]
        for outcome in noAttempts {
            let fake = FakeSystemContactPhotoWriter()
            fake.outcome = outcome
            let returned = await fake.writePhoto(jpeg, to: linkedRecord)
            XCTAssertEqual(returned, outcome)
            XCTAssertTrue(fake.intents.isEmpty,
                          "no intent may be recorded for \(outcome.logToken)")
            XCTAssertTrue(fake.writes.isEmpty,
                          "no payload may be recorded for \(outcome.logToken)")
        }
    }

    /// The pre-request failures (fetch failed/empty, fingerprint mismatch)
    /// record no intent either: the request is only ever built after the
    /// fingerprint holds — which is what "prevented, not detected" means
    /// for the wrong-contact write.
    func testFakeRecordsNoIntentBeforeTheRequestIsBuilt() async {
        let preRequest: [SystemContactPhotoWriteOutcome] = [
            .recordGone,
            .identityMismatch,
            .failed(.fetchFailed),
            .failed(.notInGrantedSelection),
        ]
        for outcome in preRequest {
            let fake = FakeSystemContactPhotoWriter()
            fake.outcome = outcome
            let returned = await fake.writePhoto(jpeg, to: linkedRecord)
            XCTAssertEqual(returned, outcome)
            XCTAssertTrue(fake.intents.isEmpty,
                          "no request exists yet for \(outcome.logToken)")
        }
    }

    /// Every attempted outcome records exactly ONE intent, and EVERY
    /// recorded intent satisfies the photo-only invariant (§6.2 layer 2:
    /// the field-set invariant is asserted on every call).
    func testFakeRecordsPhotoOnlyIntentForAttemptedOutcomes() async {
        let attempts: [SystemContactPhotoWriteOutcome] = [
            .written,
            .failed(.saveRejected),
            .failed(.readBackMismatch),
        ]
        for outcome in attempts {
            let fake = FakeSystemContactPhotoWriter()
            fake.outcome = outcome
            let returned = await fake.writePhoto(jpeg, to: linkedRecord)
            XCTAssertEqual(returned, outcome)
            XCTAssertEqual(fake.writes.count, 1)
            XCTAssertEqual(fake.writes.first?.jpeg, jpeg)
            XCTAssertEqual(fake.writes.first?.link, linkedRecord)
            XCTAssertEqual(fake.intents.count, 1)
            XCTAssertTrue(fake.intents.allSatisfy(\.isPhotoConfined),
                          "every recorded intent must be photo-only (\(outcome.logToken))")
            XCTAssertEqual(fake.intents.first?.imageBytesHash,
                           SystemContactPhotoWriter.imageBytesHash(of: jpeg))
        }
    }

    /// A clear is an attempt too: the link is recorded, still with a
    /// photo-only intent and the empty (no-payload) hash.
    func testFakeClearRecordsTheClearedLinkWithAnEmptyHash() async {
        let fake = FakeSystemContactPhotoWriter()
        let outcome = await fake.clearPhoto(from: linkedRecord)
        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(fake.clearedLinks, [linkedRecord])
        XCTAssertEqual(fake.intents, [PhotoWriteIntent(identifier: linkedRecord.identifier,
                                                       numberKey: linkedRecord.numberKey,
                                                       fields: [.photo],
                                                       imageBytesHash: "")])
        XCTAssertTrue(fake.intents.allSatisfy(\.isPhotoConfined))
    }

    /// The double's model of "was a request built?" agrees with the
    /// no-attempt/pre-request/attempt classification the seam implements
    /// — the one place the double and the production vocabulary meet.
    func testFakeRequestIsBuiltClassification() {
        for outcome in Self.noRequestOutcomes {
            XCTAssertFalse(FakeSystemContactPhotoWriter.requestIsBuilt(for: outcome),
                           "\(outcome.logToken) happens before the request is built")
        }
        for outcome in Self.attemptOutcomes {
            XCTAssertTrue(FakeSystemContactPhotoWriter.requestIsBuilt(for: outcome),
                          "\(outcome.logToken) happens after the request is built")
        }
    }

    private static let noRequestOutcomes: [SystemContactPhotoWriteOutcome] = [
        .skippedNoLink,
        .skippedNoAuthorization(.notDetermined),
        .skippedNoAuthorization(.denied),
        .skippedNoAuthorization(.limited),
        .skippedNoAuthorization(.full),
        .recordGone,
        .identityMismatch,
        .failed(.fetchFailed),
        .failed(.notInGrantedSelection),
    ]

    private static let attemptOutcomes: [SystemContactPhotoWriteOutcome] = [
        .written,
        .failed(.saveRejected),
        .failed(.readBackMismatch),
    ]

    // MARK: - F1 source-level assertions (scan the writer's own source)

    /// The production file under scan, located through `FeatureSourceScan`
    /// (the same path contract the confinement scan uses).
    private static let writerRelativePath =
        "ElderlyAssistant/Services/Contacts/SystemContactPhotoWriter.swift"

    private func writerSource() -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent(Self.writerRelativePath)
        return FeatureSourceScan.codeText(of: url)
    }

    /// All capture-group-1 matches of `pattern` in `text`, in order.
    private func captured(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capturedRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capturedRange])
        }
    }

    /// The first occurrence of `marker` in `text`, for order assertions.
    private func position(of marker: String, in text: String) -> String.Index? {
        text.range(of: marker)?.lowerBound
    }

    /// F1 layer 2, the assertion the security review asked for: the ONLY
    /// property assigned on the mutable system contact is `imageData`.
    /// The binding name is DERIVED from the checked `mutableCopy()` cast,
    /// so a rename cannot quietly dodge the scan — and a second mutated
    /// property fails this test.
    func testOnlyImageDataIsAssignedOnTheMutableContact() {
        let source = writerSource()
        let bindings = captured(
            #"guard let (\w+) = \S+\.mutableCopy\(\) as\? CNMutableContact"#, in: source)
        XCTAssertEqual(bindings.count, 1,
                       "expected exactly one checked mutable-copy guard; found \(bindings)")
        guard let binding = bindings.first else { return }

        let assignmentSites = captured("\\b\(binding)\\.(\\w+) *=", in: source)
        XCTAssertEqual(assignmentSites, ["imageData"],
                       "the only property assigned on the mutable system contact must be "
                       + "imageData; found \(assignmentSites)")
        XCTAssertEqual(assignmentSites.count, 1,
                       "exactly one assignment site on the mutable contact (write and clear "
                       + "share the one parameterised path)")

        for forceCast in ["mutableCopy() as!", "as! CNMutableContact", "try!"] {
            XCTAssertFalse(source.contains(forceCast),
                           "no force cast / force unwrap on the write path (\(forceCast))")
        }
    }

    /// F1 layer 2, the request half: the save request is constructed once
    /// and its ONLY mutation is an `update` of that one mutable contact —
    /// never `add` (no creation) and never `delete` (no deletion).
    func testTheSaveRequestIsUpdateOnly() {
        let source = writerSource()
        XCTAssertEqual(captured(#"let (\w+) = CNSaveRequest\(\)"#, in: source), ["request"],
                       "the save request is constructed exactly once")
        XCTAssertEqual(captured(#"\brequest\.(\w+)\("#, in: source), ["update"],
                       "the only call on the save request must be update(_:)")
        for forbidden in ["request.add(", "request.delete(", "request.addMember(",
                          "request.removeMember("] {
            XCTAssertFalse(source.contains(forbidden),
                           "the update-only claim forbids \(forbidden)")
        }
    }

    /// The attempt sequence, in source order (§1.4): fetch → fingerprint
    /// re-check → intent → checked mutable copy → execute → read-back
    /// verification → `.written`. Plus the two orderings that make the
    /// confinement more than a comment: the fingerprint mismatch returns
    /// BEFORE any request exists, and `.failed(.saveRejected)` follows the
    /// `execute` inside its do/catch.
    func testTheAttemptSequenceIsFetchFingerprintIntentSaveReadBackWrite() {
        let source = writerSource()

        let orderedMarkers = [
            "[link.identifier]",                                             // fetch by identifier
            "fingerprintHolds(link, currentNumbers: currentNumbers)",        // step 2
            "let intent = SystemContactWriteDecision.intent(for: link, assigning: jpeg)",
            "mutableCopy() as? CNMutableContact",                            // step 3
            "let request = CNSaveRequest()",
            "request.update(mutable)",
            "try store.execute(request)",
            "let readBack = readBackImageData(identifier: link.identifier)", // step 4
            "SystemContactWriteDecision.readBackVerified(assigned: jpeg, readBack: readBack)",
            "return emit(.written, startedAt: startedAt)",
        ]
        var previous: String.Index?
        for marker in orderedMarkers {
            guard let index = position(of: marker, in: source) else {
                XCTFail("marker not found in the writer source: \(marker)")
                return
            }
            if let previous {
                XCTAssertLessThan(previous, index,
                                  "\(marker) is out of the §1.4 order")
            }
            previous = index
        }

        guard let mismatch = position(of: "return emit(.identityMismatch, startedAt: startedAt)",
                                      in: source),
              let mutableCopy = position(of: "mutableCopy() as? CNMutableContact", in: source),
              let request = position(of: "let request = CNSaveRequest()", in: source) else {
            XCTFail("expected the identity-mismatch return, the mutable copy and the request")
            return
        }
        XCTAssertLessThan(mismatch, mutableCopy,
                          "a fingerprint mismatch must return before any mutable copy exists")
        XCTAssertLessThan(mismatch, request,
                          "a fingerprint mismatch must return before any request is built")
    }

    /// The success claim is gated on the read-back, and the save's
    /// failure arm is a do/catch around `execute` that returns the
    /// `save_rejected` reason code — pinned on the save block itself, so
    /// a future edit cannot make `.written` unconditional or let an
    /// `execute` error escape the outcome vocabulary.
    func testTheSaveBlockCatchesExecuteFailuresAndTheSuccessIsGatedOnReadBack() {
        let source = writerSource()
        guard let requestStart = position(of: "let request = CNSaveRequest()", in: source),
              let readBackStart = position(of: "let readBack = readBackImageData", in: source) else {
            XCTFail("expected the request construction and the read-back re-fetch")
            return
        }
        let saveBlock = String(source[requestStart..<readBackStart])
        XCTAssertTrue(saveBlock.contains("request.update(mutable)"))
        XCTAssertTrue(saveBlock.contains("try store.execute(request)"))
        XCTAssertTrue(saveBlock.contains("} catch {"),
                      "execute must sit inside a do/catch")
        XCTAssertTrue(saveBlock.contains(".failed(.saveRejected)"),
                      "an execute failure must surface as the save_rejected reason code")

        guard let verified = position(of: "readBackVerified(assigned: jpeg, readBack: readBack)",
                                      in: source),
              let written = position(of: "return emit(.written", in: source) else {
            XCTFail("expected the read-back verification and the written return")
            return
        }
        XCTAssertLessThan(verified, written,
                          "`.written` must be returned only after the read-back verified")
    }

    /// The seam writes NOTHING to the console (the §5.2 rule T-155's
    /// release gate re-checks from outside) and carries no force
    /// unwraps — the two source-level properties this file must keep.
    func testTheWriterSourceCarriesNoConsoleWriteOrForceUnwrap() {
        let source = writerSource()
        for forbidden in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint("] {
            XCTAssertFalse(source.contains(forbidden),
                           "the write seam must write no console output (\(forbidden))")
        }
        for forbidden in ["try!", "as!", "fatalError(", "preconditionFailure("] {
            XCTAssertFalse(source.contains(forbidden),
                           "the write seam must not trap or force anything (\(forbidden))")
        }
    }

    /// The §5.2 event wiring, pinned at source level (the store cannot be
    /// driven from a test, so this is how the closed vocabulary is tied
    /// to the one emit site): component `contacts_photo`, eventType
    /// `write`, the outcome log token, the raw reason code, the metadata
    /// — and no identifier, number or byte anywhere near the event.
    func testTheWriterEmitsTheClosedContactsPhotoWriteEvent() {
        let source = writerSource()
        for required in [#"component: "contacts_photo""#,
                         #"eventType: "write""#,
                         "observabilityBus?.emit(ObservabilityEvent(",
                         "outcome: outcome.logToken",
                         "errorCode: outcome.failureReasonCode",
                         "metadata: outcome.metadata"] {
            XCTAssertTrue(source.contains(required),
                          "the §5.2 write event wiring is incomplete: \(required)")
        }
        XCTAssertFalse(source.contains("identifier: intent."),
                       "no identifier may enter the event")
        XCTAssertFalse(source.contains("integerValue"),
                       "no number may enter the event")
    }

    /// F1 layer 1, module-wide (§6.2/§6.4): `CNSaveRequest` and
    /// `CNMutableContact` occur in exactly ONE file of the app module —
    /// this writer. Any other file constructing them fails the gate.
    func testCNSaveRequestAndCNMutableContactLiveOnlyInTheWriterFile() {
        let tokens = ["CNSaveRequest", "CNMutableContact"]
        var sitesByFile: [String: Set<String>] = [:]
        for url in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant") {
            let text = FeatureSourceScan.codeText(of: url)
            let hits = Set(tokens.filter { text.contains($0) })
            if !hits.isEmpty {
                sitesByFile[FeatureSourceScan.relativePath(of: url)] = hits
            }
        }
        XCTAssertEqual(Set(sitesByFile.keys), [Self.writerRelativePath],
                       "CNSaveRequest/CNMutableContact must live only in the write seam; found: "
                       + sitesByFile.keys.sorted().joined(separator: ", "))
        XCTAssertEqual(sitesByFile[Self.writerRelativePath], Set(tokens),
                       "the scan must find BOTH tokens in the writer itself (a scan that "
                       + "matches nothing proves nothing)")
    }

    /// `CNContactStore` stays the read glue's dependency too: the writer
    /// may hold the store, but the TWO files that name it in code are the
    /// writer and the address-book directory (§6.2's allowance) — pinned
    /// so a third construction site cannot appear unnoticed.
    func testCNContactStoreConstructionsStayInTheAllowedFiles() {
        let allowed: Set<String> = [Self.writerRelativePath,
                                    "ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift"]
        var sites: Set<String> = []
        for url in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant") {
            let text = FeatureSourceScan.codeText(of: url)
            guard text.contains("CNContactStore(") else { continue }
            sites.insert(FeatureSourceScan.relativePath(of: url))
        }
        XCTAssertTrue(sites.isSubset(of: allowed),
                      "unexpected CNContactStore construction sites: "
                      + sites.subtracting(allowed).sorted().joined(separator: ", "))
        XCTAssertTrue(sites.contains(Self.writerRelativePath),
                      "the writer must be one of the store's construction sites")
    }
}

/// The shared scripted double for the write seam (design-l1 §9.4): it
/// records what a real attempt would have built — one `PhotoWriteIntent`
/// per request that was built, the payload bytes, and the cleared link —
/// and returns the scripted outcome. Injected through
/// `SystemContactPhotoWriting`, so no suite that uses it touches
/// `CNContactStore`.
final class FakeSystemContactPhotoWriter: SystemContactPhotoWriting {

    /// One recorded write call.
    struct WriteCall: Equatable {
        let link: SystemContactLink
        let jpeg: Data
    }

    /// Scripted access state `writeAccess()` reports (default: full).
    var access: SystemContactWriteAccess = .full

    /// Scripted outcome for the next attempt (default: `.written`).
    var outcome: SystemContactPhotoWriteOutcome = .written

    private(set) var accessRequests = 0
    /// One intent per call whose outcome happens AFTER the request was
    /// built (§1.4 steps 3-4) — the invariant every assertion applies.
    private(set) var intents: [PhotoWriteIntent] = []
    /// The bytes handed to each write that built a request, in call order.
    private(set) var writes: [WriteCall] = []
    /// The links cleared by calls that built a request, in call order.
    private(set) var clearedLinks: [SystemContactLink] = []

    func writeAccess() async -> SystemContactWriteAccess {
        accessRequests += 1
        return access
    }

    func writePhoto(_ jpeg: Data, to link: SystemContactLink) async -> SystemContactPhotoWriteOutcome {
        if Self.requestIsBuilt(for: outcome) {
            intents.append(PhotoWriteIntent(identifier: link.identifier,
                                            numberKey: link.numberKey,
                                            fields: [.photo],
                                            imageBytesHash: SystemContactPhotoWriter
                                                .imageBytesHash(of: jpeg)))
            writes.append(WriteCall(link: link, jpeg: jpeg))
        }
        return outcome
    }

    func clearPhoto(from link: SystemContactLink) async -> SystemContactPhotoWriteOutcome {
        if Self.requestIsBuilt(for: outcome) {
            intents.append(PhotoWriteIntent(identifier: link.identifier,
                                            numberKey: link.numberKey,
                                            fields: [.photo],
                                            imageBytesHash: ""))
            clearedLinks.append(link)
        }
        return outcome
    }

    /// §1.4: which outcomes happen AFTER the request was built. Exhaustive
    /// switch, no `default` — a new outcome case must classify itself.
    static func requestIsBuilt(for outcome: SystemContactPhotoWriteOutcome) -> Bool {
        switch outcome {
        case .written, .failed(.saveRejected), .failed(.readBackMismatch):
            return true
        case .skippedNoLink, .skippedNoAuthorization, .recordGone, .identityMismatch,
             .failed(.fetchFailed), .failed(.notInGrantedSelection):
            return false
        }
    }
}
