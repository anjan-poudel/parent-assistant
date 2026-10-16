import XCTest
import EventKit
@testable import ElderlyAssistant

/// The Events form's value rules (rich-events task, 2026-09-17; design
/// §2 / §5): validation, the house default duration, address and notes
/// normalization, and — the load-bearing one — the recurrence
/// translation from the three choices the form offers to the
/// `EKRecurrenceRule` an `EKEvent` is actually written with.
///
/// Everything here is pure: no event store, no permissions, no UI. The
/// form view binds fields and nothing else; these are the rules it
/// binds to.
final class FreeFormEventFormTests: XCTestCase {

    private let en = Locale(identifier: "en")
    private let ne = Locale(identifier: "ne")

    /// Pinned local clock: 2026-09-17 09:00 (a Thursday).
    private func date(hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 17, hour: hour, minute: minute, second: second))!
    }

    private func makeEvent(id: String = "evt-1",
                           title: String = "Dr Sharma",
                           start: Date? = nil,
                           durationMinutes: Int = 30,
                           recurrence: EventRecurrence? = nil,
                           notes: String? = nil,
                           address: String? = nil,
                           photoFilename: String? = nil) -> FreeFormEvent {
        FreeFormEvent(id: id,
                      title: title,
                      startDate: start ?? date(hour: 11),
                      durationMinutes: durationMinutes,
                      recurrence: recurrence,
                      notes: notes,
                      address: address,
                      photoFilename: photoFilename)
    }

    // MARK: - Validation

    func testTitleIsTheOnlyRequiredField() {
        var form = FreeFormEventForm(startDate: date(hour: 11))
        XCTAssertFalse(form.isValid, "an untitled event is not saveable")

        form.title = "   \n "
        XCTAssertFalse(form.isValid,
                       "whitespace is not a title — the same reading the trimmed value has")

        form.title = "  Eye doctor "
        XCTAssertTrue(form.isValid)
        XCTAssertEqual(form.trimmedTitle, "Eye doctor",
                       "what is validated is what is written")
    }

    func testEverythingElseHasAHonestDefaultSoATitleAloneIsSaveable() {
        let form = FreeFormEventForm(startDate: date(hour: 11))

        XCTAssertEqual(form.durationMinutes, 30)
        XCTAssertEqual(form.recurrence, .none)
        XCTAssertEqual(form.notes, "")
        XCTAssertEqual(form.address, "")
        XCTAssertNil(form.pickedPhoto, "nothing picked yet — not the same as 'no photo'")
        XCTAssertFalse(form.removedPhoto)
        XCTAssertNil(form.originalRecurrence)
    }

    func testDefaultStartDateIsAnHourAheadOnTheMinute() {
        let now = date(hour: 9, minute: 30, second: 47)
        let proposed = FreeFormEventForm.defaultStartDate(now: now)
        XCTAssertEqual(proposed, date(hour: 10, minute: 30),
                       "the appointment form's default (now + 1h), seconds zeroed")
    }

    func testDefaultDurationAndTheFourOfferedChoicesAreTheHouseDefaults() {
        XCTAssertEqual(FreeFormEventForm.defaultDurationMinutes, 30)
        XCTAssertEqual(FreeFormEventForm.durationChoices, [15, 30, 60, 120])
        // The gateway answers the same 30 for an event with no measurable
        // end — the form's default and the read-back default must agree,
        // or a saved event would change length on reopen.
        let form = FreeFormEventForm(startDate: date(hour: 11))
        XCTAssertEqual(form.normalizedDurationMinutes, 30)
        let record = CalendarEventRecord(eventIdentifier: "x", calendarIdentifier: nil,
                                         title: "x", notes: nil, startDate: date(hour: 11),
                                         isAllDay: false, isCanceled: false, recurrence: nil)
        XCTAssertEqual(record.durationMinutes, 30)
    }

    // MARK: - Normalization

    func testBlankNotesAndAddressBecomeNilNotEmptyStrings() {
        var form = FreeFormEventForm(startDate: date(hour: 11))
        XCTAssertNil(form.normalizedNotes)
        XCTAssertNil(form.normalizedAddress)

        form.notes = "  Ring the bell twice  "
        form.address = "  Boudha, Kathmandu  "
        XCTAssertEqual(form.normalizedNotes, "Ring the bell twice")
        XCTAssertEqual(form.normalizedAddress, "Boudha, Kathmandu",
                       "trimmed — the Calendar row and the Google twin read the same address")
    }

    func testAWhitespaceOnlyAddressIsNoAddress() {
        var form = FreeFormEventForm(startDate: date(hour: 11))
        form.address = "   \n  "
        XCTAssertNil(form.normalizedAddress,
                     "an emptied field and a never-filled one must read the same — "
                     + "this is exactly what the Go button's existence hangs on")

        let event = makeEvent(address: "   ")
        XCTAssertFalse(event.hasAddress,
                       "a whitespace address must not put a Go button on an event "
                       + "with nowhere to go")
    }

    func testDurationIsFlooredAtOneMinute() {
        var form = FreeFormEventForm(startDate: date(hour: 11))
        form.durationMinutes = 0
        XCTAssertEqual(form.normalizedDurationMinutes, 1,
                       "a zero-length block is not something anyone can be reminded of")
        form.durationMinutes = -30
        XCTAssertEqual(form.normalizedDurationMinutes, 1)
    }

    func testDurationLabelsUseTheSingleHouseFormat() {
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 15, locale: en), "15 min")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 30, locale: en), "30 min")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 60, locale: en), "1 hr")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 120, locale: en), "2 hr")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 90, locale: en), "90 min",
                       "only whole hours read as hours — 90 min is not '1.5 hr'")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 30, locale: ne), "30 मिनेट")
        XCTAssertEqual(FreeFormEventForm.durationLabel(minutes: 120, locale: ne), "2 घण्टा")
    }

    // MARK: - Recurrence translation (form → app terms)

    func testRecurrenceChoicesRoundTripThroughTheAppVocabulary() {
        XCTAssertNil(FreeFormEventRecurrence.none.eventRecurrence(startDate: date(hour: 11)))
        XCTAssertEqual(FreeFormEventRecurrence.daily.eventRecurrence(startDate: date(hour: 11)),
                       .daily)
        XCTAssertEqual(FreeFormEventRecurrence.weekly.eventRecurrence(startDate: date(hour: 11)),
                       .weekly(weekdays: [5]),
                       "weekly means the weekday the event already falls on — "
                       + "2026-09-17 is a Thursday (5)")

        XCTAssertEqual(FreeFormEventRecurrence.from(nil), .none)
        XCTAssertEqual(FreeFormEventRecurrence.from(.daily), .daily)
        XCTAssertEqual(
            FreeFormEventRecurrence.from(.weekly(weekdays: [2, 4, 6])), .weekly,
            "any weekly rule reads as the weekly choice; WHICH days is preserved separately")
    }

    func testEveryRecurrenceChoiceHasItsOwnCatalogKey() {
        XCTAssertEqual(FreeFormEventRecurrence.allCases.count, 3,
                       "none / daily / weekly — monthly and yearly are out of scope")
        for choice in FreeFormEventRecurrence.allCases {
            let key = choice.titleKey
            XCTAssertEqual(key, "events.recurrence.\(choice.rawValue)")
            XCTAssertNotEqual(L10n.str(key, locale: en), key, "\(key) is untranslated")
            XCTAssertNotEqual(L10n.str(key, locale: ne), key, "\(key) has no Nepali")
        }
    }

    func testResolvedRecurrenceMatrix() {
        // none → nil; daily → daily, regardless of what the event had.
        var fromNone = FreeFormEventForm(startDate: date(hour: 11))
        fromNone.recurrence = .none
        XCTAssertNil(fromNone.resolvedRecurrence)

        var toDaily = FreeFormEventForm(startDate: date(hour: 11))
        toDaily.originalRecurrence = .weekly(weekdays: [2, 4])
        toDaily.recurrence = .daily
        XCTAssertEqual(toDaily.resolvedRecurrence, .daily)

        // weekly, chosen fresh → the start date's weekday.
        var freshWeekly = FreeFormEventForm(startDate: date(hour: 11))
        freshWeekly.recurrence = .weekly
        XCTAssertEqual(freshWeekly.resolvedRecurrence, .weekly(weekdays: [5]))

        // weekly on an event that was already weekly → the day list is
        // NOT the form's to change (the form has no weekday picker; the
        // family may have edited the days in the Calendar app).
        var editedSeries = FreeFormEventForm(startDate: date(hour: 11))
        editedSeries.originalRecurrence = .weekly(weekdays: [2, 4, 6])
        editedSeries.recurrence = .weekly
        XCTAssertEqual(editedSeries.resolvedRecurrence, .weekly(weekdays: [2, 4, 6]),
                       "opening and saving a family-edited series must not drop days "
                       + "this form never showed")

        // weekly chosen on a former daily → the start date's weekday.
        var dailyToWeekly = FreeFormEventForm(startDate: date(hour: 11))
        dailyToWeekly.originalRecurrence = .daily
        dailyToWeekly.recurrence = .weekly
        XCTAssertEqual(dailyToWeekly.resolvedRecurrence, .weekly(weekdays: [5]))
    }

    // MARK: - The draft the gateway writes

    func testDraftCarriesTheTrimmedTitleNotesAndAddress() {
        var form = FreeFormEventForm(startDate: date(hour: 14, minute: 30))
        form.title = "  Dentist  "
        form.notes = "  bring the old x-ray  "
        form.address = "  Patan Durbar Square  "
        form.durationMinutes = 60

        let draft = form.draft()
        XCTAssertEqual(draft.title, "Dentist")
        XCTAssertEqual(draft.notes, "bring the old x-ray")
        XCTAssertEqual(draft.location, "Patan Durbar Square")
        XCTAssertEqual(draft.startDate, date(hour: 14, minute: 30))
        XCTAssertEqual(draft.durationMinutes, 60)
        XCTAssertNil(draft.recurrence)
    }

    func testDraftOfAnAddresslessEventHasNoLocation() {
        var form = FreeFormEventForm(startDate: date(hour: 11))
        form.title = "Physio"
        XCTAssertNil(form.draft().location,
                     "EventKit stores an empty location string happily — the form must "
                     + "not hand it one")
    }

    // MARK: - The edit form

    func testEditFormLoadsEveryFieldAndRemembersTheOriginalRule() {
        let event = makeEvent(title: "Eye doctor",
                              start: date(hour: 15),
                              durationMinutes: 60,
                              recurrence: .weekly(weekdays: [2, 4]),
                              notes: "room 4",
                              address: "Tilganga",
                              photoFilename: "a.jpg")

        let form = FreeFormEventForm(event: event)
        XCTAssertEqual(form.title, "Eye doctor")
        XCTAssertEqual(form.startDate, date(hour: 15))
        XCTAssertEqual(form.durationMinutes, 60)
        XCTAssertEqual(form.recurrence, .weekly)
        XCTAssertEqual(form.notes, "room 4")
        XCTAssertEqual(form.address, "Tilganga")
        XCTAssertEqual(form.originalRecurrence, .weekly(weekdays: [2, 4]))
        XCTAssertNil(form.pickedPhoto, "an edit must not look like a freshly-picked photo")
        XCTAssertFalse(form.removedPhoto)
        // And saving it unchanged is a no-op on the rule.
        XCTAssertEqual(form.resolvedRecurrence, .weekly(weekdays: [2, 4]))
    }

    func testEditFormOfAOneOffEventHasTheNoneChoice() {
        XCTAssertEqual(FreeFormEventForm(event: makeEvent()).recurrence, .none)
    }

    // MARK: - The EventKit rule the recurrence becomes

    func testRecurrenceRulesAreTheOneNoneDailyWeeklyMapping() {
        XCTAssertTrue(EKCalendarGateway.recurrenceRules(for: nil).isEmpty,
                      "nil means 'does not repeat' and CLEARS any rule the event had")

        let daily = EKCalendarGateway.recurrenceRules(for: .daily)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.frequency, .daily)
        XCTAssertEqual(daily.first?.interval, 1)
        XCTAssertNil(daily.first?.recurrenceEnd)

        let weekly = EKCalendarGateway.recurrenceRules(for: .weekly(weekdays: [5]))
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly.first?.frequency, .weekly)
        XCTAssertEqual(weekly.first?.interval, 1)
        XCTAssertEqual(weekly.first?.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue), [5])
        XCTAssertEqual(weekly.first?.daysOfTheWeek?.map(\.weekNumber), [0],
                       "weekNumber must be 0 for a weekly rule")

        let multi = EKCalendarGateway.recurrenceRules(for: .weekly(weekdays: [2, 4, 6]))
        XCTAssertEqual(multi.first?.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue), [2, 4, 6])
    }

    /// The round trip the reconcile depends on: what the form's weekly
    /// choice writes, the gateway reads back as the same app-level rule.
    func testAWeeklyChoiceSurvivesTheRuleRoundTrip() {
        for weekdays in [[5], [1, 7], [2, 4, 6]] {
            let rules = EKCalendarGateway.recurrenceRules(for: .weekly(weekdays: weekdays))
            XCTAssertEqual(EKCalendarGateway.recurrence(from: rules.first),
                           .weekly(weekdays: weekdays),
                           "weekdays \(weekdays) must read back identically")
        }
        XCTAssertEqual(EKCalendarGateway.recurrence(
            from: EKCalendarGateway.recurrenceRules(for: .daily).first), .daily)
        XCTAssertNil(EKCalendarGateway.recurrence(from: nil))
    }

    // MARK: - Places the Go button rides on

    func testAnAddresslessEventHasNoGoButton() {
        XCTAssertFalse(makeEvent(address: nil).hasAddress)
        XCTAssertTrue(makeEvent(address: "Boudha").hasAddress)
    }

    /// The free-form Navigate path reuses the EXISTING directions
    /// builders — no event-specific map URL was added, so the
    /// auto-start guarantees the directions tests pin hold here too.
    func testNavigateReusesTheExistingAutoStartDirectionsURL() {
        let url = MapsLinks.directionsURL(for: .googleMaps,
                                          latitude: 27.7215, longitude: 85.3620,
                                          uiLanguageCode: "ne")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.google.com")
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("dir_action=navigate"),
                      "the walking auto-start ask is unchanged for rich events")
        XCTAssertTrue(query.contains("travelmode=walking"))
        XCTAssertTrue(query.contains("hl=ne"))

        let apple = MapsLinks.directionsURL(for: .appleMaps,
                                            latitude: 27.7215, longitude: 85.3620,
                                            uiLanguageCode: "ne")
        XCTAssertEqual(apple?.scheme, "maps")
    }

    // MARK: - How the list states a series

    func testTheListSaysOnceForAOneOffAndRepeatsForASeries() {
        let oneOff = makeEvent(start: date(hour: 11))
        let oneOffText = EventsView.whenText(for: oneOff, locale: en)
        XCTAssertTrue(oneOffText.contains("·"), "a one-off prints its date and time")
        XCTAssertTrue(oneOffText.contains("11:00"))
        XCTAssertFalse(oneOffText.contains("Every"))

        let daily = makeEvent(start: date(hour: 11), recurrence: .daily)
        let dailyText = EventsView.whenText(for: daily, locale: en)
        // Formatting the clock the same way the view does isolates the
        // RULE under test from 12/24-hour region differences.
        let clock = daily.startDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(en))
        XCTAssertEqual(dailyText, L10n.fmt("events.repeats.daily", locale: en, clock),
                       "a series says its RULE, never the first occurrence's date — "
                       + "which would read as a past appointment")
        XCTAssertFalse(dailyText.contains("·"))

        let weekly = makeEvent(start: date(hour: 11),
                               recurrence: .weekly(weekdays: [5]))
        let weeklyText = EventsView.whenText(for: weekly, locale: en)
        XCTAssertTrue(weeklyText.contains("Thursday"),
                      "the day the event falls on is the day it says: \(weeklyText)")
        XCTAssertTrue(weeklyText.contains("Every"))
        XCTAssertFalse(weeklyText.contains("·"))

        let nepali = EventsView.whenText(for: daily, locale: ne)
        XCTAssertTrue(nepali.hasPrefix("हरेक दिन"), "the rule is stated in the app language: \(nepali)")
    }
}
