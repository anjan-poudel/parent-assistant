import AVFoundation
import Combine
import Foundation

/// C06 — playback's failures (design L2 §3.3, §3.5). All of them render one
/// plain line inside the cover (`instruction.video.unavailable`) with the
/// Close control still available; no error code or technical detail ever
/// reaches the person (FR-RIE-020).
enum InstructionPlaybackFailure: Error, Equatable {
    /// Preflight said not playable.
    case unsupported
    /// AVPlayerItem failed.
    case playerFailed
    /// The system stopped playback (audio session/call).
    case interrupted
    /// The ready watchdog expired.
    case timedOut
}

/// C06 — the closed playback event vocabulary (design L2 §3.5, §6.4).
///
/// These five values are the only things that ever cross the playback seam.
/// There is no `NSError`, domain, code or path in this type: a failure is a
/// typed value, and the controller maps it to the one plain line and the one
/// `instruction_playback` event (design §6.2, §6.4).
enum InstructionPlaybackEvent: Equatable {
    /// Adapter only: the player was constructed and the file is playable.
    case preflightPassed
    /// Adapter: the AVPlayerItem reached `.readyToPlay`.
    case ready
    case failed(InstructionPlaybackFailure)
    /// Played to the end.
    case finished
    /// Controller only: the cover closed. The adapter never emits this.
    case closed
}

/// C06 — the controller's two timers (design L2 §9.1). These are values the
/// controller injects into its own deadline seam; no type in this file
/// creates a timer.
///
/// `preflightTimeoutSeconds` bounds a future asynchronous adapter before the
/// tap feels dead; the shipped adapter completes preflight synchronously.
/// `readyWatchdogSeconds` is the last-resort ceiling for a platform stall
/// with no signal at all (design §8.1). Neither value is user-configurable;
/// production constructs once from `.standard` and injects.
///
/// T-017 adds the controller's deadline seam below this declaration. The
/// controller is the only type in this file that schedules a deadline; the
/// AVKit adapter owns none (P-1).
struct InstructionPlaybackConfiguration: Equatable {
    let preflightTimeoutSeconds: TimeInterval
    let readyWatchdogSeconds: TimeInterval

    static let standard = InstructionPlaybackConfiguration(
        preflightTimeoutSeconds: 0.6,
        readyWatchdogSeconds: 10
    )
}

/// IF-19 — the playback boundary the cover and the controller use
/// (design L2 §2.6, §2.7, §3.5, §7.1).
///
/// The adapter behind this seam owns the platform player, preflight, ready
/// observation, failure observation and teardown. It owns no timers, no copy
/// and no policy about when playback may start: whoever holds
/// `renderablePlayer` decides when to call `play()`, and the adapter itself
/// never does (FR-RIE-018: no sound before an explicit user action).
@MainActor
protocol InstructionVideoPlaying: AnyObject {
    /// `nil` until a successful preflight inside `present`.
    var renderablePlayer: AVPlayer? { get }

    /// Preflight (the synchronous playability check), construct the player
    /// and item, register the observations, and emit `.preflightPassed` — or
    /// one `.failed` — before returning. The URL is callback-scoped to this
    /// call and is never stored by the adapter (design §7.4).
    func present(url: URL, onEvent: @escaping @MainActor (InstructionPlaybackEvent) -> Void)

    /// Pause first, then remove every observer, clear the item and release
    /// the player. Idempotent; no event is emitted after it returns.
    func dismiss()
}

// MARK: - Deadline seam (P-1)

/// A scheduled playback deadline (T-017; design L2 §2.6, §9.1, §9.4).
///
/// The controller owns both playback deadlines and the AVKit adapter owns
/// none. A deadline is a cancellable value so `close()` and every terminal
/// transition can guarantee "no timer remains scheduled"; the controller
/// suite drives both expiry paths with `ManualDeadline` instead of a
/// wall-clock sleep.
@MainActor
protocol InstructionPlaybackDeadline: AnyObject {
    /// Idempotent. A cancelled deadline never invokes its expiry closure.
    func cancel()
}

/// The injected deadline factory (T-017; design §9.4 item 2).
///
/// `schedule(after:onExpire:)` is the only way this feature starts a timer.
/// Production defaults to `SystemInstructionPlaybackDeadlineScheduler`
/// when the controller is built without one; tests inject a manual factory
/// and fire on demand, which keeps the two bounds deterministic.
@MainActor
protocol InstructionPlaybackDeadlineScheduling: AnyObject {
    /// Arms `onExpire` once, `seconds` from now, on the main actor, and
    /// returns the token that cancels it. The interval is the injected
    /// configuration value by name — never a literal at the call site.
    func schedule(after seconds: TimeInterval,
                  onExpire: @escaping @MainActor () -> Void) -> InstructionPlaybackDeadline
}

/// Production deadline factory: a cancellable main-actor suspension.
///
/// Deliberately not a run-loop timer: a structured task cancelled by its
/// token gives the controller exactly the contract it needs — expiry runs
/// once on the main actor and never after `cancel()` — with no run-loop
/// dependency and no extra state.
@MainActor
final class SystemInstructionPlaybackDeadlineScheduler: InstructionPlaybackDeadlineScheduling {

    /// Nonisolated so a composition root can build the production default
    /// in a plain initializer argument.
    nonisolated init() {}

    func schedule(after seconds: TimeInterval,
                  onExpire: @escaping @MainActor () -> Void) -> InstructionPlaybackDeadline {
        let task = Task { @MainActor in
            // Cancellation-aware suspension: a cancelled task wakes
            // immediately instead of holding the process for the bound.
            try? await ContinuousClock().sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            onExpire()
        }
        return ScheduledInstructionPlaybackDeadline(task: task)
    }
}

/// The concrete production token. Private: callers only need `cancel()`.
@MainActor
private final class ScheduledInstructionPlaybackDeadline: InstructionPlaybackDeadline {

    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - C06 — playback controller (IF-20)

/// C06 — the playback policy owner (IF-20; design L2 §2.6, §8.1, §9.1,
/// §11.3 I).
///
/// The controller is created only when the person taps Play: the
/// initializer stores values and constructs nothing, so no preflight, no
/// player, no timer and no event exist before `start()`. `start()` is the
/// single entry point that presents the adapter, and it is idempotent —
/// playback can never autoplay and never retries a failed session
/// (FR-RIE-018).
///
/// The controller owns both timers (P-1):
/// - a `preflightTimeoutSeconds` (0.6 s) bound: a preflight that never
///   answers becomes `.failed(.unsupported)` and the one plain line;
/// - a `readyWatchdogSeconds` (10 s) responsiveness ceiling armed only
///   after `.preflightPassed`: a ready that never arrives becomes
///   `.failed(.timedOut)`. The watchdog is not failure detection — the
///   adapter reports real failures immediately — so a slow ready inside the
///   window is never labelled failed early (design §8.1).
///
/// One terminal outcome yields at most one `instruction_playback` event:
/// `.ready`, `.failed` (carrying the §3.3 token) or `.closed` once a player
/// had been presented. `duration_ms` is an injected-`now()` delta from
/// `start()`. The URL is stored only until close and is never logged or
/// emitted (design §6.4, §7.4).
///
/// Deviation record (T-017): design §3.5 shows a `deadline:` async closure
/// parameter and a three-case `State`. The task's acceptance criteria
/// require an injected deadline *factory* (so both timers are cancellable
/// and testable with `ManualDeadline`) and a state that distinguishes the
/// idle/preflight/preparing/ready/finished/closed phases. Both are
/// implemented here; `.preparing` keeps the design's public name for the
/// preflight-passed phase, and `start`/`close`/`title`/`state`/`player`
/// keep the design's surface.
@MainActor
final class InstructionPlaybackController: ObservableObject {

    /// The playback phases the cover renders (design §2.6; T-017 state
    /// distinction). `idle` is the pre-tap phase; `preflighting` bounds the
    /// adapter's preflight; `preparing` is the preflight-passed phase
    /// waiting on `.ready`; `ready` is the phase whose player the cover
    /// shows; `.failed` carries the typed failure whose one plain line the
    /// cover resolves through `InstructionMessageKey.forPlayback`;
    /// `finished` keeps the last frame with Close available; `closed` is
    /// terminal and makes every late adapter event a no-op.
    enum State: Equatable {
        case idle
        case preflighting
        case preparing
        case ready
        case failed(InstructionPlaybackFailure)
        case finished
        case closed
    }

    /// The cover's title. The controller never renders it and never logs
    /// it; it is a value the cover owns.
    let title: String?

    @Published private(set) var state: State = .idle
    @Published private(set) var player: AVPlayer?

    private let adapter: InstructionVideoPlaying
    private let configuration: InstructionPlaybackConfiguration
    private let events: InstructionObservability
    private let deadlineFactory: InstructionPlaybackDeadlineScheduling
    private let now: () -> Date

    /// The playback handoff. It is needed only for `start()` and is dropped
    /// by every terminal transition, so a closed controller retains no
    /// path (design §7.4). The adapter never stores it.
    private var url: URL?
    private var startedAt: Date?
    private var preflightDeadline: InstructionPlaybackDeadline?
    private var readyDeadline: InstructionPlaybackDeadline?

    /// True once the adapter reported `.preflightPassed` — the seam's
    /// guarantee that a player was constructed for this session. It is the
    /// only reason `close()` may emit the `.closed` outcome.
    private var didPresentPlayer = false

    init(url: URL,
         title: String?,
         player: InstructionVideoPlaying,
         configuration: InstructionPlaybackConfiguration,
         events: InstructionObservability,
         deadlineFactory: InstructionPlaybackDeadlineScheduling? = nil,
         now: @escaping () -> Date = Date.init) {
        self.url = url
        self.title = title
        self.adapter = player
        self.configuration = configuration
        self.events = events
        self.deadlineFactory = deadlineFactory ?? SystemInstructionPlaybackDeadlineScheduler()
        self.now = now
    }

    // MARK: - IF-20

    /// Presents the video player once. The person's tap is the only caller;
    /// the initializer did nothing, so there is no autoplay path
    /// (FR-RIE-018). A second call in any phase is a no-op: no re-present,
    /// no retry, no second deadline.
    func start() {
        guard state == .idle, let url else { return }
        startedAt = now()
        state = .preflighting
        // Arm before present: the shipped adapter reports preflight
        // synchronously inside present, and that report must cancel this
        // bound rather than find it armed afterwards.
        armPreflightDeadline()
        adapter.present(url: url) { [weak self] event in
            self?.handle(event)
        }
    }

    /// The one close path: idempotent, cancels both deadlines, dismisses the
    /// adapter (which pauses before releasing), drops the URL and makes
    /// every later adapter event a no-op. A session that had a player emits
    /// exactly one `.closed` outcome; one that never presented a player
    /// emits nothing (design §2.6.4, §6.4).
    func close() {
        guard state != .closed else { return }
        cancelPreflightDeadline()
        cancelReadyDeadline()
        url = nil
        adapter.dismiss()
        player = nil
        let hadPlayer = didPresentPlayer
        didPresentPlayer = false
        state = .closed
        if hadPlayer {
            events.playback(outcome: .closed, durationMs: elapsedMilliseconds(), error: nil)
        }
    }

    // MARK: - Adapter events (IF-19)

    /// Every seam event is routed here. The guards make each phase accept
    /// only the events that can legally follow it, so a late or duplicated
    /// callback cannot resurrect a dismissed cover, restart playback, or
    /// emit a second outcome.
    private func handle(_ event: InstructionPlaybackEvent) {
        switch event {
        case .preflightPassed:
            guard state == .preflighting else { return }
            // The preflight bound has done its job; the ready watchdog now
            // owns the only remaining wait (design §2.6.2).
            cancelPreflightDeadline()
            didPresentPlayer = true
            state = .preparing
            armReadyDeadline()

        case .ready:
            guard state == .preparing else { return }
            cancelPreflightDeadline()
            cancelReadyDeadline()
            player = adapter.renderablePlayer
            state = .ready
            events.playback(outcome: .ready, durationMs: elapsedMilliseconds(), error: nil)

        case .failed(let failure):
            guard isAwaitingPlayback else { return }
            fail(failure)

        case .finished:
            guard state == .ready else { return }
            cancelPreflightDeadline()
            cancelReadyDeadline()
            url = nil
            // The player stays for the last frame; Close remains available
            // and owns the teardown (design §3.5 timer contract).
            state = .finished

        case .closed:
            // Controller-only vocabulary: the adapter never emits it, and a
            // callback that does is not a controller transition.
            break
        }
    }

    /// The three non-terminal phases in which an adapter failure is real.
    /// `.idle`, `.failed`, `.finished` and `.closed` ignore it.
    private var isAwaitingPlayback: Bool {
        switch state {
        case .preflighting, .preparing, .ready:
            return true
        case .idle, .failed, .finished, .closed:
            return false
        }
    }

    // MARK: - Deadlines (P-1)

    private func armPreflightDeadline() {
        preflightDeadline = deadlineFactory.schedule(
            after: configuration.preflightTimeoutSeconds
        ) { [weak self] in
            self?.handlePreflightTimeout()
        }
    }

    private func armReadyDeadline() {
        readyDeadline = deadlineFactory.schedule(
            after: configuration.readyWatchdogSeconds
        ) { [weak self] in
            self?.handleReadyWatchdogTimeout()
        }
    }

    private func cancelPreflightDeadline() {
        preflightDeadline?.cancel()
        preflightDeadline = nil
    }

    private func cancelReadyDeadline() {
        readyDeadline?.cancel()
        readyDeadline = nil
    }

    /// Preflight never answered: the tap would feel dead, so fail with the
    /// one unsupported line (design §8.1, §9.2). Reached only while still
    /// preflighting; a cancelled or late firing is a no-op.
    private func handlePreflightTimeout() {
        guard state == .preflighting else { return }
        preflightDeadline = nil
        fail(.unsupported)
    }

    /// No `.ready` inside the responsiveness ceiling: timed out. A slow
    /// ready before this fires is still accepted — this is a ceiling for a
    /// platform stall, not early failure detection (design §8.1).
    private func handleReadyWatchdogTimeout() {
        guard state == .preparing else { return }
        readyDeadline = nil
        fail(.timedOut)
    }

    // MARK: - Failure and outcome

    /// The single failure transition shared by the adapter's typed failures
    /// and both deadlines: cancel every deadline, dismiss the adapter, drop
    /// the URL, fall back to the one plain line and emit exactly one failed
    /// outcome with its §3.3 token.
    private func fail(_ failure: InstructionPlaybackFailure) {
        cancelPreflightDeadline()
        cancelReadyDeadline()
        url = nil
        state = .failed(failure)
        player = nil
        adapter.dismiss()
        events.playback(outcome: .failed, durationMs: elapsedMilliseconds(), error: failure)
    }

    /// `duration_ms` from the injected clock: the session length on every
    /// terminal outcome. The emitter clamps to >= 0 (design §6.4).
    private func elapsedMilliseconds() -> Int {
        guard let startedAt else { return 0 }
        return Int(now().timeIntervalSince(startedAt) * 1000)
    }
}
