import AVFoundation
import Foundation
@testable import ElderlyAssistant

// The session-level doubles and the one composition both TG-09 suites build
// on: `LiveTranslateSessionModelTests` (the session's life over the real
// components) and `LiveTranslatePluginTests` (the plugin's entry, which hands
// a real `LiveTranslateSessionDependencies` to the view).
//
// They live in one file for the reason the feature's own seams do: a second
// copy of a double is a second thing to keep honest. Everything here is a
// *platform* seam — the camera layer, the recognition engine, the microphone,
// the audio session and the speech queue — because those are the four things a
// unit-test host cannot provide. Everything else in the composition is the
// shipped type.

/// One ordered log shared by the doubles that take part in an ordering
/// assertion, so teardown reads as a sequence rather than as a set of
/// unrelated counts. Guarded: the camera's teardown hops to its capture queue
/// while the rest of the teardown runs on the main actor.
final class SessionLog {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func count(of entry: String) -> Int { all.filter { $0 == entry }.count }

    func index(of entry: String) -> Int? { all.firstIndex(of: entry) }
}

/// The clock both the capture session's cadence and the detector's pass
/// cadence read, advanced by the test so a delivered frame is due.
final class SessionClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    func advance(_ interval: TimeInterval = 1) {
        lock.lock(); time += interval; lock.unlock()
    }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return time
    }
}

/// T-006's capture layer, stubbed: the same narrow protocol the shipped
/// AVFoundation layer implements, logging every lifecycle call and holding the
/// sample-buffer sink so a test can deliver a real frame.
final class SessionCaptureLayer: LiveCameraCaptureLayer {
    let session = AVCaptureSession()
    var authorizationStatus: CameraAuthorizationStatus = .granted
    var thermalState: ProcessInfo.ThermalState = .nominal
    var configurationError: LiveTranslateError?

    private let log: SessionLog
    private let lock = NSLock()
    private var sink: ((CMSampleBuffer) -> Void)?
    private var running = false

    init(log: SessionLog) { self.log = log }

    func requestAccess() async -> Bool { true }

    func configureVideoOnly(onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
                            queue: DispatchQueue) throws {
        if let configurationError { throw configurationError }
        lock.lock(); sink = onSampleBuffer; lock.unlock()
        log.append("camera.configure")
    }

    func startRunning() {
        lock.lock(); running = true; lock.unlock()
        log.append("camera.start")
    }

    func stopRunning() {
        lock.lock(); running = false; lock.unlock()
        log.append("camera.stop")
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); let sink = self.sink; lock.unlock()
        sink?(sampleBuffer)
    }

    // MARK: Zoom and focus (owner report, 2026-09-17)

    /// The harness's device is a single-lens one: the pipeline tests are about
    /// recognition and translation, and a device that reports switch-over
    /// factors would only be scenery here. (The zoom *maths* is where switching
    /// is exercised — `LiveCameraZoomModelTests` — and the seam's calls are
    /// logged here for the ones that touch them.)
    var zoomCapabilities = CameraZoomCapabilities.unknown
    var videoZoomFactor: Double = 1
    var supportsFocusPointOfInterest = true

    @discardableResult
    func setVideoZoomFactor(_ factor: Double) -> Double {
        videoZoomFactor = factor
        log.append("camera.zoom")
        return factor
    }

    func focus(atDevicePoint point: CGPoint) {
        log.append("camera.focus")
    }

    func focusContinuously(atDevicePoint point: CGPoint) {
        log.append("camera.focusContinuously")
    }

    func setFocusLocked(_ locked: Bool) {
        log.append("camera.focusLock")
    }

    func observeSubjectAreaChanges(_ handler: @escaping () -> Void) {}
}

/// T-007's recognition seam, stubbed: scripted regions, logged lifecycle.
final class SessionRecognitionEngine: LiveTextRecognitionEngine {
    var supportsTracking = true
    var regions: [LiveTextDetector.DetectedTextRegion] = []
    var trackedBoxes: [String: NormalizedBox] = [:]
    var errorToThrow: Error?

    private let log: SessionLog
    private let lock = NSLock()
    private var calls = 0
    private var forgets = 0

    init(log: SessionLog) { self.log = log }

    var recognizeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var forgetCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return forgets
    }

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        lock.lock(); calls += 1; lock.unlock()
        log.append("detector.pass")
        if let errorToThrow { throw errorToThrow }
        return regions
    }

    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox] {
        trackedBoxes
    }

    func forgetRememberedRectangles() {
        lock.lock(); forgets += 1; lock.unlock()
        log.append("detector.forget")
    }
}

/// The object seam, scripted: the detector asks this for the scene's objects
/// instead of paying for a real saliency + classification pass.
///
/// Every test that scripts recognition scripts this too, even when it has no
/// objects to give: a scripted test's whole value is that a pass is decided by
/// the fixture, and a real Vision request would put the simulator's opinion of
/// a synthetic buffer into the result.
final class StubObjectDetectionEngine: LiveObjectDetectionEngine {
    var supportsObjectDetection: Bool
    var objects: [LiveTextDetector.DetectedSceneObject] = []
    var errorToThrow: Error?

    /// Run at the start of every detection, before anything else. A test that
    /// wants an object pass that is *slow* — the shape a device's first
    /// saliency request has, and the one the text path must not wait for —
    /// hands the detector a verdict through here and blocks on its own
    /// semaphore, which is what makes "the text pass did not wait" an
    /// observation rather than a wall-clock guess.
    var onDetect: ((CVPixelBuffer) -> Void)?

    private let lock = NSLock()
    private var calls = 0
    private var completed = 0

    init(supportsObjectDetection: Bool = true) {
        self.supportsObjectDetection = supportsObjectDetection
    }

    var detectCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    /// Detections that have returned — answered or refused. The gap between
    /// this and `detectCallCount` is an object pass still in flight.
    var completedDetections: Int {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedSceneObject] {
        lock.lock(); calls += 1; lock.unlock()
        onDetect?(pixelBuffer)
        lock.lock(); completed += 1; lock.unlock()
        if let errorToThrow { throw errorToThrow }
        return objects
    }
}

/// The shipped speech path, narrowed to what C12 uses and logged.
final class SessionSpeechPath: LiveTranslateSpeechPath {
    private let log: SessionLog
    private let lock = NSLock()
    private var spoken: [Announcement] = []
    private var speaking = false

    init(log: SessionLog) { self.log = log }

    func enqueue(_ announcement: Announcement) {
        lock.lock(); spoken.append(announcement); lock.unlock()
        log.append("speech.enqueue")
    }

    func drain(sourceID: String) {
        log.append("speech.drain")
        lock.lock(); spoken.removeAll { $0.sourceID == sourceID }; lock.unlock()
    }

    func isSpeaking(sourceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return speaking
    }

    var spokenTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return spoken.map(\.text)
    }

    var drainCount: Int { log.count(of: "speech.drain") }

    func setSpeaking(_ value: Bool) {
        lock.lock(); speaking = value; lock.unlock()
    }
}

/// The shipped one-shot microphone, hand-driven: one window at a time, one
/// completion per window, logged.
final class SessionDevice: LiveTranslateUtteranceCapturing {
    private let log: SessionLog
    private let lock = NSLock()
    private var completion: ((Result<String, SearchPhraseCapture.Failure>) -> Void)?
    private var starts = 0
    private var cancels = 0

    init(log: SessionLog) { self.log = log }

    func start(completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) {
        lock.lock(); starts += 1; self.completion = completion; lock.unlock()
        log.append("device.start")
    }

    func cancel() {
        lock.lock()
        cancels += 1
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        log.append("device.cancel")
        completion?(.failure(.cancelled))
    }

    /// Reports an outcome from the open window, exactly as the shipped
    /// capture reports one.
    func report(_ result: Result<String, SearchPhraseCapture.Failure>) {
        lock.lock(); let completion = self.completion; self.completion = nil; lock.unlock()
        completion?(result)
    }

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    var cancelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancels
    }

    var hasOpenWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return completion != nil
    }
}

/// `AudioSessionControlling`, stubbed: the real `AudioSessionManager` drives
/// it, so the calls a test reads are the ones the shipped manager makes.
final class SessionAudioSession: AudioSessionControlling {
    private let log: SessionLog

    init(log: SessionLog) { self.log = log }

    var isInputAvailable = true
    var notificationSource: AnyObject? { nil }

    func requestRecordPermission(_ callback: @escaping (Bool) -> Void) { callback(true) }

    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {}

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        log.append(active ? "audio.active" : "audio.inactive")
    }

    func setMode(_ mode: AVAudioSession.Mode) throws {}

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
}

/// A composed test session: the dependency value the model (and the plugin's
/// view) is built from, plus every double and real component it was composed
/// from, so a test can assert both sides.
struct LiveTranslateSessionTestParts {
    let dependencies: LiveTranslateSessionDependencies
    let camera: LiveCameraSession
    let capture: SessionCaptureLayer
    let detector: LiveTextDetector
    let engine: SessionRecognitionEngine
    /// The scripted object seam the detector was built with, so a test can
    /// decide what the scene's objects are (and count the passes that asked).
    let objects: StubObjectDetectionEngine
    let speech: SessionSpeechPath
    let device: SessionDevice
    let audio: SessionAudioSession
    let cache: LabelTranslationCache
    let gate: LiveTranslateConsentGate
    let governor: GeminiCostGovernor
    let client: GeminiClient
    let transport: TierTranslationTransport
    let notifications: NotificationCenter
    let bus: LiveTranslateSanitisingBus
    let log: SessionLog
    let clock: SessionClock
    let defaults: UserDefaults
    /// The `UserDefaults` suite this composition owns; the caller removes its
    /// persistent domain in teardown.
    let suiteName: String
}

/// The production composition, with only the platform seams doubled. Every
/// store is separate, so a fault injected into one is provably a fault in
/// that one component — and lifecycle notifications go to a centre the test
/// owns, so a real app notification cannot perturb a run.
@MainActor
func makeLiveTranslateSessionTestParts(
    authorization: CameraAuthorizationStatus = .granted,
    consent: Bool = false,
    configured: Bool = false,
    configurationError: LiveTranslateError? = nil,
    dictionary: [String: String] = [:],
    transport: TierTranslationTransport = TierTranslationTransport(),
    locale: Locale = Locale(identifier: "ne-NP"),
    extractMode: Bool = false,
    config: LiveTranslateConfig = .default) -> LiveTranslateSessionTestParts {

    // A session opens showing the *recognized text* — that is the shipped
    // default (owner verdict, 2026-09-18) and it is pinned as one, by
    // `LiveTranslateConfigTests` for the value and by the extract-mode tests
    // for the behaviour. The suites that pre-date the rework are about the
    // translated view, so they opt out here rather than each carrying a copy of
    // the same opt-out; a suite that wants the shipped default asks for it.
    var config = config
    config.extractModeDefault = extractMode

    let suiteName = "livetranslate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let log = SessionLog()
    let clock = SessionClock()
    let bus = LiveTranslateSanitisingBus()
    let notifications = NotificationCenter()
    let storage = LabelTranslationCacheTestStorage()
    let configStore = GeminiConfigStore(storage: storage)
    if configured { configStore.save("fake-key") }
    let gate = LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus)
    if consent { _ = gate.record(granted: true) }
    let governor = GeminiCostGovernor(storage: storage, observabilityBus: bus)
    let cache = LabelTranslationCache(storage: LabelTranslationCacheTestStorage(),
                                      config: config,
                                      observabilityBus: bus,
                                      dictionary: dictionary)
    let client = GeminiClient(configStore: configStore,
                              observabilityBus: bus,
                              transport: transport,
                              costGovernor: governor)

    let capture = SessionCaptureLayer(log: log)
    capture.authorizationStatus = authorization
    capture.configurationError = configurationError
    let camera = LiveCameraSession(config: config,
                                   observabilityBus: bus,
                                   capture: capture,
                                   notificationCenter: notifications,
                                   now: { clock.now })
    let engine = SessionRecognitionEngine(log: log)
    let objects = StubObjectDetectionEngine()
    let detector = LiveTextDetector(config: config,
                                    observabilityBus: bus,
                                    engine: engine,
                                    objectEngine: objects,
                                    now: { clock.now })
    let speech = SessionSpeechPath(log: log)
    let device = SessionDevice(log: log)
    let audio = SessionAudioSession(log: log)

    let dependencies = LiveTranslateSessionDependencies(
        locale: locale,
        camera: camera,
        detector: detector,
        cache: cache,
        consentGate: gate,
        costGovernor: governor,
        client: client,
        speechPath: speech,
        captureDevice: device,
        audioSession: AudioSessionManager(observabilityBus: bus,
                                          audioSession: audio,
                                          defaults: defaults),
        settings: LiveTranslateSettings(defaults: defaults),
        notifications: notifications,
        observabilityBus: bus,
        config: config)

    return LiveTranslateSessionTestParts(dependencies: dependencies,
                                         camera: camera,
                                         capture: capture,
                                         detector: detector,
                                         engine: engine,
                                         objects: objects,
                                         speech: speech,
                                         device: device,
                                         audio: audio,
                                         cache: cache,
                                         gate: gate,
                                         governor: governor,
                                         client: client,
                                         transport: transport,
                                         notifications: notifications,
                                         bus: bus,
                                         log: log,
                                         clock: clock,
                                         defaults: defaults,
                                         suiteName: suiteName)
}
