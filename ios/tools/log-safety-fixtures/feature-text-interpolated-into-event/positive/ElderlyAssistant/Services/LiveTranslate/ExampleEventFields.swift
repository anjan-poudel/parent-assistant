// FIXTURE (positive) — rule feature-text-interpolated-into-event.
//
// Two shapes of the same failure: an `error_code` built by interpolating a
// raw error (the B1 defect class, on the event surface) and a metadata value
// built by interpolating recognized text. Both put upstream or scene text
// into the log payload.
import Foundation

struct ExampleEventFields {
    let bus: ObservabilityBus

    func degraded(error: Error, region: TextRegion, reason: String) {
        bus.emit(ObservabilityEvent(
            component: "livetranslate",
            eventType: "translation_degraded",
            outcome: "degraded",
            errorCode: "cloud_failed: \(error)",
            metadata: [.reason: "\(region.text)"]
        ))
    }
}
