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

    var activeLocale: Locale { Locale(identifier: "ne-NP") }

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

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) {}
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
