import XCTest
@testable import ElderlyAssistant

/// `APNsFamilyNotifier` — the family-alert sender (caregiver
/// event-notifications task, 2026-09-13).
///
/// The transport is still the stub it always was (no device tokens are
/// provisioned until the relay project), so what is testable — and what
/// this suite pins — is the CONTRACT around it: which contacts are
/// targeted, what the results say, and what an event alert is allowed to
/// put on the observability bus.
final class FamilyNotifierTests: XCTestCase {

    private func contact(name: String = "Daughter",
                         target: Bool = true,
                         channel: NotifyChannel = .sms) -> EmergencyContact {
        EmergencyContact(id: UUID(), displayName: name, deviceToken: "token-\(name)",
                         isEmergencyContact: true, isFamilyNotificationTarget: target,
                         notifyChannel: channel)
    }

    private func makeNotifier(_ contacts: [EmergencyContact])
        -> (APNsFamilyNotifier, RecordingObservabilityBus) {
        let bus = RecordingObservabilityBus()
        let notifier = APNsFamilyNotifier(contacts: contacts,
                                          apnsProvider: APNsProvider(),
                                          observabilityBus: bus)
        return (notifier, bus)
    }

    private func eventContext(title: String = "Amlodipine",
                              kind: EventNotifyKind = .medicationReminder)
        -> FamilyAlertContext {
        FamilyAlertContext(kind: kind,
                           eventIdHash: IdHashing.shortHash(of: UUID()),
                           eventTitle: title,
                           fireAt: Date())
    }

    // MARK: - Targeting

    func testOnlyFamilyNotificationTargetsAreNotified() async {
        let (notifier, _) = makeNotifier([contact(name: "Daughter", target: true),
                                          contact(name: "Neighbour", target: false)])

        let results = await notifier.notifyAll(alertType: .emergencyCall, at: Date())

        XCTAssertEqual(results.count, 1, "a non-target contact is filtered at construction")
    }

    func testUpdateContactsReplacesAndRefiltersTheList() async {
        let (notifier, _) = makeNotifier([contact(name: "Daughter")])

        notifier.updateContacts([contact(name: "Son", target: false),
                                 contact(name: "Aunt", target: true)])
        let results = await notifier.notifyAll(alertType: .missedMedication, at: Date())

        XCTAssertEqual(results.count, 1)
    }

    func testResultHashesTheContactIdNotTheName() async {
        let daughter = contact(name: "Daughter")
        let (notifier, _) = makeNotifier([daughter])

        let results = await notifier.notifyAll(alertType: .emergencyCall, at: Date())

        XCTAssertEqual(results.first?.contactIdHash, IdHashing.shortHash(of: daughter.id))
        XCTAssertEqual(results.first?.success, true, "the APNs provider is still the succeeding stub")
        XCTAssertNil(results.first?.errorCode)
    }

    // MARK: - Legacy alerts (no context)

    /// The pre-existing alerts (emergency, missed dose, double dose)
    /// behave exactly as before this seam existed: no channel modeled,
    /// no event on the bus.
    func testLegacyAlertCarriesNoChannelAndEmitsNothing() async {
        let (notifier, bus) = makeNotifier([contact(channel: .whatsApp)])

        let results = await notifier.notifyAll(alertType: .missedMedication, at: Date())

        XCTAssertNil(results.first?.channel,
                     "delivery surface was never modelled for the legacy alerts")
        XCTAssertFalse(bus.contains("family_event_alerted"))
        XCTAssertTrue(bus.events.isEmpty)
    }

    /// The 2-arg form is a real entry point (the protocol extension and
    /// this class forward to the 3-arg form with a nil context) — it must
    /// keep behaving as the legacy call.
    func testTwoArgumentEntryPointStillWorks() async {
        let (notifier, bus) = makeNotifier([contact()])

        let results = await notifier.notifyAll(alertType: .inactivityAlert, at: Date())

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.channel)
        XCTAssertTrue(bus.events.isEmpty)
    }

    // MARK: - Event alerts (with context)

    func testEventAlertResultCarriesTheContactsNotifyChannel() async {
        let (notifier, _) = makeNotifier([contact(channel: .messenger)])

        let results = await notifier.notifyAll(alertType: .eventReminder, at: Date(),
                                               context: eventContext())

        XCTAssertEqual(results.first?.channel, NotifyChannel.messenger.rawValue)
    }

    /// One bus event per CONTACT: the channel is a property of the
    /// delivery, so two caregivers on two channels produce two records —
    /// "the alert went out over WhatsApp" is only true per recipient.
    func testEventAlertEmitsOneChannelRecordPerContact() async {
        let (notifier, bus) = makeNotifier([contact(name: "Daughter", channel: .whatsApp),
                                            contact(name: "Son", channel: .sms)])
        let context = eventContext(kind: .routineReminder)

        _ = await notifier.notifyAll(alertType: .eventReminder, at: Date(), context: context)

        let emitted = bus.events(named: "family_event_alerted")
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(Set(emitted.compactMap { $0.metadata["channel"] }),
                       [NotifyChannel.whatsApp.rawValue, NotifyChannel.sms.rawValue])
    }

    func testEventAlertRecordIsPiiFreeAndNamesTheKind() async {
        let title = "Dr Sharma Cardiology"
        let (notifier, bus) = makeNotifier([contact(channel: .whatsApp)])
        let context = eventContext(title: title, kind: .calendarEvent)

        _ = await notifier.notifyAll(alertType: .eventReminder, at: Date(), context: context)

        guard let event = bus.events(named: "family_event_alerted").first else {
            return XCTFail("expected a family_event_alerted record")
        }
        XCTAssertEqual(event.metadata["alert_type"], FamilyAlertType.eventReminder.rawValue)
        XCTAssertEqual(event.metadata["kind"], EventNotifyKind.calendarEvent.rawValue)
        XCTAssertEqual(event.metadata["channel"], NotifyChannel.whatsApp.rawValue)
        XCTAssertEqual(event.metadata["event_id_hash"], context.eventIdHash)
        XCTAssertEqual(event.component, "family_notifier")
        for (_, value) in event.metadata {
            XCTAssertFalse(value.contains(title),
                           "the event title must never be a metadata value: \(value)")
        }
    }

    /// The channel is derived from the contact, so an event alert to a
    /// contact constructed without one still rides the universal
    /// fallback rather than reporting nothing.
    func testEventAlertDefaultsToSMSForAChannelLessContact() async {
        let legacy = EmergencyContact(id: UUID(), displayName: "Daughter",
                                      deviceToken: "token", isEmergencyContact: true,
                                      isFamilyNotificationTarget: true)
        XCTAssertEqual(legacy.notifyChannel, .sms, "the field defaults to the universal fallback")
        let (notifier, bus) = makeNotifier([legacy])

        let results = await notifier.notifyAll(alertType: .eventReminder, at: Date(),
                                               context: eventContext())

        XCTAssertEqual(results.first?.channel, NotifyChannel.sms.rawValue)
        XCTAssertEqual(bus.events(named: "family_event_alerted").first?.metadata["channel"],
                       NotifyChannel.sms.rawValue)
    }

    // MARK: - Wire type

    /// One wire type covers all three event kinds — the kind travels in
    /// the in-memory context and in the local bus record, never in the
    /// envelope, so the payload keeps its `alert_type`-only shape.
    func testEventReminderWireValueIsStable() throws {
        let encoded = try JSONEncoder().encode(FamilyAlertType.eventReminder)

        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"eventReminder\"")
    }

    func testLegacyAlertWireValuesAreUnchanged() throws {
        let encoded = try JSONEncoder().encode(FamilyAlertType.missedMedication)

        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"missedMedication\"",
                       "adding a case must not renumber or rename the existing wire types")
    }

    /// Every alert type has a family-facing body — the new wire type
    /// included — in both shipped languages. `L10n.str` answers with the
    /// KEY itself when the catalog has no entry, so "resolved to
    /// something other than the key" is exactly "the catalog has it".
    func testEveryAlertTypeHasABodyInBothLanguages() {
        let keys = ["family.alertEmergency", "family.alertMissedMedication",
                    "family.alertHealthMonitoringInterrupted",
                    "family.alertConfigurationApplied", "family.alertPossibleDoubleDose",
                    "family.alertInactivity", "family.alertEventReminder"]

        for key in keys {
            for locale in [Locale(identifier: "en"), Locale(identifier: "ne")] {
                let body = L10n.str(key, locale: locale)
                XCTAssertNotEqual(body, key,
                                  "\(key) is missing from the \(locale.identifier) catalog")
                XCTAssertFalse(body.isEmpty)
            }
        }
    }
}
