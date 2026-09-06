import Foundation
#if canImport(CallKit)
import CallKit
#endif

/// The seam between live-call detection and CallKit (call-history task,
/// 2026-09-06): the coordinator and `LiveCallDetector` talk to this
/// protocol, never to CallKit types, so the whole feature is testable
/// against a fake provider and CallKit stays behind one thin wall.
protocol CallStateProviding: AnyObject {
    /// True while a call is connected (has been picked up) and has not
    /// ended yet.
    var hasActiveCall: Bool { get }

    /// Registers `listener` to be invoked whenever the system reports a
    /// call-state change. An implementation may invoke the listener on
    /// any queue.
    func addChangeListener(_ listener: @escaping () -> Void)
}

/// Production `CallStateProviding` backed by CXCallObserver.
///
/// Masked/anonymous by platform design: for calls that involve OTHER apps
/// (the overwhelmingly common case — the user's phone is ringing because
/// someone called, not because this app placed a call), iOS delivers a
/// CXCall whose identifying details are masked — no handle, no number, no
/// identity. The only fact an app can know — and therefore the only fact
/// this feature ever claims — is "a call is connected". Detection is
/// deliberately anonymous: nothing about the call is read for storage,
/// and no call detail ever reaches the activity log.
final class CXCallStateProvider: NSObject, CallStateProviding {
    private let observer = CXCallObserver()
    private var listeners: [() -> Void] = []

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
}

extension CXCallStateProvider: CXCallObserverDelegate {
    func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        for listener in listeners {
            listener()
        }
    }
}

/// Edge-triggered live-call detector (call-history task, 2026-09-06).
///
/// Snapshots `provider.hasActiveCall` at init, subscribes to provider
/// changes, and fires `onChange` ONLY when the active state actually
/// changes — never a duplicate callback for an unchanged state, and never
/// an initial callback just because a call was already connected when the
/// detector was created (the coordinator reads `hasActiveCall` for that).
/// A transition that lands between the snapshot and the subscription is
/// collapsed into the snapshot update and reported once.
///
/// Keeps no CallKit types — everything CallKit lives in
/// `CXCallStateProvider`.
final class LiveCallDetector {
    private let provider: CallStateProviding
    private let onChange: ((Bool) -> Void)?

    /// Current belief about whether a call is connected.
    private(set) var hasActiveCall: Bool

    init(provider: CallStateProviding, onChange: ((Bool) -> Void)? = nil) {
        self.provider = provider
        self.onChange = onChange
        hasActiveCall = provider.hasActiveCall
        provider.addChangeListener { [weak self] in self?.refresh() }
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
