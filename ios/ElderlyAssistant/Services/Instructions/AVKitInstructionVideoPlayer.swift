import AVFoundation

/// C07 — the only file that constructs `AVPlayer`/`AVPlayerItem` for
/// instructions, and the only reader of playback-time AVFoundation state
/// (design L2 §2.7, §7.1).
///
/// The adapter's whole contract crosses the seam as typed
/// `InstructionPlaybackEvent` values: no `NSError`, domain, code,
/// description or path ever leaves this file, and nothing is logged at all
/// (design §6.4: no console writes in the feature roots; the
/// `FailedToPlayToEnd` notification's error payload is deliberately not
/// read).
///
/// Ownership is deliberately narrow (design §2.7.4): the adapter owns the
/// player, the synchronous preflight, ready observation, failure
/// observation and teardown. It owns no timers, no copy, no availability
/// policy and no decision about when playback may start — it never calls
/// `play()`; whoever holds `renderablePlayer` drives playback. The URL is
/// callback-scoped to `present` and is never stored (design §7.4).
///
/// The observation handlers are internal so the adapter suite drives every
/// mapping deterministically; the registrations themselves are
/// source-pinned by that suite (design §11.2).
@MainActor
final class AVKitInstructionVideoPlayer: NSObject, InstructionVideoPlaying {

    // MARK: - State

    /// `nil` until a successful preflight inside `present`; `nil` again
    /// after `dismiss` (design §2.7.1, §2.7.3).
    private(set) var renderablePlayer: AVPlayer?

    private var onEvent: (@MainActor (InstructionPlaybackEvent) -> Void)?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playToEndObserver: NSObjectProtocol?
    private var failToEndObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var didDeliverReady = false
    private var didDeliverTerminal = false
    private var isDismissed = false

    /// Constructs nothing (design §2.7): no player exists before `present`.
    override init() {
        super.init()
    }

    deinit {
        // Safety net: the controller always dismisses (design §2.6.2–2.6.4),
        // but a leaked notification registration must not outlive the
        // adapter. The KVO observation invalidates itself on deallocation.
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        if let failToEndObserver {
            NotificationCenter.default.removeObserver(failToEndObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - IF-19

    func present(url: URL, onEvent: @escaping @MainActor (InstructionPlaybackEvent) -> Void) {
        // A fresh present is a fresh session: whatever a previous session
        // left behind is replaced without emitting (replay is a fresh
        // `present` from the view; the adapter keeps no history).
        teardownObservers()
        renderablePlayer = nil
        self.onEvent = onEvent
        didDeliverReady = false
        didDeliverTerminal = false
        isDismissed = false

        // Preflight (design §2.7.1): the synchronous playability check. A
        // non-file URL is refused before AVFoundation sees it — no network
        // access is permitted anywhere in this path (design §8.3). A
        // missing or unplayable file is the same single typed failure.
        guard url.isFileURL, AVURLAsset(url: url).isPlayable else {
            emit(.failed(.unsupported))
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        renderablePlayer = player

        // Status KVO (design §2.7.2): `.readyToPlay` → `.ready`, `.failed`
        // → `.failed(.playerFailed)`. `[.initial]` catches an item that
        // already settled before the observation attached.
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status)
            }
        }

        let center = NotificationCenter.default
        playToEndObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlayedToEnd()
            }
        }
        failToEndObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            // The notification's userInfo carries an NSError; it is
            // deliberately not read (design §6.4: no raw errors escape).
            Task { @MainActor [weak self] in
                self?.handleFailedToReachEnd()
            }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            var type: AVAudioSession.InterruptionType?
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt {
                type = AVAudioSession.InterruptionType(rawValue: raw)
            }
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        }

        // Last, and before returning (design §2.7.1).
        emit(.preflightPassed)
    }

    func dismiss() {
        // Close the door before touching the player: an observation already
        // in flight becomes a no-op (T-004 scenario "A late event after
        // close is ignored").
        isDismissed = true
        // Pause first, then clear the item, then release the player
        // (design §2.7.3; T-004 scenario "Dismiss pauses before
        // releasing"). Every step is idempotent, so a second dismiss is a
        // harmless no-op.
        renderablePlayer?.pause()
        renderablePlayer?.replaceCurrentItem(with: nil)
        teardownObservers()
        renderablePlayer = nil
        onEvent = nil
    }

    // MARK: - Observation handlers

    /// The status mapping the KVO observer forwards to (design §2.7.2).
    /// Internal so the adapter suite drives the mapping deterministically.
    func handleItemStatus(_ status: AVPlayerItem.Status) {
        guard !isDismissed, !didDeliverTerminal else { return }
        switch status {
        case .readyToPlay:
            guard !didDeliverReady else { return }
            didDeliverReady = true
            emit(.ready)
        case .failed:
            emit(.failed(.playerFailed))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// The `AVPlayerItemDidPlayToEndTime` mapping (design §2.7.2). A finish
    /// observation before the item ever became ready is spurious and is
    /// dropped (T-004 test `testFinishedOnlyAfterStart`).
    func handlePlayedToEnd() {
        guard !isDismissed, !didDeliverTerminal, didDeliverReady else { return }
        emit(.finished)
    }

    /// The `AVPlayerItemFailedToPlayToEndTime` mapping: a mid-play failure
    /// is the same one typed `.playerFailed` as a status failure.
    func handleFailedToReachEnd() {
        guard !isDismissed, !didDeliverTerminal, didDeliverReady else { return }
        emit(.failed(.playerFailed))
    }

    /// The `AVAudioSession.interruptionNotification` mapping (design
    /// §2.7.2): `.began` is one typed `.failed(.interrupted)`; `.ended` (the
    /// system returned our audio) is not an event — resuming is never the
    /// adapter's decision.
    func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard !isDismissed, !didDeliverTerminal else { return }
        guard type == .began else { return }
        emit(.failed(.interrupted))
    }

    // MARK: - Emission and teardown

    /// The single emission gate: nothing after dismiss, and one terminal
    /// event per session — a `.failed` or `.finished` closes the door
    /// (T-004 scenario "Preflight failure reports one plain failure and
    /// stays closed").
    private func emit(_ event: InstructionPlaybackEvent) {
        guard !isDismissed, !didDeliverTerminal else { return }
        onEvent?(event)
        switch event {
        case .failed, .finished:
            didDeliverTerminal = true
        case .preflightPassed, .ready, .closed:
            break
        }
    }

    /// Removes every observation registered by `present` (design §2.7.3).
    private func teardownObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = nil
        if let failToEndObserver {
            NotificationCenter.default.removeObserver(failToEndObserver)
        }
        failToEndObserver = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }
}
