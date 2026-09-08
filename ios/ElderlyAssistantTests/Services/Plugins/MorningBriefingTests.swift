import XCTest
@testable import ElderlyAssistant

/// Voice-OS shell v1 (docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md
/// §4.4/§5/§7) — MorningBriefing unit tests:
///  - wake-window trigger logic (inside / before / after / once-per-day),
///  - deterministic composition in en + ne with fakes for every data
///    source (the fake APIs mirror the REAL service read APIs the
///    production conformances bridge: `RoutineScheduler.todaysOccurrences()`
///    + `entry(for:)`, `MedicationScheduler.pendingReminders` +
///    `medicationEntries()`, `ExternalCalendarService.todaysSpokenLines(locale:)`),
///  - honest empty lines per source and the honest weather-unavailable line,
///  - fire() idempotency per calendar day,
///  - fire() persistence (briefing persistence task, 2026-09-08): the
///    composed text lands in the injected `MorningBriefingStore` for its
///    calendar day; a same-day no-op never clobbers; the next-day fire
///    replaces the slot; a storage failure still speaks and emits a
///    sanitised `briefing_persist_failed` event,
///  - determinism: identical inputs → identical announcement text.
///
/// English expectations pin the plan's en catalog values verbatim
/// ("Good morning", "Today is %@", …). Nepali expectations assert the
/// composed Bikram Sambat argument and verbatim user data — the pinned
/// ne key VALUES are Agent D's to add.
final class MorningBriefingTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// 2026-09-06 is a Sunday (आइतबार) = भदौ २१, २०८३ per the BikramSambat
    /// anchor table (BikramSambatTests / TopicPreAnswerTests pin the same
    /// pair). All instants are built in the host calendar/time zone and
    /// read back in the same zone, so the BS day count is stable (same
    /// constraint TopicPreAnswerTests documents for its date reply).
    private func day(_ day: Int, _ hour: Int, _ minute: Int = 0,
                     month: Int = 9, year: Int = 2026) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Fixture builders

    /// A pending morning-walk entry with a verbatim (locale-independent)
    /// title, plus its pending occurrences at 07:00 and 09:00. The fixture
    /// ALSO carries the states that must NOT appear in a briefing:
    /// delivered/expired occurrences today and a pending occurrence
    /// tomorrow.
    private struct RoutineFixture {
        let entry: RoutineEntry
        let occurrence7: RoutineOccurrence
        let occurrence9: RoutineOccurrence
        let deliveredToday: RoutineOccurrence
        let expiredToday: RoutineOccurrence
        let pendingTomorrow: RoutineOccurrence
    }

    private func makeRoutineFixture() -> RoutineFixture {
        let entry = RoutineEntry(
            id: UUID(), category: .walk, titleOverride: "Morning walk",
            scheduleTimes: [], frequency: .daily, isEnabled: true
        )
        func occurrence(_ id: UUID, _ at: Date, _ state: RoutineOccurrence.State) -> RoutineOccurrence {
            RoutineOccurrence(id: id, entryId: entry.id, scheduledAt: at, state: state)
        }
        return RoutineFixture(
            entry: entry,
            occurrence7: occurrence(UUID(), day(6, 7, 0), .pending),
            occurrence9: occurrence(UUID(), day(6, 9, 0), .pending),
            deliveredToday: occurrence(UUID(), day(6, 6, 30), .delivered),
            expiredToday: occurrence(UUID(), day(6, 6, 0), .expired),
            pendingTomorrow: occurrence(UUID(), day(7, 7, 0), .pending)
        )
    }

    /// A pending Amlodipine 5 mg reminder at 08:00 today, plus the states
    /// that must NOT appear: an already-completed dose today, a fired
    /// (unacknowledged, escalation-owned) dose today, and a pending dose
    /// tomorrow.
    private struct MedicationFixture {
        let entry: MedicationEntry
        let pending8: ScheduledReminder
        let completedToday: ScheduledReminder
        let firedToday: ScheduledReminder
        let pendingTomorrow: ScheduledReminder
    }

    private func makeMedicationFixture() -> MedicationFixture {
        let entry = MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Amlodipine",
            doseDescription: "5 mg",
            scheduleTimes: [],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil
        )
        func reminder(_ at: Date, _ state: ScheduledReminder.ReminderState) -> ScheduledReminder {
            ScheduledReminder(
                id: UUID(), medicationEntryId: entry.id, scheduledAt: at,
                refireCount: 0,
                escalationDeadline: at.addingTimeInterval(3600),
                state: state, lastFiredAt: nil, acknowledgedAt: nil
            )
        }
        return MedicationFixture(
            entry: entry,
            pending8: reminder(day(6, 8, 0), .pending),
            completedToday: reminder(day(6, 6, 30), .completed),
            firedToday: reminder(day(6, 6, 45), .fired),
            pendingTomorrow: reminder(day(7, 8, 0), .pending)
        )
    }

    // MARK: - Test doubles (fakes mirror the real service read APIs)

    private enum BriefingFakes {

        final class Queue: SpeakQueueProtocol {
            var enqueued: [Announcement] = []
            var isSpeaking: Bool = false
            var currentCard: AnnouncementCard?

            func enqueue(_ announcement: Announcement) {
                enqueued.append(announcement)
            }
        }

        final class Bus: ObservabilityBus {
            var emitted: [ObservabilityEvent] = []
            func emit(_ event: ObservabilityEvent) {
                emitted.append(event)
            }
        }

        final class RoutineSource: BriefingRoutineSource {
            var occurrences: [RoutineOccurrence] = []
            var entries: [UUID: RoutineEntry] = [:]
            func todaysOccurrences() -> [RoutineOccurrence] { occurrences }
            func entry(for id: UUID) -> RoutineEntry? { entries[id] }
        }

        final class MedicationSource: BriefingMedicationSource {
            var reminders: [ScheduledReminder] = []
            var entries: [MedicationEntry] = []
            var pendingReminders: [ScheduledReminder] { reminders }
            func medicationEntries() -> [MedicationEntry] { entries }
        }

        final class CalendarSource: BriefingCalendarSource {
            var lines: [String] = []
            func todaysSpokenLines(locale: Locale) -> [String] { lines }
        }

        final class WeatherSource: BriefingWeatherSource {
            var summary: String?
            func todaySummary(locale: Locale) -> String? { summary }
        }

        /// Storage that always fails to write — pins the best-effort
        /// contract: a briefing still speaks when persistence misses.
        final class FailingEncryptedStorage: EncryptedLocalStorage {
            func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
                .failure(.encryptedWriteFailed)
            }
            func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
                .failure(.encryptedReadFailed)
            }
            func delete(key: String) -> Result<Void, StorageError> {
                .failure(.encryptedWriteFailed)
            }
        }
    }

    private struct Harness {
        let queue = BriefingFakes.Queue()
        let bus = BriefingFakes.Bus()
        let routines = BriefingFakes.RoutineSource()
        let medications = BriefingFakes.MedicationSource()
        let calendar = BriefingFakes.CalendarSource()
        let weather = BriefingFakes.WeatherSource()

        func briefing(
            locale: Locale = Locale(identifier: "en-US"),
            weatherAvailable: Bool = true,
            briefingStore: MorningBriefingStore? = nil,
            now: @escaping () -> Date = Date.init
        ) -> MorningBriefing {
            MorningBriefing(
                queue: queue,
                observability: bus,
                routineSource: routines,
                medicationSource: medications,
                calendarSource: calendar,
                weatherSource: weatherAvailable ? weather : nil,
                briefingStore: briefingStore,
                locale: locale,
                now: now
            )
        }
    }

    /// Fixture wiring used by the composition tests: two pending walks,
    /// one pending dose, two calendar lines, live fake weather.
    private func harnessWithEverything() -> Harness {
        let harness = Harness()
        let routine = makeRoutineFixture()
        harness.routines.entries[routine.entry.id] = routine.entry
        harness.routines.occurrences = [
            routine.occurrence7, routine.occurrence9,
            routine.deliveredToday, routine.expiredToday, routine.pendingTomorrow
        ]
        let medication = makeMedicationFixture()
        harness.medications.entries = [medication.entry]
        harness.medications.reminders = [
            medication.pending8, medication.completedToday,
            medication.firedToday, medication.pendingTomorrow
        ]
        harness.calendar.lines = ["Doctor — 10:30 AM", "Lunch with Maya — 12:00 PM"]
        harness.weather.summary = "Sunny and 22 degrees"
        return harness
    }

    // MARK: - SpeechSource surface

    func testIsApplicableToEnAndNeOnly() {
        let briefing = Harness().briefing()
        XCTAssertTrue(briefing.isApplicable(locale: en))
        XCTAssertTrue(briefing.isApplicable(locale: Locale(identifier: "en-GB")))
        XCTAssertTrue(briefing.isApplicable(locale: ne))
        XCTAssertFalse(briefing.isApplicable(locale: Locale(identifier: "hi-IN")))
        XCTAssertFalse(briefing.isApplicable(locale: Locale(identifier: "fr")))
    }

    func testSourceIDDefaultPriorityAndNextAnnouncement() async {
        let briefing = Harness().briefing()
        XCTAssertEqual(briefing.sourceID, "morning_briefing")
        XCTAssertEqual(briefing.defaultPriority, .briefing)
        // Push source: fire() enqueues; the pull surface never re-returns
        // an announcement (double-speak guard).
        let pulled = await briefing.nextAnnouncement()
        XCTAssertNil(pulled)
    }

    // MARK: - Wake window

    func testWakeWindowBoundaries() {
        let briefing = Harness().briefing()
        // Inside the default 05:00–10:00 window.
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 5, 0), calendar: .current))
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 7, 0), calendar: .current))
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 9, 59), calendar: .current))
        // Start hour is inclusive, end hour exclusive.
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 4, 59), calendar: .current))
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 10, 0), calendar: .current))
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 11, 0), calendar: .current))
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 23, 0), calendar: .current))
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 0, 0), calendar: .current))
    }

    func testCustomWakeWindowBoundsAreHonored() {
        let briefing = Harness().briefing()
        briefing.wakeWindowStart = 6
        briefing.wakeWindowEnd = 9
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 5, 59), calendar: .current))
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 6, 0), calendar: .current))
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 8, 59), calendar: .current))
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 9, 0), calendar: .current))
    }

    func testFiresOncePerWakeWindowPerCalendarDay() async {
        var now = day(6, 7, 0)
        let harness = Harness()
        let briefing = harness.briefing(now: { now })

        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(6, 7, 0), calendar: .current))
        await briefing.fire()

        // Second activation later the same day, still inside the window.
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 9, 0), calendar: .current))

        // A NEW calendar day inside the window fires again.
        XCTAssertTrue(briefing.shouldFireOnActivation(now: day(7, 7, 0), calendar: .current))
        now = day(7, 7, 0)
        await briefing.fire()
        XCTAssertEqual(harness.queue.enqueued.count, 2)
    }

    // MARK: - fire() composition

    func testFireEnqueuesSingleBriefingAnnouncementWithFullEnglishText() async throws {
        let harness = harnessWithEverything()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })

        await briefing.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 1)
        let announcement = try XCTUnwrap(harness.queue.enqueued.first)
        XCTAssertEqual(announcement.priority, .briefing)
        XCTAssertEqual(announcement.sourceID, "morning_briefing")
        XCTAssertEqual(announcement.text,
                       "Good morning, Today is Sunday, September 6, 2026\n" +
                       "Your routines today: Morning walk — 7 am, Morning walk — 9 am\n" +
                       "Your medications today: Amlodipine — 5 mg — 8 am\n" +
                       "Your events today: Doctor — 10:30 AM, Lunch with Maya — 12:00 PM\n" +
                       "The weather today: Sunny and 22 degrees")
        // Outcome card mirrors the spoken text; body is never log metadata.
        let card = try XCTUnwrap(announcement.card)
        XCTAssertEqual(card.title, "Good morning")
        XCTAssertEqual(card.body, announcement.text)
        XCTAssertEqual(card.symbolName, "sunrise.fill")
    }

    func testFireDoesNotFabricateStaleOrOtherDayItems() async {
        // The full-text pin above already proves delivered/expired/
        // completed/fired/yesterday-tomorrow items stay out; this test
        // documents the filtering expectation explicitly.
        let harness = harnessWithEverything()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })
        await briefing.fire()
        let text = harness.queue.enqueued.first!.text
        XCTAssertTrue(text.contains("Morning walk — 7 am, Morning walk — 9 am"))
        XCTAssertFalse(text.contains("6:30 am"))
        XCTAssertFalse(text.contains("6:45 am"))
        XCTAssertFalse(text.contains("6:00 am"))
        XCTAssertFalse(text.contains("Sunday, September 7"))
    }

    func testCompositionNepaliLocaleUsesBikramSambatDate() async throws {
        let harness = harnessWithEverything()
        let briefing = harness.briefing(locale: ne, now: { self.day(6, 7, 0) })

        await briefing.fire()

        let announcement = try XCTUnwrap(harness.queue.enqueued.first)
        let lines = announcement.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5, "greeting+date, routines, medications, calendar, weather")
        // The greeting line carries the BS argument (weekday + BS date).
        XCTAssertTrue(lines[0].contains("आइतबार"), "unexpected: \(lines[0])")
        XCTAssertTrue(lines[0].contains("भदौ २१, २०८३"), "unexpected: \(lines[0])")
        // Verbatim user data passes through untranslated.
        XCTAssertTrue(lines[1].contains("Morning walk"))
        XCTAssertTrue(lines[2].contains("Amlodipine"))
        XCTAssertTrue(lines[4].contains("Sunny and 22 degrees"))
    }

    /// Spoken-text audit (2026-09-08): every briefing line that embeds a
    /// clock goes through `SpokenTime`, so the Nepali composition must
    /// never carry an ASCII clock token — and single-digit minutes speak
    /// UNPADDED ("बजेर ५ मिनेट", never "बजेर ०५ मिनेट" or "7:05"). The
    /// calendar line is out of scope here: it renders the source's
    /// verbatim spoken lines verbatim.
    func testNepaliCompositionMinutesUseUnpaddedSpokenForm() async throws {
        let harness = Harness()
        let routine = makeRoutineFixture()
        // Override the 07:00 occurrence to 07:05 — exercises a
        // single-digit Devanagari minute end-to-end through fire().
        let atSevenFive = RoutineOccurrence(
            id: UUID(), entryId: routine.entry.id,
            scheduledAt: day(6, 7, 5), state: .pending
        )
        harness.routines.entries[routine.entry.id] = routine.entry
        harness.routines.occurrences = [atSevenFive, routine.occurrence9]
        let medication = makeMedicationFixture()
        harness.medications.entries = [medication.entry]
        harness.medications.reminders = [medication.pending8]
        let briefing = harness.briefing(locale: ne, now: { self.day(6, 7, 0) })

        await briefing.fire()

        let lines = try XCTUnwrap(harness.queue.enqueued.first).text
            .components(separatedBy: "\n")
        XCTAssertTrue(lines[1].contains("बिहान ७ बजेर ५ मिनेट"),
                      "routine line must speak unpadded minutes: \(lines[1])")
        XCTAssertTrue(lines[2].contains("बिहान ८ बजे"),
                      "medication line must speak the on-the-hour form: \(lines[2])")
        // Time segments only — titles/doses may legitimately carry
        // ASCII ("Morning walk", "5 mg") and the catalog lead-in ends
        // with a colon; the SPOKEN time is what must stay clean.
        let times = [lines[1], lines[2]].flatMap { line in
            line.split(separator: ",").map { item in
                String(item.split(separator: "—").last ?? "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        for time in times {
            XCTAssertNil(time.rangeOfCharacter(from: asciiDigits),
                         "ASCII digits must never reach the spoken time: \(time)")
            XCTAssertFalse(time.contains(":"),
                           "clock colons must never reach the spoken time: \(time)")
        }
    }

    func testAllScheduleSourcesEmptyProducesNothingLine() async {
        let harness = Harness()
        harness.weather.summary = nil
        let briefing = harness.briefing(weatherAvailable: false, now: { self.day(6, 7, 0) })

        await briefing.fire()

        let text = harness.queue.enqueued.first!.text
        XCTAssertEqual(text,
                       "Good morning, Today is Sunday, September 6, 2026\n" +
                       "You have nothing scheduled today\n" +
                       "Weather is not available in this mode")
    }

    func testEmptySourcesEachContributeAnHonestEmptyLineWhenOthersHaveItems() async {
        let harness = Harness()
        let routine = makeRoutineFixture()
        harness.routines.entries[routine.entry.id] = routine.entry
        harness.routines.occurrences = [routine.occurrence7]   // routines non-empty
        harness.calendar.lines = ["Doctor — 10:30 AM"]          // calendar non-empty
        harness.weather.summary = "Sunny and 22 degrees"
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })

        await briefing.fire()

        let lines = harness.queue.enqueued.first!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[2], L10n.str("briefing.empty.medications", locale: en))
        XCTAssertFalse(lines[2].isEmpty)
        // The empty line must NOT claim a fabricated medication.
        XCTAssertFalse(lines[3].contains("Amlodipine"))
    }

    func testWeatherLineUsesProviderSummaryWhenAvailable() async {
        let harness = Harness()
        harness.weather.summary = "Rain expected later"
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })
        await briefing.fire()
        let lines = harness.queue.enqueued.first!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "The weather today: Rain expected later")
    }

    func testUnavailableWeatherProducesHonestLineWhenProviderMissing() async {
        let harness = Harness()
        let briefing = harness.briefing(weatherAvailable: false, now: { self.day(6, 7, 0) })
        await briefing.fire()
        let lines = harness.queue.enqueued.first!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "Weather is not available in this mode")
    }

    func testUnavailableWeatherProducesHonestLineWhenProviderReturnsNil() async {
        let harness = Harness()
        harness.weather.summary = nil
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })
        await briefing.fire()
        let lines = harness.queue.enqueued.first!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "Weather is not available in this mode")
    }

    func testSpokenTriggerWorksOutsideWakeWindow() async {
        // fire() is the spoken-command path — it must speak even at 11:00
        // (only the ACTIVATION trigger is window-gated).
        let harness = Harness()
        harness.weather.summary = "Sunny"
        let briefing = harness.briefing(now: { self.day(6, 11, 0) })
        XCTAssertFalse(briefing.shouldFireOnActivation(now: day(6, 11, 0), calendar: .current))
        await briefing.fire()
        XCTAssertEqual(harness.queue.enqueued.count, 1)
    }

    // MARK: - Idempotency + determinism

    func testFireIsIdempotentWithinACalendarDay() async throws {
        let harness = Harness()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })

        await briefing.fire()
        await briefing.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 1, "second fire same day must be a no-op")
        XCTAssertEqual(harness.bus.emitted.map(\.eventType), ["briefing_fired", "briefing_fire_skipped"])
        let skip = try XCTUnwrap(harness.bus.emitted.last)
        XCTAssertEqual(skip.metadata["state"], "already_fired_today")
        XCTAssertEqual(skip.component, "morning_briefing")
    }

    func testFireSpeaksAgainOnTheNextCalendarDay() async {
        var now = day(6, 7, 0)
        let harness = Harness()
        let briefing = harness.briefing(now: { now })

        await briefing.fire()
        now = day(7, 7, 0)
        await briefing.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 2)
    }

    func testCompositionIsDeterministicForIdenticalInputs() async {
        let harnessA = harnessWithEverything()
        let briefingA = harnessA.briefing(now: { self.day(6, 7, 0) })
        await briefingA.fire()

        let harnessB = harnessWithEverything()
        let briefingB = harnessB.briefing(now: { self.day(6, 7, 0) })
        await briefingB.fire()

        XCTAssertEqual(harnessA.queue.enqueued.first!.text,
                       harnessB.queue.enqueued.first!.text)
    }

    func testComposeLinesIsPureAndStable() {
        let harness = harnessWithEverything()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })

        let first = briefing.composeLines(locale: en, now: day(6, 7, 0))
        let second = briefing.composeLines(locale: en, now: day(6, 7, 30))
        XCTAssertEqual(first, second, "same day, same sources → identical lines")
        XCTAssertEqual(first, briefing.composeLines(locale: en, now: day(6, 7, 0)))
    }

    func testFireTextMatchesComposeLines() async {
        let harness = harnessWithEverything()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })
        await briefing.fire()
        let expected = briefing.composeLines(locale: en, now: day(6, 7, 0)).joined(separator: "\n")
        XCTAssertEqual(harness.queue.enqueued.first!.text, expected)
    }

    // MARK: - Persistence (briefing persistence task, 2026-09-08)

    func testFirePersistsComposedTextForItsDay() async throws {
        let harness = harnessWithEverything()
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let briefing = harness.briefing(briefingStore: store,
                                        now: { self.day(6, 7, 0) })

        await briefing.fire()

        let stored = try XCTUnwrap(store.load())
        // The stored text IS the spoken text — a later replay re-speaks
        // exactly what was said in the morning, never a recomposition.
        XCTAssertEqual(stored.text, harness.queue.enqueued.first?.text)
        XCTAssertFalse(stored.text.isEmpty)
        // Keyed by the calendar day's start + the composition locale.
        XCTAssertEqual(stored.dayStart,
                       Calendar.current.startOfDay(for: day(6, 7, 0)))
        XCTAssertEqual(stored.localeIdentifier, "en-US")
        // A glanceable one-liner exists for the Home widget capsule.
        XCTAssertFalse(stored.previewLine.isEmpty)
    }

    func testSameDaySecondFireIsNoOpAndNeverClobbersStoredText() async throws {
        let harness = harnessWithEverything()
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let briefing = harness.briefing(briefingStore: store,
                                        now: { self.day(6, 7, 0) })

        await briefing.fire()
        let first = try XCTUnwrap(store.load())

        // Same-day second trigger with a COMPLETELY different schedule:
        // composition would differ, but the once-per-day budget makes the
        // trigger a no-op — the stored briefing must survive untouched
        // (same-day no-op never clobbers).
        harness.routines.occurrences = []
        harness.medications.reminders = []
        harness.medications.entries = []
        harness.calendar.lines = []
        harness.weather.summary = nil
        await briefing.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 1,
                       "second fire same day must be a no-op")
        XCTAssertEqual(try XCTUnwrap(store.load()), first)
        XCTAssertTrue(first.text.contains("Amlodipine"))
        XCTAssertEqual(harness.bus.emitted.last?.eventType, "briefing_fire_skipped")
    }

    func testNextDayFireReplacesStoredSlot() async throws {
        var now = day(6, 7, 0)
        let harness = harnessWithEverything()
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let briefing = harness.briefing(briefingStore: store, now: { now })

        await briefing.fire()
        XCTAssertEqual(store.load()?.dayStart,
                       Calendar.current.startOfDay(for: day(6, 7, 0)))

        // A fresh day with an empty schedule: the new composition replaces
        // the old slot — single-slot persistence, no history (the next-day
        // write IS the pruning).
        now = day(7, 7, 0)
        harness.routines.occurrences = []
        harness.medications.reminders = []
        harness.medications.entries = []
        harness.calendar.lines = []
        harness.weather.summary = nil
        await briefing.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 2)
        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(stored.dayStart,
                       Calendar.current.startOfDay(for: day(7, 7, 0)))
        XCTAssertEqual(stored.text, harness.queue.enqueued.last?.text)
        XCTAssertFalse(stored.text.contains("Amlodipine"))
        XCTAssertTrue(stored.text.contains("You have nothing scheduled today"))
    }

    func testNepaliCompositionPersistsNepaliLocaleAndText() async throws {
        let harness = harnessWithEverything()
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let briefing = harness.briefing(locale: ne, briefingStore: store,
                                        now: { self.day(6, 7, 0) })

        await briefing.fire()

        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(stored.localeIdentifier, "ne-NP")
        XCTAssertEqual(stored.text, harness.queue.enqueued.first?.text)
        XCTAssertTrue(stored.text.contains("बिहान ७ बजे"),
                      "Nepali spoken form persisted: \(stored.text)")
    }

    func testPersistFailureStillSpeaksAndEmitsSanitisedEvent() async throws {
        let harness = Harness()
        harness.weather.summary = "Sunny"
        let store = MorningBriefingStore(storage: BriefingFakes.FailingEncryptedStorage())
        let briefing = harness.briefing(briefingStore: store,
                                        now: { self.day(6, 7, 0) })

        await briefing.fire()

        // Persistence is best-effort — a storage failure never silences
        // the briefing; a PII-free event records the miss. fire() emits
        // briefing_persist_failed from inside persist() BEFORE the
        // trailing briefing_fired, so the failure event is never `.last` —
        // select it by type, not position.
        XCTAssertEqual(harness.queue.enqueued.count, 1)
        let event = try XCTUnwrap(
            harness.bus.emitted.first { $0.eventType == "briefing_persist_failed" }
        )
        XCTAssertEqual(event.component, "morning_briefing")
        XCTAssertEqual(event.metadata, ["state": "storage_error"])
        for key in event.metadata.keys {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key))
        }
        XCTAssertTrue(harness.bus.emitted.contains { $0.eventType == "briefing_fired" },
                      "the fire itself still reports success alongside the persist miss")
    }

    // MARK: - Date argument

    func testDateArgEnglishPinsFullGregorianDate() {
        XCTAssertEqual(MorningBriefing.dateArg(for: day(6, 10, 0), locale: en, calendar: .current),
                       "Sunday, September 6, 2026")
    }

    func testDateArgNepaliPinsWeekdayAndBikramSambatDate() {
        XCTAssertEqual(MorningBriefing.dateArg(for: day(6, 10, 0), locale: ne, calendar: .current),
                       "आइतबार, भदौ २१, २०८३")
    }

    func testObservabilityEventsNeverCarryUserContent() async {
        let harness = harnessWithEverything()
        let briefing = harness.briefing(now: { self.day(6, 7, 0) })
        await briefing.fire()
        await briefing.fire()

        XCTAssertFalse(harness.bus.emitted.isEmpty)
        for event in harness.bus.emitted {
            XCTAssertEqual(event.component, "morning_briefing")
            XCTAssertFalse(event.eventType.contains("Amlodipine"))
            // Every metadata key is on the LogSanitiser allowlist — names,
            // titles and transcript content can never reach a log sink.
            for key in event.metadata.keys {
                XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                              "metadata key \(key) is not allowlisted")
            }
        }
    }
}

/// In-memory `EncryptedLocalStorage` for the persistence tests — the real
/// implementation is Keychain-backed and untestable without a device
/// context (same file-local fake pattern as the storage-store test files).
private final class InMemoryEncryptedStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}
