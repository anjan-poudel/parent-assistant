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
//  - **The cadence follows the scene, not the clock.** The tap measures each
//    sample against the last frame recognition ran on (`FrameChangeDetector`,
//    a 64 × 64 luminance signature — tens of microseconds against Vision's
//    tens of milliseconds) and drops a still scene to `stableSampleInterval`
//    (~1.4 fps), returning to the nominal cadence the moment the picture
//    changes. A sample the tap does not deliver costs nothing downstream: no
//    pass, no Vision request, no tracking request, no publication. The gate
//    never *stops* the stream, because the stabiliser needs
//    `regionAppearPasses` consecutive sightings to publish a region — the
//    reduced cadence is the refresh rate that keeps that hysteresis honest.
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

    /// The capture device's zoom factor when this frame was produced
    /// (`AVCaptureDevice.videoZoomFactor`): 1 is the wide camera's native field
    /// of view, and anything above it is the **device's own crop of the
    /// sensor**, not a digital enlargement of a wider frame.
    ///
    /// Carried so the recognition pass knows what it is looking at. The buffer
    /// handed to Vision is the zoomed region at the capture preset's full size,
    /// so "the elder zoomed in on the small print" and "the picture moved" are
    /// different facts about a frame, and only the frame carries both. A caller
    /// that never asked the device for a zoom gets 1, which is the honest
    /// answer for a frame read straight off a sample buffer.
    let zoomFactor: Double

    /// The rectangle of this buffer the elder is actually looking at — the
    /// display's virtual crop, on top of the sensor's own zoom (owner
    /// follow-up, 2026-09-18: panning).
    ///
    /// The device's zoom has already cropped the *sensor*; this is the second,
    /// display-side crop the pan and the zoom window ask for, and it is what
    /// the recognition pass hands itself before Vision sees the picture, so
    /// that the small print on the glass is the small print in the results.
    /// `.whole` for a session that has neither zoomed nor panned, which is
    /// every frame this feature produced before the window existed.
    let crop: LiveCameraCrop
}

extension CameraFrame {
    /// Reads a frame's geometry out of a delivered sample buffer. The buffer
    /// is the one `AVCaptureVideoDataOutput` produced under `videoSettings`,
    /// so it is already downscaled, and it is retained only by this value.
    init?(sampleBuffer: CMSampleBuffer, zoomFactor: Double = 1, crop: LiveCameraCrop = .whole) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        self.pixelBuffer = pixelBuffer
        self.pixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        self.timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        self.zoomFactor = zoomFactor
        self.crop = crop
    }

    /// This frame's pixels, narrowed to a rectangle of it.
    ///
    /// A **copy** into a buffer of the crop's own size, not a view over the
    /// original's memory: a view would be cheaper (an allocation of a buffer
    /// header and nothing else) but it would make the cropped buffer's validity
    /// depend on the original's lifetime and on the platform's alignment rules
    /// for caller-supplied row pointers — a subtle failure mode in exchange for
    /// a copy of at most a few megabytes, on a pass that already costs tens of
    /// milliseconds of Vision. What Vision is given is a buffer that is exactly
    /// the visible picture, at the capture preset's resolution: no downscale,
    /// no second request, and no frame invented beyond its own edges.
    ///
    /// `.whole` returns the frame's own buffer, which is the identity case and
    /// the one every caller before the window existed takes.
    func cropped(to crop: LiveCameraCrop) -> CVPixelBuffer {
        guard !crop.isWhole else { return pixelBuffer }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // The crop's pixel bounds, as whole pixels inside the buffer. A window
        // that asks for less than a pixel of a row (a two-pixel frame with a
        // 0.7 window) still gets a pixel rather than an empty buffer, so the
        // pass always has something well-formed to run on.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let minX = Swift.min(width - 1, Swift.max(0, Int(crop.box.xMin * Double(width))))
        let minY = Swift.min(height - 1, Swift.max(0, Int(crop.box.yMin * Double(height))))
        let maxX = Swift.min(width, Swift.max(minX + 1, Int((crop.box.xMax * Double(width)).rounded(.up))))
        let maxY = Swift.min(height, Swift.max(minY + 1, Int((crop.box.yMax * Double(height)).rounded(.up))))
        let cropWidth = maxX - minX
        let cropHeight = maxY - minY

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, cropWidth, cropHeight, format,
                                  attributes as CFDictionary, &destination) == kCVReturnSuccess,
              let destination else {
            return pixelBuffer
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return pixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return pixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let sourceBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return pixelBuffer
        }

        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let bytesPerPixel = 4
        let rowBytes = Swift.min(cropWidth * bytesPerPixel, Swift.min(sourceStride, destinationStride))
        let source = sourceBase.assumingMemoryBound(to: UInt8.self) + minY * sourceStride + minX * bytesPerPixel
        let destinationBytes = destinationBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<cropHeight {
            memcpy(destinationBytes + row * destinationStride, source + row * sourceStride, rowBytes)
        }
        return destination
    }
}

// MARK: - The frame-change gate

/// One frame's luminance signature: `side × side` mean-luma samples on a 0–255
/// scale, read straight out of the delivered pixel buffer.
///
/// Nothing is allocated but the samples themselves (4,096 bytes at the default
/// side): the frame is not copied, not resized and not retained, so the
/// signature costs a scan and no memory — which is the whole point of putting
/// the gate in front of Vision rather than in a scaled copy of the frame.
struct LuminanceSignature: Equatable {
    let side: Int
    let samples: [UInt8]

    /// Reads a signature off a pixel buffer, or `nil` when the buffer is not in
    /// a format this reads (the capture layer asks the platform for 32BGRA; a
    /// test may hand over anything).
    ///
    /// `region` narrows the read to the part of the buffer the elder can
    /// actually see — the display's crop — because the gate's question is "did
    /// *the picture on screen* change", and pixels outside the window are not
    /// on screen. It costs nothing: the same `side × side` samples, taken from
    /// a smaller rectangle. `whole` (the default) reads the whole buffer, which
    /// is the identity and what every caller before the window existed asked
    /// for.
    ///
    /// `nil` is not "unchanged" and never means "skip": a frame the gate cannot
    /// measure is a frame recognition runs on, which is the pre-gate behaviour
    /// and the safe direction to fail in.
    static func of(_ pixelBuffer: CVPixelBuffer,
                   side: Int,
                   region: LiveCameraCrop = .whole) -> LuminanceSignature? {
        guard side > 0 else { return nil }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // Packed 32-bit RGB layouts only: the loop below reads four 8-bit
        // components per pixel, and that is true of these and not of a planar
        // buffer (whose luma plane is one byte per pixel). A planar buffer is
        // refused rather than mis-read, and a refusal fails open — recognition
        // runs.
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB,
              !CVPixelBufferIsPlanar(pixelBuffer) else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // The two packed layouts differ in channel order; both are read as
        // (c0, c1, c2) at the pixel's first three bytes, and a luminance
        // average is order-independent for this purpose — what the gate
        // compares is the same channel of the same pixel on the next frame,
        // and that is stable for a fixed format.
        let isBGRA = format == kCVPixelFormatType_32BGRA
        let rOffset = isBGRA ? 2 : 1
        let bOffset = isBGRA ? 0 : 3

        // The sampled rectangle, in whole pixels. `whole`'s bounds are exactly
        // the buffer's, so the arithmetic below is the one this gate has always
        // done: `first + (row * extent) / side` with `first` 0 and the full
        // height.
        let firstX = Swift.min(width - 1, Swift.max(0, Int(region.box.xMin * Double(width))))
        let firstY = Swift.min(height - 1, Swift.max(0, Int(region.box.yMin * Double(height))))
        let endX = Swift.min(width, Swift.max(firstX + 1, Int((region.box.xMax * Double(width)).rounded(.up))))
        let endY = Swift.min(height, Swift.max(firstY + 1, Int((region.box.yMax * Double(height)).rounded(.up))))
        let spanX = endX - firstX
        let spanY = endY - firstY

        var samples = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            let y = firstY + (row * spanY) / side
            let rowBase = y * bytesPerRow
            for column in 0..<side {
                let x = firstX + (column * spanX) / side
                let pixel = bytes + rowBase + x * 4
                // BT.601 luma, integer arithmetic: the gate compares one
                // signature with another, so a fixed-point approximation is
                // not merely adequate, it is the same function on both sides.
                let value = (Int(pixel[bOffset]) * 29
                             + Int(pixel[1]) * 150
                             + Int(pixel[rOffset]) * 77) >> 8
                samples[row * side + column] = UInt8(clamping: value)
            }
        }
        return LuminanceSignature(side: side, samples: samples)
    }

    /// Mean absolute difference per sample, as a fraction of full scale.
    /// `nil` when the two signatures do not describe the same grid.
    func meanAbsoluteDifference(from other: LuminanceSignature) -> Double? {
        guard side == other.side, samples.count == other.samples.count,
              !samples.isEmpty else { return nil }
        var total = 0
        for index in samples.indices {
            total += abs(Int(samples[index]) - Int(other.samples[index]))
        }
        return Double(total) / Double(samples.count) / 255.0
    }
}

/// The frame-change gate: "is this frame a materially different picture from
/// the last one recognition ran on?"
///
/// It exists to be cheap enough to run on every delivered sample, so that
/// Vision — the feature's dominant CPU term, and the thing the device's own
/// crash reports show burning a core while nothing on screen was changing —
/// can be skipped when its answer could not differ. Recognition over an
/// unchanged frame cannot produce a different set of strings: the input is the
/// same and Vision is deterministic for a fixed input, so the pass is pure
/// cost.
///
/// Held by value and mutated under the owner's own lock (`LiveCameraSession`
/// taps on one video queue and reads later frames through the same lock), so
/// the gate adds no second synchronisation story to reason about.
struct FrameChangeDetector {

    /// The signature of the last frame that was handed to recognition.
    private var reference: LuminanceSignature?

    /// Whether `frame` is materially different from the remembered one. Does
    /// **not** mutate: a frame that is dropped by the cadence afterwards must
    /// not become the new reference, or the gate would slowly walk its own
    /// baseline away from the frame the overlay is actually showing.
    ///
    /// Measured over the frame's own crop — the part of the picture on screen —
    /// so a gesture that moves the window is a different picture by
    /// construction. The window's own edge is dropped when it moves (`LiveCameraSession.setCrop`),
    /// which is what stops the gate comparing two different rectangles and
    /// calling them the same scene.
    ///
    /// The first frame after a start (or after `forget`) is always a change,
    /// and a frame whose signature cannot be read is always a change.
    func isMateriallyDifferent(_ frame: CameraFrame, side: Int, threshold: Double) -> Bool {
        guard let reference else { return true }
        guard let current = LuminanceSignature.of(frame.pixelBuffer, side: side, region: frame.crop) else {
            return true
        }
        guard let difference = current.meanAbsoluteDifference(from: reference) else { return true }
        return difference >= threshold
    }

    /// Remembers this frame as the reference the next comparison is made
    /// against. Called for the frames actually handed to recognition.
    mutating func remember(_ frame: CameraFrame, side: Int) {
        guard let signature = LuminanceSignature.of(frame.pixelBuffer, side: side, region: frame.crop) else {
            return
        }
        reference = signature
    }

    /// Drops the reference: the next frame is a change, whatever it shows.
    /// Used on a resume, where the scene the session returns to is not the one
    /// it left.
    mutating func forget() {
        reference = nil
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

    // MARK: Zoom and focus (owner report, 2026-09-17)

    /// What the configured device can do about zoom: the factors it can
    /// deliver and the factors at which it hands over to its next lens.
    /// `.unknown` before a device exists.
    ///
    /// Asked again on every interaction rather than remembered: the valid range
    /// follows the device's *active format*, which the platform may change
    /// under a running session, and a factor clamped against a stale range is
    /// either an out-of-range exception or a zoom the elder did not ask for.
    var zoomCapabilities: CameraZoomCapabilities { get }

    /// The device's zoom factor now — what the frames reaching the sink were
    /// cropped at.
    var videoZoomFactor: Double { get }

    /// Sets the zoom factor and answers the factor the device actually took.
    ///
    /// The answer is the device's, not the argument's: the platform clamps to
    /// the active format's own range, and a caller that kept its own number
    /// would draw a readout the camera never honoured.
    @discardableResult
    func setVideoZoomFactor(_ factor: Double) -> Double

    /// Whether the device can be told *where* to focus at all.
    var supportsFocusPointOfInterest: Bool { get }

    /// Moves the focus point — a device point: normalized, top-left origin —
    /// and starts a **one-shot** focus operation there. Setting the point alone
    /// focuses nothing; the implementation sets the focus mode after it.
    func focus(atDevicePoint point: CGPoint)

    /// Moves the focus point and starts a **continuous** close-range search
    /// there: the mode that keeps looking as the subject moves, used when the
    /// device reports the subject area changed under a focus that has stopped
    /// adjusting. Distinct from `focus(atDevicePoint:)` on purpose — a
    /// one-shot holds the lens where it landed, which is right for a tap and
    /// wrong for a subject that has moved.
    func focusContinuously(atDevicePoint point: CGPoint)

    /// Holds focus at its current lens position, or returns it to the
    /// continuous search.
    func setFocusLocked(_ locked: Bool)

    /// Registers the device's own report that the subject area changed
    /// substantially (the packet was turned over, brought closer, moved into
    /// shadow). Registration replaces any previous handler.
    func observeSubjectAreaChanges(_ handler: @escaping () -> Void)
}

/// The shipped capture layer. One `AVCaptureVideoDataOutput`, no photo output,
/// no file output, no picker.
final class AVFoundationCaptureLayer: NSObject, LiveCameraCaptureLayer {

    let session = AVCaptureSession()

    /// The feature's operational constants, read here because this is the file
    /// that imports AVFoundation: the capture preset, the zoom the session
    /// starts at, and the focus policy.
    private let config: LiveTranslateConfig

    /// The device lookup, injectable so a test can exercise the no-camera path
    /// without unplugging anything. The default is this feature's own lens
    /// preference (see `defaultDevice`), never a bare
    /// `AVCaptureDevice.default(for: .video)`, which would hand back the
    /// single wide-angle camera.
    private let deviceProvider: () -> AVCaptureDevice?

    private var device: AVCaptureDevice?
    private var sink: ((CMSampleBuffer) -> Void)?
    private var isConfigured = false
    private var subjectAreaObserver: NSObjectProtocol?

    init(config: LiveTranslateConfig = .default,
         deviceProvider: (() -> AVCaptureDevice?)? = nil) {
        self.config = config
        self.deviceProvider = deviceProvider ?? Self.defaultDevice
        super.init()
    }

    deinit {
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    // MARK: Device discovery

    /// The device the session captures from: the **virtual** multi-lens device
    /// first, because that is the only kind that gives the elder what the
    /// standard camera app has.
    ///
    /// A virtual device publishes `virtualDeviceSwitchOverVideoZoomFactors`, so
    /// raising `videoZoomFactor` past one of those factors is what makes the
    /// camera hand over from the ultra-wide to the wide to the telephoto — the
    /// automatic lens switching the owner asked for, performed by the platform
    /// on the sensor, not by this feature on the picture. It is also the only
    /// kind that performs the *close-subject* fallback: a telephoto whose
    /// minimum focus distance is 40 cm cannot see a packet held at 20 cm, and
    /// the platform answers that by switching to a shorter lens on its own —
    /// which is precisely the blur the owner reported. A single wide-angle
    /// camera zooms digitally and never switches.
    ///
    /// The order is `CameraLensSet.discoveryOrder` (triple, dual-wide, wide),
    /// read as a value rather than written as three lookups in a row, and the
    /// last lookup is the honest fallback for a device that has none of them:
    /// `AVCaptureDevice.default(for: .video)` is still a working camera.
    static func defaultDevice() -> AVCaptureDevice? {
        for lensSet in CameraLensSet.discoveryOrder {
            if let device = AVCaptureDevice.default(deviceType(for: lensSet),
                                                    for: .video,
                                                    position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// The AVFoundation device type a lens set is discovered by.
    ///
    /// A total mapping, asserted as a value in the tests: a wrong case would
    /// otherwise only show up as "the camera is single-lens on a triple-camera
    /// phone", which is invisible until someone tries to read a packet.
    static func deviceType(for lensSet: CameraLensSet) -> AVCaptureDevice.DeviceType {
        switch lensSet {
        case .triple: return .builtInTripleCamera
        case .dualWide: return .builtInDualWideCamera
        case .wideAngle: return .builtInWideAngleCamera
        }
    }

    /// The session presets to try, in order, for a configured capture quality.
    ///
    /// An ordered list rather than one preset because `canSetSessionPreset(_:)`
    /// is the platform's answer about *this device's* formats: a preset a
    /// device cannot deliver is not an error the elder should see — a smaller
    /// frame is still a working translator — and the list ends at the size
    /// every back camera has been able to deliver since iOS 4, so it cannot run
    /// out.
    static func presets(for quality: LiveTranslateCaptureQuality) -> [AVCaptureSession.Preset] {
        switch quality {
        case .high: return [.hd1280x720, .vga640x480]
        case .standard: return [.vga640x480]
        }
    }

    // MARK: Permission

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

    // MARK: Configuration

    func configureVideoOnly(onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
                            queue: DispatchQueue) throws {
        guard !isConfigured else { return }
        guard let device = deviceProvider() else {
            throw LiveTranslateError.cameraUnavailable(.noCaptureDevice)
        }
        self.device = device

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            // The device exists but cannot be opened — another client holds it,
            // or the system refused it. Neither is fixable in process.
            throw LiveTranslateError.cameraUnavailable(.resourceInUse)
        }

        session.beginConfiguration()
        applyPreset()
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

        // The device's own half of the quality story, after the graph is
        // committed (the formats the session settled on decide the zoom range)
        // and before the first frame is produced.
        applyQuality(to: device)

        sink = onSampleBuffer
        isConfigured = true
    }

    /// Asks for the configured quality, falling back down the list.
    ///
    /// The frame the elder gets is the platform's own downscale of the sensor,
    /// not a size this feature invents — the preset is the one lever over that,
    /// and `cameraQuality` is where it is written down.
    private func applyPreset() {
        for preset in Self.presets(for: config.cameraQuality) where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            return
        }
    }

    /// Configures the device itself: the opening zoom, the focus policy, and
    /// the two platform behaviours that decide how much the *device* does on
    /// its own (constituent camera switching, and HDR).
    ///
    /// One lock, one pass. Every property below throws without
    /// `lockForConfiguration`, and the focus properties only take effect once
    /// the focus mode is set *after* them, so a half-applied policy would
    /// silently do nothing.
    private func applyQuality(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            // A device that cannot be locked still captures at the platform's
            // defaults, which is a working translator — never a failure the
            // elder is shown.
            return
        }
        defer { device.unlockForConfiguration() }

        // The lens switching is the platform's. `.auto` (the default for
        // devices that support it) lets the virtual device pick the best
        // constituent for the scene, including the close-subject fallback to a
        // shorter lens. Set explicitly rather than inherited so the feature
        // states its choice in code — and never `.locked`, which would pin the
        // session to one constituent and make the switch-over factors the zoom
        // model reads meaningless.
        if device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
            device.setPrimaryConstituentDeviceSwitchingBehavior(
                .auto,
                restrictedSwitchingBehaviorConditions: [])
        }

        if device.isSubjectAreaChangeMonitoringEnabled != config.subjectAreaChangeMonitoring {
            device.isSubjectAreaChangeMonitoringEnabled = config.subjectAreaChangeMonitoring
        }

        // The platform turns HDR on by default for a format that fits it; the
        // feature states it rather than inheriting it, and can turn it off (see
        // `automaticVideoHDR` for why that escape hatch exists at all).
        device.automaticallyAdjustsVideoHDREnabled = config.automaticVideoHDR

        // The opening view, in the same space and by the same rule as every
        // later one: the config's value is a *readout* number ("1× is the wide
        // camera's own view") and the device wants its own, so the conversion
        // goes through the device's capabilities — which also mean the opening
        // factor is inside the range the model will hold the elder to, rather
        // than a first position the first gesture has to correct.
        //
        // A range that traps on a device reporting an inverted one is closed by
        // the same helper the model clamps with: one clamping rule, one place.
        device.videoZoomFactor = Self.zoomCapabilities(of: device).openingFactor(for: config)

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = config.focusPointOfInterest
        }
        applyRangeRestriction(to: device)
        if config.smoothAutoFocus, device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        // The mode last, always: the point, the restriction and the smooth
        // flag only take effect once a focus mode is set after them.
        if config.focusLockDefault {
            applyFocusMode(.locked, to: device)
        } else {
            applyFocusMode(.continuousAutoFocus, to: device)
        }
    }

    /// The near-range restriction, where the config and the device both allow
    /// it. Called *before* the focus mode at every site that wants it: the
    /// restriction has no effect until the mode is set after it.
    private func applyRangeRestriction(to device: AVCaptureDevice) {
        guard config.focusNearRangeRestriction,
              device.isAutoFocusRangeRestrictionSupported else { return }
        device.autoFocusRangeRestriction = .near
    }

    /// Sets a focus mode the device actually supports.
    private func applyFocusMode(_ mode: AVCaptureDevice.FocusMode, to device: AVCaptureDevice) {
        guard device.isFocusModeSupported(mode) else { return }
        device.focusMode = mode
    }

    // MARK: Zoom

    var zoomCapabilities: CameraZoomCapabilities {
        guard let device else { return .unknown }
        return Self.zoomCapabilities(of: device)
    }

    /// What a device reports, whether or not it is the one currently running:
    /// the same answer the running path gives, so the opening factor in
    /// `applyQuality` and the bounds a later gesture is held to are read off
    /// the same device in the same vocabulary.
    private static func zoomCapabilities(of device: AVCaptureDevice) -> CameraZoomCapabilities {
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = Swift.max(minimum, device.maxAvailableVideoZoomFactor)
        return CameraZoomCapabilities(
            range: minimum...maximum,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            widestLensIsUltraWide: widestLensIsUltraWide(device))
    }

    var videoZoomFactor: Double { Double(device?.videoZoomFactor ?? 1) }

    @discardableResult
    func setVideoZoomFactor(_ factor: Double) -> Double {
        guard let device else { return factor }
        do {
            try device.lockForConfiguration()
        } catch {
            return factor
        }
        defer { device.unlockForConfiguration() }

        // Clamped against the range read *inside* the same lock: assigning
        // outside `minAvailableVideoZoomFactor...maxAvailableVideoZoomFactor`
        // raises `NSRangeException` — an Objective-C exception, which is a crash
        // in Swift, not a catchable error — and the range itself follows the
        // active format, so a value clamped a moment earlier can be out of range
        // a moment later.
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = Swift.max(minimum, device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = CGFloat(LiveCameraZoomModel.clamped(factor, to: minimum...maximum))
        return Double(device.videoZoomFactor)
    }

    /// Whether this device's widest lens is its ultra-wide camera — the one
    /// fact the readout's unit is derived from
    /// (`CameraZoomCapabilities.displayMultiplier`), read off the device's own
    /// constituent list.
    ///
    /// A virtual device lists its constituents in the order its switch-over
    /// factors progress, so the first is the widest view it can give: the
    /// ultra-wide on every phone that has one. The alternative is the platform's
    /// own answer — `displayVideoZoomFactorMultiplier`, the ratio the system
    /// readout uses — but that property is iOS 18+ and the guard that reaches it
    /// would have to spell its version number in this file, which the feature's
    /// source-hygiene scan reads as a re-declaration of a configured default
    /// (`overlayMinPointSize = 18`). The scan cannot tell a version number from
    /// a parameter, and a scan that guessed would be the worse guard. A device
    /// whose first constituent is not the ultra-wide — the wide angle only, or
    /// an ordering this does not know — gets 1, which is the honest unit for it.
    private static func widestLensIsUltraWide(_ device: AVCaptureDevice) -> Bool {
        device.constituentDevices.first?.deviceType == .builtInUltraWideCamera
    }

    // MARK: Focus

    var supportsFocusPointOfInterest: Bool { device?.isFocusPointOfInterestSupported ?? false }

    func focus(atDevicePoint point: CGPoint) {
        guard let device, device.isFocusPointOfInterestSupported else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }

        // The point, then the restriction, then the mode: setting the point
        // alone focuses nothing, and the restriction is only read when a focus
        // mode is set after it.
        device.focusPointOfInterest = point
        applyRangeRestriction(to: device)
        // A one-shot scan where the device offers one — that is the "snap it
        // into focus where I pointed" the elder asked for by tapping — and
        // continuous focus where it does not.
        if device.isFocusModeSupported(.autoFocus) {
            applyFocusMode(.autoFocus, to: device)
        } else {
            applyFocusMode(.continuousAutoFocus, to: device)
        }
    }

    func focusContinuously(atDevicePoint point: CGPoint) {
        guard let device, device.isFocusPointOfInterestSupported else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        device.focusPointOfInterest = point
        applyRangeRestriction(to: device)
        applyFocusMode(.continuousAutoFocus, to: device)
    }

    func setFocusLocked(_ locked: Bool) {
        guard let device, device.isFocusModeSupported(locked ? .locked : .continuousAutoFocus) else {
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        if !locked {
            applyRangeRestriction(to: device)
        }
        applyFocusMode(locked ? .locked : .continuousAutoFocus, to: device)
    }

    func observeSubjectAreaChanges(_ handler: @escaping () -> Void) {
        guard let device else { return }
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
        // The device posts on whichever thread detected the change; the handler
        // is the session's, which hops to its own queue rather than doing work
        // here.
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: nil) { _ in handler() }
    }

    // MARK: Running

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

    /// The frame-change gate's state. Lock-guarded with the rest of the tap
    /// state, because the tap is the only writer and the tap is where the
    /// cadence decision is made.
    private var frameDetector = FrameChangeDetector()
    /// The pipeline's stale-scene signal (see `ocrSceneStale`).
    private var sceneStale = false

    /// The zoom the device was last applied (see `setZoom`), stamped on every
    /// delivered frame. Kept here rather than read off the device on the video
    /// queue: the device is a seam implementation's business, and one lock
    /// already guards every value the tap reads.
    private var videoZoomFactor: Double
    /// The window the elder is looking through, told by the zoom surface (see
    /// `setCrop`): `.whole` until a gesture narrows it.
    private var crop: LiveCameraCrop = .whole
    /// The focus point the session last asked for (a device point), and whether
    /// the elder has focus held. Both are mirrors of the zoom surface's state,
    /// kept here because the subject-area re-arm runs off the video-adjacent
    /// path and cannot ask the view.
    private var focusPoint: CGPoint
    private var focusIsLocked: Bool

    private let stream: AsyncStream<CameraFrame>
    private var continuation: AsyncStream<CameraFrame>.Continuation?

    // MARK: Init

    init(config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         capture: LiveCameraCaptureLayer? = nil,
         notificationCenter: NotificationCenter = .default,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        // The shipped layer is built with *this* session's config (the preset,
        // the opening zoom and the focus policy are all config values, and the
        // layer is the file that speaks AVFoundation). A supplied layer is used
        // as it is: it is the caller's, and in tests it is a stub with no
        // device behind it at all.
        let capture = capture ?? AVFoundationCaptureLayer(config: config)
        self.capture = capture
        self.notificationCenter = notificationCenter
        self.now = now
        // The at-rest factor, in the space every other zoom in this class is in
        // (`setZoom`): the config's readout value taken into the device's own
        // space through the layer if it already has a device, and the config's
        // own bounds when it has none. The first `start()` replaces it with the
        // device's own answer either way (`CameraFrame.zoomFactor`).
        self.videoZoomFactor = capture.zoomCapabilities.openingFactor(for: config)
        self.focusPoint = config.focusPointOfInterest
        self.focusIsLocked = config.focusLockDefault

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

    /// The pipeline's stale-scene signal. `true` means the last
    /// `stalePassesBeforeReducedCadence` recognition passes contained no new or
    /// changed region, so the tap runs at the reduced cadence from now on.
    ///
    /// Written by the pipeline (which owns the pass and is the only component
    /// that can tell a pass with no text from a pass that did not run), read
    /// here on the video-output queue, exactly like `ocrPassInFlight`. The
    /// session does not infer it: a scene that is moving without containing new
    /// text is a fact about the recognition results, not about the pixels.
    var ocrSceneStale: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return sceneStale
        }
        set {
            lock.lock(); defer { lock.unlock() }
            sceneStale = newValue
        }
    }

    /// The tap's interval after the thermal response (NFR-LCT-002 scenario 3):
    /// at or above the configured threshold the cadence slows by the configured
    /// factor, so a hot device degrades instead of stopping.
    ///
    /// This is the **nominal** cadence — the one a scene that is actively
    /// producing new text runs at. The reduce-when-idle half is
    /// `effectiveSampleInterval(changed:stale:)`.
    var effectiveSampleInterval: TimeInterval {
        let thermal = capture.thermalState
        let reduced = thermal.rawValue >= config.thermalStateThreshold.rawValue
        return reduced ? config.ocrSampleInterval * config.thermalCadenceFactor
                       : config.ocrSampleInterval
    }

    /// The interval this sample gets, given what the frame-change gate and the
    /// pipeline's staleness signal say about the scene.
    ///
    /// **Lock-free by contract**: the tap calls this while it already holds the
    /// lock, so it may only read values the caller has read. Two ways to end up
    /// at the reduced cadence — the frame is materially the same picture as the
    /// last one recognition ran on, or the pipeline reports that recent passes
    /// found no new text — and the difference between them is the point: the
    /// first is cheap to measure and catches a still camera, the second catches
    /// motion that carries no information (a hand, a reflection, a screen
    /// playing video behind the sign) and is the one that would otherwise hold
    /// the full cadence open for as long as the elder kept pointing the camera
    /// at the same sign.
    ///
    /// A *changed* frame in a scene the pipeline has not called stale runs at
    /// the full cadence, because a new sign must be read as soon as it appears:
    /// the reduced cadence is a bound on idling, never a lag on news.
    func effectiveSampleInterval(changed: Bool, stale: Bool) -> TimeInterval {
        let nominal = effectiveSampleInterval
        guard !changed || stale else { return nominal }
        // `max` rather than the reduced value alone: on a hot device the nominal
        // cadence may already be slower than the reduced one, and the thermal
        // response is a floor on how much the feature slows down, not a ceiling.
        return Swift.max(nominal, config.stableSampleInterval)
    }

    // MARK: Zoom and focus (owner report, 2026-09-17)

    /// The zoom and focus surface the session view renders: the elder's factor,
    /// the device's bounds and switch-over factors, and the focus-lock state.
    ///
    /// Lazily built so its closures can reach this session without capturing it
    /// strongly — the surface is owned here, and a strong pair would be a
    /// retain cycle. It is a view surface: read it on the main thread.
    private(set) lazy var zoomSurface: LiveCameraZoomSurface = LiveCameraZoomSurface(
        config: config,
        capabilities: { [weak self] in self?.zoomCapabilities ?? .unknown },
        applyZoom: { [weak self] factor in self?.setZoom(factor) ?? factor },
        applyFocus: { [weak self] point in self?.focus(at: point) },
        applyFocusLock: { [weak self] locked in self?.setFocusLocked(locked) },
        applyCrop: { [weak self] crop in self?.setCrop(crop) })

    /// What the configured device can do about zoom, straight from the capture
    /// seam — `.unknown` before the session is configured and after it is torn
    /// down, because then there is no device to ask and the model works from
    /// the app's own bounds alone.
    var zoomCapabilities: CameraZoomCapabilities {
        switch state {
        case .running, .interrupted:
            return capture.zoomCapabilities
        default:
            return .unknown
        }
    }

    /// The zoom the delivered frames are cropped at. Read by a consumer that
    /// needs to know what a frame is a picture *of*.
    var currentVideoZoom: Double {
        withLock { videoZoomFactor }
    }

    /// Applies a zoom factor to the running device and answers the factor
    /// actually in effect.
    ///
    /// Clamped twice, deliberately. Once here, against the app's bounds narrowed
    /// by what the device reports, so that a caller always gets a number it can
    /// draw even when the session is not running; and once inside the capture
    /// layer, against the range read under the device's own configuration lock,
    /// because assigning outside it raises an Objective-C exception — a crash —
    /// and the range follows the active format.
    ///
    /// The zoom crosses into the recognition path through the *device*, not
    /// through this feature: `videoZoomFactor` crops the sensor before the data
    /// output sees the frame, so the buffer handed to Vision is the zoomed
    /// region at the capture preset's full size, with no second, downscaled
    /// copy of the picture in between.
    ///
    /// The frame-change gate's baseline is dropped with every applied change: a
    /// frame of the same scene at a different zoom is a different picture, and
    /// keeping the old baseline would have the gate answer "unchanged" for the
    /// frame that shows the small print the elder just zoomed in on — the one
    /// frame it must never drop. The cost is at most one extra pass.
    @discardableResult
    func setZoom(_ factor: Double) -> Double {
        // The factor arrives in the *device's* space — the one the model's
        // bounds, steps and readout are all built in — and the bounds are the
        // config's own limits converted into it by the same rule the model
        // uses (`CameraZoomCapabilities.rawBounds(for:)`), never a second copy
        // of the arithmetic.
        let capabilities = zoomCapabilities
        let requested = LiveCameraZoomModel.clamped(factor, to: capabilities.rawBounds(for: config))
        guard state == .running else { return requested }

        let applied: Double = onCaptureQueue { capture.setVideoZoomFactor(requested) }
        withLock {
            videoZoomFactor = applied
            frameDetector.forget()
        }
        return applied
    }

    /// The window the elder is looking through, told by the zoom surface whose
    /// gestures produced it (owner follow-up, 2026-09-18).
    ///
    /// Told rather than computed here, and deliberately: the window is a
    /// function of the *readout* the elder sees and the window ramp's config,
    /// which is the zoom model's business, and the surface is the only object
    /// that holds the model the device is actually in step with. The session
    /// keeps what it is given and stamps it on every frame, so the recognition
    /// pass, the frame-change gate and the overlay all crop the same rectangle
    /// the preview is drawn through.
    ///
    /// The gate's baseline is dropped with every change, for the same reason
    /// `setZoom` drops it: the gate measures two frames against each other, and
    /// two different rectangles of the same scene are not the same picture.
    /// Keeping the old baseline would have the gate compare the new window
    /// against the old one's pixels and answer "unchanged" about a picture the
    /// elder has just moved. The cost is at most one extra pass per gesture
    /// sample that actually moves the window.
    func setCrop(_ crop: LiveCameraCrop) {
        withLock {
            // A stopped session has already put its window back and will never
            // stamp another frame: a late update from a surface the view is
            // still holding must not reopen it.
            guard currentState != .stopped, self.crop != crop else { return }
            self.crop = crop
            frameDetector.forget()
        }
    }

    /// The window the delivered frames are cropped to. `.whole` until a
    /// gesture narrows it. Read by a consumer that needs to know what part of
    /// the frame a frame is showing.
    var currentCrop: LiveCameraCrop {
        withLock { crop }
    }

    /// Moves the focus point — a *device* point: normalized, top-left origin —
    /// and starts a focus operation there.
    ///
    /// The conversion from a tap in the letterboxed preview to this point is the
    /// preview layer's own (`captureDevicePointConverted(fromLayerPoint:)`),
    /// and it happens in the view, on the layer that knows the aspect fit. What
    /// arrives here is already in the device's coordinates.
    ///
    /// A tap also releases the focus lock: the one-shot focus the layer applies
    /// is the release, so there is no second call to make — and the surface is
    /// told, so the lock's control and the lock's device state cannot be drawn
    /// disagreeing.
    func focus(at devicePoint: CGPoint) {
        guard state == .running, capture.supportsFocusPointOfInterest else { return }
        withLock {
            focusPoint = devicePoint
            focusIsLocked = false
        }
        zoomSurface.focusLockChanged(to: false)
        onCaptureQueue { capture.focus(atDevicePoint: devicePoint) }
    }

    /// Holds focus at its current lens position, or returns it to the
    /// continuous close-range search.
    func setFocusLocked(_ locked: Bool) {
        withLock { focusIsLocked = locked }
        // The surface is told even when the session is not running: the elder
        // pressed the control, and a control that flipped back because the
        // camera happened to be between states would be the app arguing with
        // itself.
        zoomSurface.focusLockChanged(to: locked)
        guard state == .running else { return }
        onCaptureQueue { capture.setFocusLocked(locked) }
    }

    /// The device reports that the subject area changed substantially: the
    /// elder turned the packet over, brought it closer, or moved it out of the
    /// light. Bring the focus back to the close range at the point the elder
    /// last aimed at — unless they have focus held, which is them saying "do
    /// not move it".
    ///
    /// Continuous focus rather than another one-shot scan: a one-shot holds the
    /// lens position it found, which is right after a tap and wrong after a
    /// change — the packet that was turned over is at a different distance, and
    /// the mode that keeps looking is the one that finds it. It is also a
    /// *different* mode assignment from the tap's, so the re-arm is a real focus
    /// operation and not a re-assertion of the state the device is already in.
    private func refocusAfterSubjectAreaChange() {
        guard state == .running else { return }
        let target: CGPoint? = withLock {
            guard !focusIsLocked else { return nil }
            return focusPoint
        }
        guard let target else { return }
        onCaptureQueue { capture.focusContinuously(atDevicePoint: target) }
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
        let appliedZoom: Double
        do {
            appliedZoom = try onCaptureQueue {
                try capture.configureVideoOnly(onSampleBuffer: { [weak self] sampleBuffer in
                    self?.sampleArrived(sampleBuffer)
                }, queue: videoOutputQueue)
                // The opening zoom is the layer's — it applied
                // `initialVideoZoom` while it held the device's configuration
                // lock — and reading it back is what keeps the frames' own zoom
                // stamp honest, including on a device whose own range clamped
                // the value.
                return capture.videoZoomFactor
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

        withLock { videoZoomFactor = appliedZoom }
        // The device's answer is the surface's answer too: a device whose own
        // range clamped the opening factor would otherwise leave the readout,
        // and the window computed from it, describing a picture the camera is
        // not taking. The foreground transition is the session's only other
        // writer of the surface, and it is on the main thread like this one.
        zoomSurface.sessionOpened(atDeviceFactor: appliedZoom)
        registerLifecycleObservers()
        registerSubjectAreaObserver()
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
            // The first frame after a resume is a change by construction: the
            // scene the elder returns to is not the one the session left, and
            // the reduced cadence must not survive the interruption.
            withLock {
                frameDetector.forget()
                sceneStale = false
                lastSampledAt = nil
            }
            setState(.running)
            // Where the window was pointed is the elder's gesture state, and a
            // camera that went away and came back is the case the config's
            // `panResetsOnExit` is written for. This runs on the foreground
            // transition's thread — the main thread — like every other surface
            // write.
            zoomSurface.sessionReleased()
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
            frameDetector.forget()
            sceneStale = false
            // Back to the same at-rest reading the init states, by the same
            // rule: a caller that asks after a teardown gets a factor it can
            // draw, and a restart re-reads the device anyway.
            videoZoomFactor = capture.zoomCapabilities.openingFactor(for: config)
            crop = .whole
            focusPoint = config.focusPointOfInterest
            focusIsLocked = config.focusLockDefault
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
        // The elder has left the picture; the surface's own window state goes
        // with them when the config says so (the session's own window is
        // already back to `.whole` above, and `setCrop` refuses a stopped
        // session, so this cannot reopen it).
        zoomSurface.sessionReleased()
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
    ///  3. the frame-change gate measures the sample against the last frame
    ///     recognition ran on, and the answer chooses the interval (full
    ///     cadence for a changed scene, the reduced one otherwise);
    ///  4. a sample inside that interval is dropped;
    ///  5. otherwise the frame is yielded to the stream, which itself holds at
    ///     most one frame.
    ///
    /// Step 3 is where the feature's largest cost is avoided: a frame that is
    /// materially the same picture as the last one recognition saw cannot
    /// produce a different set of strings, so running Vision on it is pure
    /// cost — and it is a cost the device's own crash reports show being paid
    /// at ~4 Hz over a scene that was not changing. The gate runs *before* the
    /// interval check because it chooses the interval, and it commits its
    /// reference only for frames actually delivered, so a dropped sample never
    /// moves the baseline away from the frame the overlay is showing.
    private func sampleArrived(_ sampleBuffer: CMSampleBuffer) {
        // What the device was zoomed to when this sample was produced, and
        // which window of it the elder has moved to: the buffer is the device's
        // own crop of the sensor, and the frame carries both facts so the pass
        // knows what it is looking at.
        let (zoom, crop) = withLock { (videoZoomFactor, self.crop) }
        guard let frame = CameraFrame(sampleBuffer: sampleBuffer, zoomFactor: zoom, crop: crop) else {
            return
        }

        let accepted: AsyncStream<CameraFrame>.Continuation? = withLock {
            guard currentState == .running else { return nil }
            guard !passInFlight else { return nil }
            let changed = frameDetector.isMateriallyDifferent(frame,
                                                             side: config.frameSignatureSide,
                                                             threshold: config.frameChangeThreshold)
            let interval = effectiveSampleInterval(changed: changed, stale: sceneStale)
            let timestamp = now()
            if let last = lastSampledAt, timestamp - last < interval { return nil }
            lastSampledAt = timestamp
            // Delivered, therefore recognized (or tracked): this frame is the
            // gate's new baseline.
            frameDetector.remember(frame, side: config.frameSignatureSide)
            return continuation
        }
        accepted?.yield(frame)
    }

    // MARK: Lifecycle observers

    /// Registers the device's own report that the subject area changed. A
    /// no-op when the config turns monitoring off (and the device is then not
    /// asked to monitor at all, so nothing is posted).
    private func registerSubjectAreaObserver() {
        guard config.subjectAreaChangeMonitoring else { return }
        capture.observeSubjectAreaChanges { [weak self] in
            self?.refocusAfterSubjectAreaChange()
        }
    }

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
