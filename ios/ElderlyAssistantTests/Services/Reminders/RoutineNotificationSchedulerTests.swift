import Foundation
import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// C17 / IF-30 — the routine notification payload and its one instruction
/// bit (design-l2 §2.17, §3.6, §11.3 H and S; must-carry N-6/N-9).
///
/// The suite name is `RoutineNotificationSchedulerTests` — the real name
/// (N-6). There is deliberately no `RoutineNotificationContentTests`.
///
/// Every attachment is produced by an injected `FakeAttachmentFactory` in
/// this suite's own temporary directory. No test constructs
/// `UNRoutineNotificationScheduler` or asks `UNUserNotificationCenter` for
/// anything: the builder is pure and the scheduler's identifier/cancel
/// surface is static and source-pinned.
final class RoutineNotificationSchedulerTests: XCTestCase {

    private let occurrenceId = UUID()
    private let entryId = UUID()
    private let entryTitle = "Time for your walk"
    private let reminderTitle = "Reminder"
    private let en = Locale(identifier: "en")

    private var tempDirectory: URL!
    private var fakeFactory: FakeAttachmentFactory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutineNotificationSchedulerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        fakeFactory = FakeAttachmentFactory(directory: tempDirectory)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        fakeFactory = nil
        try super.tearDownWithError()
    }

    // MARK: - Payload shape (design §11.3 H)

    func testUserInfoHasExactlyFourProducerKeys() throws {
        let photoURL = try makePhotoFile()
        let content = makeContent(visualAidURL: photoURL, hadInstruction: true)
        let info = content.userInfo

        XCTAssertEqual(info.count, 4,
                       "the payload is closed: exactly the four producer keys")
        XCTAssertEqual(Set(info.keys.compactMap { $0 as? String }),
                       ["occurrence_id", "entry_id", "type", "had_instruction"])
        XCTAssertEqual(info["occurrence_id"] as? String, occurrenceId.uuidString)
        XCTAssertEqual(info["entry_id"] as? String, entryId.uuidString)
        XCTAssertEqual(info["type"] as? String, "routine_reminder")
        XCTAssertTrue(info["had_instruction"] is Bool,
                      "had_instruction must be a boolean, never a string or a struct")
        XCTAssertEqual(info["had_instruction"] as? Bool, true)
    }

    func testHadInstructionRoundTripsBool() {
        for expected in [true, false] {
            let content = makeContent(hadInstruction: expected)
            XCTAssertEqual(content.userInfo["had_instruction"] as? Bool, expected,
                           "the raw payload must carry exactly the caller's Bool")
            XCTAssertEqual(RoutineNotificationContent.hadInstruction(
                               from: content.userInfo),
                           expected,
                           "the typed reader must return exactly the caller's Bool")
        }
    }

    func testMissingHadInstructionReadsFalse() {
        // The pre-upgrade producer's payload, byte for byte: three keys and
        // no had_instruction. Its tap must behave as a photo-only tap (the
        // no-op half is exercised by `RoutineVisualAidFireHandlerTests`,
        // design §11.3 B); this unit pins the value the reader produces.
        let legacy: [AnyHashable: Any] = [
            "occurrence_id": occurrenceId.uuidString,
            "entry_id": entryId.uuidString,
            "type": "routine_reminder"
        ]
        XCTAssertNil(legacy["had_instruction"])
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(from: legacy),
                       "a missing key means no instruction screen — never a crash")

        let photoOnly = makeContent(hadInstruction: false)
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(
                           from: photoOnly.userInfo))

        // A non-Bool value fails closed the same way.
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(
                           from: ["had_instruction": "true"]))
    }

    func testNoInstructionTextCaptionFilenameOrURLInPayload() {
        let content = makeContent(hadInstruction: true)
        let info = content.userInfo

        let bannedKeys = ["text", "caption", "filename", "url", "instruction",
                          "instruction_text", "instruction_caption",
                          "instruction_filename", "instruction_url", "media",
                          "attachment"]
        for key in bannedKeys {
            XCTAssertNil(info[key],
                         "instruction content key '\(key)' must never enter the payload")
        }
        XCTAssertTrue(content.attachments.isEmpty,
                      "no instruction media may be attached")
        XCTAssertEqual(fakeFactory.callCount, 0,
                       "a nil visual aid must not call the attachment factory")

        // The only strings on the wire are the two ids and the producer
        // type; an instruction's text/caption/filename cannot ride along.
        XCTAssertEqual(Set(info.values.compactMap { $0 as? String }),
                       [occurrenceId.uuidString, entryId.uuidString, "routine_reminder"])
        XCTAssertTrue(info.values.allSatisfy { !($0 is URL) })
        XCTAssertTrue(info.values.allSatisfy { !($0 is Data) })
    }

    func testNoCategoryOrActionIsSet() {
        let content = makeContent(hadInstruction: true)

        XCTAssertEqual(content.categoryIdentifier, "",
                       "routine reminders have no category — nothing to acknowledge")
        XCTAssertEqual(content.interruptionLevel, .active,
                       "the builder must not change the shipping interruption level")
        XCTAssertFalse(builderSource.contains("categoryIdentifier"))
        XCTAssertFalse(builderSource.contains("UNNotificationCategory"))
        XCTAssertFalse(builderSource.contains("UNNotificationAction"))
        XCTAssertFalse(builderSource.contains("interruptionLevel"))
    }

    func testTitleBodySoundAndIdentifierMatchShippingShape() {
        let localizedTitle = L10n.str("routine.notificationTitle", locale: en)
        let content = makeContent(reminderTitle: localizedTitle, hadInstruction: false)

        // Fixture: the pre-feature content, built by hand from the shipping
        // shape (`UNRoutineNotificationScheduler` before C17).
        let shipping = UNMutableNotificationContent()
        shipping.title = localizedTitle
        shipping.body = entryTitle
        shipping.sound = .default
        shipping.userInfo = [
            "occurrence_id": occurrenceId.uuidString,
            "entry_id": entryId.uuidString,
            "type": "routine_reminder"
        ]

        XCTAssertFalse(localizedTitle.isEmpty,
                       "routine.notificationTitle must resolve, not fall back to empty")
        XCTAssertEqual(content.title, shipping.title)
        XCTAssertEqual(content.body, shipping.body)
        XCTAssertEqual(content.sound, shipping.sound)
        XCTAssertEqual(content.subtitle, shipping.subtitle)
        XCTAssertEqual(content.categoryIdentifier, shipping.categoryIdentifier)
        XCTAssertEqual(UNRoutineNotificationScheduler.notificationIdentifier(for: occurrenceId),
                       "routine_\(occurrenceId.uuidString)",
                       "the producer identifier stays routine_<uuid>")
        // Every shipping key survives; had_instruction is the only addition
        // (design R-13: mechanical equivalence plus one boolean).
        XCTAssertEqual(Set(content.userInfo.keys.compactMap { $0 as? String }),
                       Set(shipping.userInfo.keys.compactMap { $0 as? String })
                           .union(Set(["had_instruction"])))
    }

    // MARK: - The one attachment (design §2.17, N-9)

    func testFirstPhotoAttachmentIsPreserved() throws {
        let photoURL = try makePhotoFile()
        let content = makeContent(visualAidURL: photoURL, hadInstruction: true)

        XCTAssertEqual(fakeFactory.callCount, 1,
                       "only the first photo is offered to the factory")
        XCTAssertEqual(fakeFactory.handoffs.first?.url, photoURL)
        XCTAssertEqual(fakeFactory.handoffs.first?.occurrenceId, occurrenceId,
                       "the throwaway copy is named per occurrence, as shipping did")
        XCTAssertEqual(content.attachments.count, 1,
                       "at most one photo is attached — the platform and shipping shape")
        XCTAssertEqual(content.attachments.first?.identifier, "routine_visual_aid",
                       "the shipping first-photo attachment identifier is unchanged")
    }

    func testNilAttachmentFactoryLeavesTextOnly() throws {
        let photoURL = try makePhotoFile()
        fakeFactory.returnsNil = true
        let content = makeContent(visualAidURL: photoURL, hadInstruction: true)

        XCTAssertEqual(fakeFactory.callCount, 1,
                       "the injected factory is the only attachment seam")
        XCTAssertTrue(content.attachments.isEmpty,
                      "a nil attachment leaves a text-only reminder")
        XCTAssertEqual(content.title, reminderTitle)
        XCTAssertEqual(content.body, entryTitle)
        XCTAssertEqual(content.userInfo.count, 4,
                       "the payload is identical with or without an attachment")

        // N-9: arming still happens. The scheduler adds the request
        // unconditionally — no branch on attachments and no throwing path.
        XCTAssertTrue(schedulerSource.contains("center.add(request)"))
        XCTAssertFalse(schedulerSource.contains("attachments"),
                       "the scheduler must not gate arming on an attachment")
        XCTAssertFalse(schedulerSource.contains("throw"))
    }

    // MARK: - Cancels and purity (design §11.3 S)

    func testScopedCancelsAreUnchanged() {
        XCTAssertEqual(UNRoutineNotificationScheduler.notificationIdentifier(for: occurrenceId),
                       "routine_\(occurrenceId.uuidString)",
                       "the cancel identifier stays namespaced exactly as before")
        XCTAssertTrue(schedulerSource.contains("removePendingNotificationRequests("),
                      "cancels stay scoped through the identifier-list overload")
        XCTAssertTrue(schedulerSource.contains(
            "withIdentifiers: occurrenceIds.map(Self.notificationIdentifier(for:))"),
                      "cancels are scoped to explicit identifiers, resolved by the one helper")
        XCTAssertTrue(schedulerSource.contains(
            "cancelRoutineReminders(occurrenceIds: [occurrenceId])"),
                      "the single cancel delegates to the scoped batch")
        XCTAssertFalse(schedulerSource.contains("removeAllPendingNotificationRequests"),
                       "removeAll would wipe the medication system's alarms (safety)")
    }

    func testBuilderUsesNoNotificationCentre() throws {
        XCTAssertFalse(builderSource.contains("UNUserNotificationCenter"),
                       "the builder must be pure — no notification centre")
        XCTAssertFalse(builderSource.contains("NotificationCenter"),
                       "no notification centre of any kind")
        XCTAssertFalse(builderSource.contains("center.add"))

        // Behavioural half: the injected factory is the only attachment
        // path, so building content performs no centre request.
        let photoURL = try makePhotoFile()
        let content = makeContent(visualAidURL: photoURL, hadInstruction: true)
        XCTAssertEqual(fakeFactory.callCount, 1)
        XCTAssertEqual(content.attachments.count, 1)
    }

    // MARK: - Helpers

    private func makeContent(
        reminderTitle: String? = nil,
        visualAidURL: URL? = nil,
        hadInstruction: Bool = false,
        using factory: ((URL, UUID) -> UNNotificationAttachment?)? = nil
    ) -> UNMutableNotificationContent {
        RoutineNotificationContent.make(
            occurrenceId: occurrenceId,
            entryId: entryId,
            entryTitle: entryTitle,
            reminderTitle: reminderTitle ?? self.reminderTitle,
            visualAidURL: visualAidURL,
            hadInstruction: hadInstruction,
            attachmentFactory: factory ?? fakeFactory.make
        )
    }

    /// A real file for the builder's `visualAidURL` slot. The fake factory
    /// ignores its bytes and builds its own throwaway copy, exactly as the
    /// shipping default does with a copy.
    private func makePhotoFile() throws -> URL {
        let url = tempDirectory.appendingPathComponent("routine-aid.png")
        try FakeAttachmentFactory.onePixelPNG.write(to: url)
        return url
    }

    private func source(_ iosRelativePath: String) -> String {
        FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory(file: #filePath)
                .appendingPathComponent(iosRelativePath))
    }

    private var builderSource: String {
        source("ElderlyAssistant/Services/Notifications/RoutineNotificationContent.swift")
    }

    private var schedulerSource: String {
        source("ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift")
    }

    /// Design §11.4. Returns a real `UNNotificationAttachment` built from a
    /// throwaway one-pixel PNG in the suite's own temporary directory, or
    /// nil when `returnsNil` is set. Records every URL it is handed so a
    /// test can prove the *first photo* is the only thing offered.
    private final class FakeAttachmentFactory {

        struct Handoff {
            let url: URL
            let occurrenceId: UUID
        }

        private let directory: URL
        private(set) var handoffs: [Handoff] = []
        private(set) var callCount = 0
        var returnsNil = false

        init(directory: URL) {
            self.directory = directory
        }

        func make(_ url: URL, _ occurrenceId: UUID) -> UNNotificationAttachment? {
            callCount += 1
            handoffs.append(Handoff(url: url, occurrenceId: occurrenceId))
            guard !returnsNil else { return nil }
            let file = directory.appendingPathComponent(
                "attachment-\(UUID().uuidString).png")
            do {
                try Self.onePixelPNG.write(to: file)
                return try UNNotificationAttachment(identifier: "routine_visual_aid",
                                                    url: file)
            } catch {
                XCTFail("could not build the fake attachment: \(error)")
                return nil
            }
        }

        /// A valid 1x1 PNG: the attachment initializer validates the file's
        /// type, so an empty file is not enough.
        static let onePixelPNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
            + "+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
