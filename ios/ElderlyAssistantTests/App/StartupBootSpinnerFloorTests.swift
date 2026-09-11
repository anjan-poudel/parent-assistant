import XCTest
@testable import ElderlyAssistant

/// Guards the boot spinner's DELAYED APPEARANCE ([BOOT-REVIEW P0-3],
/// 2026-09-10): the indicator must not appear for the first
/// `StartupBoot.spinnerAppearanceDelaySeconds` of a boot, so work that
/// finishes inside that window shows nothing at all, and a boot that does
/// show one dismisses it the moment `.ready` lands — there is no
/// minimum-display floor any more (the old 2.5 s floor made a fast boot
/// look slow).
///
/// The pure `SpinnerAppearanceDelay` model is tested with injected dates
/// and `StartupBoot` with an injected clock (no real sleeps).
///
/// `TestClock` below is shared with `StartupBootTests`, which pins the
/// same appearance semantics on the phase-progression paths.
final class StartupBootSpinnerFloorTests: XCTestCase {

    // MARK: - Pure delay model

    func testDelayIsNotElapsedBeforeTheDelay() {
        let delay = SpinnerAppearanceDelay(delaySeconds: 0.2)
        let beganAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(delay.isElapsed(beganAt: beganAt, now: beganAt),
                       "a boot that just began must show nothing")
        XCTAssertFalse(delay.isElapsed(beganAt: beganAt,
                                       now: beganAt.addingTimeInterval(0.19)),
                       "0.19 s of a 0.2 s delay must NOT reveal")
    }

    func testDelayElapsesAtExactlyTheDelay() {
        let delay = SpinnerAppearanceDelay(delaySeconds: 0.2)
        let beganAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(delay.isElapsed(beganAt: beganAt,
                                      now: beganAt.addingTimeInterval(0.2)),
                      "the boundary itself is elapsed (>= semantics)")
        XCTAssertTrue(delay.isElapsed(beganAt: beganAt,
                                      now: beganAt.addingTimeInterval(9)))
    }

    func testRemainingCountsDownAndClampsAtZero() {
        let delay = SpinnerAppearanceDelay(delaySeconds: 0.2)
        let beganAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(delay.remaining(beganAt: beganAt,
                                       now: beganAt.addingTimeInterval(0.05)),
                       0.15, accuracy: 0.0001)
        XCTAssertEqual(delay.remaining(beganAt: beganAt,
                                       now: beganAt.addingTimeInterval(0.2)),
                       0, accuracy: 0.0001)
        // A clock that runs backwards (or a stale beganAt) yields a
        // LARGER remainder, never a negative one — the gate schedules,
        // it never misbehaves.
        XCTAssertEqual(delay.remaining(beganAt: beganAt,
                                       now: beganAt.addingTimeInterval(-3)),
                       3.2, accuracy: 0.0001)
    }

    func testElapsedMeasuresTimeSinceTheBootBegan() {
        let delay = SpinnerAppearanceDelay(delaySeconds: 0.2)
        let beganAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(delay.elapsed(beganAt: beganAt,
                                     now: beganAt.addingTimeInterval(1.25)),
                       1.25, accuracy: 0.0001)
    }

    /// The review's window is 150–250 ms: long enough that an ordinary boot
    /// never flashes an indicator, short enough that genuinely slow work
    /// still says something is happening.
    func testAppearanceDelaySitsInTheReviewWindow() {
        XCTAssertGreaterThanOrEqual(StartupBoot.spinnerAppearanceDelaySeconds, 0.15)
        XCTAssertLessThanOrEqual(StartupBoot.spinnerAppearanceDelaySeconds, 0.25)
    }

    // MARK: - StartupBoot with injected clock

    func testBootShowsNothingUntilTheDelayPasses() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        XCTAssertTrue(boot.hasStarted)
        XCTAssertFalse(boot.spinnerVisible,
                       "begin() alone must not show the spinner")

        clock.advance(by: 0.1)   // still inside the window
        boot.revealSpinnerIfNeeded()
        XCTAssertFalse(boot.spinnerVisible)

        // Past the window (deliberately past the boundary, so the
        // assertion never rides on double-rounding at exactly the delay).
        clock.advance(by: StartupBoot.spinnerAppearanceDelaySeconds)
        boot.revealSpinnerIfNeeded()
        XCTAssertTrue(boot.spinnerVisible,
                      "once the delay elapses, genuinely-slow work shows the spinner")
    }

    func testFastBootNeverShowsASpinner() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()

        // Boot completes 50 ms in — well inside the appearance window.
        clock.advance(by: 0.05)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible,
                       "a fast boot must never flash a spinner at all")

        // The stale appearance timer fires later: the gate stays closed on
        // a completed boot.
        clock.advance(by: StartupBoot.spinnerAppearanceDelaySeconds)
        boot.revealSpinnerIfNeeded()
        XCTAssertFalse(boot.spinnerVisible,
                       "a completed boot never reveals a late spinner")
    }

    func testSlowBootDismissesTheSpinnerTheMomentReady() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        clock.advance(by: StartupBoot.spinnerAppearanceDelaySeconds + 0.001)
        boot.revealSpinnerIfNeeded()
        XCTAssertTrue(boot.spinnerVisible)

        // 4 s of boot work later, `.ready` lands. No floor holds it: the
        // dismissal is immediate (the view animates the transition).
        clock.advance(by: 4.0)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible,
                       "no minimum-display floor — readiness dismisses at once")
    }

    func testRestartOpensAFreshAppearanceWindow() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        clock.advance(by: StartupBoot.spinnerAppearanceDelaySeconds + 0.001)
        boot.revealSpinnerIfNeeded()
        XCTAssertTrue(boot.spinnerVisible)
        boot.advance(to: .ready)
        XCTAssertFalse(boot.spinnerVisible)

        // Restart: hidden again from zero, and the PREVIOUS boot's elapsed
        // time must not fast-forward the new window away.
        boot.begin()
        XCTAssertFalse(boot.spinnerVisible)
        boot.revealSpinnerIfNeeded()
        XCTAssertFalse(boot.spinnerVisible,
                       "a restart gets its own full appearance delay")
        clock.advance(by: StartupBoot.spinnerAppearanceDelaySeconds + 0.001)
        boot.revealSpinnerIfNeeded()
        XCTAssertTrue(boot.spinnerVisible)
    }

    func testSpinnerStaysHiddenUntilBootBegins() {
        // The reveal gate alone never shows the spinner (on first run the
        // onboarding wizard may precede begin()).
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.revealSpinnerIfNeeded()
        XCTAssertFalse(boot.spinnerVisible)

        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        boot.revealSpinnerIfNeeded()
        XCTAssertFalse(boot.spinnerVisible,
                       "an unstarted boot never shows 'Loading…'")
    }

    func testDefaultClockStillProducesAWorkingBoot() {
        // The production default (Date.init, plus the real appearance
        // timer) must drive a full boot without traps.
        let boot = StartupBoot()
        boot.begin()
        boot.advance(to: .preparingVoice)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible)
    }
}

/// Fake wall clock for the appearance tests — time only moves when the
/// test says so, mirroring how production code reads `Date()` through the
/// injected closure. Shared with `StartupBootTests`.
final class TestClock {
    private(set) var now: Date

    init(startingAt start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    func tick() -> Date { now }
}
