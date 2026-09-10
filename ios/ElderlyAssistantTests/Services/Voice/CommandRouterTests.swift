import XCTest
import SwiftUI
@testable import ElderlyAssistant

final class CommandRouterTests: XCTestCase {

    func testNepaliMedicationAcknowledgementRoutesToOldestPendingReminder() {
        let coordinator = MockVoiceCommandCoordinator()
        let reminderId = UUID()
        coordinator.pendingReminderId = reminderId
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: MockObservabilityBus(),
            speaker: MockSpeaker()
        )

        let result = router.route(transcript: "मैले औषधि खाएँ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.confirmationChallengeEntryIds, [reminderId])
        XCTAssertTrue(coordinator.acknowledgedEntryIds.isEmpty)
        XCTAssertEqual(coordinator.recordedTranscripts, ["मैले औषधि खाएँ"])
    }

    // MARK: - Emergency (deterministic keyword net — see CommandRouter.emergencyPhrases)

    /// Regression for a real bug found via live testing against the Gemini
    /// API (2026-09-04): "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" (help, my
    /// kidney hurts) was classified `health_query` by the LLM, not
    /// `emergency`. This deterministic net must catch it independent of
    /// the LLM's classification, since it never even reaches the LLM
    /// (`NullCommandInterpreter` in this test — the router falls straight
    /// to `routeKeyword`).
    func testDistressPhraseWithSymptomTriggersEmergencyDeterministically() {
        let coordinator = MockVoiceCommandCoordinator()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus, speaker: MockSpeaker())

        let result = router.route(transcript: "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_emergency_keyword" })
    }

    func testEnglishHelpPhraseTriggersEmergency() {
        let coordinator = MockVoiceCommandCoordinator()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(), speaker: MockSpeaker())

        let result = router.route(transcript: "please help me")

        XCTAssertEqual(result, .emergencyTriggered)
    }

    func testEmergencyIsCheckedBeforeMedicationAckSoItCannotBeShadowed() {
        // A distress phrase must win even if it happens to also contain an
        // ack-shaped word — emergency is checked first in routeKeyword.
        let coordinator = MockVoiceCommandCoordinator()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(), speaker: MockSpeaker())

        let result = router.route(transcript: "सहयोग गर्नुहोस्, मैले औषधि खाएँ तर लडेँ")

        XCTAssertEqual(result, .emergencyTriggered)
    }

    func testSensitiveCallCommandIsBlockedUntilAuthExists() async {
        let coordinator = MockVoiceCommandCoordinator()
        let speaker = MockSpeaker()
        let bus = MockObservabilityBus()
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: bus,
            speaker: speaker
        )

        let result = router.route(transcript: "छोरालाई फोन गर")
        await Task.yield()

        XCTAssertEqual(result, .blockedSensitiveAction)
        XCTAssertTrue(coordinator.acknowledgedEntryIds.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_sensitive_blocked_auth_unavailable"
        })
        // The refusal must ALSO land on the outcome card — the live-caption
        // pill is gone by the time the block fires, so a spoken-only reply
        // leaves the screen with no transcript and no answer (2026-09-05).
        XCTAssertEqual(coordinator.genericReplies.count, 1)
    }

    // MARK: - Trial wiring: voice call / send message (LLM-interpreted path)

    /// 2026-09-05: calling now asks for confirmation FIRST — the router's
    /// job is just to request it and speak the prompt. Nothing is dialed
    /// at this layer; `AppCoordinator.handleConfirmationResponse` does
    /// that only after the user says yes (covered by AppCoordinator-level
    /// testing, not here — this test is about CommandRouter's contract).
    func testCallWithResolvedContactRequestsConfirmationNotADial() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = "छोरालाई फोन गर्ने हो?"
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil, medication: nil,
            message: nil, callType: "voice", requestedApp: nil, pluginAction: nil, pluginEntities: nil, confidence: 0.95, reply: "ठिक छ, फोन गर्दैछु"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई फोन गर")

        XCTAssertEqual(coordinator.callConfirmationRequests.count, 1)
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.contact, "छोरा")
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.callType, "voice")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_call_confirmation_requested" })
    }

    /// "messenger ma call gara" — the LLM extracts requestedApp=messenger;
    /// the router's job is to hand the slot through to the coordinator's
    /// confirmation flow untouched (the messenger method resolution,
    /// handle check, and deep link all live below this layer).
    func testMessengerCallIntentRoutesAppSlotThroughToConfirmation() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = "छोरालाई म्यासेन्जर अडियो कल गर्ने हो?"
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: "messenger", pluginAction: nil, pluginEntities: nil, confidence: 0.95, reply: "ठिक छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई messenger ma call gara")

        XCTAssertEqual(coordinator.callConfirmationRequests.count, 1)
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.contact, "छोरा")
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.requestedApp, "messenger")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_call_confirmation_requested" })
    }

    /// "messenger video" — callType=video + requestedApp=messenger both
    /// survive routing, so MethodResolver can pick .messengerVideo.
    func testMessengerVideoCallIntentRoutesBothSlotsThrough() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = "छोरालाई म्यासेन्जर भिडियो कल गर्ने हो?"
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil, medication: nil,
            message: nil, callType: "video", requestedApp: "म्यासेन्जर", pluginAction: nil, pluginEntities: nil, confidence: 0.95, reply: "ठिक छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई म्यासेन्जरमा भिडियो कल गर")

        XCTAssertEqual(coordinator.callConfirmationRequests.count, 1)
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.requestedApp, "म्यासेन्जर")
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.callType, "video")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_call_confirmation_requested" })
    }

    func testCallWithUnresolvedContactStaysBlocked() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = nil
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "अज्ञात व्यक्ति", time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil, confidence: 0.95, reply: "ठिक छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "फोन गर")

        XCTAssertEqual(coordinator.callConfirmationRequests.first?.contact, "अज्ञात व्यक्ति")
        // A name WAS extracted but didn't resolve — distinct "contact not
        // found" message, not the generic "blocked" one (2026-09-05 fix).
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_call_contact_not_found"
        })
    }

    /// The yes/no follow-up to a call confirmation must NOT speak the
    /// generic medication-flavored "confirmationYes" text — AppCoordinator
    /// owns that response for calls (see `isAwaitingCallConfirmation`).
    func testCallConfirmationYesDoesNotSpeakGenericMedicationText() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isAwaitingConfirmation = true
        coordinator.isAwaitingCallConfirmation = true
        let speaker = MockSpeaker()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(),
                                   speaker: speaker)

        let result = router.route(transcript: "हजुर")

        XCTAssertEqual(result, .callConfirmed)
        XCTAssertEqual(coordinator.confirmationResponses, [.yes])
        XCTAssertTrue(speaker.utterances.isEmpty,
                      "CommandRouter must not also speak — AppCoordinator speaks its own call-specific response")
    }

    /// Regression: a plain Q&A reply (`.query`/`.none`) previously had NO
    /// visible trace at all — only the tracked actions (ack/reminder/
    /// call/message) produced an outcome card. Found via a real device
    /// test where the user reported "no transcript got written" for an
    /// ordinary question.
    func testQueryReplyProducesAVisibleGenericOutcome() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil, confidence: 0.9, reply: "आज घमाइलो छ।"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(),
                                   speaker: MockSpeaker(), interpreter: interpreter)

        // A non-topic query: weather is now pre-answered by
        // `TopicPreAnswer` (NO-GIBBERISH) before the interpreter chain
        // runs, so the generic-reply regression needs a plain question
        // outside the weather/time/date/greeting table.
        _ = router.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")

        XCTAssertEqual(coordinator.genericReplies, ["आज घमाइलो छ।"])
    }

    // MARK: - .plugin dispatch (plugin architecture, 2026-09-05)

    func testPluginIntentDispatchesToRegisteredPlugin() {
        let coordinator = MockVoiceCommandCoordinator()
        let registry = PluginRegistry()
        let plugin = FakePlugin(id: "test_plugin", actionNames: ["test.action"], applicableToNepali: false)
        registry.register(plugin)
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport())
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .plugin, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil,
            pluginAction: "test.action", pluginEntities: ["foo": "bar"],
            confidence: 0.9, reply: ""
        )
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter,
                                   pluginRegistry: registry, geminiClient: client)

        _ = router.route(transcript: "do the test thing")

        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_plugin_dispatched" })
        // handle() runs in a Task — give it a turn to land.
        let exp = expectation(description: "plugin handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(plugin.handledCommands.count, 1)
        XCTAssertEqual(plugin.handledCommands.first?.actionName, "test.action")
        XCTAssertEqual(plugin.handledCommands.first?.entities["foo"], "bar")
    }

    func testPluginIntentWithUnknownActionSpeaksUnavailable() {
        let coordinator = MockVoiceCommandCoordinator()
        let registry = PluginRegistry()   // nothing registered
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport())
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .plugin, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil,
            pluginAction: "nope.action", pluginEntities: nil,
            confidence: 0.9, reply: ""
        )
        let bus = MockObservabilityBus()
        let speaker = MockSpeaker()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker, interpreter: interpreter,
                                   pluginRegistry: registry, geminiClient: client)

        _ = router.route(transcript: "do something unsupported")

        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_plugin_unresolved" })
        // speak() dispatches to a Task — let it land before asserting.
        let exp = expectation(description: "speak delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(speaker.utterances.count, 1, "the unavailable message must actually be spoken")
    }

    func testSendMessageWithResolvedContactPresentsComposeSheet() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.messageOutcome = .nativeComposePresented
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .sendMessage, entryId: nil, contact: "छोरी", time: nil, medication: nil,
            message: "म राम्रो छु", callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil, confidence: 0.95, reply: "सन्देश तयार छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरीलाई सन्देश पठाऊ, म राम्रो छु")

        XCTAssertEqual(coordinator.composedMessages.count, 1)
        XCTAssertEqual(coordinator.composedMessages.first?.contact, "छोरी")
        XCTAssertEqual(coordinator.composedMessages.first?.body, "म राम्रो छु")
        XCTAssertNil(coordinator.composedMessages.first?.requestedApp)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_message_composing" })
    }

    func testSendMessageNamingWhatsAppThreadsRequestedAppThrough() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.messageOutcome = .whatsAppChatOpened
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .sendMessage, entryId: nil, contact: "छोरी", time: nil, medication: nil,
            message: "म राम्रो छु", callType: nil, requestedApp: "whatsapp", pluginAction: nil, pluginEntities: nil,
            confidence: 0.95, reply: "सन्देश तयार छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरीलाई वाट्सएपमा सन्देश पठाऊ, म राम्रो छु")

        // The router threads the slot verbatim — WHICH surface opens is
        // the coordinator's decision (contact resolution + CallLinks).
        XCTAssertEqual(coordinator.composedMessages.first?.requestedApp, "whatsapp")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_message_whatsapp_opened" })
    }

    func testSendMessageWhatsAppFallbackEmitsInfoEvent() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.messageOutcome = .fellBackToNativeCompose
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .sendMessage, entryId: nil, contact: "छोरी", time: nil, medication: nil,
            message: "म राम्रो छु", callType: nil, requestedApp: "whatsapp", pluginAction: nil, pluginEntities: nil,
            confidence: 0.95, reply: "सन्देश तयार छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरीलाई वाट्सएपमा सन्देश पठाऊ")

        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_message_whatsapp_fallback_sms" })
        // The coordinator speaks the disclosed fallback line — the router
        // must NOT also speak the model's ack as if WhatsApp opened.
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "command_message_whatsapp_opened" })
    }
}

/// Deterministic `CommandInterpreter` double: fires its completion
/// synchronously so tests don't need to await a dispatch gap.
private final class FakeCommandInterpreter: CommandInterpreter {
    var isAvailable = true
    var nextCommand: InterpretedCommand?
    /// [INTENT-TOOLS] (2026-09-07) How often `interpret` was actually
    /// invoked — lets the calculator/weather-yield tests prove the
    /// deterministic stages answer WITHOUT ever consulting the LLM.
    private(set) var interpretCallCount = 0

    func interpret(transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCallCount += 1
        completion(nextCommand)
    }
}

/// [REST-DIP-FIX] (2026-09-08) Deterministic interpreter double that
/// HOLDS its completion until the test fires it — mirrors the production
/// round-trip (IntentRouter completions land on arbitrary queues seconds
/// after `route()` returned), so tests can observe the router between
/// `route()` returning and the async reply dispatch finishing.
private final class HoldableCommandInterpreter: CommandInterpreter {
    var isAvailable = true
    private(set) var interpretCallCount = 0
    private var heldCompletions: [(transcript: String,
                                   context: InterpreterContext,
                                   completion: (InterpretedCommand?) -> Void)] = []

    func interpret(transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCallCount += 1
        heldCompletions.append((transcript, context, completion))
    }

    /// Fires the oldest held completion with `command` (nil = the
    /// interpreter abstains, exactly like a real no-confidence result).
    func completeNext(with command: InterpretedCommand?) {
        let held = heldCompletions.removeFirst()
        held.completion(command)
    }
}

private final class MockVoiceCommandCoordinator: VoiceCommandCoordinating {
    var recordedTranscripts: [String] = []
    var pendingReminderId: UUID?
    var acknowledgedEntryIds: [UUID] = []
    var confirmationChallengeEntryIds: [UUID] = []
    var confirmationResponses: [ConfirmationResponse] = []
    var confirmationPrompt: String? = "के तपाईंले औषधि अहिले लिनुभएको हो?"
    var isAwaitingConfirmation = false
    var addedReminders: [(title: String, time: DateComponents)] = []
    /// Defaults to `.available` so existing router tests keep the generic
    /// re-prompt behavior; the availability-matrix tests script it.
    var brainReadiness = BrainReadiness.available

    /// [INTENT-TOOLS] (2026-09-07) Live-web capability — protocol
    /// requirement with an extension default of false; this stored var
    /// satisfies it so the weather-yield tests can script BOTH sides:
    /// false (default, on-device stack) keeps the deterministic
    /// pre-answer; true (cloud stack) yields weather to the interpreter.
    var canAnswerLiveQuestionsFromWeb = false

    /// [LOCAL-TOOLS] (2026-09-07) On-device-stack flag — protocol
    /// requirement with an extension default of false; this stored var
    /// satisfies it so the local-tools tests can script BOTH sides:
    /// false (default) keeps every pre-existing router test on its exact
    /// historical path (deterministic weather pre-answer, generic
    /// re-prompt); true arms the live weather/search tools.
    var isOnDeviceStack = false

    /// [WEATHER-ROUTING] (2026-09-07) Locale override — the default stays
    /// ne-NP (every existing test's expectations); tests that pin an
    /// English spoken sentence (e.g. the `weather.replySource` hedge)
    /// set this to an English locale.
    var localeOverride: Locale?
    var activeLocale: Locale { localeOverride ?? Locale(identifier: "ne-NP") }

    func recordTranscript(_ text: String) {
        recordedTranscripts.append(text)
    }

    func oldestPendingReminderEntryId() -> UUID? {
        pendingReminderId
    }

    func handleMedicationAcknowledgement(entryId: UUID) {
        acknowledgedEntryIds.append(entryId)
    }

    func startVoiceAckConfirmation(for entryId: UUID) -> String? {
        confirmationChallengeEntryIds.append(entryId)
        isAwaitingConfirmation = confirmationPrompt != nil
        return confirmationPrompt
    }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        confirmationResponses.append(response)
        isAwaitingConfirmation = false
    }

    /// [REST-DIP-FIX] (2026-09-08) Speech-start recorder. The router
    /// calls `noteSpeakingStarted()` synchronously when it commits a
    /// reply, so the turn-holding tests can pin that the commit happens
    /// while the turn is still pending (its main-queue speech-start hop
    /// precedes the pipeline's deferred idle hop).
    private(set) var speakingStarts = 0
    func noteSpeakingStarted() { speakingStarts += 1 }
    func noteSpeakingEnded() {}

    /// [LOCAL-TOOLS] (2026-09-07) Every spoken line, in speech order. The
    /// deterministic twin of `speaker.utterances` (which records inside
    /// each speak Task, i.e. asynchronously): `noteAssistantSpoke` runs
    /// synchronously at speak time, so multi-line sequences — the
    /// announce-then-reply weather turn, the cap-notice-then-re-prompt
    /// search turn — can be asserted exactly.
    var assistantSpoken: [String] = []
    func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
    var genericReplies: [String] = []
    func noteGenericReply(_ text: String) { genericReplies.append(text) }

    func addVoiceReminder(title: String, time: DateComponents) {
        addedReminders.append((title, time))
    }

    var isAwaitingCallConfirmation = false
    var callConfirmationPrompt: String? = "फोन गर्ने हो?"
    var callConfirmationRequests: [(contact: String?, callType: String?, requestedApp: String?)] = []
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? {
        callConfirmationRequests.append((contactQuery, callType, requestedApp))
        return callConfirmationPrompt
    }

    var overrideUtterances: [String] = []
    var overrideShouldHandle = false
    func handleCallConfirmationOverride(_ utterance: String) -> Bool {
        overrideUtterances.append(utterance)
        return overrideShouldHandle
    }

    var composedMessages: [(contact: String?, body: String, requestedApp: String?)] = []
    var messageOutcome: MessageComposeOutcome = .contactNotFound
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome {
        composedMessages.append((name, body, requestedApp))
        return messageOutcome
    }

    var presentedPluginViews: [AnyView] = []
    func presentPluginView(_ view: AnyView) { presentedPluginViews.append(view) }

    /// voice-contact-search (2026-09-07): recorder for the keyword
    /// pre-route's coordinator call.
    var contactSearchRequests: [String?] = []
    func requestContactSearch(query: String?) {
        contactSearchRequests.append(query)
    }

    /// [DIRECTIONS] (2026-09-07) Navigation members — protocol
    /// requirements satisfied by stored vars/recorders so the directions
    /// tests can script BOTH sides: an empty candidate list keeps every
    /// pre-existing router test on its exact historical path (the stage
    /// still owns bare-home requests), and populated lists arm the
    /// candidate-resolution tests.
    var navigationCandidates: [DirectionsCandidate] = []
    var isAwaitingNavigationDisambiguation = false
    var navigationRequests: [DirectionsRoute.PlaceTarget] = []
    func requestNavigation(to target: DirectionsRoute.PlaceTarget) {
        navigationRequests.append(target)
    }
    /// Canned yes/no question the mock "asks" for the first candidate —
    /// nil by default (router then ends the turn silently), non-nil in
    /// the disambiguation tests (router speaks it verbatim).
    var navigationDisambiguationPrompt: String? = nil
    var navigationDisambiguationRequests: [[DirectionsCandidate]] = []
    func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? {
        navigationDisambiguationRequests.append(targets)
        return navigationDisambiguationPrompt
    }

    /// [ALARMS-TIMERS] (2026-09-07) Alarm/timer creation — protocol
    /// requirements with an extension default of .failed; these stored
    /// vars satisfy them so the stage tests can script every outcome.
    /// The DEFAULT of .scheduled keeps pre-existing router tests (none of
    /// which speak an alarm/timer marker) on their historical path.
    var alarmSetOutcome: AlarmTimerSetOutcome = .scheduled
    var alarmSetRequests: [(time: Date, label: String?)] = []
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome {
        alarmSetRequests.append((time, label))
        return alarmSetOutcome
    }

    var timerStartOutcome: AlarmTimerSetOutcome = .scheduled
    var timerStartRequests: [(durationSeconds: Int, label: String?)] = []
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        timerStartRequests.append((durationSeconds, label))
        return timerStartOutcome
    }

    /// [ALARMS-TIMERS] (2026-09-08) Voice OFF/SNOOZE — protocol
    /// requirements with an extension default of .noAlarm; these stored
    /// vars satisfy them so the stage tests can script every outcome.
    /// The DEFAULT of .noAlarm keeps pre-existing router tests (none of
    /// which speak an off/snooze marker) on their historical path.
    var alarmOffOutcome: AlarmOffOutcome = .noAlarm
    private(set) var alarmOffRequestCount = 0
    func requestAlarmOff() -> AlarmOffOutcome {
        alarmOffRequestCount += 1
        return alarmOffOutcome
    }

    var alarmSnoozeOutcome: AlarmSnoozeOutcome = .noAlarm
    private(set) var alarmSnoozeRequests: [Int] = []
    func requestAlarmSnooze(minutes: Int) -> AlarmSnoozeOutcome {
        alarmSnoozeRequests.append(minutes)
        return alarmSnoozeOutcome
    }

    var pendingRephraseCommand: InterpretedCommand? { rephrasePended?.command }
    private(set) var rephrasePended: (command: InterpretedCommand, sourceTranscript: String?)?
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? {
        let taken = rephrasePended
        rephrasePended = nil
        return taken
    }
}

private final class MockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

// MARK: - Contact-search keyword pre-route (voice-contact-search, 2026-09-07)

/// Wiring of the deterministic contact-search stage: `VoiceContactSearchRoute`
/// decides before the topic table and interpreter, the coordinator receives
/// the extracted query, and call-shaped utterances never reach it.
final class CommandRouterContactSearchTests: XCTestCase {

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator)
        -> (CommandRouter, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker())
        return (router, bus)
    }

    func testDevanagariContactSearchRoutesToCoordinatorWithExtractedQuery() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "मैयाको फोन नम्बर खोज")

        XCTAssertEqual(result, .contactSearchRequested)
        XCTAssertEqual(coordinator.contactSearchRequests, ["मैया"])
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "contact_search_command" })
    }

    func testRomanizedContactSearchRoutesToCoordinator() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "maiya ko phone khoja")

        XCTAssertEqual(result, .contactSearchRequested)
        XCTAssertEqual(coordinator.contactSearchRequests, ["maiya"])
    }

    func testGreetingPrefixedSearchIsASearchNotSmallTalk() {
        // The pre-route sits BEFORE the TopicPreAnswer table: a greeting
        // prefix must not turn "नमस्ते, मैयाको फोन नम्बर खोज" into a
        // greeting reply.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "नमस्ते, मैयाको फोन नम्बर खोज")

        XCTAssertEqual(result, .contactSearchRequested)
        XCTAssertEqual(coordinator.contactSearchRequests, ["मैया"])
        XCTAssertTrue(coordinator.genericReplies.isEmpty)
    }

    func testSearchShapedUtteranceWithoutNameStillRoutes() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "फोन नम्बर खोज")

        XCTAssertEqual(result, .contactSearchRequested)
        XCTAssertEqual(coordinator.contactSearchRequests, [nil])
    }

    func testDirectCallUtteranceIsNotSwallowedBySearchMarkers() {
        // "फोन नम्बर लगाऊ" is a CALL intent (golden corpus) — the phone-
        // word markers must never shadow it.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "फोन नम्बर लगाऊ")

        XCTAssertNotEqual(result, .contactSearchRequested)
        XCTAssertTrue(coordinator.contactSearchRequests.isEmpty)
    }

    func testCallVerbUtteranceIsNotSwallowedBySearchMarkers() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "छोरालाई फोन गर")

        XCTAssertTrue(coordinator.contactSearchRequests.isEmpty)
    }

    func testEmergencyStillWinsBeforeContactSearch() {
        // The safety net is above the pre-route in the ladder — distress
        // phrasing that contains no search marker must never be delayed.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(coordinator.contactSearchRequests.isEmpty)
    }
}

// MARK: - Intent tools (intent-tools, 2026-09-07): calculator + weather yield

/// Router wiring of the deterministic tool stages:
///  - `intent_tool_calculator` answers provable arithmetic in the
///    pre-route layer (after the topic table, before the interpreter) on
///    BOTH stacks by default — the interpreter is never consulted, the
///    reply is carded + spoken with the coordinator's locale, and
///    division by zero is an honest visible+spoken error event.
///  - `canAnswerLiveQuestionsFromWeb` (default false) yields the WEATHER
///    topic to the interpreter so a grounded cloud answer can replace
///    the no-data pre-answer; time/date/greeting stay deterministic.
final class CommandRouterIntentToolsTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator,
                            interpreter: FakeCommandInterpreter? = nil)
        -> (CommandRouter, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   interpreter: interpreter ?? FakeCommandInterpreter())
        return (router, bus)
    }

    // MARK: - Calculator: computed answers

    func testCalculatorAnswerIsSpokenAndCardedWithoutConsultingTheLLM() async {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)

        let result = router.route(transcript: "५ जोड ३ कति हुन्छ?")
        await Task.yield()

        XCTAssertEqual(result, .unrecognised(transcript: "५ जोड ३ कति हुन्छ?"))
        XCTAssertEqual(coordinator.genericReplies, ["५ जोड ३ बराबर ८ हुन्छ।"],
                       "the deterministic reply must land on the outcome card")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "intent_tool_calculator" && $0.outcome == "success"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "command_dispatched_to_llm" })
        XCTAssertEqual(interpreter.interpretCallCount, 0,
                       "provable arithmetic must never reach the LLM interpreter")
    }

    func testCalculatorReplySpokenInCoordinatorsLocale() async {
        let coordinator = MockVoiceCommandCoordinator()
        let speaker = MockSpeaker()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker, interpreter: FakeCommandInterpreter())

        _ = router.route(transcript: "१० र ४ घटाउनुहोस्")
        await Task.yield()

        XCTAssertEqual(speaker.utterances.map(\.text), ["१० घटाउ ४ बराबर ६ हुन्छ।"])
        XCTAssertEqual(speaker.utterances.first?.locale, Locale(identifier: "ne-NP"))
    }

    // MARK: - Calculator: division by zero — honest error, never a number

    func testDivisionByZeroIsVisibleSpokenErrorNotANumber() async {
        let coordinator = MockVoiceCommandCoordinator()
        let speaker = MockSpeaker()
        let interpreter = FakeCommandInterpreter()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker, interpreter: interpreter)

        _ = router.route(transcript: "१० लाई ० ले भाग गर")
        await Task.yield()

        let expected = L10n.str("calculator.error.divByZero", locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [expected],
                       "the error must be VISIBLE — a spoken-only error vanishes with the caption pill")
        XCTAssertEqual(speaker.utterances.map(\.text), [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "intent_tool_calculator" && $0.outcome == "error"
                && $0.errorCode == "division_by_zero"
        })
        XCTAssertEqual(interpreter.interpretCallCount, 0)
    }

    // MARK: - Calculator: non-arithmetic falls through untouched

    func testNonArithmeticUtteranceStillReachesTheInterpreter() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "त्यो कुरा मलाई थाहा छैन।"
        )
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")

        XCTAssertEqual(interpreter.interpretCallCount, 1)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_dispatched_to_llm" })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "intent_tool_calculator" })
        XCTAssertEqual(coordinator.genericReplies, ["त्यो कुरा मलाई थाहा छैन।"])
    }

    func testCalculatorNeverShadowsEmergencyOrCallVocabulary() async {
        // Safety net outranks the tool stage — distress stays emergency.
        let emergencyCoordinator = MockVoiceCommandCoordinator()
        let (emergencyRouter, _) = makeRouter(emergencyCoordinator)
        XCTAssertEqual(emergencyRouter.route(transcript: "मद्दत गर्नुहोस् ५ जोड ३"),
                       .emergencyTriggered)
        // Call-shaped utterances are vetoed inside CalculatorTool
        // (mirrors the sensitive-call phrases) — they route onward, they
        // are never answered as arithmetic. With an interpreter present
        // the LLM path fires first (its asynchronous return shape is
        // `.unrecognised`); the post-LLM sensitive-call block then wins
        // inside the completion.
        let callCoordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: callCoordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)
        let result = router.route(transcript: "छोरालाई फोन गर ५ जोड ३")
        XCTAssertEqual(result, .unrecognised(transcript: "छोरालाई फोन गर ५ जोड ३"))
        XCTAssertEqual(interpreter.interpretCallCount, 1)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_dispatched_to_llm" })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_sensitive_blocked_auth_unavailable"
        }, "the post-LLM sensitive-call block must still fire")
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "intent_tool_calculator" },
                       "call talk must never be answered as arithmetic")
    }

    // MARK: - Weather yield: live-web capability decides the path

    func testWeatherPreAnswerStandsWhenLiveWebCapabilityIsOff() {
        // Default stack (extension default false — on-device brain, cloud
        // disabled, or cloud brain unavailable): the honest deterministic
        // no-data answer must win; the interpreter is never consulted.
        let coordinator = MockVoiceCommandCoordinator()   // canAnswerLiveQuestionsFromWeb == false
        let interpreter = FakeCommandInterpreter()
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: "भोलि काठमाडौंमा पानी पर्छ?")

        let expected = TopicPreAnswer.reply(for: .weather, locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "topic_pre_answer"
                && $0.metadata["topic"] == TopicPreAnswer.Topic.weather.rawValue
        })
        XCTAssertEqual(interpreter.interpretCallCount, 0)
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "command_dispatched_to_llm" })
    }

    func testWeatherYieldsToInterpreterWhenLiveWebCapabilityIsOn() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.canAnswerLiveQuestionsFromWeb = true
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "भोलि काठमाडौंमा हल्का पानी पर्ने सम्भावना छ।"
        )
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: "भोलि काठमाडौंमा पानी पर्छ?")
        await Task.yield()

        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "topic_pre_answer" },
                       "with live-web on, the weather no-data pre-answer must NOT fire")
        XCTAssertEqual(interpreter.interpretCallCount, 1,
                       "the grounded cloud interpreter answers the forecast")
        XCTAssertEqual(coordinator.genericReplies, ["भोलि काठमाडौंमा हल्का पानी पर्ने सम्भावना छ।"])
    }

    func testArncliffeWeatherFlowsToLiveWebInterpreterWithoutTheStaticLine() async {
        // The original bug report on the Gemini-with-key stack: live-web
        // capability is on, so the static "can't look up weather" no-data
        // line must NOT intercept — the grounded cloud interpreter answers
        // for Arncliffe instead. [WEATHER-ROUTING] (2026-09-07)
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.canAnswerLiveQuestionsFromWeb = true
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "It is dry in Arncliffe right now, with no rain expected."
        )
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: "what's the weather like in Arncliffe?")
        await Task.yield()

        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "topic_pre_answer" },
                       "with live-web on, the no-data pre-answer must NOT fire for Arncliffe")
        XCTAssertEqual(interpreter.interpretCallCount, 1,
                       "the grounded cloud interpreter answers the place-specific forecast")
        XCTAssertEqual(coordinator.genericReplies,
                       ["It is dry in Arncliffe right now, with no rain expected."])
        XCTAssertFalse(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather"
        }, "no local weather tool may run on the Gemini stack")
    }

    func testTimeAndDateStayDeterministicEvenWithLiveWebOn() {
        // Time/date are LOCAL FACTS, not web lookups — the live-web
        // capability yields ONLY the weather topic.
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.canAnswerLiveQuestionsFromWeb = true
        let interpreter = FakeCommandInterpreter()
        let (router, bus) = makeRouter(coordinator, interpreter: interpreter)
        let fixedNow = Date(timeIntervalSince1970: 1_727_000_000)   // pinned, not wall clock
        router.clock = { fixedNow }

        _ = router.route(transcript: "अहिले कति बजेको छ?")

        let expected = TopicPreAnswer.reply(for: .time, locale: ne, now: fixedNow)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "topic_pre_answer"
                && $0.metadata["topic"] == TopicPreAnswer.Topic.time.rawValue
        })
        XCTAssertEqual(interpreter.interpretCallCount, 0)
    }
}

// MARK: - Local tools (local-tools, 2026-09-07): live weather + web search

/// Wiring of the two [LOCAL-TOOLS] stages, both ON-DEVICE-stack only:
///
///  - WEATHER: a weather-topic utterance on the on-device stack announces
///    "weather.checking" and answers for the place that was ASKED: a
///    named place in the utterance is geocoded through open-meteo's
///    geocoding seam (same `LocalToolTransport`) and the forecast is read
///    for THAT point — the Arncliffe fix ([WEATHER-ROUTING] 2026-09-07);
///    a geocode failure, or an utterance naming no place, reads the
///    forecast for the DEVICE location (point-of-use,
///    one-request-per-instance `LocationFetching` factory). Every live
///    reading is carded + spoken WRAPPED in the `weather.replySource`
///    attribution hedge with a `local_tools`/`weather`/`ok` event. ANY
///    failure (location denied, no fix, transport error, malformed
///    payload) delivers the EXISTING static `topic.weather.unavailable`
///    line with a `weather`/`fail` event — never a fabricated number, and
///    never the `topic_pre_answer` event (a fallback that followed a tool
///    attempt is distinguishable). Off-stack, the static pre-answer
///    stands unchanged.
///
///  - SEARCH: fires ONLY at the post-interpreter abstention point when
///    the utterance is question-shaped AND a credential pair is
///    configured; the cap day speaks the cap notice + the generic
///    re-prompt (one uninterrupted sequence), failures/empty results fall
///    back to the generic re-prompt with a `search`/`fail` event, and the
///    tool NEVER runs for utterances an intent, topic, or tool already
///    answered — topic-matched utterances carry an additional in-hook veto
///    as defense in depth ([WEATHER-ROUTING] 2026-09-07).
final class CommandRouterLocalToolsTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private var quotaDefaults: UserDefaults!
    private var quotaSuiteName: String!

    override func setUp() {
        super.setUp()
        quotaSuiteName = "CommandRouterLocalToolsTests.\(UUID().uuidString)"
        quotaDefaults = UserDefaults(suiteName: quotaSuiteName)
    }

    override func tearDown() {
        quotaDefaults.removePersistentDomain(forName: quotaSuiteName)
        quotaDefaults = nil
        quotaSuiteName = nil
        super.tearDown()
    }

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator,
                            interpreter: CommandInterpreter? = nil,
                            searchConfigStore: SearchConfigStore? = nil,
                            locationFetcherFactory: (() -> LocationFetching)? = nil,
                            weatherTransport: LocalToolTransport? = nil,
                            searchTransport: LocalToolTransport? = nil,
                            localToolLogStore: LocalToolLogStore? = nil)
        -> (CommandRouter, MockObservabilityBus, MockSpeaker) {
        let bus = MockObservabilityBus()
        let speaker = MockSpeaker()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter ?? NullCommandInterpreter(),
                                   searchConfigStore: searchConfigStore,
                                   locationFetcherFactory: locationFetcherFactory,
                                   weatherTransport: weatherTransport,
                                   searchTransport: searchTransport,
                                   searchQuotaDefaults: quotaDefaults,
                                   localToolLogStore: localToolLogStore)
        return (router, bus, speaker)
    }

    /// [TOOL-DEBUG-LOG] (2026-09-07) A real store over the in-memory
    /// `EncryptedLocalStorage` double — the router under test records into
    /// it exactly like production (AppCoordinator injects the same store
    /// class over the Keychain channel).
    private func makeLogStore() -> LocalToolLogStore {
        LocalToolLogStore(storage: GeminiInMemoryStorage())
    }

    private func waitForToolDelivery() {
        let exp = expectation(description: "local-tool async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    private var weatherJSON: Data {
        Data(#"{"current": {"temperature_2m": 24.3, "weather_code": 0,"#.utf8)
            + Data(#" "wind_speed_10m": 12.5, "relative_humidity_2m": 62}}"#.utf8)
    }

    // MARK: - Weather: named place → geocoded live reading

    /// The Arncliffe fix end to end: "is it raining in Arncliffe?" on the
    /// on-device stack geocodes ARNCLIFFE (never the device location),
    /// fetches the forecast for that point, and the reply names the
    /// geocoded place — hedged by the `weather.replySource` attribution
    /// line. The device location seam is never consulted.
    func testOnDeviceWeatherQuestionWithNamedPlaceGeocodesAndSpeaksThatPlacesConditions() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        coordinator.localeOverride = Locale(identifier: "en-US")
        // A location fix exists but must NEVER be requested — the named
        // place answers for itself.
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "Kathmandu")))
        let transport = StubLocalToolTransport(
            data: weatherJSON,
            geocodingData: Data(#"{"results": [{"name": "Arncliffe", "latitude": -33.9375,"#.utf8)
                + Data(#" "longitude": 151.1522}]}"#.utf8))
        let (router, bus, speaker) = makeRouter(coordinator,
                                                locationFetcherFactory: { fetcher },
                                                weatherTransport: transport)

        let result = router.route(transcript: "is it raining in Arncliffe?")
        waitForToolDelivery()

        XCTAssertEqual(result, .unrecognised(transcript: "is it raining in Arncliffe?"))
        // Two round-trips: geocode for the spoken name, then the forecast
        // at the GEOCODED coordinates.
        XCTAssertEqual(transport.capturedRequests.count, 2)
        let geocode = URLComponents(url: transport.capturedRequests[0].url!,
                                    resolvingAgainstBaseURL: false)
        XCTAssertEqual(geocode?.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(geocode?.queryItems?.first { $0.name == "name" }?.value, "arncliffe")
        XCTAssertEqual(geocode?.queryItems?.first { $0.name == "count" }?.value, "1")
        let forecast = URLComponents(url: transport.capturedRequests[1].url!,
                                     resolvingAgainstBaseURL: false)
        XCTAssertEqual(forecast?.host, "api.open-meteo.com")
        XCTAssertEqual(forecast?.queryItems?.first { $0.name == "latitude" }?.value, "-33.9375")
        XCTAssertEqual(forecast?.queryItems?.first { $0.name == "longitude" }?.value, "151.1522")
        XCTAssertEqual(fetcher.requestCount, 0,
                       "a named-place answer must never prompt for the device location")
        // Spoken: the checking announcement, then the hedged live reply
        // naming the GEOCODED place (Arncliffe, not the device's place).
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: "Arncliffe", locale: Locale(identifier: "en"))
        let expected = L10n.fmt("weather.replySource",
                                locale: Locale(identifier: "en-US"), raw)
        XCTAssertEqual(raw, "It's 24°C and clear in Arncliffe.")
        XCTAssertEqual(expected,
                       "According to the weather service, It's 24°C and clear in Arncliffe.")
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("weather.checking", locale: Locale(identifier: "en-US")), expected])
        XCTAssertEqual(coordinator.genericReplies, [expected],
                       "the hedged live reading must land on the outcome card")
        XCTAssertEqual(Set(speaker.utterances.map(\.text)),
                       Set([L10n.str("weather.checking", locale: Locale(identifier: "en-US")),
                            expected]))
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "ok"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "topic_pre_answer" },
                       "a live answer must not also emit the no-data pre-answer event")
    }

    /// Nepali named place through the same pipeline: the locative
    /// "काठमाडौंमा" is geocoded (Devanagari name on the wire, decoded by
    /// the seam) and the device location stays untouched.
    func testOnDeviceNepaliWeatherQuestionWithNamedPlaceGeocodesThatPlace() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: nil)))
        let transport = StubLocalToolTransport(
            data: weatherJSON,
            geocodingData: Data(#"{"results": [{"name": "Kathmandu", "latitude": 27.7172,"#.utf8)
                + Data(#" "longitude": 85.324}]}"#.utf8))
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        _ = router.route(transcript: "भोलि काठमाडौंमा पानी पर्छ?")
        waitForToolDelivery()

        XCTAssertEqual(transport.capturedRequests.count, 2)
        let geocode = URLComponents(url: transport.capturedRequests[0].url!,
                                    resolvingAgainstBaseURL: false)
        XCTAssertEqual(geocode?.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(geocode?.queryItems?.first { $0.name == "name" }?.value, "काठमाडौं")
        XCTAssertEqual(fetcher.requestCount, 0)
        // The reply names the GEOCODED (English) place under Nepali.
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: "Kathmandu", locale: ne)
        let expected = L10n.fmt("weather.replySource", locale: ne, raw)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "weather" && $0.outcome == "ok"
        })
    }

    // MARK: - Weather: no place name → device location

    /// A weather question that names NO place reads the forecast for the
    /// DEVICE location (point-of-use permission) — no geocode round-trip.
    func testOnDeviceWeatherQuestionWithoutPlaceNameUsesDeviceLocation() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        // Simulator-style: fix without a reverse-geocoded place name.
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: nil)))
        let transport = StubLocalToolTransport(data: weatherJSON)
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        _ = router.route(transcript: "मौसम कस्तो छ?")
        waitForToolDelivery()

        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "no place was named — only the device forecast round-trip")
        let components = URLComponents(url: transport.capturedRequests[0].url!,
                                       resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.host, "api.open-meteo.com")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "latitude" }?.value, "27.7172")
        // The announced lookup first, then the hedged carded + spoken
        // reply without a place clause.
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: nil, locale: ne)
        let expected = L10n.fmt("weather.replySource", locale: ne, raw)
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("weather.checking", locale: ne), expected])
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "ok"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "topic_pre_answer" })
    }

    // MARK: - Weather: named place + geocode failure → device location

    /// A spoken place the geocoder cannot resolve must not end the turn:
    /// the router falls back to the DEVICE location and answers honestly
    /// for where the device is.
    func testNamedPlaceGeocodeFailureFallsBackToDeviceLocation() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "काठमाडौं")))
        // geocodingData defaults to an empty payload → the geocode parse
        // finds no result (200 OK, nothing matched).
        let transport = StubLocalToolTransport(data: weatherJSON)
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        _ = router.route(transcript: "is it raining in Arncliffe?")
        waitForToolDelivery()

        XCTAssertEqual(transport.capturedRequests.count, 2,
                       "geocode attempt + device-location forecast")
        XCTAssertEqual(URLComponents(url: transport.capturedRequests[0].url!,
                                     resolvingAgainstBaseURL: false)?.host,
                       "geocoding-api.open-meteo.com")
        XCTAssertEqual(URLComponents(url: transport.capturedRequests[1].url!,
                                     resolvingAgainstBaseURL: false)?.host,
                       "api.open-meteo.com")
        XCTAssertEqual(fetcher.requestCount, 1,
                       "an unresolvable place must fall back to the device fix")
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: "काठमाडौं", locale: ne)
        let expected = L10n.fmt("weather.replySource", locale: ne, raw)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "ok"
        })
    }

    /// The geocode HTTP round-trip itself failing (non-200) falls back
    /// the same way — a transport error is a geocode failure.
    func testNamedPlaceGeocodeHTTPFailureFallsBackToDeviceLocation() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "काठमाडौं")))
        let transport = StubLocalToolTransport(data: weatherJSON, geocodingStatusCode: 503)
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        _ = router.route(transcript: "काठमाडौंको मौसम कस्तो छ?")
        waitForToolDelivery()

        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(coordinator.genericReplies.count, 1)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "ok"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "weather" && $0.outcome == "fail" })
    }

    // MARK: - Weather: failure → the EXISTING static no-data line

    func testLocationDeniedFallsBackToStaticNoDataLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .failure(.notAuthorized))
        let transport = StubLocalToolTransport(data: weatherJSON)   // must never be used
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        // No place is named — the turn goes straight to the device fix
        // and dies on the denied permission.
        _ = router.route(transcript: "मौसम कस्तो छ?")
        waitForToolDelivery()

        let expected = TopicPreAnswer.reply(for: .weather, locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [expected],
                       "denied location must deliver the unchanged no-data line")
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("weather.checking", locale: ne), expected])
        XCTAssertTrue(transport.capturedRequests.isEmpty,
                      "no forecast fetch may happen without a location fix")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "fail"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "weather" && $0.outcome == "ok" })
    }

    func testWeatherTransportFailureFallsBackToStaticNoDataLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "काठमाडौं")))
        let transport = StubLocalToolTransport(data: Data(), statusCode: 503)
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: transport)

        // No place named — the single forecast round-trip fails.
        _ = router.route(transcript: "मौसम कस्तो छ?")
        waitForToolDelivery()

        let expected = TopicPreAnswer.reply(for: .weather, locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "only the forecast round-trip — no geocode without a named place")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "fail"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "weather" && $0.outcome == "ok" })
    }

    // MARK: - Weather: gating

    func testWeatherQuestionOffTheOnDeviceStackKeepsTheStaticPreAnswer() {
        // canAnswerLiveQuestionsFromWeb false + isOnDeviceStack false (the
        // Gemini stack with its cloud brain down): the deterministic
        // no-data answer stands — the location seam is never even
        // consulted.
        let coordinator = MockVoiceCommandCoordinator()
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "काठमाडौं")))
        let (router, bus, _) = makeRouter(coordinator, locationFetcherFactory: { fetcher })

        _ = router.route(transcript: "भोलि काठमाडौंमा पानी पर्छ?")

        let expected = TopicPreAnswer.reply(for: .weather, locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [expected])
        XCTAssertEqual(fetcher.requestCount, 0,
                       "the location seam must stay dormant off the on-device stack")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "topic_pre_answer"
                && $0.metadata["topic"] == TopicPreAnswer.Topic.weather.rawValue
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
    }

    // MARK: - Weather: never falls through to web search

    func testWeatherQuestionNeverReachesTheSearchHookEvenWithCredentialsConfigured() {
        // The Arncliffe failure mode, end to end: search credentials ARE
        // configured and the utterance IS question-shaped — yet a weather
        // topic must be answered by the weather path alone. The topic
        // intercept runs before the search hook, and the in-hook topic
        // veto makes the boundary airtight ([WEATHER-ROUTING] 2026-09-07):
        // no search round-trip, no quota tick, no search event.
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: nil)))
        let weatherTransport = StubLocalToolTransport(data: weatherJSON)
        let searchTransport = StubLocalToolTransport()   // must never be called
        let (router, bus, _) = makeRouter(coordinator,
                                          locationFetcherFactory: { fetcher },
                                          weatherTransport: weatherTransport,
                                          searchTransport: searchTransport)

        _ = router.route(transcript: "is it raining in Arncliffe?")
        waitForToolDelivery()

        // The weather path ran (geocode attempt + forecast round-trips).
        XCTAssertEqual(weatherTransport.capturedRequests.count, 2)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "weather" && $0.outcome == "ok"
        })
        XCTAssertTrue(searchTransport.capturedRequests.isEmpty,
                      "weather talk must never reach the search transport")
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0,
                       "the search quota must stay untouched")
        XCTAssertFalse(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "search"
        })
    }

    // MARK: - Search: happy path

    func testSearchToolAnswersQuestionShapedAbstentionWhenConfigured() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        // One CSE-shaped payload drives both the transport stub and the
        // expected summary — the fixture guarantees two speakable
        // sentences, so the unwrap below can never crash a healthy test.
        let payload = Data("""
        {"items": [
            {"title": "France - Wikipedia",
             "snippet": "France is a country in Western Europe. Its capital is Paris. More here.",
             "link": "https://en.wikipedia.org/wiki/France"}
        ]}
        """.utf8)
        let transport = StubLocalToolTransport(data: payload)
        let (router, bus, speaker) = makeRouter(coordinator,
                                                searchConfigStore: store,
                                                searchTransport: transport)

        // Question-shaped, and NOT matched by any topic/tool — the pure
        // abstention point the hook is designed for.
        let result = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        XCTAssertEqual(result, .unrecognised(transcript: "what is the capital of France"))
        guard let expectedSummary = SearchTool.summaryReply(
            for: SearchTool.parseSearchJSON(data: payload), locale: ne) else {
            XCTFail("the test fixture must produce a speakable summary")
            return
        }
        XCTAssertEqual(coordinator.genericReplies, [expectedSummary],
                       "the search summary must land on the outcome card")
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("search.looking", locale: ne), expectedSummary])
        XCTAssertEqual(Set(speaker.utterances.map(\.text)),
                       Set([L10n.str("search.looking", locale: ne), expectedSummary]))
        XCTAssertEqual(transport.capturedRequests.count, 1)
        let components = URLComponents(url: transport.capturedRequests[0].url!,
                                       resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.host, "www.googleapis.com")
        XCTAssertEqual(components?.path, "/customsearch/v1")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "search" && $0.outcome == "ok"
        })
        // Attempt-based accounting: the fire ticked the quota exactly once.
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 1)
    }

    // MARK: - Search: quota cap

    func testSearchCapDaySpeaksCapNoticeThenRepromptWithoutCallingTransport() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let transport = StubLocalToolTransport()   // must never be called
        let (router, bus, speaker) = makeRouter(coordinator,
                                                searchConfigStore: store,
                                                searchTransport: transport)
        // Seed today's bucket at the cap (router compares against the
        // current calendar — seed it the same way).
        quotaDefaults.set(SearchQuota.dayStamp(for: Date(), calendar: .current),
                          forKey: SearchQuota.dayKey)
        quotaDefaults.set(SearchQuota.dailyLimit, forKey: SearchQuota.countKey)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        let capText = L10n.str("search.capReached", locale: ne)
        let reprompt = L10n.str("router.reprompt", locale: ne)
        XCTAssertEqual(coordinator.genericReplies, [capText],
                       "the cap notice is VISIBLE — a spoken-only notice vanishes with the caption pill")
        XCTAssertEqual(coordinator.assistantSpoken, [capText, reprompt],
                       "cap notice + re-prompt must be one uninterrupted spoken sequence")
        XCTAssertEqual(Set(speaker.utterances.map(\.text)), Set([capText, reprompt]))
        XCTAssertTrue(transport.capturedRequests.isEmpty,
                      "a capped day must never reach the network")
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), SearchQuota.dailyLimit,
                       "the cap path must not tick the counter")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "search" && $0.outcome == "cap"
        })
    }

    // MARK: - Search: failure / empty → the generic re-prompt

    func testSearchTransportFailureSpeaksGenericRepromptWithFailEvent() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let transport = StubLocalToolTransport(data: Data(), error: URLError(.timedOut))
        let (router, bus, _) = makeRouter(coordinator,
                                          searchConfigStore: store,
                                          searchTransport: transport)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        let reprompt = L10n.str("router.reprompt", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("search.looking", locale: ne), reprompt],
                       "the generic re-prompt follows the failed search")
        XCTAssertTrue(coordinator.genericReplies.isEmpty,
                      "the fallback is spoken-only — exactly the pre-tool abstention behavior")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "search" && $0.outcome == "fail"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "search" && $0.outcome == "ok" })
        // Attempt-based accounting: the failed attempt was still counted.
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 1)
    }

    func testSearchEmptyResultsSpeakGenericRepromptWithFailEvent() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        // 200 OK but nothing matched — indistinguishable from failure by
        // design: both fall back to the honest re-prompt.
        let transport = StubLocalToolTransport(data: Data(#"{"items": []}"#.utf8))
        let (router, bus, _) = makeRouter(coordinator,
                                          searchConfigStore: store,
                                          searchTransport: transport)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        let reprompt = L10n.str("router.reprompt", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("search.looking", locale: ne), reprompt])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "local_tools" && $0.eventType == "search" && $0.outcome == "fail"
        })
    }

    // MARK: - Search: gating — the hook must never over-fire

    func testSearchNeverFiresWithoutConfiguredCredentials() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let (router, bus, _) = makeRouter(coordinator)   // no SearchConfigStore

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)])
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
    }

    func testSearchNeverFiresOnTheGeminiStack() {
        let coordinator = MockVoiceCommandCoordinator()   // isOnDeviceStack == false
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let (router, bus, _) = makeRouter(coordinator, searchConfigStore: store)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)],
                       "the Gemini stack answers questions natively — local search stays off")
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
    }

    func testSearchNeverFiresOnStatements() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let (router, bus, _) = makeRouter(coordinator, searchConfigStore: store)

        _ = router.route(transcript: "म बजार जान्छु")
        waitForToolDelivery()

        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)])
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
    }

    func testSearchNeverFiresWhenTheInterpreterProducedAnIntent() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "पेरिस फ्रान्सको राजधानी हो।"
        )
        let (router, bus, _) = makeRouter(coordinator,
                                          interpreter: interpreter,
                                          searchConfigStore: store)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        // The intent answered — the LLM was consulted, the search tool was
        // NOT (an utterance that produced an intent never reaches the
        // abstention hook).
        XCTAssertEqual(interpreter.interpretCallCount, 1)
        XCTAssertEqual(coordinator.genericReplies, ["पेरिस फ्रान्सको राजधानी हो।"])
        XCTAssertFalse(coordinator.assistantSpoken.contains(L10n.str("search.looking", locale: ne)))
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
    }

    func testSearchNeverFiresWhenCalculatorAnsweredTheUtterance() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let (router, bus, _) = makeRouter(coordinator, searchConfigStore: store)

        // Question-shaped ("कति") AND configured — but the deterministic
        // calculator answered it in the pre-route layer first.
        _ = router.route(transcript: "५ जोड ३ कति हुन्छ?")
        waitForToolDelivery()

        XCTAssertEqual(coordinator.genericReplies, ["५ जोड ३ बराबर ८ हुन्छ।"])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "intent_tool_calculator" && $0.outcome == "success"
        })
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "local_tools" })
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
    }

    // MARK: - Debug log (tool-debug-log, 2026-09-07): exactly ONE entry
    // per local-tool attempt, with the right kind/outcome/response

    private func singleEntry(_ logStore: LocalToolLogStore,
                             file: StaticString = #filePath, line: UInt = #line) -> LocalToolLogEntry? {
        let entries = logStore.entries()
        guard entries.count == 1 else {
            XCTFail("expected exactly ONE logged entry, found \(entries.count)",
                    file: file, line: line)
            return nil
        }
        return entries.first
    }

    /// Weather ok end to end: the named-place geocode → forecast happy
    /// path logs ONE weather entry whose response is the hedged live
    /// sentence the user heard.
    func testWeatherOkRecordsExactlyOneEntryWithTheLiveAnswer() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        coordinator.localeOverride = Locale(identifier: "en-US")
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "Kathmandu")))
        let transport = StubLocalToolTransport(
            data: weatherJSON,
            geocodingData: Data(#"{"results": [{"name": "Arncliffe", "latitude": -33.9375,"#.utf8)
                + Data(#" "longitude": 151.1522}]}"#.utf8))
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        locationFetcherFactory: { fetcher },
                                        weatherTransport: transport,
                                        localToolLogStore: logStore)

        _ = router.route(transcript: "is it raining in Arncliffe?")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        XCTAssertEqual(entry.kind, .weather)
        XCTAssertEqual(entry.query, "is it raining in Arncliffe?",
                       "the RAW utterance is the logged query — captured before the request")
        XCTAssertEqual(entry.outcome, "ok")
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: "Arncliffe",
                                    locale: Locale(identifier: "en"))
        XCTAssertEqual(entry.response, L10n.fmt("weather.replySource",
                                                locale: Locale(identifier: "en-US"), raw),
                       "the response is the hedged live sentence the user heard")
        XCTAssertNil(entry.statusCode, "the weather tool does not surface an HTTP status")
        XCTAssertNotNil(entry.durationMs)
    }

    /// Weather failure (location denied → the static no-data line) logs
    /// ONE "fail" entry carrying that honest line.
    func testWeatherFailRecordsExactlyOneEntryWithTheStaticLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .failure(.notAuthorized))
        let transport = StubLocalToolTransport(data: weatherJSON)   // must never be used
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        locationFetcherFactory: { fetcher },
                                        weatherTransport: transport,
                                        localToolLogStore: logStore)

        _ = router.route(transcript: "मौसम कस्तो छ?")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        XCTAssertEqual(entry.kind, .weather)
        XCTAssertEqual(entry.query, "मौसम कस्तो छ?")
        XCTAssertEqual(entry.outcome, "fail")
        XCTAssertEqual(entry.response, TopicPreAnswer.reply(for: .weather, locale: ne),
                       "the response is the honest no-data line the user heard")
        XCTAssertNil(entry.statusCode)
        XCTAssertNotNil(entry.durationMs)
    }

    /// Named place + geocode failure → the live DEVICE reading answers:
    /// still a live answer, but for the wrong place — the log records the
    /// delivery as outcome "fallback" (the bus event stays "ok").
    func testWeatherGeocodeFallbackRecordsOneEntryWithOutcomeFallback() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let fetcher = StubLocationFetcher(result: .success(
            LocationFix(latitude: 27.7172, longitude: 85.3240, placeName: "काठमाडौं")))
        // geocodingData defaults to an empty payload → the geocode parse
        // finds no result (200 OK, nothing matched) → device fallback.
        let transport = StubLocalToolTransport(data: weatherJSON)
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        locationFetcherFactory: { fetcher },
                                        weatherTransport: transport,
                                        localToolLogStore: logStore)

        _ = router.route(transcript: "is it raining in Arncliffe?")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        XCTAssertEqual(entry.kind, .weather)
        XCTAssertEqual(entry.query, "is it raining in Arncliffe?")
        XCTAssertEqual(entry.outcome, "fallback",
                       "a device-location answer to a named-place question is logged as fallback")
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3, wmoCode: 0,
                                                       windKmh: 12.5, humidityPercent: 62)
        let raw = WeatherTool.reply(for: conditions, placeName: "काठमाडौं", locale: ne)
        XCTAssertEqual(entry.response, L10n.fmt("weather.replySource", locale: ne, raw))
        XCTAssertNotNil(entry.durationMs)
    }

    /// Search happy path logs ONE "ok" entry with the summary text and
    /// the 200 the transport returned.
    func testSearchOkRecordsOneEntryWithTheSummaryAndStatus() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let payload = Data("""
        {"items": [
            {"title": "France - Wikipedia",
             "snippet": "France is a country in Western Europe. Its capital is Paris. More here.",
             "link": "https://en.wikipedia.org/wiki/France"}
        ]}
        """.utf8)
        let transport = StubLocalToolTransport(data: payload)
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        searchConfigStore: store,
                                        searchTransport: transport,
                                        localToolLogStore: logStore)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        guard let expectedSummary = SearchTool.summaryReply(
            for: SearchTool.parseSearchJSON(data: payload), locale: ne) else {
            XCTFail("the test fixture must produce a speakable summary")
            return
        }
        XCTAssertEqual(entry.kind, .search)
        XCTAssertEqual(entry.query, "what is the capital of France")
        XCTAssertEqual(entry.outcome, "ok")
        XCTAssertEqual(entry.response, expectedSummary)
        XCTAssertEqual(entry.statusCode, 200,
                       "the HTTP status the transport returned must be recorded")
        XCTAssertNotNil(entry.durationMs)
    }

    /// A capped search day logs ONE "cap" entry carrying the cap line —
    /// no request ever went out.
    func testSearchCapRecordsOneEntryWithTheCapLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let transport = StubLocalToolTransport()   // must never be called
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        searchConfigStore: store,
                                        searchTransport: transport,
                                        localToolLogStore: logStore)
        // Seed today's bucket at the cap (router compares against the
        // current calendar — seed it the same way).
        quotaDefaults.set(SearchQuota.dayStamp(for: Date(), calendar: .current),
                          forKey: SearchQuota.dayKey)
        quotaDefaults.set(SearchQuota.dailyLimit, forKey: SearchQuota.countKey)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        XCTAssertEqual(entry.kind, .search)
        XCTAssertEqual(entry.query, "what is the capital of France")
        XCTAssertEqual(entry.outcome, "cap")
        XCTAssertEqual(entry.response, L10n.str("search.capReached", locale: ne))
        XCTAssertNil(entry.statusCode, "a capped attempt never reached the network")
        XCTAssertNotNil(entry.durationMs)
    }

    /// A failed search (transport error) logs ONE "fail" entry carrying
    /// the honest generic re-prompt.
    func testSearchFailureRecordsOneEntryWithTheReprompt() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key-test")
        store.saveSearchEngineID("cx-test")
        let transport = StubLocalToolTransport(data: Data(), error: URLError(.timedOut))
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        searchConfigStore: store,
                                        searchTransport: transport,
                                        localToolLogStore: logStore)

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        guard let entry = singleEntry(logStore) else { return }
        XCTAssertEqual(entry.kind, .search)
        XCTAssertEqual(entry.outcome, "fail")
        XCTAssertEqual(entry.response, L10n.str("router.reprompt", locale: ne),
                       "the response is the honest re-prompt the user heard")
        XCTAssertNil(entry.statusCode, "a thrown transport error has no HTTP status")
        XCTAssertNotNil(entry.durationMs)
    }

    /// A tool that never fired logs NOTHING: the log follows the
    /// `local_tools` event gating exactly — declined utterances are not
    /// attempts.
    func testDeclinedSearchAttemptLogsNothing() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isOnDeviceStack = true
        let logStore = makeLogStore()
        let (router, _, _) = makeRouter(coordinator,
                                        localToolLogStore: logStore)   // no SearchConfigStore

        _ = router.route(transcript: "what is the capital of France")
        waitForToolDelivery()

        XCTAssertTrue(logStore.entries().isEmpty,
                      "a search the hook declined (no credentials) is not an attempt and logs nothing")
    }
}

/// [LOCAL-TOOLS] (2026-09-07) `LocationFetching` double — fires its
/// completion with a scripted result, synchronously and exactly once.
private final class StubLocationFetcher: LocationFetching {
    private(set) var requestCount = 0
    let result: Result<LocationFix, LocationFetchFailure>

    init(result: Result<LocationFix, LocationFetchFailure>) {
        self.result = result
    }

    func requestCurrentLocation(completion: @escaping (Result<LocationFix, LocationFetchFailure>) -> Void) {
        requestCount += 1
        completion(result)
    }
}

/// [LOCAL-TOOLS] (2026-09-07) `LocalToolTransport` double — records every
/// request it is handed and answers with scripted data/status/error. No
/// network: the router's fetch seam is exercised end to end through it.
///
/// [WEATHER-ROUTING] (2026-09-07) A named-place weather turn performs TWO
/// round-trips (geocode, then forecast), so the stub answers per host:
/// requests to `geocoding-api.open-meteo.com` get `geocodingData`/
/// `geocodingStatusCode`; everything else gets `data`/`statusCode`. The
/// geocoding defaults (empty payload, 200) make the geocode parse fail —
/// preserving the pre-geocode behavior for tests that do not script one
/// (the router then falls back to the device location).
private final class StubLocalToolTransport: LocalToolTransport {
    private(set) var capturedRequests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int
    private let error: Error?
    private let geocodingData: Data
    private let geocodingStatusCode: Int

    init(data: Data = Data(), statusCode: Int = 200, error: Error? = nil,
         geocodingData: Data = Data(), geocodingStatusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
        self.error = error
        self.geocodingData = geocodingData
        self.geocodingStatusCode = geocodingStatusCode
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        if let error { throw error }
        let isGeocoding = request.url?.host == "geocoding-api.open-meteo.com"
        let payload = isGeocoding ? geocodingData : data
        let code = isGeocoding ? geocodingStatusCode : statusCode
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.local")!,
                                       statusCode: code,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (payload, response)
    }
}

// MARK: - Voice-driven directions stage (directions task, 2026-09-07)

/// Wiring of the deterministic directions stage: `DirectionsRoute` decides
/// after the safety net, confirmation flow and contact search, and before
/// the topic table + interpreter; the coordinator receives the resolved
/// target, an ambiguous name match becomes a yes/no question (never a
/// guessed place), and an unknown name gets the honest fallback line.
/// Ordering proofs: emergency, contact search and a pending yes/no answer
/// all win over a directions marker, and a transport verb without
/// navigation shape ("म बजार जान्छु") never routes.
final class CommandRouterDirectionsTests: XCTestCase {

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator)
        -> (CommandRouter, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker())
        return (router, bus)
    }

    /// Resolves a catalog key exactly as the router does (hosted tests:
    /// Bundle.main is the app, so lproj lookup works) — deterministic
    /// twin of the spoken/visible lines.
    private func text(_ key: String) -> String {
        L10n.str(key, locale: Locale(identifier: "ne-NP"))
    }

    private func place(id: UUID, name: String) -> DirectionsCandidate {
        DirectionsCandidate(id: id, source: .savedPlace, name: name,
                            address: "काठमाडौं", relationship: nil)
    }

    private func relative(id: UUID, name: String, relationship: String)
        -> DirectionsCandidate {
        DirectionsCandidate(id: id, source: .familyContact, name: name,
                            address: "बूढानीलकण्ठ", relationship: relationship)
    }

    // MARK: - Navigate

    /// "मलाई घर लैजाऊ" needs NO candidate list — the bare-home
    /// destination resolves to `.defaultHome` and the COORDINATOR decides
    /// what home is (and speaks the honest no-home line when none is on
    /// file). Never small talk, never an interpreter question.
    func testBareHomeTakeMeHomeRoutesDefaultHome() {
        let coordinator = MockVoiceCommandCoordinator()   // no candidates
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "मलाई घर लैजाऊ")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.defaultHome])
        XCTAssertTrue(coordinator.genericReplies.isEmpty,
                      "a routed request speaks nothing here — the coordinator owns execution speech")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "directions_command" && $0.outcome == "success"
        })
    }

    /// "अस्पताल लैजाऊ" against a saved place named अस्पताल resolves to
    /// that place's id — the coordinator's execution target.
    func testSavedPlaceByNameRoutesItsPlaceTarget() {
        let coordinator = MockVoiceCommandCoordinator()
        let hospital = UUID()
        coordinator.navigationCandidates = [place(id: hospital, name: "अस्पताल")]
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "अस्पताल लैजाऊ")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.place(hospital)])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "directions_command" && $0.outcome == "success"
        })
    }

    /// The GO family fires with a home word: "घर जानुहोस्" is a
    /// navigation request even though it carries no TAKE verb.
    func testGoHomePhraseRoutesDefaultHome() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "घर जानुहोस्")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.defaultHome])
    }

    /// Relationship-anchored navigation: "छोरीको घर लैजाऊ" resolves to
    /// the daughter's stored address through the relationship tier, not
    /// through her name.
    func testRelationshipAnchorRoutesContactHome() {
        let coordinator = MockVoiceCommandCoordinator()
        let sita = UUID()
        coordinator.navigationCandidates = [relative(id: sita, name: "सीता",
                                                     relationship: "छोरी")]
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "छोरीको घर लैजाऊ")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.familyContact(sita)])
    }

    /// A greeting-prefixed navigation request is navigation, not small
    /// talk — the stage sits before the TopicPreAnswer table.
    func testGreetingPrefixedTakeMeHomeIsNavigationNotSmallTalk() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "नमस्ते, मलाई घर लैजाऊ")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.defaultHome])
        XCTAssertTrue(coordinator.genericReplies.isEmpty,
                      "no greeting reply may shadow the navigation request")
    }

    /// English "take me home" — same default-home resolution.
    func testEnglishTakeMeHomeRoutesDefaultHome() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "take me home")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.navigationRequests, [.defaultHome])
    }

    // MARK: - Ordering (what wins over a directions marker)

    /// A contact-search request that happens to carry home/direction
    /// words ("मैयाको घरको बाटो खोज") is a SEARCH — the contact-search
    /// stage runs before the directions stage, and the directions
    /// decision vetoes खोज markers anyway. Never both.
    func testSearchShapedUtteranceNeverReachesDirectionsStage() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "मैयाको घरको बाटो खोज")

        XCTAssertEqual(result, .contactSearchRequested)
        XCTAssertEqual(coordinator.contactSearchRequests, ["मैया घर बाटो"])
        XCTAssertTrue(coordinator.navigationRequests.isEmpty)
        XCTAssertTrue(coordinator.navigationDisambiguationRequests.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "contact_search_command" })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "directions_command" })
    }

    /// Emergency outranks a directions marker — "मद्दत गर्नुहोस्, मलाई
    /// घर लैजाऊ" is a distress call, never a drive (constitution: never
    /// blocked, by anything, ever).
    func testEmergencyOutranksNavigationMarker() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "मद्दत गर्नुहोस्, मलाई घर लैजाऊ")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(coordinator.navigationRequests.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_emergency_keyword" })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "directions_command" })
    }

    /// A plain statement with a transport-shaped word but no request
    /// shape ("म बजार जान्छु" = I go to the market) is not directions —
    /// no requestNavigation, no disambiguation, no directions event.
    func testGoingToMarketStatementIsNotDirections() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "म बजार जान्छु")

        XCTAssertNotEqual(result, .navigationRequested)
        XCTAssertTrue(coordinator.navigationRequests.isEmpty)
        XCTAssertTrue(coordinator.navigationDisambiguationRequests.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "directions_command" })
    }

    // MARK: - Honest fallbacks

    /// A directions-shaped request whose name matches nothing speaks the
    /// honest "place not found" line (visible card + speech) and never
    /// routes onward to a model — the stage OWNS the outcome.
    func testUnknownPlaceSpeaksHonestFallbackLine() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "गाउँ लैजाऊ")

        XCTAssertEqual(result, .unrecognised(transcript: "गाउँ लैजाऊ"))
        XCTAssertTrue(coordinator.navigationRequests.isEmpty)
        let expected = text("directions.placeNotFound")
        XCTAssertEqual(coordinator.genericReplies, [expected],
                       "the visible outcome card must carry the honest fallback")
        XCTAssertEqual(coordinator.assistantSpoken, [expected],
                       "the fallback must also be spoken")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "directions_command" && $0.outcome == "unknown_place"
        })
    }

    /// Two candidates too close to call become a yes/no question — the
    /// coordinator is asked (with the top candidate first), the returned
    /// question is spoken, and NO place is guessed. The pending walk then
    /// resolves through the confirmation path.
    func testAmbiguousMatchAsksInsteadOfGuessing() {
        let coordinator = MockVoiceCommandCoordinator()
        let first = UUID()
        let second = UUID()
        coordinator.navigationCandidates = [
            relative(id: first, name: "मैया", relationship: "दिदी"),
            relative(id: second, name: "मैया", relationship: "बहिनी")
        ]
        coordinator.navigationDisambiguationPrompt = "कुन मैया लैजाने?"
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "मैयाको घर लैजाऊ")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertTrue(coordinator.navigationRequests.isEmpty,
                      "a disambiguation ask is not an execution — no target is chosen")
        XCTAssertEqual(coordinator.navigationDisambiguationRequests.count, 1)
        XCTAssertEqual(coordinator.navigationDisambiguationRequests.first?.map(\.id),
                       [first, second],
                       "the ask must be answered by the user, top candidate first")
        XCTAssertEqual(coordinator.assistantSpoken, ["कुन मैया लैजाने?"],
                       "the coordinator's question is spoken verbatim")
        XCTAssertTrue(coordinator.genericReplies.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "directions_disambiguation" && $0.outcome == "info"
        })
    }

    // MARK: - The pending-walk confirmation path

    /// YES during a pending disambiguation resolves the walk through
    /// `handleConfirmationResponse` — it must NOT re-enter the directions
    /// stage (no fresh requestNavigation) and must not speak the generic
    /// medication-flavored "confirmationYes" line.
    func testYesDuringPendingDisambiguationNeverReEntersDirectionsStage() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isAwaitingConfirmation = true
        coordinator.isAwaitingNavigationDisambiguation = true
        let speaker = MockSpeaker()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker)

        let result = router.route(transcript: "हजुर")

        XCTAssertEqual(result, .navigationRequested)
        XCTAssertEqual(coordinator.confirmationResponses, [.yes])
        XCTAssertTrue(coordinator.navigationRequests.isEmpty,
                      "resolving the walk is handleConfirmationResponse's business — never a new route()")
        XCTAssertTrue(coordinator.assistantSpoken.isEmpty,
                      "CommandRouter must not speak — the coordinator owns the walk's response")
        XCTAssertTrue(speaker.utterances.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "confirmation_yes" })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "directions_command" })
    }

    /// NO during a pending disambiguation cancels the walk — the
    /// coordinator speaks its own `directions.cancelled` (or walks to the
    /// next candidate), so the router stays silent and reports the
    /// utterance as consumed.
    func testNoDuringPendingDisambiguationCancelsSilently() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isAwaitingConfirmation = true
        coordinator.isAwaitingNavigationDisambiguation = true
        let speaker = MockSpeaker()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker)

        let result = router.route(transcript: "होइन")

        XCTAssertEqual(result, .unrecognised(transcript: "होइन"))
        XCTAssertEqual(coordinator.confirmationResponses, [.no])
        XCTAssertTrue(coordinator.navigationRequests.isEmpty)
        XCTAssertTrue(coordinator.assistantSpoken.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "confirmation_no" })
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "directions_command" })
    }
}

// MARK: - [ALARMS-TIMERS] Alarm + timer voice stage

/// Wiring of the deterministic alarms/timers stage (2026-09-07): parse
/// happens BEFORE the topic table and interpreter; the coordinator
/// receives the resolved request; the router speaks the
/// outcome-dependent line; observability lands under component
/// "alarms_timers" at resolution. (2026-09-08) Plus the synchronous
/// OFF/SNOOZE branches checked after the set parses: the coordinator
/// receives the turn-off/snooze request, the router speaks the honest
/// outcome (confirmation with the spoken time, the "no alarms" line, or
/// the failure fallback), and unsanctioned shapes fall through with no
/// "alarms_timers" events at all.
final class CommandRouterAlarmTimerTests: XCTestCase {

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator)
        -> (CommandRouter, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker())
        return (router, bus)
    }

    /// [REGRESSION-AUDIT] (2026-09-10) Bounded WAIT (1 ms poll, ≤5 s)
    /// for the alarm/timer permission round-trip to commit its reply.
    /// The set handlers dispatch a non-isolated Task whose `await` on
    /// the async coordinator protocol is a two-hop executor chain — a
    /// single `Task.yield()` (or even 500 bare yields, which complete in
    /// under the handler's ~100 µs round trip on this simulator) returns
    /// before the commit, which is why six routing + permission-fallback
    /// tests failed deterministically at the a74f8d5 gate (born with the
    /// alarms stage in 3b6c9a9 — the handlers are byte-identical across
    /// the whole turn-timing / script-regression window, so those hooks
    /// did not cause it). Assertions in each test are unchanged; only
    /// the await is disciplined.
    private func awaitReplyCommit(
        _ router: CommandRouter,
        _ coordinator: MockVoiceCommandCoordinator,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        var waited: UInt64 = 0
        while (coordinator.genericReplies.isEmpty || router.isTurnReplyPending)
            && waited < 5_000_000_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            waited += 1_000_000
        }
        XCTAssertFalse(coordinator.genericReplies.isEmpty,
                       "the alarm/timer reply never committed",
                       file: file, line: line)
        XCTAssertFalse(router.isTurnReplyPending,
                       "the turn resolved only after the reply was committed",
                       file: file, line: line)
    }

    private var en: Locale { Locale(identifier: "en-US") }

    func testEnglishAlarmCommandReachesCoordinatorAndConfirms() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "set an alarm for 6 am")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(result, .unrecognised(transcript: "set an alarm for 6 am"))
        XCTAssertEqual(coordinator.alarmSetRequests.count, 1)
        XCTAssertEqual(coordinator.alarmSetRequests[0].label, nil)
        let components = Calendar.current.dateComponents(
            [.hour, .minute], from: coordinator.alarmSetRequests[0].time)
        XCTAssertEqual(components.hour, 6)
        XCTAssertEqual(components.minute, 0)
        XCTAssertTrue(coordinator.genericReplies.contains { $0 == "Alarm set for 6 am." },
                      "spoken confirmation embeds the resolved time, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_set"
                && $0.outcome == "success"
        })
    }

    func testEnglishPeriodAdjustmentEveningAlarm() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set an alarm for 8 in the evening")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(coordinator.alarmSetRequests.count, 1)
        let components = Calendar.current.dateComponents(
            [.hour, .minute], from: coordinator.alarmSetRequests[0].time)
        XCTAssertEqual(components.hour, 20, "8 in the evening must resolve to 8 pm")
        XCTAssertEqual(components.minute, 0)
    }

    func testWakeMarkerRoutesAsAlarm() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "बिहान ६ बजे उठाउनुहोस्")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(coordinator.alarmSetRequests.count, 1)
        let components = Calendar.current.dateComponents(
            [.hour, .minute], from: coordinator.alarmSetRequests[0].time)
        XCTAssertEqual(components.hour, 6)
        XCTAssertEqual(components.minute, 0)
    }

    func testBareWakeInfinitiveIsNotAnAlarmCommand() async {
        // Golden-corpus guard: "बिहान ६ बजे उठाउनु" is the reminder
        // corpus's set_reminder utterance — the alarms stage must NOT
        // steal it (only the honorific do-for-me wake markers are alarm
        // commands).
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "बिहान ६ बजे उठाउनु")
        await Task.yield()

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "alarms_timers" })
    }

    func testThirdPersonWakeRequestIsNotAnAlarmCommand() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "wake my grandson at 7")
        await Task.yield()

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "alarms_timers" })
    }

    func testAlarmQuestionIsNotSwallowedByTheStage() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "when is my alarm set?")
        await Task.yield()

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "alarms_timers" },
                       "questions fall through the stage unchanged")
    }

    func testPermissionDeniedSpeaksTheHonestFallback() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmSetOutcome = .permissionDenied
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "set an alarm for 6 am")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.hasPrefix("Notifications are off")
        }, "denial must be spoken honestly, never a false 'alarm set'")
        XCTAssertFalse(coordinator.genericReplies.contains { $0.contains("Alarm set for") })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_set"
                && $0.outcome == "permission_denied"
        })
    }

    func testAtCapacitySpeaksTheDeleteFirstFallback() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmSetOutcome = .atCapacity
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set an alarm for 6 am")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.genericReplies.contains { $0.hasPrefix("Too many alarms") })
    }

    func testNepaliTimerCommandReachesCoordinatorAndConfirms() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "टाइमर ५ मिनेट")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(result, .unrecognised(transcript: "टाइमर ५ मिनेट"))
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.contains("टाइमर सुरु भयो")
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testEnglishTimerCommandReachesCoordinator() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set a timer for 10 minutes")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 600)
        XCTAssertTrue(coordinator.timerStartRequests[0].label == nil)
        XCTAssertTrue(coordinator.genericReplies.contains { $0 == "Timer started for 10 minutes." })
    }

    func testAlarmWordedCountdownRoutesAsTimerNotAlarm() async {
        // Doctrine extension (2026-09-10): "set an alarm in 5 minutes"
        // is an alarm-worded COUNTDOWN — unambiguous "ring me in N"
        // intent. The timer parse claims it: a 300 s timer starts and
        // it must NEVER become a time-of-day alarm.
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "set an alarm in 5 minutes")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty,
                      "countdown phrasings must never become an alarm")
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertTrue(coordinator.genericReplies.contains { $0 == "Timer started for 5 minutes." },
                      "the confirmation speaks the timer, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testTimerOutOfBoundsFallsThroughTheStage() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set a timer for 25 hours")
        await Task.yield()

        XCTAssertTrue(coordinator.timerStartRequests.isEmpty,
                      "an out-of-range duration must never be confirmed")
    }

    // MARK: - [NUMBER-WORDS] number-word forms (2026-09-10)

    func testNepaliNumberWordTimerRoutesToCoordinator() async {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "टाइमर पाँच मिनेट")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(result, .unrecognised(transcript: "टाइमर पाँच मिनेट"))
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.contains("टाइमर सुरु भयो")
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testUserPhrasePanchMinutKoAlarmLagaauSetsAFiveMinuteTimer() async {
        // The user-reported phrase, end to end: "पांच मिनुटको अलार्म
        // लगाऊ" ("set a 5-minute alarm") must START A 5-MINUTE TIMER —
        // number-word normalization + the मिनुट unit + the alarm-worded
        // countdown doctrine make the coordinator receive 300 s and the
        // confirmation speak. Never a 5 o'clock alarm.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "पांच मिनुटको अलार्म लगाऊ")
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(result, .unrecognised(transcript: "पांच मिनुटको अलार्म लगाऊ"))
        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty,
                      "a 5-minute alarm is a countdown — never a 5 o'clock alarm")
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertNil(coordinator.timerStartRequests[0].label)
        XCTAssertTrue(coordinator.genericReplies.contains { $0.contains("टाइमर सुरु भयो") },
                      "the confirmation speaks the timer, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testBareClockAlarmPhraseStaysAnAlarm() async {
        // Safety net for the doctrine extension: a clock phrase has no
        // duration unit — "५ बजेको अलार्म लगाऊ" stays a time-of-day
        // alarm, never a timer.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "५ बजेको अलार्म लगाऊ")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.timerStartRequests.isEmpty,
                      "a bare clock phrase must never become a timer")
        XCTAssertEqual(coordinator.alarmSetRequests.count, 1)
        let components = Calendar.current.dateComponents(
            [.hour, .minute], from: coordinator.alarmSetRequests[0].time)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 0)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_set"
                && $0.outcome == "success"
        })
    }

    func testUserSpokenPhrasePanchMinetTimerLagaauTaRoutesAsTimer() async {
        // The user's natural-speech form: "पाँच मिनेट टाइमर लगाऊ त"
        // ("set a 5-minute timer, okay") — informal verb spelling plus
        // the emphasis particle must route exactly like the canonical
        // form: a 300 s timer with a clean label, never an alarm.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "पाँच मिनेट टाइमर लगाऊ त")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty)
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertNil(coordinator.timerStartRequests[0].label)
        XCTAssertTrue(coordinator.genericReplies.contains { $0.contains("टाइमर सुरु भयो") },
                      "the confirmation speaks the timer, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testDeviceTranscriptPanchMinekoTimerLagaunRoutesAsTimer() async {
        // Real-device whisper transcript, end to end: spoken "पाँच
        // मिनेट टाइमर लगाऊ त" transcribed as "पाँच मिनेको टाइमर लगाउँ"
        // — the मिने unit variant and the nasalized verb must reach the
        // coordinator as a 300 s timer with a clean label, never an
        // alarm.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "पाँच मिनेको टाइमर लगाउँ")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty)
        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertEqual(coordinator.timerStartRequests[0].durationSeconds, 300)
        XCTAssertNil(coordinator.timerStartRequests[0].label)
        XCTAssertTrue(coordinator.genericReplies.contains { $0.contains("टाइमर सुरु भयो") },
                      "the confirmation speaks the timer, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "success"
        })
    }

    func testTimerPermissionDeniedSpeaksTheTimerFallback() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.timerStartOutcome = .permissionDenied
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "टाइमर ५ मिनेट")
        await awaitReplyCommit(router, coordinator)

        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.hasPrefix("Notifications are off")
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "permission_denied"
        })
    }

    // MARK: - OFF + SNOOZE branches (2026-09-08)

    private func enDate(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: hour, minute: minute
        ))!
    }

    func testEnglishAlarmOffRoutesToCoordinatorAndConfirms() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmOffOutcome = .disabled(time: enDate(6, 0))
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "turn off the alarm")

        XCTAssertEqual(result, .unrecognised(transcript: "turn off the alarm"))
        XCTAssertEqual(coordinator.alarmOffRequestCount, 1)
        XCTAssertTrue(coordinator.alarmSetRequests.isEmpty,
                      "an OFF command must never SET an alarm")
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0 == "Alarm for 6 am is turned off."
        }, "the confirmation names the alarm's spoken time, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_off"
                && $0.outcome == "success"
        })
    }

    func testNepaliAlarmOffRoutesToCoordinator() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.alarmOffOutcome = .disabled(time: enDate(6, 0))
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "अलार्म बन्द गर")

        XCTAssertEqual(coordinator.alarmOffRequestCount, 1)
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.contains("अलार्म बन्द भयो")
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_off"
                && $0.outcome == "success"
        })
    }

    func testAlarmOffNoAlarmSpeaksTheNoAlarmsLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmOffOutcome = .noAlarm
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "turn off the alarm")

        XCTAssertEqual(coordinator.alarmOffRequestCount, 1)
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0 == "You don't have any alarms set."
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_off"
                && $0.outcome == "no_alarm"
        })
    }

    func testAlarmOffFailureSpeaksTheHonestFallback() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmOffOutcome = .failed
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "turn off the alarm")

        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.hasPrefix("Sorry — I couldn't turn off the alarm")
        })
        XCTAssertFalse(coordinator.genericReplies.contains { $0.contains("turned off.") },
                       "a failed off must never sound like a confirmation")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_off"
                && $0.outcome == "failed"
        })
    }

    func testTimeQualifiedCancellationFallsThroughTheStage() {
        // "cancel the 6 am alarm" names a specific alarm — the off branch
        // must not guess which one; the utterance falls through unchanged.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "cancel the 6 am alarm")

        XCTAssertEqual(coordinator.alarmOffRequestCount, 0)
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "alarms_timers" })
    }

    func testSnoozeRoutesParsedMinutesAndConfirmsSpokenUntilTime() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmSnoozeOutcome = .snoozed(until: enDate(10, 15))
        let (router, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "snooze for 15 minutes")

        XCTAssertEqual(result, .unrecognised(transcript: "snooze for 15 minutes"))
        XCTAssertEqual(coordinator.alarmSnoozeRequests, [15])
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0 == "Snoozed until 10:15 am."
        }, "the confirmation embeds the SPOKEN re-wake time, got \(coordinator.genericReplies)")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_snoozed"
                && $0.outcome == "success"
        })
    }

    func testBareSnoozeUsesTheParserDefaultMinutes() {
        let coordinator = MockVoiceCommandCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "स्नुज गर")

        XCTAssertEqual(coordinator.alarmSnoozeRequests, [10])
    }

    func testSnoozeNoAlarmSpeaksTheNoAlarmsLine() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmSnoozeOutcome = .noAlarm
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "snooze")

        XCTAssertEqual(coordinator.alarmSnoozeRequests, [10])
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0 == "You don't have any alarms set."
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_snoozed"
                && $0.outcome == "no_alarm"
        })
    }

    func testSnoozeFailureSpeaksTheHonestFallback() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmSnoozeOutcome = .failed
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "snooze")

        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.hasPrefix("Sorry — I couldn't snooze the alarm")
        })
        XCTAssertFalse(coordinator.genericReplies.contains { $0.contains("Snoozed until") },
                       "a failed snooze must never sound like a confirmation")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_snoozed"
                && $0.outcome == "failed"
        })
    }

    func testSnoozeTheTimerFallsThroughTheStage() {
        // Timer business, not an alarm re-wake — the parser declines and
        // the utterance falls through unchanged.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "snooze the timer")

        XCTAssertTrue(coordinator.alarmSnoozeRequests.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.component == "alarms_timers" })
    }

    // MARK: - REGRESSION-AUDIT (2026-09-10): async-dispatch reply hold

    /// Six routing + permission-fallback tests above failed
    /// deterministically at the a74f8d5 full gate: the alarm/timer set
    /// handlers dispatched a non-isolated Task and never marked the turn
    /// reply-pending, so `route()` returned with the pipeline free to
    /// resume wake listening while the notification-permission round-trip
    /// was still in flight (born with the alarms stage in 3b6c9a9 — the
    /// handlers are byte-identical across the turn-timing / script-
    /// regression window, so those hooks were innocent). The fix holds
    /// the turn exactly like the LLM path. This test pins it and FAILS
    /// on the broken commit (`isTurnReplyPending` was false at return).
    func testAlarmRoutingSurvivesTimingHooks() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        let bus = MockObservabilityBus()
        // Constructed WITH the turn-timing tracer: the hooks must be
        // inert for routing (the original suspicion was the TURN-TIMING
        // commit's hooks — they are nil-safe and did not cause the six
        // failures).
        let tracer = VoiceTurnLatencyTracer(observabilityBus: bus)
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   turnTracer: tracer)

        // [FLAKE-PIN] (2026-09-11) The hold pin moved off the synchronous
        // read of `isTurnReplyPending`. Reading the flag right after
        // `route()` returned raced the handler's non-isolated Task: on
        // iOS 18.3 the executor can run the mock round-trip to completion
        // — committing the reply and clearing the flag — before the
        // assert executes, so this test failed intermittently on 18.3
        // while always passing on 26.5 (pre-existing on origin/master).
        // The pin is unchanged — the turn is held during the alarm
        // round-trip — but it is observed through the router's resolve
        // callback, registered BEFORE `route()`: it fires only when a
        // marked hold is released (`resolveTurnReplyPending`'s guard), so
        // on the broken commit (no hold marked) it never fires and this
        // test still fails. `awaitReplyCommit` keeps the bounded-wait
        // poll of the flag itself (1 ms poll, ≤5 s) and pins that the
        // turn resolved only after the reply was committed.
        var turnWasHeld = false
        router.onTurnReplyResolved = { turnWasHeld = true }

        let result = router.route(transcript: "set an alarm for 6 am")

        XCTAssertEqual(result, .unrecognised(transcript: "set an alarm for 6 am"))
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(coordinator.alarmSetRequests.count, 1)
        XCTAssertTrue(coordinator.genericReplies.contains { $0 == "Alarm set for 6 am." })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "alarm_set"
                && $0.outcome == "success"
        })
        XCTAssertFalse(router.isTurnReplyPending,
                       "the turn resolves only after the reply was committed")
        XCTAssertTrue(turnWasHeld,
                      "the alarm round-trip must hold the pipeline like the LLM path")
    }

    /// The timer twin of `testAlarmRoutingSurvivesTimingHooks` — including
    /// the permission-denied path (the "permission fallbacks" half of the
    /// a74f8d5 incident).
    func testTimerRoutingSurvivesTimingHooksIncludingDenial() async {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.timerStartOutcome = .permissionDenied
        let bus = MockObservabilityBus()
        let tracer = VoiceTurnLatencyTracer(observabilityBus: bus)
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   turnTracer: tracer)

        let result = router.route(transcript: "टाइमर ५ मिनेट")

        XCTAssertEqual(result, .unrecognised(transcript: "टाइमर ५ मिनेट"))
        XCTAssertTrue(router.isTurnReplyPending)
        await awaitReplyCommit(router, coordinator)

        XCTAssertEqual(coordinator.timerStartRequests.count, 1)
        XCTAssertTrue(coordinator.genericReplies.contains {
            $0.hasPrefix("Notifications are off")
        })
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "alarms_timers" && $0.eventType == "timer_started"
                && $0.outcome == "permission_denied"
        })
        XCTAssertFalse(router.isTurnReplyPending)
    }

    /// The synchronous off/snooze branches commit inside `route()` and
    /// must never hold the token — the fix must not leak the pending
    /// hold into the synchronous handlers.
    func testAlarmOffAndSnoozeRemainSynchronousAndNeverHoldTheTurn() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.localeOverride = en
        coordinator.alarmOffOutcome = .disabled(time: enDate(6, 0))
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "turn off the alarm")

        XCTAssertEqual(coordinator.alarmOffRequestCount, 1)
        XCTAssertFalse(router.isTurnReplyPending,
                       "off is synchronous — the turn must not stay pending")
    }
}

// MARK: - REST-DIP-FIX (2026-09-08): the turn-pending token

/// Router-side pins for the no-rest-dip fix. The user-visible guarantee —
/// the UI session never drops to rest between "understanding" and the
/// reply this same turn produces — is enforced by VoicePipeline: it reads
/// `CommandRouter.isTurnReplyPending` right after `route()` returns and
/// DEFERS its return to `.idle` while the token is set (the session holds
/// "understanding"), releasing only when the token clears or the safety
/// timeout falls back to today's behavior. These tests pin the token
/// contract the pipeline defers on:
///
///  - a turn handed to the async LLM interpreter stays pending from
///    `route()` returning until the interpret completion commits the
///    reply — for BOTH outcomes (abstention → re-prompt, and a routed
///    command → spoken reply);
///  - the reply speech is committed BEFORE the token clears, so its
///    speech-start hop precedes the pipeline's deferred idle hop on the
///    main queue (the FIFO ordering the no-rest guarantee rests on);
///  - turns whose reply is committed synchronously inside `route()`
///    (deterministic stages, or a synchronous interpreter completion —
///    instant-STT shapes) never hold the token, so the pipeline returns
///    to idle immediately exactly as before — the session mapping
///    (speakingCount > 0 → `.speaking`) then keeps it off rest.
///
/// The VoicePipeline half — the deferral, its generation-guarded release,
/// and the 35 s safety timeout — has no unit harness (concrete
/// AVAudioEngine/AudioSessionManager deps); those pins live in the
/// pipeline implementation and are exercised by the main-checkout build.
final class CommandRouterTurnHoldingTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator,
                            interpreter: CommandInterpreter)
        -> (CommandRouter, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   interpreter: interpreter)
        return (router, bus)
    }

    /// A plain request that clears every deterministic stage (safety net,
    /// confirmation, contact search, directions, alarms/timers, briefing,
    /// topic table, calculator) so routing hands the turn to the LLM
    /// interpreter — the async path the rest dip came from.
    private let llmBoundTranscript = "मलाई एउटा कथा सुनाउनुहोस्"

    private func queryCommand(reply: String) -> InterpretedCommand {
        InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil,
            pluginEntities: nil, confidence: 0.9, reply: reply)
    }

    /// (a) An unrecognised transcript (the interpreter ABSTAINS → the
    /// re-prompt fallback) must keep the turn pending from `route()`
    /// returning until the abstention completion has committed the
    /// re-prompt speech — the pipeline therefore holds "understanding"
    /// across the whole window instead of dropping to rest, and releases
    /// only after the reply's speech-start hop was enqueued.
    func testUnrecognisedTranscriptKeepsTurnPendingUntilFallbackReplyIsCommitted() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = HoldableCommandInterpreter()
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        let result = router.route(transcript: llmBoundTranscript)

        XCTAssertEqual(result, .unrecognised(transcript: llmBoundTranscript))
        XCTAssertEqual(interpreter.interpretCallCount, 1)
        // The model is still "thinking" — nothing spoken, turn pending:
        // the pipeline must NOT return to idle here (that was the dip).
        XCTAssertTrue(router.isTurnReplyPending,
                      "the turn must stay pending while the interpreter round-trip is outstanding")
        XCTAssertTrue(coordinator.assistantSpoken.isEmpty,
                      "no reply speech may exist while the turn is pending")

        // The completion lands: the brain abstained → the router commits
        // the re-prompt fallback and only then resolves the turn.
        interpreter.completeNext(with: nil)

        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)])
        XCTAssertEqual(coordinator.speakingStarts, 1,
                       "the fallback reply speech must be committed by the time the turn resolves")
        XCTAssertFalse(router.isTurnReplyPending,
                       "the turn resolves only after the reply speech was committed")
    }

    /// (b) A transcript routed through the LLM must never release the
    /// pipeline to idle while the model thinks — the token stays set from
    /// `route()` returning until the interpreted command's reply speech
    /// is committed.
    func testLlmRoutedTranscriptKeepsTurnPendingWhileTheModelThinks() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = HoldableCommandInterpreter()
        let modelReply = "कथाको सुरुवात: एक देशमा एउटा बूढो बाबा थिए।"
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: llmBoundTranscript)

        // The model is thinking — the session must hold "understanding".
        XCTAssertTrue(router.isTurnReplyPending)
        XCTAssertTrue(coordinator.assistantSpoken.isEmpty)

        interpreter.completeNext(with: queryCommand(reply: modelReply))

        // The reply was spoken, and the turn resolved only after the
        // commit (speech-start hop precedes the deferred idle hop).
        XCTAssertEqual(coordinator.assistantSpoken.first, modelReply)
        XCTAssertEqual(coordinator.speakingStarts, 1)
        XCTAssertFalse(router.isTurnReplyPending)
    }

    /// (c) Instant-STT shapes: a SYNCHRONOUS interpreter completion (the
    /// test fakes' shape) commits the fallback reply inside `route()`
    /// itself, so the token is already clear when `route()` returns —
    /// the pipeline returns to idle immediately, and the session mapping
    /// (the reply's speech-start hop already precedes the idle hop) keeps
    /// it on `.speaking`, never rest. The pipeline's visible path
    /// (`.transcribing` → `.understanding` → `.speaking`) is the
    /// `.processing`-before-`.routing` guard's half of the fix.
    func testSynchronousInterpreterCompletionNeverHoldsTheTurn() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = nil   // abstains → re-prompt, all inside route()
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        let result = router.route(transcript: llmBoundTranscript)

        XCTAssertEqual(result, .unrecognised(transcript: llmBoundTranscript))
        XCTAssertFalse(router.isTurnReplyPending,
                       "a synchronously-answered turn must not hold the pipeline")
        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)],
                       "the fallback was committed synchronously inside route()")
        XCTAssertEqual(coordinator.speakingStarts, 1)
    }

    /// (c) Deterministic-stage turns (topic pre-answer here) speak
    /// synchronously inside `route()` and must never hold the token —
    /// the pipeline returns to idle exactly as before; no artificial
    /// busy-hold for speech that is already committed.
    func testDeterministicStageTurnNeverHoldsTheTurn() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        let result = router.route(transcript: "अहिले कति बजेको छ?")

        XCTAssertEqual(result, .unrecognised(transcript: "अहिले कति बजेको छ?"))
        XCTAssertEqual(interpreter.interpretCallCount, 0,
                       "the topic table answers without the interpreter")
        XCTAssertFalse(router.isTurnReplyPending)
        XCTAssertEqual(coordinator.speakingStarts, 1,
                       "the topic reply was committed synchronously inside route()")
    }

    /// (d) Safety-timeout precondition: a turn whose interpreter
    /// completion NEVER fires keeps the token set (the router never
    /// resolves on its own — it cannot know the dispatch died). The
    /// PIPELINE's 35 s safety timeout is the fallback that then returns
    /// it to idle / wake listening — today's behavior — for such a turn.
    func testTurnWhoseCompletionNeverFiresStaysPendingForTheSafetyTimeout() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = HoldableCommandInterpreter()
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: llmBoundTranscript)

        // No completion is ever fired — the token must remain set: only
        // the pipeline's bounded safety timeout (not the router) may
        // release a dead turn, so a wedged interpreter can never silently
        // strand the pipeline in a busy state past that bound.
        XCTAssertTrue(router.isTurnReplyPending)
        XCTAssertTrue(coordinator.assistantSpoken.isEmpty)
    }
}
