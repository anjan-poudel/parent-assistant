import XCTest
import Foundation
@testable import ElderlyAssistant

final class SpeechSourceRegistryTests: XCTestCase {

    func testRegisterPreservesRegistrationOrder() {
        let registry = SpeechSourceRegistry()
        registry.register(FakeSpeechSource(id: "first", applicableToNepali: false))
        registry.register(FakeSpeechSource(id: "second", applicableToNepali: false))

        XCTAssertEqual(registry.sources.map(\.sourceID), ["first", "second"])
    }

    func testApplicableSourcesRespectsLocaleGating() {
        let registry = SpeechSourceRegistry()
        registry.register(FakeSpeechSource(id: "nepali_only", applicableToNepali: true))
        registry.register(FakeSpeechSource(id: "universal", applicableToNepali: false))

        XCTAssertEqual(
            registry.applicableSources(locale: Locale(identifier: "ne-NP")).map(\.sourceID),
            ["nepali_only", "universal"]
        )
        XCTAssertEqual(
            registry.applicableSources(locale: Locale(identifier: "en")).map(\.sourceID),
            ["universal"]
        )
    }

    func testNoSourcesIsEmptyResult() {
        let registry = SpeechSourceRegistry()
        XCTAssertTrue(registry.applicableSources(locale: Locale(identifier: "en")).isEmpty)
    }

    func testDuplicateSourceIDIsDroppedWithoutCrash() {
        let bus = FakeObservabilityBus()
        let registry = SpeechSourceRegistry(observabilityBus: bus)
        let first = FakeSpeechSource(id: "dup_source", applicableToNepali: false)
        registry.register(first)
        registry.register(FakeSpeechSource(id: "dup_source", applicableToNepali: false))

        // First claimant keeps the identity; the second is dropped (never a crash).
        XCTAssertEqual(registry.sources.count, 1)
        XCTAssertTrue(registry.sources.first === first)

        // The collision is the loud failure, reported PII-free.
        XCTAssertEqual(bus.emittedEvents.count, 1)
        let event = bus.emittedEvents[0]
        XCTAssertEqual(event.component, "speech_source_registry")
        XCTAssertEqual(event.eventType, "speech_source_collision")
        XCTAssertEqual(event.outcome, "failure")
        XCTAssertEqual(event.errorCode, "dup_source")
    }

    func testSameInstanceRegisteredTwiceIsAlsoRejected() {
        let bus = FakeObservabilityBus()
        let registry = SpeechSourceRegistry(observabilityBus: bus)
        let source = FakeSpeechSource(id: "single", applicableToNepali: false)
        registry.register(source)
        registry.register(source)

        XCTAssertEqual(registry.sources.count, 1)
        XCTAssertEqual(bus.emittedEvents.count, 1)
    }

    func testNextAnnouncementPullContractReturnsNilWhenNothingQueued() async {
        let source = FakeSpeechSource(id: "pull_source", applicableToNepali: false)
        let announcement = await source.nextAnnouncement()
        XCTAssertNil(announcement, "nil means 'nothing to say now' — never an error")
    }
}

/// Minimal in-test speech source double.
final class FakeSpeechSource: SpeechSource {
    let sourceID: String
    private let applicableToNepali: Bool
    var defaultPriority: AnnouncementPriority = .notification

    init(id: String, applicableToNepali: Bool) {
        self.sourceID = id
        self.applicableToNepali = applicableToNepali
    }

    func isApplicable(locale: Locale) -> Bool {
        !applicableToNepali || locale.language.languageCode?.identifier == "ne"
    }

    func nextAnnouncement() async -> Announcement? { nil }
}

/// Capturing observability double (same shape as the medication-scheduler
/// test suite's `MockObservabilityBus`).
final class FakeObservabilityBus: ObservabilityBus {
    var emittedEvents: [ObservabilityEvent] = []

    func emit(_ event: ObservabilityEvent) {
        emittedEvents.append(event)
    }
}
