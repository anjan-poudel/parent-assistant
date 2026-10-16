import XCTest
@testable import ElderlyAssistant

/// [SANITISED-DEBUG-LANE] (owner decision, 2026-09-20) The debug lane's
/// contract, asserted at **both ends of its route**:
///
///  - what the lane hands the bus — a raw recorder, below: every answered
///    pair, in the batch's own order, with the leg's timing. That is the
///    owner's diagnostic;
///  - what a **sink** receives — the shipped `LogSanitiser`, through
///    `LiveTranslateSanitisingBus`: the same lines with every string replaced
///    by `[redacted]`, so a capture shows that a pair existed, in what order,
///    with what timing, and never the scene text.
///
/// The two ends are asserted separately on purpose. A suite that drove only
/// the sanitising bus could not tell a lane that had quietly stopped sending
/// pairs from one that was working; a suite that drove only the raw recorder
/// would never notice text reaching a log surface.
///
/// The whole file is inside `#if DEBUG` because the type it tests is: the lane
/// — like its readers — does not exist in a Release build, which is what keeps
/// master's shipped property ("a Release build reads the switch into the
/// config and has nothing that acts on it") true of the lane as well.
#if DEBUG
final class LiveTranslateDebugLaneTests: XCTestCase {

    private let sourceSentence = "Take two tablets after breakfast"
    private let translatedSentence = "नाश्ते के बाद दो गोलियाँ लें"

    // MARK: - What the lane hands the bus

    func testAnEnabledLaneEmitsEveryPairInTheBatchesOwnOrderWithItsTiming() {
        let bus = RawRecorder()
        let lane = LiveTranslateDebugLane(bus: bus, enabled: true)

        lane.translationPairs([(source: "seat available", translation: "सीट उपलब्ध है"),
                               (source: sourceSentence, translation: translatedSentence)],
                              leg: .cloud,
                              durationMs: 412)

        let events = bus.events
        XCTAssertEqual(events.count, 2, "one line per answered pair, no summary line")
        XCTAssertEqual(events.map(\.eventType),
                       ["translate_debug_cloud", "translate_debug_cloud"])
        XCTAssertEqual(events.map(\.durationMs), [412, 412],
                       "the batch's own timing rides every line of the batch")
        XCTAssertEqual(events.map(\.component), ["livetranslate", "livetranslate"])
        XCTAssertEqual(events.map(\.outcome), ["debug", "debug"])
        XCTAssertEqual(events[0].metadata["source_text"], "seat available",
                       "the lane hands over the pair it was given — redaction is the choke point's job")
        XCTAssertEqual(events[0].metadata["translated_text"], "सीट उपलब्ध है")
        XCTAssertEqual(events[1].metadata["source_text"], sourceSentence)
        XCTAssertEqual(events[1].metadata["translated_text"], translatedSentence)
        XCTAssertEqual(events[0].metadata["duration_ms"], "412")
        XCTAssertEqual(events[1].metadata["duration_ms"], "412")
    }

    func testTheOcrLineCarriesThePassCountAlongsideTheText() {
        let bus = RawRecorder()
        LiveTranslateDebugLane(bus: bus, enabled: true)
            .recognizedText("Pharmacy | Open until eight", regionCount: 2)

        XCTAssertEqual(bus.events.count, 1, "one line per OCR pass")
        XCTAssertEqual(bus.events.first?.eventType, "translate_debug_ocr")
        XCTAssertEqual(bus.events.first?.metadata["regionCount"], "2")
        XCTAssertEqual(bus.events.first?.metadata["recognized_text"],
                       "Pharmacy | Open until eight")
        XCTAssertNil(bus.events.first?.durationMs,
                     "the pass's own timing is not measured here and must not be invented")
    }

    func testEachLegLabelsItsOwnLines() {
        let bus = RawRecorder()
        let lane = LiveTranslateDebugLane(bus: bus, enabled: true)

        lane.translationPairs([(source: "a", translation: "b")], leg: .cloud, durationMs: 1)
        lane.translationPairs([(source: "c", translation: "d")], leg: .local, durationMs: 2)

        XCTAssertEqual(bus.events.map(\.eventType),
                       ["translate_debug_cloud", "translate_debug_local"],
                       "the leg is a closed vocabulary, not free text")
    }

    func testABatchWithNoAnsweredPairEmitsNoLineAtAll() {
        let bus = RawRecorder()
        LiveTranslateDebugLane(bus: bus, enabled: true)
            .translationPairs([], leg: .cloud, durationMs: 5)

        XCTAssertTrue(bus.events.isEmpty,
                      "an empty batch has no pairs to show; the counts still travel the normal event")
    }

    // MARK: - What a sink receives

    func testASinkSeesThePairsAndTheTimingAndNeverTheText() {
        let bus = LiveTranslateSanitisingBus()
        let lane = LiveTranslateDebugLane(bus: bus, enabled: true)

        lane.recognizedText(sourceSentence, regionCount: 3)
        lane.translationPairs([(source: sourceSentence, translation: translatedSentence)],
                              leg: .local,
                              durationMs: 907)

        let ocr = bus.events(named: "translate_debug_ocr")
        XCTAssertEqual(ocr.count, 1)
        XCTAssertEqual(ocr.first?.metadata["regionCount"], "3",
                       "the count is not content and is the half of the pass's diagnostic")
        XCTAssertEqual(ocr.first?.metadata["recognized_text"], "[redacted]")

        let pairs = bus.events(named: "translate_debug_local")
        XCTAssertEqual(pairs.count, 1, "the pair's existence — not its text — survives")
        XCTAssertEqual(pairs.first?.metadata["source_text"], "[redacted]")
        XCTAssertEqual(pairs.first?.metadata["translated_text"], "[redacted]")
        XCTAssertEqual(pairs.first?.metadata["duration_ms"], "907",
                       "the timing is the diagnostic and it survives redaction")
        XCTAssertEqual(pairs.first?.durationMs, 907)

        // The sweep that matters: the text is nowhere on any field of any
        // event a sink would print. Metadata alone is not enough — a leak that
        // moved into the event type or the outcome token would pass a
        // metadata-only assertion.
        for event in bus.events {
            var fields = [event.eventType, event.outcome, event.errorCode ?? "", event.component]
            fields.append(contentsOf: event.metadata.map { "\($0.key)=\($0.value)" })
            for field in fields {
                XCTAssertFalse(field.contains(sourceSentence),
                               "recognized text reached a log surface in '\(field)'")
                XCTAssertFalse(field.contains(translatedSentence),
                               "translated text reached a log surface in '\(field)'")
            }
        }
    }

    // MARK: - The switch

    func testALaneThatIsOffEmitsNothingAtAll() {
        let raw = RawRecorder()
        let off = LiveTranslateDebugLane(bus: raw, enabled: false)
        off.recognizedText(sourceSentence, regionCount: 3)
        off.translationPairs([(source: sourceSentence, translation: translatedSentence)],
                             leg: .cloud,
                             durationMs: 12)
        XCTAssertTrue(raw.events.isEmpty,
                      "the switch turns the lane off without a rebuild — the reason it is persisted")

        let onTheSink = LiveTranslateSanitisingBus()
        LiveTranslateDebugLane(bus: onTheSink, enabled: false)
            .recognizedText(sourceSentence, regionCount: 1)
        XCTAssertTrue(onTheSink.events.isEmpty)
    }

    /// The smoke check the owner's directive asks for, reading the switch
    /// itself rather than handing `enabled` in: with
    /// `translationDebugLoggingEnabled` true the lane produces output, with it
    /// false the lane is silent. The nominal default is on (owner directive,
    /// 2026-09-20), so the first half is also what a fresh device build does.
    func testTheDiagnosticSwitchIsWhatTurnsTheLaneOn() {
        var config = LiveTranslateConfig.default
        XCTAssertTrue(config.translationDebugLoggingEnabled,
                      "the nominal default is on — a capture must not need a scheme edit")

        let on = RawRecorder()
        LiveTranslateDebugLane(bus: on, enabled: config.translationDebugLoggingEnabled)
            .translationPairs([(source: "a", translation: "b")], leg: .cloud, durationMs: 3)
        XCTAssertEqual(on.events.count, 1, "the switch is on: the lane produces output")

        config.translationDebugLoggingEnabled = false
        let off = RawRecorder()
        LiveTranslateDebugLane(bus: off, enabled: config.translationDebugLoggingEnabled)
            .translationPairs([(source: "a", translation: "b")], leg: .cloud, durationMs: 3)
        XCTAssertTrue(off.events.isEmpty, "the switch is off: the lane is silent")
    }
}

/// A recorder with **no** sanitiser, so a test can assert what the lane sent
/// rather than what a sink received. The shipped sink sanitises — that end of
/// the route is `LiveTranslateSanitisingBus`, the real `LogSanitiser` minus the
/// print — and nothing here is used to make a claim about a log surface.
///
/// Locked for the same reason that double is (its doc has the incident): a sink
/// is a cross-queue object, and an unsynchronised append is a heap corruption
/// rather than a lost event.
private final class RawRecorder: ObservabilityBus {

    private let lock = NSLock()
    private var stored: [ObservabilityEvent] = []

    var events: [ObservabilityEvent] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func emit(_ event: ObservabilityEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }
}
#endif
