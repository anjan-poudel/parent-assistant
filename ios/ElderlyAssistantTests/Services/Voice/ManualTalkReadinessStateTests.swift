import XCTest
@testable import ElderlyAssistant

/// Unit tests for the manual-Talk readiness machine ([BOOT-REVIEW P0-2],
/// 2026-09-10). The review's contract, pinned here rather than merely
/// documented on `AppCoordinator.voicePipelineReadiness`:
///
///  - the launch value is `.loading(.starting)` (the hero renders it from
///    the very first frame),
///  - `.ready` is reachable from EXACTLY ONE transition — the successful
///    `voicePipeline.start` completion callback,
///  - a failure is sticky: no timer, no other boot phase and no repeated
///    request can upgrade `.failed` to `.ready`,
///  - wake-word (KWS) engine state cannot move readiness in either
///    direction — manual Talk must come up when KWS degrades to Null.
///
/// Pure value transitions, no
/// coordinator, no queues, no clock).
final class ManualTalkReadinessStateTests: XCTestCase {

    // MARK: - Launch value

    func testInitialValueIsLoadingStarting() {
        let machine = ManualTalkReadinessState()
        XCTAssertEqual(machine.value, .loading(.starting))
        // The coordinator's published initial value IS this constant, so
        // the two cannot drift (a first frame that renders `.ready` would
        // claim a voice connection that does not exist yet).
        XCTAssertEqual(ManualTalkReadinessState.initial,
                       VoicePipelineReadiness.loading(.starting))
    }

    // MARK: - The one path to .ready

    func testStartSuccessIsTheOnlyPathToReady() {
        var machine = ManualTalkReadinessState()
        machine.noteStartRequested()
        XCTAssertEqual(machine.value, .loading(.starting),
                       "asking the pipeline to start is not a start")

        machine.noteStartSucceeded()
        XCTAssertEqual(machine.value, .ready)
    }

    func testRequestDoesNotSettleReadiness() {
        var machine = ManualTalkReadinessState()
        machine.noteStartRequested()
        machine.noteStartRequested()
        XCTAssertEqual(machine.value, .loading(.starting))
    }

    func testWakeWordEngineSettlingNeverMovesReadiness() {
        // Real engine: manual Talk is unaffected (it was never KWS-gated).
        var real = ManualTalkReadinessState()
        real.noteWakeWordEngineSettled(isReal: true)
        XCTAssertEqual(real.value, .loading(.starting))

        // Null engine (the honest degradation): manual Talk must still be
        // able to become ready — the KWS fallback is not a Talk failure.
        var null = ManualTalkReadinessState()
        null.noteWakeWordEngineSettled(isReal: false)
        XCTAssertEqual(null.value, .loading(.starting))
        null.noteStartSucceeded()
        XCTAssertEqual(null.value, .ready,
                       "manual Talk comes up even with a Null wake-word engine")
    }

    func testWakeWordEngineSettlingCannotResurrectAFailure() {
        var machine = ManualTalkReadinessState()
        machine.noteStartFailed(reason: "audio_session")
        machine.noteWakeWordEngineSettled(isReal: true)
        machine.noteWakeWordEngineSettled(isReal: false)
        XCTAssertEqual(machine.value, .failed(.pipelineStartFailed(reason: "audio_session")),
                       "nothing but a real start success clears a failure")
    }

    // MARK: - Sticky failure

    func testFailureCarriesTheMachineReason() {
        var machine = ManualTalkReadinessState()
        machine.noteStartFailed(reason: "engine_unavailable")
        XCTAssertEqual(machine.value,
                       .failed(.pipelineStartFailed(reason: "engine_unavailable")))
    }

    func testFailureIsNotClearedByARepeatedRequest() {
        var machine = ManualTalkReadinessState()
        machine.noteStartFailed(reason: "engine_unavailable")
        machine.noteStartRequested()
        XCTAssertEqual(machine.value,
                       .failed(.pipelineStartFailed(reason: "engine_unavailable")),
                       "a retry request must not wipe the honest failure "
                       + "before its callback answers")
    }

    func testRetrySuccessUpgradesFailureToReady() {
        var machine = ManualTalkReadinessState()
        machine.noteStartFailed(reason: "engine_unavailable")
        machine.noteStartRequested()
        machine.noteStartSucceeded()
        XCTAssertEqual(machine.value, .ready,
                       "the Talk hero's tap-to-retry is the recovery path")
    }

    func testReadyIsNeverDowngradedByARequest() {
        var machine = ManualTalkReadinessState()
        machine.noteStartSucceeded()
        machine.noteStartRequested()
        XCTAssertEqual(machine.value, .ready,
                       "the hero is already live — a recycle request must "
                       + "not re-gate it")
    }

    func testRepeatedSuccessIsIdempotent() {
        var machine = ManualTalkReadinessState()
        machine.noteStartSucceeded()
        machine.noteStartSucceeded()
        XCTAssertEqual(machine.value, .ready)
    }

    func testLatestFailureWins() {
        var machine = ManualTalkReadinessState()
        machine.noteStartFailed(reason: "first")
        machine.noteStartFailed(reason: "second")
        XCTAssertEqual(machine.value, .failed(.pipelineStartFailed(reason: "second")),
                       "the newest honest reason is the one shown")
    }

    // MARK: - Value semantics

    func testMachineIsAValueType() {
        // The coordinator holds the machine privately and publishes its
        // value; a copy must not alias, or a test/preview copy could move
        // the live hero's state.
        let original = ManualTalkReadinessState()
        var copy = original
        copy.noteStartSucceeded()
        XCTAssertEqual(original.value, .loading(.starting))
        XCTAssertEqual(copy.value, .ready)
    }
}
