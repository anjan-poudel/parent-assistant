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

// MARK: - App Intents `.clock` schema — investigated, NOT adoptable yet
//
// iOS 26's new App Intents schema domains (Apple, WWDC25 "Adopt App
// Intents for Apple Intelligence" — domains incl. `.clock` with
// createTimer/createAlarm/…, where Siri/Apple Intelligence routes clock
// commands to the app that adopts the domain) are NOT present in the SDK
// this codebase builds against. Verified 2026-09-10 against the installed
// toolchain (Xcode 26.6, iPhoneOS26.5 SDK): no `Clock*` intent or schema
// type exists in any shipped framework's public swiftinterface
// (AppIntents, ClockKit, WidgetKit, AlarmKit all searched). The
// `AssistantSchemas.Intent` MARKER protocol exists (iOS 16+), but the
// clock domain's concrete schema types ship in a later SDK.
//
// Constraint for the future adoption: the clock domain is ALL-OR-NOTHING
// per app — adopting any clock schema (e.g. timers) requires adopting
// every one (alarms, stopwatch, …), which also means those intents must
// exist in the app. When the SDK with the schema ships: add the domain's
// intent conformances for ALL clock actions or none; a timers-only
// adoption is rejected. Nothing to do in this codebase today.

