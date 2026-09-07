import Foundation
import Combine
import CryptoKit
import BackgroundTasks
import UIKit
import EventKit

/// Read-only bridge from the native Calendar/Reminders apps into this
/// app (v2-pivot §4.1 + user decisions 2026-09-07): events from ALL
/// calendars and due-dated Reminders-app items surface as
/// `ExternalReminder` values with in-app notifications; the app never
/// writes back — a row tap opens the native app via `calshow:` /
/// `x-apple-reminderkit://` behind the `ExternalItemOpening` seam.
///
/// Bridge, not rewrite: the app's own medication/routine schedulers are
/// untouched and keep firing as before. Items that would double-notify
/// are excluded up front (our own mirror-tagged routine events, items
/// that already carry their own alarm, declined invitations, items
/// already started).
///
/// Rescan cadence: launch + foreground (`AppCoordinator.start` /
/// `handleScenePhase(.active)`), the hourly BGAppRefresh task
/// `com.elderlyassistant.calendar.scan`, and — while enabled — every
/// `.EKEventStoreChanged` notification, so an edit the family makes in
/// the native Calendar/Reminders apps lands within a moment instead of
/// waiting for the next cadence beat. Every pass is idempotent: stable
/// identifiers (`external_` + SHA-256 of the native item) let
/// same-identifier re-adds replace in place, and cancels are scoped to
/// identifiers this service armed — never `removeAllPendingNotificationRequests`
/// (medication alarms share the center). Whole calendars can be
/// excluded by identifier (`excludedCalendarIdentifiers` — the app's
/// own two-way "Sahayak" calendar, 2026-09-07).
final class ExternalCalendarService: ObservableObject {

    // MARK: - Tunables & identity

    static let backgroundTaskIdentifier = "com.elderlyassistant.calendar.scan"
    /// BGAppRefresh earliest-begin — hourly is the plan's cadence.
    static let backgroundRefreshMinimumLead: TimeInterval = 60 * 60
    /// Scan horizon: events from the START OF TODAY through
    /// +scanHorizonDays full days ahead. The window must open at 00:00
    /// — EKEventStore's event predicate only returns events whose
    /// start falls inside the window, so a window opening at the scan
    /// instant would hide everything that started earlier today
    /// (all-day events, start 00:00, above all — precisely the days the
    /// family calendar runs on). Calendar-driven regression fix,
    /// 2026-09-07. Far-future events re-scan into view as they approach.
    static let scanHorizonDays = 7
    /// Hard cap of armed notifications per pass. UN keeps 64 pending
    /// per app; 48 leaves headroom for the medication and routine
    /// systems' alarms on the same center.
    static let maxArmedNotifications = 48
    static let defaultLeadMinutes = 5
    static let maxLeadMinutes = 30

    /// Honest, persisted account of what the OS allows (restored in
    /// init — same statefulness fix as `CalendarSyncService.status`).
    enum ExternalAccessStatus: String, Equatable {
        /// Never asked (feature off, or freshly toggled off).
        case notRequested
        /// Both stores readable.
        case enabled
        /// Exactly one store readable (e.g. events yes, reminders no) —
        /// the feature works partially and says so.
        case partial
        /// Permission denied by the user (or restricted).
        case denied
        /// A fetch failed despite permission — transient.
        case error
    }

    // MARK: - Seams

    private let scanner: NativeCalendarScanning
    private let alarmScheduler: ExternalAlarmScheduling
    private let opener: ExternalItemOpening
    private let observabilityBus: ObservabilityBus
    /// Injectable clock — tests pin "now" so horizon/lead behavior is
    /// deterministic. Production passes `Date.init`.
    private let now: () -> Date
    /// Background-refresh submission, injectable for tests.
    private let submitRefreshRequest: () -> Void

    /// Locale notification titles resolve against. `AppCoordinator`
    /// keeps it in sync with the app language (`syncServiceLocales`).
    var locale: Locale = Locale(identifier: "en")

    /// Native calendars whose events this service must never import —
    /// calendar-driven task, 2026-09-07: the app's own two-way
    /// "Sahayak" calendar mirrors the routine, whose alarms fire
    /// in-app already; importing its events would double-notify. The
    /// mirror-tag notes check in `mapEvents` is the braces (it covers
    /// both mirror forms); this identifier set is the belt that keeps
    /// mirror events out even if their notes ever change. Coordinated
    /// by `AppCoordinator` from `CalendarSyncService`'s Sahayak id.
    var excludedCalendarIdentifiers: Set<String> = []

    // MARK: - Persisted state (UserDefaults — UI preferences, not secrets)

    /// Whether the family turned importing on (Settings toggle). The
    /// toggle is INTENT; `status` is the OS's truth — a denied request
    /// leaves the toggle on with an honest status line underneath
    /// (same shape as `CalendarSyncService`).
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    /// Notification lead time in minutes (0–30, default 5; all-day
    /// items always fire 08:00 same day regardless). Changing it
    /// re-scans so armed notifications follow the new lead.
    var leadMinutes: Int {
        didSet {
            leadMinutes = min(max(leadMinutes, 0), Self.maxLeadMinutes)
            UserDefaults.standard.set(leadMinutes, forKey: Self.leadDefaultsKey)
            // Self-assignment inside didSet does not re-trigger the
            // observer, so the clamp above is recursion-free.
            guard isEnabled, leadMinutes != oldValue else { return }
            Task { await rescan() }
        }
    }

    private static let enabledDefaultsKey = "externalCalendar.enabled"
    private static let statusDefaultsKey = "externalCalendar.status"
    private static let leadDefaultsKey = "externalCalendar.leadMinutes"

    // MARK: - Published state

    @Published private(set) var status: ExternalAccessStatus
    /// Everything the last scan mapped (the whole horizon) — views
    /// derive today's rows through `todaysItems()`.
    @Published private(set) var reminders: [ExternalReminder] = []

    /// Notification identifiers this service armed on the last pass —
    /// the ONLY identifiers a scoped cancel may touch.
    private var armedIdentifiers: Set<String> = []

    /// `.EKEventStoreChanged` observer token (armed while enabled) —
    /// keeps import fresh without waiting for the next foreground or
    /// BGTask beat.
    private var storeChangeObserver: NSObjectProtocol?

    /// Coalescing flag: store-change notifications arrive in bursts
    /// (an edit session commits several times), and a scan already
    /// under way has seen the latest commit or will on the next
    /// notification — one pass per burst is enough. Touched only on
    /// the main queue (observer queue + the async reset below).
    private var isScanning = false

    init(
        scanner: NativeCalendarScanning = EKCalendarScanner(),
        alarmScheduler: ExternalAlarmScheduling = UNExternalReminderScheduler(),
        opener: ExternalItemOpening = SystemExternalItemOpener(),
        observabilityBus: ObservabilityBus,
        now: @escaping () -> Date = Date.init,
        submitRefreshRequest: @escaping () -> Void = ExternalCalendarService.submitBackgroundRefreshRequest
    ) {
        self.scanner = scanner
        self.alarmScheduler = alarmScheduler
        self.opener = opener
        self.observabilityBus = observabilityBus
        self.now = now
        self.submitRefreshRequest = submitRefreshRequest
        let restoredStatus = UserDefaults.standard
            .string(forKey: Self.statusDefaultsKey)
            .flatMap(ExternalAccessStatus.init(rawValue:)) ?? .notRequested
        self.status = restoredStatus
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        let storedLead = UserDefaults.standard.object(forKey: Self.leadDefaultsKey) as? Int
            ?? Self.defaultLeadMinutes
        self.leadMinutes = min(max(storedLead, 0), Self.maxLeadMinutes)
    }

    // MARK: - Lifecycle (coordinator-driven)

    /// Launch/foreground hook — NEVER prompts. When the family has the
    /// feature on, refreshes access truth (permission may have been
    /// revoked in Settings since last launch) and rescans. Called from
    /// `AppCoordinator.start` and the `.active` scene phase.
    func startIfEnabled() async {
        guard isEnabled else { return }
        startObservingNativeChanges()
        await rescan()
    }

    /// Point-of-use permission ask for BOTH stores (the Settings toggle
    /// turning ON) — then scans. Re-requesting after a decision returns
    /// the existing answer without prompting, so toggling again is safe.
    func enable() async {
        isEnabled = true
        startObservingNativeChanges()
        let eventsGranted = await scanner.requestEventAccess()
        let remindersGranted = await scanner.requestReminderAccess()
        await updateStatus(eventsGranted: eventsGranted, remindersGranted: remindersGranted)
        guard isEnabled else { return }   // family flipped the toggle mid-prompt
        emit("external_enabled",
             outcome: (eventsGranted || remindersGranted) ? "success" : "denied")
        await rescan()
    }

    /// Turns the feature off: cancels every notification this service
    /// armed (scoped — medication/routine alarms untouched) and clears
    /// the published list.
    func disable() async {
        isEnabled = false
        stopObservingNativeChanges()
        let stale = Array(armedIdentifiers)
        armedIdentifiers.removeAll()
        await MainActor.run {
            reminders = []
            persistStatus(.notRequested)
            if !stale.isEmpty {
                alarmScheduler.cancelExternalReminders(identifiers: stale)
            }
        }
        emit("external_disabled", outcome: "success",
             metadata: ["cancelled": "\(stale.count)"])
    }

    /// Full scan pass: events from start-of-day today through +7 full
    /// days (see `scanHorizonDays` — the window MUST open at 00:00 or
    /// today's already-started events never reach the mapper) + due
    /// reminders, mapped and published on main, previous armed
    /// notifications cancelled (scoped) and re-armed. Idempotent —
    /// this IS the BGTask handler body as well as the foreground
    /// refresh and the store-change observer's pass.
    func rescan() async {
        guard isEnabled else { return }
        submitRefreshRequest()

        let start = now()
        let (eventsGranted, remindersGranted) = await refreshedAccessTruth()

        var mapped: [ExternalReminder] = []
        var fetchFailed = false
        if eventsGranted {
            do {
                // Calendar-driven regression fix (2026-09-07): the
                // fetch window opens at the START OF THE SCAN DAY, not
                // at the scan instant — EKEventStore's predicate only
                // returns events whose start lies inside the window, so
                // a now()-anchored window hid every event that started
                // earlier today (all-day events above all). The mapper
                // still drops timed events already under way — it must
                // simply get the chance to SEE them first.
                let calendar = Calendar.current
                let windowStart = calendar.startOfDay(for: start)
                let scanned = try await scanner.fetchEvents(
                    from: windowStart,
                    to: windowStart.addingTimeInterval(
                        TimeInterval(Self.scanHorizonDays + 1) * 86_400)
                )
                mapped.append(contentsOf: Self.mapEvents(importable(from: scanned),
                                                         now: start))
            } catch {
                fetchFailed = true
            }
        }
        if remindersGranted {
            do {
                let scanned = try await scanner.fetchDueReminders()
                mapped.append(contentsOf: Self.mapReminders(scanned, now: start))
            } catch {
                fetchFailed = true
            }
        }

        let armedCount = await publishAndArm(items: mapped, fetchFailed: fetchFailed, now: start)
        emit("external_scan", outcome: fetchFailed ? "failure" : "success",
             metadata: ["mapped": "\(mapped.count)", "armed": "\(armedCount)"])
    }

    /// Submits the hourly background-refresh request (called from
    /// `.background` scene phase and after every rescan so the chain
    /// stays alive).
    func submitBackgroundRefresh() {
        submitRefreshRequest()
    }

    // MARK: - Native store-change observation (import freshness)

    /// Arms the `.EKEventStoreChanged` observer — edits the family
    /// makes in the native Calendar/Reminders apps (and the app's own
    /// calendar writes, mirror events excluded by tag/calendar) refresh
    /// the import immediately instead of waiting for the next
    /// foreground or BGTask beat. Idempotent; `disable()` removes it.
    /// Never a write path — rescans only read, so there is no
    /// self-triggering loop.
    func startObservingNativeChanges() {
        guard storeChangeObserver == nil else { return }
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.isScanning else { return }
            self.isScanning = true
            Task { [weak self] in
                guard let self else { return }
                await self.rescan()
                await MainActor.run { self.isScanning = false }
            }
        }
    }

    func stopObservingNativeChanges() {
        guard let storeChangeObserver else { return }
        NotificationCenter.default.removeObserver(storeChangeObserver)
        self.storeChangeObserver = nil
    }

    /// The actual BGAppRefresh submission. Errors are swallowed on
    /// purpose: `.tooManyPendingTaskRequests` (a refresh is already
    /// queued), unsupported contexts, etc. — a refused refresh is never
    /// a feature failure, just a quieter schedule.
    static func submitBackgroundRefreshRequest() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: backgroundRefreshMinimumLead)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Swallowed — see above.
        }
    }

    // MARK: - Read surfaces

    /// Today's mapped items (by their start day), oldest first — the
    /// external half of the merged today lists (Reminders leaf, Calendar
    /// leaf schedule section).
    func todaysItems() -> [ExternalReminder] {
        reminders
            .filter { Calendar.current.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Today's items as ready-to-speak summary lines for the routine
    /// plugin's `routine.query` answer — one spoken list spanning all
    /// three reminder systems. Timed items whose moment already passed
    /// are left out (their reminder has gone by); all-day items stay
    /// relevant all day.
    func todaysSpokenLines(locale: Locale) -> [String] {
        let currentTime = now()
        return todaysItems()
            .filter { $0.isAllDay || $0.startDate > currentTime }
            .map { item in
                if item.isAllDay { return item.title }
                let time = item.startDate.formatted(
                    Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
                return "\(item.title) — \(time)"
            }
    }

    // MARK: - Opening (read-only integration)

    /// Tap on an external row: best-effort deep link into the item's
    /// native app. There is no public per-item API — opening the app
    /// (Calendar for events, Reminders for reminders) is the whole
    /// gesture, gated on `canOpenURL`.
    func open(_ item: ExternalReminder) {
        guard let url = Self.nativeAppURL(for: item.source) else { return }
        guard opener.canOpen(url) else {
            emit("external_open_unavailable", outcome: "failure",
                 metadata: ["source": item.source.rawValue])
            return
        }
        opener.open(url)
        emit("external_item_opened", outcome: "success",
             metadata: ["source": item.source.rawValue])
    }

    static func nativeAppURL(for source: ExternalReminder.Source) -> URL? {
        switch source {
        case .event: return URL(string: "calshow://")
        case .reminder: return URL(string: "x-apple-reminderkit://show")
        }
    }

    // MARK: - Mapping rules (pure — unit-tested)

    /// Stable identity: full SHA-256 (hex) of `source|nativeId|start`
    /// — deterministic across rescans and launches, unique per native
    /// item (a moved event gets a new key and therefore a fresh
    /// notification rather than a stale re-fire).
    static func stableKey(source: ExternalReminder.Source,
                          nativeIdentifier: String, startDate: Date) -> String {
        let payload = "\(source.rawValue)|\(nativeIdentifier)|\(Int(startDate.timeIntervalSince1970))"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// When an item's in-app notification should fire, or nil when it
    /// should surface without one:
    /// - items that already carry their own native alarm → nil (the OS
    ///   already covers them; an in-app twin would double-notify);
    /// - timed items → start − lead (nil once that instant has passed);
    /// - all-day items → 08:00 on their day (nil once past).
    static func fireDate(for item: ExternalReminder, leadMinutes: Int,
                         now: Date, calendar: Calendar = .current) -> Date? {
        guard !item.hasOwnAlarm else { return nil }
        if item.isAllDay {
            guard let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                                              of: item.startDate),
                  morning > now else { return nil }
            return morning
        }
        let fire = item.startDate.addingTimeInterval(-TimeInterval(leadMinutes) * 60)
        return fire > now ? fire : nil
    }

    static func mapEvents(_ scanned: [ScannedEvent], now: Date) -> [ExternalReminder] {
        scanned.compactMap { event in
            // A declined invitation is not a commitment.
            guard !event.isDeclined else { return nil }
            // Our own mirrored routine events (notes carry the mirror
            // tag) are already fired by the in-app routine scheduler —
            // importing them would double-notify.
            guard event.notes?.contains(CalendarSyncService.mirrorTag) != true else { return nil }
            // Skip timed events already under way. All-day events are
            // exempt: an all-day event is "today", not "already
            // started" — midnight has passed but the day hasn't.
            guard event.isAllDay || event.startDate > now else { return nil }
            return ExternalReminder(
                id: stableKey(source: .event, nativeIdentifier: event.nativeIdentifier,
                              startDate: event.startDate),
                source: .event,
                title: event.title,
                notes: event.notes,
                startDate: event.startDate,
                isAllDay: event.isAllDay,
                hasOwnAlarm: event.hasAlarms,
                calendarName: event.calendarName
            )
        }
    }

    static func mapReminders(_ scanned: [ScannedReminder], now: Date) -> [ExternalReminder] {
        scanned.compactMap { reminder in
            // Completed, dateless, or already-due reminders are not
            // reminders of anything still ahead.
            guard !reminder.isCompleted,
                  let dueDate = reminder.dueDate,
                  dueDate > now else { return nil }
            return ExternalReminder(
                id: stableKey(source: .reminder, nativeIdentifier: reminder.nativeIdentifier,
                              startDate: dueDate),
                source: .reminder,
                title: reminder.title,
                notes: reminder.notes,
                startDate: dueDate,
                isAllDay: reminder.isAllDay,
                hasOwnAlarm: reminder.hasAlarms,
                calendarName: reminder.calendarName
            )
        }
    }

    // MARK: - Private

    /// Drops scanned events from excluded native calendars before the
    /// mapper sees them (2026-09-07 two-way: the app's own Sahayak
    /// calendar). Events without a calendar identifier (legacy test
    /// doubles) pass through — exclusion is keyed on identity we have.
    private func importable(from scanned: [ScannedEvent]) -> [ScannedEvent] {
        guard !excludedCalendarIdentifiers.isEmpty else { return scanned }
        return scanned.filter { event in
            guard let calendarIdentifier = event.calendarIdentifier else { return true }
            return !excludedCalendarIdentifiers.contains(calendarIdentifier)
        }
    }

    /// Re-reads both stores' authorization truth, persists the honest
    /// derived status (enabled / partial / denied), and returns what is
    /// actually fetchable this pass. Runs on every scan so a Settings-
    /// level revocation surfaces within one pass (the plan's "status
    /// checks per scan" rule).
    private func refreshedAccessTruth() async -> (eventsGranted: Bool, remindersGranted: Bool) {
        let eventsGranted = scanner.eventAuthorizationGranted
        let remindersGranted = scanner.reminderAuthorizationGranted
        switch (eventsGranted, remindersGranted) {
        case (true, true): await setStatus(.enabled)
        case (false, false): await setStatus(.denied)
        default: await setStatus(.partial)
        }
        return (eventsGranted, remindersGranted)
    }

    private func updateStatus(eventsGranted: Bool, remindersGranted: Bool) async {
        switch (eventsGranted, remindersGranted) {
        case (true, true): await setStatus(.enabled)
        case (false, false): await setStatus(.denied)
        default: await setStatus(.partial)
        }
    }

    private func setStatus(_ value: ExternalAccessStatus) async {
        await MainActor.run { persistStatus(value) }
    }

    @MainActor
    private func persistStatus(_ value: ExternalAccessStatus) {
        UserDefaults.standard.set(value.rawValue, forKey: Self.statusDefaultsKey)
        status = value
    }

    /// Main-actor half of a scan pass: publishes the mapped list, then
    /// cancels the previous pass's arms (scoped to OUR identifiers) and
    /// re-arms the ≤48 nearest future fires. Returns the armed count.
    @MainActor
    private func publishAndArm(items: [ExternalReminder], fetchFailed: Bool,
                               now: Date) -> Int {
        reminders = items
        if fetchFailed {
            persistStatus(.error)
        }
        let stale = Array(armedIdentifiers)
        armedIdentifiers.removeAll()
        if !stale.isEmpty {
            alarmScheduler.cancelExternalReminders(identifiers: stale)
        }
        let candidates = items.compactMap { item -> (ExternalReminder, Date)? in
            guard let fire = Self.fireDate(for: item, leadMinutes: leadMinutes,
                                           now: now) else { return nil }
            return (item, fire)
        }
        .sorted { $0.1 < $1.1 }

        var armed = 0
        let title = L10n.str("externalReminders.notificationTitle", locale: locale)
        for (item, fire) in candidates.prefix(Self.maxArmedNotifications) {
            let identifier = ExternalNotificationIdentity.identifier(for: item.id)
            alarmScheduler.scheduleExternalReminder(identifier: identifier, title: title,
                                                    body: item.title, at: fire)
            armedIdentifiers.insert(identifier)
            armed += 1
        }
        return armed
    }

    private func emit(_ eventType: String, outcome: String, metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "external_calendar", eventType: eventType, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}

// MARK: - External item opening seam

/// URL-opening seam for the read-only tap integration — production uses
/// `UIApplication` (main-queued), tests fake it and assert the exact
/// URLs and decisions (the `CallLinkOpening` pattern).
protocol ExternalItemOpening {
    func canOpen(_ url: URL) -> Bool
    func open(_ url: URL)
}

/// Production opener. `canOpenURL` must run on the main thread.
struct SystemExternalItemOpener: ExternalItemOpening {
    func canOpen(_ url: URL) -> Bool {
        if Thread.isMainThread { return UIApplication.shared.canOpenURL(url) }
        return DispatchQueue.main.sync { UIApplication.shared.canOpenURL(url) }
    }

    func open(_ url: URL) {
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }
}
