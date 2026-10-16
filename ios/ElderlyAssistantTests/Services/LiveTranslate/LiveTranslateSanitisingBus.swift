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
///
/// **Every read and write is under a lock, because an observability sink is a
/// cross-queue object.** The shipped sink is called from every queue the app
/// owns — the camera's capture queue, the speech queue, the tier's transport
/// callbacks — and since the scene-block rework the detector emits the object
/// pass's events from the object pass's own queue while the text pass emits
/// `ocr_pass` from the vision queue. The shipped bus survives that because it
/// prints and holds nothing; this double holds an array, and an unsynchronised
/// append racing another append (or an assertion reading the array) is a heap
/// corruption rather than a lost event — it was observed as one, at the
/// detector suite, as `malloc: Heap corruption detected, free list is
/// damaged`. The double stands in for a sink, so it has to be as safe to call
/// from anywhere as the sink is.
final class LiveTranslateSanitisingBus: ObservabilityBus {

    private let sanitiser = LogSanitiser()
    private let lock = NSLock()

    /// The events, read-only and taken under the lock: a snapshot, so a
    /// caller's iteration cannot race a background emission.
    private var storedEvents: [ObservabilityEvent] = []

    var events: [ObservabilityEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func emit(_ event: ObservabilityEvent) {
        let clean = sanitiser.sanitise(event)
        lock.lock(); storedEvents.append(clean); lock.unlock()
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
