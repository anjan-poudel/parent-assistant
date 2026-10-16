import XCTest
@testable import ElderlyAssistant

/// Point, tap & ask — the consent gate (design
/// `docs/superpowers/specs/2026-09-19-point-tap-ask-design.md` §5, §6): the
/// deliberate mirror of `LiveTranslateConsentGateTests` (T-014) for the
/// feature's own key and version stamp.
///
/// The scenarios the design's failure table calls out are the ones that
/// matter most here, and they are the ones a happy-path test would miss:
///
///  - **Absence is not consent.** A missing, corrupt, stale-version or
///    unreadable record all deny, and each keeps its own name so the surfaces
///    and the evidence can tell them apart.
///  - **A withdrawal is immediate even when storage is broken.** The elder's
///    "no" lands in memory before it lands on disk, the delete is verified by
///    reading back, a surviving grant is overwritten with a deny record, and a
///    revocation that could not be made to take effect is *reported as a
///    failure* rather than returned as a success.
///  - **A decline is a withdrawal in miniature.** The deny-first rule covers
///    the prompt's "no" exactly as it covers revocation: a decline whose
///    write fails still stops egress for the rest of the process.
///  - **One writer.** The record is written by exactly one API, reachable
///    from exactly the two controls the design sanctions (the session
///    model's grant and decline handlers), and no configuration value can
///    reach the decision.
final class PointAskConsentGateTests: XCTestCase {

    private let consentKey = PointAskConsentGate.storageKey
    private let cacheKey = LabelTranslationCache.storageKey
    private let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    private func makeGate(config: PointAskConfig = .default) -> PointAskConsentGate {
        PointAskConsentGate(storage: storage,
                            config: config,
                            observabilityBus: bus,
                            now: { self.recordedAt })
    }

    /// The error of a failed authorization, or nil — `Result`'s own accessors
    /// are awkward to assert on directly.
    private func error(of result: Result<PointAskConsentGate.Grant, PointAskError>)
        -> PointAskError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Every line in the feature's sources matching `pattern`, with its file
    /// and line number — the same shape `FeatureSourceScan.firstMatch` uses,
    /// for the checks that need all occurrences rather than the first.
    private func matchingLines(of pattern: String,
                               inFiles files: [String]) -> [String] {
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

    /// The feature's own sources, as `FeatureSourceScan`-style relative paths.
    private var pointAskSources: [String] {
        FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/PointAsk")
            .map { FeatureSourceScan.relativePath(of: $0) }
            + ["ElderlyAssistant/Services/Gemini/GeminiClient+PointAsk.swift"]
    }

    // MARK: - Scenario: a grant is the only decision that allows a send

    func testAGrantedRecordForTheCurrentDisclosureVersionAllowsEgress() {
        let gate = makeGate()
        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "nothing is granted before a decision")

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(gate.currentDecision(), .granted)
        XCTAssertTrue(gate.currentDecision().allowsEgress)
        guard case .success(let grant) = gate.authorize() else {
            return XCTFail("a recorded grant must authorize a request")
        }
        XCTAssertEqual(grant.disclosureVersion, PointAskConfig.default.disclosureVersion,
                       "the proof carries the version it was granted for")
    }

    func testTheRecordIsWrittenUnderTheDeclaredKeyAndNowhereElse() {
        let gate = makeGate()
        storage.setRaw(Data("cached translation".utf8), forKey: cacheKey)

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(storage.writtenKeys, [consentKey],
                       "the gate writes the consent key and nothing else")
        XCTAssertNotNil(storage.bytes(forKey: cacheKey),
                        "a consent decision never touches the translation cache")
    }

    // MARK: - Scenario: every absence form denies, with its own decision

    func testAnAbsentRecordDeniesAsNotRecorded() {
        let gate = makeGate()
        XCTAssertEqual(gate.currentDecision(), .notRecorded)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(error(of: gate.authorize()), .consentNotRecorded)
    }

    func testARecordThatSaysNoDeniesAsDenied() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: false).isSuccess)

        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)
    }

    func testACorruptRecordDeniesAsUnreadableAndNeverAsGranted() {
        for corrupt in ["not a record", "{}", #"{"granted":"yes"}"#, #"{"granted":true}"#] {
            storage.setRaw(Data(corrupt.utf8), forKey: consentKey)
            let gate = makeGate()

            XCTAssertEqual(gate.currentDecision(), .unreadable,
                           "an unreadable record is its own state, never a grant and never "
                           + "'not asked yet': \(corrupt)")
            XCTAssertFalse(gate.currentDecision().allowsEgress)
            XCTAssertEqual(error(of: gate.authorize()), .consentRecordUnreadable)
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

    func testAStoreThatCannotAnswerAtAllDeniesAsUnreadable() {
        storage.failsReads = true
        storage.setRaw(Data("{\"granted\":true}".utf8), forKey: consentKey)
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .unreadable,
                       "bytes the store cannot decode are unreadable, not absent")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
    }

    func testTheFourDecisionsAreDistinguishableAndOnlyAGrantAllowsEgress() {
        XCTAssertEqual(PointAskConsentGate.Decision.allCases.count, 4)
        for decision in PointAskConsentGate.Decision.allCases {
            XCTAssertEqual(decision.allowsEgress, decision == .granted,
                           "\(decision) must not allow egress")
        }
        XCTAssertEqual(Set(PointAskConsentGate.Decision.allCases).count, 4,
                       "the four states are distinct")
    }

    // MARK: - Scenario: a stale grant does not carry over

    func testAGrantForADifferentDisclosureVersionDoesNotCarryOver() throws {
        storage.setRaw(try JSONEncoder().encode(PointAskConsentGate.ConsentRecord(
            granted: true,
            recordedAt: recordedAt,
            disclosureVersion: "pointask.disclosure.older.r0")), forKey: consentKey)
        let gate = makeGate()

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "the current copy has no record; the elder is asked again under it")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(error(of: gate.authorize()), .consentNotRecorded)
    }

    func testGrantingUnderANewDisclosureVersionRecordsThatVersion() throws {
        var config = PointAskConfig.default
        config.disclosureVersion = "pointask.disclosure.draft.19sep2026.r2"
        let gate = makeGate(config: config)

        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let stored = try JSONDecoder().decode(
            PointAskConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertEqual(stored.disclosureVersion, "pointask.disclosure.draft.19sep2026.r2")
        XCTAssertEqual(gate.currentDecision(), .granted)
    }

    // MARK: - Scenario: no configuration implies consent

    func testNoConfigurationValueReachesTheConsentDecision() {
        let gateSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/"
                                        + "PointAskConsentGate.swift"))
        let regex = try! NSRegularExpression(pattern: "config\\.([A-Za-z0-9_]+)")
        let whole = NSRange(gateSource.startIndex..<gateSource.endIndex, in: gateSource)
        let touched = Set(regex.matches(in: gateSource, options: [], range: whole).compactMap {
            Range($0.range(at: 1), in: gateSource).map { String(gateSource[$0]) }
        })

        XCTAssertGreaterThan(touched.count, 0, "the scan must see the config it is checking")
        XCTAssertEqual(touched, ["disclosureVersion"],
                       "the only configuration value the decision depends on is the version stamp; "
                       + "a knob that could grant would be a consent the elder never gave")
    }

    func testTheConfigTypeCarriesNoConsentSetting() {
        let configSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/"
                                        + "PointAskConfig.swift"))
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?i)consent", in: configSource),
                     "there is no consent parameter to set")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?i)revoke", in: configSource),
                     "revocation is an elder's action, not a setting")
    }

    // MARK: - Scenario: the record is explicit and minimal

    func testTheStoredRecordCarriesExactlyThreeFieldsAndNoMore() throws {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let bytes = try XCTUnwrap(storage.bytes(forKey: consentKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["granted", "recordedAt", "disclosureVersion"],
                       "the record is the granted flag, the time and the version — no user "
                       + "identifier, no device identifier, no free text")

        let record = try JSONDecoder().decode(PointAskConsentGate.ConsentRecord.self,
                                              from: bytes)
        XCTAssertTrue(record.granted)
        XCTAssertEqual(record.recordedAt, recordedAt,
                       "the timestamp comes from the injected clock, not from an ambient one")
    }

    // MARK: - Scenario: withdrawal is immediate (AM-1, AM-4)

    func testAWithdrawalBetweenTwoAttemptsDeniesTheRetry() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // Attempt 1 is authorized...
        guard case .success = gate.authorize() else {
            return XCTFail("the first attempt is authorized by the recorded grant")
        }
        XCTAssertTrue(gate.revoke().isSuccess)

        // ...and the tier re-reads the gate immediately before the retry
        // (AM-1): anything but `granted` denies, and the record is gone.
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)
        XCTAssertNil(storage.bytes(forKey: consentKey), "revocation deletes the record")
    }

    func testARevocationDeniesInMemoryEvenWhenStorageCannotBeRead() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // Every read and every write fails from here on; the delete works.
        // The raw channel still shows the bytes are gone, so the withdrawal
        // *is* verified — and the in-memory deny is in force regardless, so
        // the next attempt is denied whatever storage says.
        storage.failsReads = true
        storage.failsWrites = true

        XCTAssertTrue(gate.revoke().isSuccess,
                      "a store whose read is down is not a store still holding a grant: the "
                      + "raw channel answers what the decoding read cannot")
        XCTAssertNil(storage.bytes(forKey: consentKey), "the delete was real")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the elder's 'no' is in force in memory even though nothing could be "
                       + "read back")
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)
    }

    func testARevocationWhoseDeleteFailsStillStopsTheNextAttempt() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.failsDeletes = true

        // The delete fails, but the tombstone write succeeds: the grant is
        // overwritten by a deny record, so the withdrawal took effect.
        XCTAssertTrue(gate.revoke().isSuccess)
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)

        let stored = try! JSONDecoder().decode(
            PointAskConsentGate.ConsentRecord.self,
            from: XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertFalse(stored.granted, "the surviving grant was replaced by a deny record")
    }

    func testADeleteThatReportsSuccessAndKeepsTheRecordIsCaughtByTheReadBack() {
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
        let stored = try! JSONDecoder().decode(
            PointAskConsentGate.ConsentRecord.self,
            from: XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertFalse(stored.granted)
    }

    func testARevocationWhoseDeleteLiesAndCannotBeReadIsReportedAsAFailure() {
        // The worst combination the seam allows: the delete reports success
        // and keeps the bytes, and the store will not decode what is there.
        // The record cannot be shown to be gone — it may be a grant that
        // reads back on a later launch — so the withdrawal is reported as a
        // failure, never as done. The tombstone is attempted anyway, and the
        // in-memory deny stands for the rest of this session (AM-4).
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.keepsBytesAfterDelete = true
        storage.failsReads = true

        XCTAssertEqual(gate.revoke().failureError, .recordUnreadable,
                       "an unverifiable record is not a completed withdrawal")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1,
                       "the unverifiable withdrawal is evidenced as a failure")
    }

    func testAWithdrawalThatCannotBeMadeToTakeEffectIsNeverSilent() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.failsDeletes = true
        storage.failsWrites = true

        XCTAssertEqual(gate.revoke().failureError, .writeFailed)
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1,
                       "the failure is evidenced, so it is visible rather than inferred from "
                       + "a missing success")

        // The honest residual: when every write path is broken, the record on
        // disk still says granted. The gate cannot fix that, which is exactly
        // why the failure is surfaced to the elder and to the log instead of
        // being swallowed — a quiet success here is the bug this test exists
        // to prevent.
        let relaunched = makeGate()
        XCTAssertEqual(relaunched.currentDecision(), .granted)
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "this session still denies, because the in-memory 'no' outranks disk")
    }

    func testARelaunchCannotReadBackAGrantThatWasWithdrawn() {
        storage.failsDeletes = true
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertTrue(gate.revoke().isSuccess)

        // A relaunch is a new gate over the same bytes.
        let relaunched = makeGate()
        XCTAssertEqual(relaunched.currentDecision(), .denied,
                       "a withdrawal the elder made must not come back granted")
        XCTAssertFalse(relaunched.currentDecision().allowsEgress)
    }

    // MARK: - Scenario: a decline is a withdrawal in miniature (deny first)

    func testADeclineDeniesInMemoryEvenWhenItsWriteFails() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        storage.failsWrites = true

        XCTAssertEqual(gate.record(granted: false).failureError, .writeFailed)

        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the elder's 'no' is in force before storage is touched, so a failed "
                       + "decline write still stops egress")
        XCTAssertEqual(error(of: gate.authorize()), .consentDenied)

        // And a later grant that writes and reads back clears the deny.
        storage.failsWrites = false
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(gate.currentDecision(), .granted)
    }

    // MARK: - Scenario: revocation cancels in-flight work (AM-1)

    func testRevocationCancelsEveryRegisteredInFlightRequest() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        var cancelled = 0
        let first = gate.registerInFlight { cancelled += 1 }
        let second = gate.registerInFlight { cancelled += 1 }
        XCTAssertEqual(gate.inFlightRegistrationCount, 2)

        XCTAssertTrue(gate.revoke().isSuccess)

        XCTAssertEqual(cancelled, 2, "every in-flight request is cancelled, not just the newest")
        XCTAssertEqual(gate.inFlightRegistrationCount, 0)
        _ = first
        _ = second
    }

    func testRegistrationIsReleasedOnEveryExitAndCannotBeCancelledTwice() {
        let gate = makeGate()
        var cancelled = 0
        let registration = gate.registerInFlight { cancelled += 1 }

        gate.revoke()
        XCTAssertEqual(cancelled, 1)
        gate.revoke()
        XCTAssertEqual(cancelled, 1, "a second revocation does not cancel the same attempt again")

        registration.release()
        registration.release()
        XCTAssertEqual(gate.inFlightRegistrationCount, 0, "release is idempotent")
    }

    // MARK: - Scenario: a request needs the gate's proof (AM-7)

    func testAGrantCanOnlyBeMintedByTheGate() {
        let mints = matchingLines(of: "\\bGrant\\(disclosureVersion:",
                                  inFiles: pointAskSources)
        XCTAssertEqual(mints.count, 1,
                       "exactly one place mints a consent proof, and it is the gate's own "
                       + "authorize(): \(mints)")
        XCTAssertTrue(mints[0].hasPrefix("ElderlyAssistant/Services/PointAsk/"
                                         + "PointAskConsentGate.swift"))

        let gateSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/"
                                        + "PointAskConsentGate.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "fileprivate init(disclosureVersion: String)"),
            in: gateSource),
                        "the proof's initialiser is `fileprivate`, so no file outside the gate "
                        + "can mint one and the builder that requires a Grant cannot be reached "
                        + "without the gate (AM-7)")
    }

    func testTheConsentKeyIsDeclaredOnceAndOnlyTheGateWritesIt() {
        let keyUsers = matchingLines(of: NSRegularExpression.escapedPattern(
            for: "\"plugin.point_ask.consent.v1\""), inFiles: pointAskSources)
        XCTAssertEqual(keyUsers.count, 1, "the consent key is declared once: \(keyUsers)")
        XCTAssertTrue(keyUsers[0].hasPrefix(gatePath))

        let gateSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(gatePath))
        XCTAssertEqual(occurrences(of: "storage\\.write\\(", in: gateSource), 1,
                       "the gate has one storage write site — the one `record(granted:)` and "
                       + "the revocation tombstone share")
        XCTAssertEqual(occurrences(of: "storage\\.delete\\(", in: gateSource), 1,
                       "and one delete site, which is revocation")
    }

    func testTheRecordIsWrittenOnlyByThePromptsTwoAnswers() {
        // The record's writer is reachable from exactly two controls, and
        // both are the consent surfaces: the session model's grant and
        // decline handlers. A third call site is a consent written by
        // something the elder never touched.
        let callers = matchingLines(of: "\\.record\\(granted:",
                                    inFiles: pointAskSources)
        XCTAssertEqual(callers.count, 2,
                       "the prompt's two answers are the only calls: \(callers)")
        for caller in callers {
            XCTAssertTrue(caller.hasPrefix("ElderlyAssistant/Services/PointAsk/"
                                           + "PointAskSessionModel.swift"),
                          "an unauthorised writer of the consent record: \(caller)")
        }
    }

    func testTheGateIsTheOnlyThingThatCanAuthorizeOrDeny() {
        let authors = matchingLines(of: "func authorize\\(\\)", inFiles: pointAskSources)
        XCTAssertEqual(authors.count, 1, "one authorization policy: \(authors)")
    }

    // MARK: - Evidence

    func testEveryDecisionPointIsEvidencedWithContentFreeEvents() {
        let gate = makeGate()
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\bprint\\(",
                                                  in: FeatureSourceScan.codeText(
                                                    of: FeatureSourceScan.iosDirectory()
                                                        .appendingPathComponent(
                                                            "ElderlyAssistant/Services/PointAsk/"
                                                            + "PointAskConsentGate.swift"))),
                     "consent decisions are evidenced on the bus, not by printing")

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
        for event in bus.events {
            XCTAssertTrue(Set(PointAskEventCatalogue.entries.keys).contains(event.eventType),
                          "\(event.eventType) is not in the catalogue")
        }
    }

    func testAWriteFailureIsEvidencedAsAFailureWithAStableCode() {
        let gate = makeGate()
        storage.failsWrites = true

        XCTAssertEqual(gate.record(granted: true).failureError, .writeFailed)

        let events = bus.events(named: "consent_write_failed")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].outcome, "failure")
        XCTAssertEqual(events[0].errorCode, "pointask_consent_write_failed")
        XCTAssertTrue(events[0].metadata.isEmpty,
                      "no identifier, no path, no text — a stable code and nothing else")
    }

    // MARK: - A model cannot reach the decision at all

    func testACrashOrHangOfAModelCannotGrantConsentOrBypassTheGate() {
        // The gate holds no reference to a model, an engine, an encoder or a
        // session, so there is no path from a crashed or hung one to a grant.
        let gateSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(gatePath))
        for modelType in ["Model", "Engine", "Encoder", "Whisper", "Translator",
                          "URLSession", "Task", "async"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: modelType, in: gateSource),
                         "the gate mentions '\(modelType)': a model that crashes or hangs "
                         + "must have no object to hang onto")
        }

        // And its whole state is the store, the catalogue's events, the clock
        // and a deny-only mirror.
        let gate = makeGate()
        XCTAssertEqual(Mirror(reflecting: gate).children.compactMap(\.label).sorted(),
                       ["config", "deniesInMemory", "events", "inFlight", "lock", "now", "storage"])

        // A grant is re-read from the store every time, so a hung request
        // holds no memoised permission: a record that changes under the gate
        // is what decides, and a record that stops being readable denies.
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(gate.currentDecision(), .granted)
        storage.setRaw(Data(), forKey: consentKey)
        XCTAssertEqual(gate.currentDecision(), .unreadable,
                       "the decision is the store's current answer, not the last one")

        // Finally: waiting never helps. A refusal repeated a hundred times is
        // still a refusal, and never drifts into a grant.
        storage = LabelTranslationCacheTestStorage()
        let fresh = makeGate()
        for _ in 0..<100 {
            XCTAssertEqual(fresh.currentDecision(), .notRecorded)
            XCTAssertEqual(error(of: fresh.authorize()), .consentNotRecorded)
        }
    }

    // MARK: - Storage integration (the real, encrypted, on-disk channel)

    func testTheRecordSurvivesOnTheRealEncryptedChannelAndRevocationRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PointAskConsentGateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The gate takes the shipped encrypted file channel directly: the
        // record is written as a protected payload on disk, and three
        // "launches" share the directory because the point is persistence.
        func storage() -> EncryptedFileStorage {
            EncryptedFileStorage(rootDirectory: root)
        }
        let gate = PointAskConsentGate(storage: storage(),
                                       observabilityBus: bus,
                                       now: { self.recordedAt })

        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "a fresh install has no consent, on the real store as on the double")
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        // A relaunch over the same directory keeps the decision.
        let reopened = PointAskConsentGate(storage: storage(),
                                           observabilityBus: bus)
        XCTAssertEqual(reopened.currentDecision(), .granted,
                       "the record is a real payload on the encrypted channel, not memory")

        XCTAssertTrue(reopened.revoke().isSuccess)

        // Revocation is the delete (design, C09), so the verified outcome is
        // an *empty* channel, not a deny record. What matters for AM-4 part 4
        // is that no read can produce a grant again — a fresh gate over the
        // same directory cannot resurrect it.
        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "the delete is real: the file's payload is gone")
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        let third = PointAskConsentGate(storage: storage(),
                                        observabilityBus: bus)
        XCTAssertEqual(third.currentDecision(), .notRecorded,
                       "a relaunch after a withdrawal finds no grant to read back")
        XCTAssertFalse(third.currentDecision().allowsEgress)
        XCTAssertEqual(error(of: third.authorize()), .consentNotRecorded)
    }

    // MARK: Helpers

    private var gatePath: String {
        "ElderlyAssistant/Services/PointAsk/PointAskConsentGate.swift"
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
