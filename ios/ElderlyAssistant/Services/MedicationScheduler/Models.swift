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
    /// Exact dose times (hour/minute only). For a slot entry (D2) this is
    /// the resolved-time MIRROR — written by the save gate and the
    /// mapping-change pass, and never an arming input (arming resolves
    /// fresh from the household mapping).
    ///
    /// The one `var` on this entry, and for one reason: it is what makes
    /// `withScheduleTimes` below a whole-value copy. See that method's
    /// comment — a copy that names fields one by one is how a field gets
    /// silently dropped, and a dropped field here is a dose change the
    /// family never asked for.
    var scheduleTimes: [DateComponents]
    let frequency: MedicationFrequency
    let ackWindowMinutes: Int             // default: 5
    let maxRefireCount: Int               // default: 5
    let escalationWindowMinutes: Int       // default: 60
    let doubleDoseWindowHours: Int         // dementia FR-D03, default: 4
    let photoVerificationEnabled: Bool     // dementia FR-D04a
    let confirmationDescription: String?   // dementia FR-D01, caregiver-configured
    /// What the medicine is FOR (medication-purpose task, 2026-09-17):
    /// a `MedicationPurpose` chip id ("bloodPressure") or the caregiver's
    /// own words. Optional because every entry that existed before this
    /// field existed has no purpose, and a schedule must never be lost to
    /// a missing key — see `init(from:)` for the migration.
    ///
    /// Read at three surfaces, all through `MedicationPurpose`: the
    /// settings row's caption, the photo caption ("रक्तचापको औषधि —
    /// अम्लोडिपिन"), and the voice photo query's vocabulary
    /// (`MedicationVoiceVocabulary` — the elder can ask for a medicine by
    /// what it is for, not only by its name).
    let purpose: String?
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
    /// The structured dose quantity (FR-MSR-001, slot-model revamp
    /// 2026-10-15): how much of the medicine one dose is — an amount plus a
    /// unit (a `MedicationDoseUnit` raw value, or the family's own words).
    ///
    /// Optional, and decoded with `decodeIfPresent` below, exactly like
    /// `purpose` and `visualAids` before it: every entry saved before the
    /// slot model has no quantity, and a schedule must never be lost to a
    /// missing key (NFR-MSR-006). No backfill of any kind — the family
    /// states the quantity, nothing infers one.
    let quantity: MedicationQuantity?
    /// The time-of-day this dose belongs to (FR-MSR-001): morning /
    /// afternoon / evening. The slot carries NO clock time of its own —
    /// the exact time comes from the household mapping
    /// (`MedicationSlotClock`), resolved at arming time — so the family
    /// never computes a clock time to save a medicine.
    ///
    /// Optional for the same migration reason as `quantity`: a pre-slot
    /// payload holds its raw times and must keep loading untouched
    /// (NFR-MSR-006). `nil` is a legacy clock-time entry, and the shipped
    /// behaviour stays first-class for it.
    let slot: MedicationSlot?
    /// Before-meal / after-meal context for this dose (FR-MSR-001):
    /// rendered in copy and on the dose screen, never a second clock and
    /// never a second firing. Optional like `slot`.
    let mealRelation: MealRelation?

    /// The memberwise initializer every construction site uses. The
    /// slot-model parameters (`quantity`, `slot`, `mealRelation`) carry
    /// `nil` defaults so every existing caller — and every legacy-shaped
    /// entry — stays source-compatible; the slot-model save gate passes
    /// them explicitly.
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
        purpose: String? = nil,
        visualAids: [VisualAid] = [],
        quantity: MedicationQuantity? = nil,
        slot: MedicationSlot? = nil,
        mealRelation: MealRelation? = nil
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
        self.purpose = purpose
        self.visualAids = visualAids
        self.quantity = quantity
        self.slot = slot
        self.mealRelation = mealRelation
    }

    /// Explicit keys because `init(from:)` is hand-written (see below) —
    /// every other field keeps a strict decode, exactly like `RoutineEntry`.
    private enum CodingKeys: String, CodingKey {
        case id, userProfileId, medicationName, doseDescription, scheduleTimes,
             frequency, ackWindowMinutes, maxRefireCount, escalationWindowMinutes,
             doubleDoseWindowHours, photoVerificationEnabled, confirmationDescription,
             purpose, visualAids,
             quantity, slot, mealRelation
    }

    /// Migration-safe decode: `visualAids` was added after the first
    /// installs shipped, so a payload persisted before it MUST decode as an
    /// empty list rather than throwing `keyNotFound` and losing the
    /// household's whole medication schedule (the failure mode is identical
    /// to the routine store's — see `RoutineEntry.init(from:)`). `purpose`
    /// rides the same rule for the same reason — a pre-purpose payload has
    /// no such key and MUST decode as "no purpose" (medication-purpose
    /// task, 2026-09-17). The slot-model fields (`quantity`, `slot`,
    /// `mealRelation`, 2026-10-15) ride it too: a pre-slot payload has
    /// none of the three keys and MUST load with them `nil` and its
    /// stored times intact (FR-MSR-004, NFR-MSR-006). Every other key
    /// stays required: a payload missing one of those is genuinely
    /// corrupt and must fail loudly rather than default a dose.
    ///
    /// Legacy payloads load IN PLACE — nothing here reads, rewrites or
    /// re-persists the stored bytes; the migration is forward-only and
    /// fail-safe.
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
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        visualAids = try container.decodeIfPresent([VisualAid].self, forKey: .visualAids) ?? []
        quantity = try container.decodeIfPresent(MedicationQuantity.self, forKey: .quantity)
        slot = try container.decodeIfPresent(MedicationSlot.self, forKey: .slot)
        mealRelation = try container.decodeIfPresent(MealRelation.self, forKey: .mealRelation)
    }

    /// The same medication with a different set of dose times — the
    /// copy-with a calendar-driven edit needs (rich-events task,
    /// 2026-09-17). Every field but `scheduleTimes` is preserved
    /// verbatim, which is the whole point: a family retiming a dose in
    /// the Calendar app must not reset the ack window, the refire count
    /// or the escalation window the caregiver configured, and must not
    /// touch the visual aids they attached — or, since the slot model
    /// (2026-10-15), the quantity, the slot or the meal relation.
    ///
    /// THE TRAP, fixed structurally: this used to be a memberwise
    /// rebuild that named every field, and the compiler could not notice
    /// a dropped one — the memberwise initializer defaults fields, so
    /// every field added since is silently lost on the copy (an entry
    /// that loses its slot here fires at the wrong time and loses the
    /// slot the family chose; review-l2 risk 3). This is now a
    /// whole-value copy with exactly one replacement: whatever the value
    /// carries is carried, today and for every field added later. The
    /// single `var` on `scheduleTimes` is what buys that guarantee — a
    /// copy that names fields one by one is the failure mode itself.
    ///
    /// A method on the model rather than a rebuild at the call site: the
    /// only copy shape a caller can write safely. `MedicationScheduler
    /// .setScheduleTimes` and the mapping-change mirror rewrite both go
    /// through here, so both inherit the guarantee.
    func withScheduleTimes(_ times: [DateComponents]) -> MedicationEntry {
        var copy = self
        copy.scheduleTimes = times
        return copy
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
    /// The BARE FILE NAME of the evidence photo attached to this record
    /// (FR-MSR-013, slot-model revamp 2026-10-15) — never a path, never
    /// the bytes; the JPEG lives at the evidence store's per-entry
    /// layout, named from this log's id (`<logId>.jpg`, see
    /// `MedicationEvidenceStore`).
    ///
    /// Optional with a memberwise default, and decoded through the
    /// synthesized optional rule (`decodeIfPresent`): every adherence log
    /// written before this field existed carries no such key and MUST
    /// keep loading — a lost log is a lost dose history. `nil` is an
    /// honestly evidence-free record, never a claim that a photo exists;
    /// the record surface's attach path is the only writer.
    var evidencePhotoFileName: String? = nil
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
    /// The elder completed the acknowledgement and confirmation chain
    /// and the intake was recorded (FR-MSR-015, slot-model revamp
    /// 2026-10-15): the caregiver's record that the dose was actually
    /// taken.
    ///
    /// APPENDED to the taxonomy, never inserted: the raw values ARE the
    /// wire contract (FR-MSR-017), and a case renumbered ahead of a
    /// shipped one would silently change the meaning of every family
    /// alert payload a deployed phone already carries. The one-way
    /// `entry_id_hash` is the only medication reference a payload may
    /// carry where one is needed — never a name, a dose or a title.
    case intakeRecorded
    /// A dose's escalation began — the first re-fire decision for that
    /// reminder (D10; FR-MSR-015). Same wire rules as `intakeRecorded`:
    /// appended last, PII-free, type + timestamp only.
    case escalationStarted
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
