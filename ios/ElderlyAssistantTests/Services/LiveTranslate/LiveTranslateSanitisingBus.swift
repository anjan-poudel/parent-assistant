import Foundation
@testable import ElderlyAssistant

/// The shipped log chokepoint, minus the print.
///
/// Every event is sanitised by the real `LogSanitiser` before it is captured,
/// so a test asserts on what a log sink would actually see. The shipped
/// `ConsoleObservabilityBus` performs exactly this sanitise step and then
/// prints; `LiveTranslateAllowListTests` additionally drives that real bus
/// end to end, so "it survives the bus" is evidenced on the real sink too and
/// not only here.
final class LiveTranslateSanitisingBus: ObservabilityBus {

    private let sanitiser = LogSanitiser()

    private(set) var events: [ObservabilityEvent] = []

    func emit(_ event: ObservabilityEvent) {
        events.append(sanitiser.sanitise(event))
    }

    func events(named eventType: String) -> [ObservabilityEvent] {
        events.filter { $0.eventType == eventType }
    }

    var eventTypes: Set<String> { Set(events.map(\.eventType)) }

    /// The metadata actually observed for an event type, after sanitisation.
    func observedMetadataKeys(named eventType: String) -> Set<String> {
        events(named: eventType).reduce(into: Set<String>()) { $0.formUnion($1.metadata.keys) }
    }
}
