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
        // [PROFILE-INTERVIEW T-102] The wizard now has 7 steps (the
        // interview steps inserted after permissions) and a cold start
        // with pending steps auto-presents it (FR-PI-016). The Home-side
        // presentation is asynchronous (a one-shot on Home's first
        // appearance) and step transitions leave brief gaps with no
        // wizard element in the tree, so a single empty probe no longer
        // means "no wizard present". The walk therefore stands down only
        // after four consecutive quiet probes, each itself waiting up to
        // 6 s for a late presentation (~18 s of confirmed quiet; the
        // presentation appeared well within this window on a starved
        // simulator during the T-102 validation run). A fresh install
        // can still walk the wizard TWICE (ContentView's pass, then
        // Home's one-shot on the preserved skipped-steps state); 40
        // iterations leave headroom over the worst case (two passes x
        // 7 steps + permission taps).
        var quietProbes = 0
        for _ in 0..<40 {
            // Permissions step: tap the allow buttons so the system
            // alerts appear and are accepted — skipping this step
            // leaves mic undetermined and the voice pipeline lands in
            // .error ("Try again" dead button).
            if allow.exists {
                allow.tap()
                quietProbes = 0
                acceptPermissionAlertIfPresent(wait: 2)
            } else if skip.exists {
                skip.tap()
                quietProbes = 0
                acceptPermissionAlertIfPresent()
            } else if next.exists {
                next.tap()
                quietProbes = 0
                acceptPermissionAlertIfPresent()
            } else {
                quietProbes += 1
                if quietProbes >= 4 { break }
                _ = skip.waitForExistence(timeout: 6)
                continue
            }
        }
        // The pipeline start (finishOnboarding -> coordinator.start) can
        // raise the mic prompt a beat after the walk settles; give that
        // alert a bounded window and accept it.
        acceptPermissionAlertIfPresent(wait: 5)
    }

    /// Accepts a pending SpringBoard permission alert, polling for it
    /// directly instead of synthesizing an app tap to fire the
    /// registered interruption monitor. The old monitor-firing tap
    /// delivered a blind app-coordinate tap on every iteration; with
    /// the interview pending, Home carries a live "optional setup"
    /// strip whose activation re-opens the wizard at the first pending
    /// step — a tap settling into it re-presented the wizard after
    /// every dismissal, so the walk never went quiet (2026-10-06 run:
    /// 40 skip taps, one full pass every ~19 s). Polling SpringBoard
    /// needs no in-app tap at all; the registered monitor stays as the
    /// net for alerts that appear while later test code taps app
    /// elements.
    private func acceptPermissionAlertIfPresent(wait: TimeInterval = 0.3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: wait) else { return }
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    /// Titles of the wizard's steps (the pilot locale), in wizard order.
    /// Lets a test read which step a presented wizard is on without
    /// assuming anything about the persisted state.
    private static let stepTitles = ["भाषा छान्नुहोस्",
                                     "अनुमति दिनुहोस्",
                                     "तपाईंको बारेमा",
                                     "परिवार र साथीहरू",
                                     "आपत्कालीन सम्पर्कहरू",
                                     "तपाईंको आवाज",
                                     "जेमिनी AI जोड्नुहोस्"]

    /// Waits for a presented wizard and returns the title of the step it
    /// is on. Fails the test if no step title ever appears.
    private func presentedStepTitle(in app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> String {
        for _ in 0..<15 {
            for title in Self.stepTitles {
                if app.staticTexts[title].firstMatch.exists { return title }
            }
            _ = app.buttons["छाड्नुहोस्"].waitForExistence(timeout: 1)
        }
        XCTFail("No wizard step title appeared. Hierarchy:\n"
                + app.debugDescription, file: file, line: line)
        return ""
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
        // Bounded wait: the idle status is an asynchronous readiness
        // signal (pipeline start after the wizard walk and boot); the
        // previous immediate `.exists` silently depended on the walk
        // having consumed exactly the boot window, which no longer holds
        // reliably on a loaded simulator.
        XCTAssertTrue(app.staticTexts["तयार छु"].waitForExistence(timeout: 20),
                      "Idle status should be Nepali")
    }

    /// Four configured favourites must fit without a horizontal swipe; the
    /// requested action rows stay separately ordered and reachable.
    func testHomeKeepsConfiguredAppsAndActionRowsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-quickAccessApps", "(facebook, messenger, youtube, camera)",
                               "-appTextSize", "medium", "-appTheme", "sky",
                               "-appVisualStyle", "soft"]
        app.launch()
        completeOnboardingIfNeeded(app)

        func visibleRow(_ identifiers: [String]) -> [CGRect] {
            identifiers.map { identifier in
                let button = app.buttons[identifier]
                XCTAssertTrue(button.waitForExistence(timeout: 15), identifier)
                let bounds = button.frame
                XCTAssertGreaterThanOrEqual(bounds.minX, app.frame.minX, identifier)
                XCTAssertLessThanOrEqual(bounds.maxX, app.frame.maxX, identifier)
                XCTAssertGreaterThanOrEqual(bounds.minY, app.frame.minY, identifier)
                XCTAssertLessThanOrEqual(bounds.maxY, app.frame.maxY, identifier)
                XCTAssertTrue(button.isHittable, identifier)
                return bounds
            }
        }

        func orderedRow(_ frames: [CGRect]) {
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
                XCTAssertEqual(left.minY, right.minY, accuracy: 1)
            }
        }

        let favourites = visibleRow(["facebook", "messenger", "youtube", "camera"].map {
            "home.quickAccess.\($0)"
        })
        let upper = visibleRow(["home.action.appliance", "home.action.liveTranslate",
                                "home.action.feed", "home.action.maps"])
        let lower = visibleRow(["home.action.phone", "home.action.medication",
                                "home.action.reminders"])
        orderedRow(favourites)
        orderedRow(upper)
        orderedRow(lower)
        for card in upper.dropFirst() {
            XCTAssertEqual(card.height, upper[0].height, accuracy: 1,
                           "Wrapping a label must not leave mismatched action-card heights")
        }
        XCTAssertLessThanOrEqual(upper.map(\.maxY).max()!, lower.map(\.minY).min()!)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Complete Home with supplied icons and separate action rows"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        tap(app.buttons["home.action.feed"], expecting: app.staticTexts["feeds.title"],
            within: 15, in: app)
        tap(app.buttons["leaf.back"], expecting: app.buttons["home.action.phone"],
            within: 10, in: app)
        tap(app.buttons["home.action.phone"], expecting: app.staticTexts["call.title"],
            within: 15, in: app)
        tap(app.buttons["leaf.back"], expecting: app.buttons["home.action.appliance"],
            within: 10, in: app)
    }

    /// [PROFILE-INTERVIEW T-102] FR-PI-016's startup presentation
    /// (design-l2 test table, "Startup presentation"): with onboarding
    /// seen and the interview still pending — skipped steps stay pending
    /// by design — a COLD START presents the wizard over Home at the
    /// first pending step, with the skip affordance, so the user is
    /// never trapped.
    ///
    /// The shared simulator's persisted state can carry steps an older
    /// run already completed, so the test does not assume the interview
    /// starts at language: it records the title of the step the wizard
    /// first presents at, then asserts the cold start resumes at the
    /// SAME step. The walk only ever SKIPS steps (never completes one),
    /// so the first pending step is invariant across the relaunch by
    /// construction. (The exact first-pending rule itself is pinned
    /// state-free by ColdStartRoutingTests.)
    func testColdStartWithPendingInterviewPresentsTheWizard() throws {
        // First launch: record the step the wizard presents at, then
        // consume the wizard (the helper walks a presented wizard) and
        // land on Home.
        let app = XCUIApplication()
        app.launch()
        let firstStep = presentedStepTitle(in: app)
        completeOnboardingIfNeeded(app)
        app.terminate()

        // Cold start again: the pending interview must resurface at the
        // same first pending step, still skippable.
        app.launch()
        let skip = app.buttons["छाड्नुहोस्"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15),
                      "A cold start with pending steps must present the "
                      + "interview wizard. Hierarchy:\n" + app.debugDescription)
        XCTAssertEqual(presentedStepTitle(in: app), firstStep,
                       "The cold start must resume the interview at the "
                       + "first pending step")

        // Leave the app on Home for the rest of the suite (skipped stays
        // pending — the state this test just exercised).
        completeOnboardingIfNeeded(app)
    }
    /// Precondition: the simulator has no Gemini key and uses Nepali.
    /// The Home tile must still open offline manuals, not just speak a
    /// refusal. Opening a guide also proves the nested library dismisses
    /// back into the helper instead of losing the app-wide presentation.
    func testApplianceHelpWithoutCloudOpensBundledManualAndDismisses() throws {
        let app = launchToHome()
        let appliance = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "उपकरण सहायता")).firstMatch
        let manuals = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "म्यानुअलहरू")).firstMatch
        tap(appliance, expecting: manuals, within: 15, in: app)
        let takePhoto = app.buttons["फोटो खिच्नुहोस्"]
        XCTAssertTrue(takePhoto.exists)
        XCTAssertFalse(takePhoto.isEnabled,
                       "Fresh cloud analysis must be unavailable without a key")
        XCTAssertTrue(manuals.isEnabled, "Offline manuals must remain usable")

        let iphone = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "आइफोन सुरुवात")).firstMatch
        tap(manuals, expecting: iphone, within: 10, in: app)
        let firstStep = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@",
            "तपाईंको फोन सुतिरहेको छ। ब्युँझाउन दायाँपट्टिको बटन थिच्नुहोस्।")).firstMatch
        tap(iphone, expecting: firstStep, within: 10, in: app)
        XCTAssertFalse(manuals.exists, "Opening a bundled guide must leave the library")

        tap(app.buttons["बन्द गर्नुहोस्"].firstMatch,
            expecting: app.buttons["home.talk"], within: 10, in: app)
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
                        // [PROFILE-INTERVIEW T-103] The profile editor's
                        // row (design-l2 §5.7: tab .family — rows become
                        // [.family, .profile, .caregiverNotifications,
                        // .calling]).
                        ("मेरो बारेमा", "मेरो बारेमा"),
                        ("परिवारलाई खबर गर्ने", "परिवारलाई खबर गर्ने"),
                        ("कलिङ", "कलिङ")]),
            ("सम्झनाहरू", [("औषधि तालिका", "औषधि तालिका"),
                           ("दिनचर्या", "दिनचर्या"),
                           ("अलार्म र टाइमर", "अलार्म र टाइमर"),
                           ("कार्यक्रमहरू", "कार्यक्रमहरू"),
                           ("पात्रो", "पात्रो"),
                           ("क्यालेन्डर साझा", "क्यालेन्डर साझा")]),
            ("उपकरणहरू", [("द्रुत एपहरू", "द्रुत एपहरू"),
                           ("settings.feeds", "settings.feeds.title"),
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
                    format: "label CONTAINS %@ OR identifier == %@", row, row)).firstMatch
                XCTAssertTrue(rowButton.waitForExistence(timeout: 10),
                              "Settings row \"(\(row))\" should exist on tab \"(\(tab))\"")
                if !rowButton.isHittable { app.swipeUp() }
                let destinationTitle = app.staticTexts.matching(NSPredicate(
                    format: "label == %@ OR identifier == %@", title, title)).firstMatch
                tap(rowButton, expecting: destinationTitle, within: 10, in: app)
                tap(app.buttons["पछाडि"].firstMatch,
                    expecting: app.staticTexts["सेटिङ"].firstMatch,
                    within: 8, in: app)
            }
        }
    }

    /// Exercises genuine selectors, navigation and process restart without preference fixtures.
    func testAppearanceSelectionsAreIndependentAndSurviveRelaunch() throws {
        let app = launchToHome()

        func reveal(_ element: XCUIElement) {
            let viewport = app.scrollViews["leaf.content"].firstMatch
            for attempt in 0..<24 {
                if isOnScreen(element, in: app), element.isHittable { return }
                let upward = element.exists
                    ? element.frame.midY > viewport.frame.midY
                    : attempt < 12
                let start = viewport.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.5, dy: upward ? 0.75 : 0.25))
                let end = viewport.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.5, dy: upward ? 0.45 : 0.55))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Appearance control must be reachable: \(element), bounds \(element.frame), viewport \(viewport.frame)")
        }

        func openAppearance() {
            let settings = app.buttons["home.settings"].firstMatch
            let systemTab = app.buttons["settings.tab.system"].firstMatch
            tap(settings, expecting: systemTab, within: 15, in: app)
            if !isOnScreen(systemTab, in: app) {
                app.buttons["settings.tab.voice"].firstMatch.swipeLeft()
            }
            for _ in 0..<5 where !isOnScreen(systemTab, in: app) {
                systemTab.swipeLeft()
            }
            let appearanceRow = app.buttons["settings.appearance"].firstMatch
            tap(systemTab, expecting: appearanceRow, within: 10, in: app)
            tap(appearanceRow, expecting: app.buttons["textSize.system"], within: 10, in: app)
        }

        func choose(_ identifier: String) {
            let row = app.buttons[identifier]
            reveal(row)
            row.tap()
            XCTAssertTrue(row.isSelected, "The chosen appearance option must expose selected state")
        }

        func assertSelected(_ identifier: String) {
            let row = app.buttons[identifier]
            reveal(row)
            XCTAssertTrue(row.isSelected, "Changing the other option must preserve this selection")
        }

        func capture(_ name: String, preview: Bool = true) {
            if preview {
                let panel = app.descendants(matching: .any)["appearance.preview"].firstMatch
                let viewport = app.scrollViews["leaf.content"].firstMatch
                for _ in 0..<10 {
                    let bounds = panel.frame
                    let visible = viewport.frame
                    if bounds.minY >= visible.minY, bounds.maxY <= visible.maxY { break }
                    viewport.swipeDown()
                }
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func returnHome() {
            let back = app.buttons["settings.back"].firstMatch
            tap(back, expecting: app.buttons["settings.tab.system"].firstMatch, within: 10, in: app)
            tap(back, expecting: app.buttons["home.settings"].firstMatch, within: 10, in: app)
        }

        openAppearance()
        choose("appearance.style.classic")
        choose("appearance.skin.cream")
        assertSelected("appearance.style.classic")
        capture("Classic + Warm Cream preview")
        choose("appearance.style.glass")
        assertSelected("appearance.skin.cream")
        choose("appearance.skin.sage")
        assertSelected("appearance.style.glass")
        for identifier in ["textSize.system", "textSize.medium", "textSize.large", "textSize.xxl"] {
            choose(identifier)
        }
        assertSelected("appearance.skin.sage")
        assertSelected("appearance.style.glass")
        choose("textSize.small")
        let previewText = app.staticTexts["appearance.preview.talk"].firstMatch
        reveal(previewText)
        let smallTextHeight = previewText.frame.height
        XCTAssertGreaterThan(smallTextHeight, 0)
        capture("Glass + Sage + Small preview")
        choose("textSize.xl")
        reveal(previewText)
        expectation(for: NSPredicate { _, _ in previewText.frame.height > smallTextHeight },
                    evaluatedWith: previewText)
        waitForExpectations(timeout: 5)
        let xlTextHeight = previewText.frame.height
        assertSelected("appearance.skin.sage")
        assertSelected("appearance.style.glass")
        capture("Glass + Sage preview")
        returnHome()
        capture("Glass + Sage returned Home", preview: false)

        openAppearance()
        assertSelected("appearance.style.glass")
        assertSelected("appearance.skin.sage")
        assertSelected("textSize.xl")
        app.terminate()
        app.launch()
        completeOnboardingIfNeeded(app)
        openAppearance()
        assertSelected("appearance.style.glass")
        assertSelected("appearance.skin.sage")
        assertSelected("textSize.xl")
        reveal(previewText)
        XCTAssertEqual(previewText.frame.height, xlTextHeight, accuracy: 1,
                       "The restored size must preserve visible text dimensions")
        capture("Glass + Sage restored after relaunch")

        for (skin, name) in [("midnight", "Midnight"), ("darkRose", "Dark Rose")] {
            let identifier = "appearance.skin.\(skin)"
            choose(identifier)
            assertSelected("appearance.style.glass")
            assertSelected("textSize.xl")
            reveal(previewText)
            XCTAssertEqual(previewText.frame.height, xlTextHeight, accuracy: 1,
                           "Choosing a dark skin must preserve the visible text size")
            capture("Glass + \(name) + XL preview")
            returnHome()
            capture("\(name) returned Home", preview: false)
            app.terminate()
            app.launch()
            completeOnboardingIfNeeded(app)
            XCTAssertTrue(app.buttons["home.settings"].firstMatch.waitForExistence(timeout: 15))
            capture("\(name) Home after relaunch", preview: false)
            openAppearance()
            assertSelected(identifier)
            assertSelected("appearance.style.glass")
            assertSelected("textSize.xl")
            capture("\(name) restored selection and preview")
        }

        choose("appearance.skin.sky")
        assertSelected("appearance.style.glass")
        choose("appearance.style.soft")
        assertSelected("appearance.skin.sky")
        assertSelected("textSize.xl")
        choose("textSize.system")
        capture("Soft + Sky preview")
        returnHome()
        capture("Soft + Sky returned Home", preview: false)
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
