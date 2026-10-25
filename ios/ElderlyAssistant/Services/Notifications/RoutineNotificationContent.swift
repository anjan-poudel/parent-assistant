import Foundation
import UserNotifications

/// C17 / IF-30. The one pure builder for a routine reminder's notification
/// content, extracted from `UNRoutineNotificationScheduler` so the payload —
/// including `had_instruction` — is testable without a notification centre.
///
/// Design-l2 §2.17 and §3.6. The builder owns the payload shape; the
/// scheduler owns the trigger and the `center.add` call. Nothing here reads a
/// clock, asks for authorization or talks to `UNUserNotificationCenter`.
///
/// **Instruction content never enters the payload** (FR-RIE-021/022). The
/// single instruction-derived value is the `had_instruction` boolean: it tells
/// the tap path whether an instruction screen exists for this occurrence.
/// Text, captions, filenames, URLs and media attachments are deliberately not
/// parameters and must never become ones — the reminder's only attachment is
/// the existing first photo.
enum RoutineNotificationContent {

    // MARK: - Producer keys (the payload's closed vocabulary)

    /// `userInfo` key carrying the occurrence's id.
    static let occurrenceIdKey = "occurrence_id"
    /// `userInfo` key carrying the owning routine entry's id.
    static let entryIdKey = "entry_id"
    /// `userInfo` key carrying the producer type tag.
    static let typeKey = "type"
    /// `userInfo` key carrying the caller's instruction-presence boolean.
    /// A boolean and nothing more — never instruction content.
    static let hadInstructionKey = "had_instruction"

    /// `userInfo["type"]` value for routine reminders. Kept byte-equal to
    /// `RoutineVisualAidFireHandler.routineReminderType`; the tap handler's
    /// constant is the consumer half of the same producer tag.
    static let routineReminderType = "routine_reminder"

    // MARK: - Builder

    /// IF-30. Builds the reminder's content.
    ///
    /// - Parameters:
    ///   - occurrenceId: the occurrence being armed; becomes `occurrence_id`.
    ///   - entryId: the routine entry that owns the occurrence; becomes
    ///     `entry_id` (the id the fired screen and tap path resolve).
    ///   - entryTitle: the reminder text shown as the notification body.
    ///   - reminderTitle: the localized notification title
    ///     (`routine.notificationTitle`), resolved by the caller because the
    ///     builder has no locale and a notification has no view.
    ///   - visualAidURL: the entry's FIRST photo, or nil. At most this one
    ///     photo is attached; attaching is best-effort.
    ///   - hadInstruction: `entry.instruction?.isPresent == true` at arming
    ///     time. Rides the payload as `had_instruction`.
    ///   - attachmentFactory: injection seam for the photo attachment. The
    ///     default is the shipping first-photo copy-and-attach path; tests
    ///     pass a fake (which may return nil) and never touch a centre.
    ///
    /// Pure by construction: no centre, no clock, no file IO of its own. The
    /// injected factory is where the shipping default performs its one
    /// best-effort file copy.
    nonisolated static func make(
        occurrenceId: UUID,
        entryId: UUID,
        entryTitle: String,
        reminderTitle: String,
        visualAidURL: URL?,
        hadInstruction: Bool,
        attachmentFactory: (URL, UUID) -> UNNotificationAttachment? = Self.standardAttachment
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminderTitle
        content.body = entryTitle
        content.sound = .default
        // Exactly the four producer keys. No category and no action:
        // routine reminders are not safety-critical — nothing to
        // acknowledge, no escalation behind them.
        content.userInfo = [
            occurrenceIdKey: occurrenceId.uuidString,
            entryIdKey: entryId.uuidString,
            typeKey: routineReminderType,
            hadInstructionKey: hadInstruction
        ]
        // The reminder's photo in the banner (photo-visual-aids task).
        // Best-effort by construction: a nil or unreadable photo simply
        // arms a text-only reminder, exactly as before the feature.
        if let visualAidURL,
           let attachment = attachmentFactory(visualAidURL, occurrenceId) {
            content.attachments = [attachment]
        }
        return content
    }

    // MARK: - Reader

    /// The one reader for the producer's `had_instruction` value.
    ///
    /// A pre-upgrade payload has no key at all and MUST read `false`
    /// (design P-13): its tap stays a no-op, exactly as today. A non-`Bool`
    /// value is treated the same way — failing closed to "no instruction
    /// screen" rather than presenting an empty one. The fire context
    /// (`RoutineInstructionFireContext`, design §3.6) reads this value.
    nonisolated static func hadInstruction(from userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[hadInstructionKey] as? Bool ?? false
    }

    // MARK: - Shipping attachment (moved from the scheduler unchanged)

    /// Builds the banner image from a THROWAWAY COPY of the stored photo.
    ///
    /// The copy is not an optimisation, it is the whole point:
    /// `UNNotificationAttachment` **moves** the file it is handed into the
    /// system's attachment store. Handing it the app's only copy would
    /// delete the reminder's photo as a side effect of arming its
    /// notification — and arming re-runs on every launch
    /// (`RoutineScheduler.scheduleAll`), so the photo would vanish the
    /// first time. One copy per occurrence, overwritten on each re-arm, so
    /// nothing accumulates.
    ///
    /// Returns nil (leaving the reminder armed, text-only) when the copy
    /// cannot be made or the image is not an attachment the system accepts.
    /// This is the design's default `attachmentFactory`; tests inject their
    /// own and never execute this path.
    static func standardAttachment(from sourceURL: URL,
                                   occurrenceId: UUID) -> UNNotificationAttachment? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisualAidAttachments", isDirectory: true)
        let copyURL = directory.appendingPathComponent(occurrenceId.uuidString + ".jpg")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // A previous arm normally leaves nothing behind (the system
            // took the copy), but a failed attachment may have.
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        } catch {
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: "routine_visual_aid",
                                                url: copyURL)
        } catch {
            try? FileManager.default.removeItem(at: copyURL)
            return nil
        }
    }
}
