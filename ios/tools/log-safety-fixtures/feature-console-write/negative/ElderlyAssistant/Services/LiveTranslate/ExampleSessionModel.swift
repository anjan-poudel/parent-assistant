// FIXTURE (negative) — rule feature-console-write must stay quiet.
//
// The same signal, routed the sanctioned way: an `ObservabilityEvent` through
// the bus. The rule must fire on console writes only, never on the correct
// route.
import Foundation

func sessionStarted(bus: ObservabilityBus) {
    bus.emit(ObservabilityEvent(
        component: "livetranslate",
        eventType: "session_started",
        outcome: "success"
    ))
}
