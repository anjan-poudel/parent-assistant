#if DEBUG
import Foundation

/// The live-camera-translation debug lane: the owner's leg-by-leg trace of
/// what the recogniser read and what each translation leg answered, routed
/// through the sanitising bus instead of a console write.
///
/// **Why this exists as its own type, outside the feature.** [DEBUG-LOG]'s
/// original lane was a `print` in the feature's own sources, and the feature
/// may not carry one: `LiveTranslateSourceHygieneTests` fails any console
/// write in `Services/LiveTranslate/`, and the release gate fails a
/// content-bearing event field there (`NFR-LCT-006` — no recognized string on
/// a log surface, in any build). The owner's directive of 2026-09-20 keeps
/// the lane and changes its route: the strings travel the bus, and
/// `LogSanitiser` redacts them (`LogSanitiser.redactedKeys`) before any sink
/// sees the event. What a console therefore shows is the pair's existence,
/// its order and its timing —
/// `translate_debug_cloud outcome=debug metadata=[source_text: [redacted],
/// translated_text: [redacted], duration_ms: 412]` — and never the text.
///
/// **Debug-only, deliberately.** The shipped framing before this change was
/// that a Release build reads `translationDebugLoggingEnabled` into the
/// config "and has nothing that acts on it"; the whole type is inside
/// `#if DEBUG` so that stays true of the lane as well. The flag still gates
/// it inside a Debug build, because the owner's switch has to be able to turn
/// the noise off without a rebuild.
///
/// The redaction is the choke point's, not this type's — this type hands the
/// bus the raw string on purpose, so that the guarantee lives in the one
/// place every event already goes through and a future call site cannot
/// forget it.
struct LiveTranslateDebugLane {

    /// Which leg produced the pair. A closed vocabulary: it is the only part
    /// of an event type this lane varies, and it is a compile-time literal at
    /// every call site.
    enum Leg: String {
        case cloud
        case local
    }

    let bus: ObservabilityBus
    let enabled: Bool

    init(bus: ObservabilityBus, enabled: Bool) {
        self.bus = bus
        self.enabled = enabled
    }

    /// The OCR pass: every recognized string of the pass in one line, plus the
    /// region count that the content-free `ocrPass(regionCount:)` event
    /// already carries. The strings are redacted at the bus boundary.
    func recognizedText(_ text: String, regionCount: Int) {
        guard enabled else { return }
        bus.emit(ObservabilityEvent(
            component: Self.component,
            eventType: "translate_debug_ocr",
            durationMs: nil,
            outcome: "debug",
            errorCode: nil,
            metadata: [
                "regionCount": String(regionCount),
                "recognized_text": text
            ]))
    }

    /// One line per answered pair, in the batch's own order, with the leg's
    /// duration. `leg` decides the event type and nothing else.
    func translationPairs(_ pairs: [(source: String, translation: String)],
                          leg: Leg,
                          durationMs: Int) {
        guard enabled else { return }
        for pair in pairs {
            bus.emit(ObservabilityEvent(
                component: Self.component,
                eventType: "translate_debug_\(leg.rawValue)",
                durationMs: durationMs,
                outcome: "debug",
                errorCode: nil,
                metadata: [
                    "source_text": pair.source,
                    "translated_text": pair.translation,
                    "duration_ms": String(durationMs)
                ]))
        }
    }

    /// The feature's own component tag, so the lane's lines sit with the
    /// feature's other events in a capture.
    private static let component = "livetranslate"
}
#endif
