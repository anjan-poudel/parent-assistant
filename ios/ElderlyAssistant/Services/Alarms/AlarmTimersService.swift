import Foundation
import Combine
import UserNotifications

// MARK: - Models

/// [ALARMS-TIMERS] (2026-09-07) One user alarm.
///
/// `time` is the concrete date-time the alarm was created for — the FIRST
/// ring instant. Only its hour/minute-of-day are meaningful afterwards:
/// the OS alarm is a DAILY-repeating calendar trigger (see `AlarmScheduler`),
/// the UI renders time-of-day only, and re-arms (`scheduleAll`) replace the
/// pending request in place by `id`. Keeping the full date makes the
/// "next occurrence" resolution testable and keeps the stored record
/// self-describing.
struct Alarm: Codable, Identifiable, Equatable {
    var id: UUID
    var time: Date
    var label: String?
    var isEnabled: Bool
    /// Voice-snooze state (2026-09-08): the absolute re-wake instant of
    /// the pending one-shot snooze notification, nil when none is
    /// outstanding. Persisted so a snooze survives an app relaunch in
    /// the record (the OS holds the armed one-shot itself) and so
    /// disabling the alarm can clear it. `scheduleAll` deliberately does
    /// NOT re-arm snoozes — they are ephemeral one-shots the OS keeps.
    var snoozedUntil: Date?

    init(id: UUID = UUID(), time: Date, label: String? = nil, isEnabled: Bool = true,
         snoozedUntil: Date? = nil) {
        self.id = id
        self.time = time
        self.label = label
        self.isEnabled = isEnabled
        self.snoozedUntil = snoozedUntil
    }
}

/// [ALARMS-TIMERS] (2026-09-07) One in-app countdown timer.
///
/// `endsAt` is the absolute completion instant. `isActive` distinguishes
/// live countdowns from finished ones that still await the prune sweep
/// (`pruneFinishedTimers` drops `!isActive` rows and rows whose deadline
/// has passed — an app that was closed when the timer fired finds the row
/// already cleaned on its next launch). The UI shows only active timers.
struct TimerItem: Codable, Identifiable, Equatable {
    var id: UUID
    var endsAt: Date
    var label: String?
    var isActive: Bool

    init(id: UUID = UUID(), endsAt: Date, label: String? = nil, isActive: Bool = true) {
        self.id = id
        self.endsAt = endsAt
        self.label = label
        self.isActive = isActive
    }
}

/// [ALARMS-TIMERS] (2026-09-07) Outcome of an alarm/timer creation request
/// (voice or UI). `CommandRouter` maps this to the honest spoken line —
/// success only when the item is actually persisted + armed, the denial
/// fallback when notification permission is off.
enum AlarmTimerSetOutcome: Equatable {
    /// Permission granted and the item is stored + armed.
    case scheduled
    /// Notification permission is denied — nothing was stored or armed.
    case permissionDenied
    /// The store's cap is full (see `AlarmTimersStore`) — nothing stored.
    case atCapacity
    /// Persistence (or a defensive input guard) failed — nothing armed.
    case failed
}

/// [ALARMS-TIMERS] (2026-09-08) Outcome of a voice alarm-OFF request
/// ("turn off the alarm", "अलार्म बन्द गर"). `CommandRouter` maps it
/// to the honest spoken line — the confirmation names the alarm's time,
/// so a mis-target can never pass silently.
enum AlarmOffOutcome: Equatable {
    /// The alarm was disabled (persisted `enabled=false`) and its
    /// pending daily + snooze notifications cancelled. `time` is its
    /// time-of-day for the spoken confirmation.
    case disabled(time: Date)
    /// No enabled alarm existed to turn off — the list is empty, the
    /// resolved target is unknown, or it was already off. The router
    /// speaks the "no alarms" line.
    case noAlarm
    /// Persistence failed — nothing was cancelled.
    case failed
}

/// [ALARMS-TIMERS] (2026-09-08) Outcome of a voice SNOOZE request
/// ("snooze", "स्नुज गर"). Same honest-outcome contract as
/// `AlarmOffOutcome`.
enum AlarmSnoozeOutcome: Equatable {
    /// A one-shot re-wake notification is armed `until` (now + minutes,
    /// bounded 1…`AlarmTimersService.maxSnoozeMinutes`) and the
    /// snooze-until marker persisted; the daily repeat is untouched.
    case snoozed(until: Date)
    /// No enabled alarm existed to snooze.
    case noAlarm
    /// Persistence failed — nothing armed.
    case failed
}

// MARK: - Store

/// [ALARMS-TIMERS] (2026-09-07) Encrypted persistence for the alarms +
/// timers lists — the `FamilyContactStore`/`RoutineStore` shape: Keychain
/// (Data Protection Complete, constitution §Security), JSON round-trip,
/// whole-list save on every mutation.
///
/// Caps: alarms are daily-repeat notifications, one pending request each,
/// and iOS allows at most 64 pending notification requests per app — 20
/// alarms leaves comfortable headroom for timers, medication reminders and
/// routines. Timers cap at 10 live countdowns (each also holds one pending
/// request until it fires).
final class AlarmTimersStore {
    private static let alarmsKey = "alarms.list"
    private static let timersKey = "timers.list"
    static let maxAlarms = 20
    static let maxTimers = 10

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: Alarms

    func loadAlarms() -> [Alarm] {
        guard case .success(let alarms) = storage.read(
            key: Self.alarmsKey, type: [Alarm].self
        ) else { return [] }
        return alarms
    }

    @discardableResult
    func saveAlarms(_ alarms: [Alarm]) -> Bool {
        switch storage.write(key: Self.alarmsKey, value: alarms) {
        case .success: return true
        case .failure: return false
        }
    }

    // MARK: Timers

    func loadTimers() -> [TimerItem] {
        guard case .success(let timers) = storage.read(
            key: Self.timersKey, type: [TimerItem].self
        ) else { return [] }
        return timers
    }

    @discardableResult
    func saveTimers(_ timers: [TimerItem]) -> Bool {
        switch storage.write(key: Self.timersKey, value: timers) {
        case .success: return true
        case .failure: return false
        }
    }
}

// MARK: - Notification-center seam

/// [ALARMS-TIMERS] (2026-09-07) Test seam over the parts of
/// `UNUserNotificationCenter` the alarms/timers feature uses. The
/// production adapter is `UNNotificationCenterScheduler`; tests inject a
/// recording fake so arming decisions — daily-repeating alarm triggers,
/// one-shot timer triggers, cancellations, authorization outcomes — are
/// asserted without the real OS center.
protocol LocalNotificationScheduling: AnyObject {
    /// Requests notification authorization (.alert/.sound/.badge). Returns
    /// true only when granted. A previous denial returns false WITHOUT
    /// re-prompting (iOS prompts only while `.notDetermined`), so
    /// point-of-use calls stay honest and cheap.
    func requestAuthorization() async -> Bool
    /// Adds (or replaces — same identifier) a pending notification request.
    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)?)
    /// Removes pending requests with the given identifiers.
    func removePendingNotifications(withIdentifiers identifiers: [String])
}

/// Production `LocalNotificationScheduling` — a thin adapter over
/// `UNUserNotificationCenter.current()`.
final class UNNotificationCenterScheduler: LocalNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[AlarmScheduler] Authorization request failed: \(error)")
            return false
        }
    }

    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)? = nil) {
        center.add(request, withCompletionHandler: completion)
    }

    func removePendingNotifications(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - AlarmScheduler (arms iOS local notifications)

/// [ALARMS-TIMERS] (2026-09-07) Arms alarms and timer completions as iOS
/// local notifications through the `LocalNotificationScheduling` seam.
///
/// PLATFORM HONESTY — iOS does NOT let third-party apps create alarms in
/// the built-in Clock app. Every alarm app (this one included) schedules
/// its OWN repeating local notification instead, so an "alarm" here is a
/// notification that repeats DAILY at the chosen time-of-day while the
/// alarm is enabled (`UNCalendarNotificationTrigger(dateComponents:
/// [.hour, .minute], repeats: true)`). The Settings leaf caption
/// (`alarms.honestyNote`) and this doc say exactly that. Timers are fully
/// in-app countdowns whose completion fires a one-shot notification at
/// `endsAt`; while the app is foregrounded the presentation delegate
/// (`AlarmTimerNotificationDelegate`) also speaks "Timer finished."
final class AlarmScheduler {
    private let notifications: LocalNotificationScheduling

    /// Locale for notification titles/bodies; kept in sync by
    /// `AppCoordinator` when the app language changes (spec §3.2). Content
    /// is built per-call, so armed notifications keep the language they
    /// were armed in until the next re-arm.
    var locale: Locale

    init(notifications: LocalNotificationScheduling,
         locale: Locale = Locale(identifier: "en")) {
        self.notifications = notifications
        self.locale = locale
    }

    // MARK: Authorization (point of use)

    /// Requests notification permission at POINT OF USE — the first alarm
    /// or timer creation asks; every later call resolves the already-
    /// determined status without re-prompting (meds request at launch in
    /// `UNNotificationScheduler.init`; alarms/timers deliberately defer so
    /// a user who never uses the feature is never asked).
    func requestAuthorizationIfNeeded() async -> Bool {
        let granted = await notifications.requestAuthorization()
        if !granted {
            print("[AlarmScheduler] Notification authorization denied — alarms/timers will not ring.")
        }
        return granted
    }

    // MARK: Alarms — daily repeat

    /// Arms (or replaces, same id) the daily-repeating notification for
    /// `alarm`. Only the hour/minute of `alarm.time` matter.
    func scheduleAlarm(_ alarm: Alarm) {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("alarms.notification.title", locale: locale)
        content.body = alarm.label ?? Self.timeText(alarm.time, locale: locale)
        content.sound = .default
        content.userInfo = ["kind": "alarm", "id": alarm.id.uuidString]

        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let request = UNNotificationRequest(
            identifier: Self.alarmRequestID(alarm.id),
            content: content,
            trigger: trigger
        )
        notifications.add(request) { error in
            if let error {
                print("[AlarmScheduler] Failed to arm alarm \(alarm.id): \(error)")
            }
        }
    }

    func cancelAlarm(id: UUID) {
        notifications.removePendingNotifications(withIdentifiers: [Self.alarmRequestID(id)])
    }

    // MARK: Snooze — one-shot re-wake (2026-09-08)

    /// Arms a ONE-SHOT snooze notification for `alarm` that rings
    /// `timeInterval` seconds from arming. The daily repeat request is
    /// untouched (it re-queues itself with the OS), and a repeat snooze
    /// replaces the previous one in place (same identifier). The
    /// interval (not an absolute date) is the seam so tests pin the
    /// exact trigger with the service's injected clock.
    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("alarms.notification.title", locale: locale)
        content.body = alarm.label ?? Self.timeText(alarm.time, locale: locale)
        content.sound = .default
        content.userInfo = ["kind": "alarm", "id": alarm.id.uuidString]

        let request = UNNotificationRequest(
            identifier: Self.alarmSnoozeRequestID(alarm.id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(timeInterval, 1), repeats: false
            )
        )
        notifications.add(request) { error in
            if let error {
                print("[AlarmScheduler] Failed to arm snooze for alarm \(alarm.id): \(error)")
            }
        }
    }

    func cancelSnooze(id: UUID) {
        notifications.removePendingNotifications(withIdentifiers: [Self.alarmSnoozeRequestID(id)])
    }

    // MARK: Timers — one-shot completion

    /// Arms the one-shot completion notification for `timer` at its
    /// `endsAt`. The trigger date is absolute, so an in-flight timer
    /// survives re-arms (`scheduleAll`) by simple replacement.
    func scheduleTimerCompletion(for timer: TimerItem) {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("timers.finished", locale: locale)
        content.body = timer.label ?? ""
        content.sound = .default
        content.userInfo = ["kind": "timer", "id": timer.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: timer.endsAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: Self.timerRequestID(timer.id),
            content: content,
            trigger: trigger
        )
        notifications.add(request) { error in
            if let error {
                print("[AlarmScheduler] Failed to arm timer \(timer.id): \(error)")
            }
        }
    }

    func cancelTimer(id: UUID) {
        notifications.removePendingNotifications(withIdentifiers: [Self.timerRequestID(id)])
    }

    // MARK: Identifiers

    static func alarmRequestID(_ id: UUID) -> String { "alarm.\(id.uuidString)" }
    static func alarmSnoozeRequestID(_ id: UUID) -> String { "alarm.snooze.\(id.uuidString)" }
    static func timerRequestID(_ id: UUID) -> String { "timer.\(id.uuidString)" }

    /// The alarm's time-of-day as a short locale string ("6:00 AM" /
    /// "बिहान ६:०० बजे") — the notification body when the alarm has no
    /// label.
    private static func timeText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Foreground presentation delegate

/// [ALARMS-TIMERS] (2026-09-07) Foreground delivery for alarm/timer
/// notifications. iOS silences notification PRESENTATION while the app is
/// active unless a `UNUserNotificationCenterDelegate` returns presentation
/// options, and no other delegate exists in the app today (medication and
/// routine reminders deliver via the OS alone). This delegate:
///
///  - presents OUR alarm/timer notifications as banners + sound while the
///    app is foregrounded, and
///  - reports a TIMER completion up to `AppCoordinator` (via the
///    `onForegroundTimerFinished` closure), which expires the timer row
///    and SPEAKS "Timer finished." — a chime the user cannot see is
///    useless to someone already looking at the phone.
///
/// Every OTHER notification (medication reminders etc., which carry no
/// "kind" userInfo) returns `[]` — exactly the no-delegate behavior those
/// features have today; nothing about them changes.
final class AlarmTimerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Called when a timer-completion notification arrives while the app
    /// is foregrounded. May be invoked on any queue; the coordinator hops
    /// to main before touching published state.
    var onForegroundTimerFinished: ((UUID) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        guard let kind = info["kind"] as? String else { return [] }
        if kind == "timer",
           let idString = info["id"] as? String,
           let id = UUID(uuidString: idString) {
            onForegroundTimerFinished?(id)
        }
        return [.banner, .sound]
    }
}

// MARK: - AlarmTimersService

/// [ALARMS-TIMERS] (2026-09-07) Owns the on-device alarms + timers feature
/// end to end — the single service behind the voice stage (via
/// `AppCoordinator`), the Settings leaf, launch re-arm and the background
/// task.
///
/// Rules inherited from the medication/routine paths:
///  - Persistence BEFORE arming: a crash between the two must leave
///    durable state, never an armed notification for a forgotten item.
///  - FR-025 re-queue: `scheduleAll()` re-arms everything on every launch
///    and BGTask wake; armed requests replace in place by id, so this is
///    idempotent.
///  - Store caps keep the app well under iOS's 64 pending-notification
///    limit.
///
/// Threading: the `@Published` lists are main-confined (SwiftUI reads
/// them). Async entry points (`addAlarm`/`startTimer`) hop to main
/// internally before mutating; sync UI mutations are main-only by
/// contract; `scheduleAll()` and `expireTimer` dispatch to main when
/// called off it (background task / notification callbacks).
final class AlarmTimersService: ObservableObject {
    @Published private(set) var alarms: [Alarm]
    @Published private(set) var timers: [TimerItem]

    /// Active locale — injected from `AppCoordinator` (`syncServiceLocales`).
    var locale: Locale

    /// Hard ceiling on one timer's duration (defensive; the parser
    /// enforces the same bound). Beyond a day a "timer" is really a
    /// scheduled event.
    static let maxTimerDurationSeconds = 86_400

    /// Hard ceiling on one snooze delay, in minutes — mirrored by
    /// `AlarmTimerCommandParser.maxSnoozeMinutes` (defensive; the
    /// parser enforces the same bound). Beyond an hour a "snooze" is
    /// really a timer or a schedule change.
    static let maxSnoozeMinutes = 60

    private let store: AlarmTimersStore
    private let scheduler: AlarmScheduler
    private let observabilityBus: ObservabilityBus
    private let now: () -> Date

    init(store: AlarmTimersStore,
         scheduler: AlarmScheduler,
         observabilityBus: ObservabilityBus,
         locale: Locale = Locale(identifier: "en"),
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.scheduler = scheduler
        self.observabilityBus = observabilityBus
        self.locale = locale
        self.now = now
        self.alarms = store.loadAlarms()
        self.timers = store.loadTimers()
    }

    // MARK: Visible state

    /// Live countdowns only — finished rows leave the visible list the
    /// moment they finish and are swept from storage by the next prune.
    var activeTimers: [TimerItem] {
        timers.filter { $0.isActive && $0.endsAt > now() }
    }

    func alarm(with id: UUID) -> Alarm? {
        alarms.first { $0.id == id }
    }

    func timer(with id: UUID) -> TimerItem? {
        timers.first { $0.id == id }
    }

    // MARK: Alarm creation (voice + UI)

    /// Point-of-use creation: asks for notification permission first (a
    /// denial means the alarm could never ring — nothing is stored or
    /// armed, and the caller speaks the honest `alarms.permissionDenied`
    /// line), then persists BEFORE arming. `proposedTime` is canonicalised
    /// to its next future occurrence (a time already passed today rolls to
    /// tomorrow, same minute).
    func addAlarm(at proposedTime: Date, label: String?) async -> AlarmTimerSetOutcome {
        let granted = await scheduler.requestAuthorizationIfNeeded()
        guard granted else {
            emit("alarm_permission_denied", outcome: "denied")
            return .permissionDenied
        }
        return await onMain {
            self.addAlarmAuthorized(at: proposedTime, label: label)
        }
    }

    private func addAlarmAuthorized(at proposedTime: Date, label: String?) -> AlarmTimerSetOutcome {
        guard alarms.count < AlarmTimersStore.maxAlarms else {
            emit("alarm_capacity_reached", outcome: "at_capacity")
            return .atCapacity
        }
        let alarm = Alarm(time: nextOccurrence(of: proposedTime),
                          label: Self.trimmed(label))
        // Persistence BEFORE arming (house rule — see class doc).
        guard store.saveAlarms(alarms + [alarm]) else {
            emit("alarm_persistence_failed", outcome: "failed")
            return .failed
        }
        alarms.append(alarm)
        scheduler.scheduleAlarm(alarm)
        emit("alarm_created", outcome: "success", id: alarm.id)
        return .scheduled
    }

    /// Settings-leaf toggle. Disabling cancels the pending daily
    /// notification; enabling re-arms it (permission was granted when the
    /// alarm was created; if the family later revoked notifications at the
    /// OS level the OS simply will not present — the toggle stays honest
    /// in the list). Main-confined (UI).
    func setAlarmEnabled(id: UUID, enabled: Bool) {
        guard let alarm = alarm(with: id), alarm.isEnabled != enabled else { return }
        var updated = alarm
        updated.isEnabled = enabled
        guard store.saveAlarms(alarms.map { $0.id == id ? updated : $0 }) else {
            emit("alarm_persistence_failed", outcome: "failed")
            return
        }
        if enabled {
            scheduler.scheduleAlarm(updated)
        } else {
            scheduler.cancelAlarm(id: id)
        }
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            alarms[index] = updated
        }
        emit(enabled ? "alarm_enabled" : "alarm_disabled", outcome: "success", id: id)
    }

    /// Deletes an alarm: persists the removal first, then cancels the
    /// pending request (a crash between the two leaves at worst one
    /// stale ring that the next `scheduleAll()` rebuild clears). Main-
    /// confined (UI).
    func removeAlarm(id: UUID) {
        guard alarm(with: id) != nil else { return }
        guard store.saveAlarms(alarms.filter { $0.id != id }) else {
            emit("alarm_persistence_failed", outcome: "failed")
            return
        }
        alarms.removeAll { $0.id == id }
        scheduler.cancelAlarm(id: id)
        emit("alarm_removed", outcome: "success", id: id)
    }

    // MARK: Voice alarm OFF + SNOOZE (2026-09-08)

    /// The enabled alarm whose most recent ring is closest to `now` —
    /// the target for the voice OFF/SNOOZE commands ("turn off the
    /// alarm", "snooze"): when an alarm is ringing or just rang, that is
    /// THE alarm the user means, and the confirmation always speaks its
    /// time so a mis-target can never pass silently. Deterministic
    /// under the injected `now` (tests pin it). Nil when no enabled
    /// alarm exists.
    func mostRecentlyRungEnabledAlarm() -> Alarm? {
        let calendar = Calendar.current
        let current = now()
        return alarms
            .filter(\.isEnabled)
            .compactMap { alarm -> (alarm: Alarm, lastRing: Date)? in
                let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
                guard let lastRing = calendar.nextDate(after: current,
                                                       matching: components,
                                                       matchingPolicy: .nextTime,
                                                       direction: .backward) else { return nil }
                return (alarm, lastRing)
            }
            .max(by: { $0.lastRing < $1.lastRing })?
            .alarm
    }

    /// Voice-path alarm OFF. Persists `enabled=false` and clears any
    /// snooze-until marker BEFORE cancelling the pending daily AND any
    /// pending snooze notification (persist-then-arm house rule), then
    /// reports the honest outcome. Main-confined (the coordinator's
    /// voice path runs on main); the Settings toggle keeps using
    /// `setAlarmEnabled`.
    @discardableResult
    func disableAlarm(id: UUID) -> AlarmOffOutcome {
        guard let alarm = alarm(with: id), alarm.isEnabled else {
            return .noAlarm
        }
        var updated = alarm
        updated.isEnabled = false
        updated.snoozedUntil = nil
        guard store.saveAlarms(alarms.map { $0.id == id ? updated : $0 }) else {
            emit("alarm_persistence_failed", outcome: "failed")
            return .failed
        }
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            alarms[index] = updated
        }
        scheduler.cancelAlarm(id: id)
        scheduler.cancelSnooze(id: id)
        emit("alarm_disabled", outcome: "success", id: id)
        return .disabled(time: alarm.time)
    }

    /// Voice-path SNOOZE. Persists the snooze-until marker first, then
    /// arms a ONE-SHOT re-wake notification `minutes` from `now()` —
    /// the daily repeat request is untouched, and a repeat snooze
    /// replaces the previous one-shot in place. `minutes` is defensively
    /// clamped to 1…`maxSnoozeMinutes` (the parser already enforces the
    /// same bound). Main-confined.
    @discardableResult
    func snoozeAlarm(id: UUID, minutes: Int) -> AlarmSnoozeOutcome {
        let bounded = min(max(minutes, 1), Self.maxSnoozeMinutes)
        guard let alarm = alarm(with: id), alarm.isEnabled else {
            return .noAlarm
        }
        let until = now().addingTimeInterval(TimeInterval(bounded * 60))
        var updated = alarm
        updated.snoozedUntil = until
        guard store.saveAlarms(alarms.map { $0.id == id ? updated : $0 }) else {
            emit("alarm_persistence_failed", outcome: "failed")
            return .failed
        }
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            alarms[index] = updated
        }
        scheduler.scheduleSnooze(for: updated, timeInterval: TimeInterval(bounded * 60))
        emit("alarm_snoozed", outcome: "success", id: id)
        return .snoozed(until: until)
    }

    // MARK: Timer creation (voice + UI)

    /// Point-of-use creation, same contract as `addAlarm`. The countdown
    /// is fully in-app: `endsAt` is persisted immediately, the one-shot
    /// completion notification is armed, and the Settings leaf renders the
    /// live remaining time.
    func startTimer(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        guard (1...Self.maxTimerDurationSeconds).contains(durationSeconds) else {
            emit("timer_invalid_duration", outcome: "failed")
            return .failed
        }
        let granted = await scheduler.requestAuthorizationIfNeeded()
        guard granted else {
            emit("timer_permission_denied", outcome: "denied")
            return .permissionDenied
        }
        return await onMain {
            self.startTimerAuthorized(durationSeconds: durationSeconds, label: label)
        }
    }

    private func startTimerAuthorized(durationSeconds: Int, label: String?) -> AlarmTimerSetOutcome {
        guard activeTimers.count < AlarmTimersStore.maxTimers else {
            emit("timer_capacity_reached", outcome: "at_capacity")
            return .atCapacity
        }
        let timer = TimerItem(endsAt: now().addingTimeInterval(TimeInterval(durationSeconds)),
                              label: Self.trimmed(label))
        guard store.saveTimers(timers + [timer]) else {
            emit("timer_persistence_failed", outcome: "failed")
            return .failed
        }
        timers.append(timer)
        scheduler.scheduleTimerCompletion(for: timer)
        emit("timer_created", outcome: "success", id: timer.id)
        return .scheduled
    }

    /// Cancels a running timer (persist removal, then cancel the pending
    /// notification). Main-confined (UI).
    func cancelTimer(id: UUID) {
        guard timer(with: id) != nil else { return }
        guard store.saveTimers(timers.filter { $0.id != id }) else {
            emit("timer_persistence_failed", outcome: "failed")
            return
        }
        timers.removeAll { $0.id == id }
        scheduler.cancelTimer(id: id)
        emit("timer_cancelled", outcome: "success", id: id)
    }

    /// Marks a timer finished (the foreground notification delegate
    /// observed its completion). The row leaves the visible list and the
    /// next prune sweeps it from storage. Dispatches to main when called
    /// off it (delegate callbacks can arrive on any queue).
    func expireTimer(id: UUID) {
        guard timer(with: id) != nil else { return }
        let mutation = { [weak self] in
            guard let self else { return }
            guard var timer = self.timer(with: id), timer.isActive else { return }
            timer.isActive = false
            guard self.store.saveTimers(self.timers.map { $0.id == id ? timer : $0 }) else {
                self.emit("timer_persistence_failed", outcome: "failed")
                return
            }
            if let index = self.timers.firstIndex(where: { $0.id == id }) {
                self.timers[index] = timer
            }
            self.emit("timer_finished", outcome: "success", id: id)
        }
        if Thread.isMainThread {
            mutation()
        } else {
            DispatchQueue.main.async(execute: mutation)
        }
    }

    /// Drops finished rows and rows whose deadline has passed (their
    /// one-shot notification already fired or is stale). Runs inside
    /// `scheduleAll` and whenever the Settings leaf appears.
    func pruneFinishedTimers() {
        let current = now()
        let living = timers.filter { $0.isActive && $0.endsAt > current }
        guard living.count != timers.count else { return }
        guard store.saveTimers(living) else {
            emit("timer_persistence_failed", outcome: "failed")
            return
        }
        timers = living
        emit("timer_pruned_expired", outcome: "success")
    }

    // MARK: Schedule all (FR-025 launch + BGTask re-queue)

    /// Re-arms every enabled alarm and every live timer — the FR-025
    /// re-queue. Idempotent: pending requests replace in place by id.
    /// Launched from `start()` (main) and the background task (off main —
    /// this dispatches the whole pass to main; nothing else can mutate the
    /// service concurrently while the app is suspended).
    func scheduleAll() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleAll() }
            return
        }
        pruneFinishedTimers()
        for alarm in alarms where alarm.isEnabled {
            scheduler.scheduleAlarm(alarm)
        }
        for timer in activeTimers {
            scheduler.scheduleTimerCompletion(for: timer)
        }
        emit("alarms_timers_requeued", outcome: "success")
    }

    // MARK: - Private helpers

    /// Next future occurrence of `proposedTime`'s time-of-day: a moment
    /// already passed rolls to tomorrow at the same minute. Used by the
    /// voice path (whose parser already resolved next-occurrence — this is
    /// idempotent for future dates) and the Settings DatePicker (which can
    /// hand back an earlier time today).
    private func nextOccurrence(of proposed: Date) -> Date {
        let calendar = Calendar.current
        guard proposed <= now() else { return proposed }
        return calendar.date(byAdding: .day, value: 1, to: proposed) ?? proposed
    }

    static func trimmed(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func onMain<Value>(_ body: @escaping () -> Value) async -> Value {
        if Thread.isMainThread { return body() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: Observability

    private func emit(_ eventType: String, outcome: String, id: UUID? = nil) {
        var metadata: [String: String] = [:]
        if let id { metadata["id_hash"] = IdHashing.shortHash(of: id) }
        observabilityBus.emit(ObservabilityEvent(
            component: "alarms_timers",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
