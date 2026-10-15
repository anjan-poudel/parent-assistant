import XCTest
@testable import ElderlyAssistant

/// T-023 — the medication MANAGE screen (owner-directed, amendment 6).
///
/// The unit repairs the two owner reports against the W0–W4 device build:
///
///  1. "the Settings medication UI always shows the add-new-medication
///     form and never shows existing schedules" — the shipped leaf made
///     the inline form the whole screen. The manage list inverts that
///     (list first, explicit add, tap-to-edit pre-filled through the
///     shipped T-018 conversion);
///  2. "I entered a medication schedule and it just disappeared" — two
///     mechanisms, both closed here: the DISPLAY half (a computed
///     `medicationEntries` behind no observable revision, so the screen
///     re-drew on incidental churn) and the REAL-LOSS half (the
///     `loadSchedule` persist tail discarded its write result, so a
///     failed write read as "saved" while nothing was stored).
///
/// The suite asserts BOTH the pure seams (row composition through the
/// one composer, the shipped key tables, the prefill source) and the
/// durable mechanism (the revision bump, the write-first-or-fail tail,
/// the coordinator guards) — the same static + behavioral idiom its
/// sibling `MedicationEditorSurfaceTests` ships, on purpose: one testing
/// style for this feature's surfaces.
final class MedicationManageListTests: XCTestCase {

    // MARK: - The list-first presentation

    /// The first Gherkin scenario: every schedule is listed — name, dose
    /// line, slot + meal context, purpose — and a LEGACY entry appears
    /// exactly as stored. The list's content is the coordinator's own
    /// answer (`coordinator.medicationEntries`), and the T-020
    /// Medicine-times card stays reachable on the same screen.
    func testListRendersAllEntriesLegacyIncluded() {
        let legacy = legacyEntry(name: "Metformin",
                                 times: [DateComponents(hour: 10, minute: 30)])
        let slot = medicationEntry(name: "Amlodipine", doseDescription: "1 tablet",
                                   times: [MedicationSlotClock.defaultMorningTime.dateComponents],
                                   slot: .morning, mealRelation: .afterMeal)
        let bare = medicationEntry(name: "Vitamin D", doseDescription: "",
                                   times: [DateComponents(hour: 9, minute: 0)])

        let rows = [legacy, slot, bare].map {
            MedicationManageListView.rowLines(for: $0, locale: english)
        }
        XCTAssertEqual(rows.map(\.name), ["Metformin", "Amlodipine", "Vitamin D"],
                       "every entry has its row, the legacy one included")

        XCTAssertEqual(rows[0].whenLine,
                       MedicationScheduleSettingsView.timesText(legacy.scheduleTimes),
                       "a legacy row keeps its stored clock times through the shipped formatter")
        XCTAssertFalse(rows[0].whenLine.contains(
            L10n.str(MedicationScheduleSettingsView.slotKey(for: .morning), locale: english)),
                       "no slot label appears on a legacy entry — nothing is converted in the list (D2)")
        XCTAssertEqual(rows[1].doseLine, "1 tablet",
                       "a slot entry's dose line renders as stored")
        XCTAssertNil(rows[2].doseLine,
                     "an empty dose line draws no dose line at all")
        XCTAssertNil(rows[2].purpose)

        // The mechanisms the rows hang off, in the code: rows render the
        // coordinator's entries, the empty branch is the only other
        // shape, and the Medicine-times card is hosted HERE — on the
        // manage screen, not buried one cover down (T-020 reachability).
        let manage = manageSource()
        XCTAssertTrue(manage.contains("ForEach(listEntries)"),
                      "one row per entry, no filtering")
        XCTAssertTrue(manage.contains("coordinator.medicationEntries"),
                      "the list draws the coordinator's own answer")
        XCTAssertTrue(manage.contains("MedicationScheduleSettingsView(screen: .medicineTimesCard)"),
                      "the Medicine-times card (and its one-shot retime note) is reachable on the manage screen")
        XCTAssertTrue(leafSource().contains("case .medicineTimesCard"),
                      "…through the shipped card arm — the shipped suite's card keeps its home")
    }

    /// The row's composition, resolved through the ONE composer and the
    /// ONE key mapping: the C2 dose line round-trips the stored words,
    /// the slot and meal keys are the shipped statics' keys, and the
    /// purpose chip's stored id resolves its label in the active locale.
    func testRowCompositionCarriesNameDoseLineSlotMealAndPurpose() {
        let quantity = MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue)
        let entry = medicationEntry(name: "Amlodipine",
                                    doseDescription: "1 tablet, after dinner",
                                    times: [MedicationSlotClock.defaultEveningTime.dateComponents],
                                    purpose: "bloodPressure",
                                    quantity: quantity, slot: .evening, mealRelation: .afterMeal)

        let lines = MedicationManageListView.rowLines(for: entry, locale: english)
        XCTAssertEqual(lines.name, "Amlodipine")
        XCTAssertEqual(lines.doseLine, "1 tablet, after dinner",
                       "the row states the same words the save path composed (C2)")
        XCTAssertEqual(lines.doseLine,
                       DoseLine.compose(quantity: quantity, doseText: "after dinner",
                                        locale: english),
                       "…through the one composer, never a second string assembly")
        XCTAssertEqual(lines.whenLine,
                       L10n.str(MedicationScheduleSettingsView.slotKey(for: .evening),
                                locale: english)
                       + " · "
                       + L10n.str(MedicationScheduleSettingsView.mealKey(for: .afterMeal),
                                  locale: english),
                       "time of day and meal context, both named through the shipped key tables")
        XCTAssertEqual(lines.purpose,
                       L10n.str("meds.purpose.bloodPressure", locale: english),
                       "the chip's stored id resolves its label at draw time")
        XCTAssertNotEqual(MedicationManageListView.rowLines(for: entry, locale: nepali).purpose,
                          lines.purpose,
                          "the same row reads Nepali under the Nepali locale")

        // A slot row with no meal relation states the slot alone — the
        // separator never dangles.
        let noMeal = medicationEntry(name: "Vitamin D", doseDescription: "",
                                     times: [MedicationSlotClock.defaultMorningTime.dateComponents],
                                     slot: .morning)
        XCTAssertEqual(MedicationManageListView.rowLines(for: noMeal, locale: english).whenLine,
                       L10n.str(MedicationScheduleSettingsView.slotKey(for: .morning),
                                locale: english))

        // A line whose halves do not align keeps the family's words,
        // verbatim (the composer's rule 3, mirrored in the row).
        let foreign = medicationEntry(name: "Metformin", doseDescription: "one pill",
                                      times: [DateComponents(hour: 8, minute: 0)])
        let foreignLines = MedicationManageListView.rowLines(for: foreign, locale: english)
        XCTAssertEqual(foreignLines.doseLine, "one pill",
                       "foreign text is never recomposed into a quantity statement")
        XCTAssertNil(foreignLines.purpose)
    }

    /// The second Gherkin scenario: the row IS the edit door, and the
    /// form it opens is pre-filled through the SHIPPED T-018 conversion —
    /// asserted at the source, because "reuse, never rebuild" is exactly
    /// the property that needs the source: the manage list calls the
    /// leaf's editing initializer, and that initializer's seed is
    /// `Self.draft(from:)` plus the editing id (so Save edits the same
    /// entry — no duplicate).
    func testRowTapOpensEditorPrefilled() {
        let manage = manageSource()
        let row = region("private func row(_ entry: MedicationEntry)",
                         to: "private var addControl", in: manage)
        XCTAssertTrue(row.contains("EditorTarget(entry: entry)"),
                      "the row, not a new control, is the edit-existing door")

        let editor = region("private func editor(for target: EditorTarget)",
                            to: "static func rowLines", in: manage)
        XCTAssertTrue(editor.contains("MedicationScheduleSettingsView(editing: entry"),
                      "the edit arm presents the shipped form through its editing initializer")
        XCTAssertFalse(manage.contains("draft(from:"),
                       "the manage list composes no draft of its own — the prefill source is the leaf's initializer")

        let leaf = leafSource()
        let editingInit = region("init(editing entry: MedicationEntry", to: "var body", in: leaf)
        XCTAssertTrue(editingInit.contains("Self.draft(from: entry, locale: locale)"),
                      "…whose state seed IS the T-018 conversion (IF-22) — a call, never a copy")
        XCTAssertTrue(editingInit.contains("_editingEntryId = State(initialValue: entry.id)"),
                      "…plus the editing id, so a save edits that entry instead of creating a duplicate")
    }

    /// The third Gherkin scenario: the add control opens the SAME form in
    /// new-entry mode — the shipped initializer with no editing argument,
    /// under the shipped `settings.meds.add` caption.
    func testAddControlOpensNewEntryForm() {
        let manage = manageSource()
        let add = region("private var addControl", to: "private func editor(for", in: manage)
        XCTAssertTrue(add.contains("EditorTarget(entry: nil)"),
                      "the add control opens the form with no entry — new-entry mode")
        XCTAssertTrue(add.contains("\"settings.meds.add\""),
                      "…under the shipped add caption")

        let editor = region("private func editor(for target: EditorTarget)",
                            to: "static func rowLines", in: manage)
        XCTAssertTrue(editor.contains("MedicationScheduleSettingsView(onSaveLanded: { editorTarget = nil })"),
                      "the new-entry arm constructs the shipped form with no editing argument")
        XCTAssertFalse(manage.contains("editing: nil"),
                       "…and invents no spelling the shipped initializer does not have")
    }

    /// The never-auto-opens half of report 1, as mechanism: the manage
    /// screen's arrival content is the list (or the empty card) and the
    /// add control — the form exists only behind a non-nil presentation
    /// target that exactly two explicit controls can set.
    func testAddFormDoesNotAutoOpenOnAppear() {
        let manage = manageSource()
        XCTAssertFalse(manage.contains("onAppear"),
                       "no appear hook exists on this screen")
        XCTAssertFalse(manage.contains(".task"),
                       "…and no task either — nothing runs on arrival but drawing")
        XCTAssertTrue(manage.contains("@State private var editorTarget: EditorTarget?"),
                      "the presentation target starts nil…")
        XCTAssertEqual(count(of: "editorTarget = EditorTarget(", in: manage), 2,
                       "…and exactly two explicit controls set it: a row tap, and the add control")
        XCTAssertTrue(manage.contains("fullScreenCover(item: $editorTarget)"),
                      "the form is reachable only through the cover's non-nil target")
        XCTAssertEqual(count(of: "editorTarget = nil", in: manage), 2,
                       "both arms dismiss on a landed save; a failed save leaves the form up")

        let body = region("var body: some View", to: "private var listEntries", in: manage)
        XCTAssertTrue(body.contains("if listEntries.isEmpty"),
                      "the arrival content is the list or the honest empty card")
        XCTAssertTrue(body.contains("ForEach(listEntries)"),
                      "…one row per existing schedule")
        XCTAssertFalse(body.contains("addForm"),
                       "the shipped add form is never drawn on the manage screen — it lives one cover down")
        XCTAssertTrue(body.contains("addControl"),
                      "the explicit add control is the way in")
    }

    /// The fourth Gherkin scenario: the empty household sees the existing
    /// words — `settings.meds.empty`, verbatim — and the form still does
    /// not open itself.
    func testEmptyStateUsesTheExistingString() {
        let manage = manageSource()
        XCTAssertTrue(manage.contains("if listEntries.isEmpty"),
                      "the empty branch is an emptiness test, not a launch default")
        XCTAssertTrue(manage.contains("Text(\"settings.meds.empty\")"),
                      "…drawing the shipped empty caption")

        XCTAssertEqual(L10n.str("settings.meds.empty", locale: english),
                       "No medications scheduled yet",
                       "the shipped words, verbatim — the Gherkin's own sentence")
        let nepaliEmpty = L10n.str("settings.meds.empty", locale: nepali)
        XCTAssertFalse(nepaliEmpty.isEmpty)
        XCTAssertNotEqual(nepaliEmpty, "No medications scheduled yet",
                          "the empty line is translated, not English-in-Nepali")

        XCTAssertTrue(manage.contains("Text(\"settings.meds.add\")"),
                      "the empty screen's way out is the shipped add control")
    }

    /// The fifth Gherkin scenario (guard): every user-visible line draws
    /// through the appearance tokens (whose `scaled` floors at 18pt), and
    /// every interactive element carries the 44pt tap floor. The only
    /// raw font sizes are the three decorative icon glyphs, each on a
    /// Button with its own accessibility label.
    func testManageListMeetsElderlyFitFloor() {
        let manage = manageSource()

        for line in manage.split(separator: "\n") where line.contains(".font(") {
            let source = String(line)
            XCTAssertTrue(source.contains("appearance.typography.")
                          || source.contains("size: 22)")
                          || source.contains("size: 24, weight:"),
                          "type outside the scaled tokens breaks the 18pt floor: \(source)")
        }
        // The exemptions are counted, not assumed: exactly three glyph
        // fonts (photo, delete, add), everything else token-drawn.
        XCTAssertEqual(count(of: ".font(", in: manage),
                       count(of: ".font(.system(size: appearance.typography.", in: manage) + 3,
                       "three decorative glyph sizes and no other raw font")

        for line in manage.split(separator: "\n") where line.contains(".frame(minHeight:") {
            XCTAssertTrue(String(line).contains("DesignTokens."),
                          "a height floor outside the design tokens: \(line)")
        }
        XCTAssertEqual(count(of: ".frame(minWidth: DesignTokens.minTapTargetSize", in: manage), 2,
                       "both icon buttons hold the 44pt width floor")
        XCTAssertEqual(count(of: "accessibilityLabel(Text(\"visualAid.add\"))", in: manage), 1,
                       "the photo button announces itself")
        XCTAssertEqual(count(of: "accessibilityLabel(Text(\"settings.meds.delete\"))", in: manage), 1,
                       "…and so does the delete button")

        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44,
                                    "NFR-MSR-005's floor is at least 44pt")
        let typography = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Theme/AppTypography.swift"))
        XCTAssertTrue(typography.contains("max(18"),
                      "every scaled token resolves at or above the 18pt legibility floor")
    }

    // MARK: - The save-visibility contract (owner report 2)

    /// Requirement (b): a saved entry is visible IMMEDIATELY — the list's
    /// redraw dependency is explicit. The save bumps the coordinator's
    /// published revision by exactly one, the revision is bumped only on
    /// the committed-write seam, and the manage list reads it in its
    /// body path instead of hoping for incidental `@Published` churn.
    @MainActor
    func testSavedEntryAppearsImmediatelyWithoutRelaunch() throws {
        let (coordinator, _, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }
        XCTAssertTrue(coordinator.medicationEntries.isEmpty,
                      "the household starts with nothing scheduled")
        let before = coordinator.medicationScheduleRevision

        let request = MedicationSaveRequest(name: "Amlodipine", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.slot(.morning)], photo: nil)
        XCTAssertNil(coordinator.addMedication(request), "the save lands")

        let saved = try XCTUnwrap(coordinator.medicationEntries
            .first { $0.medicationName == "Amlodipine" },
            "the new entry is in the list's content the moment the save returns")
        XCTAssertEqual(coordinator.medicationScheduleRevision, before + 1,
                       "…and the published revision moved by exactly this save — the explicit redraw signal")

        // The list draws that very entry on the very next body pass.
        XCTAssertEqual(MedicationManageListView.rowLines(for: saved,
                                                         locale: coordinator.activeLocale).name,
                       "Amlodipine")

        // The mechanism, in the code: the signal is published state …
        let coordinatorText = coordinatorSource()
        XCTAssertTrue(coordinatorText.contains("@Published private(set) var medicationScheduleRevision = 0"),
                      "the redraw signal is @Published — the list depends on it, not on a side channel")
        XCTAssertTrue(collapsed(coordinatorText).contains("self.medicationScheduleRevision += 1"),
                      "…bumped at the one seam every committed medication write funnels through")
        // …and the list reads it in its own content path.
        XCTAssertTrue(manageSource().contains("coordinator.medicationScheduleRevision"),
                      "the manage list's body reads the revision, so the save re-draws the list")
    }

    /// The round trip behind "it just disappeared": a saved entry is in
    /// the persisted payload, survives a FRESH scheduler over the same
    /// storage (the relaunch simulation), and its reminder is re-armed
    /// from the persisted entry.
    @MainActor
    func testSavedEntrySurvivesRelaunchAndStaysArmed() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        let request = MedicationSaveRequest(name: "Metformin", strength: nil, purpose: nil,
                                            quantity: nil, mealRelation: nil,
                                            rows: [.time(DateComponents(hour: 10, minute: 30))],
                                            photo: nil)
        XCTAssertNil(coordinator.addMedication(request),
                     "the save must land before a relaunch can be simulated")
        let saved = try XCTUnwrap(coordinator.medicationEntries
            .first { $0.medicationName == "Metformin" })

        // The relaunch: process death is a fresh scheduler over the same
        // storage — the exact read path a cold start takes (`scheduleAll`
        // restores from disk and re-arms every un-fired dose).
        let storage = try XCTUnwrap(stored("storage", of: scheduler,
                                           as: EncryptedLocalStorage.self),
                                    "the scheduler persists through its injected storage")
        let alarm = MockAlarmScheduler()
        let relaunched = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarm,
            observabilityBus: MockObservabilityBus(),
            familyNotifier: MockFamilyNotifier(),
            caregiverNotifySettings: CaregiverNotifySettings.isolated())
        relaunched.scheduleAll()

        XCTAssertEqual(relaunched.medicationEntries().map(\.id), [saved.id],
                       "the persisted entry is still there after the relaunch")
        let restored = try XCTUnwrap(relaunched.medicationEntries().first)
        XCTAssertEqual(restored.medicationName, "Metformin")
        XCTAssertEqual(restored.scheduleTimes.first?.hour, 10)
        XCTAssertEqual(restored.scheduleTimes.first?.minute, 30)

        XCTAssertEqual(relaunched.pendingReminders.count, 1,
                       "the dose is restored as a pending reminder")
        XCTAssertEqual(relaunched.pendingReminders.first?.medicationEntryId, saved.id)
        let armed = try XCTUnwrap(alarm.scheduledReminders.values.first,
                                  "the restored dose is re-armed from the persisted entry")
        XCTAssertEqual(Calendar.current.component(.hour, from: armed), 10)
        XCTAssertEqual(Calendar.current.component(.minute, from: armed), 30)
    }

    /// Requirement (a)/(c) at the scheduler seam — the exact write path
    /// every coordinator save funnels through: a failed persist is LOUD
    /// (the shipped `entry_persistence_failed` event, the `false` return
    /// every caller is pinned to honor) and NOTHING moves behind a
    /// schedule that was not stored — the previous schedule stays in
    /// memory, on disk and armed, and a refused retime moves nothing.
    ///
    /// The coordinator half is a source pin, on purpose (disclosed in the
    /// unit report): `AppCoordinator` composes its scheduler over the
    /// concrete `MigratingEncryptedStorage` with no storage seam, so a
    /// coordinator-level write failure cannot be driven without
    /// fabricating a seam the app does not have. The propagation IS
    /// pinned where it lives: all four save paths gate on this Bool.
    func testPersistFailureOnSaveIsLoudAndNothingIsArmed() throws {
        let storage = MockEncryptedLocalStorage()
        let alarm = MockAlarmScheduler()
        let observability = MockObservabilityBus()
        let scheduler = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarm,
            observabilityBus: observability,
            familyNotifier: MockFamilyNotifier(),
            caregiverNotifySettings: CaregiverNotifySettings.isolated())

        let previous = medicationEntry(name: "Metformin", doseDescription: "",
                                       times: [DateComponents(hour: 10, minute: 0)])
        XCTAssertTrue(scheduler.loadSchedule(entries: [previous]),
                      "the household's previous schedule persists and arms")
        XCTAssertEqual(alarm.scheduledReminders.count, 1)
        observability.emittedEvents.removeAll()

        // The failure: the entries write refuses. This is the save every
        // coordinator path performs — loadSchedule with the next state.
        storage.shouldFailWrite = true
        let added = medicationEntry(name: "Amlodipine", doseDescription: "",
                                    times: [DateComponents(hour: 8, minute: 0)])
        XCTAssertFalse(scheduler.loadSchedule(entries: [previous, added]),
                       "a failed persist is the caller's failure — never a silent success")

        XCTAssertTrue(observability.emittedEvents.contains {
            $0.eventType == "entry_persistence_failed"
        }, "the shipped failure event reports the write (PII-free)")
        XCTAssertFalse(observability.emittedEvents.contains {
            $0.eventType == "schedule_loaded"
        }, "a failed persist loads nothing — the share observer is never told either")

        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [previous.id],
                       "nothing is adopted: the previous schedule is intact in memory")
        XCTAssertEqual(alarm.scheduleCallCount, 1,
                       "a failed save arms nothing new")
        XCTAssertEqual(alarm.scheduledReminders.count, 1,
                       "…and the previous dose stays armed, exactly as it was")
        XCTAssertEqual(scheduler.pendingReminders.first?.medicationEntryId, previous.id)

        guard case .success(let stored) = storage.read(key: "medication.entries",
                                                       type: [MedicationEntry].self) else {
            return XCTFail("the previously persisted schedule must still be on disk")
        }
        XCTAssertEqual(stored.map(\.id), [previous.id],
                       "storage still holds the schedule that WAS persisted — memory and disk agree")

        // The retime path reports the same failure instead of a silent
        // "retimed": the write is the gate there too.
        XCTAssertFalse(scheduler.setScheduleTimes([DateComponents(hour: 9, minute: 0)],
                                                  entryId: previous.id))
        XCTAssertEqual(scheduler.medicationEntries().first?.scheduleTimes.first?.hour, 10,
                       "a refused retime moves nothing")
        XCTAssertFalse(observability.emittedEvents.contains {
            $0.eventType == "medication_retime_refused"
        }, "the WRITE failed — this was no slot refusal")
        XCTAssertEqual(observability.emittedEvents.filter {
            $0.eventType == "entry_persistence_failed"
        }.count, 2, "both failed writes were reported")

        // The coordinator propagation, pinned where it lives: every save
        // path gates on the Bool and says so honestly, and nothing arms
        // before the guard passes.
        let coordinatorText = coordinatorSource()
        XCTAssertEqual(count(of: "guard medicationScheduler.loadSchedule(entries: entries)",
                             in: coordinatorText), 4,
                       "all four save paths gate on the persist result: add, slot save, remove, voice")
        let collapsedCoordinator = collapsed(coordinatorText)
        XCTAssertTrue(collapsedCoordinator.contains(
            "guard medicationScheduler.loadSchedule(entries: entries) else { return \"settings.meds.saveFailed\" }"),
            "the family-facing paths surface the shipped failure line")
        XCTAssertTrue(collapsedCoordinator.contains(
            "guard medicationScheduler.loadSchedule(entries: entries) else { return false }"),
            "the remove path reports the refused removal to the manage list")
        XCTAssertEqual(count(of: "\"settings.meds.saveFailed\"", in: coordinatorText), 3,
                       "the three family-facing save paths (add, slot save, voice) name the same key")

        let saveRegion = collapsed(region("func addMedication(_ request: MedicationSaveRequest)",
                                          to: "func removeMedication(id: UUID)",
                                          in: coordinatorText))
        let guardRange = try XCTUnwrap(saveRegion.range(of:
            "guard medicationScheduler.loadSchedule(entries: entries) else { return \"settings.meds.saveFailed\" }"))
        let armRange = try XCTUnwrap(saveRegion.range(of: "medicationScheduler.scheduleAll()"))
        XCTAssertLessThan(guardRange.lowerBound, armRange.lowerBound,
                          "the save path arms only AFTER the persist succeeded")
    }

    // MARK: - Fixtures

    /// The calendar the stored-times comparisons run under: fixed UTC,
    /// the T-009 fixture.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var english: Locale { AppLanguage.english.locale }
    private var nepali: Locale { AppLanguage.nepali.locale }

    private func legacyEntry(name: String, times: [DateComponents]) -> MedicationEntry {
        medicationEntry(name: name, doseDescription: "", times: times)
    }

    private func medicationEntry(
        name: String,
        doseDescription: String,
        times: [DateComponents],
        purpose: String? = nil,
        quantity: MedicationQuantity? = nil,
        slot: MedicationSlot? = nil,
        mealRelation: MealRelation? = nil
    ) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: doseDescription,
            scheduleTimes: times,
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            purpose: purpose,
            quantity: quantity,
            slot: slot,
            mealRelation: mealRelation)
    }

    /// The real coordinator over the real scheduler (the T-017/T-018
    /// recipe), with the constructor seams injected. `entries` seeds the
    /// schedule; the RETURNED `restore` closure must be deferred by the
    /// TEST method (a defer inside this helper would fire before the
    /// test body runs).
    @MainActor
    private func makeSeededCoordinator(entries: [MedicationEntry])
        -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
            restore: () -> Void)? {
        let coordinator = AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: MedicationSurfaceTestStorage()),
            medicationEvidenceStore: MedicationEvidenceStore(rootDirectory: evidenceRoot))
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return nil }
        let previous = scheduler.medicationEntries()
        scheduler.loadSchedule(entries: entries)
        return (coordinator, scheduler, { scheduler.loadSchedule(entries: previous) })
    }

    /// One stored property of `subject`, by label (the house `stored`
    /// helper). A missing label or a mismatched type is an explicit
    /// failure, never a silent nil.
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

    // MARK: - Source slicing (the presentation-suite idiom)

    /// The manage list's own source, comment-stripped and sliced at its
    /// column-0 boundaries.
    private func manageSource() -> String {
        structSource(named: "MedicationManageListView",
                     in: "ElderlyAssistant/App/MedicationManageListView.swift")
    }

    /// The shipped leaf's source — the file the prefill conversion and
    /// the card arm live in.
    private func leafSource() -> String {
        structSource(named: "MedicationScheduleSettingsView",
                     in: "ElderlyAssistant/App/SettingsView.swift")
    }

    private func structSource(named name: String, in path: String) -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent(path)
        let text = FeatureSourceScan.codeText(of: url)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name)") }) else {
            XCTFail("\(path) has no top-level struct \(name)")
            return ""
        }
        let end = lines[(start + 1)...].firstIndex { line in
            ["struct ", "enum ", "extension ", "final class ", "class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// The coordinator's full source (comment-stripped) — the file the
    /// save-path propagation lives in.
    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The text between two code markers (comment-stripped, so the
    /// markers and pins are code, never prose — the house `region`
    /// convention).
    private func region(_ start: String, to end: String, in text: String) -> String {
        guard let startRange = text.range(of: start) else {
            XCTFail("the source has no `\(start)`")
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

    private func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - Test doubles
    // (private to this suite, the house pattern its sibling suites ship;
    // the alarm/observability/notifier doubles are the reusable
    // top-level ones from the scheduler suite)

    /// In-memory `EncryptedLocalStorage` for the household-mapping store:
    /// every test here runs on the mapping's defaults (an absent record).
    private final class MedicationSurfaceTestStorage: EncryptedLocalStorage {
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
            .appendingPathComponent("MedicationManageList-" + UUID().uuidString,
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
