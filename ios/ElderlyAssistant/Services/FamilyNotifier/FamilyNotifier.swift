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
/// recorded locally, delivery is unchanged (the APNs provider is still
/// the stub it always was).
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

// MARK: - iOS APNs Implementation

#if os(iOS)
final class APNsFamilyNotifier: FamilyNotifierProtocol {

    private var contacts: [EmergencyContact]
    private let apnsProvider: APNsProvider
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
         apnsProvider: APNsProvider = APNsProvider(),
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
            let payload = buildPayload(alertType: alertType, timestamp: timestamp)

            let pushResult = await apnsProvider.sendPush(
                payload: payload,
                deviceToken: contact.deviceToken
            )

            let result = NotificationResult(
                contactIdHash: idHash(contact.id),
                success: pushResult,
                errorCode: pushResult ? nil : "apns_delivery_failed",
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
                                 channel: contact.notifyChannel)
            }
        }

        // Partial delivery is acceptable -- log failures
        let failureCount = results.filter { !$0.success }.count
        if failureCount > 0 {
            print("[FamilyNotifier] \(failureCount)/\(results.count) notifications failed")
        }

        return results
    }

    private func buildPayload(alertType: FamilyAlertType, timestamp: Date) -> [String: Any] {
        var aps: [String: Any] = [
            "aps": [
                "alert": alertBody(for: alertType),
                "sound": alertType == .emergencyCall ? "critical-alert.aiff" : "default",
                "badge": 1,
                "category": "FAMILY_ALERT"
            ]
        ]

        // Payload contains alert type + timestamp only (no PII, no health values)
        aps["alert_type"] = alertType.rawValue
        aps["timestamp"] = ISO8601DateFormatter().string(from: timestamp)

        return aps
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
        }
    }

    /// PII-free record of one event alert: the wire alert type, the app
    /// kind, the channel the push rode, and the hashed event id. The
    /// event TITLE is never a metadata value (constitution C9).
    private func emitEventAlerted(alertType: FamilyAlertType,
                                  context: FamilyAlertContext,
                                  channel: NotifyChannel) {
        observabilityBus.emit(ObservabilityEvent(
            component: "family_notifier",
            eventType: "family_event_alerted",
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
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

// MARK: - APNs Provider Stub

final class APNsProvider {
    /// Sends a push notification payload to a device token.
    /// Returns true if delivery was successful.
    /// In production: uses URLSession with HTTP/2 to api.push.apple.com,
    /// JWT token auth, pinned certificate.
    func sendPush(payload: [String: Any], deviceToken: String) async -> Bool {
        // Stub implementation -- T-028-a requires APNs integration
        // This will be replaced with real APNs HTTP/2 client in production
        print("[APNsProvider] Push sent to token: \(deviceToken.prefix(8))...")
        return true
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
