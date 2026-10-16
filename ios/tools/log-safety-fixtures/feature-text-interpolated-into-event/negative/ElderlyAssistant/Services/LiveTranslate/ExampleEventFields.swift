// FIXTURE (negative) — rule feature-text-interpolated-into-event must stay
// quiet.
//
// The same two fields built the sanctioned way: the code comes from the
// error taxonomy's own `logSafeErrorCode` (a compile-time constant), and the
// reason comes from a closed-vocabulary token. Neither is content.
import Foundation

struct ExampleEventFields {
    let bus: ObservabilityBus

    func degraded(error: LiveTranslateError, reason: TranslationUnavailableReason) {
        bus.emit(ObservabilityEvent(
            component: "livetranslate",
            eventType: "translation_degraded",
            outcome: "degraded",
            errorCode: error.logSafeErrorCode,
            metadata: [.reason: reason.rawValue]
        ))
    }
}
