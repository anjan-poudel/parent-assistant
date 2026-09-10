import XCTest
@testable import ElderlyAssistant

/// [HOME-TIMER-CHIP] (2026-09-11) The chip's pure computation:
/// nearest-timer selection, ticking under an injected clock, expiry, the
/// documented pause-freeze limit, and the countdown text shapes.
final class HomeTimerChipModelTests: XCTestCase {

    /// Fixed epoch base — every deadline is derived from it so the tests
    /// never depend on the wall clock.
    private let base = Date(timeIntervalSince1970: 1_752_000_000)

    private func timer(id: UUID = UUID(),
                       endsAt: Date,
                       label: String? = nil,
                       isActive: Bool = true) -> TimerItem {
        TimerItem(id: id, endsAt: endsAt, label: label, isActive: isActive)
    }

    // MARK: Visibility + expiry

    func testNoTimersYieldsHiddenSnapshot() {
        let snapshot = HomeTimerChipModel.snapshot(timers: [], at: base)
        XCTAssertFalse(snapshot.isVisible)
        XCTAssertNil(snapshot.timerID)
        XCTAssertNil(snapshot.endsAt)
        XCTAssertEqual(snapshot.activeCount, 0)
    }

    func testTimerWhoseDeadlineArrivedIsNotRunning() {
        // The chip mirrors the service's live rule (endsAt > now): a row
        // at or past its deadline is finished, not running.
        let atDeadline = timer(endsAt: base)
        let pastDeadline = timer(endsAt: base.addingTimeInterval(-1))

        let snapshot = HomeTimerChipModel.snapshot(timers: [atDeadline, pastDeadline], at: base)

        XCTAssertFalse(snapshot.isVisible, "a finished timer must not show the chip")
    }

    func testInactiveTimerIsNotRunning() {
        let snapshot = HomeTimerChipModel.snapshot(
            timers: [timer(endsAt: base.addingTimeInterval(60), isActive: false)],
            at: base)
        XCTAssertFalse(snapshot.isVisible)
    }

    func testRunningTimerIsVisible() {
        let id = UUID()
        let snapshot = HomeTimerChipModel.snapshot(
            timers: [timer(id: id, endsAt: base.addingTimeInterval(65))],
            at: base)
        XCTAssertTrue(snapshot.isVisible)
        XCTAssertEqual(snapshot.timerID, id)
        XCTAssertEqual(snapshot.remaining, 65)
        XCTAssertEqual(snapshot.activeCount, 1)
    }

    // MARK: Ticking (injected clock)

    func testRemainingTicksDownWithTheInjectedClock() {
        let id = UUID()
        let rows = [timer(id: id, endsAt: base.addingTimeInterval(65))]

        let first = HomeTimerChipModel.snapshot(timers: rows, at: base)
        let second = HomeTimerChipModel.snapshot(timers: rows, at: base.addingTimeInterval(30))
        let third = HomeTimerChipModel.snapshot(timers: rows, at: base.addingTimeInterval(64))

        XCTAssertEqual(first.remaining, 65)
        XCTAssertEqual(second.remaining, 35)
        XCTAssertEqual(third.remaining, 1, "ceiling keeps the last second visible")
    }

    func testRemainingRoundsUpToWholeSeconds() {
        // 59.2 s left must render as 60, never 59 — the chip never
        // under-reports what the user sees coming.
        let snapshot = HomeTimerChipModel.snapshot(
            timers: [timer(endsAt: base.addingTimeInterval(59.2))],
            at: base)
        XCTAssertEqual(snapshot.remaining, 60)
    }

    // MARK: Nearest selection + multiple

    func testNearestEndsAtWinsAmongMultipleTimers() {
        let far = UUID()
        let near = UUID()
        let rows = [
            timer(id: far, endsAt: base.addingTimeInterval(600), label: "far"),
            timer(id: near, endsAt: base.addingTimeInterval(120), label: "near")
        ]

        let snapshot = HomeTimerChipModel.snapshot(timers: rows, at: base)

        XCTAssertEqual(snapshot.timerID, near, "the soonest deadline is the chip's timer")
        XCTAssertEqual(snapshot.label, "near")
        XCTAssertEqual(snapshot.remaining, 120)
        XCTAssertEqual(snapshot.activeCount, 2)
    }

    func testExpiredNearestIsSkippedForTheNextRunningTimer() {
        // The nearest row finished (deadline passed) but has not been
        // swept yet — the chip must show the NEXT running timer, never a
        // 0:00 ghost.
        let dead = UUID()
        let live = UUID()
        let rows = [
            timer(id: dead, endsAt: base.addingTimeInterval(-30)),
            timer(id: live, endsAt: base.addingTimeInterval(90))
        ]

        let snapshot = HomeTimerChipModel.snapshot(timers: rows, at: base)

        XCTAssertEqual(snapshot.timerID, live)
        XCTAssertEqual(snapshot.remaining, 90)
        XCTAssertEqual(snapshot.activeCount, 1)
    }

    // MARK: Honest limits

    func testPausedSystemTimerFreezesTheDerivedRemaining() {
        // PAUSE IS NOT MODELED (the app-side record carries no pause
        // state — see `HomeTimerChipModel`): if the SYSTEM countdown is
        // paused from the system UI, `endsAt` stays put and the derived
        // remaining stops ticking down. This test PINS that the model
        // derives purely from `endsAt` — the chip is an independent
        // rendering, not a mirror of the system countdown, and the app's
        // own stop is cancel-only by design.
        let rows = [timer(endsAt: base.addingTimeInterval(120))]

        let atStart = HomeTimerChipModel.snapshot(timers: rows, at: base)
        let afterAWhile = HomeTimerChipModel.snapshot(timers: rows, at: base.addingTimeInterval(45))

        XCTAssertEqual(atStart.remaining, 120)
        XCTAssertEqual(afterAWhile.remaining, 75,
                       "with an unchanged endsAt the chip keeps deriving — it has no pause signal")
    }

    // MARK: Countdown text

    func testCountdownTextMinuteSecondShape() {
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: 65, isNepali: false), "1:05")
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: 0, isNepali: false), "0:00")
    }

    func testCountdownTextHourShape() {
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: 3665, isNepali: false), "1:01:05")
    }

    func testCountdownTextClampsNegativeRemainingToZero() {
        // The tick that straddles the deadline may evaluate a hair below
        // zero — the digits read 0:00, never "-0:01".
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: -0.4, isNepali: false), "0:00")
    }

    func testCountdownTextUsesDevanagariDigitsInNepali() {
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: 65, isNepali: true), "१:०५")
        XCTAssertEqual(HomeTimerChipModel.countdownText(remaining: 3665, isNepali: true), "१:०१:०५")
    }
}

/// [HOME-TIMER-CHIP] (2026-09-11) The chip's view model: visibility, the
/// nearest-selection logic and the stop affordance. The rows arrive
/// through a provider closure and stop through a recorded action, so the
/// tests need no notification center, no store, no AlarmKit.
@MainActor
final class HomeTimerChipViewModelTests: XCTestCase {

    private var rows: [TimerItem] = []
    private var stoppedIDs: [UUID] = []
    private var nowDate = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeViewModel() -> HomeTimerChipViewModel {
        HomeTimerChipViewModel(rows: { [self] in rows },
                               stopTimer: { [self] in stoppedIDs.append($0) },
                               now: { [self] in nowDate })
    }

    private func timer(id: UUID = UUID(), endsIn seconds: TimeInterval) -> TimerItem {
        TimerItem(id: id, endsAt: nowDate.addingTimeInterval(seconds))
    }

    func testHiddenWhenNoTimerRuns() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isVisible)
        XCTAssertNil(viewModel.snapshot.timerID)
    }

    func testVisibleWhenATimerRuns() {
        rows = [timer(endsIn: 90)]
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.snapshot.remaining, 90)
    }

    func testNearestSelectionLogic() {
        // Two running timers — the chip must own the SOONEST deadline,
        // and the +N affordance must count both.
        let near = timer(endsIn: 120)
        let far = timer(endsIn: 600)
        rows = [far, near]
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.snapshot.timerID, near.id)
        XCTAssertEqual(viewModel.snapshot.activeCount, 2)
    }

    func testRefreshRecomputesAfterRowsChange() {
        // The service publishes on create/cancel — one refresh must move
        // the chip from hidden to visible (and back).
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isVisible)

        rows = [timer(endsIn: 60)]
        viewModel.refresh()
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.snapshot.remaining, 60)

        rows = []
        viewModel.refresh()
        XCTAssertFalse(viewModel.isVisible)
    }

    func testStopNearestCancelsTheNearestTimer() {
        let near = timer(endsIn: 120)
        rows = [timer(endsIn: 600), near]
        let viewModel = makeViewModel()

        viewModel.stopNearest()

        XCTAssertEqual(stoppedIDs, [near.id], "one tap stops the NEAREST timer, never another")
    }

    func testStopNearestIsANoOpWhileHidden() {
        let viewModel = makeViewModel()
        viewModel.stopNearest()
        XCTAssertTrue(stoppedIDs.isEmpty)
    }
}
