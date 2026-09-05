import XCTest
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

    // MARK: - Required JSON fields (must match InterpretedCommand exactly)

    func testMentionsAllRequiredFields() {
        let prompt = build()
        for field in ["action", "entryId", "contact", "time", "medication",
                      "message", "callType", "requestedApp", "confidence", "reply"] {
            XCTAssertTrue(prompt.contains("\"\(field)\""), "missing field: \(field)")
        }
    }

    func testMentionsAllActionValues() {
        let prompt = build()
        for action in ["ack_med", "call", "emergency", "set_reminder",
                       "health_query", "music", "send_message", "query", "none"] {
            XCTAssertTrue(prompt.contains("\"\(action)\""), "missing action: \(action)")
        }
    }

    // MARK: - Intent-first framing (product requirement, 2026-09-05)

    func testFramesModelAsIntentEngineNotChatbot() {
        let prompt = build()
        XCTAssertTrue(prompt.contains("INTENT-RECOGNITION"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("not a"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("conversational chatbot"))
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
