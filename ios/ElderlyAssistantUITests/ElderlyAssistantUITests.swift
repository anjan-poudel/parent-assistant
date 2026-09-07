import XCTest

/// Interaction smoke tests: talk button state flip and hub navigation.
/// Asserts the Nepali pilot strings so a locale regression fails loudly.
final class ElderlyAssistantUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Fresh installs land on the onboarding wizard; the user's device is
    /// past it. Skip every step (skip persists per-step) so the tests
    /// exercise the same Home state the user sees. Mic/notification
    /// permission alerts from SpringBoard are auto-accepted.
    private func completeOnboardingIfNeeded(_ app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        let skip = app.buttons["छाड्नुहोस्"]
        let next = app.buttons["अर्को"]
        let allow = app.buttons["दिनुहोस्"].firstMatch
        for _ in 0..<8 {
            // Permissions step: tap the allow buttons so the system
            // alerts appear and the interruption monitor accepts them —
            // skipping this step leaves mic undetermined and the voice
            // pipeline lands in .error ("Try again" dead button).
            if allow.exists {
                allow.tap()
            } else if skip.exists {
                skip.tap()
            } else if next.exists {
                next.tap()
            } else {
                break
            }
            app.tap()  // lets interruption monitors fire
        }
        // The pipeline start (post-wizard) re-requests mic; if the alert
        // is still up, one more tap lets the monitor accept it.
        app.tap()
    }

    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        completeOnboardingIfNeeded(app)
        return app
    }

    func testHomeShowsNepaliTalkButton() throws {
        let app = launchToHome()

        let talk = app.buttons["बोल्नुहोस्"]
        XCTAssertTrue(talk.waitForExistence(timeout: 15),
                      "Home should show the Nepali talk button. Hierarchy:\n"
                      + app.debugDescription)
        XCTAssertTrue(app.staticTexts["तयार छु"].exists,
                      "Idle status should be Nepali")
    }

    func testTalkButtonStartsListening() throws {
        let app = launchToHome()

        let talk = app.buttons["बोल्नुहोस्"]
        XCTAssertTrue(talk.waitForExistence(timeout: 15))
        talk.tap()

        let listening = app.buttons["सुन्दै छु…"]
        XCTAssertTrue(listening.waitForExistence(timeout: 10),
                      "Tapping talk should flip the button to the listening state")
    }

    /// Regression for "stuck in listening": after a talk cycle the button
    /// must return to idle (बोल्नुहोस्). The STT timeout guarantees the
    /// cycle completes within ~10s even when no speech is recognised.
    func testTalkButtonReturnsToIdleAfterListening() throws {
        let app = launchToHome()

        let talk = app.buttons["बोल्नुहोस्"]
        XCTAssertTrue(talk.waitForExistence(timeout: 15))
        talk.tap()

        let listening = app.buttons["सुन्दै छु…"]
        XCTAssertTrue(listening.waitForExistence(timeout: 10),
                      "Tapping talk should flip the button to the listening state")

        let idleAgain = app.buttons["बोल्नुहोस्"]
        XCTAssertTrue(idleAgain.waitForExistence(timeout: 30),
                      "Talk button never returned to idle — stuck in the listening cycle")
    }

    func testHubSettingsNavigationAndModelScreen() throws {
        let app = launchToHome()

        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "Settings entry should be reachable from Home")
        settings.tap()

        // Settings screen title. AI Models is intentionally NOT a normal
        // row here (redesign 2026-09-03 §3.3 — buried behind a long-press
        // since there's no caregiver app yet to hand it off to).
        let title = app.staticTexts["सेटिङ"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "Tapping the Settings dock item should push Settings")
        XCTAssertFalse(app.buttons["AI मोडेल"].exists,
                       "AI Models must not be a plain visible row")
        title.press(forDuration: 1.6)

        // Model management screen: automatic-selection row or empty state.
        let automatic = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "स्वचालित")).firstMatch
        let downloaded = app.staticTexts["डाउनलोड भएको छैन"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 10) ||
                      downloaded.waitForExistence(timeout: 10),
                      "Long-pressing the Settings title should reveal the model screen")
    }

    /// Walks EVERY Settings section row: each tap must push its screen
    /// (title visible), and back must return. Catches a broken row or a
    /// navigation regression in one pass.
    func testEverySettingsSectionNavigates() throws {
        let app = launchToHome()
        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.staticTexts["सेटिङ"].firstMatch.waitForExistence(timeout: 10))

        let sections: [(row: String, title: String)] = [
            ("भाषा र क्षेत्र", "भाषा र क्षेत्र"),
            ("जेमिनी AI", "जेमिनी AI"),
            ("आवाज इन्जिन", "आवाज इन्जिन"),
            ("आवाज सक्रियता", "आवाज सक्रियता"),
            ("आवाजहरू", "आवाजहरू"),
            ("द्रुत एपहरू", "द्रुत एपहरू"),
            ("परिवार र साथीहरू", "परिवार र साथीहरू"),
            ("औषधि तालिका", "औषधि तालिका"),
            ("गोपनीयता", "गोपनीयता"),
            ("सहायकको गतिविधि", "सहायकको गतिविधि"),
        ]
        for (row, title) in sections {
            // Custom status rows compose their label ("जेमिनी AI, सक्रिय"),
            // so match by containment, not exact equality.
            let rowButton = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", row)).firstMatch
            XCTAssertTrue(rowButton.waitForExistence(timeout: 10),
                          "Settings row \"(\(row))\" should exist")
            rowButton.tap()
            let pushed = app.staticTexts[title].firstMatch
            XCTAssertTrue(pushed.waitForExistence(timeout: 10),
                          "Tapping \"(\(row))\" should push its screen (title \"(\(title))\")")
            let back = app.buttons["पछाडि"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(app.staticTexts["सेटिङ"].firstMatch.waitForExistence(timeout: 5),
                          "Back should return to Settings")
        }
    }

    /// Quick-access picker interaction: search field filters the catalog.
    func testQuickAccessPickerSearchWorks() throws {
        let app = launchToHome()
        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let row = app.buttons["द्रुत एपहरू"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let search = app.textFields["एपहरू खोज्नुहोस्"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10),
                      "Quick access picker should show its search field")
        search.tap()
        search.typeText("whatsapp")
        XCTAssertTrue(app.staticTexts["WhatsApp"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["ह्वाट्सएप"].firstMatch.waitForExistence(timeout: 5),
                      "Searching should surface the WhatsApp row")
    }
}
