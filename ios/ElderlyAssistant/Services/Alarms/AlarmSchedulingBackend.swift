import Foundation
import UserNotifications

// MARK: - Backend-neutral types

/// [ALARMKIT-ALARMS] (2026-09-10) Which backend arms alarms on this
/// device.
enum AlarmBackendKind: String, Equatable {
    /// iOS 26+ AlarmKit — REAL system alarms: they ring through silent
    /// mode and Focus, present a Lock Screen alert the user can stop or
    /// snooze, and fire with the app terminated (verified against
    /// developer.apple.com/documentation/AlarmKit and WWDC25 session 230
    /// "Wake up to the AlarmKit API").
    case alarmKit
    /// Pre-iOS-26 fallback — the app's own daily-repeating local
    /// notification (the historical `AlarmScheduler` behavior).
    case localNotifications
}

/// Alarm-permission status in backend-neutral terms — what the Settings
/// leaf and the voice path surface. Mapped per backend:
///  - AlarmKit backend: `AlarmManager.AuthorizationState` (exact,
///    synchronous map — see `AlarmKitAlarmBackend.map`).
///  - UN backend: the last point-of-use resolution (UN offers no
///    synchronous settings read — see `UNAlarmBackend.authorizationStatus`).
enum AlarmAuthorizationStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - Seam

/// [ALARMKIT-ALARMS] (2026-09-10) The ALARM-side scheduling seam — the
/// alarm operations of the alarms/timers feature. Two backends:
///
///  - `AlarmKitAlarmBackend` (iOS 26+): real system alarms via AlarmKit's
///    `AlarmManager`. AlarmKit is NOT unit-testable below the iOS 26
///    runtime, and even on it system alarms are real and nondeterministic
///    — so every behavior the service depends on is expressed through
///    THIS protocol and tested with fakes (see
///    `AlarmSchedulingBackendTests` / `AlarmKitAlarmBackendTests`).
///  - `UNAlarmBackend`: the pre-26 path — the app's own daily-repeating
///    UN notification, byte-for-byte the historical `AlarmScheduler`
///    alarm behavior, so nothing changes for pre-26 devices.
///
/// Timer operations are deliberately NOT part of this seam (they are
/// in-app countdowns + one-shot notifications, owned elsewhere).
protocol AlarmSchedulingBackend: AnyObject {
    var kind: AlarmBackendKind { get }
    /// Current permission state — `.denied` is what the Settings leaf
    /// surfaces honestly.
    var authorizationStatus: AlarmAuthorizationStatus { get }
    /// Locale for content the backend builds (notification titles,
    /// system-alarm titles/buttons). Forwarded from `AlarmScheduler.locale`
    /// (kept in sync with the app language by `AppCoordinator`).
    var locale: Locale { get set }

    /// Point-of-use permission ask. Returns true when alarms CAN ring on
    /// this backend. A previous denial must never re-prompt (iOS prompts
    /// only while notDetermined — the honest cheap-resolution rule the
    /// historical UN path already followed).
    func requestAuthorizationIfNeeded() async -> Bool

    func scheduleAlarm(_ alarm: Alarm)
    func cancelAlarm(id: UUID)
    /// Arms the app's own one-shot re-wake notification (custom-minute
    /// voice snoozes; the ONLY snooze mechanism pre-26).
    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval)
    func cancelSnooze(id: UUID)
    /// Voice snooze → the SYSTEM alarm's own snooze where the system
    /// supports it. Returns false when it cannot honor the request (the
    /// system snooze duration is fixed, or no system alarm exists) — the
    /// caller then arms the app's one-shot notification instead.
    func snoozeViaSystem(id: UUID, minutes: Int) -> Bool
}

// MARK: - Shared UN request building

/// [ALARMKIT-ALARMS] (2026-09-10) The UN request shapes the alarm side
/// shares: the daily-repeating alarm notification and the one-shot snooze
/// notification. Used by `UNAlarmBackend` (pre-26) AND by the AlarmKit
/// backend's fallbacks (system refusal → daily notification;
/// arbitrary-minute snoozes). Content and identifiers are identical to
/// the historical `AlarmScheduler` — pre-26 devices see no change.
enum UNAlarmRequestFactory {

    /// The daily-repeating alarm notification — one pending request per
    /// enabled alarm, armed under `AlarmScheduler.alarmRequestID`.
    static func dailyRepeatRequest(for alarm: Alarm, locale: Locale) -> UNNotificationRequest {
        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        return UNNotificationRequest(
            identifier: AlarmScheduler.alarmRequestID(alarm.id),
            content: baseContent(for: alarm, locale: locale),
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
    }

    /// The ONE-SHOT snooze re-wake notification (the daily repeat request
    /// stays untouched; a repeat snooze replaces the previous one-shot in
    /// place under the same identifier).
    static func snoozeRequest(for alarm: Alarm,
                              timeInterval: TimeInterval,
                              locale: Locale) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: AlarmScheduler.alarmSnoozeRequestID(alarm.id),
            content: baseContent(for: alarm, locale: locale),
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(timeInterval, 1), repeats: false
            )
        )
    }

    private static func baseContent(for alarm: Alarm, locale: Locale) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("alarms.notification.title", locale: locale)
        content.body = alarm.label ?? timeText(alarm.time, locale: locale)
        content.sound = .default
        content.userInfo = ["kind": "alarm", "id": alarm.id.uuidString]
        return content
    }

    /// The alarm's time-of-day as a short locale string ("6:00 AM" /
    /// "बिहान ६:०० बजे") — the notification body when the alarm has no
    /// label.
    static func timeText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - UN backend (pre-26 fallback)

/// [ALARMKIT-ALARMS] (2026-09-10) The pre-iOS-26 alarm backend — the
/// historical `AlarmScheduler` UN behavior, extracted verbatim so the
/// seam's selection logic has a real fallback.
///
/// PLATFORM HONESTY — iOS does NOT let third-party apps create alarms in
/// the built-in Clock app. Every alarm app (this one included) schedules
/// its OWN repeating local notification instead, so an "alarm" here is a
/// notification that repeats DAILY at the chosen time-of-day while the
/// alarm is enabled. The Settings caption (`alarms.honestyNote`) says
/// exactly that on these devices. On iOS 26+ the AlarmKit backend
/// replaces this with a real system alarm.
final class UNAlarmBackend: AlarmSchedulingBackend {

    let kind: AlarmBackendKind = .localNotifications

    /// UN has no synchronous settings read, so this is the LAST resolved
    /// status, updated at each point-of-use ask (`.notDetermined` until
    /// the first one). The Settings leaf uses it conservatively: it only
    /// ever claims `.denied` after an actual denial.
    private(set) var authorizationStatus: AlarmAuthorizationStatus = .notDetermined

    var locale: Locale

    private let notifications: LocalNotificationScheduling

    init(notifications: LocalNotificationScheduling,
         locale: Locale = Locale(identifier: "en")) {
        self.notifications = notifications
        self.locale = locale
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let granted = await notifications.requestAuthorization()
        authorizationStatus = granted ? .authorized : .denied
        if !granted {
            print("[UNAlarmBackend] Notification authorization denied — alarms will not ring.")
        }
        return granted
    }

    func scheduleAlarm(_ alarm: Alarm) {
        notifications.add(UNAlarmRequestFactory.dailyRepeatRequest(for: alarm, locale: locale)) { error in
            if let error {
                print("[UNAlarmBackend] Failed to arm alarm \(alarm.id): \(error)")
            }
        }
    }

    func cancelAlarm(id: UUID) {
        notifications.removePendingNotifications(
            withIdentifiers: [AlarmScheduler.alarmRequestID(id)]
        )
    }

    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval) {
        notifications.add(
            UNAlarmRequestFactory.snoozeRequest(for: alarm, timeInterval: timeInterval, locale: locale)
        ) { error in
            if let error {
                print("[UNAlarmBackend] Failed to arm snooze for alarm \(alarm.id): \(error)")
            }
        }
    }

    func cancelSnooze(id: UUID) {
        notifications.removePendingNotifications(
            withIdentifiers: [AlarmScheduler.alarmSnoozeRequestID(id)]
        )
    }

    /// Pre-26 there is no system alarm to snooze — a voice snooze is
    /// always the app's own one-shot notification.
    func snoozeViaSystem(id: UUID, minutes: Int) -> Bool { false }
}
