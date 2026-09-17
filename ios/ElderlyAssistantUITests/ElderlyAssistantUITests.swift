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

    /// Taps `target` and waits for `expected` to appear, retrying the tap
    /// while it doesn't. Right after `launchToHome` the screen is still
    /// settling (boot-spinner collapse, scroll restore), and a tap
    /// synthesized from a stale accessibility snapshot can land where the
    /// element was a frame earlier — the retry resolves the element's
    /// current frame once layout has settled. (2026-09-17: without the
    /// retry, every settings-navigation test failed on the simulator —
    /// the first tap landed on pre-settle coordinates.)
    private func tap(_ target: XCUIElement,
                     expecting expected: XCUIElement,
                     within timeout: TimeInterval,
                     in app: XCUIApplication,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
        guard target.waitForExistence(timeout: 5) else {
            XCTFail("\(target) never appeared. Hierarchy:\n"
                    + app.debugDescription, file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            target.tap()
            if expected.waitForExistence(timeout: 4) { return }
        } while Date() < deadline
        XCTFail("Tapping \(target) never produced \(expected). Hierarchy:\n"
                + app.debugDescription, file: file, line: line)
    }

    /// Frame-math visibility — `isHittable` throws "Activation point
    /// invalid" for fully off-screen elements instead of returning
    /// false, so the pill-bar scroll uses this.
    private func isOnScreen(_ element: XCUIElement,
                            in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let screen = app.frame
        return !frame.isEmpty
            && frame.minX < screen.maxX && frame.maxX > screen.minX
            && frame.minY < screen.maxY && frame.maxY > screen.minY
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

        // Settings screen title. The technical settings are intentionally
        // NOT rows on any tab (redesign 2026-09-03 §3.3 + 2026-09-16 reorg
        // §3 — buried behind a long-press since there's no caregiver app
        // yet to hand them off to).
        let title = app.staticTexts["सेटिङ"].firstMatch
        tap(settings, expecting: title, within: 12, in: app)
        XCTAssertFalse(app.buttons["AI मोडेल"].exists,
                       "AI Models must not be a plain visible row")

        // The five tabs are the visible surface (2026-09-16 reorg §3).
        for tab in ["आवाज", "परिवार", "सम्झनाहरू", "उपकरणहरू", "प्रणाली"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.waitForExistence(timeout: 10),
                          "Settings tab \"\(tab)\" should exist")
        }

        title.press(forDuration: 1.2)

        // ...and the hidden sheet carries the technical rows that left the
        // tabs, with the model screen behind its own row. YouTube rides
        // here since the menu-deepening pass (2026-09-17): a provider-key
        // screen, not a household Tools row.
        let models = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "AI मोडेल")).firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10),
                      "Long-pressing the Settings title should reveal the technical sheet")
        for row in ["जेमिनी AI", "आवाज इन्जिन", "युट्युब"] {
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
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "Settings entry should be reachable from Home")
        tap(settings, expecting: app.staticTexts["सेटिङ"].firstMatch,
            within: 12, in: app)

        // The five tabs' rows, in table order (2026-09-16 reorg §3).
        let tabs: [(tab: String, rows: [(row: String, title: String)])] = [
            ("आवाज", [("आवाज सक्रियता", "आवाज सक्रियता"),
                      ("आवाज निजीकरण", "आवाज निजीकरण"),
                      ("आवाजहरू", "आवाजहरू")]),
            ("परिवार", [("परिवार र साथीहरू", "परिवार र साथीहरू"),
                        ("परिवारलाई खबर गर्ने", "परिवारलाई खबर गर्ने"),
                        ("कलिङ", "कलिङ")]),
            ("सम्झनाहरू", [("औषधि तालिका", "औषधि तालिका"),
                           ("दिनचर्या", "दिनचर्या"),
                           ("अलार्म र टाइमर", "अलार्म र टाइमर"),
                           ("कार्यक्रमहरू", "कार्यक्रमहरू"),
                           ("पात्रो", "पात्रो"),
                           ("क्यालेन्डर साझा", "क्यालेन्डर साझा")]),
            ("उपकरणहरू", [("द्रुत एपहरू", "द्रुत एपहरू"),
                           ("फिड", "फिड"),
                           ("म्यानुअलहरू", "म्यानुअलहरू"),
                           ("ठाउँ र नक्सा", "ठाउँ र नक्सा")]),
            ("प्रणाली", [("रूप", "रूप"),
                         ("भाषा र क्षेत्र", "भाषा र क्षेत्र"),
                         ("लाइभ अनुवाद", "लाइभ अनुवाद"),
                         ("गोपनीयता", "गोपनीयता")]),
        ]
        for (index, (tab, rows)) in tabs.enumerated() {
            let tabButton = app.buttons[tab].firstMatch
            XCTAssertTrue(tabButton.waitForExistence(timeout: 10),
                          "Settings tab \"\(tab)\" should exist")
            if !isOnScreen(tabButton, in: app) {
                // The pill bar scrolls horizontally (five Nepali titles
                // don't fit one screen). The currently selected tab's
                // pill is on screen, so drag IT leftward first, then
                // keep dragging the target pill itself as it slides in.
                let currentPill = app.buttons[tabs[index - 1].tab].firstMatch
                if isOnScreen(currentPill, in: app) { currentPill.swipeLeft() }
                for _ in 0..<4 where !isOnScreen(tabButton, in: app) {
                    tabButton.swipeLeft()
                }
            }
            XCTAssertTrue(isOnScreen(tabButton, in: app),
                          "Settings tab \"\(tab)\" should be reachable by scrolling the pill bar")
            let firstRowButton = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", rows[0].row)).firstMatch
            tap(tabButton, expecting: firstRowButton, within: 10, in: app)
            for (row, title) in rows {
                // Custom status rows compose their label ("आवाजहरू, स्थापित"),
                // so match by containment, not exact equality.
                let rowButton = app.buttons.matching(NSPredicate(
                    format: "label CONTAINS %@", row)).firstMatch
                XCTAssertTrue(rowButton.waitForExistence(timeout: 10),
                              "Settings row \"(\(row))\" should exist on tab \"(\(tab))\"")
                if !rowButton.isHittable { app.swipeUp() }
                tap(rowButton, expecting: app.staticTexts[title].firstMatch,
                    within: 10, in: app)
                tap(app.buttons["पछाडि"].firstMatch,
                    expecting: app.staticTexts["सेटिङ"].firstMatch,
                    within: 8, in: app)
            }
        }
    }

    /// Quick-access picker interaction: search field filters the catalog.
    func testQuickAccessPickerSearchWorks() throws {
        let app = launchToHome()
        let settings = app.buttons["सेटिङ"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        tap(settings, expecting: app.staticTexts["सेटिङ"].firstMatch,
            within: 12, in: app)
        // Quick apps lives on the Tools tab since the 2026-09-16 reorg.
        let toolsTab = app.buttons["उपकरणहरू"].firstMatch
        let row = app.buttons["द्रुत एपहरू"].firstMatch
        tap(toolsTab, expecting: row, within: 10, in: app)
        let search = app.textFields["एपहरू खोज्नुहोस्"].firstMatch
        tap(row, expecting: search, within: 10, in: app)
        search.tap()
        search.typeText("whatsapp")
        XCTAssertTrue(app.staticTexts["WhatsApp"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["ह्वाट्सएप"].firstMatch.waitForExistence(timeout: 5),
                      "Searching should surface the WhatsApp row")
    }
}
