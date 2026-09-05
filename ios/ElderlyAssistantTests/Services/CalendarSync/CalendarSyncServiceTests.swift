import XCTest
@testable import ElderlyAssistant

final class CalendarSyncServiceTests: XCTestCase {

    private func makeEntry(name: String, hour: Int, minute: Int,
                           category: RoutineCategory = .medication) -> RoutineEntry {
        RoutineEntry(category: category,
                     titleOverride: name,
                     scheduleTimes: [DateComponents(hour: hour, minute: minute)],
                     frequency: .daily,
                     isEnabled: true)
    }

    private func makeService(granted: Bool) -> (CalendarSyncService, FakeEventWriter) {
        let writer = FakeEventWriter(granted: granted)
        let service = CalendarSyncService(eventWriter: writer,
                                          observabilityBus: MockObservabilityBus())
        return (service, writer)
    }

    func testPermissionDeniedSetsDeniedStatusAndMirrorsNothing() async {
        let (service, writer) = makeService(granted: false)
        service.isEnabled = true
        await service.enableAndSync(entries: [makeEntry(name: "खाना", hour: 8, minute: 0)])
        // Status lands on main — give it a turn.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.status, .denied)
        XCTAssertTrue(writer.addedEvents.isEmpty, "denied permission must mirror nothing — local-only mode, no partial state")
    }

    func testPermissionGrantedMirrorsEveryEntryTime() async {
        let (service, writer) = makeService(granted: true)
        service.isEnabled = true
        let entries = [makeEntry(name: "व्यायाम", hour: 7, minute: 30, category: .exercise),
                       makeEntry(name: "औषधि", hour: 8, minute: 0, category: .medication)]
        await service.enableAndSync(entries: entries)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(writer.addedEvents.count, 2)
        XCTAssertEqual(writer.addedEvents.map(\.title).sorted(),
                       ["औषधि (औषधि)", "व्यायाम (व्यायाम)"].sorted(),
                       "each mirrored event is titled with the entry name + its routine category label")
    }

    func testSyncNowIsANoOpWhenNotEnabled() {
        let (service, writer) = makeService(granted: true)
        // isEnabled defaults false, status notRequested.
        service.syncNow(entries: [makeEntry(name: "x", hour: 9, minute: 0)])
        XCTAssertTrue(writer.addedEvents.isEmpty)
    }

    func testRebuildRemovesOnlyMirrorEvents() async {
        let (service, writer) = makeService(granted: true)
        service.isEnabled = true
        writer.preExistingEvents = [
            FakeEventWriter.StoredEvent(title: "user's own event", notes: nil),
            FakeEventWriter.StoredEvent(title: "old mirror", notes: "com.elderlyassistant.mirrored-routine")
        ]
        await service.enableAndSync(entries: [makeEntry(name: "new", hour: 10, minute: 0)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writer.removedEvents.map(\.title), ["old mirror"],
                       "rebuild must remove only our mirrored events, never the user's own")
    }
}

/// In-memory `CalendarSyncService.EventWriting` — the real writer is a
/// thin EventKit shell; all sync LOGIC lives in the service and is
/// tested here with zero OS permission involvement.
final class FakeEventWriter: CalendarSyncService.EventWriting {
    struct StoredEvent {
        let title: String
        let notes: String?
    }

    private let granted: Bool
    var preExistingEvents: [StoredEvent] = []
    private(set) var addedEvents: [StoredEvent] = []
    private(set) var removedEvents: [StoredEvent] = []

    init(granted: Bool) { self.granted = granted }

    func requestAccess() async -> Bool { granted }

    func removeMirrorEvents(matchingIdentifier fragment: String) -> Int {
        let mirrors = preExistingEvents.filter { $0.notes?.contains(fragment) == true }
        removedEvents.append(contentsOf: mirrors)
        preExistingEvents.removeAll { $0.notes?.contains(fragment) == true }
        return mirrors.count
    }

    func addMirrorEvent(title: String, notes: String?, startHour: Int, startMinute: Int,
                        categoryLabel: String) -> String? {
        addedEvents.append(StoredEvent(title: title, notes: notes))
        return UUID().uuidString
    }
}
