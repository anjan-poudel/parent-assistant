import Foundation
import XCTest
@testable import ElderlyAssistant

// T-177 — the indicator, the revocation surfaces and the coordinator wiring
// (FR-CNR-007, FR-CNR-008, FR-CNR-009; NFR-CNR-009; design-l1 §8.5, §8.6).
//
// The unit's Gherkin, one scenario per section below:
//
//  1. The badge is present for the whole cloud-active window (the routing
//     decision → the reply spoken) and reflects the enabled state in
//     Settings; a local turn never shows it (a build in which the badge
//     shows during local-only traffic fails this suite — the model section
//     pins the window semantics, and the wiring pins below prove the window
//     has exactly ONE open site, reached only from the cloud attempt).
//  2. One short spoken notice per session, at the first cloud-active turn,
//     in the elder's language, never replacing or delaying the reply
//     (pinned at the call site: the once-flag, the single caller and the
//     catalogue key — the utterance itself is heard on the device
//     checklist, T-185).
//  3. Revocation from the Settings toggle AND one deterministic voice
//     revoke keyword rule, both through the gate's ONE writer; the next
//     turn routes local with no cached route surviving (driven end to end
//     through the REAL coordinator and the REAL router in this file).
//  4. The spoken state query answers truthfully from the gate's decision,
//     in the elder's language, in both states.
//  5. Every pre-existing keyword behaviour unchanged (pinned in
//     `KeywordIntentRuleTests` — the cloud-chat family claims nothing any
//     existing rule claims).
//  6. No content or identity in any event or log line, no new permission,
//     no Info.plist change (the classification-only event assertions and
//     the source-hygiene pins).
//
// Witness strategy (mirrors `DialogueCoordinatorWiringTests`): the real
// `AppCoordinator` is constructed fresh per test and `start()` is
// deliberately never called (it re-registers BGTaskScheduler handlers and
// trips a platform exception in the test host). Everything reachable
// through `init` — the gate's writers, the prompt, the surfaces, the
// confirmation window — is driven behaviourally; the `start()`-scoped
// wiring (the lane/guard seams, the responder hooks, the window's open
// site) is pinned by region-scoped source scans of the shipped call sites,
// each scan a named property, not a formatting accident. The consent
// record itself is process-EXTERNAL state (the gate lives on the app's
// real store — the injected profile double does not back it), so the
// suite purges it before and after every test (the Isolation section).


// MARK: - Test doubles (file-scope: no cross-suite visibility)

private final class CNR177MockBus: ObservabilityBus {
    var emitted: [ObservabilityEvent] = []
    func emit(_ event: ObservabilityEvent) { emitted.append(event) }
}

private final class CNR177MockSpeaker: Speaker {
    var spoken: [String] = []
    func speak(_ text: String, locale: Locale) async { spoken.append(text) }
    func cancel() {}
}

/// The stub cloud chat interpreter behind the responder wrapper. Records
/// that the delegate was asked, answers with a scripted command, and
/// carries a settable failure class so the wrapper's forwarding is
/// observable.
private final class CNR177StubChatResponder: ChatResponding, CloudFailureReporting {
    var askedCount = 0
    var lastTranscript: String?
    var lastContext: InterpreterContext?
    var completionCommand: InterpretedCommand?
    var failureClass: GeminiFailureClass?
    var clearedFailure = false

    func respondToChat(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
        askedCount += 1
        lastTranscript = transcript
        lastContext = context
        completion(completionCommand)
    }

    var lastCloudFailureClass: GeminiFailureClass? { failureClass }

    func clearCloudFailure() {
        clearedFailure = true
        failureClass = nil
    }
}

/// An interpreter that records every consultation — used to prove the
/// cloud-chat voice family never reaches a model (T-177: "no model/NLU/
/// classifier widening": the family is resolved by keywords alone).
private final class CNR177RecordingInterpreter: CommandInterpreter {
    var isAvailable = true
    private(set) var interpreted: [String] = []

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpreted.append(transcript)
        completion(nil)
    }
}

/// In-memory stand-in for the encrypted channel (the per-file private fake
/// every coordinator suite carries): the coordinator's init requires one
/// and nothing in this suite reads the profile back.
private final class CNR177InMemoryProfilePayloadStorage: ProfilePayloadStorage {
    var payloads: [String: Data] = [:]
    private let encoder = JSONEncoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard let data = try? encoder.encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        payloads[key] = data
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)   // this fake is raw-read only
    }

    func delete(key: String) -> Result<Void, StorageError> {
        payloads[key] = nil
        return .success(())
    }

    func readRawData(key: String) -> Data? { payloads[key] }
    func hasPayload(key: String) -> Bool? { payloads[key] != nil }
}

// MARK: - The suite

@MainActor
final class CloudChatIndicatorAndRevocationTests: XCTestCase {

    // MARK: Fixtures

    private let revokeUtterance = "इन्टरनेटबाट जवाफ बन्द गर"
    private let stateQueryUtterance = "इन्टरनेटबाट जवाफ आउँदैछ?"

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(profileStorage: CNR177InMemoryProfilePayloadStorage())
    }

    private func makeRouter(_ coordinator: AppCoordinator,
                            interpreter: CommandInterpreter = NullCommandInterpreter())
        -> (router: CommandRouter, bus: CNR177MockBus) {
        let bus = CNR177MockBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: CNR177MockSpeaker(),
                                   interpreter: interpreter)
        return (router, bus)
    }

    private func chatCommand(_ reply: String) -> InterpretedCommand {
        InterpretedCommand(action: .chat, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: nil, callType: nil,
                           requestedApp: nil, confidence: 0.9, reply: reply)
    }

    private func chatContext() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne",
                           addressAs: nil)
    }

    // MARK: Isolation (the consent record is a REAL store)

    /// The coordinator's consent gate is built over the app's real
    /// `MigratingEncryptedStorage` — the injected profile double only backs
    /// the profile store (`profileStorage ?? storage`) — so the
    /// `plugin.cloud_chat.consent.v1` record is process-external state: it
    /// survives between coordinator instances AND between runs. (Wave-close
    /// rework, 2026-10-15: four tests were order-dependent for exactly this
    /// reason.) Purge the key through the SAME channel the gate writes
    /// through, before and after every test — the Spotify-wiring suite's
    /// own "a fresh install in the app's own terms" pattern: an absent
    /// record is exactly a fresh install (`.notRecorded`), and the teardown
    /// keeps a real grant or denial from outliving the suite.
    override func setUp() {
        super.setUp()
        purgeCloudChatConsentRecord()
    }

    override func tearDown() {
        purgeCloudChatConsentRecord()
        super.tearDown()
    }

    /// `MigratingEncryptedStorage.delete(key:)` routes by key (the keychain
    /// copy first, then the file store) — the same routing the gate's
    /// `LiveTranslateCipherStorage` forwards to — so this removes the exact
    /// slot `currentDecision()` reads. Never around the storage under test:
    /// the channel is the app's own.
    private func purgeCloudChatConsentRecord() {
        _ = MigratingEncryptedStorage().delete(key: CloudChatConsentGate.storageKey)
    }

    /// A coordinator over a purged consent record — the multi-leg test's
    /// own fresh install. `setUp` purges once per test, so the FIRST
    /// coordinator of a test is covered; a later leg follows that leg's
    /// real write and must purge explicitly to start clean (the sheet test
    /// and the spoken-answer test each drive two or three legs).
    private func makeFreshCoordinator() -> AppCoordinator {
        purgeCloudChatConsentRecord()
        return makeCoordinator()
    }

    // MARK: Witness helpers

    /// One stored property of `subject`, by label. The `as? T` cast unwraps
    /// one level of `Optional` (the documented toolchain behaviour), which
    /// is what makes the coordinator's private seams readable at all. A
    /// missing label or a mismatched type is an explicit failure, never a
    /// silent nil.
    private func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self,
                           file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject)
            .children.first(where: { $0.label == label }) else {
            XCTFail("no stored property '\(label)' on \(Swift.type(of: subject))",
                    file: file, line: line)
            return nil
        }
        guard let value = child.value as? T else {
            XCTFail("stored property '\(label)' is not a \(T.self) — holds \(Swift.type(of: child.value))",
                    file: file, line: line)
            return nil
        }
        return value
    }

    /// Runs `body` with process stdout redirected to a temp file and returns
    /// what the coordinator's console bus printed (the LiveTranslate/Spotify
    /// pattern). The coordinator's default bus is `ConsoleObservabilityBus`;
    /// the gate's events land here.
    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/cnr177-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    private func eventCount(_ name: String, in console: String) -> Int {
        console.components(separatedBy: name).count - 1
    }

    /// Waits out the main-queue hops (the outcome card's `setOutcome` hop,
    /// the session window's `.idle` transition): the sentinel enqueued LAST
    /// can only run after everything enqueued before it.
    private func drainMainQueue() {
        let done = expectation(description: "main-queue hops drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Builds the coordinator's consent prompt (view state, created on
    /// first surface access) and reads it back through `Mirror`.
    private func consentPrompt(of coordinator: AppCoordinator) -> CloudChatConsentPrompt? {
        _ = coordinator.cloudChatConsentSheetSurface
        return stored("cloudChatConsentPromptStorage", of: coordinator,
                      as: CloudChatConsentPrompt.self)
    }

    /// Presents the question exactly as the routing decision does: through
    /// the prompt's ONE entry point, whose `startSpokenCapture` seam is the
    /// coordinator's own capture arming.
    private func presentTheQuestion(on coordinator: AppCoordinator,
                                    file: StaticString = #filePath, line: UInt = #line)
        -> CloudChatConsentPrompt? {
        // Isolation self-check: the purge in setUp is what makes the store a
        // fresh install, so a polluted record fails HERE, at the cause,
        // instead of surfacing as a downstream order-dependent symptom
        // (wave-close rework, 2026-10-15).
        if let gate = stored("cloudChatConsentGate", of: coordinator,
                             as: CloudChatConsentGate.self) {
            XCTAssertEqual(gate.currentDecision(), .notRecorded,
                           "the suite must start from a clean consent store — setUp purges the record through the same channel",
                           file: file, line: line)
            guard gate.currentDecision() == .notRecorded else { return nil }
        }
        guard let prompt = consentPrompt(of: coordinator) else {
            XCTFail("the coordinator must build its consent prompt on surface access",
                    file: file, line: line)
            return nil
        }
        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {}),
                       .awaitingDecision,
                       "a fresh gate presents the question and never answers the turn off-device",
                       file: file, line: line)
        return prompt
    }

    // MARK: Source pins (the `start()`-scoped wiring's only witness)

    private func coordinatorSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func commandRouterSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func keywordRuleSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/KeywordIntentRule.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func indicatorSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent(
                "ElderlyAssistant/Services/Intents/CloudChat/CloudChatActivityIndicator.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func homeSubviewsSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/HomeSubviews.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    /// The body of one function, from its declaration to the next
    /// same-indent declaration. Nil when the function does not exist — an
    /// explicit failure at every call site, never a silent pass.
    private func functionBody(named name: String, in source: String,
                              file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let start = source.range(of: "func \(name)(") else {
            XCTFail("no function '\(name)' in the scanned source", file: file, line: line)
            return nil
        }
        let tail = source[start.upperBound...]
        if let end = tail.range(of: "\n    private func ") ?? tail.range(of: "\n    func ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }

    // MARK: - 1. The badge window (FR-CNR-008; design-l1 §8.5)

    /// Scenario — "The badge is present for the whole cloud-active window".
    /// The model is the window's whole state: nothing before the attempt
    /// begins, present through it, gone after the close. The count is the
    /// truth so a close can never race an open.
    func testTheBadgeIsOnForTheWholeOpenWindowAndNeverBeforeOrAfter() {
        let model = CloudChatActivityIndicatorModel()
        XCTAssertFalse(model.isActive, "no window is open before any attempt")
        XCTAssertEqual(model.openWindowCountForTesting, 0)

        model.requestBegan()
        XCTAssertTrue(model.isActive, "the window is open from the attempt's begin")
        XCTAssertEqual(model.openWindowCountForTesting, 1)

        model.requestEnded()
        XCTAssertFalse(model.isActive, "the window is closed by its paired end")
        XCTAssertEqual(model.openWindowCountForTesting, 0)
    }

    /// An unpaired close is ignored rather than counted: a count that could
    /// go negative would let a later attempt fail to show the badge, and
    /// silently *not* showing it is the one error this type must not make
    /// (the shipped model's own rule).
    func testAnUnpairedWindowCloseIsIgnoredSoTheNextWindowStillShows() {
        let model = CloudChatActivityIndicatorModel()

        model.requestEnded()
        model.requestEnded()
        XCTAssertEqual(model.openWindowCountForTesting, 0, "unpaired ends never count")

        model.requestBegan()
        XCTAssertTrue(model.isActive, "the first real attempt still shows the badge")
    }

    /// Scenario — "a local turn never shows the badge" is structural: the
    /// model's ONLY input is the attempt calls, and a local turn never
    /// reaches the one open site (pinned below). This test names the
    /// false-negative directly: a model nothing called stays dark.
    func testALocalOnlyTurnLeavesTheBadgeOff() {
        let model = CloudChatActivityIndicatorModel()
        // Nothing a local turn does touches this model — it has no other
        // input. Breathing room for any future accidental coupling: the
        // model must not have moved.
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.openWindowCountForTesting, 0)
    }

    /// Scenario — "reflecting the enabled state in Settings". The surface
    /// is the badge's one truth: shown only in an open window AND only
    /// while cloud chat is in force, so a revoked device shows nothing even
    /// if a window were still open. The label is T-171's copy in the
    /// elder's language.
    func testTheBadgeRendersOnlyInAnOpenWindowOnADeviceWhereCloudChatIsInForce() {
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en")

        let openAndEnabled = CloudChatActivityIndicatorSurface(
            isActive: true, cloudChatEnabled: true, locale: ne)
        XCTAssertTrue(openAndEnabled.isShown, "an open window on an enabled device shows the badge")

        let openButRevoked = CloudChatActivityIndicatorSurface(
            isActive: true, cloudChatEnabled: false, locale: ne)
        XCTAssertFalse(openButRevoked.isShown,
                       "a revoked device shows nothing even with a window open")

        let closedButEnabled = CloudChatActivityIndicatorSurface(
            isActive: false, cloudChatEnabled: true, locale: ne)
        XCTAssertFalse(closedButEnabled.isShown, "no window, no badge")

        let closedAndRevoked = CloudChatActivityIndicatorSurface(
            isActive: false, cloudChatEnabled: false, locale: ne)
        XCTAssertFalse(closedAndRevoked.isShown)

        // The words are the catalogue's, both languages, and the glyph is a
        // system identifier — never user copy.
        XCTAssertEqual(openAndEnabled.label, L10n.str("cloud.chat.indicator", locale: ne))
        XCTAssertEqual(CloudChatActivityIndicatorSurface(
            isActive: false, cloudChatEnabled: false, locale: en).label,
                       L10n.str("cloud.chat.indicator", locale: en))
        XCTAssertEqual(CloudChatActivityIndicatorSurface.symbolName, "cloud")
    }

    /// "No content text, structurally": the label is a catalogue value with
    /// no format slots, so nothing from a turn could ride into it.
    func testTheBadgeLabelCarriesNoFormatSlotsInEitherLanguage() {
        for identifier in ["ne-NP", "en"] {
            let label = L10n.str("cloud.chat.indicator", locale: Locale(identifier: identifier))
            XCTAssertFalse(label.isEmpty, "\(identifier): the badge must say words, not sit silent")
            XCTAssertFalse(label.contains("%"),
                           "\(identifier): the badge copy has no format slots — nothing from the turn can ride in")
        }
    }

    // MARK: - 2. The responder hooks (the window's one feed)

    /// Hook ordering is the contract the coordinator's bookkeeping rests
    /// on: begin before the delegate is asked, settle inside the delegate's
    /// completion BEFORE the caller's completion — so by the time the
    /// router's chat guard reads the served path (T-174) the provenance for
    /// this attempt is already recorded.
    func testTheAttemptHooksRunAroundTheDelegateInTheDeclaredOrder() {
        var order: [String] = []
        let stub = CNR177StubChatResponder()
        stub.completionCommand = chatCommand("यो जवाफ हो")
        let responder = CloudChatIndicatorResponder(
            wrapping: stub,
            onAttemptBegan: { order.append("began") },
            onAttemptSettled: { _ in order.append("settled") })

        responder.respondToChat(transcript: "के छ?", context: chatContext()) { _ in
            order.append("caller")
        }

        XCTAssertEqual(order, ["began", "settled", "caller"],
                       "begin fires before the delegate is asked, settle before the caller sees the reply")
        XCTAssertEqual(stub.askedCount, 1, "the delegate is asked exactly once per attempt")
        XCTAssertEqual(stub.lastTranscript, "के छ?", "the wrapper passes the transcript through unchanged")
    }

    /// The settle hook is what records the served-path provenance: a `.chat`
    /// reply is the cloud's, anything else (an abstention, a failure, a
    /// non-chat shape) is not — and the record is visible to the caller's
    /// own completion, which is the order the guard reads in.
    func testTheSettleHookRecordsProvenanceBeforeTheCallerSeesTheReply() {
        func provenance(for command: InterpretedCommand?) -> (settled: Bool, atCaller: Bool?) {
            var settled = false
            var atCaller: Bool?
            let stub = CNR177StubChatResponder()
            stub.completionCommand = command
            let responder = CloudChatIndicatorResponder(
                wrapping: stub,
                onAttemptBegan: {},
                onAttemptSettled: { settled = ($0?.action == .chat) })
            responder.respondToChat(transcript: "के छ?", context: chatContext()) { _ in
                atCaller = settled
            }
            return (settled, atCaller)
        }

        let chat = provenance(for: chatCommand("यो जवाफ हो"))
        XCTAssertTrue(chat.settled, "a .chat reply was served from the cloud")
        XCTAssertEqual(chat.atCaller, true,
                       "the guard's read happens after the settle — provenance is never a frame late")

        let none = provenance(for: InterpretedCommand(action: .none, entryId: nil, contact: nil,
                                                      time: nil, medication: nil, message: nil,
                                                      callType: nil, requestedApp: nil,
                                                      confidence: 0.9, reply: "foo"))
        XCTAssertFalse(none.settled, "a non-chat shape is not a served reply")

        let abstained = provenance(for: nil)
        XCTAssertFalse(abstained.settled, "an abstention/failure has no provenance")
    }

    /// The wrapper is the ONE responder both cloud doors share, so it must
    /// forward the failure reporting too — a wrapper that swallowed the
    /// class would blind the honest degradation line.
    func testTheWrapperForwardsFailureReporting() {
        let stub = CNR177StubChatResponder()
        stub.failureClass = .notConfigured
        let responder = CloudChatIndicatorResponder(
            wrapping: stub, onAttemptBegan: {}, onAttemptSettled: { _ in })

        XCTAssertEqual(responder.lastCloudFailureClass, .notConfigured)

        responder.clearCloudFailure()
        XCTAssertTrue(stub.clearedFailure, "clear reaches the wrapped interpreter")
        XCTAssertNil(responder.lastCloudFailureClass)
    }

    // MARK: - 3. The Settings row (design-l1 §8.6)

    /// Scenario — "Revocation from the Settings toggle". Both directions
    /// write through the gate's ONE writer: OFF is the revocation, ON is
    /// the explicit re-enable, and the row's read is the gate's current
    /// decision — never a mirrored preference.
    func testTheSettingsToggleWritesThroughTheGatesOneWriter() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.cloudChatEnabled, "a fresh install denies by absence")

        let onConsole = captureConsole { coordinator.setCloudChatEnabledFromSettings(true) }
        XCTAssertTrue(coordinator.cloudChatEnabled, "the grant is in force immediately after the write")
        XCTAssertEqual(eventCount("consent_recorded", in: onConsole), 1,
                       "the grant is evidenced once, by the gate")

        let offConsole = captureConsole { coordinator.setCloudChatEnabledFromSettings(false) }
        XCTAssertFalse(coordinator.cloudChatEnabled, "the revoke is in force immediately")
        XCTAssertEqual(eventCount("consent_revoked", in: offConsole), 1,
                       "the withdrawal is evidenced once, by the gate")

        // The write survives a re-read with nothing in between: there is no
        // cache for a revocation to have to invalidate.
        XCTAssertFalse(coordinator.cloudChatEnabled)
    }

    /// The Settings write is silent and asks nothing: it is not one of the
    /// question's two entry points (`consentNeedDetected` is), and no badge
    /// window is involved.
    func testTheSettingsToggleIsSilentAndAsksNoQuestion() {
        let coordinator = makeCoordinator()
        let outcomeBefore = coordinator.lastOutcome

        _ = captureConsole { coordinator.setCloudChatEnabledFromSettings(true) }
        drainMainQueue()

        XCTAssertFalse(coordinator.cloudChatConsentPromptIsPresented,
                       "Settings is not where the question becomes real")
        let surface = coordinator.cloudChatIndicatorSurface
        XCTAssertTrue(surface.cloudChatEnabled, "the badge's enabled half reflects the grant")
        XCTAssertFalse(surface.isShown, "no attempt, no window — the badge stays off")
        XCTAssertEqual(coordinator.lastOutcome?.id, outcomeBefore?.id,
                       "a Settings write cards nothing")
    }

    // MARK: - 4. The voice controls through the real router and coordinator

    /// Scenario — "Revocation by voice". The deterministic keyword family
    /// resolves the utterance, the router reports it and ends the turn, and
    /// the coordinator performs the withdrawal through the gate's one
    /// writer. End to end: the real `CommandRouter` over the real
    /// `AppCoordinator`.
    func testARevokeUtteranceWithdrawsThroughTheGateAndEndsTheTurn() {
        let coordinator = makeCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let console = captureConsole {
            XCTAssertEqual(router.route(transcript: revokeUtterance),
                           .unrecognised(transcript: revokeUtterance),
                           "the revoke phrase ends the turn — it is never a chat reply")
        }

        XCTAssertFalse(coordinator.cloudChatEnabled,
                       "the next routing read refuses egress — the withdrawal is in force")
        XCTAssertEqual(eventCount("consent_revoked", in: console), 1,
                       "the withdrawal went through the gate's ONE writer")
        XCTAssertTrue(bus.emitted.contains {
            $0.component == "command_router"
                && $0.eventType == "cloud_chat_voice_control"
                && $0.outcome == "revoke"
        }, "the router reports what it matched")

        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("cloud.chat.revoke.done", locale: coordinator.activeLocale),
                       "the elder hears that answers come from this phone now")
    }

    /// Scenario — "no content or identity in any event or log line": the
    /// router's event is classification only (a closed outcome token, no
    /// metadata, no error code, no duration), and no event anywhere carries
    /// the utterance.
    func testTheRevokeTurnEmitsOnlyTheClassificationAndNoContent() {
        let coordinator = makeCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = captureConsole { _ = router.route(transcript: revokeUtterance) }

        let control = bus.emitted.filter { $0.eventType == "cloud_chat_voice_control" }
        XCTAssertEqual(control.count, 1, "one control, one event")
        XCTAssertEqual(control.first?.metadata.isEmpty, true,
                       "the event carries no metadata at all")
        XCTAssertNil(control.first?.errorCode)
        XCTAssertNil(control.first?.durationMs)
        XCTAssertTrue(["revoke", "state_query"].contains(control.first?.outcome ?? ""),
                      "the outcome is a member of the closed vocabulary, nothing else")

        for event in bus.emitted {
            for value in event.metadata.values {
                XCTAssertFalse(value.contains("इन्टरनेटबाट"),
                               "no event may carry the transcript: \(event.eventType)")
            }
        }
    }

    /// Scenario — "the spoken state query answered truthfully from the
    /// gate's decision, in the elder's language", in both states. The query
    /// turn costs no write, and the line follows the gate, not the request.
    func testAStateQueryIsAnsweredTruthfullyFromTheGateInBothStates() {
        let coordinator = makeCoordinator()
        let (router, bus) = makeRouter(coordinator)
        let locale = coordinator.activeLocale

        let offConsole = captureConsole {
            XCTAssertEqual(router.route(transcript: stateQueryUtterance),
                           .unrecognised(transcript: stateQueryUtterance))
        }
        XCTAssertEqual(eventCount("consent_", in: offConsole), 0,
                       "a state query never writes: it is a question, not a decision")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("cloud.chat.state.spoken.off", locale: locale),
                       "not recorded reads as 'answers come from this phone'")

        // The explicit re-enable, then the same question — the ON line.
        coordinator.setCloudChatEnabledFromSettings(true)
        _ = captureConsole { _ = router.route(transcript: stateQueryUtterance) }
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("cloud.chat.state.spoken.on", locale: locale),
                       "the satisfied gate reads as the ON line")

        let outcomes = bus.emitted
            .filter { $0.eventType == "cloud_chat_voice_control" }
            .map(\.outcome)
        XCTAssertEqual(outcomes, ["state_query", "state_query"],
                       "every query is reported, in order")
    }

    /// Scenario — "no cached route survives revocation": the routing
    /// decision re-reads per call, so a withdrawal changes the very next
    /// decision. Driven at the seam with the REAL gate and the REAL
    /// decision, with the same per-call-read closure shape the coordinator
    /// wires — and again through the real coordinator, whose enabled read
    /// flips with no call in between.
    func testNoCachedRouteSurvivesRevocation() {
        let gate = CloudChatConsentGate(storage: LabelTranslationCacheTestStorage(),
                                        observabilityBus: LiveTranslateSanitisingBus())
        let inputs = CloudChatRouting.Inputs(
            consent: { gate.currentDecision() },
            online: { true },
            keyConfigured: { true },
            costAllows: { true })

        XCTAssertEqual(CloudChatRouting.decide(inputs), .local(reason: .consentNotRecorded),
                       "absence is not consent")

        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(CloudChatRouting.decide(inputs), .cloud, "all four inputs yes")

        _ = gate.revoke()
        XCTAssertEqual(CloudChatRouting.decide(inputs), .local(reason: .consentDenied),
                       "the withdrawal owns the very next decision")
        XCTAssertEqual(CloudChatRouting.decide(inputs), .local(reason: .consentDenied),
                       "and the one after — there is no cache to expire")

        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertEqual(CloudChatRouting.decide(inputs), .cloud,
                       "the explicit re-enable restores the route")

        // The coordinator's own read is the gate's current decision: a
        // router-driven revoke is visible on the very next read.
        let coordinator = makeCoordinator()
        let (router, _) = makeRouter(coordinator)
        coordinator.setCloudChatEnabledFromSettings(true)
        XCTAssertTrue(coordinator.cloudChatEnabled)
        _ = captureConsole { _ = router.route(transcript: revokeUtterance) }
        XCTAssertFalse(coordinator.cloudChatEnabled,
                       "revocation takes effect at the next turn — never earlier, never later")
    }

    /// Scenario — "no model, no NLU, no classifier widening": the family is
    /// resolved from the keyword table alone, before any interpreter is
    /// consulted, for both controls.
    func testTheVoiceControlsNeverConsultAnInterpreter() {
        let coordinator = makeCoordinator()
        let recording = CNR177RecordingInterpreter()
        let (router, _) = makeRouter(coordinator, interpreter: recording)

        _ = captureConsole {
            _ = router.route(transcript: revokeUtterance)
            _ = router.route(transcript: stateQueryUtterance)
        }

        XCTAssertTrue(recording.interpreted.isEmpty,
                      "the voice controls answer deterministically — a model is never asked")
    }

    // MARK: - 5. The consent question's spoken answer (the shipped capture)

    /// Scenario — "the answer rides the existing spoken-confirmation
    /// capture, through the gate's one writer". A spoken yes with the
    /// question live writes the grant, closes the question, closes the 45 s
    /// window and speaks the truth read AFTER the write.
    func testASpokenYesThroughTheConfirmationWindowWritesTheGrantAndClosesTheQuestion() {
        let coordinator = makeCoordinator()
        guard presentTheQuestion(on: coordinator) != nil else { return }

        XCTAssertTrue(coordinator.cloudChatConsentPromptIsPresented,
                      "the question is on screen — the elder was never required to touch")
        XCTAssertTrue(coordinator.isAwaitingCloudChatConsentConfirmation,
                      "the spoken capture is armed with the question")
        XCTAssertTrue(coordinator.isAwaitingConfirmation,
                      "the captured window is the shipped confirmation window")
        XCTAssertEqual(coordinator.voiceSession.state, .awaitingConfirmation)

        let console = captureConsole { coordinator.handleConfirmationResponse(.yes) }

        XCTAssertTrue(coordinator.cloudChatEnabled, "the grant landed through the one writer")
        XCTAssertEqual(eventCount("consent_recorded", in: console), 1)
        XCTAssertFalse(coordinator.cloudChatConsentPromptIsPresented,
                       "a question with an answer is not a question")
        XCTAssertFalse(coordinator.isAwaitingCloudChatConsentConfirmation,
                       "the capture resolves with the answer")

        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("cloud.chat.state.spoken.on", locale: coordinator.activeLocale),
                       "the state line is read from the gate AFTER the write")
        XCTAssertEqual(coordinator.voiceSession.state, .idle, "the answer's window closes")
    }

    /// Scenario — "a no is an answer too": the decline closes the question
    /// with a denial in force, speaks the OFF line, and chat keeps working
    /// on-device.
    func testASpokenNoClosesTheQuestionWithADenial() {
        let coordinator = makeCoordinator()
        guard presentTheQuestion(on: coordinator) != nil else { return }

        let console = captureConsole { coordinator.handleConfirmationResponse(.no) }

        XCTAssertFalse(coordinator.cloudChatEnabled,
                       "the decline denies — and nothing re-asks it automatically")
        XCTAssertEqual(eventCount("consent_denied", in: console), 1)
        XCTAssertFalse(coordinator.cloudChatConsentPromptIsPresented)

        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("cloud.chat.state.spoken.off", locale: coordinator.activeLocale))
        XCTAssertEqual(coordinator.voiceSession.state, .idle)
    }

    /// A yes/no that arrives after the question was answered is not an
    /// answer to it: nothing is written, nothing is said (the prompt's
    /// `questionNotLive` contract, surfaced through the coordinator).
    func testARepeatedAnswerAfterTheQuestionClosedWritesNothing() {
        let coordinator = makeCoordinator()
        guard presentTheQuestion(on: coordinator) != nil else { return }
        _ = captureConsole { coordinator.handleConfirmationResponse(.yes) }
        drainMainQueue()
        let outcomeAfterGrant = coordinator.lastOutcome

        let console = captureConsole { coordinator.handleConfirmationResponse(.yes) }
        XCTAssertEqual(eventCount("consent_", in: console), 0,
                       "no second write: the question is gone")
        XCTAssertTrue(coordinator.cloudChatEnabled, "the grant is untouched")
        XCTAssertEqual(coordinator.lastOutcome?.id, outcomeAfterGrant?.id,
                       "no line is spoken for a question that is not live")
    }

    /// The sheet's controls are the same answer path — both write through
    /// the gate's one writer, and a sheet answer with no live question
    /// writes nothing.
    func testTheSheetAnswersWriteThroughTheSameGateWriter() {
        // Allow.
        let allowed = makeCoordinator()
        guard presentTheQuestion(on: allowed) != nil else { return }
        let onConsole = captureConsole { allowed.answerCloudChatConsentFromSheet(.allow) }
        XCTAssertTrue(allowed.cloudChatEnabled)
        XCTAssertEqual(eventCount("consent_recorded", in: onConsole), 1)
        XCTAssertFalse(allowed.cloudChatConsentPromptIsPresented)

        // Not now — a fresh leg install: the allow above is a real record
        // in the process-external store, so this leg purges first.
        let declined = makeFreshCoordinator()
        guard presentTheQuestion(on: declined) != nil else { return }
        let offConsole = captureConsole { declined.answerCloudChatConsentFromSheet(.notNow) }
        XCTAssertFalse(declined.cloudChatEnabled)
        XCTAssertEqual(eventCount("consent_denied", in: offConsole), 1)
        XCTAssertFalse(declined.cloudChatConsentPromptIsPresented)

        // No live question: the tap is not an answer and nothing is written.
        let untouched = makeFreshCoordinator()
        _ = untouched.cloudChatConsentSheetSurface
        let nothing = captureConsole { untouched.answerCloudChatConsentFromSheet(.allow) }
        XCTAssertEqual(eventCount("consent_", in: nothing), 0,
                       "an answer outside the live question is not an answer")
        XCTAssertFalse(untouched.cloudChatEnabled)
    }

    /// Scenario — the widened yes/no path: with the consent capture pended,
    /// a plain yes/no through the real router is consumed by the consent
    /// block — it is never a medication acknowledgement and never the
    /// generic catalog line.
    func testTheConsentAnswerRidesTheExistingYesNoCaptureAndIsNotAMedicationAck() {
        let yes = makeCoordinator()
        guard presentTheQuestion(on: yes) != nil else { return }
        let (yesRouter, yesBus) = makeRouter(yes)

        XCTAssertEqual(yesRouter.route(transcript: "हो"), .unrecognised(transcript: "हो"),
                       "the consent yes ends the turn plainly — never .acknowledgedMedication")
        XCTAssertTrue(yesBus.emitted.contains {
            $0.eventType == "confirmation_yes" && $0.outcome == "success"
        })
        XCTAssertTrue(yes.cloudChatEnabled, "and the yes became a grant")

        // A fresh leg install: the yes above is a real grant in the
        // process-external store, so this leg purges first.
        let no = makeFreshCoordinator()
        guard presentTheQuestion(on: no) != nil else { return }
        let (noRouter, noBus) = makeRouter(no)

        XCTAssertEqual(noRouter.route(transcript: "होइन"), .unrecognised(transcript: "होइन"))
        XCTAssertTrue(noBus.emitted.contains {
            $0.eventType == "confirmation_no" && $0.outcome == "success"
        })
        XCTAssertFalse(no.cloudChatEnabled, "and the no became a denial")
        XCTAssertFalse(no.isAwaitingCloudChatConsentConfirmation)
    }

    // MARK: - 6. The wiring pins (the `start()`-scoped seams)

    /// The window has exactly ONE open site and one close funnel: the
    /// attempt's begin is the only writer of the open flag, the model's
    /// begin/end are each called once, and the speech-end funnel is the
    /// only close the turn's own speech drives. This is what makes "the
    /// badge never shows for a local turn" structural: a local turn never
    /// reaches the attempt's hooks.
    func testTheIndicatorWindowHasExactlyOneOpenSiteAndTheSpeechEndFunnel() {
        let source = coordinatorSource()

        XCTAssertEqual(source.components(separatedBy: "cloudChatIndicatorWindowOpen = true").count - 1, 1,
                       "exactly one site opens the window")
        XCTAssertEqual(source.components(separatedBy: "requestBegan()").count - 1, 1,
                       "the model's begin is called once")
        XCTAssertEqual(source.components(separatedBy: "requestEnded()").count - 1, 1,
                       "the model's end is called once")
        XCTAssertEqual(source.components(separatedBy: "self.cloudChatCloseWindowIfSpeechEnded()").count - 1, 1,
                       "the speech-end funnel is a single call")

        // The open site is the attempt-began, which the responder's begin
        // hook calls — the one feed both cloud doors share.
        let began = functionBody(named: "cloudChatCloudAttemptBegan", in: source) ?? ""
        XCTAssertTrue(began.contains("cloudChatIndicatorWindowOpen = true"),
                      "the attempt's begin is the open site")
        XCTAssertTrue(began.contains("requestBegan()"))
        XCTAssertTrue(source.contains("onAttemptBegan: { [weak self] in self?.cloudChatCloudAttemptBegan() }"),
                      "the hook is wired to the attempt's begin")

        // The close funnel only closes a SETTLED, silent window: the badge
        // belongs to the window that ends with the reply's utterance.
        let funnel = functionBody(named: "cloudChatCloseWindowIfSpeechEnded", in: source) ?? ""
        XCTAssertTrue(funnel.contains("guard cloudChatIndicatorWindowOpen, cloudChatAttemptSettled"),
                      "an unsettled window is not closed by a notice's speech end")
        XCTAssertTrue(funnel.contains("speakingCount == 0"))

        // The provenance is recorded synchronously from the settled command
        // — the guard's read can never be a frame late.
        let settled = functionBody(named: "cloudChatCloudAttemptSettled", in: source) ?? ""
        XCTAssertTrue(settled.contains("cloudChatReplyServedFromCloud = (command?.action == .chat)"),
                      "provenance is the settled command's own shape")
        XCTAssertTrue(source.contains("cloudChatReplyServedFromCloud ? .cloud : .onDevice"),
                      "the guard's servingPath reads that provenance")
    }

    /// The lane and guard seams are filled per turn and nothing is cached:
    /// the consent closure is a call that reads the gate, the guard asks
    /// the identical decision, and both the lane's cloud leg and the
    /// guard's escalation share the ONE wrapped responder.
    func testTheLaneAndGuardSeamsAreFilledPerTurnAndNothingIsCached() {
        let source = coordinatorSource()

        XCTAssertTrue(source.contains("router3.cloudChatLane.routingInputs = CloudChatRouting.Inputs("))
        XCTAssertTrue(source.contains("consent: { [weak self] in self?.cloudChatConsentInput() },"),
                      "the consent input is a per-call read, not a stored decision")

        let consentInput = functionBody(named: "cloudChatConsentInput", in: source) ?? ""
        XCTAssertTrue(consentInput.contains("let decision = cloudChatConsentGate.currentDecision()"),
                      "the gate is read on every call")
        XCTAssertTrue(consentInput.contains("if decision == .notRecorded"),
                      "the question's ONE precise trigger is the not-recorded chat turn")
        XCTAssertTrue(consentInput.contains("cloudChatConsentPrompt().consentNeedDetected("),
                      "and it goes through the prompt's one entry point")

        XCTAssertTrue(source.contains("chatGuard: ChatGuardSeam("),
                      "the guard seam is filled at construction")
        XCTAssertTrue(source.contains("servingPath: { [weak self] in self?.cloudChatServingPath() ?? .onDevice },"),
                      "the served path is the provenance read — never a cached claim")
        XCTAssertTrue(source.contains("cloudAllowed: { [weak self] in self?.cloudChatGuardAllowsCloud() ?? false },"))
        XCTAssertTrue(source.contains("respondToChat: { [weak self] transcript, completion in"))

        let allows = functionBody(named: "cloudChatGuardAllowsCloud", in: source) ?? ""
        XCTAssertTrue(allows.contains("return CloudChatRouting.decide(inputs) == .cloud"),
                      "the escalation door asks the identical question the lane asked")

        XCTAssertTrue(source.contains("let cloudChatResponder = CloudChatIndicatorResponder("),
                      "one wrapped responder")
        XCTAssertTrue(source.contains("router3.cloudChatLane.cloudResponder = cloudChatResponder"),
                      "the lane's cloud leg uses it")
        XCTAssertTrue(source.contains("if let responder = cloudChatCloudResponder") ||
                      source.contains("guard let responder = cloudChatCloudResponder"),
                      "the guard's escalation uses the same instance")
    }

    /// The notice: one short line, once per session, at the attempt's begin
    /// — it rides the wait and can never replace or delay the reply, which
    /// is committed later on the router's own lane.
    func testTheNoticeIsOncePerSessionAndRidesTheAttemptBegin() {
        let source = coordinatorSource()

        XCTAssertEqual(source.components(separatedBy: "cloudChatSpeakNoticeOnce()").count - 1, 2,
                       "the notice is declared once and called from exactly one site")

        let notice = functionBody(named: "cloudChatSpeakNoticeOnce", in: source) ?? ""
        XCTAssertTrue(notice.contains("guard !cloudChatNoticeSpoken, speaker != nil else { return }"),
                      "once per session, and only when there is someone to hear it")
        XCTAssertTrue(notice.contains("speak(key: \"cloud.chat.indicatorSpoken\")"),
                      "the words are T-171's catalogue key — the elder's language, no content")

        let began = functionBody(named: "cloudChatCloudAttemptBegan", in: source) ?? ""
        XCTAssertTrue(began.contains("cloudChatSpeakNoticeOnce()"),
                      "the notice rides the attempt's begin — committed before the network call is awaited")
    }

    /// The coordinator owns every withdrawal through the gate's ONE writer;
    /// the router only reports what its keyword family matched, and the
    /// confirmation block yields to a simultaneous dose challenge.
    func testTheCoordinatorOwnsTheWriterAndTheRouterOnlyReports() {
        let wiringSource = coordinatorSource()
        XCTAssertTrue(wiringSource.contains("_ = cloudChatConsentGate.record(granted: true)"),
                      "the Settings ON is the explicit re-enable, through one writer")
        XCTAssertEqual(wiringSource.components(separatedBy: "cloudChatConsentGate.revoke()").count - 1, 2,
                       "the Settings OFF and the voice revoke are the two withdrawal call sites")
        XCTAssertTrue(wiringSource.contains("if pendingCloudChatConsentCapture, pendingConfirmationEntryId == nil {"),
                      "the consent answer yields to a simultaneous dose challenge")
        XCTAssertTrue(wiringSource.contains("startSpokenCapture: { [weak self] in") ||
                      wiringSource.contains("self?.beginCloudChatConsentCapture()"),
                      "the spoken capture is the coordinator's own arming — reachable without touch")

        let routerSource = commandRouterSource()
        XCTAssertTrue(routerSource.contains("if let request = KeywordIntentRule.cloudChatVoiceRequest(transcript: preText) {"))
        XCTAssertTrue(routerSource.contains("emitCloudChatVoiceControl(request)"))
        XCTAssertTrue(routerSource.contains("coordinator?.handleCloudChatVoiceRequest(request)"),
                      "the coordinator owns every consequence")
        XCTAssertTrue(routerSource.contains("var isAwaitingCloudChatConsentConfirmation: Bool { false }"),
                      "the extension default keeps every pre-existing conformer inert")
        XCTAssertTrue(routerSource.contains("if isCloudChatConsentConfirmation { return .unrecognised(transcript: raw) }"))

        let emit = functionBody(named: "emitCloudChatVoiceControl", in: routerSource) ?? ""
        XCTAssertTrue(emit.contains("\"cloud_chat_voice_control\""))
        XCTAssertTrue(emit.contains("metadata: [:]"),
                      "the event carries no metadata at all — classification only")

        let ruleSource = keywordRuleSource()
        XCTAssertTrue(ruleSource.contains(
            "static func cloudChatVoiceRequest(transcript raw: String) -> CloudChatVoiceRequest?"),
            "the resolver takes the transcript and nothing else — no dynamic vocabulary")
    }

    /// The surfaces' mount and the indicator file's hygiene: the host is
    /// mounted exactly once in the status slot, the sheet's `isPresented`
    /// binding ignores writes (the question closes only when the gate has
    /// a decision), the badge glyph and identifier are the file's, and the
    /// file emits no event, logs nothing, and imports no new framework.
    func testTheSurfaceHostIsMountedAndTheIndicatorFileStaysClean() {
        let home = homeSubviewsSource()
        XCTAssertEqual(home.components(separatedBy: "CloudChatSurfacesHost()").count - 1, 1,
                       "the surfaces host is mounted once, in the status slot")

        let indicator = indicatorSource()
        XCTAssertTrue(indicator.contains("isShown: Bool { isActive && cloudChatEnabled }"),
                      "the badge is one truth the view and the tests read")
        XCTAssertTrue(indicator.contains("set: { _ in }"),
                      "the view never closes the question — the gate's decision does")
        XCTAssertTrue(indicator.contains("cloudchat.indicator"),
                      "the badge carries its stable identifier")

        // No event, no log line, no new permission surface.
        XCTAssertFalse(indicator.contains("emit("))
        XCTAssertFalse(indicator.contains("print("))
        XCTAssertFalse(indicator.contains("NSLog"))
        XCTAssertFalse(indicator.contains("Info.plist"))

        let imports = indicator
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("import ") }
            .map { $0.replacingOccurrences(of: "import ", with: "") }
        XCTAssertEqual(Set(imports), ["Foundation", "SwiftUI"],
                       "the indicator adds no framework and no permission")
    }
}
