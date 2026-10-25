import XCTest
import UIKit
import UserNotifications
import ObjectiveC
@testable import ElderlyAssistant

/// T-027 — cross-boundary integration for the reminders-instructions feature
/// (design L2 §4.6–§4.7, §5.5–§5.9, §6.4, §10, §11.3, §11.5).
///
/// This suite is deliberately the "seams" suite: every case drives REAL
/// production types through their public/internal boundaries (routine store +
/// scheduler + notification builder + fire handler + coordinator; the video
/// and image stores rooted in a per-test temporary directory; the free-form
/// event service over a real extras index). Only the platform edges are
/// doubled: the alarm scheduler, the observability bus, the family notifier,
/// the EventKit gateway and an in-memory encrypted store.
///
/// Rules honoured here:
/// - Temporary-directory-only: `setUpWithError` mints a unique root and
///   `tearDownWithError` removes it. Nothing is written to Application
///   Support, the Keychain, the photo library or the network.
/// - No sleeps: the handler's `DispatchQueue.main.async` sinks are drained
///   with the checked-continuation pattern from
///   `RoutineVisualAidFireHandlerTests`.
/// - No instruction text, caption or filename is ever logged; fixtures are
///   synthetic and assertions never print them.
/// - Exactly the twelve cases named by T-027. Helpers below the tests carry
///   no `test` prefix.
final class InstructionFeatureIntegrationTests: XCTestCase {

    // MARK: - Per-test isolated state

    private var tempRoot: URL!

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixedFiredAt = Date(timeIntervalSince1970: 1_700_100_000)
    private let en = Locale(identifier: "en")
    private let ne = Locale(identifier: "ne")

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstructionFeatureIntegrationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    /// The shipping key spellings this suite plants raw JSON under. Pinned
    /// here once so a store key rename fails loudly rather than silently
    /// exercising a different key.
    private enum ShippingKey {
        static let routineEntries = "routine.entries"
        static let eventExtras = "eventExtras.byEventId"
    }

    // MARK: - Test doubles

    /// An `EncryptedLocalStorage` that can hold RAW JSON, not just encoded
    /// Swift values. The migration fixtures must be decoded from the exact
    /// bytes an older build wrote (wrong types, unknown keys, nulls); the
    /// shipping `MockEncryptedLocalStorage` only ever encodes Swift values,
    /// so it cannot express those payloads. It is still reused everywhere a
    /// value round-trip is the right seam.
    private final class RawJSONStorage: EncryptedLocalStorage {
        private var raw: [String: Data] = [:]
        private(set) var deleteCallCount = 0

        func plant(_ json: String, key: String) {
            raw[key] = Data(json.utf8)
        }

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? JSONEncoder().encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            raw[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = raw[key],
                  let value = try? JSONDecoder().decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            deleteCallCount += 1
            raw[key] = nil
            return .success(())
        }
    }

    /// Minimal payload-only profile storage so `AppCoordinator` can be built
    /// without touching the real encrypted store or the Keychain. Same shape
    /// as the private fake in `AppCoordinatorInstructionTests`; re-declared
    /// because that one is file-private.
    private final class InMemoryProfileStorage: ProfilePayloadStorage {
        private var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    /// Counts the handler's two sinks. Reference type so a closure can
    /// mutate it without the test holding an escaping var.
    private final class SinkRecorder {
        var fireCount = 0
        var tapCount = 0
    }

    /// Mutable entry resolution for the removed/deleted tap cases: the
    /// handler's `entryLookup` is a closure over this box, so the test can
    /// change what "the entry as resolved NOW" means between taps.
    private final class EntryBox {
        var entry: RoutineEntry?
        init(_ entry: RoutineEntry?) { self.entry = entry }
    }

    /// The real scheduler, store, bus, notifier and recording alarm seam,
    /// wired exactly as `RoutineSchedulerTests` does.
    private struct RoutineHarness {
        let storage: MockEncryptedLocalStorage
        let store: RoutineStore
        let alarm: MockRoutineAlarmScheduler
        let bus: MockObservabilityBus
        let notifier: MockFamilyNotifier
        let scheduler: RoutineScheduler
    }

    private func makeRoutineHarness(
        videoStore: InstructionVideoStore? = nil,
        visualAidStore: VisualAidStore? = nil,
        pinnedNow: Date? = nil
    ) -> RoutineHarness {
        let storage = MockEncryptedLocalStorage()
        let store = RoutineStore(storage: storage)
        let alarm = MockRoutineAlarmScheduler()
        let bus = MockObservabilityBus()
        let notifier = MockFamilyNotifier()
        let now = pinnedNow ?? fixedNow
        let scheduler = RoutineScheduler(
            store: store,
            alarmScheduler: alarm,
            observabilityBus: bus,
            familyNotifier: notifier,
            caregiverNotifySettings: .isolated(),
            visualAidStore: visualAidStore,
            instructionVideoStore: videoStore,
            now: { now })
        return RoutineHarness(storage: storage,
                              store: store,
                              alarm: alarm,
                              bus: bus,
                              notifier: notifier,
                              scheduler: scheduler)
    }

    /// EventKit gateway with no store behind it. `FreeFormEventService` only
    /// needs a gateway to construct; the instruction write path it exercises
    /// never touches it.
    private final class StubEventGateway: EventKitCalendarGateway {
        var eventsAccess: CalendarAccess { .fullAccess }
        func requestFullAccess() async -> Bool { true }
        func ensureSahayakCalendar(knownIdentifier: String?) -> String? { "stub-calendar" }
        func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] { [] }
        func fetchEvent(identifier: String) -> CalendarEventRecord? { nil }
        func createEvent(_ draft: CalendarEventDraft, in calendarIdentifier: String?) -> String? { nil }
        func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool { false }
        func removeEvent(identifier: String) -> Bool { false }
        func removeEvents(matchingNotesFragment fragment: String) -> Int { 0 }
    }

    // MARK: - Model / store helpers

    private func makeEntry(id: UUID = UUID(),
                           instruction: Instruction? = nil,
                           aids: [VisualAid] = [],
                           title: String = "Evening walk") -> RoutineEntry {
        RoutineEntry(
            id: id,
            category: .walk,
            titleOverride: title,
            scheduleTimes: [DateComponents(hour: 17, minute: 30)],
            frequency: .daily,
            weekdays: [],
            isEnabled: true,
            visualAids: aids,
            instruction: instruction)
    }

    private func makeImage(color: UIColor = .systemBlue) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func makeVideoStore() -> InstructionVideoStore {
        let pinnedNow = fixedNow
        return InstructionVideoStore(
            baseDirectory: tempRoot.appendingPathComponent("VideoStore", isDirectory: true),
            now: { pinnedNow })
    }

    private func makeImageStore() -> VisualAidStore {
        VisualAidStore(rootDirectory: tempRoot.appendingPathComponent("VisualAids",
                                                                      isDirectory: true))
    }

    private func makeEventExtrasStore() -> EventExtrasStore {
        EventExtrasStore(storage: MockEncryptedLocalStorage())
    }

    private func makeEventService(extras: EventExtrasStore,
                                  videoStore: InstructionVideoStore) -> FreeFormEventService {
        FreeFormEventService(
            gateway: StubEventGateway(),
            extras: extras,
            photoStore: ContactPhotoStore(
                rootDirectory: tempRoot.appendingPathComponent("EventPhotos", isDirectory: true),
                directoryName: "EventPhotos"),
            instructionVideoStore: videoStore,
            observability: MockObservabilityBus())
    }

    private func textCommit(_ text: String) -> InstructionCommit {
        InstructionCommit(write: .set(InstructionPayload(kind: .text, text: text)),
                          pendingMedia: nil)
    }

    private func removeCommit() -> InstructionCommit {
        InstructionCommit(write: .remove, pendingMedia: nil)
    }

    /// Stages real bytes through the real store with a synchronous probe
    /// that always accepts. The source file lives under the per-test temp
    /// root; no AVFoundation work is performed.
    @discardableResult
    private func stageVideo(store: InstructionVideoStore,
                            root: InstructionRoot,
                            draftId: UUID = UUID(),
                            bytes: Data = Data("synthetic-video-bytes".utf8))
    throws -> StagedInstructionVideo {
        let source = tempRoot.appendingPathComponent("source-\(draftId.uuidString).mov")
        try bytes.write(to: source)
        return try store.stageSynchronously(
            from: source,
            into: root,
            limits: .standard,
            draftId: draftId,
            probe: { _ in
                .success(InstructionVideoMetadata(durationSeconds: 30,
                                                  hasVideoTrack: true,
                                                  isPlayable: true))
            }
        ).get()
    }

    /// The editor → scheduler handoff for a video: staged bytes plus the
    /// resolved `.set` payload (the filename is minted by `commit`).
    private func makeVideoCommit(store: InstructionVideoStore,
                                 root: InstructionRoot,
                                 draftId: UUID = UUID(),
                                 caption: String? = nil) throws -> InstructionCommit {
        let staged = try stageVideo(store: store, root: root, draftId: draftId)
        return InstructionCommit(
            write: .set(InstructionPayload(kind: .video, caption: caption)),
            pendingMedia: .video(AcceptedInstructionVideo(staged: staged,
                                                          validatedAt: fixedNow)))
    }

    /// Stages AND commits a video directly, for the migration-survival case
    /// (no editor/scheduler involved, so the fixture loads are pinned to
    /// "loads never delete bytes" rather than to a write path).
    private func commitVideo(store: InstructionVideoStore,
                             owner: InstructionOwner,
                             bytes: Data) throws -> (filename: String, url: URL) {
        let staged = try stageVideo(store: store, root: owner.root, bytes: bytes)
        let filename = try store.commit(staged, for: owner).get()
        return (filename, try XCTUnwrap(store.fileURL(filename: filename, owner: owner)))
    }

    /// The stored instruction-* names in an owner directory, sorted. Empty
    /// when the directory does not exist; the assertion helpers use the
    /// count to prove the single-video-per-owner invariant.
    private func videoFilenames(_ store: InstructionVideoStore,
                                owner: InstructionOwner) -> [String] {
        guard case .success(let directory) =
                store.ownerDirectoryURL(named: owner.directoryName, in: owner.root) else {
            return []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("instruction-") }.sorted()
    }

    // MARK: - Result assertions (Result<Void, _> is not Equatable)

    private func assertSuccess<E: Error>(_ result: Result<Void, E>,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure<E: Error & Equatable>(
        _ result: Result<Void, E>,
        equals expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected \(expected)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Notification stubs (runtime allocation, copied from
    // `RoutineVisualAidFireHandlerTests` because its helpers are private)

    private func notification(entryId: UUID,
                              hadInstruction: Bool?,
                              firedAt: Date,
                              occurrenceId: UUID = UUID(),
                              type: String = RoutineVisualAidFireHandler.routineReminderType)
    -> UNNotification {
        var userInfo: [AnyHashable: Any] = [
            RoutineNotificationContent.typeKey: type,
            RoutineNotificationContent.occurrenceIdKey: occurrenceId.uuidString,
            RoutineNotificationContent.entryIdKey: entryId.uuidString
        ]
        if let hadInstruction {
            userInfo[RoutineNotificationContent.hadInstructionKey] = hadInstruction
        }
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = "Evening walk"
        content.userInfo = userInfo
        return notification(from: content, firedAt: firedAt)
    }

    private func notification(from content: UNNotificationContent,
                              firedAt: Date) -> UNNotification {
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        let raw = class_createInstance(UNNotification.self, 0)! as Any as! UNNotification
        raw.setValue(request, forKey: "request")
        raw.setValue(firedAt, forKey: "date")
        return raw
    }

    private func response(to notification: UNNotification,
                          action: String = UNNotificationDefaultActionIdentifier)
    -> UNNotificationResponse {
        let raw = class_createInstance(UNNotificationResponse.self, 0)!
            as Any as! UNNotificationResponse
        raw.setValue(notification, forKey: "notification")
        raw.setValue(action, forKey: "actionIdentifier")
        return raw
    }

    /// FIFO drain of the handler's `DispatchQueue.main.async` sinks: every
    /// block enqueued before this one has run when the continuation resumes,
    /// so "no call" is proved without a sleep.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Coordinator / handler helper

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfileStorage())
    }

    private func makeFireHandler(
        lookup: @escaping (UUID) -> RoutineEntry?,
        recorder: SinkRecorder,
        coordinator: AppCoordinator
    ) -> RoutineVisualAidFireHandler {
        RoutineVisualAidFireHandler(
            entryLookup: lookup,
            onFire: { entry, context in
                recorder.fireCount += 1
                coordinator.presentRoutineVisualAids(for: entry, context: context)
            },
            onInstructionTap: { entryId, entry, firedAt in
                recorder.tapCount += 1
                coordinator.presentRoutineInstructionTap(entryId: entryId,
                                                         entry: entry,
                                                         firedAt: firedAt)
            })
    }

    private func instructionUpdatedEvents(_ bus: MockObservabilityBus)
    -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.eventType == "entry_instruction_updated" }
    }

    private func cardState(_ coordinator: AppCoordinator) -> InstructionDisplayState? {
        coordinator.firedRoutineVisualAids.map {
            RoutineVisualAidOverlay.cardState(for: $0.content)
        }
    }

    // MARK: - JSON helpers

    private func decodeEntry(_ json: String) throws -> RoutineEntry {
        try JSONDecoder().decode(RoutineEntry.self, from: Data(json.utf8))
    }

    private func decodeExtrasIndex(_ json: String) throws -> [String: EventExtras] {
        try JSONDecoder().decode([String: EventExtras].self, from: Data(json.utf8))
    }

    private func decodeMedication(_ json: String) throws -> MedicationEntry {
        try JSONDecoder().decode(MedicationEntry.self, from: Data(json.utf8))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// Every key name anywhere in an encoded value. Used for "the re-encode
    /// adds / drops exactly this key" assertions (F-1, F-8, medication).
    private func allJSONKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            var keys = Set(dictionary.keys)
            for nested in dictionary.values {
                keys.formUnion(allJSONKeys(in: nested))
            }
            return keys
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, element in
                result.formUnion(allJSONKeys(in: element))
            }
        }
        return []
    }

    private func payloadStrings(_ content: UNNotificationContent) -> [String] {
        var values = [content.title, content.subtitle, content.body]
        for value in content.userInfo.values {
            values.append(String(describing: value))
        }
        return values
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    // MARK: - 1. Routine instruction end-to-end: text

    @MainActor
    func testRoutineInstructionEndToEndText() async throws {
        let harness = makeRoutineHarness()
        let entry = makeEntry()
        XCTAssertTrue(harness.scheduler.addEntry(entry))

        let sentinelText = "Take the blue pill"
        assertSuccess(harness.scheduler.setInstruction(textCommit("  \(sentinelText)  "),
                                                       entryId: entry.id))

        let stored = try XCTUnwrap(harness.scheduler.entry(for: entry.id))
        XCTAssertEqual(stored.instruction,
                       Instruction(kind: "text", text: sentinelText),
                       "the stored wire value trims the text and keeps the raw kind")

        // The ARMED reminder reads had_instruction from the current index.
        XCTAssertFalse(harness.alarm.scheduled.isEmpty)
        XCTAssertTrue(harness.alarm.scheduled.values.allSatisfy {
            $0.entryId == entry.id && $0.hadInstruction
        }, "every newly armed occurrence for this entry expects an instruction")

        // The one event carries closed tokens only: no text, caption or
        // filename content.
        let events = instructionUpdatedEvents(harness.bus)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.outcome, "saved")
        XCTAssertEqual(event.metadata["kind"], "text")
        XCTAssertEqual(event.metadata["count"], "1")
        XCTAssertEqual(Set(event.metadata.keys),
                       ["entry_id_hash", "kind", "count"])
        XCTAssertFalse(event.metadata.values.joined(separator: " ").contains(sentinelText),
                       "instruction content never rides an observability event")

        // Real producer → real payload → real handler.
        let armed = try XCTUnwrap(harness.alarm.scheduled.first {
            $0.value.entryId == entry.id
        })
        let content = RoutineNotificationContent.make(
            occurrenceId: armed.key,
            entryId: entry.id,
            entryTitle: "Evening walk",
            reminderTitle: "Reminder",
            visualAidURL: nil,
            hadInstruction: armed.value.hadInstruction,
            attachmentFactory: { _, _ in nil })
        XCTAssertEqual(content.userInfo[RoutineNotificationContent.hadInstructionKey] as? Bool,
                       true)

        let delivered = notification(from: content, firedAt: fixedFiredAt)
        let coordinator = makeCoordinator()
        let recorder = SinkRecorder()
        let handler = makeFireHandler(
            lookup: { id in harness.scheduler.entry(for: id) },
            recorder: recorder,
            coordinator: coordinator)

        XCTAssertFalse(handler.willPresent(delivered, categoryIdentifier: ""),
                       "the handler never claims delivery")
        await drainMainQueue()

        XCTAssertEqual(recorder.fireCount, 1)
        let presentation = try XCTUnwrap(coordinator.firedRoutineVisualAids)
        XCTAssertEqual(presentation.entryId, entry.id)
        XCTAssertEqual(presentation.content,
                       .reminder(title: "Evening walk",
                                 aids: [],
                                 instruction: stored.instruction,
                                 expectsInstruction: true,
                                 firedAt: fixedFiredAt))
        XCTAssertEqual(cardState(coordinator), .text(text: sentinelText))
        XCTAssertNotNil(RoutineVisualAidOverlay.timeText(for: presentation.content,
                                                         locale: en))

        // Tap → instruction screen (present case), dedupe-compatible.
        coordinator.dismissFiredRoutineVisualAids()
        await handler.didReceive(response(to: delivered))
        await drainMainQueue()

        XCTAssertEqual(recorder.tapCount, 1)
        XCTAssertEqual(cardState(coordinator), .text(text: sentinelText))
        guard case .reminder(_, _, let tappedInstruction, let expects, let firedAt)?
                = coordinator.firedRoutineVisualAids?.content else {
            return XCTFail("tap must publish a reminder presentation")
        }
        XCTAssertEqual(tappedInstruction, stored.instruction)
        XCTAssertTrue(expects)
        XCTAssertEqual(firedAt, fixedFiredAt,
                       "the delivery date is the notification's, never a clock read")
    }

    // MARK: - 2. Routine instruction end-to-end: image

    @MainActor
    func testRoutineInstructionEndToEndImage() async throws {
        let imageStore = makeImageStore()
        let harness = makeRoutineHarness(visualAidStore: imageStore)
        let entry = makeEntry()
        XCTAssertTrue(harness.scheduler.addEntry(entry))

        let commit = InstructionCommit(
            write: .set(InstructionPayload(kind: .image, caption: "the blue box")),
            pendingMedia: .image(makeImage()))
        assertSuccess(harness.scheduler.setInstruction(commit, entryId: entry.id))

        let stored = try XCTUnwrap(harness.scheduler.entry(for: entry.id))
        let instruction = try XCTUnwrap(stored.instruction)
        let filename = try XCTUnwrap(instruction.filename)
        XCTAssertEqual(instruction.kind, "image")
        XCTAssertEqual(instruction.caption, "the blue box")
        XCTAssertTrue(instruction.isPresent)
        XCTAssertTrue(stored.visualAids.isEmpty,
                      "an instruction image is not appended to the entry's visual aids")

        // The real store resolves the bytes the real image loader reads.
        XCTAssertNotNil(imageStore.existingFileURL(VisualAid(filename: filename),
                                                   for: entry.id))
        let loader = VisualAidInstructionImageLoader(store: imageStore, entryId: entry.id)
        switch loader.loadImage(filename: filename) {
        case .success:
            break
        case .failure(let error):
            XCTFail("the committed image must load, got \(error)")
        }

        let events = instructionUpdatedEvents(harness.bus)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["kind"], "image")

        let armed = try XCTUnwrap(harness.alarm.scheduled.first {
            $0.value.entryId == entry.id
        })
        XCTAssertTrue(armed.value.hadInstruction)
        let content = RoutineNotificationContent.make(
            occurrenceId: armed.key,
            entryId: entry.id,
            entryTitle: "Evening walk",
            reminderTitle: "Reminder",
            visualAidURL: nil,
            hadInstruction: true,
            attachmentFactory: { _, _ in nil })

        let delivered = notification(from: content, firedAt: fixedFiredAt)
        let coordinator = makeCoordinator()
        let recorder = SinkRecorder()
        let handler = makeFireHandler(
            lookup: { id in harness.scheduler.entry(for: id) },
            recorder: recorder,
            coordinator: coordinator)

        XCTAssertFalse(handler.willPresent(delivered, categoryIdentifier: ""))
        await drainMainQueue()
        XCTAssertEqual(cardState(coordinator),
                       .image(filename: filename, caption: "the blue box"))
        XCTAssertNotNil(RoutineVisualAidOverlay.timeText(
            for: try XCTUnwrap(coordinator.firedRoutineVisualAids?.content),
            locale: en))

        coordinator.dismissFiredRoutineVisualAids()
        await handler.didReceive(response(to: delivered))
        await drainMainQueue()
        XCTAssertEqual(recorder.tapCount, 1)
        XCTAssertEqual(cardState(coordinator),
                       .image(filename: filename, caption: "the blue box"))
    }

    // MARK: - 3. Routine instruction end-to-end: video

    @MainActor
    func testRoutineInstructionEndToEndVideo() async throws {
        let videoStore = makeVideoStore()
        let harness = makeRoutineHarness(videoStore: videoStore)
        let entry = makeEntry()
        XCTAssertTrue(harness.scheduler.addEntry(entry))

        let draftId = UUID()
        let commit = try makeVideoCommit(store: videoStore,
                                         root: .routines,
                                         draftId: draftId,
                                         caption: "Watch this")
        assertSuccess(harness.scheduler.setInstruction(commit, entryId: entry.id))

        let stored = try XCTUnwrap(harness.scheduler.entry(for: entry.id))
        let instruction = try XCTUnwrap(stored.instruction)
        let filename = try XCTUnwrap(instruction.filename)
        let expectedName = InstructionVideoStore.storedFilename(
            draftId: draftId, sourceExtension: "mov")
        XCTAssertEqual(filename, expectedName,
                       "commit mints instruction-<draftId>.<ext>")
        XCTAssertEqual(instruction.kind, "video")
        XCTAssertEqual(instruction.caption, "Watch this")

        let owner = InstructionOwner.routine(entry.id)
        let availability = videoStore.availability(filename: filename, owner: owner)
        guard case .available(let playedURL) = availability else {
            return XCTFail("the committed video must be available, got \(availability)")
        }
        XCTAssertEqual(playedURL,
                       try XCTUnwrap(videoStore.fileURL(filename: filename, owner: owner)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: playedURL.path))
        XCTAssertEqual(try Data(contentsOf: playedURL),
                       Data("synthetic-video-bytes".utf8))

        let events = instructionUpdatedEvents(harness.bus)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["kind"], "video")

        let armed = try XCTUnwrap(harness.alarm.scheduled.first {
            $0.value.entryId == entry.id
        })
        XCTAssertTrue(armed.value.hadInstruction)
        let content = RoutineNotificationContent.make(
            occurrenceId: armed.key,
            entryId: entry.id,
            entryTitle: "Evening walk",
            reminderTitle: "Reminder",
            visualAidURL: nil,
            hadInstruction: true,
            attachmentFactory: { _, _ in nil })
        let delivered = notification(from: content, firedAt: fixedFiredAt)

        let coordinator = makeCoordinator()
        let recorder = SinkRecorder()
        let handler = makeFireHandler(
            lookup: { id in harness.scheduler.entry(for: id) },
            recorder: recorder,
            coordinator: coordinator)

        XCTAssertFalse(handler.willPresent(delivered, categoryIdentifier: ""))
        await drainMainQueue()
        XCTAssertEqual(cardState(coordinator),
                       .video(filename: filename, caption: "Watch this"))

        coordinator.dismissFiredRoutineVisualAids()
        await handler.didReceive(response(to: delivered))
        await drainMainQueue()
        XCTAssertEqual(recorder.tapCount, 1)
        XCTAssertEqual(cardState(coordinator),
                       .video(filename: filename, caption: "Watch this"))

        // The coordinator's playback seam is one delegation to its shared
        // store. That store is rooted at Application Support and is NOT
        // injectable (a `let` initialised in the coordinator); this test
        // therefore cannot hand it the temp store's bytes, and does not
        // write to Application Support. It asserts the seam answers exactly
        // what the shared store answers for an absent name and pins the
        // single-line delegation in source.
        let absent = "absent-\(UUID().uuidString).mov"
        XCTAssertEqual(coordinator.instructionPlaybackAvailability(filename: absent,
                                                                   owner: owner),
                       coordinator.instructionVideoStore.availability(filename: absent,
                                                                      owner: owner))
        XCTAssertEqual(coordinator.instructionPlaybackAvailability(filename: absent,
                                                                   owner: owner),
                       .missingFile)

        let coordinatorSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        XCTAssertEqual(occurrences(of: "func instructionPlaybackAvailability(filename: String,",
                                   in: coordinatorSource), 1)
        XCTAssertEqual(occurrences(
            of: "instructionVideoStore.availability(filename: filename, owner: owner)",
            in: coordinatorSource), 1)
    }

    // MARK: - 4. A reminder with no instruction delivers exactly as before

    @MainActor
    func testReminderFiresWithoutInstruction() async throws {
        let harness = makeRoutineHarness()
        let entry = makeEntry()
        XCTAssertTrue(harness.scheduler.addEntry(entry))
        XCTAssertFalse(harness.alarm.scheduled.isEmpty)
        XCTAssertTrue(harness.alarm.scheduled.values.allSatisfy {
            $0.entryId == entry.id && !$0.hadInstruction
        }, "an entry with no instruction arms had_instruction == false")

        let coordinator = makeCoordinator()
        let recorder = SinkRecorder()
        let handler = makeFireHandler(
            lookup: { id in harness.scheduler.entry(for: id) },
            recorder: recorder,
            coordinator: coordinator)

        let absentKey = notification(entryId: entry.id,
                                     hadInstruction: nil,
                                     firedAt: fixedFiredAt)
        XCTAssertFalse(handler.willPresent(absentKey, categoryIdentifier: ""))
        await drainMainQueue()
        XCTAssertEqual(recorder.fireCount, 0,
                       "no photo, no instruction, nothing expected: no fired screen")
        XCTAssertNil(coordinator.firedRoutineVisualAids)

        // A pre-upgrade tap (no had_instruction key) is a no-op.
        await handler.didReceive(response(to: absentKey))
        await drainMainQueue()
        XCTAssertEqual(recorder.tapCount, 0)
        XCTAssertNil(coordinator.firedRoutineVisualAids)

        // A false boolean is equally a no-op, and no foreground screen.
        let falseKey = notification(entryId: entry.id,
                                    hadInstruction: false,
                                    firedAt: fixedFiredAt)
        XCTAssertFalse(handler.willPresent(falseKey, categoryIdentifier: ""))
        await handler.didReceive(response(to: falseKey))
        await drainMainQueue()
        XCTAssertEqual(recorder.tapCount, 0)
        XCTAssertEqual(recorder.fireCount, 0)
        XCTAssertNil(coordinator.firedRoutineVisualAids)
    }

    // MARK: - 5. The notification payload carries no instruction content

    func testNotificationPayloadCarriesNoInstructionContent() throws {
        let entryId = UUID()
        let occurrenceId = UUID()
        let content = RoutineNotificationContent.make(
            occurrenceId: occurrenceId,
            entryId: entryId,
            entryTitle: "Evening walk",
            reminderTitle: "Reminder",
            visualAidURL: nil,
            hadInstruction: true,
            attachmentFactory: { _, _ in nil })

        // EXACTLY the four producer keys the design allows.
        XCTAssertEqual(Set(content.userInfo.keys),
                       Set<AnyHashable>([
                           RoutineNotificationContent.occurrenceIdKey,
                           RoutineNotificationContent.entryIdKey,
                           RoutineNotificationContent.typeKey,
                           RoutineNotificationContent.hadInstructionKey
                       ]))
        XCTAssertEqual(content.userInfo[RoutineNotificationContent.occurrenceIdKey] as? String,
                       occurrenceId.uuidString)
        XCTAssertEqual(content.userInfo[RoutineNotificationContent.entryIdKey] as? String,
                       entryId.uuidString)
        XCTAssertEqual(content.userInfo[RoutineNotificationContent.typeKey] as? String,
                       RoutineVisualAidFireHandler.routineReminderType)
        XCTAssertEqual(content.userInfo[RoutineNotificationContent.hadInstructionKey] as? Bool,
                       true)
        XCTAssertTrue(content.categoryIdentifier.isEmpty,
                      "routine reminders carry no category and no action")
        XCTAssertTrue(content.attachments.isEmpty)

        // A synthetic instruction's words/caption/filename never leak into
        // any payload field. The builder is never handed them, and the
        // sentinel proves the assertion has teeth.
        let sentinel = "blue-pill-sentinel"
        let instruction = Instruction(kind: "text", text: sentinel)
        XCTAssertEqual(instruction.trimmedText, sentinel)
        for value in payloadStrings(content) {
            XCTAssertFalse(value.contains(sentinel))
        }

        // Reader rules: absent key (pre-upgrade) and non-Bool both read
        // false and stay no-ops.
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(from: [:]))
        let nonBool: [AnyHashable: Any] = [
            RoutineNotificationContent.hadInstructionKey: "true"
        ]
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(from: nonBool))
        let actual: [AnyHashable: Any] = [
            RoutineNotificationContent.hadInstructionKey: true
        ]
        XCTAssertTrue(RoutineNotificationContent.hadInstruction(from: actual))
    }

    // MARK: - 6. Tap matrix: present / removed / deleted (+ dedupe)

    @MainActor
    func testTapPresentRemovedDeletedMatrix() async throws {
        let coordinator = makeCoordinator()
        let recorder = SinkRecorder()
        let entry = makeEntry(instruction: Instruction(kind: "text", text: "Take the blue pill"))
        let second = makeEntry(instruction: Instruction(kind: "text", text: "Drink water"))
        let box = EntryBox(entry)
        let handler = makeFireHandler(
            lookup: { id in box.entry?.id == id ? box.entry : nil },
            recorder: recorder,
            coordinator: coordinator)

        // (a) Foreground delivery presents the instruction.
        let presentNotification = notification(entryId: entry.id,
                                               hadInstruction: true,
                                               firedAt: fixedFiredAt)
        XCTAssertFalse(handler.willPresent(presentNotification, categoryIdentifier: ""))
        await drainMainQueue()
        XCTAssertEqual(cardState(coordinator), .text(text: "Take the blue pill"))

        // Dedupe: the same entry id is not replaced, even with a new date.
        let before = try XCTUnwrap(coordinator.firedRoutineVisualAids)
        coordinator.presentRoutineInstructionTap(
            entryId: entry.id,
            entry: second,
            firedAt: fixedFiredAt.addingTimeInterval(60))
        XCTAssertEqual(coordinator.firedRoutineVisualAids, before,
                       "an already-presented owner is not replaced")

        // A different entry replaces the single presentation.
        coordinator.presentRoutineInstructionTap(
            entryId: second.id,
            entry: second,
            firedAt: fixedFiredAt)
        XCTAssertEqual(coordinator.firedRoutineVisualAids?.entryId, second.id)
        XCTAssertEqual(cardState(coordinator), .text(text: "Drink water"))

        // (b) Entry exists, instruction removed after arming: the hook only
        // runs when had_instruction was true, so the card must render the
        // honest removed fallback and keep the delivery time.
        coordinator.dismissFiredRoutineVisualAids()
        let removedEntry = makeEntry(id: entry.id, instruction: nil)
        box.entry = removedEntry
        await handler.didReceive(response(to: presentNotification))
        await drainMainQueue()

        let removedContent = try XCTUnwrap(coordinator.firedRoutineVisualAids?.content)
        guard case .reminder(let title, let aids, let instruction,
                             let expects, let firedAt) = removedContent else {
            return XCTFail("a live owner must publish .reminder")
        }
        XCTAssertEqual(title, "Evening walk")
        XCTAssertTrue(aids.isEmpty)
        XCTAssertNil(instruction)
        XCTAssertTrue(expects)
        XCTAssertEqual(firedAt, fixedFiredAt)
        XCTAssertEqual(cardState(coordinator), .removed)
        XCTAssertNotNil(RoutineVisualAidOverlay.timeText(for: removedContent, locale: en),
                        "the removed fallback keeps the fire-time line")

        // (c) Owner deleted after arming: the unavailable notice, claiming
        // neither title nor time.
        coordinator.dismissFiredRoutineVisualAids()
        box.entry = nil
        await handler.didReceive(response(to: presentNotification))
        await drainMainQueue()

        guard case .unavailable? = coordinator.firedRoutineVisualAids?.content else {
            return XCTFail("a deleted owner must publish .unavailable")
        }
        let unavailableContent = try XCTUnwrap(coordinator.firedRoutineVisualAids?.content)
        XCTAssertEqual(cardState(coordinator), InstructionDisplayState.none)
        XCTAssertNil(RoutineVisualAidOverlay.timeText(for: unavailableContent, locale: en))
        XCTAssertTrue(RoutineVisualAidOverlay.footerIsEmpty(for: unavailableContent))

        // (d) Pre-upgrade payload (no had_instruction): the tap stays a
        // no-op and publishes nothing.
        coordinator.dismissFiredRoutineVisualAids()
        box.entry = entry
        let tapsBefore = recorder.tapCount
        let legacyNotification = notification(entryId: entry.id,
                                              hadInstruction: nil,
                                              firedAt: fixedFiredAt)
        await handler.didReceive(response(to: legacyNotification))
        await drainMainQueue()
        XCTAssertEqual(recorder.tapCount, tapsBefore)
        XCTAssertNil(coordinator.firedRoutineVisualAids)
    }

    // MARK: - 7. Migration fixtures F-1 … F-12

    /// Every fixture below is synthetic JSON in the exact shape an older
    /// build could have persisted. Assertions state the documented outcome
    /// for each fixture ID; nothing here deletes or rewrites media.
    @MainActor
    func testMigrationFixturesF1ThroughF12() throws {
        // Real media on disk, planted BEFORE any fixture load. If any load
        // path deletes instruction media, these survive checks fail.
        let videoStore = makeVideoStore()
        let imageStore = makeImageStore()
        let routineOwnerId = try XCTUnwrap(
            UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let eventOwner = InstructionOwner.event("evt-legacy")
        let routineOwner = InstructionOwner.routine(routineOwnerId)
        let routineBytes = Data("planted-routine-video".utf8)
        let eventBytes = Data("planted-event-video".utf8)
        let routineVideo = try commitVideo(store: videoStore,
                                           owner: routineOwner,
                                           bytes: routineBytes)
        let eventVideo = try commitVideo(store: videoStore,
                                         owner: eventOwner,
                                         bytes: eventBytes)
        let aid = try XCTUnwrap(imageStore.save(makeImage(), for: routineOwnerId,
                                                caption: "kept"))
        let aidURL = try XCTUnwrap(imageStore.existingFileURL(aid, for: routineOwnerId))

        let raw = RawJSONStorage()
        func loadedRoutineEntries(_ json: String) -> [RoutineEntry] {
            raw.plant("[\(json)]", key: ShippingKey.routineEntries)
            return RoutineStore(storage: raw).loadEntries()
        }
        func loadedExtras(_ json: String) -> [String: EventExtras]? {
            raw.plant(json, key: ShippingKey.eventExtras)
            return EventExtrasStore(storage: raw).snapshot()
        }

        // F-1: legacy routine entry, no instruction key.
        let f1 = try decodeEntry(f1LegacyRoutineEntry)
        XCTAssertNil(f1.instruction)
        XCTAssertTrue(f1.visualAids.isEmpty)
        let f1Loaded = loadedRoutineEntries(f1LegacyRoutineEntry)
        XCTAssertEqual(f1Loaded.count, 1)
        XCTAssertNil(f1Loaded.first?.instruction)
        let f1Keys = allJSONKeys(in: try jsonObject(f1))
        XCTAssertTrue(f1Keys.contains("visualAids"))
        XCTAssertFalse(f1Keys.contains("instruction"),
                       "encoding a legacy entry adds no instruction key")

        // The value round trip through the shipping mock (no raw JSON
        // tricks involved) stays equal too.
        let mock = MockEncryptedLocalStorage()
        assertSuccess(mock.write(key: ShippingKey.routineEntries, value: [f1]))
        XCTAssertEqual(RoutineStore(storage: mock).loadEntries(), [f1])

        // F-2: legacy extras with only a photo filename.
        let f2Index = try decodeExtrasIndex(f2LegacyExtras)
        XCTAssertEqual(f2Index["evt-legacy"]?.photoFilename, "a.jpg")
        XCTAssertNil(f2Index["evt-legacy"]?.instruction)
        let f2Loaded = try XCTUnwrap(loadedExtras(f2LegacyExtras))
        XCTAssertEqual(f2Loaded["evt-legacy"]?.photoFilename, "a.jpg")
        XCTAssertNil(f2Loaded["evt-legacy"]?.instruction)

        // F-3: text instruction; raw kind "text", text trimmed.
        let f3 = try decodeEntry(f3TextInstruction)
        XCTAssertEqual(f3.instruction?.kind, "text")
        XCTAssertEqual(f3.instruction?.text, "  Take the blue pill  ")
        XCTAssertEqual(f3.instruction?.trimmedText, "Take the blue pill")
        XCTAssertTrue(f3.instruction?.isPresent == true)
        XCTAssertEqual(InstructionPresentation.state(for: f3.instruction,
                                                     isExpected: true),
                       .text(text: "Take the blue pill"))
        let f3Loaded = loadedRoutineEntries(f3TextInstruction)
        XCTAssertEqual(f3Loaded.first?.instruction, f3.instruction)

        // F-4: image with caption + filename.
        let f4 = try decodeEntry(f4ImageInstruction)
        XCTAssertEqual(f4.instruction?.kind, "image")
        XCTAssertEqual(f4.instruction?.filename, "x.jpg")
        XCTAssertEqual(f4.instruction?.caption, "the blue box")
        XCTAssertTrue(f4.instruction?.isPresent == true)
        XCTAssertEqual(InstructionPresentation.state(for: f4.instruction,
                                                     isExpected: true),
                       .image(filename: "x.jpg", caption: "the blue box"))
        XCTAssertEqual(loadedRoutineEntries(f4ImageInstruction).first?.instruction,
                       f4.instruction)

        // F-4b: image with a wrong-typed text field. The field costs only
        // itself; the filename survives.
        let f4b = try decodeEntry(f4bImageWrongTypedText)
        XCTAssertEqual(f4b.instruction?.kind, "image")
        XCTAssertNil(f4b.instruction?.text)
        XCTAssertEqual(f4b.instruction?.filename, "x.jpg")
        XCTAssertEqual(loadedRoutineEntries(f4bImageWrongTypedText).first?.instruction,
                       f4b.instruction)

        // F-5: video instruction.
        let f5 = try decodeEntry(f5VideoInstruction)
        XCTAssertEqual(f5.instruction?.kind, "video")
        XCTAssertEqual(f5.instruction?.filename, "clip.mov")
        XCTAssertEqual(f5.instruction?.caption, "Watch this")
        XCTAssertEqual(InstructionPresentation.state(for: f5.instruction,
                                                     isExpected: true),
                       .video(filename: "clip.mov", caption: "Watch this"))
        XCTAssertEqual(loadedRoutineEntries(f5VideoInstruction).first?.instruction,
                       f5.instruction)

        // F-6a: unknown link kind. Verbatim round trip, unsupported display.
        let f6a = try decodeEntry(f6aLinkInstruction)
        XCTAssertEqual(f6a.instruction?.kind, "link")
        XCTAssertEqual(f6a.instruction?.url, "stored-url")
        XCTAssertTrue(f6a.instruction?.isPresent == true)
        XCTAssertEqual(InstructionPresentation.state(for: f6a.instruction,
                                                     isExpected: true),
                       .unsupported(text: nil))
        XCTAssertEqual(loadedRoutineEntries(f6aLinkInstruction).first?.instruction,
                       f6a.instruction)
        let f6aKeys = allJSONKeys(in: try jsonObject(f6a))
        XCTAssertTrue(f6aKeys.contains("url"))

        // F-6b: unknown audio kind with text.
        let f6b = try decodeEntry(f6bAudioInstruction)
        XCTAssertEqual(f6b.instruction?.kind, "audio")
        XCTAssertEqual(f6b.instruction?.text, "Listen")
        XCTAssertEqual(InstructionPresentation.state(for: f6b.instruction,
                                                     isExpected: true),
                       .unsupported(text: "Listen"))
        XCTAssertEqual(loadedRoutineEntries(f6bAudioInstruction).first?.instruction,
                       f6b.instruction)

        // F-7: wrong-typed instruction in both owners. The owner survives;
        // the instruction is nil.
        let f7Entry = try decodeEntry(f7RoutineInstructionString)
        XCTAssertNil(f7Entry.instruction)
        XCTAssertEqual(f7Entry.titleOverride, "Evening walk")
        let f7Loaded = loadedRoutineEntries(f7RoutineInstructionString)
        XCTAssertEqual(f7Loaded.count, 1)
        XCTAssertNil(f7Loaded.first?.instruction)
        XCTAssertEqual(f7Loaded.first?.titleOverride, "Evening walk")
        let f7ExtrasLoaded = try XCTUnwrap(loadedExtras(f7ExtrasInstructionString))
        XCTAssertNotNil(f7ExtrasLoaded["evt-oops"])
        XCTAssertNil(f7ExtrasLoaded["evt-oops"]?.instruction)
        XCTAssertNil(f7ExtrasLoaded["evt-oops"]?.photoFilename)

        // F-8: unknown future field. Loads; re-encode drops it.
        let f8 = try decodeEntry(f8InstructionFutureField)
        XCTAssertEqual(f8.instruction,
                       Instruction(kind: "text", text: "Take the blue pill"))
        let f8Keys = allJSONKeys(in: try jsonObject(f8))
        XCTAssertTrue(f8Keys.contains("instruction"))
        XCTAssertFalse(f8Keys.contains("future_field"),
                       "unknown nested fields do not round trip")
        XCTAssertEqual(loadedRoutineEntries(f8InstructionFutureField).first?.instruction,
                       f8.instruction)

        // F-9: empty extras index, not an error.
        let f9Snapshot = try XCTUnwrap(loadedExtras(f9EmptyExtras))
        XCTAssertTrue(f9Snapshot.isEmpty)

        // F-10: explicit null in both owners.
        let f10 = try decodeEntry(f10RoutineInstructionNull)
        XCTAssertNil(f10.instruction)
        XCTAssertNil(loadedRoutineEntries(f10RoutineInstructionNull).first?.instruction)
        let f10Extras = try XCTUnwrap(loadedExtras(f10ExtrasInstructionNull))
        XCTAssertNotNil(f10Extras["evt-null"])
        XCTAssertNil(f10Extras["evt-null"]?.instruction)

        // F-11: traversal filenames. They decode (the model is not the
        // security boundary); the video store and image loader refuse them
        // before any URL is built, and every image failure maps to the one
        // plain fallback key.
        let f11 = try decodeEntry(f11TraversalFilename)
        XCTAssertEqual(f11.instruction?.filename, "../x.jpg")
        XCTAssertEqual(InstructionPresentation.state(for: f11.instruction,
                                                     isExpected: true),
                       .image(filename: "../x.jpg", caption: nil),
                       "the card maps by kind; availability is a separate seam")
        let imageLoader = VisualAidInstructionImageLoader(store: imageStore,
                                                          entryId: routineOwnerId)
        let unsafeNames = ["../x.jpg", "..\\x.jpg", "/abs/x.jpg", "", ".", ".."]
        for name in unsafeNames {
            XCTAssertFalse(InstructionFilename.isPlain(name), "must refuse: \(name)")
            XCTAssertEqual(videoStore.availability(filename: name, owner: routineOwner),
                           .rejectedFilename)
            XCTAssertNil(videoStore.fileURL(filename: name, owner: routineOwner))
            assertFailure(videoStore.delete(name, for: routineOwner),
                          equals: .deleteFailed)
            switch imageLoader.loadImage(filename: name) {
            case .failure(.rejectedFilename):
                break
            case .failure(let error):
                XCTFail("expected rejectedFilename for \(name), got \(error)")
            case .success:
                XCTFail("the image loader must refuse \(name)")
            }
        }
        XCTAssertEqual(InstructionMessageKey.forImage(.rejectedFilename),
                       "instruction.image.unavailable")

        // F-12: video instruction whose file is absent. The card still maps
        // to .video; availability and playback say missing, and playback
        // never starts.
        let f12 = try decodeEntry(f12AbsentVideo)
        XCTAssertEqual(f12.instruction?.kind, "video")
        let f12Id = try XCTUnwrap(UUID(uuidString: "12121212-1212-1212-1212-121212121212"))
        let f12Owner = InstructionOwner.routine(f12Id)
        let f12Filename = try XCTUnwrap(f12.instruction?.filename)
        XCTAssertEqual(InstructionPresentation.state(for: f12.instruction,
                                                     isExpected: true),
                       .video(filename: "missing.mov", caption: "Watch this"))
        XCTAssertEqual(videoStore.availability(filename: f12Filename, owner: f12Owner),
                       .missingFile)
        XCTAssertNil(videoStore.fileURL(filename: f12Filename, owner: f12Owner))
        let playbackURL: (InstructionOwner, String) -> URL? = { owner, filename in
            guard case .available(let url) = videoStore.availability(filename: filename,
                                                                     owner: owner) else {
                return nil
            }
            return url
        }
        XCTAssertNil(playbackURL(f12Owner, f12Filename),
                     "no playable URL means the playback control never starts")

        // No fixture load deleted or rewrote planted media, and no storage
        // delete path ran.
        XCTAssertEqual(try Data(contentsOf: routineVideo.url), routineBytes)
        XCTAssertEqual(try Data(contentsOf: eventVideo.url), eventBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aidURL.path))
        XCTAssertEqual(videoStore.availability(filename: routineVideo.filename,
                                               owner: routineOwner),
                       .available(routineVideo.url))
        XCTAssertEqual(videoStore.availability(filename: eventVideo.filename,
                                               owner: eventOwner),
                       .available(eventVideo.url))
        XCTAssertEqual(raw.deleteCallCount, 0)
    }

    // MARK: - 8. Medication fixtures and notification taxonomy unchanged

    func testMedicationFixturesUnchanged() throws {
        // Legacy medication payload: no instruction key, and none of the
        // newer optional fields either. Strict core fields still decode and
        // every optional field is nil/defaulted — the instruction feature
        // added no field and changed no decode rule.
        let entry = try decodeMedication(legacyMedicationJSON)
        XCTAssertEqual(entry.medicationName, "Amlodipine")
        XCTAssertEqual(entry.doseDescription, "1 tablet")
        XCTAssertEqual(entry.scheduleTimes, [DateComponents(hour: 8, minute: 0)])
        XCTAssertEqual(entry.frequency, .daily)
        XCTAssertEqual(entry.ackWindowMinutes, 5)
        XCTAssertEqual(entry.maxRefireCount, 5)
        XCTAssertEqual(entry.escalationWindowMinutes, 60)
        XCTAssertEqual(entry.doubleDoseWindowHours, 4)
        XCTAssertTrue(entry.photoVerificationEnabled)
        XCTAssertNil(entry.purpose)
        XCTAssertTrue(entry.visualAids.isEmpty)
        XCTAssertNil(entry.quantity)
        XCTAssertNil(entry.slot)
        XCTAssertNil(entry.mealRelation)

        let medicationKeys = allJSONKeys(in: try jsonObject(entry))
        XCTAssertFalse(medicationKeys.contains("instruction"),
                       "the medication model never grows an instruction field")
        XCTAssertTrue(medicationKeys.contains("scheduleTimes"))
        XCTAssertTrue(medicationKeys.contains("ackWindowMinutes"))

        // The encoded top-level field set is exactly the pre-feature set:
        // no field was added, renamed or dropped by this feature.
        let encodedMedication = try XCTUnwrap(
            try jsonObject(entry) as? [String: Any])
        XCTAssertEqual(Set(encodedMedication.keys),
                       Set(["id", "userProfileId", "medicationName",
                            "doseDescription", "scheduleTimes", "frequency",
                            "ackWindowMinutes", "maxRefireCount",
                            "escalationWindowMinutes", "doubleDoseWindowHours",
                            "photoVerificationEnabled", "confirmationDescription",
                            "visualAids"]))

        // The notification taxonomy is byte-for-byte the pre-feature set.
        XCTAssertEqual(NotificationCategories.medicationReminder, "MEDICATION_REMINDER")
        XCTAssertEqual(NotificationCategories.eventReminder, "EVENT_REMINDER")
        XCTAssertEqual(NotificationCategories.openEventAction, "OPEN_EVENT")
        XCTAssertEqual(NotificationCategories.acknowledgeMedicationAction,
                       "ACKNOWLEDGE_MEDICATION")
        XCTAssertEqual(NotificationCategories.eventIdentifierKey, "event_id")

        for locale in [en, ne] {
            let categories = NotificationCategories.all(locale: locale)
            XCTAssertEqual(categories.count, 2,
                           "exactly the medication and event categories")
            let byIdentifier = Dictionary(uniqueKeysWithValues: categories.map {
                ($0.identifier, $0)
            })
            let medication = try XCTUnwrap(byIdentifier[NotificationCategories.medicationReminder])
            let event = try XCTUnwrap(byIdentifier[NotificationCategories.eventReminder])
            XCTAssertEqual(medication.actions.map { $0.identifier },
                           [NotificationCategories.acknowledgeMedicationAction])
            XCTAssertEqual(event.actions.map { $0.identifier },
                           [NotificationCategories.openEventAction])
            XCTAssertTrue(medication.options.contains(.customDismissAction))
            XCTAssertTrue(event.options.contains(.customDismissAction))
            XCTAssertTrue(medication.intentIdentifiers.isEmpty)
            XCTAssertTrue(event.intentIdentifiers.isEmpty)
            for category in categories {
                XCTAssertFalse(category.identifier.localizedCaseInsensitiveContains("instruction"))
                for action in category.actions {
                    XCTAssertFalse(action.identifier.localizedCaseInsensitiveContains("instruction"))
                }
            }
        }

        // Source pins: the medication scheduler never learns about
        // instructions, and the instruction feature never borrows the
        // medication taxonomy.
        let medicationSources = FeatureSourceScan.swiftFiles(
            in: "ElderlyAssistant/Services/MedicationScheduler")
        XCTAssertFalse(medicationSources.isEmpty)
        var medicationCode = ""
        for url in medicationSources {
            let code = FeatureSourceScan.codeText(of: url)
            medicationCode += code + "\n"
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "instruction",
                                                      in: code),
                         "\(FeatureSourceScan.relativePath(of: url)) mentions instructions")
        }
        // The safety timers are still the medication scheduler's own
        // configuration (the instruction feature neither owns nor moves
        // them).
        for timerField in ["ackWindowMinutes", "maxRefireCount",
                           "escalationWindowMinutes", "doubleDoseWindowHours"] {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: timerField,
                                                         in: medicationCode),
                            "medication timer field \(timerField) disappeared")
        }
        let categoriesSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent(
                    "ElderlyAssistant/Services/Notifications/NotificationCategories.swift"))
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "instruction", in: categoriesSource))
        for url in instructionFeatureFiles() {
            let code = FeatureSourceScan.codeText(of: url)
            for identifier in ["MEDICATION_REMINDER", "ACKNOWLEDGE_MEDICATION",
                               "EVENT_REMINDER", "OPEN_EVENT"] {
                XCTAssertNil(FeatureSourceScan.firstMatch(
                    of: NSRegularExpression.escapedPattern(for: identifier), in: code),
                    "\(FeatureSourceScan.relativePath(of: url)) borrows \(identifier)")
            }
        }

        // Behavioural pin: the cancel path stays SCOPED. Disabling one entry
        // cancels exactly that entry's occurrences and leaves the other
        // entry armed.
        let harness = makeRoutineHarness()
        let first = makeEntry(title: "Evening walk")
        let second = makeEntry(title: "Morning walk")
        XCTAssertTrue(harness.scheduler.addEntry(first))
        XCTAssertTrue(harness.scheduler.addEntry(second))
        harness.scheduler.scheduleAll()

        let firstIds = Set(harness.alarm.scheduled.filter {
            $0.value.entryId == first.id
        }.keys)
        let secondIds = Set(harness.alarm.scheduled.filter {
            $0.value.entryId == second.id
        }.keys)
        XCTAssertFalse(firstIds.isEmpty)
        XCTAssertFalse(secondIds.isEmpty)
        harness.alarm.cancelled.removeAll()

        harness.scheduler.setEnabled(first.id, enabled: false)
        XCTAssertEqual(Set(harness.alarm.cancelled), firstIds,
                       "only the disabled entry's occurrences are cancelled")
        XCTAssertTrue(secondIds.isSubset(of: Set(harness.alarm.scheduled.keys)),
                      "the other entry stays armed")
        XCTAssertFalse(harness.alarm.scheduled.keys.contains { firstIds.contains($0) })

        // The routine protocol has ONLY the scoped cancel; no cancelAll
        // API was added for the instruction feature.
        let alarmProtocolSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent(
                    "ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "func cancelRoutineReminders\\(occurrenceIds: \\[UUID\\]\\)",
            in: alarmProtocolSource))
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "cancelAll",
                                                  in: alarmProtocolSource))
    }

    // MARK: - 9. Visual-aid fixtures and the delete-signature boundary

    @MainActor
    func testVisualAidFixturesUnchanged() throws {
        // A legacy entry with visual aids and no instruction still encodes
        // and decodes byte-equivalently.
        let aid = VisualAid(filename: "legacy.jpg", caption: "the old box")
        let legacyEntry = makeEntry(aids: [aid])
        let encodedKeys = allJSONKeys(in: try jsonObject(legacyEntry))
        XCTAssertTrue(encodedKeys.contains("visualAids"))
        XCTAssertFalse(encodedKeys.contains("instruction"))
        let decoded = try JSONDecoder().decode(RoutineEntry.self,
                                               from: JSONEncoder().encode(legacyEntry))
        XCTAssertEqual(decoded, legacyEntry)
        XCTAssertEqual(decoded.visualAids, [aid])

        // Real image store + real scheduler: an entry's visual aid file
        // survives text, video and removal instruction writes.
        let imageStore = makeImageStore()
        let videoStore = makeVideoStore()
        let harness = makeRoutineHarness(videoStore: videoStore,
                                         visualAidStore: imageStore)
        let entryId = UUID()
        let savedAid = try XCTUnwrap(imageStore.save(makeImage(), for: entryId,
                                                     caption: "the old box"))
        let entry = makeEntry(id: entryId, aids: [savedAid])
        XCTAssertTrue(harness.scheduler.addEntry(entry))
        let aidURL = try XCTUnwrap(imageStore.existingFileURL(savedAid, for: entryId))

        assertSuccess(harness.scheduler.setInstruction(textCommit("Take the blue pill"),
                                                       entryId: entryId))
        XCTAssertEqual(harness.scheduler.entry(for: entryId)?.visualAids, [savedAid])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aidURL.path))

        let videoCommit = try makeVideoCommit(store: videoStore, root: .routines)
        assertSuccess(harness.scheduler.setInstruction(videoCommit, entryId: entryId))
        XCTAssertEqual(harness.scheduler.entry(for: entryId)?.visualAids, [savedAid])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aidURL.path))
        XCTAssertEqual(videoFilenames(videoStore,
                                      owner: .routine(entryId)).count, 1)

        assertSuccess(harness.scheduler.setInstruction(removeCommit(),
                                                       entryId: entryId))
        XCTAssertNil(harness.scheduler.entry(for: entryId)?.instruction)
        XCTAssertEqual(harness.scheduler.entry(for: entryId)?.visualAids, [savedAid])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aidURL.path),
                      "removing an instruction never removes a visual aid")
        XCTAssertTrue(videoFilenames(videoStore, owner: .routine(entryId)).isEmpty)

        // Event extras: the photo filename and the instruction are
        // independent fields; neither write clobbers the other.
        let extras = makeEventExtrasStore()
        XCTAssertTrue(extras.track(eventId: "evt-aids"))
        XCTAssertTrue(extras.setPhotoFilename("photo.jpg", forEventId: "evt-aids"))
        XCTAssertTrue(extras.setInstruction(
            Instruction(kind: "text", text: "Take the blue pill"),
            forEventId: "evt-aids"))
        XCTAssertEqual(extras.extras(forEventId: "evt-aids")?.photoFilename, "photo.jpg")
        XCTAssertEqual(extras.extras(forEventId: "evt-aids")?.instruction?.kind, "text")
        XCTAssertTrue(extras.setInstruction(nil, forEventId: "evt-aids"))
        XCTAssertEqual(extras.extras(forEventId: "evt-aids")?.photoFilename, "photo.jpg",
                       "clearing the instruction preserves the photo")
        XCTAssertNil(extras.extras(forEventId: "evt-aids")?.instruction)
        XCTAssertTrue(extras.setPhotoFilename(nil, forEventId: "evt-aids"))
        XCTAssertNil(extras.extras(forEventId: "evt-aids")?.photoFilename)

        // N-1 boundary: only the video store has typed delete results. The
        // image stores keep their shipping best-effort Void signatures.
        let storageRoot = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Storage")
        let visualAidSource = FeatureSourceScan.codeText(
            of: storageRoot.appendingPathComponent("VisualAidStore.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "func delete\\(_ aid: VisualAid, for entryId: UUID\\) \\{",
            in: visualAidSource))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "func deleteAll\\(for entryId: UUID\\) \\{",
            in: visualAidSource))
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: "func delete\\(_ aid: VisualAid[^\\n]*->", in: visualAidSource))
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: "func deleteAll\\(for entryId: UUID\\)[^\\n]*->", in: visualAidSource))

        let contactPhotoSource = FeatureSourceScan.codeText(
            of: storageRoot.appendingPathComponent("ContactPhotoStore.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "func delete\\(named filename: String\\?\\) \\{",
            in: contactPhotoSource))
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: "func delete\\(named filename: String\\?\\)[^\\n]*->",
            in: contactPhotoSource))

        let videoStoreSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent(
                    "ElderlyAssistant/Services/Instructions/InstructionVideoStore.swift"))
        let deleteStart = try XCTUnwrap(videoStoreSource.range(
            of: "func delete(_ filename: String,"))
        let deleteEnd = try XCTUnwrap(videoStoreSource.range(
            of: "\n    }", range: deleteStart.upperBound..<videoStoreSource.endIndex))
        let deleteRegion = String(videoStoreSource[deleteStart.lowerBound..<deleteEnd.upperBound])
        XCTAssertTrue(deleteRegion.contains("-> Result<Void, InstructionStorageError>"),
                      "the video store's delete keeps its typed failure channel")
    }

    // MARK: - 10. One video per owner, across replace/remove

    @MainActor
    func testSingleVideoPerOwnerInvariant() throws {
        let videoStore = makeVideoStore()

        // Routine owner.
        let harness = makeRoutineHarness(videoStore: videoStore)
        let entry = makeEntry()
        XCTAssertTrue(harness.scheduler.addEntry(entry))
        let routineOwner = InstructionOwner.routine(entry.id)

        let firstCommit = try makeVideoCommit(store: videoStore, root: .routines)
        assertSuccess(harness.scheduler.setInstruction(firstCommit, entryId: entry.id))
        let firstFilename = try XCTUnwrap(
            harness.scheduler.entry(for: entry.id)?.instruction?.filename)
        XCTAssertEqual(videoFilenames(videoStore, owner: routineOwner), [firstFilename])

        let secondCommit = try makeVideoCommit(store: videoStore, root: .routines)
        assertSuccess(harness.scheduler.setInstruction(secondCommit, entryId: entry.id))
        let secondFilename = try XCTUnwrap(
            harness.scheduler.entry(for: entry.id)?.instruction?.filename)
        XCTAssertNotEqual(firstFilename, secondFilename)
        XCTAssertEqual(videoFilenames(videoStore, owner: routineOwner), [secondFilename],
                       "a replace leaves exactly one instruction video")
        XCTAssertEqual(videoStore.availability(filename: firstFilename, owner: routineOwner),
                       .missingFile,
                       "the replaced file is deleted")

        assertSuccess(harness.scheduler.setInstruction(textCommit("Take the blue pill"),
                                                       entryId: entry.id))
        XCTAssertTrue(videoFilenames(videoStore, owner: routineOwner).isEmpty,
                      "a text instruction deletes the previous video")

        let thirdCommit = try makeVideoCommit(store: videoStore, root: .routines)
        assertSuccess(harness.scheduler.setInstruction(thirdCommit, entryId: entry.id))
        XCTAssertEqual(videoFilenames(videoStore, owner: routineOwner).count, 1)
        assertSuccess(harness.scheduler.setInstruction(removeCommit(), entryId: entry.id))
        XCTAssertTrue(videoFilenames(videoStore, owner: routineOwner).isEmpty)
        XCTAssertNil(harness.scheduler.entry(for: entry.id)?.instruction)

        // Event owner, same transaction through the real event service.
        let extras = makeEventExtrasStore()
        XCTAssertTrue(extras.track(eventId: "evt-single"))
        let service = makeEventService(extras: extras, videoStore: videoStore)
        let eventOwner = InstructionOwner.event("evt-single")

        let eventFirst = try makeVideoCommit(store: videoStore, root: .events)
        assertSuccess(service.setInstruction(eventFirst, forEventId: "evt-single"))
        let eventFirstFilename = try XCTUnwrap(
            extras.extras(forEventId: "evt-single")?.instruction?.filename)
        XCTAssertEqual(videoFilenames(videoStore, owner: eventOwner),
                       [eventFirstFilename])

        let eventSecond = try makeVideoCommit(store: videoStore, root: .events)
        assertSuccess(service.setInstruction(eventSecond, forEventId: "evt-single"))
        let eventSecondFilename = try XCTUnwrap(
            extras.extras(forEventId: "evt-single")?.instruction?.filename)
        XCTAssertNotEqual(eventFirstFilename, eventSecondFilename)
        XCTAssertEqual(videoFilenames(videoStore, owner: eventOwner),
                       [eventSecondFilename])
        XCTAssertEqual(videoStore.availability(filename: eventFirstFilename,
                                               owner: eventOwner),
                       .missingFile)

        assertSuccess(service.setInstruction(textCommit("Take the blue pill"),
                                             forEventId: "evt-single"))
        XCTAssertTrue(videoFilenames(videoStore, owner: eventOwner).isEmpty)
        XCTAssertEqual(extras.extras(forEventId: "evt-single")?.instruction?.kind, "text")
        XCTAssertNil(extras.extras(forEventId: "evt-single")?.instruction?.filename)

        let eventThird = try makeVideoCommit(store: videoStore, root: .events)
        assertSuccess(service.setInstruction(eventThird, forEventId: "evt-single"))
        XCTAssertEqual(videoFilenames(videoStore, owner: eventOwner).count, 1)
        assertSuccess(service.setInstruction(removeCommit(), forEventId: "evt-single"))
        XCTAssertTrue(videoFilenames(videoStore, owner: eventOwner).isEmpty)
        XCTAssertNil(extras.extras(forEventId: "evt-single")?.instruction)
    }

    // MARK: - 11. No new egress in the instruction feature

    /// Textual scans cannot prove the absence of INDIRECT egress (a helper
    /// outside these roots, a dynamically built key, or a framework sink
    /// this list does not name). They prove the feature's own sources name
    /// no network, photo-library, upload, share or document-picker surface,
    /// and the planted-token control proves the detector actually fires.
    func testNoNewEgressSourceScan() throws {
        let egressPatterns = [
            #"\bURLSession\b"#,
            #"\bURLRequest\b"#,
            #"\bNWConnection\b"#,
            #"\bWebSocket\b"#,
            #"\bCFSocket\w*"#,
            #"\bCKContainer\b"#,
            #"\bUIActivityViewController\b"#,
            #"\bUIDocumentPickerViewController\b"#,
            #"\bPHPhotoLibrary\b"#,
            #"\bPHAsset\b"#,
            #"\bPHFetchResult\b"#,
            #"\bPHImageManager\b"#,
            #"\bPHCachingImageManager\b"#,
            #"\bPHAuthorizationStatus\b"#,
            #"\brequestAuthorization\b"#,
            #"^import Photos$"#,
            #"\bupload\b"#,
            #"\bdataTask\b"#,
            #"\bdownloadTask\b"#,
            #"\bputData\b"#,
            #"\bFirebase\w*"#,
            #"\bCloudKit\b"#
        ]

        for url in instructionFeatureFiles() {
            let code = FeatureSourceScan.codeText(of: url)
            for pattern in egressPatterns {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                             "\(FeatureSourceScan.relativePath(of: url)) matches \(pattern)")
            }
        }
        let section = coordinatorInstructionSection()
        XCTAssertFalse(section.isEmpty)
        for pattern in egressPatterns {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: section),
                         "coordinator instruction composition matches \(pattern)")
        }

        // Falsifiability control: every pattern must fire on a planted
        // file. If the detector silently stopped matching, this fails.
        let plantedSource = #"""
        import Photos
        import Foundation
        let session = URLSession.shared
        let request = URLRequest(url: localURL)
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let socket = WebSocket(url: localURL)
        let classic = CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)
        let container = CKContainer.default()
        let share = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [])
        let library = PHPhotoLibrary.shared()
        let asset = PHAsset()
        let fetch = PHFetchResult<PHAsset>()
        let manager = PHImageManager.default()
        let caching = PHCachingImageManager()
        let status = PHAuthorizationStatus.authorized
        try await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        upload(data)
        session.dataTask(with: request)
        session.downloadTask(with: request)
        let cloud = putData(data)
        let firebase = FirebaseApp.configure()
        let ck = CloudKit.self
        """#
        let planted = tempRoot.appendingPathComponent("planted-egress-control.swift")
        try Data(plantedSource.utf8).write(to: planted)
        let plantedCode = FeatureSourceScan.codeText(of: planted)
        for pattern in egressPatterns {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: plantedCode),
                            "the detector missed a planted token for \(pattern)")
        }

        // Negative control: in-process pickers/sessions and a local file URL
        // are NOT egress and must not be flagged.
        let negativeSource = #"""
        import PhotosUI
        import AVFoundation
        let picker = PHPickerViewController(configuration: configuration)
        let session = AVAudioSession.sharedInstance()
        let local = URL(fileURLWithPath: "/tmp/synthetic.bin")
        let provider = UIActivityItemProvider(placeholderItem: "")
        """#
        let negative = tempRoot.appendingPathComponent("negative-egress-control.swift")
        try Data(negativeSource.utf8).write(to: negative)
        let negativeCode = FeatureSourceScan.codeText(of: negative)
        for pattern in egressPatterns {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: negativeCode),
                         "false positive on a non-egress surface for \(pattern)")
        }
    }

    // MARK: - 12. AI / voice / LLM independence

    /// This proves the instruction feature's sources have NO CODE DEPENDENCY
    /// on the AI, voice or LLM stack. It does not prove runtime isolation:
    /// a process-wide crash or resource exhaustion in another component can
    /// still affect the app, and a textual scan cannot see indirect edges
    /// outside these roots. The planted control keeps the detector honest.
    func testCrashIndependenceSourceScan() throws {
        let aiVoicePatterns = [
            #"\bIntentRouter\b"#,
            #"\bCommandInterpreter\b"#,
            #"\bLlamaCommandInterpreter\b"#,
            #"\bGeminiCommandInterpreter\b"#,
            #"\bLocalIntentInterpreter\b"#,
            #"\bLocalBrainChain\b"#,
            #"\bCloudBrainProvider\b"#,
            #"\bCloudChat\b"#,
            #"\bChatResponding\b"#,
            #"\bChatIntentClassifier\b"#,
            #"\bGeminiSpeechRecognizer\b"#,
            #"\bWhisper\w*"#,
            #"\bSFSpeechRecognizer\b"#,
            #"\bAVAudioEngine\b"#,
            #"\bAVSpeechSynthesizer\b"#,
            #"\bDialogueManager\b"#,
            #"\bSpeakerBiometricService\b"#,
            #"\bWakeAcknowledgmentService\b"#,
            #"\bAudioSessionManager\b"#,
            #"\bReplySpeakLane\b"#,
            #"\bAckFastLane\b"#,
            #"\bIntentEncoder\w*"#,
            #"\bModelStore\b"#,
            #"\bTTS\w*"#
        ]

        for url in instructionFeatureFiles() {
            let code = FeatureSourceScan.codeText(of: url)
            for pattern in aiVoicePatterns {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                             "\(FeatureSourceScan.relativePath(of: url)) depends on \(pattern)")
            }
        }
        let section = coordinatorInstructionSection()
        XCTAssertFalse(section.isEmpty)
        for pattern in aiVoicePatterns {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: section),
                         "coordinator instruction composition depends on \(pattern)")
        }

        let plantedSource = #"""
        let router = IntentRouter()
        let interpreter = CommandInterpreter()
        let llama = LlamaCommandInterpreter()
        let gemini = GeminiCommandInterpreter()
        let local = LocalIntentInterpreter()
        let chain = LocalBrainChain()
        let cloud = CloudBrainProvider()
        let chat = CloudChat()
        let responder: ChatResponding
        let classifier = ChatIntentClassifier()
        let speech = GeminiSpeechRecognizer()
        let whisper = WhisperKit()
        let sfSpeech = SFSpeechRecognizer()
        let audio = AVAudioEngine()
        let synth = AVSpeechSynthesizer()
        let dialogue = DialogueManager()
        let speaker = SpeakerBiometricService()
        let wake = WakeAcknowledgmentService()
        let audioSession = AudioSessionManager()
        let replyLane = ReplySpeakLane()
        let ackLane = AckFastLane()
        let encoder = IntentEncoderRuntime()
        let store = ModelStore()
        let voice = TTSVoice()
        """#
        let planted = tempRoot.appendingPathComponent("planted-ai-control.swift")
        try Data(plantedSource.utf8).write(to: planted)
        let plantedCode = FeatureSourceScan.codeText(of: planted)
        for pattern in aiVoicePatterns {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: plantedCode),
                            "the detector missed a planted AI/voice token for \(pattern)")
        }

        // Negative control: audio-session/AVKit/PHPicker surfaces are not
        // AI-stack components and must not be flagged.
        let negativeSource = #"""
        let session = AVAudioSession.sharedInstance()
        let camera = AVCaptureDevice.default(for: .video)
        let picker = PHPickerViewController(configuration: configuration)
        VoiceOver reads this line.
        let player = AVKitVideoPlayer()
        """#
        let negative = tempRoot.appendingPathComponent("negative-ai-control.swift")
        try Data(negativeSource.utf8).write(to: negative)
        let negativeCode = FeatureSourceScan.codeText(of: negative)
        for pattern in aiVoicePatterns {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: negativeCode),
                         "false positive on a non-AI surface for \(pattern)")
        }
    }

    // MARK: - Source roots

    /// The instruction feature's own sources plus the shared files its
    /// write/fire/notification seams live in. `FeatureSourceScan.codeText`
    /// strips comments, so a documentation example cannot fail the suite.
    private func instructionFeatureFiles() -> [URL] {
        var files = FeatureSourceScan.swiftFiles(
            in: "ElderlyAssistant/Services/Instructions")
        let ios = FeatureSourceScan.iosDirectory()
        let shared = [
            "ElderlyAssistant/App/InstructionViews.swift",
            "ElderlyAssistant/App/InstructionCapture.swift",
            "ElderlyAssistant/Services/Notifications/RoutineNotificationContent.swift",
            "ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift",
            "ElderlyAssistant/Services/Reminders/RoutineScheduler.swift",
            "ElderlyAssistant/Services/Storage/EventExtrasStore.swift",
            "ElderlyAssistant/Services/Events/FreeFormEventService.swift"
        ]
        for relative in shared {
            let url = ios.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing shared feature source \(relative)")
            files.append(url)
        }
        return files
    }

    /// The coordinator's instruction composition section, comment-free and
    /// sliced between its two named markers. The slice is what makes the
    /// scan about the feature's coordinator code rather than about the
    /// whole 15k-line composition root.
    private func coordinatorInstructionSection() -> String {
        let source = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        guard let start = source.range(
            of: "let instructionVideoStore = InstructionVideoStore()") else {
            XCTFail("cannot find the instruction composition start marker")
            return ""
        }
        guard let end = source.range(
            of: "\nextension AppCoordinator",
            range: start.upperBound..<source.endIndex) else {
            XCTFail("cannot find the instruction composition end marker")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - Fixture JSON (synthetic; design L2 §4.7)

    private let f1LegacyRoutineEntry = #"""
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": []
    }
    """#

    private let f2LegacyExtras = #"""
    {"evt-legacy": {"photoFilename": "a.jpg"}}
    """#

    private let f3TextInstruction = #"""
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "text", "text": "  Take the blue pill  "}
    }
    """#

    private let f4ImageInstruction = #"""
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "image", "caption": "the blue box", "filename": "x.jpg"}
    }
    """#

    private let f4bImageWrongTypedText = #"""
    {
      "id": "44444444-4444-4444-4444-44444444444b",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "image", "text": 7, "filename": "x.jpg"}
    }
    """#

    private let f5VideoInstruction = #"""
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "video", "caption": "Watch this", "filename": "clip.mov"}
    }
    """#

    private let f6aLinkInstruction = #"""
    {
      "id": "66666666-6666-6666-6666-666666666666",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "link", "url": "stored-url"}
    }
    """#

    private let f6bAudioInstruction = #"""
    {
      "id": "66666666-6666-6666-6666-66666666666b",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "audio", "text": "Listen"}
    }
    """#

    private let f7RoutineInstructionString = #"""
    {
      "id": "77777777-7777-7777-7777-777777777777",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": "oops"
    }
    """#

    private let f7ExtrasInstructionString = #"""
    {"evt-oops": {"instruction": "oops"}}
    """#

    private let f8InstructionFutureField = #"""
    {
      "id": "88888888-8888-8888-8888-888888888888",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {
        "kind": "text",
        "text": "Take the blue pill",
        "future_field": 42
      }
    }
    """#

    private let f9EmptyExtras = #"""
    {}
    """#

    private let f10RoutineInstructionNull = #"""
    {
      "id": "10101010-1010-1010-1010-101010101010",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": null
    }
    """#

    private let f10ExtrasInstructionNull = #"""
    {"evt-null": {"instruction": null}}
    """#

    private let f11TraversalFilename = #"""
    {
      "id": "99999999-9999-9999-9999-999999999999",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "image", "filename": "../x.jpg"}
    }
    """#

    private let f12AbsentVideo = #"""
    {
      "id": "12121212-1212-1212-1212-121212121212",
      "category": "walk",
      "titleOverride": "Evening walk",
      "scheduleTimes": [{"hour": 17, "minute": 30}],
      "frequency": "daily",
      "weekdays": [],
      "isEnabled": true,
      "visualAids": [],
      "instruction": {"kind": "video", "caption": "Watch this", "filename": "missing.mov"}
    }
    """#

    /// A pre-instruction medication payload: none of `purpose`,
    /// `visualAids`, `quantity`, `slot` or `mealRelation` exists, and the
    /// strict core fields are all present.
    private let legacyMedicationJSON = #"""
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "userProfileId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "medicationName": "Amlodipine",
      "doseDescription": "1 tablet",
      "scheduleTimes": [{"hour": 8, "minute": 0}],
      "frequency": "daily",
      "ackWindowMinutes": 5,
      "maxRefireCount": 5,
      "escalationWindowMinutes": 60,
      "doubleDoseWindowHours": 4,
      "photoVerificationEnabled": true,
      "confirmationDescription": "with water"
    }
    """#
}
