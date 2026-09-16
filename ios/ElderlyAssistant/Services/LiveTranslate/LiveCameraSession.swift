import AVFoundation
import CoreMedia
import Foundation
import UIKit

// C01 — the capture stack (T-006, FR-LCT-001/002, NFR-LCT-002/005).
//
// What this file exists to make true:
//
//  - **Video data output only.** The capture session is configured with one
//    `AVCaptureVideoDataOutput` and nothing else. There is no photo output, no
//    picker, and no code path here that writes a frame to the photo library,
//    app storage or a temporary file. The absence is structural: the capture
//    layer's protocol has no entry point that could construct a photo output,
//    and `LiveCameraCaptureGuaranteeTests` scans these sources for the APIs
//    that would be needed to write one.
//  - **Drop, not queue.** The frame tap throttles samples to the configured
//    `ocrSampleInterval` and, while an OCR pass is in flight, **drops** every
//    sample instead of queueing it. That single rule is simultaneously the
//    OCR cadence control and the memory bound (NFR-LCT-002): the effective
//    rate degrades under load, and at most one frame is ever buffered.
//  - **Never running in the background.** Backgrounding (or a system
//    interruption) pauses the session; the next foreground transition resumes
//    it at most once. A torn-down session is never restarted implicitly.
//
// Everything AVFoundation-, UIKit- and device-shaped sits behind
// `LiveCameraCaptureLayer`, so this policy is testable against a stubbed
// capture layer on a machine with no camera at all.

// MARK: - Frame

/// One sampled frame: an in-memory, downscaled pixel buffer with its pixel
/// size and capture timestamp. It is consumed by the detection pass and
/// released — nothing retains it beyond the pass and nothing writes it
/// anywhere (NFR-LCT-005).
struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let pixelSize: CGSize
    let timestamp: CMTime
}

extension CameraFrame {
    /// Reads a frame's geometry out of a delivered sample buffer. The buffer
    /// is the one `AVCaptureVideoDataOutput` produced under `videoSettings`,
    /// so it is already downscaled, and it is retained only by this value.
    init?(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        self.pixelBuffer = pixelBuffer
        self.pixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        self.timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
}

// MARK: - Permission

/// The camera authorization states this feature distinguishes. One case per
/// outcome the elder's surface can be in (T-008): asking is not the same as
/// being refused, and it is the caller's job to explain before the system
/// prompt appears.
enum CameraAuthorizationStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

// MARK: - Capture layer seam

/// C01's seam. Everything the session needs from AVFoundation, UIKit and the
/// device, expressed in the session's own vocabulary — so the session's policy
/// (permission mapping, the drop-not-queue cadence, the thermal response and
/// the background/foreground lifecycle) is exercised against a stubbed capture
/// layer in tests, with no camera, no device and no simulator camera support.
///
/// Deliberately narrow: there is **no** entry point for a photo output, a
/// movie file output or a picker anywhere in this protocol, so FR-LCT-001's
/// "no photo output is constructed" is absence-by-API rather than a promise.
protocol LiveCameraCaptureLayer: AnyObject {
    /// The session object the preview layer is built over. It exists even on a
    /// device with no camera, so the preview surface is never missing.
    var session: AVCaptureSession { get }

    var authorizationStatus: CameraAuthorizationStatus { get }
    func requestAccess() async -> Bool

    /// Builds the capture graph and starts it: exactly one
    /// `AVCaptureVideoDataOutput` feeding `onSampleBuffer` on `queue`.
    ///
    /// Throws `LiveTranslateError.cameraUnavailable(...)` — `.noCaptureDevice`
    /// when the device has no camera, `.resourceInUse` when it cannot be
    /// opened, `.configurationFailed` when the graph cannot be assembled. The
    /// caller never retries these in process (failure table row 1).
    func configureVideoOnly(onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
                            queue: DispatchQueue) throws

    func startRunning()
    func stopRunning()
    var isRunning: Bool { get }

    /// `ProcessInfo.processInfo.thermalState`, read through the seam so the
    /// cadence response is testable without heating a device.
    var thermalState: ProcessInfo.ThermalState { get }
}

/// The shipped capture layer. One `AVCaptureVideoDataOutput`, no photo output,
/// no file output, no picker.
final class AVFoundationCaptureLayer: NSObject, LiveCameraCaptureLayer {

    let session = AVCaptureSession()

    /// The device lookup, injectable so a test can exercise the no-camera path
    /// without unplugging anything.
    private let deviceProvider: () -> AVCaptureDevice?

    private var sink: ((CMSampleBuffer) -> Void)?
    private var isConfigured = false

    init(deviceProvider: @escaping () -> AVCaptureDevice? = { AVCaptureDevice.default(for: .video) }) {
        self.deviceProvider = deviceProvider
        super.init()
    }

    var authorizationStatus: CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            // `restricted` is "the system will not grant this to this user now"
            // (parental controls, MDM). The feature's taxonomy has one case for
            // a refusal and the recovery is the same shape: the elder cannot
            // fix it from this screen. The reason is not re-derived in the view.
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func configureVideoOnly(onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
                            queue: DispatchQueue) throws {
        guard !isConfigured else { return }
        guard let device = deviceProvider() else {
            throw LiveTranslateError.cameraUnavailable(.noCaptureDevice)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            // The device exists but cannot be opened — another client holds it,
            // or the system refused it. Neither is fixable in process.
            throw LiveTranslateError.cameraUnavailable(.resourceInUse)
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            // The frame is downscaled by the platform's own preset rather than
            // by a size this feature invents: the design fixes "downscaled",
            // and the OCR cadence/quality trade-off is OD1's device spike, not
            // a number buried here.
            session.sessionPreset = .vga640x480
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw LiveTranslateError.cameraUnavailable(.configurationFailed)
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_32BGRA)]
        // The device-side half of the drop rule: a frame that is late for the
        // consumer is discarded by the output rather than accumulated.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw LiveTranslateError.cameraUnavailable(.configurationFailed)
        }
        session.addOutput(output)
        session.commitConfiguration()

        sink = onSampleBuffer
        isConfigured = true
    }

    func startRunning() { session.startRunning() }
    func stopRunning() { session.stopRunning() }
    var isRunning: Bool { session.isRunning }
    var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

extension AVFoundationCaptureLayer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sink?(sampleBuffer)
    }
}

// MARK: - Session

/// Owns the capture stack: the preview surface, the frame stream, the cadence
/// and the lifecycle.
///
/// Isolation. Every session *mutation* (configure, start, stop, pause) runs on
/// one serial capture queue. The tap's cadence state (the last accepted sample,
/// the pass-in-flight flag) is guarded by a lock, because it is written by the
/// consumer and read on the video-output queue. Nothing else is shared.
///
/// Lifetime. A session is single-use: `stop()` tears the capture stack and the
/// frame stream down for good. Starting a stopped session is reported as a
/// failure rather than silently ignored — the caller builds a new session (the
/// session view does exactly that per presentation, T-027).
final class LiveCameraSession {

    /// The session's lifecycle state. `.interrupted` carries *why* the capture
    /// stopped, so the caller can say what it is recovering from instead of
    /// showing an unexplained blank preview.
    enum State: Equatable {
        case idle
        case starting
        case running
        case interrupted(CameraInterruption)
        case stopped
        case failed(LiveTranslateError)
    }

    // MARK: Dependencies

    let config: LiveTranslateConfig
    private let events: LiveTranslateEvents
    private let capture: LiveCameraCaptureLayer
    private let notificationCenter: NotificationCenter
    private let now: () -> TimeInterval

    private let captureQueue = DispatchQueue(label: "com.elderlyassistant.livetranslate.capture")
    private let videoOutputQueue = DispatchQueue(label: "com.elderlyassistant.livetranslate.video")
    private let captureQueueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()

    // MARK: State (lock-guarded)

    private var currentState: State = .idle
    private var observers: [NSObjectProtocol] = []
    private var lastSampledAt: TimeInterval?
    private var passInFlight = false
    private var explanationOffered = false
    private var startHasRun = false
    private var pendingInterruption: CameraInterruption?

    private let stream: AsyncStream<CameraFrame>
    private var continuation: AsyncStream<CameraFrame>.Continuation?

    // MARK: Init

    init(config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         capture: LiveCameraCaptureLayer = AVFoundationCaptureLayer(),
         notificationCenter: NotificationCenter = .default,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.capture = capture
        self.notificationCenter = notificationCenter
        self.now = now

        var capturedContinuation: AsyncStream<CameraFrame>.Continuation?
        // `bufferingNewest(1)` is the second half of the memory bound: even if a
        // consumer stops pulling, at most one frame is held, and a newer sample
        // replaces it rather than joining a queue.
        self.stream = AsyncStream<CameraFrame>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    // MARK: Observation

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    /// The frames the detection pass consumes, in memory, newest-only.
    var frames: AsyncStream<CameraFrame> { stream }

    /// The consumer's pass-in-flight signal (T-026's backpressure flag): while
    /// it is `true` the tap drops samples rather than queueing them. Written by
    /// the pipeline that owns the pass, read here on the video-output queue.
    var ocrPassInFlight: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return passInFlight
        }
        set {
            lock.lock(); defer { lock.unlock() }
            passInFlight = newValue
        }
    }

    /// The tap's interval after the thermal response (NFR-LCT-002 scenario 3):
    /// at or above the configured threshold the cadence slows by the configured
    /// factor, so a hot device degrades instead of stopping.
    var effectiveSampleInterval: TimeInterval {
        let thermal = capture.thermalState
        let reduced = thermal.rawValue >= config.thermalStateThreshold.rawValue
        return reduced ? config.ocrSampleInterval * config.thermalCadenceFactor
                       : config.ocrSampleInterval
    }

    // MARK: Preview

    /// The full-bleed preview surface: the capture session's own layer with
    /// **aspect-fit** gravity (`.resizeAspect`). The gravity is load-bearing —
    /// it is what lets the shipped `ApplianceOverlayMapper` aspect-fit maths
    /// apply to the overlay unchanged (NFR-LCT-012). Do not change it to fill.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspect
        return layer
    }

    // MARK: Start

    /// Starts capture, asking for the camera only when it is already the right
    /// moment to (FR-LCT-002).
    ///
    /// The permission contract is deliberate and two-step: the first call with
    /// permission not yet determined returns `.cameraPermissionNotDetermined`
    /// **without showing the system prompt**, so the caller can explain the use
    /// in the elder's own language first; the call the caller makes after the
    /// elder continues raises the system prompt. A refusal, a missing device
    /// and a failed configuration each return their own explicit result and are
    /// never retried in process.
    func start() async -> Result<Void, LiveTranslateError> {
        switch state {
        case .running:
            return .success(())
        case .stopped:
            // Rebuilding a torn-down capture stack behind the caller's back
            // would resurrect a stream nobody holds. Report it and let the
            // caller build a new session.
            return .failure(.cameraUnavailable(.configurationFailed))
        default:
            break
        }

        switch capture.authorizationStatus {
        case .granted:
            break

        case .denied:
            setState(.failed(.cameraPermissionDenied))
            events.cameraDenied()
            return .failure(.cameraPermissionDenied)

        case .notDetermined:
            let alreadyExplained: Bool = withLock {
                if explanationOffered { return true }
                explanationOffered = true
                return false
            }
            guard alreadyExplained else {
                // The elder has not been told what the camera is for yet. The
                // caller shows the explanation and re-calls `start()` (T-008);
                // capture does not begin here, and no frame is requested.
                return .failure(.cameraPermissionNotDetermined)
            }
            let granted = await capture.requestAccess()
            // The caller may have closed the view while the prompt was up.
            if state == .stopped {
                return .failure(.cameraUnavailable(.configurationFailed))
            }
            guard granted else {
                setState(.failed(.cameraPermissionDenied))
                events.cameraDenied()
                return .failure(.cameraPermissionDenied)
            }
        }

        setState(.starting)
        do {
            try onCaptureQueue {
                try capture.configureVideoOnly(onSampleBuffer: { [weak self] sampleBuffer in
                    self?.sampleArrived(sampleBuffer)
                }, queue: videoOutputQueue)
            }
        } catch let error as LiveTranslateError {
            setState(.failed(error))
            if case .cameraUnavailable(let reason) = error { events.cameraUnavailable(reason) }
            return .failure(error)
        } catch {
            let failure = LiveTranslateError.cameraUnavailable(.configurationFailed)
            setState(.failed(failure))
            events.cameraUnavailable(.configurationFailed)
            return .failure(failure)
        }

        registerLifecycleObservers()
        onCaptureQueue { capture.startRunning() }
        withLock { startHasRun = true }
        setState(.running)
        events.sessionStarted()

        // An interruption that arrived while the session was starting is
        // applied now: the session must not begin running in the background.
        if let interruption = withLock({ let pending = pendingInterruption; pendingInterruption = nil; return pending }) {
            _ = pause(interruption)
        }
        return .success(())
    }

    // MARK: Pause / resume

    /// Pauses capture for a stated reason. Idempotent: pausing a session that
    /// is already paused (or not yet running) is not an error.
    @discardableResult
    func pause(_ reason: CameraInterruption = .backgrounded) -> Result<Void, LiveTranslateError> {
        switch state {
        case .running:
            onCaptureQueue { capture.stopRunning() }
            setState(.interrupted(reason))
            events.cameraInterrupted(reason)
            return .success(())

        case .starting:
            // The start is in flight; record the interruption and let the
            // completed start apply it. Nothing runs in the background.
            withLock { pendingInterruption = reason }
            return .success(())

        case .interrupted:
            return .success(())

        case .idle:
            // Nothing is running yet: there is nothing to pause, and `start()`
            // is still the caller's next step.
            return .success(())

        case .failed(let error):
            return .failure(error)

        case .stopped:
            return .failure(.cameraUnavailable(.configurationFailed))
        }
    }

    /// Resumes a paused session — the retry the design allows, driven by the
    /// foreground transition (failure table row 2). Resuming is bounded: only a
    /// session that is actually interrupted resumes, so a repeated foreground
    /// signal cannot start a loop.
    func resume() async -> Result<Void, LiveTranslateError> {
        resumeInterruptedCapture()
    }

    /// The synchronous core of `resume()`. The foreground observer calls this
    /// directly rather than detaching a task, so "one resume per foreground
    /// transition" is an ordering the caller can observe, not a race.
    private func resumeInterruptedCapture() -> Result<Void, LiveTranslateError> {
        switch state {
        case .interrupted(let reason):
            onCaptureQueue { capture.startRunning() }
            setState(.running)
            events.cameraResumed(recoveringFrom: reason)
            return .success(())

        case .running:
            return .success(())

        case .failed(let error):
            return .failure(error)

        case .idle, .starting, .stopped:
            // There is no paused capture to resume. Reported rather than
            // silently claiming a running session (the taxonomy has no
            // dedicated "not running" token; the caller's recovery is `start()`
            // on a fresh session).
            return .failure(.cameraUnavailable(.configurationFailed))
        }
    }

    // MARK: Stop

    /// Tears the session down for good: capture stops, every observer is
    /// removed and the frame stream finishes. Nothing outlives the view.
    func stop() {
        let teardown: (observers: [NSObjectProtocol],
                       continuation: AsyncStream<CameraFrame>.Continuation?,
                       announced: Bool)? = withLock {
            // Idempotent: a second stop has nothing left to tear down.
            guard currentState != .stopped else { return nil }
            let announced = startHasRun
            startHasRun = false
            explanationOffered = false
            pendingInterruption = nil
            lastSampledAt = nil
            passInFlight = false
            currentState = .stopped
            let removed = observers
            observers = []
            return (removed, continuation, announced)
        }
        guard let teardown else { return }

        for observer in teardown.observers {
            notificationCenter.removeObserver(observer)
        }
        teardown.continuation?.finish()
        // A session that never started has a capture stack that was never
        // started either: stopping it would be a state transition on nothing,
        // and it would announce an end for a session that never existed.
        if teardown.announced {
            onCaptureQueue { capture.stopRunning() }
            events.sessionEnded()
        }
    }

    // MARK: Frame tap

    /// The tap. Runs on the video-output queue (or, in tests, on whichever
    /// thread delivered the sample) and is the whole cadence policy:
    ///
    ///  1. a sample that arrives while the session is not running drops — a
    ///     capture stack that has been paused or torn down must not show a
    ///     frame the elder has already left, and a sample already in flight
    ///     when `stopRunning()` lands still arrives here;
    ///  2. a pass in flight drops the sample — no queue, no backlog;
    ///  3. a sample inside the (thermal-adjusted) interval is dropped;
    ///  4. otherwise the frame is yielded to the stream, which itself holds at
    ///     most one frame.
    private func sampleArrived(_ sampleBuffer: CMSampleBuffer) {
        guard let frame = CameraFrame(sampleBuffer: sampleBuffer) else { return }

        let accepted: AsyncStream<CameraFrame>.Continuation? = withLock {
            guard currentState == .running else { return nil }
            guard !passInFlight else { return nil }
            let interval = effectiveSampleInterval
            let timestamp = now()
            if let last = lastSampledAt, timestamp - last < interval { return nil }
            lastSampledAt = timestamp
            return continuation
        }
        accepted?.yield(frame)
    }

    // MARK: Lifecycle observers

    private func registerLifecycleObservers() {
        // Registering twice (two successful starts on one session) would double
        // every transition, so it is guarded rather than relied upon.
        let alreadyRegistered = withLock { !observers.isEmpty }
        guard !alreadyRegistered else { return }

        var registered: [NSObjectProtocol] = []

        registered.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.pause(.backgrounded)
            })

        registered.append(notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                // One resume per foreground transition: only an interrupted
                // session resumes, so a second signal is a no-op rather than a
                // second start.
                guard case .interrupted = self.state else { return }
                _ = self.resumeInterruptedCapture()
            })

        registered.append(notificationCenter.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: capture.session, queue: nil) { [weak self] notification in
                guard let self else { return }
                // The system stopping capture is a degradation the elder can
                // see (the view renders `.interrupted`); it is never a silent
                // stall. The interruption's end is not resumed from here: the
                // foreground transition is the one resume path (failure table
                // row 2).
                _ = self.pause(Self.interruptionReason(from: notification))
            })

        withLock { observers.append(contentsOf: registered) }
    }

    /// Maps `AVCaptureSession`'s interruption reason onto the feature's closed
    /// vocabulary, so the event and the view say the same thing.
    private static func interruptionReason(from notification: Notification) -> CameraInterruption {
        let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        guard let raw, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return .systemInterruption
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return .backgrounded
        case .videoDeviceNotAvailableDueToSystemPressure:
            return .thermal
        case .videoDeviceInUseByAnotherClient,
             .audioDeviceInUseByAnotherClient,
             .videoDeviceNotAvailableWithMultipleForegroundApps:
            return .systemInterruption
        @unknown default:
            return .systemInterruption
        }
    }

    // MARK: Plumbing

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func setState(_ newState: State) {
        withLock { currentState = newState }
    }

    /// Runs `body` on the serial capture queue, which owns every capture-stack
    /// mutation. Re-entrant calls (a stop from inside a capture-queue callback)
    /// run inline rather than deadlocking.
    private func onCaptureQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: captureQueueKey) != nil {
            return try body()
        }
        return try captureQueue.sync(execute: body)
    }
}
