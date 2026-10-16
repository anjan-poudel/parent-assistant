import XCTest
@testable import ElderlyAssistant

/// T-172 — C09's shape for cloud chat: the record, the four decisions, the
/// one writer, the revoke-before-storage ordering and the write-failure
/// honesty (FR-CNR-009, NFR-CNR-006, NFR-CNR-011; design-l1 §8.3, §12, §14).
///
/// The scenarios the unit's failure table calls out are the ones that matter
/// most here, and they are the ones a happy-path test would miss:
///
///  - **Absence is not consent.** A missing, corrupt, stale-version or
///    unreadable record all refuse egress, and each keeps its own name so the
///    routing decision (T-173) and the evidence can tell them apart. The
///    decision the gate returns before any answer has been recorded is
///    `notRecorded`, established without sending anything anywhere.
///  - **A grant is a proof, not a boolean.** "The write returned success" is
///    the store's claim; the gate's own read-back is the fact. A write that
///    vanished, landed as garbage or landed as a *deny* is reported as the
///    failure it is, and the next read stays non-granted.
///  - **Revocation takes effect in memory before storage.** A withdrawal
///    whose delete and tombstone both fail still denies on every later read
///    of this process, and the failure is *reported* — never a quiet success.
///  - **One writer.** The record is written by exactly one API under one
///    lock; concurrent grants and revocations leave one of the two outcomes
///    on disk, never a torn record.
final class CloudChatConsentGateTests: XCTestCase {

    private let consentKey = CloudChatConsentGate.storageKey
    private let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    private func makeGate(config: CloudChatConsentGate.Config = .default)
        -> CloudChatConsentGate {
        CloudChatConsentGate(storage: storage,
                             config: config,
                             observabilityBus: bus,
                             now: { self.recordedAt })
    }

    // MARK: - Scenario: first use records an explicit decision

    func testAnAbsentRecordIsNotRecordedAndRefusesEgress() {
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "no decision has been recorded for the current disclosure version")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertFalse(gate.currentDecision() == .granted,
                       "the only state that allows egress is a recorded grant")

        // The answer was established without writing anything and without a
        // transport-shaped type anywhere in the gate (see
        // `testTheGateHoldsNoTransportNoModelAndNoGrant` below): a fresh
        // install's question costs the elder nothing.
        XCTAssertEqual(storage.writeCount, 0)
        XCTAssertTrue(storage.writtenKeys.isEmpty)
    }

    // MARK: - Scenario: a grant is the only state that allows egress

    func testAGrantedRecordForTheCurrentDisclosureVersionAllowsEgress() {
        let gate = makeGate()

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(gate.currentDecision(), .granted)
        XCTAssertTrue(gate.currentDecision().allowsEgress)
    }

    func testARecordThatSaysNoDeniesAsDenied() {
        let gate = makeGate()

        XCTAssertTrue(gate.record(granted: false).isSuccess)

        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    func testTheFourDecisionsAreDistinguishableAndOnlyAGrantAllowsEgress() {
        XCTAssertEqual(CloudChatConsentGate.Decision.allCases.count, 4)
        for decision in CloudChatConsentGate.Decision.allCases {
            XCTAssertEqual(decision.allowsEgress, decision == .granted,
                           "\(decision) must not allow egress")
        }
        XCTAssertEqual(Set(CloudChatConsentGate.Decision.allCases).count, 4,
                       "the four states are distinct — unreadable never collapses into "
                       + "notRecorded or denied")
    }

    func testTheRecordIsWrittenUnderTheDeclaredKeyAndNowhereElse() {
        storage.setRaw(Data("a neighbour's payload".utf8), forKey: "plugin.point_ask.consent.v1")
        let gate = makeGate()

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(storage.writtenKeys, [consentKey],
                       "the gate writes its own consent key and nothing else")
        XCTAssertNotNil(storage.bytes(forKey: "plugin.point_ask.consent.v1"),
                        "a cloud chat consent decision never touches another feature's record")
        XCTAssertEqual(CloudChatConsentGate.storageKey, "plugin.cloud_chat.consent.v1",
                       "the key is the feature-scoped one the design names")
    }

    // MARK: - Scenario: an unreadable record never collapses into an answer

    func testACorruptRecordIsUnreadableAndNeverCollapsesIntoAnAnswer() {
        for corrupt in ["not a record", "{}", #"{"granted":"yes"}"#,
                        #"{"granted":true}"#, ""] {
            storage.setRaw(Data(corrupt.utf8), forKey: consentKey)
            let gate = makeGate()

            let decision = gate.currentDecision()
            XCTAssertEqual(decision, .unreadable,
                           "an unreadable record is its own state, never a grant and never "
                           + "'not asked yet': \(corrupt)")
            XCTAssertNotEqual(decision, .notRecorded,
                              "corrupt is a different failure from 'the elder has not decided'")
            XCTAssertNotEqual(decision, .denied,
                              "corrupt is a different failure from 'the elder said no'")
            XCTAssertFalse(decision.allowsEgress, "fail closed: \(corrupt)")
        }
        XCTAssertGreaterThan(bus.events(named: "consent_unreadable").count, 0,
                             "every unreadable read is evidenced")

        // One read, one event — the count is not a coincidence of how many
        // times the loop happened to ask.
        let gate = makeGate()
        let before = bus.events(named: "consent_unreadable").count
        _ = gate.currentDecision()
        XCTAssertEqual(bus.events(named: "consent_unreadable").count, before + 1)
    }

    func testAStoreThatCannotAnswerOverBytesItHoldsIsUnreadable() {
        storage.failsReads = true
        storage.setRaw(Data(#"{"granted":true}"#.utf8), forKey: consentKey)
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .unreadable,
                       "bytes the store cannot decode are unreadable, not absent")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    func testAStoreThatCannotAnswerWithNothingAtTheKeyIsNotRecorded() {
        storage.failsReads = true
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "a store that cannot answer over an empty key is a fresh install "
                       + "reading, which is the fail-closed reading: it refuses and it prompts")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    // MARK: - Scenario: a stale disclosure version re-asks

    func testAGrantForADifferentDisclosureVersionIsNotRecordedAndNeverGranted() throws {
        storage.setRaw(try JSONEncoder().encode(CloudChatConsentGate.ConsentRecord(
            granted: true,
            recordedAt: recordedAt,
            disclosureVersion: "cloudchat.disclosure.13oct2026.r0")), forKey: consentKey)
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "the current copy has no record; the elder is asked again under it")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertNotEqual(gate.currentDecision(), .granted)
        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "repeated reads stay notRecorded — a stale grant is never honoured, "
                       + "not even once")
    }

    func testAGrantUnderANewDisclosureVersionRecordsThatVersion() throws {
        var config = CloudChatConsentGate.Config.default
        config.disclosureVersion = "cloudchat.disclosure.14oct2026.r2"
        let gate = makeGate(config: config)

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertEqual(stored.disclosureVersion, "cloudchat.disclosure.14oct2026.r2")
        XCTAssertEqual(gate.currentDecision(), .granted)
    }

    func testReAskingUnderTheNewVersionReplacesTheStaleGrant() throws {
        storage.setRaw(try JSONEncoder().encode(CloudChatConsentGate.ConsentRecord(
            granted: true,
            recordedAt: recordedAt,
            disclosureVersion: "cloudchat.disclosure.13oct2026.r0")), forKey: consentKey)
        let gate = makeGate()
        XCTAssertEqual(gate.currentDecision(), .notRecorded)

        // The re-disclosure's answer, through the one writer.
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(gate.currentDecision(), .granted)
        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertEqual(stored.disclosureVersion,
                       CloudChatConsentGate.Config.default.disclosureVersion,
                       "the replacement grant carries the current stamp, not the old one")
    }

    func testADenyRecordedUnderAnOlderVersionStaysDenied() throws {
        // The shipped precedent's reading, pinned deliberately: only a stale
        // *grant* re-asks. A recorded "no" keeps its name whichever copy it
        // was given under — it refuses egress either way, and calling it
        // notRecorded would hide that the elder already answered.
        storage.setRaw(try JSONEncoder().encode(CloudChatConsentGate.ConsentRecord(
            granted: false,
            recordedAt: recordedAt,
            disclosureVersion: "cloudchat.disclosure.13oct2026.r0")), forKey: consentKey)
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    // MARK: - Scenario: the decision is read per turn (no cached grant)

    func testTheDecisionIsTheStoresCurrentAnswerNotTheLastOne() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(gate.currentDecision(), .granted)

        storage.setRaw(try JSONEncoder().encode(CloudChatConsentGate.ConsentRecord(
            granted: false,
            recordedAt: recordedAt,
            disclosureVersion: CloudChatConsentGate.Config.default.disclosureVersion)),
            forKey: consentKey)
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "a record that changes under the gate is what decides; nothing here "
                       + "memoises a grant for a later turn")

        storage.setRaw(Data("torn".utf8), forKey: consentKey)
        XCTAssertEqual(gate.currentDecision(), .unreadable,
                       "and a record that stops being readable refuses, too")
    }

    // MARK: - Scenario: a write that did not take effect is not a success

    func testAGrantWhoseWriteFailsIsReportedAsAFailureAndTheNextReadIsNotGranted() {
        let gate = makeGate()
        storage.failsWrites = true

        XCTAssertEqual(gate.record(granted: true).failureError, .writeFailed)

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "the decision remains non-granted on the next read")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertNil(storage.bytes(forKey: consentKey),
                     "no record is on disk, so none can read back as a grant")
        XCTAssertFalse(makeGate().currentDecision().allowsEgress,
                       "and a relaunch over the same store refuses identically")
    }

    func testAGrantWhoseWriteDoesNotPersistIsCaughtByTheReadBack() {
        let lying = CloudChatConsentLyingWriteStorage(behaviour: .vanishes)
        let gate = CloudChatConsentGate(storage: lying,
                                        observabilityBus: bus,
                                        now: { self.recordedAt })

        XCTAssertEqual(gate.record(granted: true).failureError, .writeFailed,
                       "the write returned success and the record is not there — the gate "
                       + "reports the failure, never a success for a record not on disk")

        XCTAssertEqual(gate.currentDecision(), .notRecorded)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertNil(lying.bytes(forKey: consentKey))
    }

    func testAGrantWhoseWriteLandsAsGarbageFailsClosed() {
        let lying = CloudChatConsentLyingWriteStorage(behaviour: .storesGarbage)
        let gate = CloudChatConsentGate(storage: lying,
                                        observabilityBus: bus,
                                        now: { self.recordedAt })

        XCTAssertEqual(gate.record(granted: true).failureError, .recordUnreadable,
                       "the read-back found bytes it cannot decode — that is not a grant")
        XCTAssertEqual(gate.currentDecision(), .unreadable)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    func testAGrantWhoseWriteLandsAsADenyIsNotASuccess() {
        let lying = CloudChatConsentLyingWriteStorage(behaviour: .storesDeny)
        let gate = CloudChatConsentGate(storage: lying,
                                        observabilityBus: bus,
                                        now: { self.recordedAt })

        XCTAssertEqual(gate.record(granted: true).failureError, .writeFailed,
                       "what is on disk says no; the call may not claim the elder's grant")
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    func testAnHonestStoreGrantsAndReadsBackAsTheControl() {
        let honest = CloudChatConsentLyingWriteStorage(behaviour: .persists)
        let gate = CloudChatConsentGate(storage: honest,
                                        observabilityBus: bus,
                                        now: { self.recordedAt })

        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(gate.currentDecision(), .granted,
                       "the three lying-write cases above are only meaningful against a "
                       + "store that can carry a grant")
    }

    func testADeclineWhoseWriteFailsStillDeniesInMemory() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.failsWrites = true

        XCTAssertEqual(gate.record(granted: false).failureError, .writeFailed)

        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the elder's 'no' is in force before storage is touched, so a failed "
                       + "decline write still stops egress")
        XCTAssertFalse(gate.currentDecision().allowsEgress)

        // And a later grant that writes and reads back clears the deny.
        storage.failsWrites = false
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(gate.currentDecision(), .granted)
    }

    // MARK: - Scenario: revocation clears memory before storage

    func testRevocationClearsMemoryBeforeStorageSoABrokenStoreStillDenies() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // Both storage paths a revocation has are broken: the delete leaves
        // the grant in place and the tombstone write cannot land. No storage
        // outcome can have produced the deny below — only the in-memory
        // state set before storage was touched.
        storage.failsDeletes = true
        storage.failsWrites = true

        XCTAssertEqual(gate.revoke().failureError, .writeFailed,
                       "a withdrawal that could not be made to take effect is reported as a "
                       + "failure, never as done")
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1,
                       "the failure is evidenced, so it is visible rather than inferred from "
                       + "a missing success")

        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)

        // The honest residual: the record on disk still says granted, which is
        // exactly why the failure is surfaced to the elder instead of being
        // swallowed — a quiet success here is the bug this test exists to
        // prevent. (This session still denies, because the in-memory 'no'
        // outranks disk.)
        XCTAssertEqual(makeGate().currentDecision(), .granted)
    }

    func testTheDenyIsInForceBeforeTheStoredRecordIsRewritten() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // The delete lies (bytes survive) and the tombstone write fails: the
        // stored record is never rewritten, yet the very next read denies.
        storage.keepsBytesAfterDelete = true
        storage.failsWrites = true

        XCTAssertEqual(gate.revoke().failureError, .writeFailed)
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the deny was set in memory before any storage call; the failed write "
                       + "did not — and could not — have produced it")
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "and it persists for every later read in this process")

        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertTrue(stored.granted,
                      "the honest residual: the surviving record still says granted, and the "
                      + "caller was told the withdrawal did not take effect")
    }

    func testRevocationTakesEffectAtTheNextReadAndLeavesNothingToGrantFrom() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertTrue(gate.revoke().isSuccess)

        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the revoking instance denies immediately — its 'no' is in memory")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertNil(storage.bytes(forKey: consentKey),
                     "the verified delete removed the record")
        XCTAssertEqual(makeGate().currentDecision(), .notRecorded,
                       "a relaunch finds no granted record to read back")
        XCTAssertFalse(makeGate().currentDecision().allowsEgress)
    }

    func testARevokingDeleteThatLiesIsCaughtByTheReadBackAndTombstoned() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(storage.writeCount(forKey: consentKey), 1)
        storage.keepsBytesAfterDelete = true

        XCTAssertTrue(gate.revoke().isSuccess,
                      "the read-back catches the lying delete and the tombstone write makes "
                      + "the withdrawal real")

        XCTAssertEqual(storage.writeCount(forKey: consentKey), 2,
                       "the verification step wrote a deny record over the surviving grant")
        XCTAssertEqual(storage.deleteCount, 1)
        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertFalse(stored.granted)
        XCTAssertEqual(gate.currentDecision(), .denied)
    }

    func testARevocationWhoseDeleteFailsStillStopsTheNextRead() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.failsDeletes = true

        // The delete fails, but the tombstone write succeeds: the grant is
        // overwritten by a deny record, so the withdrawal took effect.
        XCTAssertTrue(gate.revoke().isSuccess)
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)

        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertFalse(stored.granted, "the surviving grant was replaced by a deny record")
    }

    func testARevocationThatCannotBeVerifiedIsReportedAsAFailureAndStillDenies() {
        // The worst combination the seam allows: the delete reports success
        // and keeps the bytes, and the store will not decode what is there.
        // The record cannot be shown to be gone — it may be a grant that
        // reads back on a later launch — so the withdrawal is reported as a
        // failure, never as done.
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.keepsBytesAfterDelete = true
        storage.failsReads = true

        XCTAssertEqual(gate.revoke().failureError, .recordUnreadable)
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1,
                       "the unverifiable withdrawal is evidenced as a failure")
    }

    func testARelaunchAfterARevocationCannotReadBackAGrant() {
        storage.failsDeletes = true
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertTrue(gate.revoke().isSuccess,
                      "the tombstone write is what makes the withdrawal real")

        let relaunched = makeGate()
        XCTAssertEqual(relaunched.currentDecision(), .denied,
                       "a withdrawal the elder made must not come back granted")
        XCTAssertFalse(relaunched.currentDecision().allowsEgress)
    }

    // MARK: - Scenario: one writer under a lock

    func testConcurrentGrantAndRevokeNeverLeaveATornOrMixedRecord() {
        let gate = makeGate()
        let iterations = 64
        let outcomesLock = NSLock()
        var outcomes: [Result<Void, CloudChatConsentGate.ConsentError>] = []
        var grantCalls = 0

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let outcome: Result<Void, CloudChatConsentGate.ConsentError>
            if index.isMultiple(of: 2) {
                outcome = gate.record(granted: true)
                outcomesLock.lock(); grantCalls += 1; outcomesLock.unlock()
            } else {
                outcome = gate.revoke()
            }
            outcomesLock.lock(); outcomes.append(outcome); outcomesLock.unlock()
        }

        XCTAssertEqual(outcomes.count, iterations, "every call completed")
        for outcome in outcomes {
            if case .failure(let error) = outcome {
                // The only honest failure on an honest store: this call's own
                // read-back caught the interleaved counterpart. A
                // `recordUnreadable` would mean a torn payload, and that must
                // never happen.
                XCTAssertEqual(error, .writeFailed,
                               "an honest store cannot make a read-back unreadable; only a "
                               + "torn write could, and that is the bug this test exists for")
            }
        }

        let final = gate.currentDecision()
        XCTAssertNotEqual(final, .unreadable,
                          "the storm left a whole record — never a torn payload")
        XCTAssertTrue(final == .granted || final == .denied,
                      "the record is one of the two outcomes (or cleanly absent), never a "
                      + "mixture: \(final)")

        if let bytes = storage.bytes(forKey: consentKey) {
            let record = try? JSONDecoder().decode(CloudChatConsentGate.ConsentRecord.self,
                                                   from: bytes)
            XCTAssertNotNil(record, "every write is a whole record")
            if final == .granted {
                XCTAssertEqual(record?.granted, true,
                               "a granted decision reads back from a granted record")
            }
        }
        XCTAssertGreaterThanOrEqual(storage.writeCount(forKey: consentKey), grantCalls,
                                    "every grant call went through the one write site")

        // The coda: with the storm over, one plain revocation lands fully —
        // the store was left coherent, not merely non-granted.
        XCTAssertTrue(gate.revoke().isSuccess)
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertNil(storage.bytes(forKey: consentKey))
        XCTAssertEqual(makeGate().currentDecision(), .notRecorded)
    }

    // MARK: - One writer: the record is written by exactly one API

    func testTheConsentKeyIsDeclaredOnceAndTheGateHasOneWriteAndOneDeleteSite() {
        let keyUsers = matchingLines(of: NSRegularExpression.escapedPattern(
            for: "plugin.cloud_chat.consent.v1"), inFiles: cloudChatSources)
        XCTAssertEqual(keyUsers.count, 1, "the consent key is declared once: \(keyUsers)")
        guard let keyUser = keyUsers.first else {
            XCTFail("the consent key literal was not found in the feature's sources")
            return
        }
        XCTAssertTrue(keyUser.hasPrefix(gatePath))

        XCTAssertEqual(occurrences(of: "storage\\.write\\(", in: gateSource), 1,
                       "the gate has one storage write site — the one `record(granted:)` and "
                       + "the revocation tombstone share")
        XCTAssertEqual(occurrences(of: "storage\\.delete\\(", in: gateSource), 1,
                       "and one delete site, which is revocation")
        XCTAssertEqual(occurrences(of: "func record\\(granted:", in: gateSource), 1,
                       "one writer")
        XCTAssertEqual(occurrences(of: "func revoke\\(", in: gateSource), 1,
                       "one revocation path")
        XCTAssertEqual(occurrences(of: "func (send|request|upload|post)\\(", in: gateSource), 0,
                       "the gate has no egress verb at all")
    }

    func testNoSourceOutsideTheGateWritesTheConsentRecord() {
        // The call-site half of the single-writer invariant lands with the
        // consent prompt (T-176) and the revocation surfaces (T-177); what is
        // checkable today is that no other file in the feature's source
        // directory knows the key or writes it.
        for file in cloudChatSources where file != gatePath {
            let code = FeatureSourceScan.codeText(
                of: FeatureSourceScan.iosDirectory().appendingPathComponent(file))
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: CloudChatConsentGate.storageKey),
                in: code),
                         "\(file) touches the consent key; only the gate may")
        }
    }

    func testTheStoredRecordIsExactlyTheThreeFieldsAndTheInjectedClock() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let bytes = try XCTUnwrap(storage.bytes(forKey: consentKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["granted", "recordedAt", "disclosureVersion"],
                       "the record is the granted flag, the time and the version — no "
                       + "transcript, no user identifier, no device identifier")

        let record = try JSONDecoder().decode(CloudChatConsentGate.ConsentRecord.self,
                                              from: bytes)
        XCTAssertTrue(record.granted)
        XCTAssertEqual(record.recordedAt, recordedAt,
                       "the timestamp comes from the injected clock, not from an ambient one")
        XCTAssertEqual(record.disclosureVersion,
                       CloudChatConsentGate.Config.default.disclosureVersion)
    }

    // MARK: - No configuration path can produce a grant

    func testNoConfigurationValueReachesTheConsentDecision() {
        let regex = try! NSRegularExpression(pattern: "config\\.([A-Za-z0-9_]+)")
        let whole = NSRange(gateSource.startIndex..<gateSource.endIndex, in: gateSource)
        let touched = Set(regex.matches(in: gateSource, options: [], range: whole).compactMap {
            Range($0.range(at: 1), in: gateSource).map { String(gateSource[$0]) }
        })

        XCTAssertGreaterThan(touched.count, 0, "the scan must see the config it is checking")
        XCTAssertEqual(touched, ["disclosureVersion"],
                       "the only configuration value the decision depends on is the version "
                       + "stamp; a knob that could grant would be a consent the elder never gave")
    }

    func testTheConfigTypeCarriesOnlyTheDisclosureStamp() {
        let configMembers = matchingLines(of: "var [A-Za-z0-9_]+:", inFiles: [gatePath])
            .filter { $0.contains("Config") == false }
        XCTAssertFalse(configMembers.isEmpty, "the scan must see the config it is checking")
        XCTAssertTrue(configSourceText.contains("disclosureVersion"),
                      "the scan must have located the config declaration, not fallen back to "
                      + "an empty string that would make the checks below vacuous")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?i)consent",
                                                  in: configSourceText),
                     "the config has no consent-shaped member")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?i)revoke", in: configSourceText),
                     "revocation is an elder's action, not a setting")
    }

    // MARK: - Evidence: classification-only events, no content-bearing logging

    func testConsentDecisionsAreEvidencedWithContentFreeEvents() {
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\bprint\\(", in: gateSource),
                     "consent decisions are evidenced on the bus, not by printing")

        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertTrue(gate.record(granted: false).isSuccess)
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertTrue(gate.revoke().isSuccess)

        XCTAssertEqual(bus.events(named: "consent_recorded").count, 2)
        XCTAssertEqual(bus.events(named: "consent_denied").count, 1)
        XCTAssertEqual(bus.events(named: "consent_revoked").count, 1)
        for eventType in ["consent_recorded", "consent_denied", "consent_revoked"] {
            XCTAssertEqual(bus.observedMetadataKeys(named: eventType), ["disclosureVersion"],
                           "\(eventType) carries the version stamp and nothing else")
        }
        XCTAssertFalse(bus.events.isEmpty)
        for event in bus.events {
            XCTAssertTrue(CloudChatConsentGate.EventCatalogue.allEventTypes.contains(event.eventType),
                          "\(event.eventType) is not in the gate's catalogue")
            XCTAssertEqual(event.component, "cloud_chat")
            XCTAssertTrue(event.metadata.values.allSatisfy { value in
                value == CloudChatConsentGate.Config.default.disclosureVersion
            }, "no value but the version stamp may travel in the metadata")
        }
    }

    func testAWriteFailureIsEvidencedAsAFailureWithAStableCode() {
        let gate = makeGate()
        storage.failsWrites = true

        XCTAssertEqual(gate.record(granted: true).failureError, .writeFailed)

        let events = bus.events(named: "consent_write_failed")
        XCTAssertEqual(events.count, 1)
        guard let event = events.first else {
            XCTFail("the write failure was not evidenced on the bus")
            return
        }
        XCTAssertEqual(event.outcome, "failure")
        XCTAssertEqual(event.errorCode, "cloudchat_consent_write_failed")
        XCTAssertTrue(event.metadata.isEmpty,
                      "no identifier, no path, no text — a stable code and nothing else")
    }

    func testTheEventCatalogueIsPinned() {
        XCTAssertEqual(CloudChatConsentGate.EventCatalogue.allEventTypes,
                       ["consent_recorded", "consent_denied", "consent_revoked",
                        "consent_unreadable", "consent_write_failed"],
                       "the event set is a closed, reviewed list")
        for (eventType, entry) in CloudChatConsentGate.EventCatalogue.entries {
            XCTAssertTrue(entry.metadataKeys.isSubset(of: ["disclosureVersion"]),
                          "\(eventType) declares metadata outside the content-free set")
        }
    }

    // MARK: - A transport or a model cannot reach the decision at all

    func testTheGateHoldsNoTransportNoModelAndNoGrant() {
        // The gate holds no reference to a model, an engine, an encoder or a
        // session, so there is no path from a crashed or hung one to a grant
        // — and nothing here can send anything anywhere.
        for token in ["Model", "Engine", "Encoder", "Whisper", "Translator",
                      "URLSession", "Task", "async", "Gemini"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: token, in: gateSource),
                         "the gate mentions '\(token)': a model that crashes or hangs must "
                         + "have no object to hang onto, and no request of its own")
        }

        // And its whole state is the store, the catalogue's events, the clock,
        // the config, the lock and a deny-only mirror. The one consent-shaped
        // field can only ever hold "no" — there is nothing else that could
        // hold a grant across a model failure.
        let gate = makeGate()
        XCTAssertEqual(Mirror(reflecting: gate).children.compactMap(\.label).sorted(),
                       ["config", "deniesInMemory", "events", "lock", "now", "storage"])

        // Finally: waiting never helps. A refusal repeated a hundred times is
        // still a refusal, and never drifts into a grant.
        storage = LabelTranslationCacheTestStorage()
        let fresh = makeGate()
        for _ in 0..<100 {
            XCTAssertEqual(fresh.currentDecision(), .notRecorded)
            XCTAssertFalse(fresh.currentDecision().allowsEgress)
        }
    }

    // MARK: - Storage integration (the real, encrypted, on-disk channel)

    func testTheRecordSurvivesOnTheRealEncryptedConsentChannel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudChatConsentGateTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The exact composition the shipped consent records use: the
        // LiveTranslate cipher decorator wrapping the shipped encrypted file
        // channel, with one key store across the three "launches" (the key
        // outliving the process is the point). The gate itself only knows the
        // `EncryptedLocalStorage` seam — this is a new feature-scoped record
        // on the existing mechanism, not a new mechanism.
        let keyStore = LiveTranslateTestCipherKeyStore()
        func storage() -> LiveTranslateCipherStorage {
            LiveTranslateCipherStorage(wrapping: EncryptedFileStorage(rootDirectory: root),
                                       keyStore: keyStore)
        }
        let gate = CloudChatConsentGate(storage: storage(),
                                        observabilityBus: bus,
                                        now: { self.recordedAt })

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "a fresh install has no consent, on the real store as on the double")
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // A relaunch over the same directory keeps the decision.
        let reopened = CloudChatConsentGate(storage: storage(),
                                            observabilityBus: bus)
        XCTAssertEqual(reopened.currentDecision(), .granted,
                       "the record is a real sealed payload on the encrypted channel, not "
                       + "memory")

        XCTAssertTrue(reopened.revoke().isSuccess)

        XCTAssertEqual(reopened.currentDecision(), .denied,
                       "the revoking instance denies from memory")
        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "the delete is real: no read can produce a grant again")
        XCTAssertFalse(gate.currentDecision().allowsEgress)

        let third = CloudChatConsentGate(storage: storage(),
                                         observabilityBus: bus)
        XCTAssertEqual(third.currentDecision(), .notRecorded,
                       "a relaunch after a withdrawal finds no grant to read back")
        XCTAssertFalse(third.currentDecision().allowsEgress)

        // The production channel's own corruption rule, pinned: the cipher
        // decorator discards a payload it cannot authenticate, so damaged
        // bytes on this channel read as absent — never as a grant, and never
        // as a crash.
        let damaged = storage()
        _ = damaged.writeRawData(Data("damaged on disk".utf8),
                                 key: CloudChatConsentGate.storageKey)
        let fourth = CloudChatConsentGate(storage: damaged,
                                          observabilityBus: bus)
        XCTAssertEqual(fourth.currentDecision(), .notRecorded)
        XCTAssertFalse(fourth.currentDecision().allowsEgress)
    }

    // MARK: - Helpers

    private var gatePath: String {
        "ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentGate.swift"
    }

    private var gateSource: String {
        FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(gatePath))
    }

    /// The config declaration's text, for the "no consent knob" check: the
    /// `Config` struct's own lines, from its declaration to `static let
    /// default`.
    private var configSourceText: String {
        let lines = gateSource.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("struct Config") }),
              let end = lines[start...].firstIndex(where: { $0.contains("static let `default`") })
        else {
            return ""
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// The feature's own sources, as `FeatureSourceScan`-style relative paths.
    private var cloudChatSources: [String] {
        FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/Intents/CloudChat")
            .map { FeatureSourceScan.relativePath(of: $0) }
    }

    /// Every line in the named sources matching `pattern`, with its file and
    /// line number — the `FeatureSourceScan.firstMatch` shape, for checks
    /// that need all occurrences rather than the first.
    private func matchingLines(of pattern: String, inFiles files: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return []
        }
        var hits: [String] = []
        for relativePath in files {
            let url = FeatureSourceScan.iosDirectory().appendingPathComponent(relativePath)
            let code = FeatureSourceScan.codeText(of: url)
            for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    hits.append("\(FeatureSourceScan.relativePath(of: url)):\(offset + 1) "
                                + text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return hits
    }

    private func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return 0
        }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }
}

/// A store that lies about its writes, so the gate's read-back verification is
/// exercised against the three ways "the write returned success" can be false.
/// The shipped byte-level double cannot express those: it either stores what
/// it was given or reports a failure, and the whole point of the read-back is
/// a store whose *success* is not evidence that the record is there.
///
/// `.persists` is the honest control, so the three lying cases are only
/// meaningful against a store that can carry a grant.
private final class CloudChatConsentLyingWriteStorage: EncryptedLocalStorage, RawEncryptedStorage {

    enum Behaviour {
        /// The honest control: the write stores what it was given.
        case persists
        /// The write reports success and stores nothing.
        case vanishes
        /// The write reports success and stores bytes no reader can decode.
        case storesGarbage
        /// The write reports success and stores a *deny* record instead.
        case storesDeny
    }

    private let behaviour: Behaviour
    private var raw: [String: Data] = [:]

    private(set) var writeCount = 0
    private(set) var readCount = 0

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func bytes(forKey key: String) -> Data? { raw[key] }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCount += 1
        switch behaviour {
        case .persists:
            guard let data = try? JSONEncoder().encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            raw[key] = data
        case .vanishes:
            break
        case .storesGarbage:
            raw[key] = Data("not a record".utf8)
        case .storesDeny:
            let deny = CloudChatConsentGate.ConsentRecord(
                granted: false,
                recordedAt: Date(timeIntervalSince1970: 0),
                disclosureVersion: CloudChatConsentGate.Config.default.disclosureVersion)
            guard let data = try? JSONEncoder().encode(deny) else {
                return .failure(.encryptedWriteFailed)
            }
            raw[key] = data
        }
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        readCount += 1
        guard let data = raw[key],
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        raw.removeValue(forKey: key)
        return .success(())
    }

    // MARK: - RawEncryptedStorage

    func readRawData(key: String) -> Data? { raw[key] }

    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
        raw[key] = data
        return .success(())
    }
}
