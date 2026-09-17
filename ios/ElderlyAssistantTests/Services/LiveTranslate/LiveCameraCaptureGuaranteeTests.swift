import AVFoundation
import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// T-006 — the guarantees that are about what the capture stack *cannot* do:
/// no photo or file output, no picker, no photo-library write, and no frame
/// bytes anywhere but memory (FR-LCT-001/NFR-LCT-005).
///
/// Two halves, deliberately: a **source scan** that fails when the forbidden
/// shape is introduced into the feature's own code (falsifiable — the scanner
/// is re-run over synthetic source containing every forbidden shape and must
/// find each one), and a **behavioural** run of the real frame path against a
/// stubbed capture layer, which asserts the file system gained nothing.
final class LiveCameraCaptureGuaranteeTests: XCTestCase {

    /// The capture surfaces that would turn a translator into a recorder or a
    /// document scanner. Each is paired with what it would mean here. Held as
    /// literal tokens: the scanner takes regular expressions, so the pattern is
    /// derived with `escapedPattern(for:)` rather than written twice.
    private let forbidden: [(token: String, meaning: String)] = [
        ("AVCapturePhotoOutput", "a still-capture output"),
        ("AVCapturePhotoSettings", "a still capture"),
        ("AVCaptureMovieFileOutput", "recording to a file"),
        ("AVCaptureFileOutput", "a file output"),
        ("AVAssetWriter", "media written to a file"),
        ("UIImagePickerController", "a picker in the view"),
        ("PHPickerViewController", "a picker in the view"),
        ("PHPhotoLibrary", "a write to the photo library"),
        ("UIImageWriteToSavedPhotosAlbum", "a write to the photo library"),
        ("UIActivityViewController", "a share sheet over a frame"),
        ("FileManager", "file-system access"),
        ("FileHandle", "a raw file write"),
        ("write(to:", "bytes written to a URL"),
        ("Data(contentsOf:", "bytes read from disk"),
        ("NSData", "a raw byte buffer")
    ]

    /// The scanner's form of each token. Built from the token so a pattern with
    /// regex metacharacters in it (`write(to:`) can never be an invalid scan
    /// that fails instead of detecting.
    private var forbiddenPatterns: [(pattern: String, token: String, meaning: String)] {
        forbidden.map { (NSRegularExpression.escapedPattern(for: $0.token), $0.token, $0.meaning) }
    }

    // MARK: Scenario: the frame path cannot leave the process

    func testNoFeatureSourceCanConstructAnotherCaptureOutputOrWriteBytes() {
        let files = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        XCTAssertFalse(files.isEmpty, "the feature's sources must be scanned, not skipped")

        for file in files {
            let code = FeatureSourceScan.codeText(of: file)
            XCTAssertFalse(code.isEmpty, "\(FeatureSourceScan.relativePath(of: file)) scanned as empty")
            for entry in forbiddenPatterns {
                if let match = FeatureSourceScan.firstMatch(of: entry.pattern, in: code) {
                    XCTFail("\(FeatureSourceScan.relativePath(of: file)):\(match.line) uses "
                            + "\(entry.token) (\(entry.meaning)) — the camera path is video data only")
                }
            }
        }
    }

    /// The falsification check: a scanner that cannot see the shape it forbids
    /// proves nothing. Every pattern above must be detected in a source that
    /// contains it.
    func testTheScanDetectsEveryForbiddenShapeWhereItActuallyAppears() {
        for entry in forbiddenPatterns {
            let source = "import AVFoundation\nlet output = \(entry.token)()\n"
            let match = FeatureSourceScan.firstMatch(of: entry.pattern, in: source)
            XCTAssertNotNil(match, "the scanner is blind to \(entry.token)")
            XCTAssertEqual(match?.line, 2)
        }
    }

    /// The capture layer's whole API: one video data output and nothing else.
    /// A second output class added later fails this rather than passing review.
    func testTheCaptureLayerConfiguresOneVideoDataOutputAndNoOther() {
        let file = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(FeatureSourceScan.liveTranslateSources)
            .appendingPathComponent("LiveCameraSession.swift")
        let code = FeatureSourceScan.codeText(of: file)

        // Construction sites only (`Type(`), not the delegate's parameter type.
        let outputClasses = try! NSRegularExpression(pattern: "AVCapture[A-Za-z]*Output\\(")
        let whole = NSRange(code.startIndex..<code.endIndex, in: code)
        let names = Set(outputClasses.matches(in: code, options: [], range: whole).compactMap {
            Range($0.range, in: code).map { String(code[$0].dropLast()) }
        })

        XCTAssertEqual(names, ["AVCaptureVideoDataOutput"],
                       "the capture layer may construct the video data output alone")
    }

    /// The seam itself has no photo/file entry point, so the policy tests
    /// cannot be satisfied by a layer that quietly captures stills: the only
    /// configuration call takes a sample-buffer sink.
    func testTheCaptureSeamExposesNoPhotoOrFileEntryPoint() throws {
        let declaration = try XCTUnwrap(block(startingWith: "protocol LiveCameraCaptureLayer",
                                              in: "LiveCameraSession.swift"))
        XCTAssertTrue(declaration.contains("configureVideoOnly(onSampleBuffer:"),
                      "the one configuration entry point hands samples to a sink")
        XCTAssertTrue(declaration.contains("startRunning") && declaration.contains("stopRunning"))
        for entry in forbidden {
            XCTAssertFalse(declaration.contains(entry.token),
                           "the seam must not expose \(entry.token) (\(entry.meaning))")
        }
        XCTAssertFalse(declaration.contains("URL"),
                       "no frame may be described by a location on disk")
    }

    /// A frame is a buffer, a size and a timestamp — no bytes, no location.
    func testAFrameCarriesNoPersistableRepresentation() throws {
        let declaration = try XCTUnwrap(block(startingWith: "struct CameraFrame",
                                              in: "LiveCameraSession.swift"))
        XCTAssertTrue(declaration.contains("pixelBuffer"))
        XCTAssertTrue(declaration.contains("pixelSize"))
        XCTAssertTrue(declaration.contains("timestamp"))
        for token in ["Data", "URL", "Codable", "Encodable", "write", "save", "UIImage", "CGImage"] {
            XCTAssertFalse(declaration.contains(token),
                           "a frame must not be expressible as bytes or a file (\(token))")
        }
    }

    // MARK: Behaviour: the frame path writes nothing

    func testRunningTheFramePathLeavesTheFileSystemUntouched() async throws {
        var locations: [URL] = [FileManager.default.temporaryDirectory]
        locations += (try? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)) ?? []
        locations += (try? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)) ?? []
        let before = try locations.map(listing)

        let bus = LiveTranslateSanitisingBus()
        let layer = LiveCameraCaptureStub()
        // The tap samples at the configured cadence, so time has to move for
        // more than the first frame to be handed on.
        var now = 1_000.0
        let session = LiveCameraSession(config: .default,
                                        observabilityBus: bus,
                                        capture: layer,
                                        notificationCenter: NotificationCenter(),
                                        now: { now })
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        // A full pass over the path: sampled frames in, consumed by the
        // detector-side consumer, then torn down.
        for index in 1...4 {
            now += LiveTranslateConfig.default.ocrSampleInterval
            try layer.deliverFrame(width: 128, height: 96,
                                   pts: CMTime(value: CMTimeValue(index), timescale: 1))
            let frame = await nextFrame(frames, within: 2.0)
            XCTAssertNotNil(frame, "sample \(index) was not handed to the consumer")
        }
        session.stop()

        let after = try locations.map(listing)
        for (location, pair) in zip(locations, zip(before, after)) {
            XCTAssertEqual(pair.0, pair.1,
                           "the frame path created or removed entries under \(location.path)")
        }
    }

    // MARK: Helpers

    /// Every path under `root`, relative to it. Sorted set semantics: a
    /// creation, a deletion or a rename is a difference; a modification is
    /// not, so unrelated bookkeeping in a shared temp directory cannot make
    /// this check flake. The unit suite runs serially in one process, so no
    /// other test is writing while this one runs.
    private func listing(_ root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            paths.insert(String(url.path.dropFirst(root.path.count)))
        }
        return paths
    }

    /// The next frame within a bound, so a delivery regression fails the test
    /// instead of hanging the suite.
    private func nextFrame(_ iterator: AsyncStream<CameraFrame>.AsyncIterator,
                           within seconds: TimeInterval) async -> CameraFrame? {
        let waiter = Task { () -> CameraFrame? in
            var iterator = iterator
            return await iterator.next()
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            waiter.cancel()
        }
        let frame = await waiter.value
        timeout.cancel()
        return frame
    }

    /// The text of a top-level declaration's body: from the line that starts
    /// it to the next line that closes it at column zero. Source scanning, not
    /// parsing — a declaration that stops being recognisable fails loudly.
    private func block(startingWith prefix: String, in fileName: String) -> String? {
        let file = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(FeatureSourceScan.liveTranslateSources)
            .appendingPathComponent(fileName)
        let lines = FeatureSourceScan.codeText(of: file).split(separator: "\n",
                                                               omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
        var body: [String] = []
        for line in lines[start...] {
            body.append(String(line))
            if line == "}" { break }
        }
        return body.joined(separator: "\n")
    }
}
