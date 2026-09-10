import XCTest
import UserNotifications
@testable import ElderlyAssistant

// MARK: - Recording audio fake

/// [TIMER-ALARM] (2026-09-10) Recording `TimerAlarmAudioPlaying` fake —
/// counts start/stop calls so the state machine's audio side effects are
/// asserted without real audio. `MockObservabilityBus` comes from
/// MedicationSchedulerTests.swift (shared across the test module).
private final class RecordingTimerAlarmAudio: TimerAlarmAudioPlaying {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startLooping() { startCount += 1 }
    func stop() { stopCount += 1 }
}

// MARK: - TimerAlarmEngine tests

/// [TIMER-ALARM] (2026-09-10) The timer-firing state machine —
/// fires → ringing → stopped — with an injected clock and a fake audio
/// player (pure logic, no real audio), plus the notification-response
/// routing seam (payload parsing + `ringTimer`). Main-confined by
/// contract: the engine mutates `@Published phase` on main, so the class
/// runs on the main actor exactly like the UI does (same pattern as
/// AlarmTimersServiceTests).
@MainActor
final class TimerAlarmEngineTests: XCTestCase {

    private var audio: RecordingTimerAlarmAudio!
    private var bus: MockObservabilityBus!
    private var nowDate: Date!
    private var ringStartedIDs: [UUID] = []

    private func fixedNow() -> Date { nowDate }

    override func setUp() {
        super.setUp()
        audio = RecordingTimerAlarmAudio()
        bus = MockObservabilityBus()
        nowDate = date(2026, 9, 10, 10, 0)
        ringStartedIDs = []
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func timer(endsInMinutes minutes: Int, id: UUID = UUID()) -> TimerItem {
        TimerItem(id: id, endsAt: nowDate.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func makeEngine() -> TimerAlarmEngine {
        let engine = TimerAlarmEngine(audio: audio, observabilityBus: bus, now: fixedNow)
        engine.onRingStarted = { [weak self] id in self?.ringStartedIDs.append(id) }
        return engine
    }

    // MARK: - State machine: fires → ringing → stopped

    func testTickBeforeDeadlineStaysIdle() {
        let engine = makeEngine()

        engine.tick(activeTimers: [timer(endsInMinutes: 5)])

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertTrue(ringStartedIDs.isEmpty)
    }

    func testTickAtDeadlineTransitionsToRingingAndStartsAudio() {
        let engine = makeEngine()
        let due = timer(endsInMinutes: 0)  // endsAt == now

        engine.tick(activeTimers: [due])

        XCTAssertEqual(engine.phase, .ringing(due))
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(audio.stopCount, 0)
        XCTAssertEqual(ringStartedIDs, [due.id])
        XCTAssertEqual(bus.emittedEvents.last?.eventType, "timer_alarm_ringing")
    }

    func testTickRingsEarliestOfMultipleElapsedTimers() {
        let engine = makeEngine()
        let later = timer(endsInMinutes: -1)
        let earlier = timer(endsInMinutes: -2)

        engine.tick(activeTimers: [later, earlier])

        XCTAssertEqual(engine.phase, .ringing(earlier))
        XCTAssertEqual(audio.startCount, 1)
    }

    func testStopRingingStopsAudioReturnsTimerIDAndReturnsToIdle() {
        let engine = makeEngine()
        let due = timer(endsInMinutes: 0)
        engine.tick(activeTimers: [due])

        let stoppedID = engine.stopRinging()

        XCTAssertEqual(stoppedID, due.id)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(bus.emittedEvents.last?.eventType, "timer_alarm_stopped")
    }

    func testStopWhileIdleIsNoOp() {
        let engine = makeEngine()

        XCTAssertNil(engine.stopRinging())
        XCTAssertEqual(audio.stopCount, 0)
        XCTAssertEqual(engine.phase, .idle)
    }

    func testTickWhileRingingDoesNotRestartAudio() {
        let engine = makeEngine()
        let due = timer(endsInMinutes: 0)
        engine.tick(activeTimers: [due])

        // Repeated driver ticks while ringing: the bell keeps looping,
        // the audio is never restarted, the phase never flickers.
        for _ in 0..<5 {
            engine.tick(activeTimers: [due])
        }

        XCTAssertEqual(engine.phase, .ringing(due))
        XCTAssertEqual(audio.startCount, 1)
    }

    func testSecondElapsedTimerRingsAfterFirstStopped() {
        let engine = makeEngine()
        let first = timer(endsInMinutes: -2)
        let second = timer(endsInMinutes: -1)
        engine.tick(activeTimers: [first, second])
        XCTAssertEqual(engine.phase, .ringing(first))

        engine.stopRinging()
        engine.tick(activeTimers: [first, second])

        XCTAssertEqual(engine.phase, .ringing(second))
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(ringStartedIDs, [first.id, second.id])
    }

    // MARK: - Notification-response routing seam

    func testPayloadParserExtractsTimerIDFromTimerPayload() {
        let id = UUID()
        let info: [AnyHashable: Any] = ["kind": "timer", "id": id.uuidString]

        XCTAssertEqual(TimerAlarmNotificationPayload.timerID(from: info), id)
    }

    func testPayloadParserRejectsAlarmAndForeignPayloads() {
        let id = UUID()
        XCTAssertNil(TimerAlarmNotificationPayload.timerID(
            from: ["kind": "alarm", "id": id.uuidString]))
        XCTAssertNil(TimerAlarmNotificationPayload.timerID(
            from: ["id": id.uuidString]))  // no kind — e.g. medication reminder
        XCTAssertNil(TimerAlarmNotificationPayload.timerID(
            from: ["kind": "timer", "id": "not-a-uuid"]))
        XCTAssertNil(TimerAlarmNotificationPayload.timerID(from: [:]))
    }

    func testNotificationResponseRoutingStartsRinging() {
        let engine = makeEngine()
        let due = timer(endsInMinutes: 0)
        engine.tick(activeTimers: [due])  // adopts the snapshot (feed)
        engine.stopRinging()

        // The tap on the delivered notification routes back into the
        // ringing screen for the same timer.
        let started = engine.ringTimer(id: due.id)

        XCTAssertTrue(started)
        XCTAssertEqual(engine.phase, .ringing(due))
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(bus.emittedEvents.last?.metadata["trigger"],
                       "notification_response")
    }

    func testNotificationResponseForUnknownTimerDoesNotRing() {
        let engine = makeEngine()
        engine.tick(activeTimers: [timer(endsInMinutes: 5)])

        // A stale tap (timer row already expired/pruned) rings nothing —
        // honest, no zombie alarms.
        XCTAssertFalse(engine.ringTimer(id: UUID()))
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(audio.startCount, 0)
    }

    func testRingTimerWhileAlreadyRingingIsIgnored() {
        let engine = makeEngine()
        let due = timer(endsInMinutes: 0)
        engine.tick(activeTimers: [due])

        XCTAssertFalse(engine.ringTimer(id: due.id))
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(engine.phase, .ringing(due))
    }

    // MARK: - Tap path: the timer ended while the app was backgrounded

    func testTapRouteRingsTimerThatLeftTheActiveSnapshot() {
        let engine = makeEngine()
        // Ended 2 minutes ago — past the snapshot filter, but its row is
        // still live within the prune grace window (the coordinator's
        // timerLookup resolves it).
        let ended = timer(endsInMinutes: -2)
        engine.timerLookup = { id in id == ended.id ? ended : nil }

        let started = engine.ringTimer(id: ended.id)

        XCTAssertTrue(started)
        XCTAssertEqual(engine.phase, .ringing(ended))
        XCTAssertEqual(audio.startCount, 1)
    }

    func testTapRouteIgnoresFutureTimerFromStalePayload() {
        let engine = makeEngine()
        // A future deadline can never have delivered a notification —
        // a stale payload must not ring an alarm for nothing.
        let future = timer(endsInMinutes: 5)
        engine.timerLookup = { id in id == future.id ? future : nil }

        XCTAssertFalse(engine.ringTimer(id: future.id))
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(audio.startCount, 0)
    }

    func testTapRouteWithoutRowRingsNothing() {
        let engine = makeEngine()
        engine.timerLookup = { _ in nil }

        XCTAssertFalse(engine.ringTimer(id: UUID()))
        XCTAssertEqual(engine.phase, .idle)
    }
}
