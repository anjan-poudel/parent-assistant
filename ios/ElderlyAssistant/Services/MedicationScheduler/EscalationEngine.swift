import Foundation

// MARK: - Escalation Engine (L2 §5.4)

enum EscalationAction: Equatable {
    case fireReminder(refireCount: Int)
    case waitForAcknowledgement(deadline: Date)
    case escalateToFamilyNotifier
    case markMissed
    case markAcknowledged
    case noAction
}

enum EscalationState: Equatable {
    case idle
    case reminderFired(refireCount: Int, firedAt: Date)
    case awaitingAcknowledgement(refireCount: Int, deadline: Date)
    case acknowledged
    case missed
    case completed
}

struct EscalationResult {
    let state: EscalationState
    let action: EscalationAction
    let nextFireAt: Date?
}

final class EscalationEngine {
    let scheduledTime: Date
    let ackWindowMinutes: Int           // default: 5
    let maxRefireCount: Int             // default: 5
    let escalationWindowMinutes: Int     // default: 60
    let refireIntervalMinutes: Int      // default: 12

    private(set) var state: EscalationState
    private(set) var currentRefireCount: Int

    init(
        scheduledTime: Date,
        ackWindowMinutes: Int = 5,
        maxRefireCount: Int = 5,
        escalationWindowMinutes: Int = 60,
        refireIntervalMinutes: Int = 12
    ) {
        self.scheduledTime = scheduledTime
        self.ackWindowMinutes = ackWindowMinutes
        self.maxRefireCount = maxRefireCount
        self.escalationWindowMinutes = escalationWindowMinutes
        self.refireIntervalMinutes = refireIntervalMinutes
        self.state = .idle
        self.currentRefireCount = 0
    }

    var escalationDeadline: Date {
        scheduledTime.addingTimeInterval(TimeInterval(escalationWindowMinutes * 60))
    }

    /// Returns when re-fire number `currentRefireCount` should happen,
    /// measured from `scheduledTime`. Callers (specifically
    /// `ackWindowExpired`) increment `currentRefireCount` FIRST, then call
    /// this — so re-fire 1 lands at scheduledTime + 12 min (not + 24),
    /// re-fire 2 at + 24, …, re-fire N at + N*12.
    ///
    /// The old implementation used `(currentRefireCount + 1)` after the
    /// increment, double-counting and only fitting 4 re-fires into the
    /// 60-minute escalation window instead of the FR-027 spec's 5.
    func nextRefireTime(after date: Date) -> Date {
        let interval = TimeInterval(refireIntervalMinutes * 60 * currentRefireCount)
        return scheduledTime.addingTimeInterval(interval)
    }

    func ackDeadline(forFiredAt firedAt: Date) -> Date {
        firedAt.addingTimeInterval(TimeInterval(ackWindowMinutes * 60))
    }

    // MARK: - State transitions

    func start() -> EscalationResult {
        currentRefireCount = 0
        state = .reminderFired(refireCount: 0, firedAt: Date())
        return EscalationResult(
            state: state,
            action: .fireReminder(refireCount: 0),
            nextFireAt: Date()
        )
    }

    func reminderDelivered(at deliveredAt: Date) -> EscalationResult {
        let deadline = ackDeadline(forFiredAt: deliveredAt)
        state = .awaitingAcknowledgement(refireCount: currentRefireCount, deadline: deadline)
        return EscalationResult(
            state: state,
            action: .waitForAcknowledgement(deadline: deadline),
            nextFireAt: nil
        )
    }

    func acknowledge(at acknowledgedAt: Date) -> EscalationResult {
        guard case .awaitingAcknowledgement(let refireCount, let deadline) = state else {
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)
        }

        if acknowledgedAt <= deadline {
            state = .acknowledged
            return EscalationResult(
                state: state,
                action: .markAcknowledged,
                nextFireAt: nil
            )
        }

        // Ack arrived after deadline -- treat as if it arrived during next re-fire
        return processAckAfterDeadline(at: acknowledgedAt)
    }

    func ackWindowExpired(at now: Date) -> EscalationResult {
        guard case .awaitingAcknowledgement = state else {
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)
        }

        if now >= escalationDeadline {
            state = .missed
            return EscalationResult(
                state: state,
                action: .escalateToFamilyNotifier,
                nextFireAt: nil
            )
        }

        currentRefireCount += 1

        if currentRefireCount > maxRefireCount {
            state = .missed
            return EscalationResult(
                state: state,
                action: .escalateToFamilyNotifier,
                nextFireAt: nil
            )
        }

        let nextTime = nextRefireTime(after: now)
        state = .reminderFired(refireCount: currentRefireCount, firedAt: now)
        return EscalationResult(
            state: state,
            action: .fireReminder(refireCount: currentRefireCount),
            nextFireAt: nextTime
        )
    }

    func markCompleted() -> EscalationResult {
        state = .completed
        return EscalationResult(state: state, action: .noAction, nextFireAt: nil)
    }

    /// Persistence bridge — collapse the runtime `EscalationState` into the
    /// serialisable `ScheduledReminder.ReminderState` used on disk.
    func toReminderState() -> ScheduledReminder.ReminderState {
        switch state {
        case .idle:                    return .pending
        case .reminderFired:           return .fired
        case .awaitingAcknowledgement: return .fired
        case .acknowledged:            return .acknowledged
        case .missed:                  return .missed
        case .completed:               return .completed
        }
    }

    // MARK: - Recovery (process kill + relaunch)

    func recover(from storedReminder: ScheduledReminder, at now: Date) -> EscalationResult {
        currentRefireCount = storedReminder.refireCount

        switch storedReminder.state {
        case .acknowledged:
            state = .acknowledged
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)

        case .missed:
            state = .missed
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)

        case .completed:
            state = .completed
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)

        case .doubleDoseBlocked:
            state = .missed
            return EscalationResult(state: state, action: .noAction, nextFireAt: nil)

        case .pending:
            // Reminder was persisted but never fired -- kick off the fire cycle.
            return start()

        case .fired:
            // Fired before the process was killed; delivery not confirmed. Re-fire now.
            state = .reminderFired(refireCount: currentRefireCount, firedAt: now)
            return EscalationResult(
                state: state,
                action: .fireReminder(refireCount: currentRefireCount),
                nextFireAt: now
            )
        }
    }

    // MARK: - Private

    private func processAckAfterDeadline(at acknowledgedAt: Date) -> EscalationResult {
        if acknowledgedAt >= escalationDeadline {
            state = .missed
            return EscalationResult(
                state: state,
                action: .escalateToFamilyNotifier,
                nextFireAt: nil
            )
        }

        // Check if we're past the final re-fire
        let finalRefireTime = scheduledTime.addingTimeInterval(
            TimeInterval(refireIntervalMinutes * 60 * maxRefireCount)
        )
        if acknowledgedAt > finalRefireTime {
            state = .missed
            return EscalationResult(
                state: state,
                action: .escalateToFamilyNotifier,
                nextFireAt: nil
            )
        }

        // Ack arrived late but within escalation window -- accept it
        state = .acknowledged
        return EscalationResult(
            state: state,
            action: .markAcknowledged,
            nextFireAt: nil
        )
    }
}
