import Foundation

// MARK: - FamilyNotifier Protocol (L2 §5.5)

protocol FamilyNotifierProtocol {
    func notifyAll(alertType: FamilyAlertType, at timestamp: Date) async -> [NotificationResult]
}

// MARK: - iOS APNs Implementation

#if os(iOS)
final class APNsFamilyNotifier: FamilyNotifierProtocol {

    private var contacts: [EmergencyContact]
    private let apnsProvider: APNsProvider

    /// Locale the family-facing alert bodies resolve against (spec §3.2).
    /// Kept in sync with the app language by `AppCoordinator`; the English
    /// default matches the legacy hardcoded strings.
    var locale: Locale = Locale(identifier: "en")

    init(contacts: [EmergencyContact], apnsProvider: APNsProvider = APNsProvider()) {
        self.contacts = contacts.filter { $0.isFamilyNotificationTarget }
        self.apnsProvider = apnsProvider
    }

    /// Replaces the contact list — called by `AppCoordinator` when the
    /// Settings family-contacts section changes. Until the broker relay
    /// provisions device tokens (review C6), pushes have no destination;
    /// the list is still kept real so the wiring is in place.
    func updateContacts(_ newContacts: [EmergencyContact]) {
        contacts = newContacts.filter { $0.isFamilyNotificationTarget }
    }

    func notifyAll(alertType: FamilyAlertType, at timestamp: Date) async -> [NotificationResult] {
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
                errorCode: pushResult ? nil : "apns_delivery_failed"
            )
            results.append(result)
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
        }
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
}

#endif
