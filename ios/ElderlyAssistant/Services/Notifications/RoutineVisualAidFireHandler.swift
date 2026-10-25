import Foundation
import UserNotifications

/// The typed facts a fired routine reminder carries into the fired screen
/// (design L2 §3.6, C14; P-12). A bare `Bool` is not enough: the screen
/// renders the delivery time next to an instruction, and the tap path has
/// to tell "the instruction moved" apart from "it never existed".
///
/// `hadInstruction` is the producer's `userInfo["had_instruction"]` value,
/// read through `RoutineNotificationContent.hadInstruction(from:)` so the
/// absent-key and non-`Bool` rules live in exactly one place. `firedAt` is
/// the notification's delivery date (`UNNotification.date`) — never a
/// clock read of this handler's own.
struct RoutineInstructionFireContext: Equatable {
    /// `userInfo["had_instruction"] ?? false` (pre-upgrade payloads and
    /// non-`Bool` values read `false`, design P-13).
    let hadInstruction: Bool
    /// The notification's delivery date.
    let firedAt: Date
}

/// Shows a reminder's photos at the moment it fires (photo-visual-aids
/// task, 2026-09-16): the fired routine notification reaches this handler
/// through the single `NotificationFacade`, and when the entry actually
/// carries a visual aid the app presents the full-screen elder-facing
/// view — image large above the reminder text — instead of a text-only
/// banner.
///
/// The instructions feature (design L2 §2.14) widens the same seam: an
/// entry whose instruction is present presents its fired screen too, and
/// the context carries the payload's `had_instruction` plus the delivery
/// date. A tap on the banner opens the instruction screen — present,
/// removed, or (for a deleted owner) the honest unavailable notice.
///
/// Registered alongside `NotificationReader` and
/// `CaregiverEventFireHandler` in `AppCoordinator`.
///
/// **Always returns `false`.** Like the caregiver handler, this one claims
/// nothing: the facade stops consulting handlers after the first claim, so
/// returning true would silently mute the read-aloud path (and the
/// caregiver alert behind `CaregiverEventFireHandler`). Presentation is a
/// side effect of delivery, never a substitute for it.
///
/// The delivery contract is unchanged for the overwhelming majority of
/// reminders: an entry with NO visual aids and NO instruction, under a
/// payload that never expected one, is not presented at all, so a
/// household that never adds a photo or an instruction sees exactly
/// today's behaviour.
final class RoutineVisualAidFireHandler: NotificationEventHandling {

    /// `userInfo["type"]` value owned by `UNRoutineNotificationScheduler`.
    /// A producer constant, not user data. Kept byte-equal to
    /// `RoutineNotificationContent.routineReminderType`; that builder is
    /// the producer half of the same tag.
    static let routineReminderType = "routine_reminder"

    private let entryLookup: (UUID) -> RoutineEntry?
    /// Called on the main queue with the fired entry and its typed context
    /// — the coordinator sets its published presentation state here. The
    /// context is not optional: an instruction-aware screen always knows
    /// whether the payload expected an instruction.
    private let onFire: (RoutineEntry, RoutineInstructionFireContext) -> Void
    /// Called on the main queue with the tapped entry's id, the entry as
    /// resolved NOW (nil when the owner was deleted after arming) and the
    /// delivery date — the coordinator maps nil to the unavailable notice.
    private let onInstructionTap: (UUID, RoutineEntry?, Date) -> Void

    /// The typed sinks (design §3.6, IF-31). `onInstructionTap` carries
    /// the entry as OPTIONAL so an owner deleted after arming can still
    /// reach presentation (L1 D14, review-l1 B-2) — a deleted owner is a
    /// notice, never a dead tap.
    init(entryLookup: @escaping (UUID) -> RoutineEntry?,
         onFire: @escaping (RoutineEntry, RoutineInstructionFireContext) -> Void,
         onInstructionTap: @escaping (UUID, RoutineEntry?, Date) -> Void) {
        self.entryLookup = entryLookup
        self.onFire = onFire
        self.onInstructionTap = onInstructionTap
    }

    /// Source compatibility for the shipping coordinator until T-025 wires
    /// the typed sinks: the pre-instruction photo-only sink sees just the
    /// entry (and ignores the context), and a tap stays today's no-op.
    /// Delete this initializer when the coordinator constructs the
    /// designated one.
    convenience init(entryLookup: @escaping (UUID) -> RoutineEntry?,
                     onFire: @escaping (RoutineEntry) -> Void) {
        self.init(entryLookup: entryLookup,
                  onFire: { entry, _ in onFire(entry) },
                  onInstructionTap: { _, _, _ in })
    }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        let content = notification.request.content
        guard let type = content.userInfo["type"] as? String,
              type == Self.routineReminderType else {
            // Not a routine reminder — medication alarms, timers and
            // imported events carry no such type. Decline silently.
            return false
        }
        // The entry id, not the occurrence id: the photos and the
        // instruction hang off the entry, and the same entry fires again
        // tomorrow. An entry deleted between arming and firing presents
        // nothing here — the TAP path is where a deleted owner becomes an
        // honest notice, never this foreground card.
        guard let raw = content.userInfo["entry_id"] as? String,
              let entryId = UUID(uuidString: raw),
              let entry = entryLookup(entryId) else {
            return false
        }
        let context = RoutineInstructionFireContext(
            hadInstruction: RoutineNotificationContent.hadInstruction(from: content.userInfo),
            firedAt: notification.date)
        // FR-RIE-015: a reminder presents the fired screen when its entry
        // has a photo OR an instruction, and also when the payload
        // expected an instruction (the entry read may race a removal; the
        // card can then render the removed fallback instead of the tap
        // being a dead end). Otherwise the reminder delivers exactly as it
        // did before the feature.
        let shouldPresent = !entry.visualAids.isEmpty
            || entry.instruction?.isPresent == true
            || context.hadInstruction
        guard shouldPresent else { return false }
        // Delegate callbacks are not documented as main-thread; the
        // coordinator's published state is.
        DispatchQueue.main.async { [onFire] in
            onFire(entry, context)
        }
        // FR-RIE-016: claiming would mute the read-aloud path and the
        // caregiver alert behind this handler.
        return false
    }

    /// The instruction tap (design §2.14.3, §4.11; FR-RIE-019). Exactly
    /// three outcomes, and every one of them reaches the surface through
    /// the sink:
    ///
    ///  1. entry exists and still carries an instruction ⇒ the card shows it;
    ///  2. entry exists but the instruction was removed ⇒ the `.removed`
    ///     fallback (the coordinator knows an instruction was expected
    ///     because this path only runs when `had_instruction` is true);
    ///  3. entry was deleted ⇒ the `instruction.reminderUnavailable`
    ///     notice, signalled by the nil entry.
    ///
    /// A photo-only or pre-upgrade payload (`had_instruction` absent or
    /// non-`Bool`) stays a no-op, exactly as before the feature. Other
    /// actions are ignored. `didReceive` is `Void` by protocol contract: it
    /// neither claims nor mutes anything, and the system still handles the
    /// tap.
    func didReceive(_ response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        let content = response.notification.request.content
        // P-13: the producer's own boolean is the discriminator. Absent
        // (pre-upgrade) and non-Bool both read false and stay a no-op.
        guard RoutineNotificationContent.hadInstruction(from: content.userInfo)
        else { return }
        // Without a well-formed owning id there is no entry to resolve and
        // no screen that could honestly be shown; the producer always
        // writes one.
        guard let raw = content.userInfo["entry_id"] as? String,
              let entryId = UUID(uuidString: raw) else { return }
        // Resolved once, and may be nil: a deleted owner reaches the
        // `.unavailable` notice through this value and is never dropped.
        let entry = entryLookup(entryId)
        let firedAt = response.notification.date
        // Delegate callbacks are not documented as main-thread; the
        // coordinator's published state is.
        DispatchQueue.main.async { [onInstructionTap] in
            onInstructionTap(entryId, entry, firedAt)
        }
    }
}
