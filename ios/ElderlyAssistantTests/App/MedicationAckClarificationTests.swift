import XCTest
@testable import ElderlyAssistant

/// T-013 — the clarification walk's state half (C4; IF-7 + IF-8;
/// FR-MSR-007/008/009). The walk exists so ambiguity is NEVER guessed:
/// these tests pin the fixed candidate order, the sanctioned question
/// forms, the pair/three-or-more answer rules (m-4), the deterministic
/// ends (including a short injected window), the `isAwaitingConfirmation`
/// fold — and, negatively, that no recording path is reachable from the
/// walk and that the walk mints no second yes/no vocabulary.
///
/// The coordinator is the real one over the real scheduler (the
/// `DialogueCoordinatorWiringTests` recipe: Mirror the private scheduler
/// seam, `loadSchedule`, restore in `defer`); the candidates under test
/// are always what IF-7 really returns for a seeded schedule — never
/// hand-built structs — so the suite exercises the seam chain the router
/// will call (schedule → candidates → walk → outcome). Speech is a no-op
/// without `start()` (no speaker / no queue), so the questions are pinned
/// through `ackClarificationQuestion(for:)`, the one home the `speak`
/// call wraps, plus the resolved catalog copy itself in both languages.
final class MedicationAckClarificationTests: XCTestCase {

    // MARK: - Named tests (T-013)

    /// Candidate order is ALWAYS `scheduledAt`, canonical name, id — never
    /// the load order, never the schedule's name-sorted order, never
    /// firing order. The fixture mixes all three discriminators: distinct
    /// times in non-alphabetical order, a same-time name tiebreak, and a
    /// same-time/same-name id tiebreak.
    @MainActor
    func testCandidatesUseFixedOrderNotFiringOrder() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        let fixture = try Self.fixedOrderFixture()
        scheduler.loadSchedule(entries: fixture.entries)

        let candidates = coordinator.medicationAckCandidates()
        XCTAssertEqual(candidates.map(\.entryId),
                       [fixture.amlodipine, fixture.paracetamol, fixture.metformin,
                        fixture.vitaminD, fixture.zinc, fixture.calciumOne, fixture.calciumTwo],
                       "the candidates must come back in the fixed scheduledAt/name/id order")
        XCTAssertEqual(candidates.map(\.medicationName),
                       ["Amlodipine", "Paracetamol", "Metformin", "Vitamin D", "Zinc",
                        "Calcium", "Calcium"],
                       "and never in the schedule's name-sorted order")
        XCTAssertTrue(candidates.allSatisfy { !$0.fired && $0.slot == nil },
                      "the fixture's reminders are unfired legacy-shape entries — fired=false, slot=nil")

        // The ONE ordering rule: the resolver's own outputs carry the same
        // order for the same set (its comparator is private; this pins the
        // two halves against each other).
        let resolution = MedicationAckResolver.resolve(utterance: "मैले औषधि खाएँ",
                                                       candidates: candidates)
        XCTAssertEqual(resolution, .ambiguous(ordered: candidates.map(\.entryId)),
                       "the resolver's ambiguous walk order must equal IF-7's order")
    }

    /// The pair form first; "yes" falls to the single form at cursor 0 and
    /// resolves there — with the sanctioned copy in both languages.
    @MainActor
    func testPairFormYesFallsToSingleFormAtCursorZero() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        let entries = Self.pairFixture()
        scheduler.loadSchedule(entries: entries)
        let amlodipine = entries[0].id

        let candidates = coordinator.medicationAckCandidates()
        XCTAssertEqual(candidates.map(\.entryId), [amlodipine, entries[1].id])

        coordinator.beginAckClarification(candidates: candidates)
        XCTAssertEqual(coordinator.pendingAckClarification?.pairAsked, true,
                       "exactly two candidates open on the pair form")
        XCTAssertEqual(ackQuestion(coordinator), "Did you mean Amlodipine or Metformin?",
                       "the pair question is the sanctioned 'X or Y' form")

        // The copy the walk speaks lives in exactly these three keys — one
        // home each — and resolves in both languages (the walk references
        // keys only).
        let region = walkRegion()
        XCTAssertEqual(occurrences(of: "meds.ack.clarifyPair", in: region), 1)
        XCTAssertEqual(occurrences(of: "meds.ack.clarifyOne", in: region), 1)
        XCTAssertEqual(occurrences(of: "meds.ack.clarifyEnded", in: region), 1)
        XCTAssertEqual(L10n.str("meds.ack.clarifyEnded", locale: AppLanguage.english.locale),
                       "OK, nothing was recorded.")
        XCTAssertEqual(L10n.str("meds.ack.clarifyEnded", locale: AppLanguage.nepali.locale),
                       "ठीक छ, केही टिपिएको छैन।")
        XCTAssertEqual(L10n.fmt("meds.ack.clarifyOne", locale: AppLanguage.nepali.locale,
                                "अम्लोडिपिन"),
                       "तपाईंले अम्लोडिपिन भन्न खोज्नुभयो?")
        XCTAssertEqual(L10n.fmt("meds.ack.clarifyPair", locale: AppLanguage.english.locale,
                                "Amlodipine", "Metformin"),
                       "Did you mean Amlodipine or Metformin?")

        // "Yes" to "X or Y?" narrows to the single form at cursor 0.
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "हो", isYes: true, isNo: false),
                       .narrowed)
        XCTAssertEqual(coordinator.pendingAckClarification?.pairAsked, false)
        XCTAssertEqual(coordinator.pendingAckClarification?.cursor, 0)
        XCTAssertEqual(ackQuestion(coordinator), "Did you mean Amlodipine?",
                       "the narrowed question is the sanctioned single form at cursor 0")

        // A second "yes" resolves to the single form's candidate.
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "हो", isYes: true, isNo: false),
                       .resolved(entryId: amlodipine))
        XCTAssertNil(coordinator.pendingAckClarification)
    }

    /// "No" on the pair form ends the walk (nothing recorded, nothing
    /// left open) — and a response arriving with no walk open is honest:
    /// nothing is interpreted, nothing is re-asked.
    @MainActor
    func testPairFormNoEnds() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        scheduler.loadSchedule(entries: Self.pairFixture())
        let candidates = coordinator.medicationAckCandidates()
        coordinator.beginAckClarification(candidates: candidates)
        XCTAssertEqual(coordinator.pendingAckClarification?.pairAsked, true)

        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .ended(reason: .rejected))
        XCTAssertNil(coordinator.pendingAckClarification)
        XCTAssertFalse(coordinator.isAwaitingAckClarification)

        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "हो", isYes: true, isNo: false),
                       .unanswered,
                       "with no walk open nothing may be interpreted")
    }

    /// Three candidates: the walk opens on the single form at cursor 0 and
    /// "no" advances the cursor and asks the next candidate (m-4).
    @MainActor
    func testThreeCandidatesNoAdvancesToNext() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        scheduler.loadSchedule(entries: Self.threeCandidateFixture())
        let candidates = coordinator.medicationAckCandidates()
        XCTAssertEqual(candidates.count, 3)

        coordinator.beginAckClarification(candidates: candidates)
        XCTAssertEqual(coordinator.pendingAckClarification?.pairAsked, false,
                       "three or more candidates open on the single form — never a numbered list")
        XCTAssertEqual(coordinator.pendingAckClarification?.cursor, 0)
        XCTAssertEqual(ackQuestion(coordinator), "Did you mean Amlodipine?")

        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        XCTAssertEqual(coordinator.pendingAckClarification?.cursor, 1)
        XCTAssertTrue(coordinator.isAwaitingAckClarification,
                      "the walk must stay open while it advances")
        XCTAssertEqual(ackQuestion(coordinator), "Did you mean Metformin?",
                       "the advanced question asks the NEXT candidate")
    }

    /// m-4: two "no"s advance, the third "yes" resolves to the THIRD
    /// candidate — and the resolution hands the id back without beginning
    /// the challenge itself (the caller continues the shipped sequence).
    @MainActor
    func testThirdYesResolvesToThirdCandidate() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        let entries = Self.threeCandidateFixture()
        scheduler.loadSchedule(entries: entries)
        let paracetamol = entries[2].id

        coordinator.beginAckClarification(candidates: coordinator.medicationAckCandidates())
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        XCTAssertEqual(coordinator.pendingAckClarification?.cursor, 2)

        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "हो", isYes: true, isNo: false),
                       .resolved(entryId: paracetamol))
        XCTAssertNil(coordinator.pendingAckClarification)
        XCTAssertNil(coordinator.pendingConfirmationEntryId,
                     "resolution must not open the challenge itself — the caller continues "
                     + "the shipped safety sequence")
    }

    /// The last candidate's "no" ends the walk with nothing recorded: no
    /// adherence log for any walk entry, no reminder touched — and the
    /// walk region contains no recording call by source.
    @MainActor
    func testThreeNosEndWithNothingRecorded() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        let entries = Self.threeCandidateFixture()
        scheduler.loadSchedule(entries: entries)

        guard let logsBefore = stored("adherenceLog", of: scheduler,
                                      as: [MedicationAdherenceLog].self) else { return }
        let reminderIdsBefore = scheduler.pendingReminders.map(\.id).sorted()
        let reminderStatesBefore = scheduler.pendingReminders.map { $0.state.rawValue }.sorted()
        let entryIds = Set(entries.map(\.id))

        coordinator.beginAckClarification(candidates: coordinator.medicationAckCandidates())
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .ended(reason: .rejected),
                       "after the last candidate's no the walk ends (m-4)")
        XCTAssertNil(coordinator.pendingAckClarification)

        guard let logsAfter = stored("adherenceLog", of: scheduler,
                                     as: [MedicationAdherenceLog].self) else { return }
        XCTAssertEqual(logsAfter.count, logsBefore.count,
                       "an unresolved walk must write no adherence log at all")
        XCTAssertTrue(logsAfter.filter { entryIds.contains($0.medicationEntryId) }.isEmpty,
                      "no walk entry may carry an adherence record after three no's")
        XCTAssertEqual(scheduler.pendingReminders.map(\.id).sorted(), reminderIdsBefore,
                       "the reminders must be untouched")
        XCTAssertEqual(scheduler.pendingReminders.map { $0.state.rawValue }.sorted(),
                       reminderStatesBefore,
                       "no reminder state may change")

        // Source pin: nothing in the walk region can record, challenge or
        // hand itself to the recording path.
        let region = walkRegion()
        for call in ["acknowledgeWithConfirmation", ".acknowledge(",
                     "startConfirmationChallenge", "handleMedicationAcknowledgement",
                     "finalizeAcknowledgement"] {
            XCTAssertFalse(region.contains(call),
                           "no recording path may be reachable from the walk (\(call))")
        }
        XCTAssertTrue(region.contains("\"medication_ack_clarify_ended\""),
                      "the walk's end reports honestly on the observability bus")
    }

    /// The same ambiguous utterance and the same pending set always
    /// produce the same clarification — for the resolver's order and for
    /// every question and outcome of the walk, whatever order the
    /// candidates are handed in.
    @MainActor
    func testWalkIsDeterministicForSameInputs() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        scheduler.loadSchedule(entries: Self.threeCandidateFixture())
        let candidates = coordinator.medicationAckCandidates()

        // The resolver's half: same utterance + same set (in any order) =
        // same answer.
        let utterance = "औषधि खाएँ"
        XCTAssertEqual(MedicationAckResolver.resolve(utterance: utterance, candidates: candidates),
                       MedicationAckResolver.resolve(utterance: utterance,
                                                     candidates: Array(candidates.reversed())),
                       "the resolver must be a total deterministic function")

        // The walk's half: same inputs = same question sequence and same
        // outcome sequence — including when the candidates arrive in the
        // opposite order (the walk re-imposes the fixed order itself).
        func run(_ handIn: [MedicationAckCandidate]) -> (questions: [String], outcomes: [AckClarifyOutcome]) {
            coordinator.beginAckClarification(candidates: handIn)
            var questions: [String] = []
            if let state = coordinator.pendingAckClarification {
                questions.append(coordinator.ackClarificationQuestion(for: state))
            }
            var outcomes: [AckClarifyOutcome] = []
            for _ in 0..<3 {
                outcomes.append(coordinator.ackClarificationResponse(raw: "छैन",
                                                                     isYes: false, isNo: true))
                if let state = coordinator.pendingAckClarification {
                    questions.append(coordinator.ackClarificationQuestion(for: state))
                }
            }
            return (questions, outcomes)
        }

        let first = run(candidates)
        let second = run(Array(candidates.reversed()))
        XCTAssertEqual(first.questions, second.questions,
                       "the same clarity must be produced for the same inputs every time")
        XCTAssertEqual(first.outcomes, second.outcomes)
        XCTAssertEqual(first.questions, ["Did you mean Amlodipine?", "Did you mean Metformin?",
                                         "Did you mean Paracetamol?"])
        XCTAssertEqual(first.outcomes, [.advanced, .advanced, .ended(reason: .rejected)])

        // No second yes/no vocabulary: the walk never re-parses "yes"/"no"
        // words — the router's shipped classifiers own them.
        let region = walkRegion()
        XCTAssertFalse(region.contains("isYesResponse"))
        XCTAssertFalse(region.contains("isNoResponse"))
        XCTAssertFalse(region.contains("\"हो\""))
    }

    /// The response window comes from `AckClarificationConfig` only — the
    /// default composes from the one named home, a short injected window
    /// really expires the walk, and the region reads no literal.
    @MainActor
    func testWindowComesFromAckClarificationConfig() async throws {
        XCTAssertEqual(AckClarificationConfig().responseWindowSeconds,
                       ConfirmationChallenge.defaultChallengeTimeoutSeconds,
                       "the default window must compose from the one named home")

        let coordinator = makeCoordinator(AckClarificationConfig(responseWindowSeconds: 0.2))
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        scheduler.loadSchedule(entries: Self.threeCandidateFixture())
        coordinator.beginAckClarification(candidates: coordinator.medicationAckCandidates())
        XCTAssertTrue(coordinator.isAwaitingAckClarification)

        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(coordinator.pendingAckClarification,
                     "the injected short window must expire the walk")
        XCTAssertFalse(coordinator.isAwaitingAckClarification)

        let region = walkRegion()
        XCTAssertEqual(occurrences(of: "ackClarificationConfig.responseWindowSeconds", in: region), 2,
                       "both arming sites read the config value")
        XCTAssertFalse(region.contains("defaultChallengeTimeoutSeconds"),
                       "the walk reads the config, never the constant directly")
        XCTAssertFalse(region.contains("TimeInterval = 30"),
                       "the walk must mint no window literal")
    }

    /// The walk rides the shipped `isAwaitingConfirmation` OR-fold: an
    /// open walk answers true, its end flips the fold back — and a live
    /// medication challenge outranks a begin (the C4 invariant).
    @MainActor
    func testWalkStateRidesIsAwaitingConfirmationFold() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        scheduler.loadSchedule(entries: Self.pairFixture())
        let before = coordinator.isAwaitingConfirmation
        XCTAssertFalse(coordinator.isAwaitingAckClarification)

        coordinator.beginAckClarification(candidates: coordinator.medicationAckCandidates())
        XCTAssertTrue(coordinator.isAwaitingAckClarification)
        XCTAssertTrue(coordinator.isAwaitingConfirmation,
                      "the open walk must fold into isAwaitingConfirmation")

        coordinator.endAckClarification(reason: .bargedIn)
        XCTAssertFalse(coordinator.isAwaitingAckClarification)
        XCTAssertEqual(coordinator.isAwaitingConfirmation, before,
                       "ending the walk must flip the fold back")

        // A live challenge outranks the walk (design-l2 C4: mutually
        // exclusive; the challenge never loses its window to a walk).
        coordinator.pendingConfirmationEntryId = UUID()
        defer { coordinator.pendingConfirmationEntryId = nil }
        XCTAssertTrue(coordinator.isAwaitingConfirmation)
        coordinator.beginAckClarification(candidates: coordinator.medicationAckCandidates())
        XCTAssertNil(coordinator.pendingAckClarification,
                     "a live challenge must refuse the walk's begin")

        // Source pin: the fold really carries the walk.
        let fold = region("var isAwaitingConfirmation: Bool {", to: "func oldestPendingReminderEntryId")
        XCTAssertTrue(collapsed(fold).contains("|| pendingAckClarification != nil"),
                      "the isAwaitingConfirmation formula must OR-in the walk")
    }

    /// C4 (design-l2 §247): an answer NAMING any walk candidate resolves
    /// to it at any cursor; several names in one breath refuse to guess
    /// and the walk asks its current question again.
    @MainActor
    func testNameContainmentResolvesAtAnyCursor() throws {
        let coordinator = makeCoordinator()
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return }
        let previous = scheduler.medicationEntries()
        defer { scheduler.loadSchedule(entries: previous) }

        let entries = Self.threeCandidateFixture()
        scheduler.loadSchedule(entries: entries)
        let candidates = coordinator.medicationAckCandidates()

        coordinator.beginAckClarification(candidates: candidates)
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "छैन", isYes: false, isNo: true),
                       .advanced)
        // The cursor asks candidate 1; the elder names candidate 2 — the
        // name wins, at any cursor.
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "Paracetamol",
                                                            isYes: false, isNo: false),
                       .resolved(entryId: entries[2].id))

        // Two candidates named in one breath: refuse to guess, re-ask.
        coordinator.beginAckClarification(candidates: candidates)
        XCTAssertEqual(coordinator.ackClarificationResponse(raw: "Amlodipine or Metformin",
                                                            isYes: false, isNo: false),
                       .unanswered)
        XCTAssertNotNil(coordinator.pendingAckClarification,
                        "the walk stays open on a refused guess")
        XCTAssertEqual(coordinator.pendingAckClarification?.cursor, 0)
    }

    // MARK: - Fixtures

    /// Two pending reminders, fixed order `[Amlodipine, Metformin]`.
    private static func pairFixture() -> [MedicationEntry] {
        let base = Date()
        return [
            medicationEntry(name: "Amlodipine", at: base.addingTimeInterval(3600)),
            medicationEntry(name: "Metformin", at: base.addingTimeInterval(7200))
        ]
    }

    /// Three pending reminders, fixed order
    /// `[Amlodipine, Metformin, Paracetamol]`.
    private static func threeCandidateFixture() -> [MedicationEntry] {
        let base = Date()
        return [
            medicationEntry(name: "Amlodipine", at: base.addingTimeInterval(3600)),
            medicationEntry(name: "Metformin", at: base.addingTimeInterval(7200)),
            medicationEntry(name: "Paracetamol", at: base.addingTimeInterval(10800))
        ]
    }

    private struct FixedOrderFixture {
        let entries: [MedicationEntry]   // deliberately scrambled load order
        let amlodipine: UUID
        let paracetamol: UUID
        let metformin: UUID
        let vitaminD: UUID
        let zinc: UUID
        let calciumOne: UUID
        let calciumTwo: UUID
    }

    /// The ordering discriminators, each in a state where load order,
    /// name-sorted order and the expected fixed order all differ:
    /// - distinct times in non-alphabetical order (Amlodipine +1h,
    ///   Paracetamol +2h, Metformin +3h),
    /// - a same-time name tiebreak (Vitamin D vs Zinc, +4h),
    /// - a same-time/same-name id tiebreak (the two Calciums, +5h).
    private static func fixedOrderFixture() throws -> FixedOrderFixture {
        let base = Date()
        func at(_ offsetHours: Double) -> Date { base.addingTimeInterval(offsetHours * 3600) }
        let amlodipine = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let paracetamol = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))
        let metformin = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A3"))
        let vitaminD = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A4"))
        let zinc = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A5"))
        let calciumOne = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let calciumTwo = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let entries = [
            medicationEntry(id: zinc, name: "Zinc", at: at(4)),
            medicationEntry(id: metformin, name: "Metformin", at: at(3)),
            medicationEntry(id: calciumTwo, name: "Calcium", at: at(5)),
            medicationEntry(id: paracetamol, name: "Paracetamol", at: at(2)),
            medicationEntry(id: calciumOne, name: "Calcium", at: at(5)),
            medicationEntry(id: amlodipine, name: "Amlodipine", at: at(1)),
            medicationEntry(id: vitaminD, name: "Vitamin D", at: at(4))
        ]
        return FixedOrderFixture(entries: entries, amlodipine: amlodipine,
                                 paracetamol: paracetamol, metformin: metformin,
                                 vitaminD: vitaminD, zinc: zinc,
                                 calciumOne: calciumOne, calciumTwo: calciumTwo)
    }

    /// A legacy-shape daily entry at `date`'s clock time (hour/minute —
    /// the scheduler resolves the next occurrence of that time).
    private static func medicationEntry(id: UUID = UUID(), name: String,
                                        at date: Date) -> MedicationEntry {
        MedicationEntry(
            id: id,
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "",
            scheduleTimes: [Calendar.current.dateComponents([.hour, .minute], from: date)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(_ config: AckClarificationConfig = AckClarificationConfig()) -> AppCoordinator {
        // Seed BEFORE construction: the init restores through the real
        // `AppLanguage.persisted()` seam (the CallConfirmationWordingTests
        // recipe), so the walk's questions resolve English deterministically.
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        return AppCoordinator(profileStorage: InMemoryProfilePayloadStorage(),
                              ackClarificationConfig: config)
    }

    /// The coordinator's current walk question through the walk's own
    /// question home (nil when no walk is open).
    @MainActor
    private func ackQuestion(_ coordinator: AppCoordinator) -> String? {
        coordinator.pendingAckClarification.map { coordinator.ackClarificationQuestion(for: $0) }
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The walk's code region (comment-stripped): IF-7 through the end of
    /// the walk ops, up to the next shipped function.
    private func walkRegion() -> String {
        region("func medicationAckCandidates()", to: "func addVoiceReminder(")
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

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static let languageKey = "appLanguage"
    private var languageBackup: Any?

    override func setUp() {
        super.setUp()
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
    }

    override func tearDown() {
        if let languageBackup {
            UserDefaults.standard.set(languageBackup, forKey: Self.languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.languageKey)
        }
        super.tearDown()
    }

    /// One stored property of `subject`, by label. The `as? T` cast
    /// unwraps one level of `Optional` (the house `stored` helper, the
    /// `DialogueCoordinatorWiringTests` convention). A missing label or a
    /// mismatched type is an explicit failure, never a silent nil.
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

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship — `ColdStartRoutingTests`,
    // `CallConfirmationWordingTests`: the coordinator's payload store only;
    // the seam under test is the real scheduler + the real walk.)

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
}
