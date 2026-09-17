import AVFoundation
import XCTest
@testable import ElderlyAssistant

/// T-025 — the in-session microphone: one command window at a time, paused
/// while the feature speaks, released as completely as the camera
/// (FR-LCT-021, NFR-LCT-005, NFR-LCT-011).
///
/// Two levels, deliberately:
///  - **unit**, over a double device and the *shipped* `AudioSessionManager`
///    driven by a stub `AudioSessionControlling` — so the audio calls the
///    tests read are the ones the real manager makes;
///  - **integration**, over a device double that behaves like the shipped
///    `SearchPhraseCapture` (activates the session when its window opens,
///    deactivates it when its window closes), including the interruption
///    path, posted as the real notification an interruption posts.
final class LiveTranslateCommandCaptureTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var bus: LiveTranslateSanitisingBus!
    private var session: StubAudioSession!
    private var audioManager: AudioSessionManager!

    override func setUp() {
        super.setUp()
        suiteName = "livetranslate.capture.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        bus = LiveTranslateSanitisingBus()
        session = StubAudioSession()
        audioManager = AudioSessionManager(observabilityBus: bus,
                                           audioSession: session,
                                           defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        bus = nil
        session = nil
        audioManager = nil
        super.tearDown()
    }

    // MARK: - Doubles

    /// The doubles that take part in an ordering assertion share one log, so
    /// "recognition stops, then the audio is released, then the camera" is a
    /// sequence a test reads rather than a claim about call sites.
    private protocol Logging: AnyObject {
        var log: (String) -> Void { get set }
    }

    /// The shipped single-utterance capture's contract, hand-driven: one
    /// completion per window, fired exactly once.
    ///
    /// `cancellationIsSynchronous` models the two honest shapes of that
    /// contract: the recogniser reporting its cancel back inline, and
    /// reporting it after `cancel()` has already returned. Both must leave
    /// the capture in the same state.
    ///
    /// `cancellationReportsTranscript` models the race the design names: audio
    /// the recogniser had ALREADY harvested wins the race against the cancel,
    /// so the window's one report carries a transcript rather than a
    /// cancellation. The capture must swallow it all the same.
    private final class StubDevice: LiveTranslateUtteranceCapturing, Logging {

        var cancellationIsSynchronous = true
        var cancellationReportsTranscript: String?
        var log: (String) -> Void = { _ in }

        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private var completion: ((Result<String, SearchPhraseCapture.Failure>) -> Void)?

        func start(completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) {
            startCount += 1
            log("device.start")
            self.completion = completion
        }

        func cancel() {
            cancelCount += 1
            log("device.cancel")
            guard cancellationIsSynchronous else { return }
            if let transcript = cancellationReportsTranscript {
                deliver(.success(transcript))
            } else {
                deliverCancellation()
            }
        }

        /// Reports the cancellation of the open window — the shipped
        /// capture's teardown ran and produced no transcript.
        @discardableResult
        func deliverCancellation() -> Bool {
            deliver(.failure(.cancelled))
        }

        @discardableResult
        func deliver(_ result: Result<String, SearchPhraseCapture.Failure>) -> Bool {
            guard let completion else { return false }
            self.completion = nil
            completion(result)
            return true
        }

        var hasOpenWindow: Bool { completion != nil }
    }

    /// Stands in for the shipped `SearchPhraseCapture` on the paths that
    /// touch audio: its window opens *through* the session manager (activate)
    /// and its teardown releases it (deactivate), exactly as the shipped
    /// type's `activateSessionAndListen` / `finish` do. Everything else is
    /// the hand-driven double above.
    private final class SessionDrivingDevice: LiveTranslateUtteranceCapturing, Logging {

        private let audioSession: AudioSessionManager
        private var completion: ((Result<String, SearchPhraseCapture.Failure>) -> Void)?
        var log: (String) -> Void = { _ in }

        private(set) var startCount = 0
        private(set) var didFailToActivate = false

        init(audioSession: AudioSessionManager) {
            self.audioSession = audioSession
        }

        func start(completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) {
            startCount += 1
            log("device.start")
            audioSession.activate { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.completion = completion
                case .failure:
                    self.didFailToActivate = true
                    completion(.failure(.audioUnavailable))
                }
            }
        }

        func cancel() {
            log("device.cancel")
            // The shipped teardown order: the tap goes, the engine stops and
            // the session is deactivated — THEN the completion is delivered.
            audioSession.deactivate()
            deliver(.failure(.cancelled))
        }

        @discardableResult
        func deliver(_ result: Result<String, SearchPhraseCapture.Failure>) -> Bool {
            guard let completion else { return false }
            self.completion = nil
            completion(result)
            return true
        }
    }

    private final class StubAudioSession: AudioSessionControlling, Logging {

        var isInputAvailable = true
        var permissionGranted = true
        var notificationSource: AnyObject? = NSObject()
        var log: (String) -> Void = { _ in }

        private(set) var categoryCalls: [(category: AVAudioSession.Category,
                                           mode: AVAudioSession.Mode,
                                           options: AVAudioSession.CategoryOptions)] = []
        private(set) var activeCalls: [Bool] = []
        private(set) var modeCalls: [AVAudioSession.Mode] = []

        func requestRecordPermission(_ callback: @escaping (Bool) -> Void) {
            callback(permissionGranted)
        }

        func setCategory(_ category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws {
            categoryCalls.append((category, mode, options))
            log("audio.setCategory")
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            activeCalls.append(active)
            log(active ? "audio.activate" : "audio.deactivate")
        }

        func setMode(_ mode: AVAudioSession.Mode) throws {
            modeCalls.append(mode)
        }

        func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    }

    // MARK: - Fixtures

    private var isSpeaking = false

    /// A capture over a plain double device, with the *shipped* audio manager
    /// underneath it.
    private func makeCapture(device: LiveTranslateUtteranceCapturing,
                             notifications: NotificationCenter = .default,
                             log: @escaping (String) -> Void = { _ in })
        -> LiveTranslateCommandCapture {
        session.log = log
        (device as? Logging)?.log = log
        return LiveTranslateCommandCapture(device: device,
                                           audioSession: audioManager,
                                           locale: nepali,
                                           notifications: notifications,
                                           isFeatureSpeaking: { [weak self] in self?.isSpeaking ?? false })
    }

    /// One resolved phrase per command, taken from T-023's own table so this
    /// suite never spells a phrase of its own.
    private func phraseTable() -> LiveTranslateCommandPhraseTable {
        .resolved(activeLocale: nepali)
    }

    private func phrase(for command: LiveTranslateCommand) -> String? {
        phraseTable().entries.first { $0.command == command }?.phrase
    }

    // MARK: - Scenario: a spoken command is captured as a single utterance

    func testASpokenCommandIsCapturedAsASingleUtterance() throws {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        let utterance = try XCTUnwrap(phrase(for: .readAll))

        capture.listen { outcomes.append($0) }

        XCTAssertEqual(device.startCount, 1, "the window opens on request")
        XCTAssertTrue(capture.isListening)
        XCTAssertTrue(capture.isMicrophoneOpen)

        XCTAssertTrue(device.deliver(.success(utterance)))

        XCTAssertEqual(outcomes, [.command(.readAll)], "the utterance is handed to T-023's parser")
        XCTAssertFalse(capture.isListening)
        XCTAssertFalse(capture.isMicrophoneOpen)
        XCTAssertEqual(device.startCount, 1,
                       "one window per request: no continuous recogniser re-arms itself")
    }

    func testEveryCommandInTheVocabularyIsReachableFromASpokenPhrase() throws {
        let table = phraseTable()
        XCTAssertEqual(table.entries.count,
                       LiveTranslateCommandPhraseTable.catalogKeys.count * AppLanguage.allCases.count,
                       "both languages' forms must resolve, or this test proves less than it looks")

        // First match wins, so a phrase two languages share is exercised once
        // — the same rule the parser itself applies.
        var exercised: Set<String> = []
        for entry in table.entries where !exercised.contains(entry.phrase) {
            exercised.insert(entry.phrase)
            let device = StubDevice()
            let capture = makeCapture(device: device)
            var outcomes: [LiveTranslateCommandCapture.Outcome] = []
            capture.listen { outcomes.append($0) }
            XCTAssertTrue(device.deliver(.success(entry.phrase)))
            XCTAssertEqual(outcomes, [.command(entry.command)],
                           "\(entry.key) in \(entry.language) must reach its command")
        }
        XCTAssertGreaterThanOrEqual(exercised.count, LiveTranslateCommand.allCommands.count,
                                    "every command must be reachable by speech")
    }

    func testASecondWindowIsRefusedWhileOneIsOpen() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        capture.listen { _ in }

        var refusals: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { refusals.append($0) }

        XCTAssertEqual(refusals, [.refused(.windowAlreadyOpen)],
                       "one utterance at a time — a second window would be a second recogniser")
        XCTAssertEqual(device.startCount, 1)
    }

    func testAMissRepromptsOnceAndThenEndsTheTurn() throws {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        // A phrase that is not in the vocabulary. The parser's near-miss rule
        // is T-023's; what this asserts is that the capture reports it.
        let nearMiss = "open the gate"

        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        XCTAssertTrue(device.deliver(.success(nearMiss)))
        XCTAssertEqual(outcomes, [.reprompt], "C12's one re-prompt")

        capture.listen { outcomes.append($0) }
        XCTAssertTrue(device.deliver(.success(nearMiss)))
        XCTAssertEqual(outcomes, [.reprompt, .turnEnded],
                       "the turn ends explicitly after the re-prompt is spent")
        XCTAssertNil(outcomes.first { if case .command = $0 { return true }; return false },
                     "nothing was said that is a command")
    }

    func testSilenceIsNotAFailure() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        XCTAssertTrue(device.deliver(.failure(.noSpeech)))

        XCTAssertEqual(outcomes, [.noSpeech])
        XCTAssertFalse(capture.isListening)
    }

    func testAnUnusableMicrophoneIsReportedAsUnavailable() {
        for failure in [SearchPhraseCapture.Failure.notAuthorized,
                        .noAudioInput,
                        .audioUnavailable,
                        .busy,
                        .recognitionFailed] {
            let device = StubDevice()
            let capture = makeCapture(device: device)
            var outcomes: [LiveTranslateCommandCapture.Outcome] = []
            capture.listen { outcomes.append($0) }

            XCTAssertTrue(device.deliver(.failure(failure)))

            XCTAssertEqual(outcomes, [.unavailable],
                           "\(failure) is not a command and not silence")
        }
    }

    func testACancellationNobodyAskedForEndsTheWindowWithoutACommand() {
        // The recogniser can give up on its own — a route change, a session
        // the system took back. The window ends with no answer and, crucially,
        // with no transcript harvested from it, and nothing reopens it behind
        // the elder's back.
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        XCTAssertTrue(device.deliver(.failure(.cancelled)))

        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertFalse(capture.isListening)
        XCTAssertEqual(device.startCount, 1,
                       "an abandoned window is not re-opened on its own")
    }

    // MARK: - Scenario: the feature does not hear itself

    func testTheWindowIsRefusedWhileTheFeatureIsSpeaking() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        isSpeaking = true

        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        XCTAssertEqual(outcomes, [.refused(.featureIsSpeaking)])
        XCTAssertEqual(device.startCount, 0, "the microphone never opened")
        XCTAssertFalse(capture.isListening)
    }

    func testSpeechPausesTheMicrophoneAndTheResumeIsAFreshWindow() throws {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        XCTAssertTrue(capture.isMicrophoneOpen)

        isSpeaking = true
        capture.speechBegan()

        XCTAssertFalse(capture.isMicrophoneOpen, "the microphone is paused for the speech")
        XCTAssertTrue(capture.isListening, "the elder's request is still open")
        XCTAssertEqual(device.cancelCount, 1)
        XCTAssertEqual(outcomes, [], "the paused window is not answered")

        isSpeaking = false
        capture.speechEnded()

        XCTAssertTrue(capture.isMicrophoneOpen)
        XCTAssertEqual(device.startCount, 2, "the resume is a fresh window, not the old audio")

        let utterance = try XCTUnwrap(phrase(for: .stopSpeaking))
        XCTAssertTrue(device.deliver(.success(utterance)))
        XCTAssertEqual(outcomes, [.command(.stopSpeaking)], "exactly one answer to one request")
    }

    func testATranscriptThatArrivesWhileTheFeatureIsSpeakingIsNeverACommand() throws {
        // Nobody told the capture that speech had started: the arrival gate is
        // the last line of defence, and it is the one that makes "the
        // feature's own output is never recognised" true rather than likely.
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        isSpeaking = true
        let utterance = try XCTUnwrap(phrase(for: .close))
        XCTAssertTrue(device.deliver(.success(utterance)))

        XCTAssertEqual(outcomes, [.cancelled],
                       "its own voice is not a command — the window is abandoned, not answered")
        XCTAssertFalse(capture.isMicrophoneOpen)
    }

    func testAudioFromBeforeTheSpeechCannotAnswerTheResumedWindow() throws {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        // Audio the recogniser had already harvested wins the race against
        // the pause: the window's one report carries a transcript rather than
        // a cancellation. The shipped recogniser's own "no transcript from a
        // cancelled window" rule is the first guard; this is the second, and
        // it is the one that holds when the two race.
        device.cancellationReportsTranscript = try XCTUnwrap(phrase(for: .stopSpeaking))
        isSpeaking = true
        capture.speechBegan()

        XCTAssertEqual(outcomes, [], "pre-speech audio is not the answer to a post-speech window")
        XCTAssertFalse(capture.isMicrophoneOpen)

        isSpeaking = false
        capture.speechEnded()
        XCTAssertTrue(device.deliver(.success(try XCTUnwrap(phrase(for: .readAll)))))

        XCTAssertEqual(outcomes, [.command(.readAll)])
    }

    func testAResumeThatArrivesMidTeardownWaitsForTheDevice() throws {
        let device = StubDevice()
        device.cancellationIsSynchronous = false
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        isSpeaking = true
        capture.speechBegan()
        isSpeaking = false
        capture.speechEnded()

        XCTAssertEqual(device.startCount, 1,
                       "the shipped capture refuses a second window while it is still closing")

        device.deliverCancellation()

        XCTAssertEqual(device.startCount, 2, "the resume opens once the device is free")
        let utterance = try XCTUnwrap(phrase(for: .repeatLast))
        XCTAssertTrue(device.deliver(.success(utterance)))
        XCTAssertEqual(outcomes, [.command(.repeatLast)])
    }

    // MARK: - Scenario: recording coexists with background audio

    func testACommandWindowActivatesTheShippedPresetThatMixesWithOtherAudio() {
        let device = SessionDrivingDevice(audioSession: audioManager)
        let capture = makeCapture(device: device)
        capture.listen { _ in }

        XCTAssertFalse(device.didFailToActivate, "no session error on the way in")
        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.categoryCalls.first?.category, .playAndRecord)
        XCTAssertEqual(session.categoryCalls.first?.mode, .measurement)
        XCTAssertTrue(session.categoryCalls.first?.options.contains(.mixWithOthers) == true,
                      "other audio keeps playing: starting the window does not mute the elder's music")
        XCTAssertEqual(session.activeCalls, [true])
    }

    func testTheFeatureNeverConfiguresTheAudioCategoryItself() {
        // The category string lives in `AudioSessionManager` and nowhere else:
        // a second `setCategory` in this feature is how two audio policies
        // start to disagree.
        let files = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        XCTAssertFalse(files.isEmpty, "the feature's sources must be scanned, not skipped")
        for file in files {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "setCategory", in: FeatureSourceScan.codeText(of: file)),
                         "\(FeatureSourceScan.relativePath(of: file)) configures the audio category")
        }
        // Falsifiable: the same pattern finds it where it does live.
        let manager = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Voice/AudioSessionManager.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "setCategory",
                                                     in: FeatureSourceScan.codeText(of: manager)))
    }

    // MARK: - Scenario: closing releases the microphone as completely as the camera

    func testCloseReleasesTheMicrophoneInTheDesignsOrder() throws {
        var log: [String] = []
        let device = StubDevice()
        let capture = makeCapture(device: device, log: { log.append($0) })
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        log.removeAll()

        capture.close { log.append("camera.stop") }

        XCTAssertEqual(log, ["device.cancel", "audio.deactivate", "camera.stop"],
                       "recognition stops, the command window is drained, the audio is "
                       + "released, and the camera session goes last")
        XCTAssertEqual(outcomes, [], "the drained window is never answered")
        XCTAssertFalse(capture.isListening)
        XCTAssertFalse(capture.isMicrophoneOpen)
    }

    func testNoRecognitionCallbackFiresAfterTeardown() throws {
        let device = StubDevice()
        device.cancellationIsSynchronous = false
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        capture.close { }

        // The recogniser reports back after the session is gone — the race
        // this teardown order exists to survive. The callback really does
        // happen; what must not happen is anything reaching the caller.
        XCTAssertTrue(device.hasOpenWindow, "the double still owes a report — that is the race")
        XCTAssertTrue(device.deliver(.success("this must never be parsed")))
        XCTAssertFalse(device.deliverCancellation(), "one window reports once, as shipped")
        XCTAssertEqual(outcomes, [], "a recognition callback after teardown is dropped")
        XCTAssertFalse(capture.isListening)
        XCTAssertFalse(capture.isMicrophoneOpen)
    }

    func testAClosedCaptureOpensNoFurtherWindowAndRefusesToListen() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        capture.close { }

        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        XCTAssertEqual(outcomes, [.refused(.sessionClosed)])
        XCTAssertEqual(device.startCount, 0)
        XCTAssertFalse(capture.isListening)
    }

    func testClosingWhilePausedStillReleasesTheAudio() {
        var log: [String] = []
        let device = StubDevice()
        let capture = makeCapture(device: device, log: { log.append($0) })
        capture.listen { _ in }
        isSpeaking = true
        capture.speechBegan()
        log.removeAll()

        capture.close { log.append("camera.stop") }

        XCTAssertEqual(log, ["audio.deactivate", "camera.stop"],
                       "a paused window has no device to cancel, but the audio is still released")
    }

    func testCancelAnswersTheCallerAndStopsTheMicrophone() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        capture.cancel()

        XCTAssertEqual(outcomes, [.cancelled], "no caller is left waiting")
        XCTAssertEqual(device.cancelCount, 1)
        XCTAssertFalse(capture.isListening)
        XCTAssertFalse(capture.isMicrophoneOpen)
    }

    func testCancelWhilePausedAnswersImmediately() {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        isSpeaking = true
        capture.speechBegan()

        capture.cancel()

        XCTAssertEqual(outcomes, [.cancelled],
                       "a paused window has no device callback coming, so the answer is immediate")
        XCTAssertEqual(device.cancelCount, 1, "and the paused window is not cancelled twice")
        XCTAssertFalse(capture.isListening)
    }

    // MARK: - Scenario: an interruption pauses capture and resumes safely

    func testAnInterruptionPausesCaptureAndResumesItWithoutDuplicatingACommand() throws {
        let center = NotificationCenter()
        let device = SessionDrivingDevice(audioSession: audioManager)
        let capture = makeCapture(device: device, notifications: center)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        XCTAssertEqual(device.startCount, 1)

        center.post(name: AVAudioSession.interruptionNotification, object: session.notificationSource,
                    userInfo: [AVAudioSessionInterruptionTypeKey:
                                AVAudioSession.InterruptionType.began.rawValue])

        XCTAssertFalse(capture.isMicrophoneOpen, "capture pauses")
        XCTAssertTrue(capture.isListening, "without losing the session")
        XCTAssertEqual(outcomes, [], "the interrupted window is not answered")
        XCTAssertEqual(session.activeCalls.last, false, "its audio is released while the call has it")

        center.post(name: AVAudioSession.interruptionNotification, object: session.notificationSource,
                    userInfo: [AVAudioSessionInterruptionTypeKey:
                                AVAudioSession.InterruptionType.ended.rawValue])

        XCTAssertTrue(capture.isMicrophoneOpen, "and resumes")
        XCTAssertEqual(device.startCount, 2, "with a fresh window")

        let utterance = try XCTUnwrap(phrase(for: .readAll))
        XCTAssertTrue(device.deliver(.success(utterance)))

        XCTAssertEqual(outcomes, [.command(.readAll)],
                       "one interruption, one window resumed, one command — never two")
    }

    func testAudioFromBeforeTheInterruptionCannotFireACommand() throws {
        let center = NotificationCenter()
        let device = StubDevice()
        let capture = makeCapture(device: device, notifications: center)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }
        // The race: a transcript the recogniser had already harvested reports
        // back as the window is cancelled.
        device.cancellationReportsTranscript = try XCTUnwrap(phrase(for: .close))

        center.post(name: AVAudioSession.interruptionNotification, object: session.notificationSource,
                    userInfo: [AVAudioSessionInterruptionTypeKey:
                                AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertEqual(outcomes, [], "it must not close the session from pre-interruption audio")

        center.post(name: AVAudioSession.interruptionNotification, object: session.notificationSource,
                    userInfo: [AVAudioSessionInterruptionTypeKey:
                                AVAudioSession.InterruptionType.ended.rawValue])
        XCTAssertTrue(device.deliver(.success(try XCTUnwrap(phrase(for: .stopSpeaking)))))

        XCTAssertEqual(outcomes, [.command(.stopSpeaking)],
                       "the pre-interruption audio fired nothing")
    }

    func testANotificationThatIsNotAnInterruptionLeavesCaptureAlone() throws {
        // The falsifiability control: the pause is tied to the interruption
        // notification, not to "any notification arriving".
        let center = NotificationCenter()
        let device = StubDevice()
        let capture = makeCapture(device: device, notifications: center)
        var outcomes: [LiveTranslateCommandCapture.Outcome] = []
        capture.listen { outcomes.append($0) }

        center.post(name: Notification.Name("not.an.interruption"), object: session.notificationSource)

        XCTAssertTrue(capture.isMicrophoneOpen)
        XCTAssertEqual(device.cancelCount, 0)

        let utterance = try XCTUnwrap(phrase(for: .readAll))
        XCTAssertTrue(device.deliver(.success(utterance)))
        XCTAssertEqual(outcomes, [.command(.readAll)])
    }

    // MARK: - Scenario: command audio is never retained or uploaded

    func testTheCaptureHoldsNoTranscriptAndNoAudio() throws {
        let device = StubDevice()
        let capture = makeCapture(device: device)
        capture.listen { _ in }
        let utterance = try XCTUnwrap(phrase(for: .readAll))
        XCTAssertTrue(device.deliver(.success(utterance)))

        // Depth 1 is the object's own state: what it keeps between calls.
        for child in Mirror(reflecting: capture).children {
            let label = child.label ?? "?"
            XCTAssertFalse(child.value is String, "\(label) holds a transcript")
            XCTAssertFalse(child.value is [String], "\(label) holds transcripts")
            XCTAssertFalse(child.value is [String: String], "\(label) holds transcripts")
        }
    }

    func testTheCaptureCannotLogStoreOrSendAnything() {
        let code = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/"
                                    + "LiveTranslateCommandCapture.swift"))
        for symbol in ["ObservabilityBus", "LiveTranslateEvents", "emit(", "print(",
                       "AVAudioFile", "AVAudioEngine", "AVAudioRecorder", "installTap",
                       "AVAudioPCMBuffer", "FileManager", "UserDefaults",
                       "URLSession", "URLRequest", "GeminiClient", "Task {"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: symbol))", in: code),
                         "\(symbol) is reachable from the command capture")
        }
        XCTAssertFalse(code.isEmpty)
    }

    func testNoTranscriptTextReachesAnyEventOrLogRecord() throws {
        // The path this feature's microphone travels has events of its own —
        // the shipped audio session's — and the utterance must appear in none
        // of them. The capture emits nothing at all, which is the structural
        // half of the same claim.
        let center = NotificationCenter()
        let device = SessionDrivingDevice(audioSession: audioManager)
        let capture = makeCapture(device: device, notifications: center)
        capture.listen { _ in }
        let utterance = try XCTUnwrap(phrase(for: .readAll))
        XCTAssertTrue(device.deliver(.success(utterance)))
        center.post(name: AVAudioSession.interruptionNotification, object: session.notificationSource,
                    userInfo: [AVAudioSessionInterruptionTypeKey:
                                AVAudioSession.InterruptionType.began.rawValue])
        capture.close { }

        XCTAssertFalse(bus.events.isEmpty, "the run must emit something to be evidence")
        for event in bus.events {
            var fields = [event.component, event.eventType, event.outcome, event.errorCode ?? ""]
            fields.append(contentsOf: event.metadata.keys)
            fields.append(contentsOf: event.metadata.values)
            XCTAssertFalse(fields.contains { $0.contains(utterance) || $0.contains("read") },
                           "\(event.eventType) carries command audio or transcript")
        }
        XCTAssertEqual(bus.eventTypes.subtracting(["audio_activate", "audio_deactivate"]), [],
                       "the capture has no event vocabulary of its own (T-003)")
    }
}
