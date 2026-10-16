// FIXTURE (negative) — rule feature-unlisted-metadata-key must stay quiet.
//
// The same event, with the key spelled the sanctioned way (a `MetadataKey`
// case whose raw value is allow-listed) and, in the second emitter, as a
// declared string key. Both are the feature's real shapes and must pass.
import Foundation

struct ExampleEmitter {
    let bus: ObservabilityBus

    func ocrPass(regionCount: Int) {
        bus.emit(ObservabilityEvent(
            component: "livetranslate",
            eventType: "ocr_pass",
            outcome: "success",
            metadata: [.regionCount: String(regionCount)]
        ))
    }

    func cacheHit(count: Int) {
        bus.emit(ObservabilityEvent(
            component: "livetranslate",
            eventType: "cache_hit",
            outcome: "success",
            metadata: ["origin": "curated_dictionary", "count": String(count)]
        ))
    }
}
