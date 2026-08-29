import Foundation

// MARK: - MedicationScheduler Protocol (L2 §5.4)

protocol MedicationSchedulerProtocol {
    func loadSchedule(entries: [MedicationEntry])
    func acknowledge(entryId: UUID, at: Date) -> Result<Void, SafetyError>
    func acknowledgeWithConfirmation(
        entryId: UUID,
        at: Date,
        confirmationResponse: ConfirmationResponse
    ) -> Result<Void, SafetyError>
    func scheduleAll()
    var pendingReminders: [ScheduledReminder] { get }
}
