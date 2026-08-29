import Foundation

// MARK: - Medication Entry (from L1 §5.1 + dementia supplement)

enum MedicationFrequency: String, Codable {
    case daily
    case weekly
    case custom
}

enum MedicationAdherenceStatus: String, Codable {
    case pending
    case acknowledged
    case missed
    case doubleDoseAttempt
}

enum PhotoVerificationStatus: String, Codable {
    case notRequired
    case pending
    case captured
    case delivered
    case unavailable
}

struct MedicationEntry: Codable, Identifiable {
    let id: UUID
    let userProfileId: UUID
    let medicationName: String
    let doseDescription: String
    let scheduleTimes: [DateComponents]   // LocalTime stored as hour/minute
    let frequency: MedicationFrequency
    let ackWindowMinutes: Int             // default: 5
    let maxRefireCount: Int               // default: 5
    let escalationWindowMinutes: Int       // default: 60
    let doubleDoseWindowHours: Int         // dementia FR-D03, default: 4
    let photoVerificationEnabled: Bool     // dementia FR-D04a
    let confirmationDescription: String?   // dementia FR-D01, caregiver-configured
}

// MARK: - Scheduled Reminder (runtime, persisted before OS alarm)

struct ScheduledReminder: Codable, Identifiable {
    let id: UUID
    let medicationEntryId: UUID
    let scheduledAt: Date
    var refireCount: Int
    var escalationDeadline: Date
    var state: ReminderState
    var lastFiredAt: Date?
    var acknowledgedAt: Date?

    enum ReminderState: String, Codable {
        case pending
        case fired
        case acknowledged
        case missed
        case doubleDoseBlocked
        case completed
    }
}

// MARK: - Medication Adherence Log (from L1 §5.1)

struct MedicationAdherenceLog: Codable, Identifiable {
    let id: UUID
    let medicationEntryId: UUID
    let scheduledAt: Date
    var acknowledgedAt: Date?
    var refireCount: Int
    var status: MedicationAdherenceStatus
    var familyAlerted: Bool
    var photoVerification: PhotoVerificationStatus
    var confirmationPassed: Bool
    var confirmationDeniedAt: Date?
}

// MARK: - Verification Photo (dementia FR-D04a-D04e)

struct VerificationPhoto {
    let id: UUID
    let adherenceLogId: UUID
    let capturedAt: Date
    var deliveredAt: Date?
    var deletedFromDeviceAt: Date?
    let imageData: Data   // max 200KB compressed
}

// MARK: - Family Alert Types

enum FamilyAlertType: String, Codable {
    case emergencyCall          // metric name only, no value
    case missedMedication       // entry_id_hash only, no medication name
    case healthMonitoringInterrupted
    case configurationUpdateApplied
    case possibleDoubleDose     // dementia FR-D03
    case inactivityAlert        // dementia FR-D12
}

struct NotificationResult {
    let contactIdHash: String
    let success: Bool
    let errorCode: String?
}
