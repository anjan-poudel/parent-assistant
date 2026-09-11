import XCTest
@testable import ElderlyAssistant

/// [BOOT-M1] Readiness registry state-machine tests — pure, no seams:
/// the design's write/read rules, the `.preparing`-until-first-write
/// default, failure monotonicity, and the explicit `retry(id:)`
/// recovery API. The registry is main-confined; XCTest runs synchronous
/// test methods on the main thread, which is where the asserts inside
/// the registry are satisfied.
@MainActor
final class FeatureReadinessTests: XCTestCase {

    private var registry: ReadinessRegistry!

    override func setUp() {
        super.setUp()
        registry = ReadinessRegistry()
    }

    // MARK: - Defaults + basic writes

    func testStateDefaultsToPreparingBeforeFirstWrite() {
        for feature in FeatureID.allCases {
            XCTAssertEqual(registry.state(of: feature), .preparing)
        }
    }

    func testSetWritesAndReadsBack() {
        registry.set(.voicePipeline, .ready)
        XCTAssertEqual(registry.state(of: .voicePipeline), .ready)

        registry.set(.voicePipeline, .failed(reason: "sherpa segfault"))
        XCTAssertEqual(registry.state(of: .voicePipeline),
                       .failed(reason: "sherpa segfault"))

        registry.set(.voicePipeline, .unavailable(reason: "no API key"))
        XCTAssertEqual(registry.state(of: .voicePipeline),
                       .unavailable(reason: "no API key"))
    }

    func testFeaturesTrackIndependently() {
        registry.set(.stt, .ready)
        registry.set(.tts, .failed(reason: "no voice"))

        XCTAssertEqual(registry.state(of: .stt), .ready)
        XCTAssertEqual(registry.state(of: .tts), .failed(reason: "no voice"))
        // Untouched features keep the honest `.preparing` default.
        XCTAssertEqual(registry.state(of: .wakeWord), .preparing)
    }

    func testPublishedStatesExposeTheSameMap() {
        registry.set(.brain, .ready)
        XCTAssertEqual(registry.states[.brain], .ready)
        XCTAssertNil(registry.states[.feeds], "no entry until first write")
    }

    // MARK: - Failure monotonicity

    func testFailedCannotSlideBackToPreparingThroughSet() {
        registry.set(.medications, .failed(reason: "storage corrupt"))
        registry.set(.medications, .preparing)
        XCTAssertEqual(registry.state(of: .medications),
                       .failed(reason: "storage corrupt"),
                       "failed → preparing must require the explicit retry API")
    }

    func testFailedReasonSurvivesTheBlockedPreparingWrite() {
        registry.set(.briefing, .failed(reason: "no sources"))
        registry.set(.briefing, .preparing)
        XCTAssertEqual(registry.state(of: .briefing), .failed(reason: "no sources"))
    }

    func testSuccessAfterFailureIsAllowedThroughSet() {
        registry.set(.contacts, .failed(reason: "decode error"))
        registry.set(.contacts, .ready)
        XCTAssertEqual(registry.state(of: .contacts), .ready,
                       "success always wins — only the preparing slide-back is gated")
    }

    func testUnavailableCanSlideToPreparingThroughSet() {
        // Only `failed` is monotonic; a feature that merely does not
        // exist may legitimately start preparing (e.g. onboarding).
        registry.set(.biometrics, .unavailable(reason: nil))
        registry.set(.biometrics, .preparing)
        XCTAssertEqual(registry.state(of: .biometrics), .preparing)
    }

    // MARK: - retry(id:)

    func testRetryResetsFailedToPreparing() {
        registry.set(.alarmsTimers, .failed(reason: "keychain read"))
        registry.retry(id: .alarmsTimers)
        XCTAssertEqual(registry.state(of: .alarmsTimers), .preparing)
    }

    func testRetryResetsUnavailableToPreparing() {
        registry.set(.calendarImport, .unavailable(reason: "not enabled"))
        registry.retry(id: .calendarImport)
        XCTAssertEqual(registry.state(of: .calendarImport), .preparing)
    }

    func testRetryIsANoOpFromPreparingAndReady() {
        XCTAssertEqual(registry.state(of: .places), .preparing)
        registry.retry(id: .places)
        XCTAssertEqual(registry.state(of: .places), .preparing)

        registry.set(.places, .ready)
        registry.retry(id: .places)
        XCTAssertEqual(registry.state(of: .places), .ready,
                       "retry must never disturb a ready feature")
    }

    func testRetryThenSetFlowRecoversHonestly() {
        registry.set(.history, .failed(reason: "decode"))
        registry.retry(id: .history)
        XCTAssertEqual(registry.state(of: .history), .preparing)
        registry.set(.history, .ready)
        XCTAssertEqual(registry.state(of: .history), .ready)
    }

    // MARK: - Catalog

    func testFeatureCatalogMatchesTheDesign() {
        XCTAssertEqual(Set(FeatureID.allCases.map(\.rawValue)), Set([
            "voicePipeline", "wakeWord", "stt", "tts", "brain",
            "medications", "routines", "alarmsTimers", "briefing",
            "biometrics", "feeds", "calendarImport", "calendarMirror",
            "history", "contacts", "places", "appointments",
            "modelHousekeeping", "notifications"
        ]))
        XCTAssertEqual(FeatureID.allCases.count, 19)
    }

    // MARK: - FeaturePreparing contract shape

    func testFeaturePreparingContractShapes() {
        let bootPreparer = StubPreparer(featureID: .stt, phase: .boot)
        let lazyPreparer = StubPreparer(featureID: .brain, phase: .lazy)

        XCTAssertEqual(bootPreparer.featureID, .stt)
        XCTAssertEqual(bootPreparer.phase, .boot)
        XCTAssertEqual(lazyPreparer.phase, .lazy)

        // prepare(on:) must be callable with any queue — the stub just
        // proves the protocol's shape compiles and is driven uniformly.
        let queue = DispatchQueue(label: "test.preparer")
        let done = expectation(description: "prepare called")
        var stub = bootPreparer
        stub.onPrepare = { done.fulfill() }
        stub.prepare(on: queue)
        wait(for: [done], timeout: 1)
    }
}

private struct StubPreparer: FeaturePreparing {
    let featureID: FeatureID
    let phase: PreparationPhase
    var onPrepare: (() -> Void)?

    func prepare(on queue: DispatchQueue) {
        queue.async { onPrepare?() }
    }
}
