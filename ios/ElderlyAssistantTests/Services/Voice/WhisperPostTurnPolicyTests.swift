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
///
/// [VOICE-OOM] (2026-10-10) Pins reshaped again by the jetsam logs: a
/// resident 4B brain admitted `soloOverBudget` (~3.4 GB live) was what
/// forced the per-turn page-in ping-pong (brain in / weights out, then
/// back). New pinned rules:
///  - an over-budget resident brain → `.releaseOnly(.brainOverBudget)`
///    regardless of the probe, checked FIRST — the brain stays, the
///    weights reload per turn at ~1.0 GB instead of the brain at
///    ~3.4 GB,
///  - the hold gate counts the REAL resident brain + a 512 MB margin.
///    This is NOT the old unreachable `footprint + llama headroom`
///    constant back from the dead: the old one added 1.2 GB no resident
///    claimed against a 2×-too-large footprint; this one adds the
///    ledger's number for a resident that actually exists (0 when none
///    is), so a brainless device keeps the footprint + margin calculus.
final class WhisperPostTurnPolicyTests: XCTestCase {

    private let footprint: UInt64 = 1_600_000_000
    private let margin = WhisperPostTurnPolicy.headroomMarginBytes

    // MARK: - Decision table ([LAT-EVIDENCE])

    func testWeightsFitWithMarginHolds() {
        // [VOICE-OOM] The hold gate is weights + margin with no brain
        // resident: held only when the probe clears the weights AND
        // leaves the margin room a turn's own spikes need.
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + margin,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .hold)
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + margin + 1,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .hold)
    }

    func testMarginalHeadroomReleasesOnly() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + margin - 1,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .releaseOnly(.ramHeadroom),
            "weights fit alone but the margin room is gone — holding would spike the turn into jetsam")
    }

    func testCriticalHeadroomReleasesOnly() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint - 1,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .releaseOnly(.ramCritical),
            "a reload would endanger the app — stay released, the next turn pays the load")
    }

    func testOverBudgetBrainForcesRelease() {
        // THE device case: a 4B admitted `soloOverBudget` (~3.4 GB live
        // on a 3.2 GB class budget). Even a generous probe must not
        // hold — holding beside it IS the per-turn page-in ping-pong,
        // and the brain's ~3.4 GB reload is the expensive half.
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint * 10,
                whisperFootprintBytes: footprint,
                activeBrain: WhisperPostTurnPolicy.ActiveBrain(
                    liveBytes: 3_400_000_000, isOverClassBudget: true)),
            .releaseOnly(.brainOverBudget))
    }

    func testResidentBrainCountsAgainstTheHeadroomGate() {
        // A within-budget resident brain still counts its REAL ledger
        // bytes: the gate is weights + brain + margin — re-warming into
        // a pit that then evicts the brain is the ping-pong in slow
        // motion.
        let brain = WhisperPostTurnPolicy.ActiveBrain(
            liveBytes: 1_980_000_000, isOverClassBudget: false)
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + brain.liveBytes + margin - 1,
                whisperFootprintBytes: footprint,
                activeBrain: brain),
            .releaseOnly(.ramHeadroom),
            "the room to keep the brain too is not there")
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + brain.liveBytes + margin,
                whisperFootprintBytes: footprint,
                activeBrain: brain),
            .hold,
            "weights + brain + margin — both may stay")
    }

    func testTTLIsThreeMinutes() {
        XCTAssertEqual(WhisperPostTurnPolicy.ttlSeconds, 180.0,
                       "the TTL pins at 180 s — a slow elderly answer after the reply still lands inside the hold")
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
        // cold load. A config with the weights resident + fitting (and
        // the margin available) holds regardless of any toggle state.
        let action = WhisperPostTurnPolicy.transcriptAction(
            config: residencyConfig(),
            availableBytes: footprint + margin,
            whisperFootprintBytes: footprint,
            activeBrain: .none)
        XCTAssertEqual(action, .hold)
    }

    func testTranscriptActionCriticalReleasesOnly() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(),
                availableBytes: footprint - 1,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .releaseOnly(.ramCritical))
    }

    func testTranscriptActionOverBudgetBrainReleases() {
        // [VOICE-OOM] The full coordinator path for the device's actual
        // situation: the policy applies (live WhisperKit weights) but a
        // soloOverBudget brain is resident — the action must release,
        // and it must carry the over-budget reason so the field capture
        // can tell it from a raw RAM squeeze.
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(),
                availableBytes: footprint * 10,
                whisperFootprintBytes: footprint,
                activeBrain: WhisperPostTurnPolicy.ActiveBrain(
                    liveBytes: 3_400_000_000, isOverClassBudget: true)),
            .releaseOnly(.brainOverBudget))
    }

    func testTranscriptActionNotApplicableWhenNothingLoaded() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(isModelLoaded: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .notApplicable,
            "a fallback STT served the turn — nothing to hold or re-warm")
    }

    func testTranscriptActionNotApplicableOutsideWhisperKitStack() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(stack: .gemini),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .notApplicable)
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(whisperKitIsActiveSTT: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
            .notApplicable)
        XCTAssertEqual(
            WhisperPostTurnPolicy.transcriptAction(
                config: residencyConfig(whisperKitAvailable: false),
                availableBytes: footprint * 2,
                whisperFootprintBytes: footprint,
                activeBrain: .none),
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
        // t+230 s, not the original t+180 s.
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
