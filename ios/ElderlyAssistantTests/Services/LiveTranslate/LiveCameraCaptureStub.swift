import AVFoundation
import CoreMedia
import Foundation
@testable import ElderlyAssistant

/// T-006's stubbed capture layer: the integration seam the session's policy is
/// exercised against, with no camera, no device and no simulator camera
/// support.
///
/// It is deliberately *not* a mock of AVFoundation. It implements the same
/// narrow protocol the shipped `AVFoundationCaptureLayer` does — one video data
/// output, no photo output, no file output — and records what the session asked
/// of it, so a test can assert both the behaviour and the configuration.
final class LiveCameraCaptureStub: LiveCameraCaptureLayer {

    /// A real (empty) `AVCaptureSession`, so the preview layer is a real layer
    /// built over a real session object, exactly as in the app.
    let session = AVCaptureSession()

    private let lock = NSLock()

    // MARK: Scripted state

    var authorizationStatus: CameraAuthorizationStatus = .granted
    var requestAccessResult = true
    var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var requestAccessCallCount = 0
    private(set) var configureCallCount = 0
    private(set) var startRunningCallCount = 0
    private(set) var stopRunningCallCount = 0
    private(set) var lastConfigurationError: LiveTranslateError?

    /// What `configureVideoOnly` throws, if anything. The session must report
    /// these as their own explicit results and never retry them in process.
    var configurationError: LiveTranslateError?

    private var sink: ((CMSampleBuffer) -> Void)?
    private var running = false

    // MARK: LiveCameraCaptureLayer

    /// Runs on the capture queue inside `startRunning()` — the one moment a
    /// test can act while the session is still `.starting`, which is where the
    /// interruption-during-start path lives.
    var onStartRunning: (() -> Void)?

    func requestAccess() async -> Bool {
        lock.lock(); requestAccessCallCount += 1; lock.unlock()
        return requestAccessResult
    }

    func configureVideoOnly(onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
                            queue: DispatchQueue) throws {
        lock.lock()
        configureCallCount += 1
        let error = configurationError
        lock.unlock()
        if let error {
            lock.lock(); lastConfigurationError = error; lock.unlock()
            throw error
        }
        sink = onSampleBuffer
    }

    func startRunning() {
        lock.lock(); startRunningCallCount += 1; running = true; lock.unlock()
        onStartRunning?()
    }

    func stopRunning() {
        lock.lock(); stopRunningCallCount += 1; running = false; lock.unlock()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: Driving frames

    /// Delivers a sample buffer to the sink the session registered — the same
    /// path `AVCaptureVideoDataOutput` uses, minus the hardware.
    func deliver(_ sampleBuffer: CMSampleBuffer) {
        sink?(sampleBuffer)
    }

    /// Delivers a freshly made frame of the given size, stamped at `pts`.
    @discardableResult
    func deliverFrame(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        let buffer = try SampleBufferFactory.make(width: width, height: height, pts: pts)
        deliver(buffer)
        return buffer
    }
}

/// Builds in-memory sample buffers for the capture tests. Real `CVPixelBuffer`s
/// and real `CMSampleBuffer`s, so the session's frame conversion is the code
/// under test rather than a fixture.
enum SampleBufferFactory {

    static func make(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw StubFailure(message: "CVPixelBufferCreate failed with \(status)")
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let formatDescription else {
            throw StubFailure(message: "CMVideoFormatDescriptionCreateForImageBuffer failed with \(formatStatus)")
        }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard bufferStatus == noErr, let sampleBuffer else {
            throw StubFailure(message: "CMSampleBufferCreateReadyWithImageBuffer failed with \(bufferStatus)")
        }
        return sampleBuffer
    }
}

struct StubFailure: Error { let message: String }
