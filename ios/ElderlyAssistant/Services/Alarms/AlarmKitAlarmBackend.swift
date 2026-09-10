import Foundation
import ActivityKit
import AlarmKit
import SwiftUI

// MARK: - AlarmManager seam

/// [ALARMKIT-ALARMS] (2026-09-10) Test seam over the parts of AlarmKit's
/// `AlarmManager` the alarm path uses. AlarmKit is not deterministically
/// testable (system alarms are real), so the backend speaks to
/// `AlarmManager` only through this protocol; tests inject a recording
/// fake (`AlarmKitAlarmBackendTests`).
///
/// API surface verified against the iOS 26.5 SDK swiftinterface
/// (AlarmKit.framework/Modules/AlarmKit.swiftmodule/
/// arm64e-apple-ios.swiftinterface) and Apple's documentation:
///  - https://developer.apple.com/documentation/AlarmKit
///  - WWDC25 session 230 "Wake up to the AlarmKit API"
///
/// AlarmKit requires NO special entitlement; it DOES require the
/// `NSAlarmKitUsageDescription` Info.plist key plus user authorization
/// (`requestAuthorization()`, `authorizationState`).
@available(iOS 26.0, *)
protocol AlarmKitManaging: AnyObject {
    var authorizationState: AlarmManager.AuthorizationState { get }
    func requestAuthorization() async throws -> AlarmManager.AuthorizationState
    /// Schedules (or replaces, same id) the system alarm. Returns nothing:
    /// `AlarmKit.Alarm` has no public memberwise initializer (SDK
    /// swiftinterface — Codable inits only), and the caller never needs
    /// the echoed alarm back.
    func schedule(id: AlarmKit.Alarm.ID,
                  configuration: AlarmManager.AlarmConfiguration<AlarmKitMetadata>) async throws
    func cancel(id: AlarmKit.Alarm.ID) throws
    /// Transitions the alarm into its countdown phase — the SYSTEM snooze:
    /// the alarm re-fires after its postAlert duration (WWDC25 230:
    /// "snoozing re-runs the post-alert countdown interval").
    func countdown(id: AlarmKit.Alarm.ID) throws
}

/// [ALARMKIT-ALARMS] (2026-09-10) Empty metadata type — AlarmKit's
/// `AlarmAttributes` is generic over `AlarmMetadata`, and even with no
/// custom data a concrete type must be supplied. This app renders NO
/// alarm widget today: the widget extension carries the countdown/alarm
/// Live Activity UI (WWDC25 230 — the extension is REQUIRED for the
/// countdown/paused presentations; the ALERT presentation this alarm path
/// uses is presented by the system itself without one). The extension is
/// owned by the timers workstream. The type is nonisolated (the project's
/// Swift 5 mode defaults there) so the Codable/Hashable/Sendable
/// conformances hold.
@available(iOS 26.0, *)
struct AlarmKitMetadata: AlarmMetadata {}

/// Production `AlarmKitManaging` — a thin adapter over
/// `AlarmManager.shared`.
@available(iOS 26.0, *)
final class ProductionAlarmManagerAdapter: AlarmKitManaging {

    var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        try await AlarmManager.shared.requestAuthorization()
    }

    func schedule(id: AlarmKit.Alarm.ID,
                  configuration: AlarmManager.AlarmConfiguration<AlarmKitMetadata>) async throws {
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    func cancel(id: AlarmKit.Alarm.ID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    func countdown(id: AlarmKit.Alarm.ID) throws {
        try AlarmManager.shared.countdown(id: id)
    }
}

// MARK: - AlarmKit backend (iOS 26+)

/// [ALARMKIT-ALARMS] (2026-09-10) The iOS 26+ alarm backend — REAL system
/// alarms via AlarmKit.
///
/// Behavior notes (WWDC25 230 + the SDK swiftinterface):
///  - TIME-OF-DAY: `Alarm.Schedule.relative` with a `Relative.Time`
///    (hour/minute) and a weekly weekday recurrence — all seven weekdays
///    is the daily repeat this app's alarms are (AlarmKit's only
///    granularity for time-of-day alarms is weekly weekday sets; it
///    adjusts for timezone changes).
///  - SNOOZE/DISMISS: when the alarm fires, the SYSTEM presents the alert
///    with Stop (and, as configured here, a Snooze button with
///    `.countdown` behavior — "snoozing re-runs the post-alert countdown
///    interval"). The app receives no event for a system-UI dismissal —
///    the daily alarm persists (it is a recurring alarm, not one-shot),
///    so the app's own list stays the source of truth. A VOICE snooze of
///    the DEFAULT length hands off to `AlarmManager.countdown(id:)` (the
///    system re-fires after the alarm's postAlert); the system duration
///    is FIXED per alarm, so arbitrary-minute snoozes fall back to the
///    app's one-shot notification (see `snoozeViaSystem`).
///  - CAPACITY: the app's own 20-alarm cap (`AlarmTimersStore.maxAlarms`)
///    still gates first; if the system refuses anyway
///    (`AlarmManager.AlarmError.maximumLimitReached` — the only public
///    AlarmKit error, and Apple documents no concrete cap), the alarm is
///    armed as the UN daily notification instead so it still rings, and
///    `scheduleAll()` retries the system arm on the next launch.
final class AlarmKitAlarmBackend: AlarmSchedulingBackend {

    let kind: AlarmBackendKind = .alarmKit

    /// The system alarm's snooze duration (postAlert minutes) — fixed by
    /// the alarm configuration and matched to the parser's DEFAULT snooze
    /// (`AlarmTimerCommandParser.defaultSnoozeMinutes`) so a bare voice
    /// "snooze" hands off to the system countdown transition. The system
    /// API cannot honor arbitrary minutes.
    let systemSnoozeMinutes: Int

    var locale: Locale

    private let manager: AlarmKitManaging
    private let notifications: LocalNotificationScheduling
    /// Outstanding system-arm tasks — awaited by tests
    /// (`waitForPendingArms`) to make the fire-and-forget schedule
    /// deterministic; capped defensively in production.
    private var pendingArms: [Task<Void, Never>] = []
    private static let maxPendingArms = 64

    init(manager: AlarmKitManaging = ProductionAlarmManagerAdapter(),
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
        Self.map(manager.authorizationState)
    }

    /// `AlarmManager.AuthorizationState` → the seam's neutral status.
    /// Tested directly — the seam stays AlarmKit-free.
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
        switch manager.authorizationState {
        case .authorized:
            granted = true
        case .notDetermined:
            let resolved = (try? await manager.requestAuthorization()) ?? .denied
            granted = resolved == .authorized
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
    /// `AlarmManager.schedule` is async, so the arm runs fire-and-forget
    /// on a task the backend retains; failures fall back to the UN daily
    /// notification so the alarm still rings.
    func scheduleAlarm(_ alarm: Alarm) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let schedule = AlarmKit.Alarm.Schedule.relative(
            .init(time: .init(hour: components.hour ?? 0,
                              minute: components.minute ?? 0),
                  repeats: .weekly(Self.dailyWeekdays))
        )

        // The system renders the title (our app name alongside it) and
        // the Snooze button; a LocalizedStringResource literal carries
        // our pre-localized text with no catalog lookup in the system
        // process (L10n.str resolved it for the app language already).
        let title = LocalizedStringResource(
            stringLiteral: L10n.str("alarms.notification.title", locale: locale))
        let snoozeButton = AlarmKit.AlarmButton(
            text: LocalizedStringResource(
                stringLiteral: L10n.str("alarmAlarmKit.snoozeButton", locale: locale)),
            textColor: DesignTokens.accent,
            systemImageName: "zzz"
        )
        let attributes = AlarmKit.AlarmAttributes<AlarmKitMetadata>(
            presentation: .init(alert: Self.makeAlertPresentation(
                title: title, snoozeButton: snoozeButton
            )),
            metadata: AlarmKitMetadata(),
            tintColor: DesignTokens.accent
        )
        let configuration = AlarmKit.AlarmManager.AlarmConfiguration<AlarmKitMetadata>(
            countdownDuration: .init(preAlert: nil,
                                     postAlert: TimeInterval(systemSnoozeMinutes * 60)),
            schedule: schedule,
            attributes: attributes,
            sound: .default
        )

        let task = Task { [manager] in
            do {
                try await manager.schedule(id: alarm.id, configuration: configuration)
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
            try manager.cancel(id: id)
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
            try manager.countdown(id: id)
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

    /// All seven weekdays = DAILY (AlarmKit's only recurrence granularity
    /// for time-of-day alarms — SDK swiftinterface,
    /// `Alarm.Schedule.Relative.Recurrence.weekly([Locale.Weekday])`).
    private static let dailyWeekdays: [Locale.Weekday] = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
    ]
}
