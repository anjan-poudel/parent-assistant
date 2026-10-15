import XCTest
@testable import ElderlyAssistant

/// T-017 — the save plumbing (design-l2 C12/IF-21; decisions D1/D2, the
/// m-2 duplicate rule; FR-MSR-001/003/013/018, FR-MSR-020, NFR-MSR-006).
///
/// What this suite pins, and why each half is worth a named test:
///
///  - **D1 — a dose row is an entry.** N rows create N single-slot
///    entries, each carrying its own slot; a once-saved medicine with two
///    doses is two rows of the family list.
///  - **D2 — the resolved-time mirror.** A slot row's entry stores the
///    household mapping's RESOLVED time in `scheduleTimes`, composed by
///    the coordinator (C1) — the view never passes a raw time for a slot
///    row, and a non-default mapping proves the mirror really resolves.
///  - **m-2 — the SHIPPED duplicate rule.** Exact name equality plus
///    effective-time intersection, over effective times: a mixed
///    legacy/slot pair compares resolved-vs-stored and still flags;
///    entries created earlier in the same save participate; an update
///    excludes the entry being edited; a corrupt mapping (empty mirror)
///    does not flag.
///  - **The shipped gates.** A name is required (and a refused save
///    persists nothing), at least one dose row is required, and the
///    mixed row shape is refused.
///  - **The remove cascade (FR-MSR-013).** A removed medication's
///    evidence folder goes with it — fail-soft, never a failure over a
///    photo, and an entry that never had evidence removes cleanly.
///  - **FR-MSR-020.** `photoVerificationEnabled: false` at every
///    new-entry construction site, and an edit never re-defaults a
///    stored dementia toggle.
///
/// Recipe (the `MedicationAckClarificationTests` convention): the real
/// coordinator over the real scheduler; the scheduler seam is Mirrored
/// for seeding and the previous schedule restored in `defer`. The
/// household mapping and the evidence store root are injected through
/// the T-017 constructor seams, so resolution is deterministic and no
/// real evidence directory is ever touched.
final class MedicationSavePlumbingTests: XCTestCase {

    // MARK: - Named tests (T-017)

    /// D1 + the mirror: two slot rows create TWO entries, each with its
    /// own slot and its own resolved-time mirror — never one multi-slot
    /// entry, and never a shared time.
    @MainActor
    func testNRowsCreateNEntries() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning), .slot(.evening)], photo: nil)
        XCTAssertNil(coordinator.addMedication(request), "the two-row slot save must succeed")

        let saved = scheduler.medicationEntries()
        XCTAssertEqual(saved.count, 2, "N dose rows must create N entries (D1)")
        let morning = try XCTUnwrap(saved.first { $0.slot == .morning })
        let evening = try XCTUnwrap(saved.first { $0.slot == .evening })
        XCTAssertNotEqual(morning.id, evening.id,
                          "each row is its own entry — never one multi-slot entry")
        XCTAssertEqual(morning.scheduleTimes, [MedicationSlotClock.defaultMorningTime.dateComponents],
                       "the morning entry carries its own resolved-time mirror (D2)")
        XCTAssertEqual(evening.scheduleTimes, [MedicationSlotClock.defaultEveningTime.dateComponents],
                       "the evening entry carries its own resolved-time mirror (D2)")
    }

    /// D2: the mirror is the HOUSEHOLD MAPPING's resolved time for the
    /// row's slot — here a non-default 06:45 morning — composed by the
    /// coordinator, not a shipped default and not any raw time (a slot
    /// row carries none).
    @MainActor
    func testMirrorWrittenFromResolvedSlotTime() throws {
        let mapping = MedicationSlotClock(morning: TimeOfDay(hour: 6, minute: 45),
                                          afternoon: TimeOfDay(hour: 12, minute: 30),
                                          evening: TimeOfDay(hour: 21, minute: 5))
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(slotClock: mapping, entries: []))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning)], photo: nil)
        XCTAssertNil(coordinator.addMedication(request))

        let entry = try XCTUnwrap(scheduler.medicationEntries().first)
        XCTAssertEqual(entry.slot, .morning, "the family's slot is stored as stated")
        XCTAssertEqual(entry.scheduleTimes, [mapping.time(for: .morning).dateComponents],
                       "the mirror is the mapping's resolved time through C1 — the one source")
        XCTAssertEqual(entry.scheduleTimes.first?.hour, 6)
        XCTAssertEqual(entry.scheduleTimes.first?.minute, 45)
    }

    /// C2 at save: the stored `doseDescription` is exactly
    /// `DoseLine.compose`'s output — rule 2 keeps both the composed
    /// quantity and the family's dose text; a quantity-less dose keeps
    /// the trimmed text. The structured quantity is stored beside the
    /// line, never parsed back out of it.
    @MainActor
    func testDoseDescriptionComposedAtSave() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let quantity = MedicationQuantity(amount: 2, unit: MedicationDoseUnit.tablet.rawValue)
        let measured = MedicationSaveRequest(name: "Amlodipine", strength: "500 mg", purpose: nil,
                                             quantity: quantity, mealRelation: nil,
                                             rows: [.slot(.morning)], photo: nil)
        XCTAssertNil(coordinator.addMedication(measured))

        let composed = try XCTUnwrap(scheduler.medicationEntries().first)
        XCTAssertEqual(composed.doseDescription, "2 tablet, 500 mg",
                       "rule 2 keeps both halves: the composed quantity AND the scanned strength")
        XCTAssertEqual(composed.doseDescription,
                       DoseLine.compose(quantity: quantity, doseText: "500 mg",
                                        locale: AppLanguage.english.locale),
                       "the stored line is exactly the C2 composer's output — one home")
        XCTAssertEqual(composed.quantity, quantity,
                       "the structured quantity is stored beside the line")

        let plain = MedicationSaveRequest(name: "Paracetamol", strength: "  half tablet  ",
                                          purpose: nil, quantity: nil, mealRelation: nil,
                                          rows: [.slot(.evening)], photo: nil)
        XCTAssertNil(coordinator.addMedication(plain))
        let trimmed = try XCTUnwrap(
            scheduler.medicationEntries().first { $0.medicationName == "Paracetamol" })
        XCTAssertEqual(trimmed.doseDescription, "half tablet",
                       "rule 3: no quantity keeps the family's dose text, trimmed")
    }

    /// m-2's headline case: an existing LEGACY entry at 08:00 and a new
    /// SLOT row resolving to 08:00 must flag — the shipped expression
    /// (name equality plus time intersection) compares resolved-vs-stored
    /// across the two shapes, and a flagged save persists nothing.
    @MainActor
    func testDuplicateRuleFlagsMixedLegacySlotPair() throws {
        let legacy = legacyEntry(name: "Amlodipine",
                                 times: [MedicationSlotClock.defaultMorningTime.dateComponents])
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: [legacy]))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning)], photo: nil)
        XCTAssertEqual(coordinator.addMedication(request), "settings.meds.duplicateError",
                       "the resolved 08:00 must intersect the stored 08:00 and flag the pair")
        XCTAssertEqual(scheduler.medicationEntries().count, 1,
                       "a flagged save persists nothing")

        // Source pin: the shipped expression shape survives in the new
        // plumbing — name equality AND time intersection, no other rule.
        let region = saveRegion()
        XCTAssertTrue(region.contains("entry.medicationName == trimmed"),
                      "the shipped name-equality half must survive (m-2)")
        XCTAssertTrue(region.contains("entry.scheduleTimes.contains { times.contains($0) }"),
                      "the shipped time-intersection half must survive (m-2)")
    }

    /// Entries created earlier in the SAME save participate: two rows
    /// assigned the same slot resolve to the same effective time, the
    /// second flags — and the whole save is refused (the first row must
    /// not land either).
    @MainActor
    func testDuplicateRuleIncludesEntriesFromTheSameSave() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let sameSlot = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                             quantity: nil, mealRelation: nil,
                                             rows: [.slot(.morning), .slot(.morning)], photo: nil)
        XCTAssertEqual(coordinator.addMedication(sameSlot), "settings.meds.duplicateError",
                       "the second row on the same resolved time flags against the first (m-2)")
        XCTAssertTrue(scheduler.medicationEntries().isEmpty,
                      "a same-save duplicate refuses the whole save")

        // The same rule for legacy-shape rows: two `.time` rows sharing
        // one effective time — the second flags against the entry the
        // first row created, and nothing lands. (A MIXED single save is
        // refused earlier by the shape gate, so the across-shape case
        // lives in the legacy-pair test above, where the shapes differ
        // across saves, not within one.)
        let sameTime = MedicationSaveRequest(name: "Metformin", strength: nil, purpose: nil,
                                             quantity: nil, mealRelation: nil,
                                             rows: [.time(MedicationSlotClock.defaultMorningTime.dateComponents),
                                                    .time(MedicationSlotClock.defaultMorningTime.dateComponents)],
                                             photo: nil)
        XCTAssertEqual(coordinator.addMedication(sameTime), "settings.meds.duplicateError",
                       "two time rows at one effective time flag within the same save (m-2)")
        XCTAssertTrue(scheduler.medicationEntries().isEmpty,
                      "a same-save duplicate refuses the whole save")
    }

    /// m-2's exclusion: re-saving an entry at its own effective time must
    /// not flag itself — while another entry with the same name and time
    /// still does. The exclusion is exactly self-deep.
    @MainActor
    func testUpdateExcludesSelf() throws {
        let entry = legacyEntry(name: "Amlodipine",
                                times: [MedicationSlotClock.defaultMorningTime.dateComponents])
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.time(MedicationSlotClock.defaultMorningTime.dateComponents)],
                                            photo: nil)
        XCTAssertNil(coordinator.updateMedication(id: entry.id, request),
                     "the entry being edited is excluded from its own check (m-2)")

        let updated = try XCTUnwrap(scheduler.medicationEntries().first)
        XCTAssertEqual(scheduler.medicationEntries().count, 1,
                       "row 1 edits in place — an update creates no second entry")
        XCTAssertEqual(updated.id, entry.id, "the id is kept (in-place edit)")
        XCTAssertEqual(updated.scheduleTimes,
                       [MedicationSlotClock.defaultMorningTime.dateComponents])

        // The exclusion is self-deep only: a rival with the same name and
        // effective time still flags the update.
        let rival = legacyEntry(name: "Amlodipine",
                                times: [MedicationSlotClock.defaultMorningTime.dateComponents])
        scheduler.loadSchedule(entries: [updated, rival])
        XCTAssertEqual(coordinator.updateMedication(id: entry.id, request),
                       "settings.meds.duplicateError",
                       "only the entry being edited is excluded — a rival still flags")
        XCTAssertEqual(scheduler.medicationEntries().count, 2,
                       "the refused update persists nothing")
    }

    /// A corrupt mapping (24:00 morning, fail-closed `.indeterminate`)
    /// resolves NO time: the row's mirror is empty, an empty mirror
    /// intersects nothing, and — per IF-21 — a resolution failure does
    /// NOT fail the save (the unresolved line and fresh-at-arming
    /// resolution are the honest signals).
    @MainActor
    func testCorruptMappingDoesNotFlag() throws {
        // The corrupt record arrives as STORED BYTES (the store's own save
        // validates and would refuse it) — exactly the half-written
        // payload a device can hold.
        let corruptJSON = """
        {"morning": {"hour": 24, "minute": 0},
         "afternoon": {"hour": 13, "minute": 0},
         "evening": {"hour": 19, "minute": 0}}
        """
        let legacy = legacyEntry(name: "Amlodipine",
                                 times: [MedicationSlotClock.defaultMorningTime.dateComponents])
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(slotClockJSON: corruptJSON, entries: [legacy]))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning)], photo: nil)
        XCTAssertNil(coordinator.addMedication(request),
                     "a resolution failure does not fail the save (IF-21)")

        let created = try XCTUnwrap(
            scheduler.medicationEntries().first { $0.slot == .morning })
        XCTAssertEqual(created.scheduleTimes, [],
                       "the unresolvable slot leaves an EMPTY mirror — no guessed, clamped or defaulted time")
        XCTAssertEqual(scheduler.medicationEntries().count, 2,
                       "and the empty mirror intersects nothing — no false duplicate")
    }

    /// The name gate is unchanged (blank text is not a name) and a
    /// refused save persists nothing; the shipped "at least one dose
    /// row" gate and IF-21's shape gate ride along.
    @MainActor
    func testNameRequiredGateUnchanged() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let blank = MedicationSaveRequest(name: "   ", strength: nil, purpose: nil,
                                          quantity: nil, mealRelation: nil,
                                          rows: [.slot(.morning)], photo: nil)
        XCTAssertEqual(coordinator.addMedication(blank), "settings.meds.nameRequired",
                       "the shipped name gate is unchanged (canSave)")

        let rowless = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [], photo: nil)
        XCTAssertEqual(coordinator.addMedication(rowless), "settings.meds.timeRequired",
                       "a save needs at least one dose row — the shipped no-time gate")

        let mixed = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                          quantity: nil, mealRelation: nil,
                                          rows: [.time(MedicationSlotClock.defaultMorningTime.dateComponents),
                                                 .slot(.morning)], photo: nil)
        XCTAssertEqual(coordinator.addMedication(mixed), "settings.meds.slotRequired",
                       "one save states one row model — mixed shapes are refused, never resolved halfway")

        XCTAssertTrue(scheduler.medicationEntries().isEmpty,
                      "no refused save may persist an entry")
    }

    /// FR-MSR-013's remove cascade: a removed entry's evidence folder
    /// goes with it, and an entry that never had evidence removes
    /// cleanly — absent files are the goal state, never a failure.
    @MainActor
    func testRemoveCascadesEvidenceDeletionFailSoft() throws {
        let withEvidence = legacyEntry(name: "Amlodipine",
                                       times: [MedicationSlotClock.defaultMorningTime.dateComponents])
        let withoutEvidence = legacyEntry(name: "Paracetamol",
                                          times: [MedicationSlotClock.defaultEveningTime.dateComponents])
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(entries: [withEvidence, withoutEvidence]))
        defer { restore() }

        // Plant real evidence bytes under the injected scratch root, in
        // the store's own on-disk layout (`<entryId>/<logId>.jpg`).
        let directory = evidenceRoot.appendingPathComponent(withEvidence.id.uuidString,
                                                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: directory.appendingPathComponent(UUID().uuidString + ".jpg", isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        coordinator.removeMedication(id: withEvidence.id)
        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [withoutEvidence.id],
                       "the entry is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the entry's evidence folder goes WITH the medication (the cascade)")

        coordinator.removeMedication(id: withoutEvidence.id)
        XCTAssertTrue(scheduler.medicationEntries().isEmpty,
                      "an entry with no evidence at all removes cleanly — fail-soft, never a failure over a photo")
    }

    /// FR-MSR-020, both halves of the flag's contract: every NEW entry
    /// carries the shipped `photoVerificationEnabled: false`, and an
    /// EDIT carries the entry's stored toggle over verbatim — it must
    /// never be re-defaulted by a save.
    @MainActor
    func testPhotoVerificationStaysDisabledAtConstruction() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning), .slot(.evening)], photo: nil)
        XCTAssertNil(coordinator.addMedication(request))
        let saved = scheduler.medicationEntries()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { !$0.photoVerificationEnabled },
                      "every new-entry construction site keeps the shipped false (FR-MSR-020)")

        // The stored toggle half: a caregiver's true survives an edit.
        let dementia = legacyEntry(name: "Donepezil",
                                   times: [MedicationSlotClock.defaultAfternoonTime.dateComponents],
                                   photoVerificationEnabled: true)
        scheduler.loadSchedule(entries: saved + [dementia])
        let edit = MedicationSaveRequest(name: "Donepezil", strength: "5 mg", purpose: nil,
                                         quantity: nil, mealRelation: nil,
                                         rows: [.time(MedicationSlotClock.defaultAfternoonTime.dateComponents)],
                                         photo: nil)
        XCTAssertNil(coordinator.updateMedication(id: dementia.id, edit))
        let kept = try XCTUnwrap(
            scheduler.medicationEntries().first { $0.id == dementia.id })
        XCTAssertTrue(kept.photoVerificationEnabled,
                      "an edit must not re-default a stored dementia toggle (FR-MSR-020)")
        XCTAssertEqual(kept.doseDescription, "5 mg", "the edit itself still lands")
    }

    // MARK: - Fixtures and helpers

    /// A legacy-shape daily entry — the pre-slot construction (`slot`
    /// nil, quantity/mealRelation nil), with the dementia toggle
    /// overridable for the FR-MSR-020 pin.
    private func legacyEntry(name: String, times: [DateComponents],
                             photoVerificationEnabled: Bool = false) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "",
            scheduleTimes: times,
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: photoVerificationEnabled,
            confirmationDescription: nil)
    }

    /// The real coordinator over the real scheduler (the T-013 recipe),
    /// with the T-017 seams injected: a household-mapping store over an
    /// in-memory channel and an evidence store rooted at the scratch
    /// directory. `entries` seeds the schedule; the RETURNED `restore`
    /// closure must be deferred by the TEST method (a defer inside this
    /// helper would fire before the test body runs).
    @MainActor
    private func makeSeededCoordinator(
        slotClock: MedicationSlotClock? = nil,
        slotClockJSON: String? = nil,
        entries: [MedicationEntry],
        evidenceRoot: URL? = nil
    ) -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
          restore: () -> Void)? {
        let coordinator = makeCoordinator(slotClock: slotClock,
                                          slotClockJSON: slotClockJSON,
                                          evidenceRoot: evidenceRoot)
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return nil }
        let previous = scheduler.medicationEntries()
        scheduler.loadSchedule(entries: entries)
        return (coordinator, scheduler, { scheduler.loadSchedule(entries: previous) })
    }

    @MainActor
    private func makeCoordinator(slotClock: MedicationSlotClock?,
                                 slotClockJSON: String?,
                                 evidenceRoot: URL?) -> AppCoordinator {
        let clockStorage = MedicationSaveTestStorage()
        if let slotClockJSON {
            // Corruption must arrive as stored bytes: the store's own save
            // validates and would refuse an invalid mapping.
            clockStorage.seed(json: slotClockJSON, forKey: MedicationSlotClockStore.storageKey)
        } else if let slotClock {
            _ = MedicationSlotClockStore(storage: clockStorage).save(slotClock)
        }
        return AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: clockStorage),
            medicationEvidenceStore: MedicationEvidenceStore(
                rootDirectory: evidenceRoot ?? self.evidenceRoot))
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The new save plumbing's code region (comment-stripped, whitespace
    /// collapsed): the request-taking entry points through the private
    /// helpers, up to the shipped `removeMedication`.
    private func saveRegion() -> String {
        collapsed(region("func addMedication(_ request: MedicationSaveRequest)",
                         to: "func removeMedication(id: UUID)"))
    }

    /// The text between two code markers (comment-stripped, so the
    /// markers and pins are code, never prose — the
    /// `CallConfirmationWordingTests.region` convention).
    private func region(_ start: String, to end: String) -> String {
        let text = coordinatorSource()
        guard let startRange = text.range(of: start) else {
            XCTFail("AppCoordinator.swift has no `\(start)`")
            return ""
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`")
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences survive while
    /// indentation and line breaks do not.
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// One stored property of `subject`, by label. The `as? T` cast
    /// unwraps one level of `Optional` (the house `stored` helper, the
    /// `MedicationAckClarificationTests` convention). A missing label or
    /// a mismatched type is an explicit failure, never a silent nil.
    private func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self,
                           file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject).children.first(where: { $0.label == label }) else {
            XCTFail("no stored property '\(label)' on \(Swift.type(of: subject))",
                    file: file, line: line)
            return nil
        }
        guard let value = child.value as? T else {
            XCTFail("stored property '\(label)' is not a \(T.self) — holds \(Swift.type(of: child.value))",
                    file: file, line: line)
            return nil
        }
        return value
    }

    // MARK: - Test doubles
    // (private to this suite, the house pattern its sibling suites ship)

    /// In-memory `EncryptedLocalStorage` for the household-mapping store:
    /// JSON encode/decode like the shipped file store, plus the raw seed
    /// seam a corrupt record needs.
    private final class MedicationSaveTestStorage: EncryptedLocalStorage {
        private var store: [String: Data] = [:]

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? JSONEncoder().encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            store[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = store[key] else { return .failure(.encryptedReadFailed) }
            guard let value = try? JSONDecoder().decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            store.removeValue(forKey: key)
            return .success(())
        }

        /// Stores a hand-written payload verbatim — the bytes the real
        /// store would have to hand back.
        func seed(json: String, forKey key: String) {
            store[key] = Data(json.utf8)
        }
    }

    /// In-memory stand-in for the coordinator's profile payload channel
    /// (the `MedicationAckClarificationTests` helper: the seam is the
    /// real scheduler and the real save path; only the profile store's
    /// channel is faked).
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    // MARK: - Language seeding (the T-013 recipe)

    private static let languageKey = "appLanguage"
    private var languageBackup: Any?
    private var evidenceRoot: URL!

    override func setUp() {
        super.setUp()
        // Seed BEFORE any coordinator exists: the init restores through
        // the real `AppLanguage.persisted()` seam, so the composed dose
        // line resolves the English catalog deterministically.
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        evidenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicationSavePlumbing-" + UUID().uuidString,
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: evidenceRoot,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let evidenceRoot {
            try? FileManager.default.removeItem(at: evidenceRoot)
        }
        if let languageBackup {
            UserDefaults.standard.set(languageBackup, forKey: Self.languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.languageKey)
        }
        super.tearDown()
    }
}
