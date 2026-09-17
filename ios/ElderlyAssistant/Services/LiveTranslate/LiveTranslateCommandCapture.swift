import AVFoundation
import Foundation

// T-025 — the in-session microphone: one command window at a time, paused
// while the feature speaks, released as completely as the camera
// (FR-LCT-021, NFR-LCT-005, NFR-LCT-011; C01's audio configuration and C12's
// command capture).
//
// What this file exists to make true:
//
//  1. **One utterance, never always-on.** A window is opened by `listen`
//     and it ends with the first outcome — a command, a re-prompt, a turn
//     end, silence, or a cancellation. There is no continuous recogniser
//     here, and the type has no loop, no timer and no restart of its own:
//     the shipped single-utterance capture (`SearchPhraseCapture`) is the
//     whole microphone, and this file only decides *when* it may listen.
//
//  2. **The feature never hears itself.** Three guards, in order of
//     closeness: `listen` refuses to open a window while the feature is
//     speaking; `speechBegan()` cancels an open window for the duration of
//     the speech and `speechEnded()` resumes it with a **fresh** window; and
//     a transcript that arrives while the feature is speaking is discarded
//     rather than parsed, so the feature's own voice cannot become a command
//     even if the first two guards are missed. A resume never re-opens the
//     window the speech interrupted, so no pre-speech audio can answer it.
//
//  3. **The audio configuration is the shipped one.** The category, the
//     mode and the music-and-recording option live in `AudioSessionManager`
//     and nowhere else: this file never calls `setCategory`, and a test scans
//     its sources for that. Recording therefore coexists with whatever the
//     elder was already listening to, exactly as the rest of the app's
//     capture does — the feature adds no audio policy of its own.
//
//  4. **Teardown releases the microphone as completely as the camera.**
//     `close` stops recognition, drops the window (the session's completion
//     is never delivered), releases the audio session, and only then runs
//     the camera session's own teardown. A recognition callback that lands
//     after that finds a closed capture and does nothing.
//
//  5. **No transcript is stored, and none can be logged.** The utterance is
//     a local: it is parsed and dropped. This file holds no observability
//     bus, so a transcript has no event to travel in — and no audio buffer,
//     file handle or URL session is in scope, so nothing can be written or
//     sent. A test scans for all four.
//
//  6. **The parser stays T-023's.** Matching is
//     `LiveTranslateCommandTurn.accept(_:in:)` against the catalog-resolved
//     table, so the command vocabulary, the near-miss rule and the one
//     re-prompt are the ones that file already fixed.

/// What the feature needs from the shipped single-utterance capture: one
/// window in, one transcript or one failure out.
///
/// Deliberately *not* a second recognition stack: `SearchPhraseCapture`
/// conforms as it is, so production passes the shipped type and tests pass a
/// double. Its contract is the shipped one — the completion fires exactly
/// once, on the main queue, and a cancelled window yields no transcript.
protocol LiveTranslateUtteranceCapturing: AnyObject {
    /// Opens a microphone window for one utterance.
    func start(completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void)
    /// Ends the open window early. The shipped implementation removes its
    /// tap, stops the engine and deactivates the audio session before it
    /// calls the completion, and never harvests a transcript from a
    /// cancelled window.
    func cancel()
}

extension SearchPhraseCapture: LiveTranslateUtteranceCapturing {}

/// C12's command capture: the session's single-utterance microphone and the
/// rules that keep it from hearing the feature's own voice.
///
/// Main-queue only, like the shipped capture it drives: the coordinator builds
/// it, opens windows on user action, and tears it down with the session.
final class LiveTranslateCommandCapture {

    /// Why a window was not opened. A refusal is delivered to the caller's
    /// completion immediately — there is nothing to wait for — and it never
    /// changes the state of the window that is already open.
    enum Refusal: Equatable {
        /// A window is already open: one utterance at a time.
        case windowAlreadyOpen
        /// The feature is speaking. It must not hear itself, so no window
        /// opens until the speech ends.
        case featureIsSpeaking
        /// The session has closed. Nothing opens a microphone afterwards.
        case sessionClosed
    }

    /// What one command window produced.
    enum Outcome: Equatable {
        /// A command was recognised: the session performs it, and only it.
        case command(LiveTranslateCommand)
        /// Nothing matched: C12's single re-prompt, worded by the session.
        case reprompt
        /// Nothing matched and the re-prompt was already spent: the turn ends
        /// here, explicitly.
        case turnEnded
        /// The window ended with no speech in it. Not a failure — the elder
        /// said nothing.
        case noSpeech
        /// The microphone could not be used (permission, route, recogniser).
        /// The session reports nothing and the elder may try again; there is
        /// no retry here.
        case unavailable
        /// The window ended without an answer — a pause for the feature's own
        /// speech, an audio interruption, or the session's own cancel. No
        /// transcript was harvested, so no command fired from it.
        case cancelled
        /// The window never opened.
        case refused(Refusal)
    }

    private let device: LiveTranslateUtteranceCapturing
    private let audioSession: AudioSessionManager
    private let notifications: NotificationCenter
    private let isFeatureSpeaking: () -> Bool

    /// T-023's vocabulary, resolved once: a session parses many utterances
    /// and the catalog does not change under it.
    private let table: LiveTranslateCommandPhraseTable

    /// The turn rule (T-023): one re-prompt, then an explicit end.
    private var turn = LiveTranslateCommandTurn()

    /// The session's open request: non-nil exactly while a logical window is
    /// open (`isListening`). Cleared when an outcome is delivered, and never
    /// delivered after `close`.
    private var completion: ((Outcome) -> Void)?

    /// True while the device has a window we have not heard back from. The
    /// microphone is "open" from `start` until the device reports — which is
    /// what makes a resume wait for a teardown instead of starting a second
    /// window the shipped capture would refuse.
    private var microphoneIsOpen = false

    /// Set when we end a window ourselves (pause, interruption, cancel,
    /// close). The cancellation the device reports back is ours, not an
    /// answer, so it is swallowed rather than delivered.
    private var cancellationIsExpected = false

    /// A resume that arrived while the device was still closing its window.
    private var resumeWhenMicrophoneCloses = false

    /// Set by `close`: the capture is inert from then on.
    private var isClosed = false

    private var interruptionObservers: [NSObjectProtocol] = []

    init(device: LiveTranslateUtteranceCapturing,
         audioSession: AudioSessionManager,
         locale: Locale,
         notifications: NotificationCenter = .default,
         isFeatureSpeaking: @escaping () -> Bool) {
        self.device = device
        self.audioSession = audioSession
        self.notifications = notifications
        self.isFeatureSpeaking = isFeatureSpeaking
        self.table = .resolved(activeLocale: locale)
        observeInterruptions()
    }

    deinit {
        interruptionObservers.forEach { notifications.removeObserver($0) }
    }

    // MARK: - State

    /// True while the session has an open command window — including while
    /// the microphone is paused for speech or for an interruption, because
    /// the elder's request has not been answered yet.
    var isListening: Bool { completion != nil }

    /// True while a recognition window is actually open. False during the
    /// feature's own speech, which is what "the microphone is paused" means.
    var isMicrophoneOpen: Bool { microphoneIsOpen }

    // MARK: - The window

    /// Opens one command window. `completion` runs on the main queue exactly
    /// once — or immediately, with `.refused`, when no window was opened.
    func listen(completion: @escaping (Outcome) -> Void) {
        assert(Thread.isMainThread, "the command capture is main-queue only")
        guard !isClosed else {
            completion(.refused(.sessionClosed))
            return
        }
        guard !isListening else {
            completion(.refused(.windowAlreadyOpen))
            return
        }
        guard !isFeatureSpeaking() else {
            // A window opened now would record the feature's own voice.
            completion(.refused(.featureIsSpeaking))
            return
        }
        self.completion = completion
        openMicrophone()
    }

    /// The session abandons the window (the elder left the mode). The
    /// caller's completion is answered with `.cancelled`, so no caller is
    /// left waiting — the shipped capture's own contract for a cancel.
    func cancel() {
        assert(Thread.isMainThread)
        guard isListening else { return }
        guard microphoneIsOpen else {
            // A paused window has no device callback coming: answer now.
            endWindow(with: .cancelled)
            return
        }
        pauseMicrophone()
        endWindow(with: .cancelled)
    }

    // MARK: - Self-speech exclusion

    /// The feature is about to speak. The microphone pauses for the duration:
    /// an open window is cancelled (no transcript is harvested from it), and
    /// the session's request stays open so `speechEnded()` resumes it.
    func speechBegan() {
        assert(Thread.isMainThread)
        guard isListening else { return }
        pauseMicrophone()
    }

    /// The feature stopped speaking: capture resumes with a **fresh** window,
    /// so nothing said before or during the speech can answer it.
    func speechEnded() {
        assert(Thread.isMainThread)
        resumeIfPossible()
    }

    // MARK: - Teardown

    /// The session's teardown, in the design's order: recognition stops, the
    /// command window is drained, the audio session is released, and only
    /// then does the camera session stop.
    ///
    /// The order is structural, not conventional: `releaseCaptureSession` is
    /// a parameter, so the camera teardown cannot be sequenced anywhere but
    /// last. After this returns, nothing this object owns can call back — the
    /// window's completion is dropped rather than delivered, and a later
    /// recognition callback finds a closed capture.
    func close(then releaseCaptureSession: () -> Void) {
        assert(Thread.isMainThread)
        guard !isClosed else { return }
        isClosed = true

        // 1. Recognition stops. The shipped capture's teardown removes its
        //    tap, stops the engine and deactivates the audio session.
        if microphoneIsOpen {
            cancellationIsExpected = true
            device.cancel()
        }
        microphoneIsOpen = false

        // 2. The command queue is drained: the window is dropped without an
        //    outcome, so no command can fire from audio heard before close.
        completion = nil
        resumeWhenMicrophoneCloses = false

        // 3. The audio session is released — this feature's own step, so the
        //    microphone is given up even when no window was open.
        audioSession.deactivate()

        // 4. Then the camera session (T-006), as the design orders it.
        releaseCaptureSession()
    }

    // MARK: - Window lifecycle

    private func openMicrophone() {
        guard !microphoneIsOpen else {
            // The device is still closing its previous window and the shipped
            // capture refuses a second start: wait for it rather than record
            // a window that never opened.
            resumeWhenMicrophoneCloses = true
            return
        }
        microphoneIsOpen = true
        device.start { [weak self] result in
            self?.microphoneWindowEnded(result)
        }
    }

    /// The microphone is paused rather than answered: the device is told to
    /// cancel, and the cancellation it reports back is swallowed so the
    /// session's completion stays open.
    private func pauseMicrophone() {
        guard microphoneIsOpen else { return }
        cancellationIsExpected = true
        device.cancel()
    }

    /// Resumes the paused window with a fresh microphone, once the previous
    /// one has actually closed. A resume that arrives mid-teardown waits for
    /// the device rather than starting a second window it would refuse.
    private func resumeIfPossible() {
        guard isListening, !isClosed else { return }
        guard !isFeatureSpeaking() else { return }
        guard !microphoneIsOpen else {
            resumeWhenMicrophoneCloses = true
            return
        }
        openMicrophone()
    }

    private func microphoneWindowEnded(_ result: Result<String, SearchPhraseCapture.Failure>) {
        assert(Thread.isMainThread)
        // A callback after teardown does nothing at all.
        guard !isClosed else { return }
        microphoneIsOpen = false

        let wasPause = cancellationIsExpected
        cancellationIsExpected = false
        if wasPause {
            resumePendingIfNeeded()
            return
        }

        switch result {
        case .success(let utterance):
            guard !isFeatureSpeaking() else {
                // The feature started speaking during the window and nobody
                // paused us: this transcript is its own voice. It is not
                // parsed, and the window ends rather than listening on.
                endWindow(with: .cancelled)
                return
            }
            answer(utterance)
        case .failure(.noSpeech):
            endWindow(with: .noSpeech)
        case .failure(.cancelled):
            // Cancelled by something other than us — an interruption the
            // system ended, or the recogniser giving up. No transcript was
            // harvested, so this is a cancellation, not a command.
            endWindow(with: .cancelled)
        case .failure:
            endWindow(with: .unavailable)
        }
        resumePendingIfNeeded()
    }

    private func resumePendingIfNeeded() {
        guard resumeWhenMicrophoneCloses else { return }
        resumeWhenMicrophoneCloses = false
        resumeIfPossible()
    }

    /// Parses the utterance (T-023) and ends the window with the turn's
    /// outcome. The utterance is a local: it is matched and dropped.
    private func answer(_ utterance: String) {
        switch turn.accept(utterance, in: table) {
        case .command(let command):
            endWindow(with: .command(command))
        case .reprompt:
            endWindow(with: .reprompt)
        case .turnEnded:
            endWindow(with: .turnEnded)
        }
    }

    /// Ends the session's request. `microphoneIsOpen` is deliberately left
    /// alone: only the device's own callback knows when its window is really
    /// closed, and a start attempted before that would be refused silently.
    private func endWindow(with outcome: Outcome) {
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }

    // MARK: - Interruptions

    /// An interruption (a call, Siri, a route change the system takes over) is
    /// an audio-session event, so it is observed on the session's own
    /// notification: the capture pauses, and the pause is the same one the
    /// feature's own speech takes — the window is not answered, and when the
    /// interruption ends the request is resumed with a fresh microphone, so
    /// audio from before it can never become the command.
    private func observeInterruptions() {
        interruptionObservers.append(notifications.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.speechBegan()
            case .ended:
                self.speechEnded()
            @unknown default:
                break
            }
        })
    }
}
