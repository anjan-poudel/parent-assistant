import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// Covers the shared prompt builder used by BOTH `GeminiCommandInterpreter`
/// and `LlamaCommandInterpreter` (see `IntentPrompt`). These are prompt-text
/// assertions, not a substitute for the live-API verification done against
/// the real Gemini endpoint before this change shipped — but they guard
/// against silent regressions to the specific guidance that live testing
/// caught problems with.
final class IntentPromptTests: XCTestCase {

    private func build(transcript: String = "test transcript",
                       meds: [String] = [],
                       languageHint: String = "ne") -> String {
        IntentPrompt.build(
            transcript: transcript,
            context: InterpreterContext(pendingMedications: meds, userLanguageHint: languageHint)
        )
    }

    // MARK: - Interpolation

    func testIncludesTranscriptVerbatim() {
        let prompt = build(transcript: "छोरालाई फोन गर")
        XCTAssertTrue(prompt.contains("छोरालाई फोन गर"))
    }

    func testIncludesPendingMedicationsWhenPresent() {
        let prompt = build(meds: ["प्रेसरको औषधि", "मधुमेहको औषधि"])
        XCTAssertTrue(prompt.contains("प्रेसरको औषधि, मधुमेहको औषधि"))
    }

    func testShowsNoneWhenNoPendingMedications() {
        let prompt = build(meds: [])
        XCTAssertTrue(prompt.contains("(none)"))
    }

    func testIncludesLanguageHint() {
        let prompt = build(languageHint: "en")
        XCTAssertTrue(prompt.contains("language hint is: en"))
    }

    // MARK: - Required JSON fields (STRUCTURED-RESPONSE CONTRACT, 2026-09-06)
    //
    // The brain must answer with the canonical contract: `intent` +
    // always-non-empty `response` + `confidence`, `actionType`/`actionUrl`
    // when the intent needs them, and the entity/slot fields. The legacy
    // wire shape (`action`/`reply`) is still ACCEPTED at parse time for
    // cached/cloud/fine-tuned payloads, but the prompt must not TEACH the
    // model the legacy keys — `response` is the spoken reply and the
    // "query"/"none" answer that fixes the "माफ गर्नुहोस्" dead-end.

    func testMentionsAllCanonicalContractFields() {
        let prompt = build()
        let canonical = ["intent", "response", "confidence", "actionType",
                         "actionUrl"]
        for field in canonical {
            XCTAssertTrue(prompt.contains("\"\(field)\""), "missing canonical field: \(field)")
        }
        let entities = ["entryId", "contact", "time", "medication", "message",
                        "callType", "requestedApp", "topic", "steps"]
        for field in entities {
            XCTAssertTrue(prompt.contains("\"\(field)\""), "missing entity field: \(field)")
        }
    }

    func testNoPluginBuildDoesNotTeachLegacyActionReplyKeys() {
        // Dual-shape tolerance is parse-side only (LlamaCommandInterpreter
        // .parse still accepts legacy payloads). The PROMPT must not teach
        // "action"/"reply" as output keys, or models would emit the legacy
        // shape and the always-populated "response" contract would drift.
        let prompt = build()
        XCTAssertFalse(prompt.contains("\"action\""), "legacy key must not be taught")
        XCTAssertFalse(prompt.contains("\"reply\""), "legacy key must not be taught")
        XCTAssertTrue(prompt.contains("non-empty"),
                      "the spoken response must be pinned non-empty")
    }

    func testMentionsAllCanonicalIntentValues() {
        let prompt = build()
        let intents = ["ack_med", "call", "send_message", "set_reminder",
                       "emergency", "health_query", "music",
                       "create_calendar_event", "suggest_video", "guide",
                       "query", "none"]
        for intent in intents {
            XCTAssertTrue(prompt.contains("\"\(intent)\""), "missing intent value: \(intent)")
        }
    }

    func testIncludesOneShotExampleOfCanonicalAnswer() {
        // The completed example + closing imperative is load-bearing: the
        // 1B base model echoes the transcript instead of emitting JSON
        // without it (verified on llama3.2:1b, 2026-09-06). Pinned so a
        // future cleanup cannot silently delete it.
        let prompt = build()
        XCTAssertTrue(prompt.contains("Example: {"), "one-shot example must be present")
        XCTAssertTrue(prompt.contains("\"intent\": \"query\""),
                      "example must show the query intent answering a question")
        XCTAssertTrue(prompt.contains("Now output ONLY the JSON object"),
                      "closing imperative must be present")
    }

    // MARK: - On-device size budget (the actual [QUERY-FIX] root cause)

    func testPromptStaysWithinOnDeviceCharacterBudget() {
        // The on-device runtime runs LLaMA 3.2 1B in a 1,024-token context.
        // The pre-fix prompt measured 2,361 tokens — the context overflowed,
        // inference finished EMPTY, and every utterance fell through to the
        // generic re-prompt. Measured with the real llama3.2:1b tokenizer
        // (2026-09-06): this build() turn is 2,936 Swift characters ≈ 785
        // tokens for this fixture; the formatted prompt (51-token chat
        // system + chat headers) is ~849 tokens — the worst observed
        // base-model completion at device settings (176 tokens) would reach
        // 1,025 total, i.e. the 1,024-token context is effectively full at
        // the measured size, and this text is the empirically verified
        // tightest size that still classifies correctly (the pre-trim
        // prompt was ~919+ tokens; a 53-token deeper trim collapsed
        // emergency recognition to 0/7 draws and a further 29-token trim
        // broke JSON output entirely on the real model — see the NOTE in
        // IntentPrompt.build). The ceiling below is the regression
        // tripwire: 3,000 chars keeps the turn within ~2% of the measured
        // size — a silent prompt bloat that would re-open the overflow bug
        // fails here instead.
        let prompt = build(transcript: "भोलिको मौसम कस्तो छ?", meds: [],
                           languageHint: "ne")
        XCTAssertLessThanOrEqual(
            prompt.count, 3_000,
            "build() must stay inside the 1,024-token on-device budget "
            + "(measured 2,936 chars for this fixture; 2,361 tokens pre-fix "
            + "overflowed the context and produced the empty-completion bug)")
    }

    // MARK: - Plugin composition (plugin architecture, 2026-09-05)

    func testNoPluginsLeavesPromptFreeOfPluginSchema() {
        let prompt = build()
        XCTAssertFalse(prompt.contains("pluginAction"))
        XCTAssertFalse(prompt.contains("pluginEntities"))
    }

    func testActivePluginContributesSchemaAndFragment() {
        let plugin = FakePlugin(id: "test_plugin", actionNames: ["test.action"], applicableToNepali: false)
        let prompt = IntentPrompt.build(transcript: "test",
                                        context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"),
                                        activePlugins: [plugin])
        XCTAssertTrue(prompt.contains("\"pluginAction\""), "plugin schema must be described when a plugin is active")
        XCTAssertTrue(prompt.contains("\"pluginEntities\""))
        XCTAssertTrue(prompt.contains("fake fragment for test_plugin"))
        XCTAssertTrue(prompt.contains("action"))
    }

    func testMultiplePluginsEachContributeFragment() {
        let a = FakePlugin(id: "plugin_a", actionNames: ["a.action"], applicableToNepali: false)
        let b = FakePlugin(id: "plugin_b", actionNames: ["b.action"], applicableToNepali: false)
        let prompt = IntentPrompt.build(transcript: "test",
                                        context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"),
                                        activePlugins: [a, b])
        XCTAssertTrue(prompt.contains("fake fragment for plugin_a"))
        XCTAssertTrue(prompt.contains("fake fragment for plugin_b"))
    }

    // MARK: - Intent-first framing (product requirement, 2026-09-05)

    func testFramesModelAsIntentEngineNotChatbot() {
        let prompt = build()
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("INTENT DECIPHERING"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("not a"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("general chatbot"))
    }

    // MARK: - Elderly-assistance dual-mode framing (2026-09-05)

    func testNamesBothOperatingModesExplicitly() {
        let prompt = build()
        XCTAssertTrue(prompt.contains("EXACTLY TWO MODES"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("INTENT DECIPHERING"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("OPEN-FORM ANSWERING"))
    }

    func testReplyStyleGuidanceIsElderlyAppropriate() {
        let prompt = build()
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("SPOKEN ALOUD"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("plain and simple"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("short sentences"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("warm"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("respectful"))
    }

    func testDistinguishesFunctionalReplyFromSubstantiveFallbackReply() {
        let prompt = build()
        // The reply-framing distinction: functional ack for real commands,
        // substantive answer only for the query/none fallback.
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("functional"))
        XCTAssertTrue(prompt.contains("\"query\"/\"none\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("substantive"))
    }

    func testFallbackReplyGuidanceDiscouragesDeflection() {
        let prompt = build()
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("do not deflect")
                      || prompt.localizedCaseInsensitiveContains("do NOT deflect"))
    }

    // MARK: - Emergency vs. health_query regression guard
    //
    // Live-tested against the real Gemini API this session: this exact
    // worked example is what fixed a real classification bug where a plea
    // for help attached to pain was mis-classified as "health_query".
    // Don't let this guidance get dropped or watered down.

    func testIncludesEmergencyVsHealthQueryWorkedExample() {
        let prompt = build()
        XCTAssertTrue(prompt.contains("मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ"))
        XCTAssertTrue(prompt.contains("is \"emergency\", NOT \"health_query\""))
    }

    func testIncludesErrTowardEmergencyGuidance() {
        let prompt = build()
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("err toward \"emergency\""))
    }

    // MARK: - Call entity guidance (callType / requestedApp)

    func testIncludesCallTypeAndRequestedAppGuidance() {
        let prompt = build()
        XCTAssertTrue(prompt.contains("callType"))
        XCTAssertTrue(prompt.contains("requestedApp"))
        XCTAssertTrue(prompt.contains("video"))
    }
}
