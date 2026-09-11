import XCTest
@testable import ElderlyAssistant

/// [LAT-M1] Unit tests for the post-turn whisper weights policy: the
/// pure probe decision table and the TTL-hold owner with an injected
/// clock (no real sleeps — the same doctrine as `StartupBootTests`).
///
/// Pinned rules:
///  - ample headroom → HOLD the weights (back-to-back turns skip the
///    reload); the TTL runs from the LAST transcript (re-arm extends),
///  - marginal headroom → release now + re-warm after the turn,
///  - critical headroom → release and stay released (jetsam safety),
///  - the hold fires its expiry callback EXACTLY once, at/past the TTL.
final class WhisperPostTurnPolicyTests: XCTestCase {

    private let footprint: UInt64 = 1_600_000_000
    private let headroom = WhisperPostTurnPolicy.llamaRuntimeHeadroomBytes

    // MARK: - Decision table

    func testAmpleHeadroomHolds() {
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + headroom,
                whisperFootprintBytes: footprint),
            .hold)
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + headroom + 1,
                whisperFootprintBytes: footprint),
            .hold)
    }

    func testMarginalHeadroomReleasesAndReWarms() {
        // Fits the weights, but not the llama runtime too — release now,
        // re-warm after the turn.
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint,
                whisperFootprintBytes: footprint),
            .releaseAndReWarm)
        XCTAssertEqual(
            WhisperPostTurnPolicy.decide(
                availableBytes: footprint + headroom - 1,
                whisperFootprintBytes: footprint),
            .releaseAndReWarm)
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

    // MARK: - TTL hold (injected clock)

    private var now: Date!
    private var fired = 0

    private func tick(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

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
