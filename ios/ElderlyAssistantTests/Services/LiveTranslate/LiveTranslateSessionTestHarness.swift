import AVFoundation
import Foundation
@testable import ElderlyAssistant

// The session-level doubles and the one composition every live-translate
// suite that needs a whole session builds on: `LiveTranslateSessionModelTests`
// (the session's life over the real components), `SnapshotModeTests` (the
// frozen path) and `LiveTranslatePluginTests` (the plugin's entry, which hands
// a real `LiveTranslateSessionDependencies` to the view).
//
// They live in one file for the reason the feature's own seams do: a second
// copy of a double is a second thing to keep honest. Almost everything here is
// a *platform* seam — the camera layer, the recognition engine, the microphone,
// the audio session and the speech queue — because those are the four things a
// unit-test host cannot provide. The brain is the one exception, and it is here
// for the same reason as the rest: a suite that asserts the *order* of the
// cascade must not have that order's timing decided by whatever assistant
// brains the host happens to hold. Everything else in the composition is the
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
    config: LiveTranslateConfig = .default,
    /// The session's on-device brain.
    ///
    /// **`nil` by default, deliberately.** Production passes nothing and the
    /// pipeline builds the shipped tier, so a suite that says nothing about
    /// the brain keeps the composition production has. A suite whose subject is
    /// the *order* of the cascade hands one in: the shipped tier's ladder ends
    /// at whatever assistant brains the machine holds, and a simulator that has
    /// one installed turns "the device was asked" into a tens-of-seconds 4B
    /// generation that answers nothing — a fact about the simulator, not about
    /// the code under test.
    brain: LocalBrainTranslating? = nil,
    /// The cloud tier's master switch (owner directive, 2026-09-19), written
    /// into the session's own settings suite before the session is built.
    ///
    /// **On by default, and deliberately so.** A real household starts with
    /// the key absent — the switch off — but the suites that come through here
    /// were written about the consent gate, the snapshot path and the
    /// cascade, and each needs the tier reachable for what it asserts to be
    /// the thing under test. `nil` leaves the key absent, which is how a test
    /// exercises the household that has never chosen (the shipped default);
    /// `false` is how a test says the household turned the cloud off.
    geminiCloudEnabled: Bool? = true,
    /// The live-translation master switch (review finding 1), written into the
    /// session's own settings suite before the session is built — the same
    /// seam `geminiCloudEnabled` uses, and for the same reason: the model
    /// reads its settings once, at build time.
    ///
    /// **On by default here, and the shipped default is off.** A household
    /// starts with the key absent and the session therefore refuses to open
    /// (`LiveTranslateSessionModel.start`); the suites that come through this
    /// composition were written about what a *running* session does, so they
    /// opt in here. `nil` leaves the key absent — the household that has never
    /// chosen — and is how a test exercises the refusal; `false` is how a test
    /// says the feature was turned off after the key was set.
    liveTranslateEnabled: Bool? = true) -> LiveTranslateSessionTestParts {

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
    // The switch, written through its declared key before the session reads
    // it — so the value the model opens with is the value the store holds,
    // exactly as the Settings leaf's write reaches a session.
    if let geminiCloudEnabled {
        defaults.set(geminiCloudEnabled, forKey: LiveTranslateSettings.geminiCloudEnabledKey)
    }
    // The live-translation switch, written the same way: absent means the
    // household has never chosen, which is the shipped default (off).
    if let liveTranslateEnabled {
        defaults.set(liveTranslateEnabled, forKey: LiveTranslateSettings.liveTranslateEnabledKey)
    }

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
        brain: brain,
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

/// Tier 1, scripted — the on-device brain the pipeline asks before the
/// cloud. It stands in for `LocalBrainTranslationTier` at the same seam
/// the pipeline actually takes (`LocalBrainTranslating`), so what a suite
/// that hands one in pins is the *cascade*: which tier answers, in what
/// order, and what reaches the gate.
///
/// It lives here rather than beside one of its callers because two suites
/// take it at that seam — `LiveTranslationPipelineTests` (the cascade as a
/// whole) and `SnapshotModeTests` (the frozen path through the same plan).
/// It is also what keeps those suites honest about *time*: the shipped tier
/// ends at whatever assistant brains the host holds, and a host that holds a
/// 4B one answers "the device was asked" with a tens-of-seconds generation
/// that returns nothing. A scripted brain says what the device is, so the
/// assertion is about the code and not about the machine the test runs on.
///
/// It emits through the shipped event API when it reports itself
/// unavailable, exactly as the real tier does, so the pipeline-level
/// claim "no brain, event, and on to the cloud" is made against the real
/// vocabulary rather than against a fake's own invention.
///
/// A class with a lock rather than an actor, so the harness can wire it up
/// and the tests can read what it was asked without an `await` at every
/// call site: the pipeline is the only writer that matters, and it awaits
/// one attempt at a time.
final class RecordingBrain: LocalBrainTranslating, @unchecked Sendable {

    private let lock = NSLock()
    private var storedAnswers: [String: String] = [:]
    private var storedUnavailable = false
    private var storedHangs = false
    private var storedCalls: [[String]] = []
    private var storedReleaseCount = 0
    private var storedHeldCalls = 0
    private var storedGateIsOpen = false
    private var storedThroughGate = 0
    private var storedAnswered = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var events: LiveTranslateEvents?

    /// The strings this brain answers, and what it answers with.
    var answers: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return storedAnswers }
        set { lock.lock(); defer { lock.unlock() }; storedAnswers = newValue }
    }

    /// When true, every attempt reports itself unusable, the way the real
    /// tier does on a device with no model installed.
    var unavailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedUnavailable }
        set { lock.lock(); defer { lock.unlock() }; storedUnavailable = newValue }
    }

    /// When true, the generation never comes back on its own: it sleeps
    /// until it is cancelled. The shape of a 4B decode that is still
    /// thinking — or stuck — when the stage deadline passes.
    var hangs: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedHangs }
        set { lock.lock(); defer { lock.unlock() }; storedHangs = newValue }
    }

    /// **The generation gate.** The next `heldCalls` generations are *held*
    /// rather than answered: each suspends until the test lets it through. A
    /// scripted *answer* says what the device is; a gate says *when* it is —
    /// which is what a test that needs two reads in flight at once, in a known
    /// order and with no wall clock, needs. Held calls are released oldest
    /// first, so the order the caller scripted the taps in is the order they
    /// come back in.
    var heldCalls: Int {
        get { lock.lock(); defer { lock.unlock() }; return storedHeldCalls }
        set { lock.lock(); defer { lock.unlock() }; storedHeldCalls = newValue }
    }

    /// Generations suspended at the gate right now — the *arrival* signal, so
    /// a test can know a read has reached the device without waiting for a
    /// duration.
    var waitingAtGate: Int {
        lock.lock(); defer { lock.unlock() }; return gateWaiters.count
    }

    /// Generations that came back *through* the gate: the positive half of the
    /// same seam — an answer was returned, so the stage it was asked by ran.
    var generationsThroughTheGate: Int {
        lock.lock(); defer { lock.unlock() }; return storedThroughGate
    }

    /// Lets the **oldest** held generation through: one at a time, so a test
    /// can finish the read it superseded while the read that replaced it is
    /// still held.
    func releaseOneHeldCall() {
        lock.lock()
        let next = gateWaiters.isEmpty ? nil : gateWaiters.removeFirst()
        lock.unlock()
        next?.resume()
    }

    /// Lets every held generation through, now and later. The teardown escape
    /// hatch: a test that ends with a read still held would otherwise leave
    /// that work suspended for the life of the process.
    func openGate() {
        lock.lock()
        storedGateIsOpen = true
        let waiting = gateWaiters
        gateWaiters = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// Every batch this brain was handed, in order.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }; return storedCalls
    }

    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }; return storedReleaseCount
    }

    /// The harness wires this to the bus it built, so an unavailable
    /// brain is reported on the pipeline's own channel with the shipped
    /// emitter rather than a vocabulary of the fake's own.
    func attach(events: LiveTranslateEvents) {
        lock.lock(); defer { lock.unlock() }
        self.events = events
    }

    /// Generations that have **come back** — answered, refused, or released
    /// from the gate. `calls` says what was asked; this says how much of it is
    /// done, which is what a test needs before it arms a gate: a call still in
    /// flight is a generation another test could hand a hold to.
    var generationsAnswered: Int {
        lock.lock(); defer { lock.unlock() }; return storedAnswered
    }

    func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome {
        let outcome = await answer(strings)
        lock.lock(); storedAnswered += 1; lock.unlock()
        return outcome
    }

    private func answer(_ strings: [String]) async -> LocalBrainTranslationOutcome {
        lock.lock()
        storedCalls.append(strings)
        let answers = storedAnswers
        let unavailable = storedUnavailable
        let hangs = storedHangs
        let events = self.events
        var held = false
        if storedHeldCalls > 0 {
            storedHeldCalls -= 1
            held = true
        }
        lock.unlock()

        if held { await awaitTheGate() }

        if hangs {
            // Cancellation-aware, like a real generation: the pipeline
            // cancels the stage when its deadline passes, so this returns
            // into nothing rather than blocking the test.
            try? await Task<Never, Never>.sleep(for: .seconds(30))
            return .none
        }

        guard !unavailable else {
            events?.brainTranslationUnavailable(.modelNotInstalled, stage: .availability)
            return .none
        }
        var translations: [String: String] = [:]
        for text in strings {
            if let answer = answers[text] { translations[text] = answer }
        }
        return LocalBrainTranslationOutcome(translations: translations, durationMs: 1)
    }

    func release() async {
        lock.lock(); defer { lock.unlock() }
        storedReleaseCount += 1
    }

    /// Suspends a held generation until a test releases it — or the gate is
    /// opened for everyone. The continuation is resumed outside the lock: what
    /// it wakes runs on this thread until its next suspension point, and a
    /// woken caller that reached for the lock again would deadlock.
    private func awaitTheGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if storedGateIsOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            gateWaiters.append(continuation)
            lock.unlock()
        }
        lock.lock(); storedThroughGate += 1; lock.unlock()
    }
}

