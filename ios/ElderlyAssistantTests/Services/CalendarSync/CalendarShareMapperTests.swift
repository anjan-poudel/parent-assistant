import XCTest
@testable import ElderlyAssistant

/// The invite policy, the twin drafts and the content fingerprint.
///
/// `CalendarShareMapper` is pure, so every rule below runs with no
/// session, no network and no settings store: a pinned UTC calendar, a
/// pinned "now" and a throwaway `CaregiverNotifySettings` suite are the
/// only inputs. That is the point of the mapper's shape — "who sees this
/// event" is decided by a value, not by a sign-in flow.
final class CalendarShareMapperTests: XCTestCase {

    // MARK: - Pinned clock

    /// The mapper's date math is calendar-INJECTED, so the suite never
    /// reads the machine's clock or timezone.
    private let utc = TimeZone(identifier: "UTC")!

    /// The zone the DRAFTS carry, which is a separate input from the one
    /// the anchoring math uses (`timeZone:` is copied into the draft
    /// verbatim — it is what Google is told the wall-clock time means).
    ///
    /// A real IANA zone rather than `utc`, because Foundation normalises
    /// `TimeZone(identifier: "UTC").identifier` to "GMT" and an assertion
    /// spelling that would read as a bug. Kathmandu is also the zone this
    /// app is actually built for.
    private let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Pinned "now": Wednesday 2026-09-16 09:00 UTC.
    ///
    /// A Wednesday matters: 08:00 is already past (so a daily slot rolls
    /// to the next day) while 20:00 is still ahead (so it stays today),
    /// and the weekly cases below can roll to the next Monday.
    private var now: Date { utcDate(2026, 9, 16, 9, 0) }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                         _ hour: Int, _ minute: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day,
                                              hour: hour, minute: minute))!
    }

    private let testLocale = Locale(identifier: "en")

    // MARK: - Builders

    /// All three toggles OFF unless the test asks otherwise — the shipped
    /// default the invite policy has to be safe under.
    private func settings(medication: Bool = false, routine: Bool = false,
                          calendar: Bool = false) -> CaregiverNotifySettings {
        CaregiverNotifySettings.isolated(medication: medication, routine: routine,
                                         calendar: calendar)
    }

    private func contact(name: String = "आमा", email: String?,
                         emergency: Bool = false) -> FamilyContact {
        FamilyContact(name: name, phone: "9812345678", relationship: "आमा",
                      email: email, isEmergencyContact: emergency)
    }

    private func medication(hours: [Int], minutes: [Int] = [],
                            name: String = "Amlodipine") -> MedicationEntry {
        let times = hours.enumerated().map { index, hour in
            DateComponents(hour: hour,
                           minute: minutes.indices.contains(index) ? minutes[index] : 0)
        }
        return MedicationEntry(
            id: UUID(), userProfileId: UUID(), medicationName: name,
            doseDescription: "One tablet", scheduleTimes: times,
            frequency: .daily, ackWindowMinutes: 5, maxRefireCount: 5,
            escalationWindowMinutes: 60, doubleDoseWindowHours: 4,
            photoVerificationEnabled: false, confirmationDescription: nil)
    }

    private func routine(hours: [Int], frequency: RoutineFrequency = .daily,
                         weekdays: [Int] = [], enabled: Bool = true,
                         title: String = "Walk",
                         category: RoutineCategory = .exercise) -> RoutineEntry {
        RoutineEntry(id: UUID(), category: category, titleOverride: title,
                     scheduleTimes: hours.map { DateComponents(hour: $0, minute: 0) },
                     frequency: frequency, weekdays: weekdays, isEnabled: enabled)
    }

    /// The title the mapper composes for a routine twin — the same
    /// "<name> (<category>)" label the native mirror writes, so the
    /// family reads one consistent string across both calendars.
    private func routineTitle(for entry: RoutineEntry) -> String {
        let label = L10n.str(entry.category.displayNameKey, locale: testLocale)
        return "\(entry.displayTitle(locale: testLocale)) (\(label))"
    }

    private func draft(title: String = "Walk",
                       start: Date,
                       duration: Int = CalendarShareMapper.defaultDurationMinutes,
                       zone: String = "UTC",
                       recurrence: EventRecurrence? = nil,
                       attendees: [String] = ["maa@example.com"],
                       kind: EventNotifyKind = .routineReminder,
                       location: String? = nil) -> CalendarTwinDraft {
        CalendarTwinDraft(title: title, startDate: start, durationMinutes: duration,
                          timeZoneIdentifier: zone, recurrence: recurrence,
                          attendeeEmails: attendees, kind: kind, location: location)
    }

    // MARK: - Key grammar

    /// The stale-twin sweep's join key: the local event id written inside
    /// a ONE-OFF key. `parts` throws it away (it is opaque, not a uuid),
    /// so this is the only way back to it — and the sweep cannot ask
    /// "is the local event still there" without it.
    func testOneOffIdentifierReturnsTheNativeEventIDAndNothingElse() {
        XCTAssertEqual(CalendarShareKey.oneOffIdentifier("calendarEvent:evt-42"), "evt-42")
        // An EventKit id is opaque and may itself be uuid-shaped; the
        // three-part slot form still must not be read as a one-off.
        XCTAssertNil(CalendarShareKey.oneOffIdentifier("calendarEvent:evt-42:0"),
                     "a slot key's trailing two components are not an event id")
        XCTAssertNil(CalendarShareKey.oneOffIdentifier("evt-42"),
                     "a bare id carries no kind and was not written by this grammar")
        XCTAssertNil(CalendarShareKey.oneOffIdentifier("notAKind:evt-42"))
        XCTAssertNil(CalendarShareKey.oneOffIdentifier("calendarEvent:"))
    }

    // MARK: - Invite policy: emergency contacts (rule 2)

    /// An emergency contact is the family's safety net, so they are
    /// invited to EVERY kind — the toggles govern people who opted in,
    /// not the person the elder calls first.
    func testEmergencyContactsAreInvitedForEveryKindEvenWithEveryToggleOff() {
        let all = settings()
        XCTAssertFalse(all.medicationReminders)
        XCTAssertFalse(all.routineReminders)
        XCTAssertFalse(all.calendarEvents)
        let mother = contact(email: "maa@example.com", emergency: true)

        for kind in EventNotifyKind.allCases {
            XCTAssertEqual(
                CalendarShareMapper.inviteeEmails(contacts: [mother], kind: kind,
                                                  notifySettings: all),
                ["maa@example.com"],
                "\(kind.rawValue): an emergency contact is invited whatever the toggles say")
        }
    }

    // MARK: - Invite policy: everyone else follows their kind's toggle (rule 3)

    func testOrdinaryContactsFollowTheirKindsToggleWhichDefaultsOff() {
        let toggles = settings()
        let son = contact(name: "छोरा", email: "son@example.com")

        XCTAssertTrue(
            CalendarShareMapper.inviteeEmails(contacts: [son], kind: .medicationReminder,
                                              notifySettings: toggles).isEmpty,
            "the toggles ship OFF — nobody is invited behind the family's back")

        toggles.medicationReminders = true
        XCTAssertEqual(
            CalendarShareMapper.inviteeEmails(contacts: [son], kind: .medicationReminder,
                                              notifySettings: toggles),
            ["son@example.com"])
        XCTAssertTrue(
            CalendarShareMapper.inviteeEmails(contacts: [son], kind: .routineReminder,
                                              notifySettings: toggles).isEmpty,
            "one kind's toggle does not open another kind")
        XCTAssertTrue(
            CalendarShareMapper.inviteeEmails(contacts: [son], kind: .calendarEvent,
                                              notifySettings: toggles).isEmpty)
    }

    func testContactWithNoAddressIsSkippedAndBlankCountsAsAbsent() {
        let toggles = settings(medication: true)
        let contacts = [
            contact(name: "no address", email: nil),
            contact(name: "whitespace", email: "   "),
            contact(name: "real", email: "real@example.com"),
            // An emergency contact with no address is a configuration
            // error the editor refuses to save — but the MAPPER must
            // still not invent an empty invitee for it.
            contact(name: "emergency, no address", email: nil, emergency: true)
        ]

        XCTAssertEqual(
            CalendarShareMapper.inviteeEmails(contacts: contacts, kind: .medicationReminder,
                                              notifySettings: toggles),
            ["real@example.com"],
            "a nil or blank address is absent — never an empty string in the attendee list")
    }

    func testDuplicateAddressesDifferingOnlyInCaseAreCollapsed() {
        let mother = contact(name: "आमा", email: "Maa@Example.com", emergency: true)
        let daughter = contact(name: "छोरी", email: "maa@example.com", emergency: true)

        XCTAssertEqual(
            CalendarShareMapper.inviteeEmails(contacts: [mother, daughter],
                                              kind: .calendarEvent,
                                              notifySettings: settings()),
            ["Maa@Example.com"],
            "one person, one invite — the first spelling is the one kept")
    }

    func testEmergencyContactsComeFirstAndTheRelativeOrderIsPreserved() {
        let toggles = settings(medication: true)
        let son = contact(name: "son", email: "son@example.com")
        let mother = contact(name: "mother", email: "maa@example.com", emergency: true)
        let daughter = contact(name: "daughter", email: "daughter@example.com")

        XCTAssertEqual(
            CalendarShareMapper.inviteeEmails(contacts: [son, daughter, mother],
                                              kind: .medicationReminder,
                                              notifySettings: toggles),
            ["maa@example.com", "son@example.com", "daughter@example.com"],
            "the always-invited set is visible at the head of the list")
    }

    // MARK: - Gate

    func testCanShareNeedsBothASignedInAccountAndConsent() {
        XCTAssertFalse(CalendarShareMapper.canShare(isSignedIn: false, hasConsented: false))
        XCTAssertFalse(CalendarShareMapper.canShare(isSignedIn: true, hasConsented: false),
                       "consent is a real gate — sign-in alone unlocks nothing")
        XCTAssertFalse(CalendarShareMapper.canShare(isSignedIn: false, hasConsented: true))
        XCTAssertTrue(CalendarShareMapper.canShare(isSignedIn: true, hasConsented: true))
    }

    // MARK: - Medication twins

    func testMedicationTwinsAreOnePerScheduleTimeAnchoredOnTheNextOccurrence() {
        let entry = medication(hours: [8, 20])
        let mother = contact(email: "maa@example.com", emergency: true)

        let drafts = CalendarShareMapper.medicationDrafts(
            entry: entry, contacts: [mother], notifySettings: settings(),
            now: now, timeZone: kathmandu, calendar: utcCalendar)

        XCTAssertEqual(drafts.count, 2, "one schedule time is one series — a two-dose day is two twins")
        XCTAssertEqual(drafts.map(\.title), ["Amlodipine", "Amlodipine"])
        XCTAssertEqual(drafts.map(\.recurrence),
                       [EventRecurrence.daily, EventRecurrence.daily],
                       "scheduleTimes are wall-clock times that repeat every day")
        XCTAssertEqual(drafts.map(\.durationMinutes),
                       [CalendarShareMapper.defaultDurationMinutes,
                        CalendarShareMapper.defaultDurationMinutes])
        XCTAssertEqual(drafts.map(\.startDate),
                       [utcDate(2026, 9, 17, 8, 0), utcDate(2026, 9, 16, 20, 0)],
                       "08:00 is already past the 09:00 clock (tomorrow); 20:00 is still ahead (today)")
        XCTAssertTrue(drafts.allSatisfy { $0.timeZoneIdentifier == "Asia/Kathmandu" },
                      "the elder's device zone is carried on the draft, not read from the account's default")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == .medicationReminder })
        XCTAssertTrue(drafts.allSatisfy { $0.attendeeEmails == ["maa@example.com"] })
    }

    func testMedicationTwinsAreEmptyWhenNobodyIsEligible() {
        let entry = medication(hours: [8])
        let ordinary = contact(email: "son@example.com")

        XCTAssertTrue(CalendarShareMapper.medicationDrafts(
            entry: entry, contacts: [], notifySettings: settings(),
            now: now, timeZone: utc, calendar: utcCalendar).isEmpty,
            "no contacts, no draft — the no-op is the mapper's, not the service's")

        XCTAssertTrue(CalendarShareMapper.medicationDrafts(
            entry: entry, contacts: [ordinary], notifySettings: settings(),
            now: now, timeZone: utc, calendar: utcCalendar).isEmpty,
            "an ordinary contact with the toggle OFF is not eligible")
    }

    // MARK: - Routine twins

    func testRoutineTwinsRecurrenceFollowsTheNativeMirror() {
        let mother = contact(email: "maa@example.com", emergency: true)
        let dailyEntry = routine(hours: [10])
        let weeklyEntry = routine(hours: [10], frequency: .weekly, weekdays: [4, 2])
        let weeklyNoDays = routine(hours: [10], frequency: .weekly, weekdays: [])

        func twin(_ entry: RoutineEntry) -> CalendarTwinDraft? {
            CalendarShareMapper.routineDrafts(
                entry: entry, contacts: [mother], notifySettings: settings(),
                now: now, locale: testLocale, timeZone: utc,
                calendar: utcCalendar).first
        }

        XCTAssertEqual(twin(dailyEntry)?.recurrence,
                       CalendarSyncService.recurrence(for: dailyEntry))
        XCTAssertEqual(twin(dailyEntry)?.recurrence, .daily)
        XCTAssertEqual(twin(weeklyEntry)?.recurrence,
                       CalendarSyncService.recurrence(for: weeklyEntry))
        XCTAssertEqual(twin(weeklyEntry)?.recurrence, .weekly(weekdays: [2, 4]))
        XCTAssertEqual(twin(weeklyNoDays)?.recurrence, .daily,
                       "an empty weekday list under .weekly means every day, not never")
        XCTAssertEqual(twin(weeklyNoDays)?.recurrence,
                       CalendarSyncService.recurrence(for: weeklyNoDays))

        XCTAssertEqual(twin(dailyEntry)?.title, routineTitle(for: dailyEntry))
        XCTAssertTrue(twin(dailyEntry)?.title.hasPrefix("Walk (") ?? false,
                      "the twin carries the same \"<name> (<category>)\" label the mirror writes")
        XCTAssertEqual(twin(dailyEntry)?.kind, .routineReminder)
        XCTAssertEqual(twin(dailyEntry)?.startDate, utcDate(2026, 9, 16, 10, 0))
        XCTAssertEqual(twin(weeklyEntry)?.startDate, utcDate(2026, 9, 16, 10, 0),
                       "Wednesday 10:00 is in the {Monday, Wednesday} set and still ahead")
    }

    func testWeeklyRoutineTwinAnchorsOnTheNextListedWeekdayWhenTodayDoesNotFire() {
        let mother = contact(email: "maa@example.com", emergency: true)
        let mondayOnly = routine(hours: [8], frequency: .weekly, weekdays: [2])

        let drafts = CalendarShareMapper.routineDrafts(
            entry: mondayOnly, contacts: [mother], notifySettings: settings(),
            now: now, locale: testLocale, timeZone: utc, calendar: utcCalendar)

        XCTAssertEqual(drafts.first?.startDate, utcDate(2026, 9, 21, 8, 0),
                       "08:00 Wednesday is past and Wednesday is not listed — the next Monday it is")
    }

    func testDisabledRoutineProducesNothing() {
        let mother = contact(email: "maa@example.com", emergency: true)

        XCTAssertTrue(CalendarShareMapper.routineDrafts(
            entry: routine(hours: [10], enabled: false), contacts: [mother],
            notifySettings: settings(), now: now, locale: testLocale,
            timeZone: utc, calendar: utcCalendar).isEmpty,
            "a disabled entry has nothing to share")
    }

    func testRoutineTwinsAreEmptyWhenNobodyIsEligible() {
        let entry = routine(hours: [10])
        let ordinary = contact(email: "son@example.com")

        XCTAssertTrue(CalendarShareMapper.routineDrafts(
            entry: entry, contacts: [], notifySettings: settings(),
            now: now, locale: testLocale, timeZone: utc, calendar: utcCalendar).isEmpty)

        XCTAssertTrue(CalendarShareMapper.routineDrafts(
            entry: entry, contacts: [ordinary],
            notifySettings: settings(routine: false),
            now: now, locale: testLocale, timeZone: utc, calendar: utcCalendar).isEmpty)
    }

    // MARK: - One-off calendar event

    func testCalendarEventTwinIsNilWhenNobodyIsEligible() {
        let start = utcDate(2026, 9, 16, 14, 0)

        XCTAssertNil(CalendarShareMapper.calendarEventDraft(
            title: "Doctor", startDate: start, durationMinutes: 45,
            contacts: [], notifySettings: settings(), timeZone: utc))
        XCTAssertNil(CalendarShareMapper.calendarEventDraft(
            title: "Doctor", startDate: start, durationMinutes: 45,
            contacts: [contact(email: "son@example.com")],
            notifySettings: settings(), timeZone: utc),
            "an ordinary contact with the calendar toggle OFF is not eligible")
    }

    func testCalendarEventTwinIsAOneOffCarryingTheGivenDuration() {
        let start = utcDate(2026, 9, 16, 14, 0)
        // Emergency contacts are eligible for `.calendarEvent` with every
        // toggle off — the voice-created event still reaches the person
        // the elder calls first.
        let mother = contact(email: "maa@example.com", emergency: true)

        let twin = CalendarShareMapper.calendarEventDraft(
            title: "Doctor", startDate: start, durationMinutes: 45,
            contacts: [mother], notifySettings: settings(), timeZone: kathmandu)

        XCTAssertEqual(twin?.title, "Doctor")
        XCTAssertEqual(twin?.startDate, start)
        XCTAssertEqual(twin?.durationMinutes, 45,
                       "a one-off carries the duration it was created with, not the house default")
        XCTAssertNil(twin?.recurrence, "a one-off has no rule")
        XCTAssertEqual(twin?.attendeeEmails, ["maa@example.com"])
        XCTAssertEqual(twin?.kind, .calendarEvent)
        XCTAssertEqual(twin?.timeZoneIdentifier, "Asia/Kathmandu")
    }

    // MARK: - Location (rich-events task, 2026-09-17)

    /// The address the elder typed is what the family reads on the
    /// invitation, so it rides the draft verbatim — trimmed, and nil for
    /// a field that is empty or was emptied.
    func testCalendarEventTwinCarriesTheAddress() {
        let start = utcDate(2026, 9, 16, 14, 0)
        let mother = contact(email: "maa@example.com", emergency: true)

        let twin = CalendarShareMapper.calendarEventDraft(
            title: "Doctor", startDate: start, durationMinutes: 45,
            contacts: [mother], notifySettings: settings(), timeZone: kathmandu,
            location: "  Tilganga, Kathmandu  ")

        XCTAssertEqual(twin?.location, "Tilganga, Kathmandu")
    }

    func testACalendarEventTwinWithoutAnAddressCarriesNone() {
        let start = utcDate(2026, 9, 16, 14, 0)
        let mother = contact(email: "maa@example.com", emergency: true)
        func twin(location: String?) -> CalendarTwinDraft? {
            CalendarShareMapper.calendarEventDraft(
                title: "Doctor", startDate: start, durationMinutes: 45,
                contacts: [mother], notifySettings: settings(), timeZone: kathmandu,
                location: location)
        }

        XCTAssertNil(twin(location: nil)?.location)
        XCTAssertNil(twin(location: "")?.location,
                       "EventKit happily stores an empty location string — "
                       + "no empty location may reach Google")
        XCTAssertNil(twin(location: "   \n ")?.location,
                       "whitespace-only is an emptied field, not an address")
        XCTAssertEqual(CalendarShareMapper.normalizedLocation("  a  "), "a")
        XCTAssertNil(CalendarShareMapper.normalizedLocation(nil))
    }

    /// The medication and routine drafts never carry one: their sources
    /// have no address field at all.
    func testMedicationAndRoutineTwinsHaveNoLocation() {
        let mother = contact(email: "maa@example.com", emergency: true)
        let medicationTwin = CalendarShareMapper.medicationDrafts(
            entry: medication(hours: [8]), contacts: [mother],
            notifySettings: settings(), now: now, timeZone: utc).first
        let routineTwin = CalendarShareMapper.routineDrafts(
            entry: routine(hours: [11]), contacts: [mother],
            notifySettings: settings(), now: now, locale: testLocale,
            timeZone: utc).first

        XCTAssertEqual(medicationTwin?.location, nil)
        XCTAssertEqual(routineTwin?.location, nil)
    }

    /// The address IS content the family sees, so a changed one has to
    /// re-write the twin — and the two "no address" spellings must hash
    /// the same, or a nil→"" round trip would edit the family's calendar
    /// for nothing.
    func testFingerprintChangesWithTheAddress() {
        let start = utcDate(2026, 9, 16, 10, 0)
        let none = draft(start: start, recurrence: .daily, location: nil)
        let blank = draft(start: start, recurrence: .daily, location: "")
        let patan = draft(start: start, recurrence: .daily, location: "Patan")
        let boudha = draft(start: start, recurrence: .daily, location: "Boudha")

        XCTAssertEqual(CalendarShareMapper.fingerprint(of: none),
                       CalendarShareMapper.fingerprint(of: blank),
                       "absent and empty are the same address")
        XCTAssertNotEqual(CalendarShareMapper.fingerprint(of: none),
                          CalendarShareMapper.fingerprint(of: patan),
                          "an added address is a change the family must see")
        XCTAssertNotEqual(CalendarShareMapper.fingerprint(of: patan),
                          CalendarShareMapper.fingerprint(of: boudha),
                          "a corrected address is a change too")
    }

    // MARK: - Fingerprint

    func testFingerprintIgnoresAttendeeOrderAndCase() {
        // The three drafts differ ONLY in the attendee list, so they share
        // the anchored start — which is the point: neither the order the
        // family happened to be listed in nor the case they typed the
        // address in is a change to the event.
        let ordered = draft(start: now, attendees: ["maa@example.com", "son@example.com"])
        let reordered = draft(start: now, attendees: ["son@example.com", "maa@example.com"])
        let recased = draft(start: now, attendees: ["MAA@example.com", "Son@Example.com"])

        XCTAssertEqual(CalendarShareMapper.fingerprint(of: ordered),
                       CalendarShareMapper.fingerprint(of: reordered),
                       "the attendee order depends on Settings, which is not a change to the event")
        XCTAssertEqual(CalendarShareMapper.fingerprint(of: ordered),
                       CalendarShareMapper.fingerprint(of: recased))
    }

    func testFingerprintChangesWithEveryPayloadField() {
        let start = utcDate(2026, 9, 16, 10, 0)
        let base = draft(title: "Walk", start: start, duration: 30, zone: "UTC",
                         recurrence: .daily, attendees: ["maa@example.com"])
        let fingerprint = CalendarShareMapper.fingerprint(of: base)

        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk with Maya", start: start, duration: 30, zone: "UTC",
                      recurrence: .daily, attendees: ["maa@example.com"])), "title")
        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk", start: start, duration: 45, zone: "UTC",
                      recurrence: .daily, attendees: ["maa@example.com"])), "duration")
        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk", start: start, duration: 30, zone: "Asia/Kathmandu",
                      recurrence: .daily, attendees: ["maa@example.com"])), "timezone")
        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk", start: start, duration: 30, zone: "UTC",
                      recurrence: .weekly(weekdays: [2]), attendees: ["maa@example.com"])),
            "recurrence")
        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk", start: start, duration: 30, zone: "UTC",
                      recurrence: .daily,
                      attendees: ["maa@example.com", "son@example.com"])), "attendee set")
        XCTAssertNotEqual(fingerprint, CalendarShareMapper.fingerprint(
            of: draft(title: "Walk", start: start, duration: 30, zone: "UTC",
                      recurrence: .daily, attendees: ["maa@example.com"],
                      kind: .medicationReminder)), "kind")
    }

    /// **The deliberate exclusion.** A recurring twin's anchor is "the
    /// next occurrence" by construction, so it moves forward every day;
    /// hashing the calendar date would re-write every series daily for
    /// no change in what the family sees. The wall-clock time is what
    /// identifies the series.
    func testFingerprintOfARecurringTwinIgnoresTheAnchorDateRollingForward() {
        let today = draft(start: utcDate(2026, 9, 16, 8, 0), recurrence: .daily)
        let nextWeek = draft(start: utcDate(2026, 9, 23, 8, 0), recurrence: .daily)
        let movedClock = draft(start: utcDate(2026, 9, 16, 9, 0), recurrence: .daily)

        XCTAssertEqual(CalendarShareMapper.fingerprint(of: today),
                       CalendarShareMapper.fingerprint(of: nextWeek),
                       "the anchor rolled forward exactly 7 days at the same wall clock and zone — same series")

        XCTAssertNotEqual(CalendarShareMapper.fingerprint(of: today),
                          CalendarShareMapper.fingerprint(of: movedClock),
                          "a changed wall-clock time IS a changed series")
    }

    /// A one-off has no rule to carry its date, so the full instant is
    /// the content.
    func testFingerprintOfAOneOffHashesTheWholeInstant() {
        let today = draft(start: utcDate(2026, 9, 16, 8, 0))
        let nextWeek = draft(start: utcDate(2026, 9, 23, 8, 0))

        XCTAssertNil(today.recurrence)
        XCTAssertNotEqual(CalendarShareMapper.fingerprint(of: today),
                          CalendarShareMapper.fingerprint(of: nextWeek),
                          "a moved one-off is a different event — nothing carries the date")
    }

    // MARK: - Diffing

    func testPlanReturnsCreatesAndRemovalsAndNothingForUnchangedKeys() {
        let plan = CalendarShareMapper.plan(currentKeys: ["a", "b", "c"],
                                            snapshotKeys: ["b", "c", "d"])
        XCTAssertEqual(plan.created, ["a"], "present now, absent before — a create")
        XCTAssertEqual(plan.removed, ["d"],
                       "present before, absent now — a tombstone, so a twin whose create once failed still gets cleaned up")

        let quiet = CalendarShareMapper.plan(currentKeys: ["a", "b"],
                                             snapshotKeys: ["a", "b"])
        XCTAssertTrue(quiet.created.isEmpty)
        XCTAssertTrue(quiet.removed.isEmpty)

        let firstEverPass = CalendarShareMapper.plan(currentKeys: ["a"], snapshotKeys: [])
        XCTAssertEqual(firstEverPass.created, ["a"])
        XCTAssertTrue(firstEverPass.removed.isEmpty)
    }
}
