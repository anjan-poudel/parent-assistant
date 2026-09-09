import XCTest
@testable import ElderlyAssistant

/// Guards the boot spinner's minimum-visibility floor ([LAUNCH-SCREEN],
/// 2026-09-10): a fast boot must still show the spinner for at least
/// `StartupBoot.spinnerMinVisibleSeconds` so it is actually perceivable
/// — a floor on dismissal ONLY. Boot work is never delayed: `.ready`
/// publishes the instant boot completes. The pure `SpinnerVisibilityFloor`
/// model is tested with injected dates, and `StartupBoot` with an
/// injected clock (no real sleeps).
///
/// `TestClock` below is shared with `StartupBootTests`, which pins the
/// same floor semantics on the phase-progression paths.
final class StartupBootSpinnerFloorTests: XCTestCase {

    // MARK: - Pure floor model

    func testFloorIsNotElapsedBeforeMinimum() {
        let floor = SpinnerVisibilityFloor(minVisibleSeconds: 2.5)
        let visibleAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(floor.isElapsed(firstVisibleAt: visibleAt,
                                       now: visibleAt.addingTimeInterval(0)))
        XCTAssertFalse(floor.isElapsed(firstVisibleAt: visibleAt,
                                       now: visibleAt.addingTimeInterval(2.49)),
                       "2.49 s of a 2.5 s floor must NOT dismiss")
    }

    func testFloorElapsesAtExactlyTheMinimum() {
        let floor = SpinnerVisibilityFloor(minVisibleSeconds: 2.5)
        let visibleAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(floor.isElapsed(firstVisibleAt: visibleAt,
                                      now: visibleAt.addingTimeInterval(2.5)),
                      "the boundary itself is elapsed (>= semantics)")
        XCTAssertTrue(floor.isElapsed(firstVisibleAt: visibleAt,
                                      now: visibleAt.addingTimeInterval(9)))
    }

    func testRemainingCountsDownAndClampsAtZero() {
        let floor = SpinnerVisibilityFloor(minVisibleSeconds: 2.5)
        let visibleAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(floor.remaining(firstVisibleAt: visibleAt,
                                       now: visibleAt.addingTimeInterval(1)),
                       1.5, accuracy: 0.0001)
        XCTAssertEqual(floor.remaining(firstVisibleAt: visibleAt,
                                       now: visibleAt.addingTimeInterval(2.5)),
                       0, accuracy: 0.0001)
        // A clock that runs backwards (or a stale visibleAt) yields a
        // LARGER remainder, never a negative one — the gate schedules,
        // it never misbehaves.
        XCTAssertEqual(floor.remaining(firstVisibleAt: visibleAt,
                                       now: visibleAt.addingTimeInterval(-3)),
                       5.5, accuracy: 0.0001)
    }

    func testElapsedMeasuresTimeSinceFirstVisible() {
        let floor = SpinnerVisibilityFloor(minVisibleSeconds: 2.5)
        let visibleAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(floor.elapsed(firstVisibleAt: visibleAt,
                                     now: visibleAt.addingTimeInterval(1.25)),
                       1.25, accuracy: 0.0001)
    }

    // MARK: - StartupBoot with injected clock

    func testFastBootHoldsSpinnerUntilFloorElapses() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        XCTAssertTrue(boot.spinnerVisible)

        // Boot completes 1 s in — far under the 2.5 s floor.
        clock.advance(by: 1.0)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete, "the floor must never delay boot work")
        XCTAssertTrue(boot.spinnerVisible,
                      "a fast boot must not flash the spinner for one frame")

        // Ticking the gate before the floor passes changes nothing.
        boot.dismissSpinnerIfFloorElapsed()
        XCTAssertTrue(boot.spinnerVisible)

        // Once the floor passes, the gate dismisses.
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds)
        boot.dismissSpinnerIfFloorElapsed()
        XCTAssertFalse(boot.spinnerVisible)
    }

    func testFloorElapsedAtReadyDismissesImmediately() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds + 1)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible,
                       "a slow boot dismisses the moment the floor is satisfied")
    }

    func testRestartOpensAFreshVisibilityWindow() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds + 1)
        boot.advance(to: .ready)
        XCTAssertFalse(boot.spinnerVisible)

        // Restart: the spinner returns AND a fresh floor window starts —
        // the old boot's elapsed time must not fast-forward it away.
        boot.begin()
        XCTAssertTrue(boot.spinnerVisible)
        clock.advance(by: 1.0)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.spinnerVisible, "a restart resets the floor window")
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds)
        boot.dismissSpinnerIfFloorElapsed()
        XCTAssertFalse(boot.spinnerVisible)
    }

    func testSpinnerStaysHiddenUntilBootBegins() {
        // advance() alone never shows the spinner (on first run the
        // onboarding wizard may precede begin()) — the floor only
        // applies once the spinner is actually visible.
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible)
    }

    func testDefaultClockStillProducesAWorkingBoot() {
        // The production default (Date.init) must drive a full boot
        // without traps.
        let boot = StartupBoot()
        boot.begin()
        XCTAssertTrue(boot.spinnerVisible)
        boot.advance(to: .preparingVoice)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
    }
}

/// Fake wall clock for the floor tests — time only moves when the test
/// says so, mirroring how production code reads `Date()` through the
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
