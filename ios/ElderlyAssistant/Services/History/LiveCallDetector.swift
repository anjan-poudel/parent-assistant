import Foundation
#if canImport(CallKit)
import CallKit
#endif

/// The seam between live-call detection and CallKit (call-history task,
/// 2026-09-06; missed-calls task, 2026-09-07): the coordinator and
/// `LiveCallDetector` talk to this protocol, never to CallKit types, so
/// the whole feature is testable against a fake provider and CallKit
/// stays behind one thin wall.
protocol CallStateProviding: AnyObject {
    /// True while a call is connected (has been picked up) and has not
    /// ended yet.
    var hasActiveCall: Bool { get }

    /// Registers `listener` to be invoked whenever the system reports a
    /// call-state change. An implementation may invoke the listener on
    /// any queue.
    func addChangeListener(_ listener: @escaping () -> Void)

    /// Registers `listener` to be invoked ONCE per call that ended
    /// without ever connecting — a missed or declined incoming call, or
    /// an attempted outgoing call that never got picked up (missed-calls
    /// task, 2026-09-07). `listener` receives the moment the call's end
    /// was observed. ANONYMOUS BY PLATFORM DESIGN: iOS masks the
    /// identity AND the number of calls that involve other apps, so this
    /// event carries no name, no number, and nothing an address book
    /// could match — the app records the event, never a caller. An
    /// implementation may invoke the listener on any queue.
    func addUnansweredListener(_ listener: @escaping (Date) -> Void)
}

/// Production `CallStateProviding` backed by CXCallObserver.
///
/// Masked/anonymous by platform design: for calls that involve OTHER apps
/// (the overwhelmingly common case — the user's phone is ringing because
/// someone called, not because this app placed a call), iOS delivers a
/// CXCall whose identifying details are masked — no handle, no number, no
/// identity. The only facts an app can know — and therefore the only
/// facts this feature ever claims — are "a call is connected" and "a
/// call went unanswered" (a call that ended without ever connecting).
/// Detection is deliberately anonymous: nothing about the call is read
/// for storage, and no call detail ever reaches the activity log.
final class CXCallStateProvider: NSObject, CallStateProviding {
    private let observer = CXCallObserver()
    private var listeners: [() -> Void] = []
    private var unansweredListeners: [(Date) -> Void] = []
    /// Once-per-call bookkeeping for the unanswered event — a call that
    /// already reported never reports again (the ended-unconnected state
    /// is terminal, so a repeat delivery is the same event, not a new
    /// one).
    private let unansweredTracker = UnansweredCallTracker()

    override init() {
        super.init()
        // Delegate callbacks on main — LiveCallDetector (and the
        // coordinator's @Published flag) are main-queue confined.
        observer.setDelegate(self, queue: .main)
    }

    var hasActiveCall: Bool {
        observer.calls.contains { $0.hasConnected && !$0.hasEnded }
    }

    func addChangeListener(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    func addUnansweredListener(_ listener: @escaping (Date) -> Void) {
        unansweredListeners.append(listener)
    }
}

extension CXCallStateProvider: CXCallObserverDelegate {
    func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        for listener in listeners {
            listener()
        }
        // Unanswered detection (missed-calls task, 2026-09-07): a
        // missed/declined call reaches its end as `hasEnded == true`
        // with `hasConnected` still false — its terminal state, the
        // moment it stops being a live, connectable call (the equivalent
        // of the call dropping out of the observer's live list). The
        // event is keyed off THIS `callChanged` callback rather than the
        // `calls` array: Apple's own guidance is that the array is an
        // asynchronous snapshot in which ended calls can linger or go
        // stale, while the delegate callbacks are the reliable signal.
        if unansweredTracker.isNewUnanswered(uuid: call.uuid,
                                             hasEnded: call.hasEnded,
                                             hasConnected: call.hasConnected) {
            let endedAt = Date()
            for listener in unansweredListeners {
                listener(endedAt)
            }
        }
    }
}

/// Once-per-call unanswered-event gate for `CXCallStateProvider`
/// (missed-calls task, 2026-09-07). CallKit cannot be driven by unit
/// tests — CXCall has no public initializer and CXCallObserver cannot be
/// faked — so the provider's ONLY stateful decision (has this call's
/// ended-unconnected state already been reported?) lives here as a pure,
/// Foundation-only tracker the tests can drive directly.
final class UnansweredCallTracker {
    private var reported: Set<UUID> = []

    /// Returns true — fire the unanswered event — exactly when this
    /// update is the FIRST observation of a call that ended without ever
    /// connecting (`hasEnded` true, `hasConnected` false). A call that
    /// connected never reports: `hasConnected` is sticky, so its end
    /// arrives with the flag still true. Re-delivered ended-unconnected
    /// updates for an already-reported call report once only.
    func isNewUnanswered(uuid: UUID, hasEnded: Bool, hasConnected: Bool) -> Bool {
        guard hasEnded, !hasConnected else { return false }
        return reported.insert(uuid).inserted
    }
}

/// Edge-triggered live-call detector (call-history task, 2026-09-06;
/// missed-calls task, 2026-09-07).
///
/// Snapshots `provider.hasActiveCall` at init, subscribes to provider
/// changes, and fires `onChange` ONLY when the active state actually
/// changes — never a duplicate callback for an unchanged state, and never
/// an initial callback just because a call was already connected when the
/// detector was created (the coordinator reads `hasActiveCall` for that).
/// A transition that lands between the snapshot and the subscription is
/// collapsed into the snapshot update and reported once.
///
/// `onUnanswered` forwards the provider's unanswered-call events (a call
/// that ended without ever connecting — missed/declined, 2026-09-07) as a
/// straight pass-through: each delivery is already once-per-call at the
/// provider, so forwarding carries the same edge semantics as `onChange`
/// — one event per real call, never a replay of the same event.
///
/// Keeps no CallKit types — everything CallKit lives in
/// `CXCallStateProvider`.
final class LiveCallDetector {
    private let provider: CallStateProviding
    private let onChange: ((Bool) -> Void)?
    /// Fired once per call that ended without ever connecting, with the
    /// moment the end was observed (missed-calls task, 2026-09-07).
    /// ANONYMOUS: the event carries no caller identity or number — iOS
    /// masks both for calls that involve other apps — and nothing
    /// derived from it ever claims one.
    private let onUnanswered: ((Date) -> Void)?

    /// Current belief about whether a call is connected.
    private(set) var hasActiveCall: Bool

    init(provider: CallStateProviding,
         onChange: ((Bool) -> Void)? = nil,
         onUnanswered: ((Date) -> Void)? = nil) {
        self.provider = provider
        self.onChange = onChange
        self.onUnanswered = onUnanswered
        hasActiveCall = provider.hasActiveCall
        provider.addChangeListener { [weak self] in self?.refresh() }
        provider.addUnansweredListener { [weak self] timestamp in
            guard let self else { return }
            self.onUnanswered?(timestamp)
        }
        // Collapse any change that landed between the snapshot above and
        // the subscription — still reported exactly once if it happened,
        // never a phantom report when nothing changed.
        refresh()
    }

    private func refresh() {
        let current = provider.hasActiveCall
        guard current != hasActiveCall else { return }
        hasActiveCall = current
        onChange?(current)
    }
}
