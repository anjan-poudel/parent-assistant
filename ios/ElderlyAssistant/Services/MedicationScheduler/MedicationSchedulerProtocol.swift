import Foundation

// MARK: - MedicationScheduler Protocol (L2 §5.4)

protocol MedicationSchedulerProtocol {
    /// Write-first-or-fail (T-023, amendment 6): the write lands before
    /// anything is adopted, and the caller learns whether it did — the
    /// schedule it passed is the schedule in memory if and only if this
    /// returns true. Callers that cannot act on a refusal (spec-only
    /// seam users) discard the result; the app's writer paths all check
    /// it.
    @discardableResult
    func loadSchedule(entries: [MedicationEntry]) -> Bool
    func acknowledge(entryId: UUID, at: Date) -> Result<Void, SafetyError>
    func acknowledgeWithConfirmation(
        entryId: UUID,
        at: Date,
        confirmationResponse: ConfirmationResponse
    ) -> Result<Void, SafetyError>
    func scheduleAll()
    var pendingReminders: [ScheduledReminder] { get }
}
