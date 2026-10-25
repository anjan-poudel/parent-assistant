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
///
/// [REMINDERS-INSTRUCTIONS] (T-024) `@MainActor` because the new tests call
/// the views' static value seams (`EventFormView.saveAction`,
/// `EventDetailView.detailState`) — the same isolation the shipping SwiftUI
/// `View` conformance has.
@MainActor
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
                           photoFilename: String? = nil,
                           instruction: Instruction? = nil) -> FreeFormEvent {
        FreeFormEvent(id: id,
                      title: title,
                      startDate: start ?? date(hour: 11),
                      durationMinutes: durationMinutes,
                      recurrence: recurrence,
                      notes: notes,
                      address: address,
                      photoFilename: photoFilename,
                      instruction: instruction)
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

    // MARK: - The instruction draft (design L2 §4.8, T-015)

    /// The edit form is seeded with the event's stored instruction, so an
    /// untouched save has nothing to write; the same draft, once edited,
    /// resolves exactly the commit the service receives.
    func testFormCarriesInstructionDraft() {
        let instruction = Instruction(kind: "text", text: "Take the blue pill")
        let form = FreeFormEventForm(event: makeEvent(instruction: instruction))

        XCTAssertEqual(form.instructionDraft.loadState, .loaded)
        XCTAssertEqual(form.instructionDraft.original, instruction,
                       "the draft knows what it loaded — revert() restores this value")
        XCTAssertNil(form.instructionDraft.resolvedCommit,
                     "an untouched draft must not write an instruction")

        var edited = form
        edited.instructionDraft.setText("Take the red pill")
        XCTAssertEqual(edited.instructionDraft.resolvedCommit,
                       InstructionCommit(write: .set(InstructionPayload(
                           kind: .text, text: "Take the red pill")),
                                         pendingMedia: nil))
    }

    /// The add form starts loaded with no instruction: `resolvedCommit` is
    /// nil (no instruction work), never an empty `.remove`.
    func testFormWithoutInstructionHasNoDraft() {
        let addForm = FreeFormEventForm(startDate: date(hour: 11))
        XCTAssertEqual(addForm.instructionDraft.loadState, .loaded)
        XCTAssertNil(addForm.instructionDraft.original)
        XCTAssertNil(addForm.instructionDraft.resolvedCommit)

        let editForm = FreeFormEventForm(event: makeEvent())
        XCTAssertNil(editForm.instructionDraft.original,
                     "an event with no instruction seeds an empty draft")
        XCTAssertNil(editForm.instructionDraft.resolvedCommit)
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

    // MARK: - Instruction editing and detail (T-024; design L2 §2.10, §4.8,
    // §4.10, §11.3 M/Q)
    //
    // SwiftUI cannot be rendered in-process here, so every rendering claim
    // is pinned either at a pure value seam the view itself uses or with a
    // `FeatureSourceScan.codeText` source pin over `EventsView.swift`
    // (comments stripped). The delete case additionally drives the REAL
    // service teardown over a temporary video store: the view must add no
    // second teardown of its own.

    /// One instruction section on the event form, bound to the form's one
    /// draft, with its editor session created by the tap.
    func testEventFormCarriesOneInstructionDraft() throws {
        let instruction = Instruction(kind: "text", text: "Take the blue pill")
        let form = FreeFormEventForm(event: makeEvent(instruction: instruction))
        XCTAssertEqual(form.instructionDraft.original, instruction)
        XCTAssertEqual(EventFormView.formSummaryState(for: form.instructionDraft),
                       .text(text: "Take the blue pill"),
                       "the section summarises the stored instruction, not a filename")
        XCTAssertEqual(EventFormView.instructionControlKey(for: form.instructionDraft),
                       "instruction.change")
        XCTAssertEqual(EventFormView.instructionControlKey(for: .loaded(instruction: nil)),
                       "instruction.add")

        let source = eventsViewSource()
        let formSource = typeSource("EventFormView", in: source)
        let body = member("var body", of: formSource)
        XCTAssertEqual(occurrences(of: "instructionCard", in: body), 1,
                       "exactly one instruction section")
        let photo = try XCTUnwrap(body.range(of: "photoCard")).lowerBound
        let instructionCard = try XCTUnwrap(body.range(of: "instructionCard")).lowerBound
        let address = try XCTUnwrap(body.range(of: "addressCard")).lowerBound
        XCTAssertTrue(photo < instructionCard && instructionCard < address,
                      "the section sits after the photo card and before the address card")

        XCTAssertEqual(occurrences(of: "coordinator.instructionCaptureCoordinator(draftSession: .events)",
                                   in: source), 1,
                       "one capture coordinator per editor session, from the one factory")
        XCTAssertFalse(source.contains("InstructionVideoCaptureCoordinator("),
                       "the view never constructs a capture coordinator itself")
        XCTAssertTrue(body.contains(".sheet(item: $instructionEditorSession)"))
        XCTAssertTrue(body.contains("initialDraft: form.instructionDraft"),
                      "the sheet starts from the form's draft")

        let sheet = typeSource("EventInstructionEditorSheet", in: source)
        XCTAssertTrue(sheet.contains("InstructionEditorView("))
        XCTAssertTrue(sheet.contains("draft: $draft"))
        XCTAssertTrue(sheet.contains("capture: capture"))
        XCTAssertTrue(sheet.contains("onAccept(draft)"),
                      "the editor's Save hands its resolved draft back")
        XCTAssertTrue(sheet.contains("onCancel: onCancel"))
    }

    /// The event form's ONE persistence call, and the total outcome →
    /// action mapping the Save tap follows (design §4.8).
    func testEventSaveSendsFormViaCoordinator() {
        XCTAssertEqual(EventFormView.saveAction(for: nil), .stayOpen)
        XCTAssertEqual(EventFormView.saveAction(
            for: FreeFormEventSaveOutcome(eventId: "evt-1", instructionSaved: true)), .dismiss)
        XCTAssertEqual(EventFormView.saveAction(
            for: FreeFormEventSaveOutcome(eventId: "evt-1", instructionSaved: false)),
            .dismissReportingPartial)

        let source = eventsViewSource()
        let formSource = typeSource("EventFormView", in: source)
        let save = member("private func save()", of: formSource)
        XCTAssertEqual(occurrences(
            of: "coordinator.saveFreeFormEvent(form, editing: event?.id)", in: save), 1)
        XCTAssertTrue(save.contains("switch EventFormView.saveAction(for: outcome)"))
        XCTAssertEqual(occurrences(of: "saveFreeFormEvent", in: source), 1,
                       "one persistence call in the whole file")
        for secondWrite in ["setInstruction(", "saveRoutineInstruction",
                            "freeFormEventService.save"] {
            XCTAssertFalse(source.contains(secondWrite),
                           "no second write path: \(secondWrite)")
        }
    }

    /// No instruction means no card and no summary — not an empty container.
    func testEventWithoutInstructionRendersNone() {
        XCTAssertEqual(EventFormView.formSummaryState(for: .loaded(instruction: nil)), .none)
        XCTAssertEqual(EventDetailView.detailState(for: makeEvent(instruction: nil)), .none)

        let source = eventsViewSource()
        let detail = typeSource("EventDetailView", in: source)
        let card = member("private func instructionCard(", of: detail)
        XCTAssertTrue(card.contains("if state != .none"),
                      "the host draws nothing for .none")
        XCTAssertTrue(card.contains("InstructionCardView("))
        XCTAssertFalse(card.contains("EmptyView()"),
                       "the shared card owns .none → EmptyView; the host adds no placeholder")
        XCTAssertFalse(card.contains("Color.clear"),
                       "no invisible container is laid out on the detail screen")
    }

    /// A partial outcome closes the form (the event exists) and leaves ONE
    /// plain line on the screen underneath — never a modal, never an error
    /// dialog, never a success claim, and never a re-submit (design
    /// §2.10.2–3, §6.1.2).
    func testPartialOutcomeShowsOnePlainLine() {
        XCTAssertEqual(EventFormView.saveAction(
            for: FreeFormEventSaveOutcome(eventId: "evt-1", instructionSaved: false)),
            .dismissReportingPartial)
        XCTAssertEqual(EventFormView.partialSaveKey, "instruction.savePartial")

        let english = L10n.str(EventFormView.partialSaveKey, locale: en)
        let nepali = L10n.str(EventFormView.partialSaveKey, locale: ne)
        XCTAssertEqual(english,
                       "The video couldn't be saved. Add it again from the event.")
        XCTAssertFalse(nepali.isEmpty)
        XCTAssertNotEqual(english, nepali)
        XCTAssertFalse(english.lowercased().contains("instruction saved"),
                       "the line never claims the instruction saved")
        XCTAssertFalse(english.contains("error"),
                       "no error code or technical detail reaches the person")

        let source = eventsViewSource()
        let formSource = typeSource("EventFormView", in: source)
        let save = member("private func save()", of: formSource)
        let partialBranch = branch(from: "case .dismissReportingPartial:",
                                   to: "\n        }\n    }", in: save)
        XCTAssertTrue(partialBranch.contains("onSaved(true)"),
                      "the host is told the outcome was partial")
        XCTAssertTrue(partialBranch.contains("dismiss()"),
                      "a non-nil outcome always closes the form")
        XCTAssertFalse(partialBranch.contains("saveFreeFormEvent"),
                       "never re-submit automatically")
        XCTAssertFalse(formSource.contains("showingPartialSave"),
                       "the form renders no notice of its own")
        XCTAssertFalse(member("var body", of: formSource).contains(".alert("),
                       "the partial line is not a modal or an error dialog")

        // The line is shown by the screen the closed form reveals: the list
        // for add/edit-from-list, the detail for edit-from-detail.
        let list = typeSource("EventsView", in: source)
        XCTAssertTrue(member("var body", of: list).contains("partialSaveNotice"))
        XCTAssertTrue(member("private var partialSaveNotice", of: list)
            .contains("EventFormView.partialSaveKey"))
        let detail = typeSource("EventDetailView", in: source)
        XCTAssertTrue(member("private func detailCards(", of: detail)
            .contains("partialSaveNotice"))
        XCTAssertTrue(member("private var partialSaveNotice", of: detail)
            .contains("EventFormView.partialSaveKey"))
        XCTAssertFalse(source.contains(
            ".alert(LocalizedStringKey(EventFormView.partialSaveKey)"),
            "the partial line is never a dialog")
    }

    /// The editor owns a copy; Cancel (button or swipe) leaves the form's
    /// draft byte-for-byte unchanged and submits nothing.
    func testCancelWritesNothing() {
        let instruction = Instruction(kind: "text", text: "Take the blue pill")
        let form = FreeFormEventForm(event: makeEvent(instruction: instruction))
        let before = form.instructionDraft

        var cancelledEdit = before
        cancelledEdit.setText("Take the red pill")
        XCTAssertEqual(form.instructionDraft, before,
                       "editing the sheet's copy changes no form state")
        XCTAssertNil(form.instructionDraft.resolvedCommit,
                     "a cancelled session leaves no pending write")

        let source = eventsViewSource()
        let formSource = typeSource("EventFormView", in: source)
        XCTAssertTrue(formSource.contains("form.instructionDraft = edited"),
                      "only the editor's Save copies the draft back")
        XCTAssertTrue(formSource.contains("onAccept: { edited in"))

        let sheet = typeSource("EventInstructionEditorSheet", in: source)
        for write in ["saveFreeFormEvent", "setInstruction(", "deleteAll(",
                      "removeItem", "FileManager"] {
            XCTAssertFalse(sheet.contains(write),
                           "the sub-sheet persists nothing: \(write)")
        }
        XCTAssertTrue(sheet.contains("onCancel: onCancel"),
                      "Cancel closes without a write")

        let buttons = member("private var saveButton", of: formSource)
        XCTAssertTrue(buttons.contains("dismiss()"))
        XCTAssertFalse(buttons.contains("saveFreeFormEvent"))
    }

    /// Delete stays on the existing coordinator/service path: the service
    /// tears the event owner's video directory down, and the view adds no
    /// second teardown.
    func testDeleteEventTearsDownMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-form-delete-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let videos = InstructionVideoStore(baseDirectory: root)
        let owner = InstructionOwner.event("evt-1")
        let ownerDirectory = try videos.ownerDirectoryURL(named: owner.directoryName,
                                                          in: .events).get()
        try FileManager.default.createDirectory(at: ownerDirectory,
                                                withIntermediateDirectories: true)
        let video = ownerDirectory.appendingPathComponent("instruction-video.mov")
        try Data([0x00, 0x01, 0x02]).write(to: video)

        let gateway = EventFormDeleteGateway()
        let service = FreeFormEventService(
            gateway: gateway,
            extras: EventExtrasStore(storage: MockEncryptedLocalStorage()),
            photoStore: ContactPhotoStore(
                rootDirectory: root.appendingPathComponent("EventPhotos", isDirectory: true)),
            instructionVideoStore: videos)

        XCTAssertTrue(service.delete(eventId: "evt-1"))
        XCTAssertEqual(gateway.removedIdentifiers, ["evt-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path),
                       "the event owner's whole video directory is torn down")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerDirectory.path))

        let source = eventsViewSource()
        let detail = typeSource("EventDetailView", in: source)
        let delete = member("private func deleteEvent()", of: detail)
        XCTAssertEqual(occurrences(
            of: "coordinator.deleteFreeFormEvent(eventId: eventId)", in: delete), 1,
            "the one delete path is the coordinator's")
        for token in ["deleteAll(", "removeItem", "FileManager",
                      "instructionVideoStore", "deleteVideoMedia",
                      "tearDownInstructionVideoMedia", "photoStore"] {
            XCTAssertFalse(delete.contains(token),
                           "the view adds no second teardown: \(token)")
        }
    }

    /// No URL field, link/YouTube playback, share sheet, transcode or
    /// photo-library permission path — and the one allowed picker is the
    /// shipping out-of-process wrapper.
    func testEventEditorOffersNoURLLinkOrPhotoLibraryPath() {
        let source = eventsViewSource()
        for token in ["https", "http://", "openURL", "UIApplication", "Link(",
                      "ShareLink", "UIActivityViewController", "PHPhotoLibrary",
                      "PHAsset", "requestAuthorization", "NSPhotoLibrary",
                      "AVPlayer", "youtube", "YouTube"] {
            XCTAssertFalse(source.contains(token),
                           "no URL/link/share/photo-library path may appear: \(token)")
        }
        XCTAssertEqual(occurrences(of: "VisualAidPhotoPicker(selectionLimit: 1)",
                                   in: source), 1,
                       "the one allowed picker is the shipping permission-free wrapper")

        let sheet = typeSource("EventInstructionEditorSheet", in: source)
        XCTAssertFalse(sheet.contains("TextField"),
                       "the shared editor owns every field; the host adds none")
        XCTAssertTrue(sheet.contains("VisualAidPhotoPicker(selectionLimit: 1)"))
    }

    /// The detail renders the shared card from the shared IF-3 state, with
    /// playback resolved off the draw path and a control only when the
    /// store says the file is available.
    func testEventDetailShowsInstructionCard() {
        let textEvent = makeEvent(
            instruction: Instruction(kind: "text", text: "Take the blue pill"))
        XCTAssertEqual(EventDetailView.detailState(for: textEvent),
                       .text(text: "Take the blue pill"))
        XCTAssertEqual(EventDetailView.detailState(for: makeEvent(
            instruction: Instruction(kind: "image", caption: "The box",
                                     filename: "photo-1.jpg"))),
            .image(filename: "photo-1.jpg", caption: "The box"))
        XCTAssertEqual(EventDetailView.detailState(for: makeEvent(
            instruction: Instruction(kind: "video", filename: "video-1.mov"))),
            .video(filename: "video-1.mov", caption: nil))
        XCTAssertEqual(EventDetailView.detailState(for: makeEvent(
            instruction: Instruction(kind: "future", text: "Read this"))),
            .unsupported(text: "Read this"))

        let videoEvent = makeEvent(
            instruction: Instruction(kind: "video", filename: "video-1.mov"))
        let url = URL(fileURLWithPath: "/tmp/video-1.mov")
        XCTAssertEqual(EventDetailView.playbackURL(
            for: videoEvent, availability: { _ in .available(url) }), url)
        for answer in [InstructionPlaybackAvailability.rejectedFilename,
                       .missingFile, .unreadableFile] {
            XCTAssertNil(EventDetailView.playbackURL(
                for: videoEvent, availability: { _ in answer }),
                "only .available yields a playable URL: \(answer)")
        }
        XCTAssertNil(EventDetailView.playbackURL(
            for: textEvent, availability: { _ in .available(url) }),
            "a text instruction has nothing to play")

        var played: URL?
        let action = EventDetailView.playAction(
            for: .video(filename: "video-1.mov", caption: nil),
            playbackURL: url,
            play: { played = $0 })
        action?("video-1.mov")
        XCTAssertEqual(played, url, "the card's action plays the resolved URL")
        XCTAssertNil(EventDetailView.playAction(
            for: .video(filename: "video-1.mov", caption: nil),
            playbackURL: nil, play: { _ in }),
            "no URL means no control, never a dead button")
        XCTAssertNil(EventDetailView.playAction(
            for: .text(text: "x"), playbackURL: url, play: { _ in }))

        let source = eventsViewSource()
        let detail = typeSource("EventDetailView", in: source)
        let body = member("var body", of: detail)
        XCTAssertTrue(body.contains(".task(id: version) { load() }"))
        XCTAssertTrue(body.contains(".fullScreenCover(item: $instructionPlayback)"))
        XCTAssertTrue(body.contains("startsWhenPresented: true"))
        XCTAssertTrue(body.contains("playback.controller.close()"))
        XCTAssertFalse(body.contains("availability"),
                       "availability is resolved in load(), never in the draw path")
        XCTAssertFalse(body.contains("instructionVideoStore"))
        XCTAssertFalse(body.contains("makeInstructionPlayback"),
                       "no controller is built before the person taps Play")

        // Design §2.10.4: under the photo and above the info card.
        let cards = member("private func detailCards(", of: detail)
        let photoAt = cards.range(of: "if let photo")?.lowerBound
        let instructionAt = cards.range(of: "instructionCard(event)")?.lowerBound
        let infoAt = cards.range(of: "VStack(alignment: .leading, spacing: 8)")?.lowerBound
        XCTAssertNotNil(photoAt)
        XCTAssertNotNil(instructionAt)
        XCTAssertNotNil(infoAt)
        if let photoAt, let instructionAt, let infoAt {
            XCTAssertTrue(photoAt < instructionAt,
                          "the instruction card sits under the photo")
            XCTAssertTrue(instructionAt < infoAt,
                          "the instruction card sits above the info card")
        }

        let card = member("private func instructionCard(", of: detail)
        XCTAssertTrue(card.contains("InstructionCardView("))
        XCTAssertTrue(card.contains("timeText: nil"),
                       "an event detail is not a fire-time surface")
        XCTAssertTrue(card.contains("imageLoader: instructionImageLoader"))
        XCTAssertTrue(card.contains("onPlay: EventDetailView.playAction("))

        let load = member("private func load()", of: detail)
        XCTAssertTrue(load.contains("coordinator.instructionPlaybackAvailability("))
        XCTAssertTrue(load.contains("owner: .event(loaded.id)"))
        XCTAssertFalse(load.contains("instructionVideoStore"),
                       "the view never reaches the store (design §2.15.2)")
        XCTAssertTrue(load.contains("EventDetailView.playbackURL("))
        XCTAssertEqual(occurrences(of: "makeInstructionPlayback", in: detail), 1,
                       "the only construction is the tap helper")
        XCTAssertTrue(member("private func playInstructionVideo(", of: detail)
            .contains("coordinator.makeInstructionPlayback(url: url, title: title)"))
    }

    /// The detail host speaks no competing label and never a filename; the
    /// shared card's labels (and the instruction's own words) are the
    /// accessible surface.
    func testEventDetailAccessibilityLabel() {
        let source = eventsViewSource()
        let detail = typeSource("EventDetailView", in: source)
        let card = member("private func instructionCard(", of: detail)
        XCTAssertFalse(card.contains(".accessibilityLabel"),
                       "the shared card labels photo/video; the host must not double-speak")
        XCTAssertFalse(card.contains("filename"),
                       "no filename is ever spoken or drawn")

        for key in [InstructionSurfaceKeys.imageAccessibility,
                    InstructionSurfaceKeys.videoAccessibility,
                    InstructionSurfaceKeys.videoPlay] {
            let english = L10n.str(key, locale: en)
            let nepali = L10n.str(key, locale: ne)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(english, key,
                              "\(key) is missing from the English catalogue")
            XCTAssertFalse(nepali.isEmpty)
            XCTAssertNotEqual(nepali, key,
                              "\(key) is missing from the Nepali catalogue")
        }

        // A text instruction's words are its accessible content.
        let textEvent = makeEvent(
            instruction: Instruction(kind: "text", text: "Take the blue pill"))
        guard case .text(let spoken) = EventDetailView.detailState(for: textEvent) else {
            return XCTFail("a text instruction renders its words")
        }
        XCTAssertEqual(spoken, "Take the blue pill")
    }

    // MARK: - T-024 source helpers

    private func eventsViewSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/EventsView.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    /// One top-level type, from its column-0 declaration to the next one.
    private func typeSource(_ name: String, in source: String) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let declarations = ["struct \(name)", "private struct \(name)",
                            "enum \(name)", "private enum \(name)",
                            "final class \(name)", "private final class \(name)"]
        guard let start = lines.firstIndex(where: { line in
            declarations.contains { line.hasPrefix($0) }
        }) else {
            XCTFail("no type named \(name) in EventsView.swift")
            return ""
        }
        let endMarkers = ["struct ", "private struct ", "enum ", "private enum ",
                          "final class ", "private final class ",
                          "extension ", "@MainActor", "#if"]
        let end = lines[(start + 1)...].firstIndex { line in
            endMarkers.contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// One member of a type source, from the marker to the next 4-space
    /// declaration. Markers are source text, never line numbers.
    private func member(_ marker: String, of source: String) -> String {
        guard let start = source.range(of: marker) else {
            XCTFail("no member \(marker)")
            return ""
        }
        let tail = source[start.lowerBound...]
        let searchStart = tail.index(tail.startIndex, offsetBy: marker.count)
        let endMarkers = ["\n    private ", "\n    static ", "\n    @",
                          "\n    func ", "\n    var ", "\n    init(",
                          "\n    let ", "\n    enum "]
        var end = tail.endIndex
        for endMarker in endMarkers {
            if let found = tail.range(of: endMarker,
                                      range: searchStart..<tail.endIndex),
               found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return String(tail[..<end])
    }

    private func branch(from start: String, to end: String,
                        in source: String) -> String {
        guard let startRange = source.range(of: start) else {
            XCTFail("missing \(start)")
            return ""
        }
        guard let endRange = source.range(
            of: end, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("missing \(end) after \(start)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

/// The EventKit seam the form's delete test drives. Only removal is
/// interesting; every other answer is empty so the service's delete path is
/// exactly the one under test.
private final class EventFormDeleteGateway: EventKitCalendarGateway {
    private(set) var removedIdentifiers: [String] = []

    var eventsAccess: CalendarAccess { .fullAccess }

    func requestFullAccess() async -> Bool { true }

    func ensureSahayakCalendar(knownIdentifier: String?) -> String? { nil }

    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] { [] }

    func fetchEvent(identifier: String) -> CalendarEventRecord? { nil }

    func createEvent(_ draft: CalendarEventDraft,
                     in calendarIdentifier: String?) -> String? { nil }

    func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool { false }

    func removeEvent(identifier: String) -> Bool {
        removedIdentifiers.append(identifier)
        return true
    }

    func removeEvents(matchingNotesFragment fragment: String) -> Int { 0 }
}
