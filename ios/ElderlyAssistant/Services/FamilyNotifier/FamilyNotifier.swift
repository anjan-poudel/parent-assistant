import Foundation

// MARK: - FamilyNotifier Protocol (L2 §5.5)

protocol FamilyNotifierProtocol {
    func notifyAll(alertType: FamilyAlertType, at timestamp: Date) async -> [NotificationResult]

    /// Context-carrying form (caregiver event-notifications task,
    /// 2026-09-13): `context` describes WHICH event fired, for the one
    /// wire type `FamilyAlertType.eventReminder` that covers event
    /// alerts of every kind. Legacy alerts pass nil — the protocol
    /// extension below supplies that default, so every existing call
    /// site and conformer compiles unchanged.
    ///
    /// A REQUIREMENT, not an extension-only member: `CommandRouter` and
    /// the schedulers hold the notifier as a protocol reference, and an
    /// extension-only method would bind statically — a conformer's own
    /// implementation could never be reached (same trap documented on
    /// `VoiceCommandCoordinating.canAnswerLiveQuestionsFromWeb`).
    func notifyAll(alertType: FamilyAlertType, at timestamp: Date,
                   context: FamilyAlertContext?) async -> [NotificationResult]
}

extension FamilyNotifierProtocol {
    /// Default: this conformer does not distinguish event contexts (or
    /// this is a legacy alert) — forward to the context-free form, i.e.
    /// behave exactly as before this seam existed.
    func notifyAll(alertType: FamilyAlertType, at timestamp: Date,
                   context: FamilyAlertContext?) async -> [NotificationResult] {
        await notifyAll(alertType: alertType, at: timestamp)
    }
}

// MARK: - Event context (in-memory only)

/// What fired, for an `eventReminder` alert (caregiver
/// event-notifications task, 2026-09-13).
///
/// **No-PII tension, documented on purpose.** The app's constitution
/// bans personal content from the wire: the alert envelope carries
/// `{v:1, alert_type, timestamp}` and nothing else, which is why
/// `missedMedication` deliberately drops the medication name. An event
/// alert is different in kind — "your father's walk reminder fired" is
/// useless to a caregiver without knowing WHICH event — so this type
/// exists to carry `eventTitle` and `fireAt` AT ALL. It is
/// **in-memory only**: it is never encoded into a payload, never
/// persisted, and never reaches the observability bus (the
/// `family_event_alerted` event records `event_id_hash` and the kind,
/// never the title).
///
/// The future relay/transport project (docs/family-notifier-e2e-
/// implementation-plan.md) MUST re-litigate title-on-wire explicitly —
/// whether the caregiver app receives the event title, an entry id it
/// resolves against its own synced copy, or a coarse category. Until
/// that decision is made, the honest state is: context is prepared and
/// recorded locally (title in memory only, never encoded) and delivery
/// reports itself honestly — the APNs transport is still the unimplemented
/// stub it always was, and since [MSR] T-011 it says so in data
/// (`.notDelivered("transport_unimplemented")`, FR-MSR-016) instead of
/// returning a fabricated success.
struct FamilyAlertContext: Equatable {
    /// Which firing system produced the alert.
    let kind: EventNotifyKind
    /// Short hash of the firing entry/occurrence/event id — the
    /// PII-free handle a log reader (or the future relay) correlates
    /// on. Same hashing rule as every other id on the bus
    /// (`IdHashing.shortHash`).
    let eventIdHash: String
    /// The event's display title, for the caregiver-facing message a
    /// future transport will compose. Never logged, never encoded.
    let eventTitle: String
    /// When the reminder was scheduled to fire (not when it was
    /// observed — those differ when the app was backgrounded).
    let fireAt: Date
}

// MARK: - Delivery rollup (FR-MSR-016)

/// The honest rollup of one `notifyAll` fan-out.
///
/// Partial is its own answer: a mixed set is never rounded up to a
/// delivery, and an empty set is never a delivery either (the vacuous
/// truth `allSatisfy` walks into). Before this seam existed the only
/// signal was the stub provider's fabricated success, so "some caregivers
/// were reached" and "none were" looked identical — the false success
/// FR-MSR-016 forbids.
enum FamilyDeliveryRollup: Equatable {
    /// No contact was targeted — nothing was attempted, and nothing
    /// attempted is not a delivery.
    case noRecipients
    /// Every attempted delivery reached its contact.
    case deliveredAll
    /// Some contacts were reached and some were not.
    case partial
    /// No attempt reached its contact.
    case noneDelivered
}

extension Array where Element == NotificationResult {
    /// The per-contact result set read as one outcome. `deliveredAll` is
    /// the only case that may be described as every caregiver notified
    /// (FR-MSR-016).
    var deliveryRollup: FamilyDeliveryRollup {
        if isEmpty { return .noRecipients }
        let delivered = filter { $0.success }.count
        if delivered == 0 { return .noneDelivered }
        if delivered == count { return .deliveredAll }
        return .partial
    }
}

// MARK: - iOS APNs Implementation

#if os(iOS)
/// Family-alert sender over the push transport.
///
/// Delivery honesty (FR-MSR-016, [MSR] T-011): the transport is the
/// unimplemented stub, so every result this class returns says what
/// actually happened — `success: false` with the transport's own reason
/// code, and a mixed fan-out rolling up as `.partial`. No string in this
/// file describes a contact as notified when the outcome was not
/// delivered.
final class APNsFamilyNotifier: FamilyNotifierProtocol {

    private var contacts: [EmergencyContact]
    /// The transport, held as the seam rather than the concrete stub: the
    /// delivered half of the rollup is unreachable through `APNsProvider`
    /// (it is unimplemented by design), so a test supplies it here.
    private let apnsProvider: any PushTransport
    /// The app's observability sink. Required (no default): the whole
    /// point of `family_event_alerted` is that the event-alert path is
    /// observable, and a silent default would hide it — the composition
    /// root always has a bus in hand.
    private let observabilityBus: ObservabilityBus

    /// Locale the family-facing alert bodies resolve against (spec §3.2).
    /// Kept in sync with the app language by `AppCoordinator`; the English
    /// default matches the legacy hardcoded strings.
    var locale: Locale = Locale(identifier: "en")

    init(contacts: [EmergencyContact],
         apnsProvider: any PushTransport = APNsProvider(),
         observabilityBus: ObservabilityBus) {
        self.contacts = contacts.filter { $0.isFamilyNotificationTarget }
        self.apnsProvider = apnsProvider
        self.observabilityBus = observabilityBus
    }

    /// Replaces the contact list — called by `AppCoordinator` when the
    /// Settings family-contacts section changes. Until the broker relay
    /// provisions device tokens (review C6), pushes have no destination;
    /// the list is still kept real so the wiring is in place.
    func updateContacts(_ newContacts: [EmergencyContact]) {
        contacts = newContacts.filter { $0.isFamilyNotificationTarget }
    }

    func notifyAll(alertType: FamilyAlertType, at timestamp: Date) async -> [NotificationResult] {
        await notifyAll(alertType: alertType, at: timestamp, context: nil)
    }

    func notifyAll(alertType: FamilyAlertType, at timestamp: Date,
                   context: FamilyAlertContext?) async -> [NotificationResult] {
        var results: [NotificationResult] = []

        for contact in contacts {
            let payload = buildPayload(alertType: alertType,
                                       timestamp: timestamp,
                                       entryIdHash: entryIdHash(for: alertType,
                                                                context: context))

            let outcome = await apnsProvider.sendPush(
                payload: payload,
                deviceToken: contact.deviceToken
            )

            // The result carries what actually happened, not what was
            // hoped for (FR-MSR-016): an unimplemented transport is a
            // `false` success with its own reason code — never the
            // fabricated `true` the stub used to return, and never the
            // generic "apns_delivery_failed" that hid the real reason.
            let result = NotificationResult(
                contactIdHash: idHash(contact.id),
                success: outcome.isDelivered,
                errorCode: outcome.errorCode,
                channel: context == nil ? nil : contact.notifyChannel.rawValue
            )
            results.append(result)

            // Event alerts are the one place a KIND and a CHANNEL are
            // worth recording: the alert_type alone cannot say whether a
            // medication or a calendar event fired, and the delivery
            // surface is the thing the caregiver-notification feature is
            // actually about. The event title never appears here (C9).
            if let context {
                emitEventAlerted(alertType: alertType,
                                 context: context,
                                 channel: contact.notifyChannel,
                                 outcome: outcome)
            }
        }

        // Partial delivery is acceptable, and it is reported AS partial:
        // the per-contact results above are the record, and the
        // `family_event_alerted` event carries the honest outcome. This
        // debug aid keeps the not-delivered count visible without claiming
        // any delivery (FR-MSR-016) — counts only, never contact identity,
        // and never compiled into Release (NFR-MSR-002: the feature's log
        // surfaces are the sanitised observability bus).
        #if DEBUG
        let notDeliveredCount = results.filter { !$0.success }.count
        if notDeliveredCount > 0 {
            print("[FamilyNotifier] \(notDeliveredCount)/\(results.count) alerts not delivered")
        }
        #endif

        return results
    }

    /// Which alert types may carry `entry_id_hash` (design-l2 §C10, D9):
    /// the four medication significant events and nothing else. The
    /// `eventReminder` type and the legacy alerts keep their shipped
    /// shape — their context stays in memory, so an event's identity never
    /// reaches the wire.
    private static let medicationSignificantEvents: Set<FamilyAlertType> = [
        .missedMedication, .possibleDoubleDose, .intakeRecorded, .escalationStarted
    ]

    /// The one-way correlation handle a payload may carry, or nil where
    /// the design pins none. `context` is the only source: a
    /// significant-event call that supplies no context gets no hash — the
    /// key is omitted, never filled with a substitute.
    private func entryIdHash(for alertType: FamilyAlertType,
                             context: FamilyAlertContext?) -> String? {
        Self.medicationSignificantEvents.contains(alertType) ? context?.eventIdHash : nil
    }

    /// The APNs envelope (FR-MSR-017, D9). Keys: `aps`, `v`, `alert_type`,
    /// `timestamp`, and `entry_id_hash` ONLY when one is supplied. No
    /// medication name, dose, label text or title on this wire, ever.
    ///
    /// Internal rather than private on purpose: this is the exact seam
    /// `notifyAll` sends through, so the wire rules are asserted against
    /// the payload that would actually leave the device.
    func buildPayload(alertType: FamilyAlertType,
                      timestamp: Date,
                      entryIdHash: String?) -> [String: Any] {
        var envelope: [String: Any] = [
            "aps": [
                "alert": alertBody(for: alertType),
                "sound": alertType == .emergencyCall ? "critical-alert.aiff" : "default",
                "badge": 1,
                "category": "FAMILY_ALERT"
            ]
        ]

        // Additive version key (D9). The envelope stays v:1: the optional
        // `entry_id_hash` is additive on a key set no deployed consumer
        // reads yet (the transport is unimplemented), recorded as the
        // honest state to be revisited at transport landing.
        envelope["v"] = 1
        // Payload contains alert type + timestamp only (no PII, no health values)
        envelope["alert_type"] = alertType.rawValue
        envelope["timestamp"] = ISO8601DateFormatter().string(from: timestamp)
        // Hash-only, and only where the design pins it (the four
        // medication significant events). One-way `IdHashing.shortHash`,
        // never a UUID, never a name or a dose.
        if let entryIdHash {
            envelope["entry_id_hash"] = entryIdHash
        }

        return envelope
    }

    private func alertBody(for alertType: FamilyAlertType) -> String {
        switch alertType {
        case .emergencyCall:
            return L10n.str("family.alertEmergency", locale: locale)
        case .missedMedication:
            return L10n.str("family.alertMissedMedication", locale: locale)
        case .healthMonitoringInterrupted:
            return L10n.str("family.alertHealthMonitoringInterrupted", locale: locale)
        case .configurationUpdateApplied:
            return L10n.str("family.alertConfigurationApplied", locale: locale)
        case .possibleDoubleDose:
            return L10n.str("family.alertPossibleDoubleDose", locale: locale)
        case .inactivityAlert:
            return L10n.str("family.alertInactivity", locale: locale)
        case .eventReminder:
            return L10n.str("family.alertEventReminder", locale: locale)
        case .intakeRecorded:
            return L10n.str("family.alertIntakeRecorded", locale: locale)
        case .escalationStarted:
            return L10n.str("family.alertEscalationStarted", locale: locale)
        }
    }

    /// PII-free record of one event alert: the wire alert type, the app
    /// kind, the channel the push rode, and the hashed event id. The
    /// event TITLE is never a metadata value (constitution C9).
    ///
    /// The outcome is the per-contact result of THIS delivery
    /// (FR-MSR-016): `success` / `failed` with the transport's own
    /// `error_code` — not the hardcoded `"success"` this event used to
    /// carry regardless of what happened.
    private func emitEventAlerted(alertType: FamilyAlertType,
                                  context: FamilyAlertContext,
                                  channel: NotifyChannel,
                                  outcome: PushOutcome) {
        observabilityBus.emit(ObservabilityEvent(
            component: "family_notifier",
            eventType: "family_event_alerted",
            durationMs: nil,
            outcome: outcome.isDelivered ? "success" : "failed",
            errorCode: outcome.errorCode,
            metadata: [
                "alert_type": alertType.rawValue,
                "kind": context.kind.rawValue,
                "channel": channel.rawValue,
                "event_id_hash": context.eventIdHash
            ]
        ))
    }

    private func idHash(_ id: UUID) -> String {
        IdHashing.shortHash(of: id)
    }
}

// MARK: - Push transport (IF-19)

/// What a push attempt actually did (IF-19).
///
/// The shipped transport is unimplemented, so the only honest outcome it
/// can report is `.notDelivered`. The type exists so that state is DATA a
/// caller and a test can see — the boolean the stub used to return could
/// only ever say "yes".
enum PushOutcome: Equatable {
    case delivered
    case notDelivered(reason: String)

    /// What a `NotificationResult` reports as `success` (FR-MSR-016).
    /// Delivery is the only thing that may be reported as delivered.
    var isDelivered: Bool {
        switch self {
        case .delivered: return true
        case .notDelivered: return false
        }
    }

    /// The failure code a result and the `family_event_alerted` event
    /// carry, or nil when the push was delivered.
    var errorCode: String? {
        switch self {
        case .delivered: return nil
        case .notDelivered(let reason): return reason
        }
    }
}

/// The narrow seam `APNsFamilyNotifier` sends through.
///
/// `APNsProvider` is the only production conformer; the protocol exists so
/// a test can supply the delivered half of the rollup (unreachable through
/// the deliberately-unimplemented stub) and observe the exact payload the
/// notifier would send. It adds no egress of its own.
protocol PushTransport {
    func sendPush(payload: [String: Any], deviceToken: String) async -> PushOutcome
}

// MARK: - APNs Provider Stub

final class APNsProvider: PushTransport {
    /// Reports what actually happened to a push attempt.
    ///
    /// The transport is NOT implemented — that is inherited, tracked work
    /// (docs/family-notifier-e2e-implementation-plan.md) — so this returns
    /// `.notDelivered(reason: "transport_unimplemented")` and performs no
    /// network work. It no longer prints "Push sent…" (which claimed a
    /// delivery that never happened) or returns a fabricated `true`
    /// (FR-MSR-016). In production: URLSession with HTTP/2 to
    /// api.push.apple.com, JWT token auth, pinned certificate; when that
    /// lands the provider is swapped and this honesty contract is
    /// unchanged.
    func sendPush(payload: [String: Any], deviceToken: String) async -> PushOutcome {
        .notDelivered(reason: "transport_unimplemented")
    }
}

// MARK: - Emergency Contact (from L1 §5.1)

struct EmergencyContact {
    let id: UUID
    let displayName: String
    let deviceToken: String
    let isEmergencyContact: Bool
    let isFamilyNotificationTarget: Bool
    /// Which text channel an event alert for this contact rides
    /// (caregiver event-notifications task, 2026-09-13) — derived by
    /// `AppCoordinator.emergencyContacts(from:defaultCallApp:)` from the
    /// contact's calling preference. Defaulted to `.sms` (the universal
    /// fallback) so constructions that predate the field stay valid.
    var notifyChannel: NotifyChannel = .sms
}

#endif
