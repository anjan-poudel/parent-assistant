import XCTest
@testable import ElderlyAssistant

/// `APNsFamilyNotifier` — the family-alert sender (caregiver
/// event-notifications task, 2026-09-13).
///
/// [MSR] T-011 made the transport honest: the provider is still the
/// unimplemented stub (no device tokens are provisioned until the relay
/// project) and it now reports that state AS DATA —
/// `.notDelivered("transport_unimplemented")` — instead of the fabricated
/// `true` it used to return. What this suite pins is the CONTRACT around
/// it: which contacts are targeted, what the per-contact results and the
/// rollup say, the PII-free envelope (`v: 1`, optional one-way
/// `entry_id_hash`), and what an event alert is allowed to put on the
/// observability bus. `success == true` may only ever be asserted against
/// a delivering transport double — never against the shipped stub.
final class FamilyNotifierTests: XCTestCase {

    private func contact(name: String = "Daughter",
                         target: Bool = true,
                         channel: NotifyChannel = .sms) -> EmergencyContact {
        EmergencyContact(id: UUID(), displayName: name, deviceToken: "token-\(name)",
                         isEmergencyContact: true, isFamilyNotificationTarget: target,
                         notifyChannel: channel)
    }

    /// Default transport is the shipped stub, so a test that does not
    /// inject one exercises the honest not-delivered path.
    private func makeNotifier(_ contacts: [EmergencyContact],
                              transport: (any PushTransport)? = nil)
        -> (APNsFamilyNotifier, RecordingObservabilityBus) {
        let bus = RecordingObservabilityBus()
        let provider: any PushTransport = transport ?? APNsProvider()
        let notifier = APNsFamilyNotifier(contacts: contacts,
                                          apnsProvider: provider,
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
        XCTAssertEqual(results.first?.success, false,
                       "the transport is unimplemented — the stub no longer fabricates a delivery")
        XCTAssertEqual(results.first?.errorCode, "transport_unimplemented",
                       "the result carries the transport's own reason code, not a generic failure")
    }

    // MARK: - Delivery honesty (FR-MSR-016, FR-MSR-018)

    /// The shipped transport cannot deliver, and the result says so — per
    /// contact, with the transport's own reason code. Nothing in this
    /// result may be read as "the caregiver was notified".
    func testNotDeliveredIsReportedPerContact() async {
        let (notifier, _) = makeNotifier([contact(name: "Daughter"), contact(name: "Son")])

        let results = await notifier.notifyAll(alertType: .intakeRecorded, at: Date(),
                                               context: eventContext())

        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertFalse(result.success,
                           "an unimplemented transport is never a success")
            XCTAssertEqual(result.errorCode, "transport_unimplemented",
                           "the honest reason travels with every not-delivered result")
        }
        XCTAssertEqual(results.deliveryRollup, .noneDelivered,
                       "not delivered is reported as not delivered, never rounded up")
    }

    /// Two contacts, two channels, one delivery: the rollup is PARTIAL —
    /// its own answer, never rounded up to success. The contact that was
    /// reached records success with its channel; the one that was not
    /// records the failure with its channel and error code.
    func testPartialRollupIsPartialNotSuccess() async {
        let daughter = contact(name: "Daughter", channel: .whatsApp)
        let son = contact(name: "Son", channel: .sms)
        let transport = RecordingPushTransport()
        transport.outcomesByToken = [daughter.deviceToken: .delivered]
        let (notifier, _) = makeNotifier([daughter, son], transport: transport)

        let results = await notifier.notifyAll(alertType: .missedMedication, at: Date(),
                                               context: eventContext())

        XCTAssertEqual(results.deliveryRollup, .partial,
                       "a mixed set is partial — never success")
        XCTAssertEqual(results.filter { $0.success }.count, 1)
        XCTAssertEqual(results.filter { !$0.success }.count, 1)

        let delivered = results.first { $0.success }
        XCTAssertEqual(delivered?.contactIdHash, IdHashing.shortHash(of: daughter.id))
        XCTAssertEqual(delivered?.channel, NotifyChannel.whatsApp.rawValue,
                       "the successful contact's result records its channel")
        XCTAssertNil(delivered?.errorCode)

        let failed = results.first { !$0.success }
        XCTAssertEqual(failed?.contactIdHash, IdHashing.shortHash(of: son.id))
        XCTAssertEqual(failed?.channel, NotifyChannel.sms.rawValue,
                       "the failed contact's result records the channel it was attempted on")
        XCTAssertEqual(failed?.errorCode, "transport_unimplemented")

        XCTAssertFalse(results.allSatisfy { $0.success },
                       "partial is never rounded up to success")
    }

    /// The `family_event_alerted` record carries the outcome of THIS
    /// delivery — `failed` with the transport's reason code, or `success`
    /// only when a push actually landed. It used to say `"success"`
    /// regardless.
    func testEmitEventAlertedCarriesTheHonestOutcome() async {
        let (undeliveredNotifier, undeliveredBus) = makeNotifier([contact(channel: .whatsApp)])

        _ = await undeliveredNotifier.notifyAll(alertType: .eventReminder, at: Date(),
                                                context: eventContext())

        let failed = undeliveredBus.events(named: "family_event_alerted").first
        XCTAssertEqual(failed?.outcome, "failed",
                       "the stub did not deliver — the record says so")
        XCTAssertEqual(failed?.errorCode, "transport_unimplemented")

        let transport = RecordingPushTransport()
        transport.outcomesByToken = ["token-Daughter": .delivered]
        let (deliveredNotifier, deliveredBus) = makeNotifier([contact(name: "Daughter")],
                                                             transport: transport)

        _ = await deliveredNotifier.notifyAll(alertType: .eventReminder, at: Date(),
                                              context: eventContext())

        let delivered = deliveredBus.events(named: "family_event_alerted").first
        XCTAssertEqual(delivered?.outcome, "success",
                       "a delivered push is the only thing that may be recorded as success")
        XCTAssertNil(delivered?.errorCode)
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

    // MARK: - The wire (FR-MSR-017, D9)

    /// D9: every alert type's envelope carries the additive version key.
    /// The shape is asserted for the whole taxonomy in one place so a new
    /// alert type cannot ship without it.
    func testPayloadCarriesVersionOne() {
        let (notifier, _) = makeNotifier([contact()])

        for alertType in Self.pinnedAlertWireValues.map({ $0.alertType }) {
            let payload = notifier.buildPayload(alertType: alertType,
                                                timestamp: Date(),
                                                entryIdHash: IdHashing.shortHash(of: UUID()))

            XCTAssertEqual(payload["v"] as? Int, 1,
                           "\(alertType) must carry the version key (D9)")
        }
    }

    /// `entry_id_hash` is supplied ONLY where the design pins it — the four
    /// medication significant events, from the in-memory context — and
    /// omitted everywhere else, including when no context is supplied. The
    /// value is the one-way hash, never a UUID.
    func testPayloadCarriesEntryIdHashOnlyWhenSupplied() async {
        let transport = RecordingPushTransport()
        let (notifier, _) = makeNotifier([contact()], transport: transport)
        let context = eventContext()

        let carrying: [FamilyAlertType] = [.missedMedication, .possibleDoubleDose,
                                           .intakeRecorded, .escalationStarted]
        let notCarrying: [FamilyAlertType] = [.emergencyCall, .healthMonitoringInterrupted,
                                              .configurationUpdateApplied, .inactivityAlert,
                                              .eventReminder]
        XCTAssertEqual(Set(carrying + notCarrying).count, Self.pinnedAlertWireValues.count,
                       "every pinned alert type is classified here — a new type must be too")

        for alertType in carrying {
            _ = await notifier.notifyAll(alertType: alertType, at: Date(), context: context)
            let sent = lastSentPayload(transport)
            XCTAssertEqual(sent["entry_id_hash"] as? String, context.eventIdHash,
                           "\(alertType) is a medication significant event: it carries the hash")
            XCTAssertFalse(sent.keys.contains("event_id_hash"),
                           "the wire spelling is entry_id_hash — the bus spelling never rides it")
            XCTAssertEqual(Set(sent.keys),
                           ["aps", "alert_type", "timestamp", "v", "entry_id_hash"],
                           "\(alertType): the envelope carries aps, alert_type, timestamp and v, "
                           + "plus the hash where pinned — nothing else")
        }

        for alertType in notCarrying {
            _ = await notifier.notifyAll(alertType: alertType, at: Date(), context: context)
            let sent = lastSentPayload(transport)
            XCTAssertFalse(sent.keys.contains("entry_id_hash"),
                           "\(alertType) may not carry an entry_id_hash, even with a context in hand")
            XCTAssertEqual(Set(sent.keys), ["aps", "alert_type", "timestamp", "v"],
                           "\(alertType): the envelope carries aps, alert_type, timestamp and v only")
        }

        // No context means no hash — the key is omitted, never substituted.
        _ = await notifier.notifyAll(alertType: .missedMedication, at: Date(), context: nil)
        XCTAssertFalse(lastSentPayload(transport).keys.contains("entry_id_hash"))

        // The direct seam agrees with the sent payload.
        let bare = notifier.buildPayload(alertType: .missedMedication, timestamp: Date(),
                                         entryIdHash: nil)
        XCTAssertNil(bare["entry_id_hash"])
    }

    /// The envelope guard: no name, dose, title, label or photo key ever
    /// appears (nested dictionaries included), and no string value carries
    /// the in-memory title — the one thing `FamilyAlertContext` holds that
    /// must never reach a wire.
    func testPayloadCarriesNoNameDoseOrTitleKeys() {
        let title = "Amlodipine 5mg"
        let context = eventContext(title: title)
        let (notifier, _) = makeNotifier([contact()])

        let payload = notifier.buildPayload(alertType: .missedMedication,
                                            timestamp: Date(),
                                            entryIdHash: context.eventIdHash)

        let forbiddenKeyFragments = ["name", "dose", "title", "label", "photo"]
        for key in Self.allKeys(in: payload) {
            for fragment in forbiddenKeyFragments {
                XCTAssertFalse(key.lowercased().contains(fragment),
                               "the wire carries no \(fragment) key: \(key)")
            }
        }

        for value in Self.allStringValues(in: payload) {
            XCTAssertFalse(value.contains(title),
                           "the title must never reach the wire: \(value)")
            XCTAssertFalse(value.contains("Amlodipine"),
                           "no fragment of the title may reach the wire: \(value)")
        }

        // No photo or binary content either — nothing on the wire is a blob.
        for value in Self.allValues(in: payload) {
            XCTAssertFalse(value is Data, "no photo content rides the wire")
        }

        // The only identity the wire carries is the one-way hash.
        XCTAssertEqual(payload["entry_id_hash"] as? String, context.eventIdHash)
    }

    /// `eventReminder` keeps its shipped shape — `aps`, `alert_type`,
    /// `timestamp` — with `v: 1` as the only additive key, and no
    /// `entry_id_hash`: the context stays in memory for this wire type.
    func testEventReminderPayloadShapeUnchangedApartFromVersion() {
        let (notifier, _) = makeNotifier([contact()])

        let payload = notifier.buildPayload(alertType: .eventReminder,
                                            timestamp: Date(),
                                            entryIdHash: nil)

        XCTAssertEqual(Set(payload.keys), ["aps", "alert_type", "timestamp", "v"],
                       "the shipped eventReminder envelope plus the additive version key")
        XCTAssertEqual(Set(payload.keys).subtracting(["v"]),
                       ["aps", "alert_type", "timestamp"],
                       "nothing but the version key was added")
        let aps = payload["aps"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(aps.keys), ["alert", "sound", "badge", "category"],
                       "the aps dictionary is unchanged")
        XCTAssertNil(payload["entry_id_hash"])
    }

    /// Every key in the envelope, nested dictionaries included — the guard
    /// above must see `aps`'s keys too, not just the top level.
    private static func allKeys(in payload: [String: Any]) -> [String] {
        var keys: [String] = []
        for (key, value) in payload {
            keys.append(key)
            if let nested = value as? [String: Any] {
                keys.append(contentsOf: allKeys(in: nested))
            }
        }
        return keys
    }

    /// Every String value in the envelope, nested dictionaries included.
    private static func allStringValues(in payload: [String: Any]) -> [String] {
        var values: [String] = []
        for (_, value) in payload {
            if let nested = value as? [String: Any] {
                values.append(contentsOf: allStringValues(in: nested))
            } else if let string = value as? String {
                values.append(string)
            }
        }
        return values
    }

    /// Every value in the envelope, nested dictionaries included.
    private static func allValues(in payload: [String: Any]) -> [Any] {
        var values: [Any] = []
        for (_, value) in payload {
            values.append(value)
            if let nested = value as? [String: Any] {
                values.append(contentsOf: allValues(in: nested))
            }
        }
        return values
    }

    /// The payload the transport was last asked to send. Fails the test if
    /// nothing was sent, so a payload assertion can never pass vacuously
    /// against an empty dictionary.
    private func lastSentPayload(_ transport: RecordingPushTransport,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) -> [String: Any] {
        guard let payload = transport.sentPayloads.last else {
            XCTFail("no payload was sent to the transport", file: file, line: line)
            return [:]
        }
        return payload
    }

    // MARK: - Wire type

    /// Every alert type's wire raw value, pinned verbatim — the shipped
    /// seven, plus the two medication significant events
    /// (`intakeRecorded`, `escalationStarted`) appended by [MSR] T-003
    /// (FR-MSR-015, FR-MSR-017). The raw values ARE the wire contract:
    /// a case renumbered or renamed ahead of a shipped one silently
    /// changes what an already-deployed family alert means.
    private static let pinnedAlertWireValues: [(alertType: FamilyAlertType,
                                                rawValue: String)] = [
        (.emergencyCall, "emergencyCall"),
        (.missedMedication, "missedMedication"),
        (.healthMonitoringInterrupted, "healthMonitoringInterrupted"),
        (.configurationUpdateApplied, "configurationUpdateApplied"),
        (.possibleDoubleDose, "possibleDoubleDose"),
        (.inactivityAlert, "inactivityAlert"),
        (.eventReminder, "eventReminder"),
        // [MSR T-003] Appended to the taxonomy — appended ONLY, so no
        // shipped value above moves.
        (.intakeRecorded, "intakeRecorded"),
        (.escalationStarted, "escalationStarted")
    ]

    /// One wire type covers all three event kinds — the kind travels in
    /// the in-memory context and in the local bus record, never in the
    /// envelope, so the payload keeps its `alert_type`-only shape.
    func testEventReminderWireValueIsStable() throws {
        let encoded = try JSONEncoder().encode(FamilyAlertType.eventReminder)

        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"eventReminder\"")
    }

    /// The stability list, extended at [MSR] T-003 with the two new
    /// taxonomy cases (FR-MSR-015's "appended, not renumbered" edge):
    /// every shipped raw value still encodes to its own literal, and
    /// each literal decodes back to the case it names — so a payload
    /// written by any build of the app keeps its meaning.
    func testLegacyAlertWireValuesAreUnchanged() throws {
        let encoded = try JSONEncoder().encode(FamilyAlertType.missedMedication)

        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"missedMedication\"",
                       "adding a case must not renumber or rename the existing wire types")

        for (alertType, pinned) in Self.pinnedAlertWireValues {
            let data = try JSONEncoder().encode(alertType)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(pinned)\"",
                           "\(alertType) must keep its pinned wire value")

            let decoded = try JSONDecoder().decode(FamilyAlertType.self, from: data)
            XCTAssertEqual(decoded, alertType,
                           "the wire value must decode back to the case that wrote it")
        }
    }

    /// Every alert type has a family-facing body — the new wire type
    /// included — in both shipped languages. `L10n.str` answers with the
    /// KEY itself when the catalog has no entry, so "resolved to
    /// something other than the key" is exactly "the catalog has it".
    func testEveryAlertTypeHasABodyInBothLanguages() {
        let keys = ["family.alertEmergency", "family.alertMissedMedication",
                    "family.alertHealthMonitoringInterrupted",
                    "family.alertConfigurationApplied", "family.alertPossibleDoubleDose",
                    "family.alertInactivity", "family.alertEventReminder",
                    // [MSR T-003] The two appended significant events
                    // (FR-MSR-015) — every alert type has a family-facing
                    // body in both shipped languages.
                    "family.alertIntakeRecorded", "family.alertEscalationStarted"]

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

// MARK: - Push transport double

/// The delivered half of the rollup, which the shipped stub cannot produce
/// by design. It records every payload it is asked to send, so the wire
/// rules are asserted at the exact seam the notifier sends through.
///
/// A token with no recorded outcome is NOT delivered — the honest default,
/// so a double can never invent a delivery a test did not ask for.
/// `NotifyChannelTests` reuses this double for the per-contact rollup.
final class RecordingPushTransport: PushTransport {

    /// Outcome per device token.
    var outcomesByToken: [String: PushOutcome] = [:]

    private(set) var sentPayloads: [[String: Any]] = []
    private(set) var sentTokens: [String] = []

    func sendPush(payload: [String: Any], deviceToken: String) async -> PushOutcome {
        sentPayloads.append(payload)
        sentTokens.append(deviceToken)
        return outcomesByToken[deviceToken] ?? .notDelivered(reason: "transport_unimplemented")
    }
}
