import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// Every notification category the app registers (rich-events task,
/// 2026-09-17).
///
/// The load-bearing test here is `testAllCarriesBothCategories`: the
/// platform's `setNotificationCategories` is a FULL REPLACE, so a
/// second registrant that built only its own category would silently
/// drop the medication category — and with it the "Taken" acknowledge
/// button on every dose reminder. That is why there is one builder
/// (`NotificationCategories.all`) and this asserts what it must carry.
///
/// Everything is pure and locale-parameterized: no notification center,
/// no authorization prompt, no running app.
final class NotificationCategoriesTests: XCTestCase {

    private let en = Locale(identifier: "en")
    private let ne = Locale(identifier: "ne")

    private func category(_ identifier: String, _ locale: Locale) -> UNNotificationCategory? {
        NotificationCategories.all(locale: locale)
            .first { $0.identifier == identifier }
    }

    // MARK: - The full-replace guard

    func testAllCarriesBothCategories() {
        for locale in [en, ne] {
            let all = NotificationCategories.all(locale: locale)
            XCTAssertEqual(all.count, 2,
                           "the one registration call is a full replace — every category "
                           + "the app owns must be in it, for \(locale.identifier)")
            XCTAssertNotNil(category(NotificationCategories.medicationReminder, locale),
                            "the medication category must survive the second registrant")
            XCTAssertNotNil(category(NotificationCategories.eventReminder, locale))
        }
    }

    // MARK: - Medication (unchanged)

    func testTheMedicationCategoryKeepsItsAcknowledgeAction() {
        let medication = category(NotificationCategories.medicationReminder, en)
        XCTAssertEqual(medication?.actions.map(\.identifier),
                       [NotificationCategories.acknowledgeMedicationAction])
        XCTAssertEqual(medication?.actions.first?.title,
                       L10n.str("meds.taken", locale: en),
                       "the action title is localized, not hardcoded English")
        XCTAssertEqual(medication?.actions.first?.options, [.foreground],
                       "acknowledging brings the app forward — unchanged behaviour")
        XCTAssertTrue(medication?.options.contains(.customDismissAction) ?? false)
        XCTAssertTrue(medication?.intentIdentifiers.isEmpty ?? false)
    }

    // MARK: - Events

    func testTheEventCategoryHasExactlyTheOpenActionInBothLanguages() {
        for (locale, expected) in [(en, L10n.str("events.notification.open", locale: en)),
                                   (ne, L10n.str("events.notification.open", locale: ne))] {
            let event = category(NotificationCategories.eventReminder, locale)
            XCTAssertEqual(event?.actions.map(\.identifier),
                           [NotificationCategories.openEventAction])
            XCTAssertEqual(event?.actions.first?.title, expected)
            XCTAssertEqual(event?.actions.first?.options, [.foreground],
                           "Open must bring the app forward — it deep-links to the "
                           + "event detail screen")
            XCTAssertTrue(event?.options.contains(.customDismissAction) ?? false)
            XCTAssertTrue(event?.intentIdentifiers.isEmpty ?? false)
        }
    }

    func testTheActionTitlesActuallyDifferByLanguage() {
        // A title that fell back to the key (or to English) would make
        // the two look identical — the assertion above would still pass
        // if both were the same wrong string.
        XCTAssertNotEqual(L10n.str("events.notification.open", locale: en),
                          L10n.str("events.notification.open", locale: ne))
        XCTAssertEqual(L10n.str("events.notification.open", locale: ne), "खोल्नुहोस्")
    }

    func testEventAndMedicationIdentifiersAreDistinctAndStable() {
        // Both are producer constants: a durable identifier must never be
        // renamed (pending notifications still reference the old string)
        // and the two must never collide.
        XCTAssertEqual(NotificationCategories.medicationReminder, "MEDICATION_REMINDER")
        XCTAssertEqual(NotificationCategories.eventReminder, "EVENT_REMINDER")
        XCTAssertEqual(NotificationCategories.openEventAction, "OPEN_EVENT")
        XCTAssertEqual(NotificationCategories.eventIdentifierKey, "event_id")
        XCTAssertEqual(NotificationCategories.acknowledgeMedicationAction,
                       "ACKNOWLEDGE_MEDICATION")
    }
}
