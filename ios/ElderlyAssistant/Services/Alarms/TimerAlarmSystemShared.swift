import Foundation
import AlarmKit

/// [TIMER-ALARM] (2026-09-10) Types shared between the app target and the
/// TimerAlarmWidget extension. Both targets compile THIS file, so the
/// `AlarmAttributes<TimerAlarmSystemMetadata>` generic instantiation has
/// the same metadata type NAME in both modules — ActivityKit matches a
/// scheduled activity to the widget extension that declares an
/// `ActivityConfiguration` for the same attributes type by name, exactly
/// like ordinary Live Activities (Apple docs: declare the ActivityAttributes
/// type in both the app and the widget extension).
///
/// AlarmKit reference (Apple, WWDC25 session "Bring alarms and timers to
/// your app with AlarmKit"):
///  - `AlarmManager.schedule(id:configuration:)` with
///    `.timer(duration:attributes:...)` creates a SYSTEM-managed timer:
///    it rings through silent mode and Focus, presents the full-screen
///    alert on the Lock Screen (like the Clock app), shows a countdown in
///    the Dynamic Island/StandBy/Apple Watch, and fires even when the app
///    is TERMINATED. No special entitlement — only the
///    NSAlarmKitUsageDescription Info.plist key and user authorization.
///  - The widget extension hosting `ActivityConfiguration(for:
///    AlarmAttributes<...>.self)` is required for the system to present
///    the timer (the countdown UI and the alert's Stop affordance).
///  - `AlarmManager.requestAuthorization()` / `authorizationState` is an
///    authorization SEPARATE from notification permission; both are asked
///    at point of use (first timer creation).

/// The AlarmKit alarm's metadata payload. Empty in v1: the alarm carries
/// no app-specific data beyond its id (the AlarmKit alarm id IS the
/// persisted `TimerItem.id`). Codable + Hashable + Sendable as the
/// `AlarmMetadata` protocol requires; an empty struct stays stable if the
/// payload grows later (add fields, keep decoding defaults).
@available(iOS 26.0, *)
struct TimerAlarmSystemMetadata: AlarmMetadata, Codable, Hashable, Sendable {
}

/// Bundle identifier of the widget extension that hosts the AlarmKit
/// alarm presentation (declared in project.yml).
enum TimerAlarmSystemShared {
    static let widgetExtensionBundleID = "com.elderlyassistant.app.TimerAlarmWidget"
}
