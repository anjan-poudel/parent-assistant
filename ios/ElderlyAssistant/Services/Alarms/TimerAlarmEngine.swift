import Foundation
import Combine
import UserNotifications

// MARK: - Audio seam

/// [TIMER-ALARM] Playback seam for the looping timer-alarm bell — the
/// fakeable boundary that keeps the engine's state machine testable with a
/// recording fake instead of real audio. Production implementation:
/// `TimerAlarmBellPlayer` (AVAudioPlayer, `numberOfLoops = -1`).
protocol TimerAlarmAudioPlaying: AnyObject {
    /// Starts the alarm bell, looping until `stop()`. Must be safe to call
    /// repeatedly (the engine guarantees one call per transition anyway).
    func startLooping()
    /// Stops the bell immediately.
    func stop()
}

// MARK: - Notification payload parser

/// [TIMER-ALARM] Parses the userInfo payload of the app's own alarm/timer
/// notifications (`"kind"` + `"id"`, written by `AlarmScheduler`).
/// `UNNotification` has no public initializer, so the facade handler
/// extracts the raw payload through this seam — the notification-response
/// routing is unit-testable without constructing real notifications.
enum TimerAlarmNotificationPayload {
    static let timerKind = "timer"

    /// The timer id of a timer-completion notification, nil for anything
    /// else (daily alarm notifications, medication/other notifications
    /// with no "kind", junk payloads).
    static func timerID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard userInfo["kind"] as? String == timerKind,
              let idString = userInfo["id"] as? String else { return nil }
        return UUID(uuidString: idString)
    }
}

// MARK: - TimerAlarmEngine

/// [TIMER-ALARM] Pure state machine for the in-app timer alarm — the
/// foreground ringing experience the UN-notification-only timer never had:
///
///   idle --elapsed (tick) or notification response--> ringing --STOP--> idle
///
/// Rules:
///  - `tick(activeTimers:)` is the foreground driver (a ~0.5 s main-runloop
///    timer plus a call on scene-phase `.active`). It adopts the UN-path
///    active-timer snapshot and fires the EARLIEST elapsed timer. While
///    ringing it does nothing — the bell keeps looping.
///  - After STOP, the next tick re-evaluates: a second timer that elapsed
///    meanwhile rings next (never two overlapping bells).
///  - The bell loops INDEFINITELY — deliberately no auto-timeout. The
///    single STOP button is the only way the alarm ends, which is the
///    whole point of a timer (honest by design; see the class doc note).
///  - The engine is MAIN-CONFINED: `@Published phase` drives the
///    full-screen overlay, and every mutator runs on main. The facade
///    handler methods below hop to main themselves.
///
/// Scope honesty: this engine rings for UN-path timers only — the
/// pre-iOS-26 and AlarmKit-denied fallback. On iOS 26 with AlarmKit
/// authorized the timer is SYSTEM-managed (AlarmManager): the system
/// presents its own full-screen alarm (louder than any in-app audio, rings
/// through silent mode and Focus, fires even when the app is terminated),
/// and the coordinator feeds this engine an empty snapshot so the two
/// never double-ring.
final class TimerAlarmEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case ringing(TimerItem)
    }

    @Published private(set) var phase: Phase = .idle

    /// Fired exactly once per transition into `.ringing`, BEFORE the
    /// bell starts — the coordinator cancels the timer's pending UN
    /// notification and any in-flight spoken output, so the OS one-shot
    /// sound and the looping bell never double up.
    var onRingStarted: ((UUID) -> Void)?

    private let audio: TimerAlarmAudioPlaying
    private let now: () -> Date
    private let observabilityBus: ObservabilityBus
    /// Snapshot of the timers this engine may ring for (the UN-path
    /// active timers), adopted on every `tick`.
    private var activeTimers: [TimerItem] = []
    /// [TIMER-ALARM] Tap-path lookup: resolves a timer by id even when it
    /// has LEFT the active snapshot — a timer that ended while the app
    /// was backgrounded is past its deadline (so `tick` ignores it), yet
    /// its row is still live and the delivered notification's tap must
    /// open the ringing screen. Wired by the coordinator to the service.
    var timerLookup: ((UUID) -> TimerItem?)?

    init(audio: TimerAlarmAudioPlaying,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.audio = audio
        self.observabilityBus = observabilityBus
        self.now = now
    }

    // MARK: - Main-confined state machine

    /// Foreground driver call. Adopts the snapshot, then — only while
    /// idle — rings the earliest timer whose deadline has passed.
    func tick(activeTimers: [TimerItem]) {
        self.activeTimers = activeTimers
        guard phase == .idle else { return }
        guard let due = activeTimers
            .filter({ $0.endsAt <= now() })
            .min(by: { $0.endsAt < $1.endsAt }) else { return }
        startRinging(due, trigger: "foreground_elapsed")
    }

    /// Notification-response routing target: a tap on the timer's
    /// delivered notification opens the app INTO the ringing alarm
    /// screen. Returns true only when ringing actually started.
    ///
    /// Resolution order (both honest, no zombie alarms):
    ///  1. the active snapshot — the foreground case;
    ///  2. `timerLookup` — the background case: the timer ended while the
    ///     app was closed, so it left the snapshot (deadline passed) but
    ///     its row is still live within the prune grace window; only
    ///     rows whose deadline has actually passed ring (a future timer
    ///     can never have delivered a notification, so a future deadline
    ///     in a tap payload is stale and ignored).
    @discardableResult
    func ringTimer(id: UUID) -> Bool {
        guard phase == .idle else { return false }
        if let timer = activeTimers.first(where: { $0.id == id }) {
            startRinging(timer, trigger: "notification_response")
            return true
        }
        if let timer = timerLookup?(id),
           timer.endsAt <= now().addingTimeInterval(1) {  // 1 s skew grace
            startRinging(timer, trigger: "notification_response")
            return true
        }
        return false
    }

    /// The STOP button. Stops the bell, returns to idle, and hands back
    /// the finished timer's id so the coordinator can expire its row.
    /// No-op while idle.
    func stopRinging() -> UUID? {
        guard case .ringing(let timer) = phase else { return nil }
        audio.stop()
        phase = .idle
        emit("timer_alarm_stopped", outcome: "success", id: timer.id)
        return timer.id
    }

    private func startRinging(_ timer: TimerItem, trigger: String) {
        onRingStarted?(timer.id)
        phase = .ringing(timer)
        audio.startLooping()
        emit("timer_alarm_ringing", outcome: "success", id: timer.id,
             trigger: trigger)
    }

    // MARK: - Observability

    private func emit(_ eventType: String, outcome: String, id: UUID? = nil,
                      trigger: String? = nil) {
        var metadata: [String: String] = [:]
        if let id { metadata["id_hash"] = IdHashing.shortHash(of: id) }
        if let trigger { metadata["trigger"] = trigger }
        observabilityBus.emit(ObservabilityEvent(
            component: "timer_alarm",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}

// MARK: - NotificationFacade handler

extension TimerAlarmEngine: NotificationEventHandling {
    /// Claims every timer-completion notification so the notification
    /// reader never speaks over the bell, and routes the ring action to
    /// main. Thread-safe: only parses the payload here; all state lives
    /// on main. (On iOS 26 with AlarmKit authorized no timer notification
    /// is ever armed, so this path is the honest pre-26/denied fallback.)
    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        guard let id = TimerAlarmNotificationPayload.timerID(
            from: notification.request.content.userInfo) else { return false }
        DispatchQueue.main.async { [weak self] in self?.ringTimer(id: id) }
        return true
    }

    /// Notification response (the tap) — same routing: open into the
    /// ringing alarm screen. Forwarded to main before touching state.
    func didReceive(_ response: UNNotificationResponse) async {
        guard let id = TimerAlarmNotificationPayload.timerID(
            from: response.notification.request.content.userInfo) else { return }
        await MainActor.run { [weak self] in self?.ringTimer(id: id) }
    }
}
