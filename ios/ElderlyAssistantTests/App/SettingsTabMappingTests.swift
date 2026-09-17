import XCTest
@testable import ElderlyAssistant

/// Guards the tabbed Settings reorg (spec
/// `docs/superpowers/specs/2026-09-16-settings-models-reorg-design.md` §3,
/// extended by the menu-deepening pass 2026-09-17): five tabs (Voice,
/// Family, Reminders, Tools, System), the seven technical rows behind the
/// title long-press, and the L10n every tab/sheet string needs.
///
/// The point of these tests is that the reorg is a TABLE change, not a UI
/// change: a row can be moved between tabs, or dropped from the hub into
/// the hidden sheet, only deliberately — losing one, or listing it twice,
/// fails here instead of silently disappearing from the household's app.
final class SettingsTabMappingTests: XCTestCase {

    typealias Section = SettingsView.SettingsSection
    typealias Destination = SettingsView.SettingsDestination

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    // MARK: - The tab table (spec §3)

    func testTabTableMatchesTheDesign() {
        // Pinned verbatim against the spec's table, as amended by the
        // menu-deepening pass (YouTube left Tools for the hidden sheet) —
        // the "contains" column is the contract, and the ORDER is the
        // household's reading order.
        XCTAssertEqual(Section.voice.rows,
                       [.wakeWord, .voicePersonalization, .ttsVoices])
        XCTAssertEqual(Section.family.rows,
                       [.family, .caregiverNotifications, .calling])
        XCTAssertEqual(Section.reminders.rows,
                       [.meds, .routines, .alarms, .events, .calendar, .calendarSharing])
        XCTAssertEqual(Section.tools.rows,
                       [.quickApps, .feeds, .manuals, .places])
        XCTAssertEqual(Section.system.rows,
                       [.appearance, .language, .privacy])
    }

    func testTabsAreTheDesignsFiveInBarOrder() {
        XCTAssertEqual(Section.allCases, [.voice, .family, .reminders, .tools, .system])
    }

    // MARK: - Every row exactly once

    func testEveryVisibleRowLivesOnExactlyOneTab() {
        let flattened = Section.allCases.flatMap(\.rows)
        XCTAssertEqual(Set(flattened).count, flattened.count,
                       "a row is listed on two tabs: "
                       + duplicates(in: flattened).map(\.rawValue).joined(separator: ", "))
        XCTAssertEqual(flattened.count, 19, "the hub's visible row count changed")
    }

    func testTheVisibleAndHiddenHalvesPartitionEveryDestination() {
        let visible = Section.allCases.flatMap(\.rows)
        let hidden = Destination.hiddenSheetRows
        let union = Set(visible).union(hidden)
        XCTAssertEqual(union, Set(Destination.allCases),
                       "a destination is unreachable — neither on a tab nor in "
                       + "the hidden sheet: "
                       + Set(Destination.allCases).subtracting(union)
                           .map(\.rawValue).sorted().joined(separator: ", "))
        XCTAssertEqual(union.count, Destination.allCases.count,
                       "a destination is in both halves")
    }

    func testTabLookupRoundTripsWithTheTable() {
        for tab in Section.allCases {
            for row in tab.rows {
                XCTAssertEqual(row.tab, tab,
                               "\(row.rawValue) points back at the wrong tab")
            }
        }
    }

    func testHiddenSheetRowsHaveNoTab() {
        for row in Destination.hiddenSheetRows {
            XCTAssertNil(row.tab,
                         "\(row.rawValue) is in the hidden sheet AND on a tab — "
                         + "the sheet is for what the tabs do not carry")
        }
    }

    // MARK: - The hidden sheet (spec §2 decision 2)

    func testHiddenSheetHoldsTheRemovedTechnicalSections() {
        // AI + dev tools, in sheet order. Content configuration (appearance,
        // language, …) stays visible — decision 2.
        XCTAssertEqual(Destination.hiddenSheetRows,
                       [.geminiAI, .voiceEngine, .webSearch, .youtube,
                        .intentLog, .toolLog])
    }

    func testCloudProviderKeyScreensAllLiveInTheHiddenSheet() {
        // The menu-deepening pass (2026-09-17) moved YouTube in: it is the
        // third of three screens that are the SAME thing — an optional
        // cloud-provider credential (a SecureField for an API key, a quota
        // note, a privacy note) that the household is never asked to
        // handle: `GeminiAPISettingsView`, `SearchSettingsView`,
        // `YouTubeSettingsView`. Two were hidden and one was not; a future
        // pass that re-exposes one of them fails here.
        let hidden = Set(Destination.hiddenSheetRows)
        for keyScreen: Destination in [.geminiAI, .webSearch, .youtube] {
            XCTAssertTrue(hidden.contains(keyScreen),
                          "\(keyScreen.rawValue) is a provider-key screen and "
                          + "belongs in the technical sheet with its peers")
        }
        XCTAssertFalse(Section.allCases.flatMap(\.rows).contains(.youtube),
                       "YouTube must not also be a visible row")
    }

    func testContentConfigurationStaysOnTheTabs() {
        // The rows decision 2 explicitly keeps visible — a regression that
        // buries one of these behind the long-press fails here.
        let visible = Set(Section.allCases.flatMap(\.rows))
        for row: Destination in [.appearance, .language, .privacy, .meds,
                                 .routines, .events, .family, .ttsVoices,
                                 .quickApps] {
            XCTAssertTrue(visible.contains(row),
                          "\(row.rawValue) must stay a visible row")
        }
    }

    // MARK: - Row identity (no row loses its L10n key)

    func testEveryRowTitleResolvesInBothLanguages() {
        // The reorg MOVES rows; a moved row that lost its key would render
        // raw ("settings.meds.title") in the household's app.
        for row in Destination.allCases {
            for locale in [english, nepali] {
                let value = L10n.str(row.titleKey, locale: locale)
                XCTAssertNotEqual(value, row.titleKey,
                                  "\(row.titleKey) is unresolved in "
                                  + "\(locale.identifier)")
            }
        }
    }

    func testEveryRowHasAnIcon() {
        for row in Destination.allCases {
            XCTAssertFalse(row.icon.isEmpty, row.rawValue)
        }
    }

    // MARK: - New strings (tab titles, sheet copy)

    func testTabTitlesAreLocalizedEnAndNe() {
        for tab in Section.allCases {
            let key = tab.titleKey
            XCTAssertEqual(key, "settings.tabs.\(tab.rawValue)")
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key, "\(key) must have an English value")
            XCTAssertNotEqual(ne, key, "\(key) must have a Nepali value")
            XCTAssertNotEqual(en, ne, "\(key) must actually be translated")
        }
    }

    func testHiddenSheetCopyIsLocalizedEnAndNe() {
        for key in ["settings.hidden.title", "settings.hidden.open",
                    "settings.hidden.hint", "settings.hidden.note"] {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key, "\(key) must have an English value")
            XCTAssertNotEqual(ne, key, "\(key) must have a Nepali value")
        }
    }

    func testEncoderDoorKeepsItsKey() {
        // The visible door to the internal AI screen ([ENCODER-RUNTIME-
        // TOGGLE]) rides the System tab now; its label must survive.
        let key = "settings.encoder.title"
        XCTAssertNotEqual(L10n.str(key, locale: english), key)
        XCTAssertNotEqual(L10n.str(key, locale: nepali), key)
    }

    // MARK: - Long-press (spec §3)

    func testLongPressDurationMatchesTheSpec() {
        // Spec §3: "e.g., 0.8s". Pinned because it is the only part of the
        // gesture a unit test can hold (the gesture itself is view-level).
        XCTAssertEqual(SettingsView.hiddenSheetLongPressDuration, 0.8,
                       accuracy: 0.001)
    }

    // MARK: - First-use record

    func testHiddenSheetUsageRecordsTheFirstOpen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "settings.tab.mapping.tests"))
        HiddenSettingsSheetUsage.clear(defaults: defaults)
        XCTAssertFalse(HiddenSettingsSheetUsage.hasBeenUsed(defaults: defaults),
                       "a fresh install must show the hint, not the ellipsis")

        HiddenSettingsSheetUsage.markUsed(defaults: defaults)
        XCTAssertTrue(HiddenSettingsSheetUsage.hasBeenUsed(defaults: defaults))

        // The view observes exactly this key through @AppStorage.
        XCTAssertTrue(defaults.bool(forKey: HiddenSettingsSheetUsage.defaultsKey))
        HiddenSettingsSheetUsage.clear(defaults: defaults)
        XCTAssertFalse(HiddenSettingsSheetUsage.hasBeenUsed(defaults: defaults))
    }

    // MARK: - The manual must not drift from the tabs (shipped content)

    func testTheManualSettingsTourNamesEveryShippedTab() throws {
        // The bundled manual walks the Settings screen for the household;
        // it used to walk the old single-scroll order. Composing the
        // assertions from the same L10n keys the tab bar renders means a
        // retitled tab fails here rather than quietly lying in the manual.
        let sections = try bundledManual()
        let tour = try XCTUnwrap(sections.first { $0.id == "settings" },
                                 "the manual must keep its Settings tour")
        let en = tour.paragraphs(locale: english).joined(separator: "\n")
        let ne = tour.paragraphs(locale: nepali).joined(separator: "\n")
        for tab in Section.allCases {
            let enTitle = L10n.str(tab.titleKey, locale: english)
            let neTitle = L10n.str(tab.titleKey, locale: nepali)
            XCTAssertTrue(en.contains(enTitle),
                          "the Settings tour must name the \"\(enTitle)\" tab")
            XCTAssertTrue(ne.contains(neTitle),
                          "सेटिङको भ्रमणले \"\(neTitle)\" ट्याबको नाम लिनुपर्छ")
        }
    }

    func testTheManualSettingsTourNamesEveryVisibleRow() throws {
        // The tour drifted once: "Daily routine" (menu-audit) and "Events"
        // (rich-events) shipped as rows while the manual's Settings tour
        // still listed only medication, alarms, calendar and sharing. The
        // household reads the manual, not the table. Composing the
        // assertions from the same L10n keys the rows render means a row
        // the tour forgets fails here instead of quietly misleading a
        // family member.
        let sections = try bundledManual()
        let tour = try XCTUnwrap(sections.first { $0.id == "settings" },
                                 "the manual must keep its Settings tour")
        let en = tour.paragraphs(locale: english).joined(separator: "\n")
        let ne = tour.paragraphs(locale: nepali).joined(separator: "\n")
        for row in Section.allCases.flatMap(\.rows) {
            let enTitle = L10n.str(row.titleKey, locale: english)
            let neTitle = L10n.str(row.titleKey, locale: nepali)
            XCTAssertTrue(en.contains(enTitle),
                          "the Settings tour must name the \"\(enTitle)\" row")
            XCTAssertTrue(ne.contains(neTitle),
                          "सेटिङको भ्रमणले \"\(neTitle)\" पङ्क्तिको नाम लिनुपर्छ")
        }
    }

    func testTheManualNamesYouTubeWhereItNowLives() throws {
        // The hidden sheet's rows are absent from the tabs on purpose, so
        // the manual's Settings tour is the family's only written pointer
        // to them — and YouTube, which the menu-deepening pass moved into
        // the sheet, has to be named there in both languages (a row that
        // moves without its manual sentence leaves the household hunting
        // for a screen the tour still puts under Tools).
        let sections = try bundledManual()
        let tour = try XCTUnwrap(sections.first { $0.id == "settings" },
                                 "the manual must keep its Settings tour")
        let en = tour.paragraphs(locale: english).joined(separator: "\n")
        let ne = tour.paragraphs(locale: nepali).joined(separator: "\n")
        let youtubeEn = L10n.str(Destination.youtube.titleKey, locale: english)
        let youtubeNe = L10n.str(Destination.youtube.titleKey, locale: nepali)
        XCTAssertTrue(en.contains(youtubeEn),
                      "the technical-settings paragraph must name \"\(youtubeEn)\"")
        XCTAssertTrue(ne.contains(youtubeNe),
                      "प्राविधिक सेटिङको अनुच्छेदले \"\(youtubeNe)\" को नाम लिनुपर्छ")
    }

    func testTheManualDoesNotPromiseAStaleHoldDuration() throws {
        // The gesture is 0.8s; the manual shipped "1.5 seconds" and the
        // household would hold the title far past the threshold. Both
        // languages, whole manual — a stale duration anywhere is a bug.
        let sections = try bundledManual()
        for paragraph in sections.flatMap({ $0.paragraphsEn + $0.paragraphsNe }) {
            XCTAssertFalse(paragraph.contains("1.5 second"), paragraph)
            XCTAssertFalse(paragraph.contains("१.५ सेकेन्ड"), paragraph)
        }
    }

    private func bundledManual() throws -> [UserManualSection] {
        guard UserManualCatalog.bundledURL() != nil else {
            throw XCTSkip("userManual.json not bundled yet "
                          + "(run ./build.sh generate)")
        }
        return try XCTUnwrap(UserManualCatalog.bundledSections(),
                             "the bundled userManual.json must decode")
    }

    // MARK: - Helpers

    private func duplicates<T: Hashable>(in values: [T]) -> [T] {
        var seen: Set<T> = []
        var repeated: Set<T> = []
        for value in values where !seen.insert(value).inserted {
            repeated.insert(value)
        }
        return Array(repeated)
    }
}
