import XCTest
@testable import ElderlyAssistant

/// [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier: the persisted
/// threshold, the pure policy, the provider seam, the routing path, the
/// spoken hold cue, the two logs it leaves, and the safety net it can
/// never get in front of.
///
/// Written, not run (the task's verification bar is a full simulator
/// COMPILE — the merge stack before this one shipped parse-only breakage,
/// so compile-green is the gate; no test runs, hold).
final class CloudCascadeSettingsTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cloudCascade.tests.\(UUID().uuidString)") ?? .standard
    }

    func testThresholdDefaultsTo97PercentWhenNeverWritten() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(CloudCascadeSettings.threshold(defaults: defaults), 0.97)
        XCTAssertEqual(CloudCascadeSettings.percent(CloudCascadeSettings.threshold(defaults: defaults)), 97)
    }

    func testThresholdIsClampedOnRead() {
        let defaults = isolatedDefaults()
        CloudCascadeSettings.setThreshold(0.10, defaults: defaults)
        XCTAssertEqual(CloudCascadeSettings.threshold(defaults: defaults),
                       CloudCascadeSettings.minimumThreshold,
                       "a hand-edited plist below the floor clamps up, never escalates everything")
        CloudCascadeSettings.setThreshold(5.0, defaults: defaults)
        XCTAssertEqual(CloudCascadeSettings.threshold(defaults: defaults),
                       CloudCascadeSettings.maximumThreshold,
                       "an out-of-range value clamps to 1.00, the honest top of the range")
    }

    func testThresholdIsClampedOnWrite() {
        let defaults = isolatedDefaults()
        CloudCascadeSettings.setThreshold(0.001, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: CloudCascadeSettings.thresholdKey),
                       CloudCascadeSettings.minimumThreshold,
                       "the write path clamps, so the stored value is always in range")
    }

    func testPercentRoundTripAndStepping() {
        XCTAssertEqual(CloudCascadeSettings.threshold(percent: 97), 0.97)
        XCTAssertEqual(CloudCascadeSettings.percent(0.97), 97)
        XCTAssertEqual(CloudCascadeSettings.stepped(0.97, bySteps: 1), 0.98)
        XCTAssertEqual(CloudCascadeSettings.stepped(0.97, bySteps: -1), 0.96)
        XCTAssertEqual(CloudCascadeSettings.stepped(CloudCascadeSettings.maximumThreshold, bySteps: 1),
                       CloudCascadeSettings.maximumThreshold,
                       "stepping saturates at the top instead of running past it")
        XCTAssertEqual(CloudCascadeSettings.stepped(CloudCascadeSettings.minimumThreshold, bySteps: -1),
                       CloudCascadeSettings.minimumThreshold)
    }

    func testSwitchDefaultsOnAndPersists() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(CloudCascadeSettings.isEnabled(defaults: defaults),
                      "the tier's rule is the requested behaviour; the switch is a tester's override")
        CloudCascadeSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CloudCascadeSettings.isEnabled(defaults: defaults))
        CloudCascadeSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CloudCascadeSettings.isEnabled(defaults: defaults))
    }
}

// MARK: - The pure rule

final class CloudCascadePolicyTests: XCTestCase {

    private let threshold = 0.97

    func testBelowThresholdEscalates() {
        XCTAssertTrue(CloudCascadePolicy.escalates(localConfidence: 0.96,
                                                   threshold: threshold,
                                                   isEnabled: true,
                                                   isCloudReady: true))
    }

    func testAboveThresholdStaysLocal() {
        XCTAssertFalse(CloudCascadePolicy.escalates(localConfidence: 0.98,
                                                    threshold: threshold,
                                                    isEnabled: true,
                                                    isCloudReady: true))
    }

    func testEqualityStaysLocal() {
        XCTAssertFalse(CloudCascadePolicy.escalates(localConfidence: 0.97,
                                                    threshold: threshold,
                                                    isEnabled: true,
                                                    isCloudReady: true),
                       "97 % is good enough at a 97 % threshold — a strict <, not <=")
    }

    func testUnconfiguredProviderIsInertBelowTheThreshold() {
        XCTAssertFalse(CloudCascadePolicy.escalates(localConfidence: 0.10,
                                                    threshold: threshold,
                                                    isEnabled: true,
                                                    isCloudReady: false),
                       "no provider ready → the tier is silent, whatever the confidence")
    }

    func testSwitchOffIsInertEvenBelowTheThreshold() {
        XCTAssertFalse(CloudCascadePolicy.escalates(localConfidence: 0.10,
                                                    threshold: threshold,
                                                    isEnabled: false,
                                                    isCloudReady: true))
    }

    func testConfigurationDelegatesToThePolicyWithItsOwnInputs() {
        let ready = CloudBrainEndpoint(provider: .gemini,
                                       interpreterName: "gemini",
                                       interpreter: StubCommandInterpreter(),
                                       isConfigured: { true },
                                       costAllows: { true })
        let unready = CloudBrainEndpoint(provider: .gemini,
                                         interpreterName: "gemini",
                                         interpreter: StubCommandInterpreter(),
                                         isConfigured: { false },
                                         costAllows: { true })
        let armed = CloudCascadeConfiguration(endpoint: ready, threshold: 0.97, isEnabled: true)
        let inert = CloudCascadeConfiguration(endpoint: unready, threshold: 0.97, isEnabled: true)
        let off = CloudCascadeConfiguration(endpoint: ready, threshold: 0.97, isEnabled: false)

        XCTAssertTrue(armed.escalates(localConfidence: 0.5))
        XCTAssertFalse(inert.escalates(localConfidence: 0.5))
        XCTAssertFalse(off.escalates(localConfidence: 0.5))
    }
}

// MARK: - The provider seam

final class CloudBrainProvidersTests: XCTestCase {

    func testNoRegistrationResolvesToNil() {
        let providers = CloudBrainProviders()
        XCTAssertNil(providers.endpoint(for: .gemini),
                     "a provider this build cannot reach is nil — which the tier reads as 'no tier'")
    }

    func testRegistrationResolvesTheProviderEndpoint() {
        let interpreter = StubCommandInterpreter()
        let providers = CloudBrainProviders(gemini: CloudBrainRegistration(
            interpreter: interpreter,
            isConfigured: { true },
            costAllows: { true }))

        let endpoint = providers.endpoint(for: .gemini)
        XCTAssertNotNil(endpoint)
        XCTAssertEqual(endpoint?.provider, .gemini)
        XCTAssertEqual(endpoint?.interpreterName, "gemini")
        XCTAssertEqual(endpoint?.interpreterName, CloudProvider.gemini.interpreterName)
        XCTAssertTrue(endpoint?.interpreter === interpreter,
                      "the endpoint routes to the interpreter the composition root registered")
    }

    func testEndpointIsReadyOnlyWithInterpreterKeyAndBudget() {
        let available = StubCommandInterpreter(available: true)
        let unavailable = StubCommandInterpreter(available: false)

        func endpoint(interpreter: CommandInterpreter,
                      configured: Bool,
                      costAllows: Bool) -> CloudBrainEndpoint {
            CloudBrainEndpoint(provider: .gemini,
                               interpreterName: "gemini",
                               interpreter: interpreter,
                               isConfigured: { configured },
                               costAllows: { costAllows })
        }

        XCTAssertTrue(endpoint(interpreter: available, configured: true, costAllows: true).isReady)
        XCTAssertFalse(endpoint(interpreter: available, configured: false, costAllows: true).isReady,
                       "no key → never ready, which is what keeps an unconfigured household inert")
        XCTAssertFalse(endpoint(interpreter: available, configured: true, costAllows: false).isReady,
                       "a spent budget → not ready (the same gate every Gemini call passes)")
        XCTAssertFalse(endpoint(interpreter: unavailable, configured: true, costAllows: true).isReady)
    }
}

// MARK: - The routing path

final class CloudCascadeRoutingTests: XCTestCase {

    /// Shared, reference-typed recorder — held by the harness and by the
    /// closures the router runs, so a closure can record without capturing
    /// the harness itself (which is illegal while it is still being
    /// initialised).
    private final class Recorder {
        /// Turn-ordered marks: "cue", then "cloud" (the cloud brain's
        /// `interpret`), which is the order the contract requires.
        var order: [String] = []
        var escalations: [CloudCascadeEscalation] = []
        var cueCount: Int { order.filter { $0 == "cue" }.count }
    }

    /// One armed router plus every recorder the tier's behaviour is
    /// asserted on: the cue's order in the turn, the trail, and the two
    /// interpreters.
    private final class Harness {
        let router: IntentRouter
        let bus: RecordingObservabilityBus
        let local: StubCommandInterpreter
        let cloud: OrderRecordingInterpreter
        let recorder: Recorder

        var order: [String] { recorder.order }
        var escalations: [CloudCascadeEscalation] { recorder.escalations }
        var cueCount: Int { recorder.cueCount }

        init(localResult: InterpretedCommand?,
             cloudResult: InterpretedCommand?,
             threshold: Double = 0.97,
             isEnabled: Bool = true,
             isConfigured: Bool = true,
             costAllows: Bool = true,
             interpreterAvailable: Bool = true) {
            // Locals only until every stored property is set — the
            // closures below capture `recorder`, never `self`.
            let recorder = Recorder()
            let bus = RecordingObservabilityBus()
            let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                      observabilityBus: bus)
            let local = StubCommandInterpreter(available: true, result: localResult)
            let cloud = OrderRecordingInterpreter(result: cloudResult,
                                                  available: interpreterAvailable) {
                recorder.order.append("cloud")
            }
            self.recorder = recorder
            self.bus = bus
            self.router = router
            self.local = local
            self.cloud = cloud

            router.localBrain = local
            router.cloudBrain = cloud
            router.cloudEnabled = true

            let endpoint = CloudBrainEndpoint(provider: .gemini,
                                              interpreterName: "gemini",
                                              interpreter: cloud,
                                              isConfigured: { isConfigured },
                                              costAllows: { costAllows })
            router.cloudCascade = CloudCascadeConfiguration(
                endpoint: endpoint,
                threshold: threshold,
                isEnabled: isEnabled,
                holdCue: { recorder.order.append("cue") },
                onEscalated: { escalation in
                    recorder.escalations.append(escalation)
                })
        }

        /// Drives one turn to completion. Uses `XCTWaiter` directly rather
        /// than the `XCTestCase` helpers: this type is nested inside the
        /// test case, so `expectation(description:)` would resolve to the
        /// OUTER case's instance member and not compile.
        func interpret(_ transcript: String) -> InterpretedCommand? {
            let exp = XCTestExpectation(description: "interpret")
            var out: InterpretedCommand?
            router.interpret(transcript: transcript,
                             context: InterpreterContext(pendingMedications: [],
                                                         userLanguageHint: "ne")) { result in
                out = result
                exp.fulfill()
            }
            _ = XCTWaiter().wait(for: [exp], timeout: 2)
            return out
        }

        var cascadeEvents: [ObservabilityEvent] {
            bus.events(named: "cloud_cascade_escalated")
        }
    }

    /// A cloud stub that marks the TURN ORDER when the router asks it to
    /// interpret — the only way to pin "the cue is committed before the
    /// cloud call", since the cue's own playback is asynchronous.
    private final class OrderRecordingInterpreter: CommandInterpreter {
        private let result: InterpretedCommand?
        private let available: Bool
        private let onInterpret: () -> Void
        private(set) var callCount = 0

        init(result: InterpretedCommand?, available: Bool,
             onInterpret: @escaping () -> Void) {
            self.result = result
            self.available = available
            self.onInterpret = onInterpret
        }

        var isAvailable: Bool { available }

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            callCount += 1
            onInterpret()
            DispatchQueue.main.async { completion(self.result) }
        }
    }

    private let localCommand = makeCommand(action: .query, confidence: 0.72,
                                           reply: "हुन्छ")
    private let cloudCommand = makeCommand(action: .query, confidence: 0.95,
                                           reply: "क्लाउडको जवाफ")

    func testSubThresholdLocalAnswerEscalatesToTheCloudBrain() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.local.callCount, 1, "the local brain still answers first")
        XCTAssertEqual(harness.cloud.callCount, 1, "0.72 < 0.97 → the online brain takes the turn")
        XCTAssertEqual(result, cloudCommand, "the cloud's answer is the turn's answer")
    }

    func testHoldCueRunsExactlyOnceBeforeTheCloudCall() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand)
        _ = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.order, ["cue", "cloud"],
                       "the cue is spoken ONCE, BEFORE the cloud call — never after, never twice")
    }

    func testLocalAnswerAtTheThresholdNeverReachesTheCloud() {
        let atThreshold = makeCommand(action: .query, confidence: 0.97)
        let harness = Harness(localResult: atThreshold, cloudResult: cloudCommand)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0, "equality stays local")
        XCTAssertEqual(harness.cueCount, 0, "no cue without an escalation")
        XCTAssertTrue(harness.escalations.isEmpty)
        XCTAssertTrue(harness.cascadeEvents.isEmpty)
        XCTAssertEqual(result, atThreshold)
    }

    func testLocalAnswerAboveTheThresholdNeverReachesTheCloud() {
        let confident = makeCommand(action: .query, confidence: 0.99)
        let harness = Harness(localResult: confident, cloudResult: cloudCommand)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0)
        XCTAssertEqual(harness.cueCount, 0)
        XCTAssertEqual(result, confident)
    }

    func testSwitchOffLeavesTheLocalAnswerStanding() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand,
                              isEnabled: false)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0)
        XCTAssertEqual(harness.cueCount, 0)
        XCTAssertEqual(result, localCommand, "the sub-threshold local answer stands — accepted at 0.72")
    }

    func testUnconfiguredProviderIsSilentAndInert() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand,
                              isConfigured: false)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0, "an unconfigured household never reaches the cloud")
        XCTAssertEqual(harness.cueCount, 0, "no cue — the user must not be told about a wait that never happens")
        XCTAssertTrue(harness.escalations.isEmpty, "no activity row, no app log line")
        XCTAssertTrue(harness.cascadeEvents.isEmpty, "no observability event")
        XCTAssertEqual(result, localCommand)
    }

    func testSpentBudgetIsSilentAndInert() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand,
                              costAllows: false)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0)
        XCTAssertEqual(harness.cueCount, 0)
        XCTAssertEqual(result, localCommand)
    }

    func testUnavailableCloudBrainIsInert() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand,
                              interpreterAvailable: false)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 0)
        XCTAssertEqual(harness.cueCount, 0)
        XCTAssertEqual(result, localCommand)
    }

    func testEscalationTrailCarriesTheNumbersAndNoContent() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand)
        _ = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.escalations.count, 1,
                       "one escalation record per escalated turn")
        let escalation = harness.escalations.first
        XCTAssertEqual(escalation?.provider, "gemini")
        XCTAssertEqual(escalation?.threshold, 0.97)
        XCTAssertEqual(escalation?.localConfidence, 0.72)
    }

    func testEscalationEventShape() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand)
        _ = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cascadeEvents.count, 1)
        let event = harness.cascadeEvents.first
        XCTAssertEqual(event?.component, "voice_routing")
        XCTAssertEqual(event?.eventType, "cloud_cascade_escalated")
        XCTAssertEqual(event?.outcome, "escalated")
        XCTAssertEqual(event?.metadata["provider"], "gemini")
        XCTAssertEqual(event?.metadata["threshold"], "0.97")
        XCTAssertEqual(event?.metadata["confidence"], "0.72")

        // C9 policy: no transcript, no reply, no key anywhere in the event.
        let rendered = (event?.metadata.values.joined(separator: " ") ?? "")
            + " " + (event?.errorCode ?? "")
        XCTAssertFalse(rendered.contains("भोलि"),
                       "no transcript content in the cascade event")
        XCTAssertFalse(rendered.contains("हुन्छ"),
                       "no local reply content in the cascade event")
        XCTAssertFalse(rendered.contains(cloudCommand.reply),
                       "no cloud reply content in the cascade event")
    }

    /// The event's three metadata keys must survive the bus's sanitiser —
    /// an allow-list that drops them would make the whole observability
    /// half of this feature invisible in the field.
    func testCascadeMetadataSurvivesTheLogSanitiser() {
        let harness = Harness(localResult: localCommand, cloudResult: cloudCommand)
        _ = harness.interpret("भोलि के गर्ने")

        guard let event = harness.cascadeEvents.first else {
            return XCTFail("no cascade event emitted")
        }
        let clean = LogSanitiser().sanitise(event)
        XCTAssertEqual(clean.metadata["provider"], "gemini")
        XCTAssertEqual(clean.metadata["threshold"], "0.97")
        XCTAssertEqual(clean.metadata["confidence"], "0.72")
    }

    func testCloudReturningNothingLeavesTheLocalAnswerStanding() {
        let harness = Harness(localResult: localCommand, cloudResult: nil)
        let result = harness.interpret("भोलि के गर्ने")

        XCTAssertEqual(harness.cloud.callCount, 1, "the turn was escalated")
        XCTAssertEqual(harness.cueCount, 1, "and the user was told about the wait")
        XCTAssertEqual(result, localCommand,
                       "a cloud that returns nothing never makes the turn WORSE than it was without the tier")
    }

    func testNoTierWiredLeavesTheLadderByteIdentical() {
        let cache = IntentCommandCache(storage: StubEncryptedStorage())
        let router = IntentRouter(cache: cache, observabilityBus: NullObservabilityBus())
        let local = StubCommandInterpreter(result: makeCommand(action: .query,
                                                              confidence: 0.72))
        router.localBrain = local
        router.cloudBrain = StubCommandInterpreter(result: makeCommand(action: .query,
                                                                       confidence: 0.95))
        router.cloudEnabled = true
        XCTAssertNil(router.cloudCascade, "no tier is the default")

        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        router.interpret(transcript: "भोलि के गर्ने",
                         context: InterpreterContext(pendingMedications: [],
                                                     userLanguageHint: "ne")) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(out?.confidence, 0.72, "the local answer stands at 0.72 ≥ 0.7")
        XCTAssertEqual(out?.reply, "ठीक छ", "and it is the local answer, untouched")
    }
}

// MARK: - The spoken hold cue

final class CloudCascadeHoldCueTests: XCTestCase {

    private final class RecordingSpeaker: Speaker {
        func speak(_ text: String, locale: Locale) async {}
        func cancel() {}
    }

    private func makeRouter(_ coordinator: StubCoordinator,
                            _ bus: RecordingObservabilityBus) -> CommandRouter {
        CommandRouter(coordinator: coordinator,
                      observabilityBus: bus,
                      speaker: RecordingSpeaker(),
                      interpreter: StubCommandInterpreter())
    }

    func testEnglishCueIsTheAuthoredLine() {
        XCTAssertEqual(L10n.str("cloudCascade.holdCue", locale: Locale(identifier: "en")),
                       "One moment — this is taking a little longer…")
    }

    func testNepaliCueIsTheAuthoredLine() {
        XCTAssertEqual(L10n.str("cloudCascade.holdCue", locale: Locale(identifier: "ne")),
                       "एक छिन — अलि बढी समय लाग्दैछ…")
    }

    func testCueIsSpokenOnceAndAnnounced() {
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let router = makeRouter(coordinator, bus)

        router.speakCloudCascadeHoldCue(locale: Locale(identifier: "en"))

        XCTAssertEqual(coordinator.assistantSpokeTexts,
                       ["One moment — this is taking a little longer…"],
                       "the cue reaches the reply lane ONCE, with the localized line")
        XCTAssertEqual(bus.events(named: "cloud_cascade_hold_cue").count, 1)
        XCTAssertEqual(bus.events(named: "cloud_cascade_hold_cue").first?.outcome, "spoken")
    }

    func testCueSpeaksTheActiveLocaleWhenNoneIsGiven() {
        let coordinator = StubCoordinator()
        coordinator.activeLocale = Locale(identifier: "ne")
        let router = makeRouter(coordinator, RecordingObservabilityBus())

        router.speakCloudCascadeHoldCue()

        XCTAssertEqual(coordinator.assistantSpokeTexts,
                       ["एक छिन — अलि बढी समय लाग्दैछ…"],
                       "the cue follows the app language, like every other spoken line")
    }
}

// MARK: - The activity log row

final class CloudCascadeActivityLogTests: XCTestCase {

    private func escalatedEntry(at timestamp: Date = Date()) -> AppActivityEntry {
        AppActivityEntry(timestamp: timestamp,
                         kind: .cloudEscalation,
                         channel: .cloud,
                         contactName: "",
                         phone: "")
    }

    func testEscalationRowCarriesNeitherContactNorContent() {
        let entry = escalatedEntry()
        XCTAssertTrue(entry.contactName.isEmpty)
        XCTAssertTrue(entry.phone.isEmpty)
        XCTAssertNil(entry.messengerHandle)
        XCTAssertNil(entry.body, "a cascade row never stores what was said")
    }

    func testEscalationRowRoundTripsThroughTheStore() {
        let log = AppActivityLog(storage: StubEncryptedStorage())
        log.append(escalatedEntry())
        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .cloudEscalation)
        XCTAssertEqual(entries.first?.channel, .cloud)
    }

    func testCloudRowReadsAsSentToTheOnlineBrain() {
        let entry = escalatedEntry()
        for locale in [Locale(identifier: "en"), Locale(identifier: "ne")] {
            let name = ActivityRowText.name(for: entry, locale: locale)
            XCTAssertEqual(name, L10n.str("history.cloudEscalation", locale: locale))
            XCTAssertFalse(name.isEmpty, "the row's name line is never blank")

            let caption = ActivityRowText.caption(for: entry,
                                                  now: entry.timestamp,
                                                  locale: locale)
            XCTAssertTrue(caption.hasPrefix(L10n.str("history.channel.cloud", locale: locale)),
                          "the caption is labelled from the CHANNEL, not from a call/message kind")
            XCTAssertFalse(caption.contains(L10n.str("history.channel.message", locale: locale)),
                           "a cloud row must never read as a message row")
        }
    }

    func testCloudRowIsNeverAMissedCall() {
        let log = AppActivityLog(storage: StubEncryptedStorage())
        log.append(escalatedEntry())
        XCTAssertNil(log.lastMissedCall(),
                     "the Home missed-call tile only ever reads Channel.unanswered rows")
    }
}

// MARK: - Safety-net precedence

/// The deterministic keyword safety net runs BEFORE any brain (the
/// 2026-09-05 reorder) and the cloud tier sits AFTER every brain — so a
/// safety-critical utterance can never reach the cascade, and the cascade
/// can never be the thing that swallows it.
final class CloudCascadeSafetyNetTests: XCTestCase {

    private final class CountingCue {
        private(set) var count = 0
        func fire() { count += 1 }
    }

    /// Silent speaker — the cue's own playback is asynchronous and not
    /// what these tests assert; its presence is what lets the router's
    /// `speak` path run (and so record through `noteAssistantSpoke`).
    private final class SilentSpeaker: Speaker {
        func speak(_ text: String, locale: Locale) async {}
        func cancel() {}
    }

    private func makeRouter(localResult: InterpretedCommand?)
    -> (CommandRouter, StubCoordinator, RecordingObservabilityBus,
        IntentRouter, StubCommandInterpreter, CountingCue) {
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let intentRouter = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                        observabilityBus: bus)
        let local = StubCommandInterpreter(result: localResult)
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.95))
        intentRouter.localBrain = local
        intentRouter.cloudBrain = cloud
        intentRouter.cloudEnabled = true

        let cue = CountingCue()
        let endpoint = CloudBrainEndpoint(provider: .gemini,
                                          interpreterName: "gemini",
                                          interpreter: cloud,
                                          isConfigured: { true },
                                          costAllows: { true })
        intentRouter.cloudCascade = CloudCascadeConfiguration(
            endpoint: endpoint,
            threshold: 0.97,
            isEnabled: true,
            holdCue: { cue.fire() },
            onEscalated: { _ in })

        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: SilentSpeaker(),
                                   interpreter: intentRouter)
        return (router, coordinator, bus, intentRouter, cloud, cue)
    }

    func testEmergencyKeywordNeverReachesTheCascade() {
        let (router, _, bus, _, cloud, cue) =
            makeRouter(localResult: makeCommand(action: .query, confidence: 0.5))

        let result = router.route(transcript: "मद्दत गर्नुहोस्")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertEqual(cloud.callCount, 0,
                       "the tier only ever sees what already passed the safety net")
        XCTAssertEqual(cue.count, 0, "no hold cue for an emergency")
        XCTAssertFalse(bus.contains("cloud_cascade_escalated"))
    }

    func testExplicitMedAckNeverReachesTheCascade() {
        let (router, coordinator, bus, _, cloud, cue) =
            makeRouter(localResult: makeCommand(action: .ackMed, confidence: 0.5))
        coordinator.pendingEntryId = UUID()

        let result = router.route(transcript: "औषधि खाएँ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertEqual(cue.count, 0)
        XCTAssertFalse(bus.contains("cloud_cascade_escalated"))
    }

    /// The positive control for the two tests above: the SAME armed router
    /// does reach the cascade on an utterance the safety net does not own —
    /// so "0 cloud calls" above is precedence, not a dead arming.
    func testNonSafetyUtteranceDoesReachTheCascade() {
        let (router, _, bus, _, cloud, cue) =
            makeRouter(localResult: makeCommand(action: .query, confidence: 0.72))

        _ = router.route(transcript: "केही राम्रो कथा सुनाउनुस्")

        let exp = expectation(description: "cascade fired")
        DispatchQueue.main.async {
            if cloud.callCount == 1 { exp.fulfill() }
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(cloud.callCount, 1, "the armed tier IS reachable on a non-safety turn")
        XCTAssertEqual(cue.count, 1, "and its hold cue ran once")
        XCTAssertTrue(bus.contains("cloud_cascade_escalated"))
    }
}
