import XCTest
@testable import ElderlyAssistant

final class EscalationEngineTests: XCTestCase {

    // Default config: 5-min ack window, 5 re-fires, 60-min escalation, 12-min intervals

    func testStartFiresInitialReminder() {
        let engine = EscalationEngine(scheduledTime: Date())
        let result = engine.start()

        XCTAssertEqual(result.action, .fireReminder(refireCount: 0))
        XCTAssertEqual(engine.currentRefireCount, 0)
    }

    func testAcknowledgeWithinWindowMarksAcknowledged() {
        let engine = EscalationEngine(scheduledTime: Date())
        _ = engine.start()
        _ = engine.reminderDelivered(at: Date())

        let result = engine.acknowledge(at: Date())

        XCTAssertEqual(result.action, .markAcknowledged)
        XCTAssertEqual(engine.state, .acknowledged)
    }

    func testAcknowledgeAfterDeadlineWithinEscalationStillAccepted() {
        let engine = EscalationEngine(scheduledTime: Date())
        _ = engine.start()
        let deliveredAt = Date()
        _ = engine.reminderDelivered(at: deliveredAt)

        // 6 minutes later -- past the 5-min ack window but well within 60-min escalation
        let lateAck = deliveredAt.addingTimeInterval(6 * 60)
        let result = engine.acknowledge(at: lateAck)

        XCTAssertEqual(result.action, .markAcknowledged)
        XCTAssertEqual(engine.state, .acknowledged)
    }

    func testAckWindowExpiredTriggersRefire() {
        let scheduledTime = Date()
        let engine = EscalationEngine(
            scheduledTime: scheduledTime,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            refireIntervalMinutes: 12
        )
        _ = engine.start()
        _ = engine.reminderDelivered(at: scheduledTime)

        let result = engine.ackWindowExpired(at: scheduledTime.addingTimeInterval(6 * 60))

        XCTAssertEqual(result.action, .fireReminder(refireCount: 1))
        XCTAssertEqual(engine.currentRefireCount, 1)
        // FR-027: re-fire 1 lands at scheduledTime + 12 min, not + 24.
        let expectedFireAt = scheduledTime.addingTimeInterval(12 * 60)
        XCTAssertNotNil(result.nextFireAt)
        XCTAssertEqual(result.nextFireAt!.timeIntervalSince1970,
                       expectedFireAt.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testFiveRefiresThenEscalate() {
        let scheduledTime = Date()
        let engine = EscalationEngine(
            scheduledTime: scheduledTime,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            refireIntervalMinutes: 12
        )

        _ = engine.start()
        _ = engine.reminderDelivered(at: scheduledTime)

        // FR-027 says 5 re-fires in the 60-min window at 12-min intervals:
        // T+12, T+24, T+36, T+48. (Re-fire 5 lands at T+60, which is the
        // escalation deadline, so ackWindowExpired at T+60 triggers escalate
        // rather than fire.) Verify each nextFireAt.
        for i in 1...4 {
            // Ack window closed 6 min after the previous fire.
            let ackClosed = scheduledTime.addingTimeInterval(TimeInterval((i - 1) * 12 * 60 + 6 * 60))
            let result = engine.ackWindowExpired(at: ackClosed)
            XCTAssertEqual(result.action, .fireReminder(refireCount: i),
                           "Expected re-fire \(i), got \(result.action)")
            let expectedFireAt = scheduledTime.addingTimeInterval(TimeInterval(i * 12 * 60))
            XCTAssertNotNil(result.nextFireAt, "Re-fire \(i) missing nextFireAt")
            XCTAssertEqual(result.nextFireAt!.timeIntervalSince1970,
                           expectedFireAt.timeIntervalSince1970,
                           accuracy: 1.0,
                           "Re-fire \(i) scheduled at wrong offset")
            _ = engine.reminderDelivered(at: expectedFireAt)
        }

        // After the 4th re-fire, ack window expires past the escalation
        // deadline → mark missed + escalate.
        let afterFourth = scheduledTime.addingTimeInterval(TimeInterval(4 * 12 * 60 + 15 * 60))
        let finalResult = engine.ackWindowExpired(at: afterFourth)
        XCTAssertEqual(finalResult.action, .escalateToFamilyNotifier)
        XCTAssertEqual(engine.state, .missed)
    }

    func testEscalationDeadlineEnforced() {
        let scheduledTime = Date()
        let engine = EscalationEngine(
            scheduledTime: scheduledTime,
            escalationWindowMinutes: 60
        )

        _ = engine.start()
        _ = engine.reminderDelivered(at: scheduledTime)

        // Past the 60-minute escalation window
        let pastDeadline = scheduledTime.addingTimeInterval(61 * 60)
        let result = engine.ackWindowExpired(at: pastDeadline)

        XCTAssertEqual(result.action, .escalateToFamilyNotifier)
        XCTAssertEqual(engine.state, .missed)
    }

    func testAcknowledgeAtExactDeadlineBoundary() {
        let engine = EscalationEngine(scheduledTime: Date(), ackWindowMinutes: 5)
        _ = engine.start()
        let deliveredAt = Date()
        let deadline = deliveredAt.addingTimeInterval(5 * 60)
        _ = engine.reminderDelivered(at: deliveredAt)

        let result = engine.acknowledge(at: deadline)

        // Exactly at deadline should still be accepted
        XCTAssertEqual(result.action, .markAcknowledged)
    }

    func testRecoverFromPendingState() {
        let engine = EscalationEngine(scheduledTime: Date())
        let storedReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: UUID(),
            scheduledAt: Date(),
            refireCount: 0,
            escalationDeadline: Date().addingTimeInterval(3600),
            state: .pending,
            lastFiredAt: nil,
            acknowledgedAt: nil
        )

        let result = engine.recover(from: storedReminder, at: Date())

        XCTAssertEqual(result.action, .fireReminder(refireCount: 0))
    }

    func testRecoverFromAcknowledgedDoesNothing() {
        let engine = EscalationEngine(scheduledTime: Date())
        let storedReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: UUID(),
            scheduledAt: Date(),
            refireCount: 2,
            escalationDeadline: Date().addingTimeInterval(3600),
            state: .acknowledged,
            lastFiredAt: Date(),
            acknowledgedAt: Date()
        )

        let result = engine.recover(from: storedReminder, at: Date())

        XCTAssertEqual(result.action, .noAction)
    }

    func testRecoverFromFiredStateRefires() {
        let engine = EscalationEngine(scheduledTime: Date())
        let storedReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: UUID(),
            scheduledAt: Date(),
            refireCount: 2,
            escalationDeadline: Date().addingTimeInterval(3600),
            state: .fired,
            lastFiredAt: Date().addingTimeInterval(-120),
            acknowledgedAt: nil
        )

        let result = engine.recover(from: storedReminder, at: Date())

        XCTAssertEqual(result.action, .fireReminder(refireCount: 2))
    }

    func testMarkCompletedEndsEngine() {
        let engine = EscalationEngine(scheduledTime: Date())
        _ = engine.start()
        _ = engine.reminderDelivered(at: Date())
        _ = engine.acknowledge(at: Date())

        let result = engine.markCompleted()

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.action, .noAction)
    }

    func testEscalationDeadlineCalculation() {
        let scheduledTime = Date()
        let engine = EscalationEngine(
            scheduledTime: scheduledTime,
            escalationWindowMinutes: 60
        )

        let deadline = engine.escalationDeadline
        let expected = scheduledTime.addingTimeInterval(3600)

        XCTAssertEqual(deadline.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func testNextRefireTimeCalculation() {
        let scheduledTime = Date()
        let engine = EscalationEngine(scheduledTime: scheduledTime, refireIntervalMinutes: 12)

        // Fresh engine: count = 0, next re-fire is at scheduledTime itself
        // (i.e. the initial fire, which lives at offset 0).
        XCTAssertEqual(engine.nextRefireTime(after: scheduledTime).timeIntervalSince1970,
                       scheduledTime.timeIntervalSince1970,
                       accuracy: 1.0)

        // After one ack-window expiry (count → 1), next re-fire = T + 12.
        _ = engine.start()
        _ = engine.reminderDelivered(at: scheduledTime)
        _ = engine.ackWindowExpired(at: scheduledTime.addingTimeInterval(6 * 60))
        let expected = scheduledTime.addingTimeInterval(12 * 60)
        XCTAssertEqual(engine.nextRefireTime(after: scheduledTime).timeIntervalSince1970,
                       expected.timeIntervalSince1970,
                       accuracy: 1.0)
    }
}
