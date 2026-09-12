import XCTest
@testable import ElderlyAssistant

/// [LAT-M1] Unit tests for the post-turn whisper weights policy: the
/// pure probe decision table and the TTL-hold owner with an injected
/// clock (no real sleeps — the same doctrine as `StartupBootTests`).
///
/// [LAT-EVIDENCE] (2026-09-12) Pins reshaped by device evidence —
/// turn 2 paid a 135 s reload (`MILCompilerForANE error: failed to
/// compile ANE model`) because the [LAT-M1] hold gate
/// (`footprint + llama headroom`) is unreachable on device and the
/// re-warm re-probed against the same gate (`rewarm outcome=skipped`).
/// New pinned rules:
///  - the weights are HELD whenever THEY fit under the current
///    ceiling — the llama-headroom tier is gone (marginal no longer
///    forces a release),
///  - critical RAM (the weights do not fit) → release only,
///  - post-turn residency NEVER depends on the warm-start preference
///    (the toggle gates BOOT warm only) — `ResidencyConfig` has no
///    warm input by construction,
///  - when the TTL hold lapses the weights are released AND a
///    background re-warm is required (never skipped by policy) — the
///    `WhisperResidencyCycle` pin, with an injected clock.
final class WhisperPostTurnPolicyTests: XCTestCase {

    private let footprint: UInt64 = 1_600_000_000

    // MARK: - Decision table ([LAT-EVIDENCE])

    func testWeightsFitHolds() {
        // The [LAT-M1] `footprint + llama headroom` gate never held on
        // device (the probe's ceiling is typically 1–3 GB); the hold
        // now fires whenever the weights themselves fit.
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint,
                whisperFootprintBytes: footprint),
            .hold)
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + 1,
                whisperFootprintBytes: footprint),
            .hold)
    }

    func testCriticalHeadroomReleasesOnly() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint - 1,
                whisperFootprintBytes: footprint),
            .releaseOnly,
            "a reload would endanger the app — stay released, the next turn pays the load")
    }

    func testTTLIsSixtySeconds() {
        XCTAssertEqual(WhisperPostTurnPolicy.ttlSeconds, 60.0,
                       "the TTL pins at 60 s — back-to-back turns inside a minute skip the reload")
    }

    // MARK: - Transcript action ([LAT-EVIDENCE])

    private func residencyConfig(stack: VoiceEngineStack = .onDevice,
                                 whisperKitIsActiveSTT: Bool = true,
                                 whisperKitAvailable: Bool = true,
                                 isModelLoaded: Bool = true) -> WhisperPostTurnPolicy.ResidencyConfig {
        WhisperPostTurnPolicy.ResidencyConfig(
            stack: stack,
            whisperKitIsActiveSTT: whisperKitIsActiveSTT,
            whisperKitAvailable: whisperKitAvailable,
            isModelLoaded: isModelLoaded)
    }

    func testResidencyHoldsIndependentOfWarmPreference() {
        // The warm-start toggle gates the BOOT warm only
        // (`WarmStartPlanner.plan(for:)`). `ResidencyConfig` has NO warm
        // input by construction, so the coordinator's hold decision
        // cannot depend on the toggle — device evidence: with warm-start
        // OFF the weights were released after turn 1 and turn 2 paid the
        // cold load. A config with the weights resident + fitting holds
        // regardless of any toggle state.
        let action = WhisperPostTurnPolicy.transcriptAction(
            config: residencyConfig(),
            availableBytes: footprint,
            whisperFootprintBytes: footprint)
        XCTAssertEqual(action, .hold)
    }

    func testTranscriptActionCriticalReleasesOnly() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(),
                availableBytes: footprint - 1,
                whisperFootprintBytes: footprint),
            .releaseOnly)
    }

    func testTranscriptActionNotApplicableWhenNothingLoaded() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(isModelLoaded: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint),
            .notApplicable,
            "a fallback STT served the turn — nothing to hold or re-warm")
    }

    func testTranscriptActionNotApplicableOutsideWhisperKitStack() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(stack: .gemini),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint),
            .notApplicable)
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(whisperKitIsActiveSTT: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint),
            .notApplicable)
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(whisperKitAvailable: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint),
            .notApplicable)
    }

    // MARK: - Residency cycle: expiry re-warm ([LAT-EVIDENCE])

    private var now: Date!
    private var fired = 0
    private var released = 0
    private var reWarmRequests = 0

    private func tick(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    private func makeCycle() -> WhisperResidencyCycle {
        WhisperResidencyCycle(clock: { [weak self] in
            self?.now ?? Date(timeIntervalSince1970: 0)
        }, onRelease: { [weak self] in
            self?.released += 1
        }, onReWarmRequired: { [weak self] in
            self?.reWarmRequests += 1
        })
    }

    func testHoldExpiryReleasesAndRequiresReWarm() {
        // The [LAT-EVIDENCE] core pin: when the TTL hold lapses, the
        // weights are released AND the background re-warm is REQUIRED —
        // never skipped by policy (the re-warm's own probe is the only
        // gate), so the next turn is warm again.
        now = Date(timeIntervalSince1970: 1_000_000)
        let cycle = makeCycle()
        cycle.arm()

        tick(WhisperPostTurnPolicy.ttlSeconds - 1)
        XCTAssertFalse(cycle.hold.expireIfNeeded(now: now))
        XCTAssertEqual(released, 0)
        XCTAssertEqual(reWarmRequests, 0)

        tick(1)
        XCTAssertTrue(cycle.hold.expireIfNeeded(now: now))
        XCTAssertFalse(cycle.hold.isHolding)
        XCTAssertEqual(released, 1, "expiry releases the weights exactly once")
        XCTAssertEqual(reWarmRequests, 1, "expiry REQUIRES the background re-warm — not skipped")

        // A second expiry call is a no-op.
        tick(10)
        XCTAssertFalse(cycle.hold.expireIfNeeded(now: now))
        XCTAssertEqual(released, 1)
        XCTAssertEqual(reWarmRequests, 1)
    }

    func testReWarmedWeightsReArmTheCycle() {
        // The re-warm success re-arms the same TTL hold: the cycle
        // repeats, so the weights stay resident between turns whenever
        // the probe allows.
        now = Date(timeIntervalSince1970: 1_000_000)
        let cycle = makeCycle()
        cycle.arm()
        tick(WhisperPostTurnPolicy.ttlSeconds)
        XCTAssertTrue(cycle.hold.expireIfNeeded(now: now))

        // The background re-warm finished — re-arm.
        cycle.arm()
        XCTAssertTrue(cycle.hold.isHolding)
        tick(WhisperPostTurnPolicy.ttlSeconds)
        XCTAssertTrue(cycle.hold.expireIfNeeded(now: now))
        XCTAssertEqual(released, 2)
        XCTAssertEqual(reWarmRequests, 2)
    }

    func testCancelClearsWithoutExpirySideEffects() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let cycle = makeCycle()
        cycle.arm()
        cycle.cancel()
        XCTAssertFalse(cycle.hold.isHolding)

        tick(WhisperPostTurnPolicy.ttlSeconds * 2)
        XCTAssertFalse(cycle.hold.expireIfNeeded(now: now))
        XCTAssertEqual(released, 0)
        XCTAssertEqual(reWarmRequests, 0,
                       "a cancelled hold never releases or re-warms — another path released the weights")
    }

    // MARK: - TTL hold (injected clock)

    private func makeHold() -> WhisperWeightsHold {
        WhisperWeightsHold(clock: { [weak self] in
            self?.now ?? Date(timeIntervalSince1970: 0)
        })
    }

    func testArmStartsAHoldForTheTTL() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let hold = makeHold()
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }

        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.holdsUntil,
                       now.addingTimeInterval(WhisperPostTurnPolicy.ttlSeconds))
        // Before the TTL nothing fires.
        tick(WhisperPostTurnPolicy.ttlSeconds - 1)
        XCTAssertFalse(hold.expireIfNeeded(now: now))
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(fired, 0)
    }

    func testExpiryFiresExactlyOnceAtTheTTL() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let hold = makeHold()
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }

        tick(WhisperPostTurnPolicy.ttlSeconds)
        XCTAssertTrue(hold.expireIfNeeded(now: now), "at the TTL the hold lapses")
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(fired, 1)

        // A second expiry call is a no-op — the callback fired once.
        tick(10)
        XCTAssertFalse(hold.expireIfNeeded(now: now))
        XCTAssertEqual(fired, 1)
    }

    func testReArmExtendsFromTheLastTranscript() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let hold = makeHold()
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }

        // A back-to-back transcript at t+50 s re-arms: the new expiry is
        // t+110 s, not the original t+60 s.
        tick(50)
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }
        XCTAssertEqual(hold.holdsUntil,
                       now.addingTimeInterval(WhisperPostTurnPolicy.ttlSeconds))

        // The original deadline passes — still holding.
        tick(10)
        XCTAssertFalse(hold.expireIfNeeded(now: now))
        XCTAssertEqual(fired, 0)

        // The extended deadline passes — fires once.
        tick(WhisperPostTurnPolicy.ttlSeconds)
        XCTAssertTrue(hold.expireIfNeeded(now: now))
        XCTAssertEqual(fired, 1)
    }

    func testCancelClearsWithoutFiring() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let hold = makeHold()
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }

        hold.cancel()
        XCTAssertFalse(hold.isHolding)
        tick(WhisperPostTurnPolicy.ttlSeconds * 2)
        XCTAssertFalse(hold.expireIfNeeded(now: now))
        XCTAssertEqual(fired, 0,
                       "a cancelled hold never fires — the weights were released by another path")
    }

    func testReArmAfterCancelStartsAFreshHold() {
        now = Date(timeIntervalSince1970: 1_000_000)
        let hold = makeHold()
        hold.arm(ttl: 10) { self.fired += 1 }
        hold.cancel()
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { self.fired += 1 }

        tick(WhisperPostTurnPolicy.ttlSeconds)
        XCTAssertTrue(hold.expireIfNeeded(now: now))
        XCTAssertEqual(fired, 1)
    }
}
