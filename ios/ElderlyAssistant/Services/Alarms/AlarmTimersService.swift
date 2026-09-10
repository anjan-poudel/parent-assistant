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

// MARK: - AlarmScheduler (alarm seam + timer notifications)

/// [ALARMS-TIMERS] (2026-09-07) Arms alarms and timer completions.
///
/// [ALARMKIT-ALARMS] (2026-09-10) The ALARM side is now a seam over two
/// backends (see `AlarmSchedulingBackend`):
///  - `AlarmKitAlarmBackend` on iOS 26+ — REAL system alarms (ring
///    through silent mode and Focus, Lock Screen stop/snooze alert, fire
///    with the app terminated). Gated on AlarmKit authorization
///    (`NSAlarmKitUsageDescription` + point-of-use ask).
///  - `UNAlarmBackend` pre-26 — the historical daily-repeating local
///    notification. PLATFORM HONESTY — iOS does NOT let third-party apps
///    create alarms in the built-in Clock app, so an "alarm" there is the
///    app's own notification repeating DAILY at the chosen time-of-day
///    (`UNCalendarNotificationTrigger(dateComponents: [.hour, .minute],
///    repeats: true)`). The Settings caption (`alarms.honestyNote`) says
///    exactly that on those devices.
///
/// Timers are fully in-app countdowns whose completion fires a one-shot
/// notification at `endsAt` (NOT part of the backend seam); while the app
/// is foregrounded the presentation delegate
/// (`AlarmTimerNotificationDelegate`) also speaks "Timer finished."
/// PLATFORM HONESTY — iOS does NOT let third-party apps create alarms in
/// the built-in Clock app. Every alarm app (this one included) schedules
/// its OWN repeating local notification instead, so an "alarm" here is a
/// notification that repeats DAILY at the chosen time-of-day while the
/// alarm is enabled (`UNCalendarNotificationTrigger(dateComponents:
/// [.hour, .minute], repeats: true)`). The Settings leaf caption
/// (`alarms.honestyNote`) and this doc say exactly that. Timers are fully
/// in-app countdowns whose completion fires a one-shot notification at
/// `endsAt` — the UN-path fallback. [TIMER-ALARM] (2026-09-10) On iOS 26
/// the PRIMARY timer path is AlarmKit's system-managed timer
/// (`AlarmKitSystemScheduler` — full-screen system alert, rings through
/// silent/Focus, survives app termination); while the app is foregrounded
/// on the UN path, the in-app `TimerAlarmEngine` rings a looping loud
/// bell until the user stops it.
final class AlarmScheduler {
    private let notifications: LocalNotificationScheduling
    private let backend: AlarmSchedulingBackend

    /// Locale for notification titles/bodies; kept in sync by
    /// `AppCoordinator` when the app language changes (spec §3.2).
    /// Forwarded to the backend, which builds all alarm content per-call
    /// (armed notifications keep the language they were armed in until
    /// the next re-arm).
    var locale: Locale {
        didSet { backend.locale = locale }
    }

    /// Explicit UN backend — the pre-26 production path AND the existing
    /// test construction (`AlarmScheduler(notifications: center)`), so
    /// every historical UN assertion keeps working unchanged.
    init(notifications: LocalNotificationScheduling,
         locale: Locale = Locale(identifier: "en")) {
        self.notifications = notifications
        self.locale = locale
        self.backend = UNAlarmBackend(notifications: notifications, locale: locale)
    }

    /// Explicit backend — tests inject fakes; `makeDefault` below is the
    /// production entry point.
    init(notifications: LocalNotificationScheduling,
         locale: Locale = Locale(identifier: "en"),
         backend: AlarmSchedulingBackend) {
        self.notifications = notifications
        self.locale = locale
        self.backend = backend
    }

    /// [ALARMKIT-ALARMS] Production factory: the AlarmKit backend on
    /// iOS 26+, the UN backend before (deployment target iOS 16).
    static func makeDefault(notifications: LocalNotificationScheduling,
                            locale: Locale = Locale(identifier: "en")) -> AlarmScheduler {
        AlarmScheduler(notifications: notifications,
                       locale: locale,
                       backend: makeAlarmBackend(isAlarmKitAvailable: isAlarmKitAvailable,
                                                 notifications: notifications,
                                                 locale: locale))
    }

    /// Pure backend selection, isolated for tests: AlarmKit ONLY when the
    /// runtime actually has it (the `#available` gate is what makes the
    /// boolean honest on every simulator/device). Every AlarmKit-touching
    /// reference sits inside this guard — nothing outside it links the
    /// iOS-26-only types (see `AlarmKitAlarmBackend.swift`).
    static func makeAlarmBackend(isAlarmKitAvailable: Bool,
                                 notifications: LocalNotificationScheduling,
                                 locale: Locale) -> AlarmSchedulingBackend {
        if isAlarmKitAvailable, #available(iOS 26.0, *) {
            return AlarmKitAlarmBackend(manager: ProductionSystemAlarmManager(),
                                        notifications: notifications,
                                        locale: locale)
        }
        return UNAlarmBackend(notifications: notifications, locale: locale)
    }

    private static var isAlarmKitAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: Backend state (Settings leaf honesty)

    /// Which backend arms alarms on THIS device — the Settings leaf
    /// labels each row "system alarm" vs "app notification" from this.
    var alarmSchedulingKind: AlarmBackendKind { backend.kind }

    /// Alarm-permission status in neutral terms (AlarmKit authorization
    /// on iOS 26+, notification permission before) — a `.denied` shows
    /// the honest caption in Settings.
    var alarmAuthorizationStatus: AlarmAuthorizationStatus { backend.authorizationStatus }

    // MARK: Authorization (point of use)

    /// Requests permission at POINT OF USE — the first alarm or timer
    /// creation asks; every later call resolves the already-determined
    /// status without re-prompting. On the AlarmKit backend the GATE is
    /// AlarmKit authorization (UN permission is asked best-effort in the
    /// same pass but never gates a system alarm).
    func requestAuthorizationIfNeeded() async -> Bool {
        await backend.requestAuthorizationIfNeeded()
    }

    // MARK: Alarms — backend-routed

    /// Arms (or replaces, same id) the alarm — a SYSTEM time-of-day
    /// alarm on the AlarmKit backend, the daily-repeating notification on
    /// the UN backend. Only the hour/minute of `alarm.time` matter.
    func scheduleAlarm(_ alarm: Alarm) {
        backend.scheduleAlarm(alarm)
    }

    func cancelAlarm(id: UUID) {
        backend.cancelAlarm(id: id)
    }

    // MARK: Snooze — backend-routed (2026-09-08 + [ALARMKIT-ALARMS])

    /// Arms the app's own ONE-SHOT snooze notification for `alarm` that
    /// rings `timeInterval` seconds from arming. The daily repeat is
    /// untouched, and a repeat snooze replaces the previous one in place
    /// (same identifier). The interval (not an absolute date) is the seam
    /// so tests pin the exact trigger with the service's injected clock.
    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval) {
        backend.scheduleSnooze(for: alarm, timeInterval: timeInterval)
    }

    func cancelSnooze(id: UUID) {
        backend.cancelSnooze(id: id)
    }

    /// [ALARMKIT-ALARMS] Voice snooze → the system alarm where possible:
    /// true when the backend handed the snooze to the system (the system
    /// re-fires after the alarm's postAlert interval — only for the
    /// DEFAULT snooze length). False — the caller arms the app's own
    /// one-shot instead — for arbitrary-minute snoozes (the system
    /// duration is fixed) and everywhere pre-26.
    func snoozeViaSystem(id: UUID, minutes: Int) -> Bool {
        backend.snoozeViaSystem(id: id, minutes: minutes)
    }

    // MARK: Timers — one-shot completion

    /// Arms the one-shot completion notification for `timer` at its
    /// `endsAt`. The trigger date is absolute, so an in-flight timer
    /// survives re-arms (`scheduleAll`) by simple replacement.
    /// [TIMER-ALARM] (2026-09-10) Loudest configuration public API allows
    /// for the background fallback:
    ///  - Custom bundled bell sound (`timer-alarm-bell.wav`, CC0, ~4.6 s —
    ///    within the ≤30 s linear-PCM limit for custom notification
    ///    sounds; falls back to the system default sound if the asset is
    ///    missing). The OS plays it ONCE — notification sounds cannot
    ///    loop — and it RESPECTS the silent switch. The repeating
    ///    until-stopped alarm is the in-app engine (foreground) and, on
    ///    iOS 26, the system-managed AlarmKit timer.
    ///  - `.timeSensitive` interruption level (iOS 15+ public API): the
    ///    user explicitly set this countdown, so the notification breaks
    ///    through Focus like a call would.
    ///  - NOT critical alerts: that needs the
    ///    com.apple.developer.usernotifications.critical-alerts
    ///    entitlement — an Apple-reviewed special entitlement this app
    ///    does not hold, and claiming the API without it would silently
    ///    degrade. If the project ever obtains the entitlement, switch
    ///    this line to `.defaultCritical`; do NOT claim it now.
    func scheduleTimerCompletion(for timer: TimerItem) {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("timers.finished", locale: locale)
        content.body = timer.label ?? ""
        content.sound = UNNotificationSound(named: UNNotificationSoundName("timer-alarm-bell.wav"))
            ?? .default
        content.interruptionLevel = .timeSensitive
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
}

// MARK: - AlarmTimersService

/// [ALARMS-TIMERS] (2026-09-07) Owns the on-device alarms + timers feature
/// end to end — the single service behind the voice stage (via
/// `AppCoordinator`), the Settings leaf, launch re-arm and the background
/// task.
///
/// [TIMER-ALARM] (2026-09-10) Timer paths, best-first:
///  1. iOS 26 + AlarmKit authorized — SYSTEM-MANAGED timer
///     (`AlarmManager`, see `AlarmKitSystemScheduler`): the system rings
///     it like the Clock app (full-screen alert, through silent mode and
///     Focus, Dynamic Island/StandBy/Watch countdown), and it survives
///     app termination. These timers are NOT re-armed by `scheduleAll` —
///     the system owns them; `scheduleAll` reconciles against
///     `AlarmManager.alarms` instead.
///  2. Everything else — the UN notification path (one-shot completion
///     notification with the bundled bell + `.timeSensitive`), plus the
///     in-app `TimerAlarmEngine` ringing a LOUD LOOPING bell in the
///     foreground until the user stops it (the fallback foreground
///     experience, also used when AlarmKit authorization is denied).
///
/// Rules inherited from the medication/routine paths:
///  - Persistence BEFORE arming: a crash between the two must leave
///    durable state, never an armed notification for a forgotten item.
///  - FR-025 re-queue: `scheduleAll()` re-arms every UN-path item on
///    every launch and BGTask wake; armed requests replace in place by
///    id, so this is idempotent.
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
    /// [TIMER-ALARM] The AlarmKit seam (iOS 26). Nil in tests and on
    /// pre-26 builds — the service then behaves exactly as before (pure
    /// UN path), which is what every existing test pins.
    private let systemScheduler: AlarmKitTimerScheduling?
    private let observabilityBus: ObservabilityBus
    private let now: () -> Date
    /// [TIMER-ALARM] Main-confined: ids of active timers the SYSTEM
    /// manages (AlarmKit path). Rebuilt by `scheduleAll`'s reconciliation
    /// and extended on every system-path creation; never persisted — the
    /// system alarm list IS the durable record.
    private(set) var systemManagedTimerIDs: Set<UUID> = []
    /// [BOOT-M1M2] Main-confined: the persisted lists have been restored
    /// at least once (guards `restoreAndScheduleAll` against a second
    /// restore clobbering in-memory mutations).
    private var didRestorePersistedState = false

    init(store: AlarmTimersStore,
         scheduler: AlarmScheduler,
         observabilityBus: ObservabilityBus,
         locale: Locale = Locale(identifier: "en"),
         now: @escaping () -> Date = Date.init,
         systemScheduler: AlarmKitTimerScheduling? = nil) {
        self.store = store
        self.scheduler = scheduler
        self.observabilityBus = observabilityBus
        self.locale = locale
        self.now = now
        self.systemScheduler = systemScheduler
        // [BOOT-M1M2] ZERO storage IO in init (constant-time startup):
        // the lists start empty and `restoreAndScheduleAll()` (called
        // once from AppCoordinator.start() on the boot queue) loads +
        // re-arms them moments after first paint. Mutators keep working
        // against the in-memory lists; the restore lands long before any
        // UI or voice turn can touch them.
        self.alarms = []
        self.timers = []
    }

    /// [BOOT-M1M2] Restore the persisted lists, callable from any
    /// thread: the storage reads run on the CALLING queue (the
    /// coordinator's boot queue), the published lists are assigned on
    /// main, then `completion` fires on main. Synchronous when called on
    /// main (the UI/test path). Idempotent per process (restore once —
    /// a second restore would clobber in-memory mutations;
    /// MedicationScheduler's didRestore rule). Load-only: nothing is
    /// armed, nothing is pruned, no events are emitted.
    func restorePersistedState(completion: (() -> Void)? = nil) {
        let loadedAlarms = store.loadAlarms()
        let loadedTimers = store.loadTimers()
        let apply: () -> Void = { [weak self] in
            guard let self, !self.didRestorePersistedState else {
                completion?()
                return
            }
            self.didRestorePersistedState = true
            self.alarms = loadedAlarms
            self.timers = loadedTimers
            completion?()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// [BOOT-M1M2] Launch restore + re-arm in one shot (what
    /// `AppCoordinator.start()` runs on the boot queue): restore first,
    /// then `scheduleAll()` on main — the re-arm must never see an
    /// unloaded list: `pruneFinishedTimers` persists the in-memory rows,
    /// so arming against `[]` would WIPE the stored timers. `completion`
    /// fires on main after the re-arm.
    func restoreAndScheduleAll(completion: (() -> Void)? = nil) {
        restorePersistedState { [weak self] in
            self?.scheduleAll()
            completion?()
        }
    }

    // MARK: Visible state

    /// Live countdowns only — finished rows leave the visible list the
    /// moment they finish and are swept from storage by the next prune.
    var activeTimers: [TimerItem] {
        timers.filter { $0.isActive && $0.endsAt > now() }
    }

    /// [ALARMKIT-ALARMS] (2026-09-10) The backend arming alarms on THIS
    /// device — AlarmKit system alarms on iOS 26+, UN notifications
    /// before. The Settings leaf labels each alarm row from this.
    var alarmSchedulingKind: AlarmBackendKind { scheduler.alarmSchedulingKind }

    /// [ALARMKIT-ALARMS] (2026-09-10) Alarm-permission status (AlarmKit
    /// authorization on iOS 26+, notification permission before). A
    /// `.denied` shows the honest caption in Settings.
    var alarmAuthorizationStatus: AlarmAuthorizationStatus { scheduler.alarmAuthorizationStatus }

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
    /// arms the re-wake `minutes` from `now()` — the daily repeat is
    /// untouched, and a repeat snooze replaces the previous re-wake in
    /// place. `minutes` is defensively clamped to
    /// 1…`maxSnoozeMinutes` (the parser already enforces the same
    /// bound). Main-confined.
    ///
    /// [ALARMKIT-ALARMS] System-first routing: a DEFAULT-length snooze
    /// on the AlarmKit path hands off to the system alarm's own snooze
    /// (`AlarmManager.countdown` — the system re-fires after the alarm's
    /// postAlert, configured to the same default), so the re-wake is a
    /// REAL system ring. The system duration is fixed, so
    /// arbitrary-minute snoozes fall back to the app's own one-shot
    /// notification (and the whole UN path pre-26) — `until` is honest
    /// either way.
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
        if !scheduler.snoozeViaSystem(id: alarm.id, minutes: bounded) {
            scheduler.scheduleSnooze(for: updated, timeInterval: TimeInterval(bounded * 60))
        }
        emit("alarm_snoozed", outcome: "success", id: id)
        return .snoozed(until: until)
    }

    // MARK: Timer creation (voice + UI)

    /// Point-of-use creation. The notification-permission flow is
    /// UNCHANGED (same ask, same honest denial line); [TIMER-ALARM] on
    /// iOS 26 an AlarmKit authorization is asked at the same point of
    /// use and, when granted, the timer becomes SYSTEM-managed (the
    /// system rings it — through silent mode and Focus, full-screen, even
    /// after the app is terminated). Denied/absent AlarmKit keeps the UN
    /// path, so a timer always works through at least the old mechanism
    /// whenever notifications are on.
    func startTimer(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        guard (1...Self.maxTimerDurationSeconds).contains(durationSeconds) else {
            emit("timer_invalid_duration", outcome: "failed")
            return .failed
        }
        let notificationGranted = await scheduler.requestAuthorizationIfNeeded()
        var systemAuthorized = false
        if let systemScheduler {
            systemAuthorized = await systemScheduler.requestAuthorization() == .authorized
            if systemAuthorized {
                emit("timer_system_path_selected", outcome: "info")
            }
        }
        guard notificationGranted || systemAuthorized else {
            emit("timer_permission_denied", outcome: "denied")
            return .permissionDenied
        }
        return await onMain {
            await self.startTimerAuthorized(durationSeconds: durationSeconds,
                                            label: label,
                                            useSystemPath: systemAuthorized)
        }
    }

    private func startTimerAuthorized(durationSeconds: Int, label: String?,
                                      useSystemPath: Bool) async -> AlarmTimerSetOutcome {
        guard activeTimers.count < AlarmTimersStore.maxTimers else {
            emit("timer_capacity_reached", outcome: "at_capacity")
            return .atCapacity
        }
        let timer = TimerItem(endsAt: now().addingTimeInterval(TimeInterval(durationSeconds)),
                              label: Self.trimmed(label))
        // Persistence BEFORE arming (house rule — see class doc).
        guard store.saveTimers(timers + [timer]) else {
            emit("timer_persistence_failed", outcome: "failed")
            return .failed
        }
        timers.append(timer)
        if useSystemPath, let systemScheduler {
            do {
                try await systemScheduler.scheduleTimer(id: timer.id,
                                                        duration: TimeInterval(durationSeconds),
                                                        label: timer.label)
                systemManagedTimerIDs.insert(timer.id)
                emit("timer_system_scheduled", outcome: "success", id: timer.id)
            } catch {
                // Honest fallback: the system path failed (e.g.
                // maximumLimitReached) — the UN path still delivers the
                // old behavior, which is better than a lost timer.
                scheduler.scheduleTimerCompletion(for: timer)
                emit("timer_system_schedule_failed_un_fallback",
                     outcome: "fallback", id: timer.id)
            }
        } else {
            scheduler.scheduleTimerCompletion(for: timer)
        }
        emit("timer_created", outcome: "success", id: timer.id)
        return .scheduled
    }

    /// Cancels a running timer (persist removal, then cancel the pending
    /// notification AND, when system-managed, the AlarmKit timer).
    /// Main-confined (UI).
    func cancelTimer(id: UUID) {
        guard timer(with: id) != nil else { return }
        guard store.saveTimers(timers.filter { $0.id != id }) else {
            emit("timer_persistence_failed", outcome: "failed")
            return
        }
        timers.removeAll { $0.id == id }
        scheduler.cancelTimer(id: id)
        if systemManagedTimerIDs.remove(id) != nil {
            systemScheduler?.cancelTimer(id: id)
        }
        emit("timer_cancelled", outcome: "success", id: id)
    }

    /// [TIMER-ALARM] Cancels only the pending UN completion notification
    /// — the `TimerAlarmEngine`'s ring-start hook: the in-app looping
    /// bell takes over in the foreground, and the OS one-shot sound must
    /// not double up. The row and any system-managed timer are untouched.
    /// Main-confined.
    func cancelPendingNotification(id: UUID) {
        scheduler.cancelTimer(id: id)
    }

    /// [TIMER-ALARM] Active timers that ring through the app's own engine
    /// (the UN path) — the foreground driver's feed. System-managed
    /// timers are excluded: the SYSTEM presents their alarm (in the
    /// foreground too), and a second in-app bell would double-ring.
    var engineManagedActiveTimers: [TimerItem] {
        activeTimers.filter { !systemManagedTimerIDs.contains($0.id) }
    }

    /// [TIMER-ALARM] The coordinator's AlarmKit `alarmUpdates`
    /// observation: a system-managed timer whose alarm no longer exists
    /// was dismissed or cancelled in the SYSTEM UI (the Lock Screen
    /// alert's Stop, the Dynamic Island dismiss) — its row expires,
    /// mirroring the system, never outliving it. Main-confined (dispatches
    /// like `scheduleAll` when called off main).
    func noteSystemTimerUpdates(systemTimerIDs systemIDs: Set<UUID>) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.noteSystemTimerUpdates(systemTimerIDs: systemIDs)
            }
            return
        }
        for id in systemManagedTimerIDs where !systemIDs.contains(id) {
            expireTimer(id: id)
        }
        systemManagedTimerIDs.formIntersection(systemIDs)
    }

    /// [TIMER-ALARM] Pushes the active locale into the AlarmKit adapter
    /// (its alert/countdown titles resolve at schedule time, the same
    /// contract as `AlarmScheduler.locale`). No-op when the seam is nil.
    func setSystemSchedulerLocale(_ locale: Locale) {
        if #available(iOS 26.0, *),
           let systemScheduler = systemScheduler as? AlarmKitSystemScheduler {
            systemScheduler.locale = locale
        }
    }

    /// Marks a timer finished — [TIMER-ALARM] either the user pressed
    /// STOP on the in-app alarm screen, or the SYSTEM-managed timer's
    /// alert was dismissed (the coordinator's AlarmKit `alarmUpdates`
    /// observation reports it). The row leaves the visible list and the
    /// next prune sweeps it from storage. Dispatches to main when called
    /// off it (delegate callbacks can arrive on any queue).
    func expireTimer(id: UUID) {
        guard timer(with: id) != nil else { return }
        let mutation = { [weak self] in
            guard let self else { return }
            self.systemManagedTimerIDs.remove(id)
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

    /// [TIMER-ALARM] (2026-09-10) How long a finished row survives in
    /// storage after its deadline — the notification-tap grace window:
    /// the delivered notification stays tappable for a while after the
    /// timer ended (typically seconds to minutes), and the tap must be
    /// able to route into the ringing screen (`TimerAlarmEngine`'s
    /// `timerLookup` resolves the row). Beyond the grace a tap opens the
    /// app without ringing — honest: that timer ended long ago.
    static let timerTapGraceSeconds: TimeInterval = 300

    /// Drops finished rows and rows whose deadline has passed LONGER than
    /// `timerTapGraceSeconds` (their one-shot notification already fired
    /// or is stale). Runs inside `scheduleAll` and whenever the Settings
    /// leaf appears.
    func pruneFinishedTimers() {
        let current = now()
        let living = timers.filter { timer in
            guard timer.isActive else { return false }
            if timer.endsAt > current { return true }
            return current.timeIntervalSince(timer.endsAt) <= Self.timerTapGraceSeconds
        }
        guard living.count != timers.count else { return }
        guard store.saveTimers(living) else {
            emit("timer_persistence_failed", outcome: "failed")
            return
        }
        timers = living
        emit("timer_pruned_expired", outcome: "success")
    }

    // MARK: Schedule all (FR-025 launch + BGTask re-queue)

    /// Re-arms every enabled alarm and every UN-path live timer — the
    /// FR-025 re-queue. Idempotent: pending requests replace in place by
    /// id. Launched from `start()` (main) and the background task (off
    /// main — this dispatches the whole pass to main; nothing else can
    /// mutate the service concurrently while the app is suspended).
    ///
    /// [TIMER-ALARM] System-managed (AlarmKit) timers are NOT re-armed
    /// here — the SYSTEM owns them across app terminations, which is
    /// their whole point. Instead the pass reconciles against
    /// `AlarmManager.alarms`:
    ///  - active rows whose id the system still manages are tracked in
    ///    `systemManagedTimerIDs` (excluded from the UN re-arm AND from
    ///    the in-app engine's feed);
    ///  - active rows the system NO LONGER manages were dismissed from
    ///    the system UI (e.g. the Lock Screen countdown's dismiss) while
    ///    the app was dead — they are expired, mirroring the system.
    func scheduleAll() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleAll() }
            return
        }
        pruneFinishedTimers()
        if let systemScheduler {
            let systemIDs = systemScheduler.systemTimerIDs()
            systemManagedTimerIDs.formIntersection(Set(timers.map(\.id)))
            for timer in activeTimers
            where systemManagedTimerIDs.contains(timer.id) && !systemIDs.contains(timer.id) {
                expireTimer(id: timer.id)
            }
            systemManagedTimerIDs.formUnion(systemIDs)
        }
        for alarm in alarms where alarm.isEnabled {
            scheduler.scheduleAlarm(alarm)
        }
        for timer in activeTimers where !systemManagedTimerIDs.contains(timer.id) {
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

    /// Async variant for main-confined bodies that themselves await (the
    /// [TIMER-ALARM] AlarmKit schedule). SE-0338 overload ranking keeps
    /// the existing sync call sites on the sync overload.
    private func onMain<Value>(_ body: @escaping () async -> Value) async -> Value {
        if Thread.isMainThread { return await body() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                Task {
                    continuation.resume(returning: await body())
                }
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
