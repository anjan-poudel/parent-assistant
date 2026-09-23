import XCTest
@testable import ElderlyAssistant

/// Stage 1 of the conversational-augmentation plan: the chat-vs-command
/// routing table. The classifier is pure, so these tests are the whole
/// contract — every case below is a routing decision, not a model
/// behaviour.
///
/// The two mistakes are not symmetric (see the classifier's own docs): a
/// false `.command` costs nothing, a false `.chat` takes a real command
/// off its execution path. The "stays a command" cases below are
/// therefore as load-bearing as the chat ones — they are the guard that
/// the chat class can never swallow a request.
final class ChatIntentClassifierTests: XCTestCase {

    // MARK: - Chat

    func testGreetingsClassifyAsChat() {
        for utterance in ["नमस्ते", "नमस्कार", "हेलो", "सुप्रभात",
                          "hello", "hi", "Good morning", "good evening"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .chat,
                           "greeting must be chat: \(utterance)")
        }
    }

    func testThanksAndFarewellsClassifyAsChat() {
        for utterance in ["धन्यवाद", "धेरै धन्यवाद", "thank you", "thanks",
                          "बिदा", "फेरि भेटौंला", "bye", "see you later"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .chat,
                           "thanks/farewell must be chat: \(utterance)")
        }
    }

    func testFeelingsAndSmallTalkClassifyAsChat() {
        for utterance in ["मलाई एक्लो लाग्छ", "मन दुख्यो", "थकाइ लाग्यो",
                          "i feel lonely", "I'm sad", "long time no see"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .chat,
                           "small talk must be chat: \(utterance)")
        }
    }

    func testHowAreYouExchangeClassifiesAsChat() {
        for utterance in ["कस्तो छ?", "तपाईंलाई कस्तो छ", "म ठीक छु",
                          "how are you?", "i'm fine"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .chat,
                           "how-are-you must be chat: \(utterance)")
        }
    }

    func testGreetingThatOpensALongerTurnIsChat() {
        // A greeting word plus a vocative/pet name: still nothing to do.
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते हजुर"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("Hello, hello"), .chat)
    }

    func testNormalizationIgnoresCaseAndPunctuation() {
        // The STT transcript arrives with the Devanagari danda, question
        // marks and mixed case — none of that may change the decision.
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते।"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("HELLO!"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("  thank you.  "), .chat)
    }

    // MARK: - Command (the guard cases)

    func testEveryCommandShapeStaysACommand() {
        let commands = [
            "छोरालाई फोन गर",                     // call
            "बिहान ८ बजे औषधि खान सम्झाउनु",        // reminder + medication
            "भोलिको मौसम कस्तो छ?",                // weather
            "गीत बजाउ",                            // music
            "मेरो प्रेसर कति छ",                    // health query
            "क्यामेरा खोल",                         // app launch
            "के छ खबर?",                           // news-shaped question
            "छोरालाई सन्देश पठाउ",                  // message
            "पात्रोमा भेट राख",                     // calendar
            "call my daughter",
            "set a reminder for 8",
            "play some bhajan"
        ]
        for utterance in commands {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .command,
                           "a request must never become chat: \(utterance)")
        }
    }

    func testContentCueWinsOverAGreetingOpening() {
        // The pre-answer table's own contract: a greeting-prefixed real
        // question is the question, never the greeting.
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते, भोलिको मौसम कस्तो छ?"), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("hello, call my son"), .command)
    }

    func testPoliteWordInsideALongerRequestStaysACommand() {
        // Whole-utterance matching is what keeps the formula table from
        // swallowing a request that merely contains a polite word.
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते भन्नुहोस् छोरालाई"), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("धन्यवाद भन रिमाइन्डर राख"), .command)
    }

    func testEmptyOrPunctuationOnlyIsNeverChat() {
        XCTAssertEqual(ChatIntentClassifier.classify(""), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("   "), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("।।?"), .command)
    }

    func testUnrecognisedUtteranceStaysACommand() {
        // The conservative default: anything the table does not claim —
        // including a substantive question — keeps today's path.
        XCTAssertEqual(ChatIntentClassifier.classify("आजको दिन कस्तो रहन्छ"), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("तपाईंलाई थाहा छ किन"), .command)
    }

    // MARK: - The device fixtures the rest of the suite replays

    func testExistingDeviceFixturesKeepTheCommandPath() {
        // `QueryEndToEndRegressionTests` and
        // `LlamaCommandInterpreterTests` replay these two exact utterances
        // through the production chain and assert the command schema
        // reaches the seam — they must not drift into the chat class.
        XCTAssertEqual(ChatIntentClassifier.classify("के छ खबर?"), .command)
        XCTAssertEqual(ChatIntentClassifier.classify("भोलिको मौसम कस्तो छ?"), .command)
    }

    func testClassifierIsPure() {
        // Same input, same decision — no state, no clock, no locale.
        for _ in 0..<3 {
            XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते"), .chat)
            XCTAssertEqual(ChatIntentClassifier.classify("छोरालाई फोन गर"), .command)
        }
    }
}
