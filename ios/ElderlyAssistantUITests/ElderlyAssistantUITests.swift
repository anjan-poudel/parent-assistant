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

        // Settings screen title. The technical settings are intentionally
        // NOT rows on any tab (redesign 2026-09-03 §3.3 + 2026-09-16 reorg
        // §3 — buried behind a long-press since there's no caregiver app
        // yet to hand them off to).
        let title = app.staticTexts["सेटिङ"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "Tapping the Settings dock item should push Settings")
        XCTAssertFalse(app.buttons["AI मोडेल"].exists,
                       "AI Models must not be a plain visible row")

        // The five tabs are the visible surface (2026-09-16 reorg §3).
        for tab in ["आवाज", "परिवार", "सम्झनाहरू", "उपकरणहरू", "प्रणाली"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.waitForExistence(timeout: 10),
                          "Settings tab \"\(tab)\" should exist")
        }

        title.press(forDuration: 1.2)

        // ...and the hidden sheet carries the technical rows that left the
        // tabs, with the model screen behind its own row.
        let models = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "AI मोडेल")).firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10),
                      "Long-pressing the Settings title should reveal the technical sheet")
        for row in ["जेमिनी AI", "आवाज इन्जिन"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", row)).firstMatch.exists,
                "The technical sheet should carry \"\(row)\"")
        }
        models.tap()

        // Model management screen: automatic-selection row or empty state.
        let automatic = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "स्वचालित")).firstMatch
        let downloaded = app.staticTexts["डाउनलोड भएको छैन"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 10) ||
                      downloaded.waitForExistence(timeout: 10),
                      "The AI models row should push the model screen")
    }

    /// Walks EVERY visible Settings row on EVERY tab: each tap must push
    /// its screen (title visible), and back must return to the same tab.
    /// Catches a broken row, a row dropped from the tab table, or a
    /// navigation regression in one pass.
    func testEverySettingsSectionNavigates() throws {
        let app = launchToHome()
        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.staticTexts["सेटिङ"].firstMatch.waitForExistence(timeout: 10))

        // The five tabs' rows, in table order (2026-09-16 reorg §3).
        let tabs: [(tab: String, rows: [(row: String, title: String)])] = [
            ("आवाज", [("आवाज सक्रियता", "आवाज सक्रियता"),
                      ("आवाज निजीकरण", "आवाज निजीकरण"),
                      ("आवाजहरू", "आवाजहरू")]),
            ("परिवार", [("परिवार र साथीहरू", "परिवार र साथीहरू"),
                        ("परिवारलाई खबर गर्ने", "परिवारलाई खबर गर्ने"),
                        ("कलिङ", "कलिङ")]),
            ("सम्झनाहरू", [("औषधि तालिका", "औषधि तालिका"),
                           ("अलार्म र टाइमर", "अलार्म र टाइमर"),
                           ("पात्रो", "पात्रो"),
                           ("क्यालेन्डर साझा", "क्यालेन्डर साझा")]),
            ("उपकरणहरू", [("द्रुत एपहरू", "द्रुत एपहरू"),
                           ("युट्युब", "युट्युब"),
                           ("फिड", "फिड"),
                           ("म्यानुअलहरू", "म्यानुअलहरू"),
                           ("ठाउँ र नक्सा", "ठाउँ र नक्सा")]),
            ("प्रणाली", [("रूप", "रूप"),
                         ("भाषा र क्षेत्र", "भाषा र क्षेत्र"),
                         ("गोपनीयता", "गोपनीयता")]),
        ]
        for (tab, rows) in tabs {
            let tabButton = app.buttons[tab].firstMatch
            XCTAssertTrue(tabButton.waitForExistence(timeout: 10),
                          "Settings tab \"\(tab)\" should exist")
            tabButton.tap()
            for (row, title) in rows {
                // Custom status rows compose their label ("आवाजहरू, स्थापित"),
                // so match by containment, not exact equality.
                let rowButton = app.buttons.matching(NSPredicate(
                    format: "label CONTAINS %@", row)).firstMatch
                XCTAssertTrue(rowButton.waitForExistence(timeout: 10),
                              "Settings row \"(\(row))\" should exist on tab \"(\(tab))\"")
                if !rowButton.isHittable { app.swipeUp() }
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
    }

    /// Quick-access picker interaction: search field filters the catalog.
    func testQuickAccessPickerSearchWorks() throws {
        let app = launchToHome()
        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        // Quick apps lives on the Tools tab since the 2026-09-16 reorg.
        let toolsTab = app.buttons["उपकरणहरू"].firstMatch
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 10))
        toolsTab.tap()
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
