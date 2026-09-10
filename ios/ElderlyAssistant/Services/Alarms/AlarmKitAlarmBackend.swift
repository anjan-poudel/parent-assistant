import Foundation
import ActivityKit
import AlarmKit
import SwiftUI

// MARK: - System alarm manager seam (neutral — no AlarmKit types)

/// [ALARMKIT-ALARMS] (2026-09-11) The seam over the system alarm manager,
/// deliberately FREE of AlarmKit types: every type in the signatures below
/// is neutral (`AlarmAuthorizationStatus`, UUID, String, Int). The
/// production implementation (`ProductionSystemAlarmManager`, iOS 26+)
/// bridges to AlarmKit's `AlarmManager`; tests inject a recording fake
/// (`AlarmKitAlarmBackendTests`) that never touches AlarmKit.
///
/// WHY NEUTRAL: a test-bundle type that CONFORMS to an iOS-26-only
/// protocol or stores an iOS-26-only type crashes the test runner on
/// older runtimes at TYPE METADATA COMPLETION — the completion function
/// resolves the unavailable symbols even though `@available` defers the
/// type's own use (integration failure reproduced on an iOS 18.3
/// simulator: "test runner crashed ... at type metadata completion
/// function for FakeAlarmKitManager"). Keeping the fake's protocol
/// neutral means the test bundle contains NO AlarmKit symbol at all, so
/// nothing can crash pre-26 — while the seam/selection tests still run
/// everywhere.
protocol SystemAlarmManaging: AnyObject {
    /// AlarmKit authorization mapped to the seam's neutral status.
    var alarmAuthorizationStatus: AlarmAuthorizationStatus { get }
    /// Requests AlarmKit authorization; returns the resolved status
    /// (a previous denial must never re-prompt — the caller checks
    /// `alarmAuthorizationStatus` first).
    func requestSystemAlarmAuthorization() async -> AlarmAuthorizationStatus
    /// Schedules (or replaces, same id) a system time-of-day alarm that
    /// repeats DAILY at hour/minute, with a `snoozeMinutes` postAlert
    /// countdown and the pre-localized `title`/`snoozeLabel` (the
    /// configuration is built inside the production adapter — AlarmKit's
    /// `AlarmConfiguration` exposes no stored properties, so nothing is
    /// lost to the seam).
    func scheduleSystemAlarm(id: UUID, hour: Int, minute: Int,
                             snoozeMinutes: Int,
                             title: String, snoozeLabel: String) async throws
    func cancelSystemAlarm(id: UUID) throws
    /// The SYSTEM snooze: transitions the alarm into its countdown phase
    /// (re-fires after the postAlert interval).
    func countdownSystemAlarm(id: UUID) throws
}

// MARK: - Production adapter (iOS 26+)

/// [ALARMKIT-ALARMS] (2026-09-10) Empty metadata type — AlarmKit's
/// `AlarmAttributes` is generic over `AlarmMetadata`, and even with no
/// custom data a concrete type must be supplied. Referenced ONLY inside
/// iOS-26-gated code (the adapter below). The type is nonisolated (the
/// project's Swift 5 mode defaults there) so the Codable/Hashable/
/// Sendable conformances hold.
@available(iOS 26.0, *)
struct AlarmKitMetadata: AlarmMetadata {}

/// Production `SystemAlarmManaging` — a thin adapter over
/// `AlarmManager.shared`. ALL AlarmKit references in the app live in this
/// iOS-26-gated file; nothing outside it touches AlarmKit.
///
/// API surface verified against the iOS 26.5 SDK swiftinterface
/// (AlarmKit.framework/Modules/AlarmKit.swiftmodule/
/// arm64e-apple-ios.swiftinterface) and Apple's documentation:
///  - https://developer.apple.com/documentation/AlarmKit
///  - WWDC25 session 230 "Wake up to the AlarmKit API"
@available(iOS 26.0, *)
final class ProductionSystemAlarmManager: SystemAlarmManaging {

    var alarmAuthorizationStatus: AlarmAuthorizationStatus {
        AlarmKitAlarmBackend.map(AlarmManager.shared.authorizationState)
    }

    func requestSystemAlarmAuthorization() async -> AlarmAuthorizationStatus {
        let resolved = (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
        return AlarmKitAlarmBackend.map(resolved)
    }

    func scheduleSystemAlarm(id: UUID, hour: Int, minute: Int,
                             snoozeMinutes: Int,
                             title: String, snoozeLabel: String) async throws {
        // Time-of-day with a weekly all-seven-days recurrence = the daily
        // repeat this app's alarms are (AlarmKit's only granularity for
        // time-of-day alarms is weekly weekday sets — SDK swiftinterface;
        // relative schedules adjust for timezone changes).
        let schedule = AlarmKit.Alarm.Schedule.relative(
            .init(time: .init(hour: hour, minute: minute),
                  repeats: .weekly(Self.dailyWeekdays))
        )

        // LocalizedStringResource literals carry the pre-localized text
        // with no catalog lookup in the system process (L10n.str already
        // resolved them for the app language).
        let snoozeButton = AlarmKit.AlarmButton(
            text: LocalizedStringResource(stringLiteral: snoozeLabel),
            textColor: DesignTokens.accent,
            systemImageName: "zzz"
        )
        let attributes = AlarmKit.AlarmAttributes<AlarmKitMetadata>(
            presentation: .init(alert: Self.makeAlertPresentation(
                title: LocalizedStringResource(stringLiteral: title),
                snoozeButton: snoozeButton
            )),
            metadata: AlarmKitMetadata(),
            tintColor: DesignTokens.accent
        )
        let configuration = AlarmKit.AlarmManager.AlarmConfiguration<AlarmKitMetadata>(
            countdownDuration: .init(preAlert: nil,
                                     postAlert: TimeInterval(snoozeMinutes * 60)),
            schedule: schedule,
            attributes: attributes,
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    func cancelSystemAlarm(id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    func countdownSystemAlarm(id: UUID) throws {
        try AlarmManager.shared.countdown(id: id)
    }

    /// The system alert presentation. On iOS 26.1+ the Stop button is
    /// implicit (the system always offers Stop — WWDC25 230); the
    /// 26.0-only initializer still requires the (deprecated) stopButton,
    /// so 26.0.x devices build the alert the legacy way.
    private static func makeAlertPresentation(
        title: LocalizedStringResource,
        snoozeButton: AlarmKit.AlarmButton
    ) -> AlarmKit.AlarmPresentation.Alert {
        if #available(iOS 26.1, *) {
            return AlarmKit.AlarmPresentation.Alert(
                title: title,
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: .countdown
            )
        } else {
            // Deprecated-in-26.1 initializer kept for 26.0.x devices; the
            // stopButton property is ignored by the system on 26.1+.
            return AlarmKit.AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmKit.AlarmButton(
                    text: LocalizedStringResource(stringLiteral: "Stop"),
                    textColor: .white,
                    systemImageName: "xmark"
                ),
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: .countdown
            )
        }
    }

    private static let dailyWeekdays: [Locale.Weekday] = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
    ]
}

// MARK: - AlarmKit backend (iOS 26+)

/// [ALARMKIT-ALARMS] (2026-09-10) The iOS 26+ alarm backend — REAL system
/// alarms via AlarmKit.
///
/// Behavior notes (WWDC25 230 + the SDK swiftinterface):
///  - TIME-OF-DAY: daily repeat at the alarm's hour/minute (see the
///    adapter).
///  - SNOOZE/DISMISS: when the alarm fires, the SYSTEM presents the alert
///    with Stop (and, as configured here, a Snooze button with
///    `.countdown` behavior — "snoozing re-runs the post-alert countdown
///    interval"). The app receives no event for a system-UI dismissal —
///    the daily alarm persists (it is a recurring alarm, not one-shot),
///    so the app's own list stays the source of truth. A VOICE snooze of
///    the DEFAULT length hands off to the system's countdown transition
///    (the system re-fires after the alarm's postAlert); the system
///    duration is FIXED per alarm, so arbitrary-minute snoozes fall back
///    to the app's one-shot notification (see `snoozeViaSystem`).
///  - CAPACITY: the app's own 20-alarm cap (`AlarmTimersStore.maxAlarms`)
///    still gates first; if the system refuses anyway
///    (`AlarmManager.AlarmError.maximumLimitReached` — the only public
///    AlarmKit error, and Apple documents no concrete cap), the alarm is
///    armed as the UN daily notification instead so it still rings, and
///    `scheduleAll()` retries the system arm on the next launch.
@available(iOS 26.0, *)
final class AlarmKitAlarmBackend: AlarmSchedulingBackend {

    let kind: AlarmBackendKind = .alarmKit

    /// The system alarm's snooze duration (postAlert minutes) — fixed by
    /// the alarm configuration and matched to the parser's DEFAULT snooze
    /// (`AlarmTimerCommandParser.defaultSnoozeMinutes`) so a bare voice
    /// "snooze" hands off to the system countdown transition. The system
    /// API cannot honor arbitrary minutes.
    let systemSnoozeMinutes: Int

    var locale: Locale

    private let manager: SystemAlarmManaging
    private let notifications: LocalNotificationScheduling
    /// Outstanding system-arm tasks — awaited by tests
    /// (`waitForPendingArms`) to make the fire-and-forget schedule
    /// deterministic; capped defensively in production.
    private var pendingArms: [Task<Void, Never>] = []
    private static let maxPendingArms = 64

    init(manager: SystemAlarmManaging,
         notifications: LocalNotificationScheduling,
         locale: Locale = Locale(identifier: "en"),
         systemSnoozeMinutes: Int = AlarmTimerCommandParser.defaultSnoozeMinutes) {
        self.manager = manager
        self.notifications = notifications
        self.locale = locale
        self.systemSnoozeMinutes = systemSnoozeMinutes
    }

    // MARK: Authorization

    var authorizationStatus: AlarmAuthorizationStatus {
        manager.alarmAuthorizationStatus
    }

    /// `AlarmManager.AuthorizationState` → the seam's neutral status.
    /// Lives here (26-gated) because only the app target may touch the
    /// AlarmKit enum; tested in `AlarmKitAuthorizationStateMappingTests`
    /// on iOS 26 runtimes.
    static func map(_ state: AlarmManager.AuthorizationState) -> AlarmAuthorizationStatus {
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        }
    }

    /// Point-of-use ask. GATE: AlarmKit authorization — without it an
    /// alarm can never ring as a system alarm, so the caller stores
    /// nothing and speaks the honest `alarmAlarmKit.permissionDenied`
    /// line (WWDC25 230: on denial "make it visually clear in your app
    /// that nothing will be scheduled"). UN permission is still requested
    /// best-effort in the same pass — the arbitrary-minute snooze
    /// fallback and the other notification features ring through it — but
    /// a UN denial NEVER gates a system alarm.
    func requestAuthorizationIfNeeded() async -> Bool {
        var granted = false
        switch manager.alarmAuthorizationStatus {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await manager.requestSystemAlarmAuthorization() == .authorized
        case .denied:
            granted = false
        }
        if !granted {
            print("[AlarmKitAlarmBackend] AlarmKit authorization denied — alarms cannot ring as system alarms.")
        }
        _ = await notifications.requestAuthorization()
        return granted
    }

    // MARK: Arming

    /// Arms (or replaces — the system keys alarms by id) the SYSTEM
    /// time-of-day alarm. Synchronous to the caller like the UN path:
    /// the system schedule is async, so the arm runs fire-and-forget on
    /// a task the backend retains; failures fall back to the UN daily
    /// notification so the alarm still rings.
    func scheduleAlarm(_ alarm: Alarm) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let snoozeMinutes = systemSnoozeMinutes
        let title = L10n.str("alarms.notification.title", locale: locale)
        let snoozeLabel = L10n.str("alarmAlarmKit.snoozeButton", locale: locale)

        let task = Task { [manager] in
            do {
                try await manager.scheduleSystemAlarm(
                    id: alarm.id, hour: hour, minute: minute,
                    snoozeMinutes: snoozeMinutes,
                    title: title, snoozeLabel: snoozeLabel
                )
            } catch {
                print("[AlarmKitAlarmBackend] System refused alarm \(alarm.id) (\(error)) — arming the UN fallback.")
                self.armUNFallback(for: alarm)
            }
        }
        pendingArms.append(task)
        if pendingArms.count > Self.maxPendingArms {
            pendingArms.removeFirst(pendingArms.count - Self.maxPendingArms)
        }
    }

    /// Awaits the outstanding system-arm tasks. Tests use this to make
    /// the fire-and-forget schedule deterministic; a no-op in production.
    func waitForPendingArms() async {
        let tasks = pendingArms
        pendingArms.removeAll()
        for task in tasks {
            await task.value
        }
    }

    func cancelAlarm(id: UUID) {
        do {
            try manager.cancelSystemAlarm(id: id)
        } catch {
            print("[AlarmKitAlarmBackend] Failed to cancel alarm \(id): \(error)")
        }
    }

    // MARK: Snooze

    /// The app's own one-shot re-wake notification — arbitrary-minute
    /// voice snoozes (the system duration is fixed). Identical UN shape
    /// to the pre-26 path.
    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval) {
        notifications.add(
            UNAlarmRequestFactory.snoozeRequest(for: alarm, timeInterval: timeInterval, locale: locale)
        ) { error in
            if let error {
                print("[AlarmKitAlarmBackend] Failed to arm snooze for alarm \(alarm.id): \(error)")
            }
        }
    }

    /// Nothing to cancel system-side: the system snooze is a countdown
    /// PHASE of the alarm itself, and `cancelAlarm` removes the alarm
    /// (its countdown dies with it).
    func cancelSnooze(id: UUID) {}

    /// Voice snooze → the system alarm's countdown transition, ONLY for
    /// the default duration (the postAlert the alarm was configured
    /// with). Anything else — or a system failure (the alarm may already
    /// be dismissed) — returns false and the caller arms the app's
    /// one-shot notification instead.
    func snoozeViaSystem(id: UUID, minutes: Int) -> Bool {
        guard minutes == systemSnoozeMinutes else { return false }
        do {
            try manager.countdownSystemAlarm(id: id)
            return true
        } catch {
            print("[AlarmKitAlarmBackend] System snooze failed for \(id): \(error) — falling back to the one-shot.")
            return false
        }
    }

    // MARK: - Private helpers

    /// Daily-repeating UN notification under the SAME identifier as the
    /// UN path — the pre-26 fallback shape, so a system refusal degrades
    /// to exactly what a pre-26 device does.
    private func armUNFallback(for alarm: Alarm) {
        notifications.add(
            UNAlarmRequestFactory.dailyRepeatRequest(for: alarm, locale: locale)
        ) { error in
            if let error {
                print("[AlarmKitAlarmBackend] UN fallback arm failed for \(alarm.id): \(error)")
            }
        }
    }
}
