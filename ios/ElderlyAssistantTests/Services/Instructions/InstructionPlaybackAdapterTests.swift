import AVFoundation
import XCTest
@testable import ElderlyAssistant

/// The AVKit adapter's contract (T-004; design L2 §2.7, §6.4, §8.2–8.3,
/// §11.2, §11.3 I).
///
/// Strategy. The mapping logic — status → ready/playerFailed, the
/// play-to-end observation → finished, the interruption → interrupted — is
/// driven through the adapter's internal handlers so every case is
/// deterministic; the real KVO path is exercised once
/// (`testReadyEmitsReadyOnce`, per design §8.1: simulator tests resolve
/// through `AVPlayerItem.status`), and the observer registrations
/// themselves are source-pinned (the suite's §11.2 evidence). Ordering
/// claims ("pauses before releasing") are pinned on the comment-stripped
/// source text of `dismiss`, the §11.3 E idiom.
///
/// Privacy. No test asserts on an `NSError`, a file path in a log or a raw
/// platform value: the adapter's whole contract is typed
/// `InstructionPlaybackEvent` values and it logs nothing. Fixtures are
/// written only into a per-test temporary directory.
///
/// Coverage note. The ten planned cases (T-004) are implemented verbatim;
/// `testInterruptionWhilePresentingMapsToInterrupted` is one extra case
/// because none of the ten covers the positive leg of the interruption
/// mapping, which design §2.7.2 pins as adapter behaviour.
@MainActor
final class InstructionPlaybackAdapterTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-playback-adapter-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures and helpers

    /// A valid, audio-only PCM WAV — a real media file AVFoundation can
    /// play (`AVURLAsset.isPlayable` is true; T-001's model suite pins the
    /// same fixture's metadata). Deterministic bytes: 0.1 s of silence at
    /// 8 kHz mono/16-bit. The adapter's preflight is the playability check
    /// only — video-track validation belongs to the store — so an audio
    /// fixture is exactly what a "playable local file" means for this seam.
    private func writeSilentWAV() throws -> URL {
        let url = tempDirectory.appendingPathComponent("silent-\(UUID().uuidString).wav")
        let sampleRate: UInt32 = 8_000
        let sampleCount = UInt32(Double(sampleRate) * 0.1)
        let dataBytes = sampleCount * 2

        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: Array(value.utf8))
        }
        func appendUInt32LE(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        func appendUInt16LE(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }

        appendASCII("RIFF")
        appendUInt32LE(36 + dataBytes)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32LE(16)              // fmt chunk size
        appendUInt16LE(1)               // linear PCM
        appendUInt16LE(1)               // mono
        appendUInt32LE(sampleRate)
        appendUInt32LE(sampleRate * 2)  // byte rate
        appendUInt16LE(2)               // block align
        appendUInt16LE(16)              // bits per sample
        appendASCII("data")
        appendUInt32LE(dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))

        try data.write(to: url)
        return url
    }

    /// A readable file that is not playable media.
    private func writeUnplayableFile() throws -> URL {
        let url = tempDirectory.appendingPathComponent("not-media-\(UUID().uuidString).mp4")
        try Data("this is not a video".utf8).write(to: url)
        return url
    }

    /// Lets main-queue blocks and main-actor tasks queued by AVFoundation
    /// observations run, without asserting anything about them.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private var playbackSourceURL: URL {
        FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Instructions/InstructionPlayback.swift")
    }

    private var adapterSourceURL: URL {
        FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Instructions/AVKitInstructionVideoPlayer.swift")
    }

    /// Comment-stripped source of the adapter (string literals preserved).
    private func adapterCode() -> String {
        FeatureSourceScan.codeText(of: adapterSourceURL)
    }

    /// The lines of one function's body from comment-stripped source, so the
    /// ordering pins can assert statement order (the §11.3 E idiom).
    private func functionBody(named signature: String, in code: String) -> [String]? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            return nil
        }
        let end = lines[(start + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("func ") || trimmed.hasPrefix("private func ")
                || trimmed.hasPrefix("deinit")
        } ?? lines.count
        return Array(lines[(start + 1)..<end])
    }

    // MARK: - Planned cases (T-004 named-test list)

    func testPresentationDoesNotAutoplay() throws {
        let url = try writeSilentWAV()
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()

        adapter.present(url: url) { events.append($0) }

        XCTAssertEqual(events, [.preflightPassed])
        let player = try XCTUnwrap(adapter.renderablePlayer,
                                   "a successful preflight constructs the player")
        XCTAssertEqual(player.rate, 0, "present never starts playback")
        XCTAssertEqual(player.timeControlStatus, .paused, "present never starts playback")
        XCTAssertNotNil(player.currentItem, "the item exists for the cover to play")

        // Source pins: the adapter never calls play and never activates or
        // reconfigures the audio session (design §2.7.4; FR-RIE-018: no
        // sound before an explicit user action).
        let code = adapterCode()
        XCTAssertFalse(code.contains(".play("), "the adapter must never call play()")
        XCTAssertFalse(code.contains(".playImmediately("), "the adapter must never start playback")
        XCTAssertFalse(code.contains("setActive"), "the adapter must never activate an audio session")
        XCTAssertFalse(code.contains("setCategory"), "the adapter must never reconfigure the audio session")

        adapter.dismiss()
    }

    func testPreflightMissingURLFailsUnsupported() {
        let missing = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString).mov")
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()

        adapter.present(url: missing) { events.append($0) }

        XCTAssertEqual(events, [.failed(.unsupported)],
                       "a missing file is one typed preflight failure")
        XCTAssertNil(adapter.renderablePlayer, "no player is constructed for a missing file")

        // Stays closed: with no observers registered, nothing can arrive.
        pump(0.3)
        XCTAssertEqual(events, [.failed(.unsupported)])
        XCTAssertNil(adapter.renderablePlayer)
    }

    func testPreflightUnplayableItemFails() throws {
        let url = try writeUnplayableFile()
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()

        adapter.present(url: url) { events.append($0) }

        XCTAssertEqual(events, [.failed(.unsupported)],
                       "an unplayable file is one typed preflight failure")
        XCTAssertNil(adapter.renderablePlayer, "no player is constructed for an unplayable file")

        pump(0.3)
        XCTAssertEqual(events, [.failed(.unsupported)])
        XCTAssertNil(adapter.renderablePlayer)
    }

    func testReadyEmitsReadyOnce() throws {
        let url = try writeSilentWAV()
        let ready = expectation(description: "item ready")
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()

        adapter.present(url: url) { event in
            events.append(event)
            if event == .ready { ready.fulfill() }
        }

        wait(for: [ready], timeout: 10)
        pump(0.5)
        XCTAssertEqual(events, [.preflightPassed, .ready],
                       "exactly one ready, and nothing else")

        // Source pins: the ready event came from the item-status KVO
        // registration (design §2.7.2), not from a poll.
        let code = adapterCode()
        XCTAssertTrue(code.contains("observe(\\.status"),
                      "ready must be KVO-driven over AVPlayerItem.status")
        XCTAssertFalse(code.contains("timeControlStatus"),
                       "no timeControlStatus polling loop is permitted")

        adapter.dismiss()
    }

    func testItemFailureEmitsPlayerFailed() throws {
        let url = try writeSilentWAV()
        let ready = expectation(description: "item ready")
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()
        adapter.present(url: url) { event in
            events.append(event)
            if event == .ready { ready.fulfill() }
        }
        wait(for: [ready], timeout: 10)

        adapter.handleItemStatus(.failed)

        XCTAssertEqual(events, [.preflightPassed, .ready, .failed(.playerFailed)],
                       "an item failure is one typed .playerFailed")

        // One plain failure: nothing after it reaches the caller.
        adapter.handleItemStatus(.readyToPlay)
        adapter.handlePlayedToEnd()
        adapter.handleFailedToReachEnd()
        adapter.handleInterruption(.began)
        pump(0.3)
        XCTAssertEqual(events, [.preflightPassed, .ready, .failed(.playerFailed)])

        adapter.dismiss()
    }

    func testFinishedOnlyAfterStart() throws {
        let url = try writeSilentWAV()
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()
        adapter.present(url: url) { events.append($0) }
        XCTAssertEqual(events, [.preflightPassed])

        // A platform finish before the item ever reached ready is spurious
        // and is dropped.
        adapter.handlePlayedToEnd()
        XCTAssertEqual(events, [.preflightPassed])

        adapter.handleItemStatus(.readyToPlay)
        XCTAssertEqual(events, [.preflightPassed, .ready])

        adapter.handlePlayedToEnd()
        XCTAssertEqual(events, [.preflightPassed, .ready, .finished])

        // A second finish observation is not a second event, and the real
        // KVO ready that may land on the pump cannot duplicate the ready.
        adapter.handlePlayedToEnd()
        pump(0.5)
        XCTAssertEqual(events, [.preflightPassed, .ready, .finished])

        // Source pins: the finish and mid-play failure observations exist.
        let code = adapterCode()
        XCTAssertTrue(code.contains(".AVPlayerItemDidPlayToEndTime"),
                      "the play-to-end observation must be registered (design §2.7.2)")
        XCTAssertTrue(code.contains(".AVPlayerItemFailedToPlayToEndTime"),
                      "the mid-play failure observation must be registered (design §2.7.2)")

        adapter.dismiss()
    }

    func testDismissPausesThenReleases() throws {
        let url = try writeSilentWAV()
        let ready = expectation(description: "item ready")
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()
        adapter.present(url: url) { event in
            events.append(event)
            if event == .ready { ready.fulfill() }
        }
        wait(for: [ready], timeout: 10)

        let player = try XCTUnwrap(adapter.renderablePlayer)
        player.play()
        pump(0.3)
        let eventsBeforeDismiss = events.count

        adapter.dismiss()
        pump(0.3)

        XCTAssertEqual(player.rate, 0, "dismiss pauses the player")
        XCTAssertEqual(player.timeControlStatus, .paused, "dismiss pauses the player")
        XCTAssertNil(player.currentItem, "dismiss clears the item")
        XCTAssertNil(adapter.renderablePlayer, "dismiss releases the player")
        XCTAssertEqual(events.count, eventsBeforeDismiss, "no event after dismiss returns")

        // Source pin: inside dismiss, the pause comes before the item clear
        // and the release (T-004 scenario "Dismiss pauses before
        // releasing"; design §2.7.3).
        let code = adapterCode()
        let dismissBody = try XCTUnwrap(functionBody(named: "func dismiss()", in: code))
        let pauseLine = try XCTUnwrap(dismissBody.firstIndex { $0.contains("pause()") })
        let clearLine = try XCTUnwrap(dismissBody.firstIndex { $0.contains("replaceCurrentItem(with: nil)") })
        let releaseLine = try XCTUnwrap(dismissBody.firstIndex { $0.contains("renderablePlayer = nil") })
        XCTAssertLessThan(pauseLine, clearLine)
        XCTAssertLessThan(clearLine, releaseLine)
    }

    func testLateObservationAfterDismissIgnored() throws {
        let url = try writeSilentWAV()
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()
        adapter.present(url: url) { events.append($0) }
        let item = try XCTUnwrap(adapter.renderablePlayer?.currentItem)

        adapter.dismiss()
        let eventsAtDismiss = events.count

        // Late platform deliveries: the real notifications (whose observers
        // dismiss removed) and the handler paths (whose dismissed guard
        // drops them).
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        adapter.handleItemStatus(.readyToPlay)
        adapter.handlePlayedToEnd()
        adapter.handleFailedToReachEnd()
        adapter.handleInterruption(.began)
        pump(0.3)

        XCTAssertEqual(events.count, eventsAtDismiss,
                       "no event reaches the caller after dismiss returns")
    }

    func testAdapterHasNoTimers() throws {
        let code = adapterCode()
        for token in ["Timer(", "scheduledTimer", "asyncAfter", "Task.sleep",
                      "DispatchSourceTimer", "Timer.publish"] {
            XCTAssertFalse(code.contains(token),
                           "the adapter owns no timer; found '\(token)'")
        }

        // The seam's own file declares values only, never a timer.
        let playbackCode = FeatureSourceScan.codeText(of: playbackSourceURL)
        for token in ["Timer(", "scheduledTimer", "asyncAfter", "Task.sleep",
                      "DispatchSourceTimer"] {
            XCTAssertFalse(playbackCode.contains(token),
                           "InstructionPlayback.swift owns no timer; found '\(token)'")
        }
    }

    func testAdapterPerformsNoNetworkOrTranscode() throws {
        let code = adapterCode()
        for token in ["URLSession", "dataTask", "uploadTask", "downloadTask",
                      "AVAssetExportSession", "AVAssetWriter", "exportAsynchronously",
                      "http://", "https://", "canUseNetworkResources"] {
            XCTAssertFalse(code.contains(token),
                           "no network or transcode call site may exist; found '\(token)'")
        }

        let playbackCode = FeatureSourceScan.codeText(of: playbackSourceURL)
        for token in ["URLSession", "dataTask", "AVAssetExportSession",
                      "AVAssetWriter", "exportAsynchronously", "http://", "https://"] {
            XCTAssertFalse(playbackCode.contains(token),
                           "InstructionPlayback.swift has no network or transcode call site; found '\(token)'")
        }
    }

    // MARK: - Interruption mapping (positive leg)

    /// The design's fourth observation (design §2.7.2): an audio-session
    /// interruption while presenting is one typed `.failed(.interrupted)`.
    /// Not in T-004's planned ten names; added because none of them covers
    /// the positive leg and the mapping is a pinned contract.
    func testInterruptionWhilePresentingMapsToInterrupted() throws {
        let url = try writeSilentWAV()
        var events: [InstructionPlaybackEvent] = []
        let adapter = AVKitInstructionVideoPlayer()
        adapter.present(url: url) { events.append($0) }

        // `.ended` (the system returned our audio) is not a failure, and a
        // missing type is not an event either.
        adapter.handleInterruption(.ended)
        adapter.handleInterruption(nil)
        XCTAssertEqual(events, [.preflightPassed])

        adapter.handleInterruption(.began)
        XCTAssertEqual(events, [.preflightPassed, .failed(.interrupted)])

        // One plain failure: the late real ready cannot resurrect the
        // session, and the interruption observation is registered.
        pump(0.5)
        XCTAssertEqual(events, [.preflightPassed, .failed(.interrupted)])
        XCTAssertTrue(adapterCode().contains("interruptionNotification"),
                      "the interruption observation must be registered (design §2.7.2)")

        adapter.dismiss()
    }
}
