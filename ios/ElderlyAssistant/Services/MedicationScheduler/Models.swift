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
    /// Photos shown with this dose (medication-visual-aids task,
    /// 2026-09-16) — the picture of the actual box, so the elder can match
    /// what is in their hand to what the reminder is asking for.
    ///
    /// Exactly the split `RoutineEntry.visualAids` uses: the model carries
    /// bare FILE NAMES only, never a path and never image bytes; the JPEGs
    /// live under `Application Support/VisualAids/med-<entryId>/<file>.jpg`
    /// in the medication `VisualAidStore` (see `VisualAidStore.directoryPrefix`
    /// — medication and routine entry ids are separate id spaces and must
    /// never be able to resolve to the same folder).
    var visualAids: [VisualAid]

    init(
        id: UUID,
        userProfileId: UUID,
        medicationName: String,
        doseDescription: String,
        scheduleTimes: [DateComponents],
        frequency: MedicationFrequency,
        ackWindowMinutes: Int,
        maxRefireCount: Int,
        escalationWindowMinutes: Int,
        doubleDoseWindowHours: Int,
        photoVerificationEnabled: Bool,
        confirmationDescription: String?,
        visualAids: [VisualAid] = []
    ) {
        self.id = id
        self.userProfileId = userProfileId
        self.medicationName = medicationName
        self.doseDescription = doseDescription
        self.scheduleTimes = scheduleTimes
        self.frequency = frequency
        self.ackWindowMinutes = ackWindowMinutes
        self.maxRefireCount = maxRefireCount
        self.escalationWindowMinutes = escalationWindowMinutes
        self.doubleDoseWindowHours = doubleDoseWindowHours
        self.photoVerificationEnabled = photoVerificationEnabled
        self.confirmationDescription = confirmationDescription
        self.visualAids = visualAids
    }

    /// Explicit keys because `init(from:)` is hand-written (see below) —
    /// every other field keeps a strict decode, exactly like `RoutineEntry`.
    private enum CodingKeys: String, CodingKey {
        case id, userProfileId, medicationName, doseDescription, scheduleTimes,
             frequency, ackWindowMinutes, maxRefireCount, escalationWindowMinutes,
             doubleDoseWindowHours, photoVerificationEnabled, confirmationDescription,
             visualAids
    }

    /// Migration-safe decode: `visualAids` was added after the first
    /// installs shipped, so a payload persisted before it MUST decode as an
    /// empty list rather than throwing `keyNotFound` and losing the
    /// household's whole medication schedule (the failure mode is identical
    /// to the routine store's — see `RoutineEntry.init(from:)`). Every other
    /// key stays required: a payload missing one of those is genuinely
    /// corrupt and must fail loudly rather than default a dose.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userProfileId = try container.decode(UUID.self, forKey: .userProfileId)
        medicationName = try container.decode(String.self, forKey: .medicationName)
        doseDescription = try container.decode(String.self, forKey: .doseDescription)
        scheduleTimes = try container.decode([DateComponents].self, forKey: .scheduleTimes)
        frequency = try container.decode(MedicationFrequency.self, forKey: .frequency)
        ackWindowMinutes = try container.decode(Int.self, forKey: .ackWindowMinutes)
        maxRefireCount = try container.decode(Int.self, forKey: .maxRefireCount)
        escalationWindowMinutes = try container.decode(Int.self, forKey: .escalationWindowMinutes)
        doubleDoseWindowHours = try container.decode(Int.self, forKey: .doubleDoseWindowHours)
        photoVerificationEnabled = try container.decode(Bool.self, forKey: .photoVerificationEnabled)
        confirmationDescription = try container.decodeIfPresent(String.self,
                                                               forKey: .confirmationDescription)
        visualAids = try container.decodeIfPresent([VisualAid].self, forKey: .visualAids) ?? []
    }
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
    /// An EVENT fired (caregiver event-notifications task, 2026-09-13):
    /// a medication/routine/calendar reminder the elder opted into
    /// sharing. One wire type for all three kinds — the kind rides in
    /// the in-memory `FamilyAlertContext`, never in the envelope, so
    /// the E2E payload stays `{v:1, alert_type, timestamp}` with no
    /// PII and no event taxonomy on the wire.
    case eventReminder
}

struct NotificationResult {
    let contactIdHash: String
    let success: Bool
    let errorCode: String?
    /// Which `NotifyChannel` this result's push rode (caregiver
    /// event-notifications task, 2026-09-13) — `nil` for the legacy
    /// alerts, whose delivery surface was never modelled. Carried on
    /// the result so a caller (and the observability event) can see
    /// the channel actually attempted, not the one intended.
    var channel: String? = nil
}
