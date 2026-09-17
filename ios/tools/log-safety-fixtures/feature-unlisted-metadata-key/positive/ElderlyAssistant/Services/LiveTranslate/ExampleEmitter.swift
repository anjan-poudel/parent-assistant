// FIXTURE (positive) — rule feature-unlisted-metadata-key.
//
// Two shapes, both a build failure: a *string* metadata key that has no
// `LogSanitiser.allowedKeys` entry, and a `MetadataKey` case whose raw value
// has none either. (AM-2/CL-5: the allow-list entry is the deliberate
// decision point, so an undeclared key must not ship silently — at the bus
// it would simply be dropped, and with it the evidence.)
import Foundation

struct ExampleEmitter {
    let bus: ObservabilityBus

    func ocrPass(regionCount: Int) {
        bus.emit(ObservabilityEvent(
            component: "livetranslate",
            eventType: "ocr_pass",
            outcome: "success",
            metadata: ["regionText": "\(regionCount)"]
        ))
    }

    enum MetadataKey: String, CaseIterable {
        case regionCount
        case regionText
    }
}
