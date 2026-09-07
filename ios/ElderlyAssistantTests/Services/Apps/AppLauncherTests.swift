import XCTest
@testable import ElderlyAssistant

/// `AppLauncher` — the catalog + launch seam behind the Home quick-access
/// row and the Settings picker (Quick Access Apps feature, 2026-09-06).
///
/// Pins the catalog invariants (18 apps, unique storage keys / name keys /
/// schemes / symbols, Apple built-ins first, scheme-only root URLs, cap
/// 8), the pure restore/validation and search rules, and — through a
/// scripted opener — that installed-probes and opens use exactly the
/// scheme root URL. Also pins the Info.plist contract that every catalog
/// scheme is declared in `LSApplicationQueriesSchemes` (the honest
/// `canOpenURL` answer depends on it) with headroom under the 50-scheme
/// cap.
final class AppLauncherTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Catalog invariants

    func testCatalogHas18Apps() {
        XCTAssertEqual(AppLauncher.catalog.count, 18)
    }

    func testCatalogIDsNameKeysSchemesAndSymbolsAreAllUnique() {
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.id)).count, 18)
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.nameKey)).count, 18)
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.scheme)).count, 18)
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.systemImage)).count, 18)
    }

    func testOfficialBrandGlyphsCoverEveryThirdPartyAppExceptIMO() {
        // Official glyphs (CC0 simple-icons, 2026-09-07) for every
        // third-party app EXCEPT imo — simple-icons removed IMO's glyph
        // over trademark concerns, and the catalog must not pretend a
        // stand-in is official. Apple built-ins keep SF Symbols (their
        // official glyphs) with nil imageName.
        let builtInIDs = ["phone", "messages", "facetime", "mail", "calendar", "maps"]
        let thirdParty = AppLauncher.catalog.filter { !builtInIDs.contains($0.id) }
        let withGlyph = thirdParty.filter { $0.imageName != nil }
        XCTAssertEqual(withGlyph.map(\.id),
                       ["whatsapp", "messenger", "facebook", "instagram", "youtube",
                        "gmail", "googlemaps", "chrome", "zoom", "telegram", "viber"])
        XCTAssertNil(AppLauncher.app(for: "imo")?.imageName)
        // Glyph asset names are unique and namespaced.
        let names = thirdParty.compactMap(\.imageName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("appIcon.") })
        // Built-ins: SF Symbols ARE the official Apple glyphs.
        XCTAssertTrue(AppLauncher.catalog.prefix(6).allSatisfy { $0.imageName == nil })

        // Every glyph carries its official brand tint as a 6-digit
        // "RRGGBB" hex — the CC0 vectors are single-color paths that
        // render BLACK without a tint, which is the "all icons the same
        // color" complaint this closes. Glyph and tint travel together:
        // among third-party apps only imo (no glyph) has none, and
        // built-ins (SF Symbols, no glyph) have none either. (2026-09-07)
        for app in withGlyph {
            let tint = app.glyphTintHex
            XCTAssertNotNil(tint, "\(app.id) must carry an official brand tint")
            XCTAssertEqual(tint?.count, 6, "\(app.id) tint must be 6 digits")
            XCTAssertTrue(tint?.allSatisfy(\.isHexDigit) ?? false,
                          "\(app.id) tint \(tint ?? "nil") must be pure hex")
        }
        XCTAssertEqual(thirdParty.filter { $0.glyphTintHex == nil }.map(\.id), ["imo"])
        XCTAssertTrue(AppLauncher.catalog.prefix(6).allSatisfy { $0.glyphTintHex == nil })
        XCTAssertNil(AppLauncher.app(for: "imo")?.glyphTintHex)
    }

    func testCatalogStartsWithAppleBuiltInsInHomeScreenOrder() {
        // Display order: Apple built-ins first (phone → maps), then
        // third-party apps — so a fresh picker feels like the home screen.
        XCTAssertEqual(AppLauncher.catalog.prefix(6).map(\.id),
                       ["phone", "messages", "facetime", "mail", "calendar", "maps"])
        XCTAssertEqual(AppLauncher.catalog[6].id, "whatsapp",
                       "the first third-party app follows the built-ins")
    }

    func testMaxFavouritesIsEight() {
        XCTAssertEqual(AppLauncher.maxFavourites, 8)
    }

    func testEveryCatalogAppRootURLIsItsSchemeOnly() {
        // The probe/open URL is always the bare scheme root — never a
        // path that depends on a third-party app's URL grammar.
        for app in AppLauncher.catalog {
            XCTAssertEqual(app.rootURL.absoluteString, "\(app.scheme)://",
                           "\(app.id) must probe/open its scheme root")
        }
    }

    // MARK: - Catalog lookup & stored-order mapping

    func testAppForKnownIDReturnsTheApp() {
        XCTAssertEqual(AppLauncher.app(for: "whatsapp")?.scheme, "whatsapp")
        XCTAssertEqual(AppLauncher.app(for: "calendar")?.id, "calendar")
    }

    func testAppForUnknownIDIsNil() {
        XCTAssertNil(AppLauncher.app(for: "not-an-app"))
        XCTAssertNil(AppLauncher.app(for: ""))
    }

    func testAppsForIDsMapsInStoredOrderAndDropsUnknown() {
        let mapped = AppLauncher.apps(for: ["calendar", "bogus", "whatsapp"])
        XCTAssertEqual(mapped.map(\.id), ["calendar", "whatsapp"])
    }

    func testValidatedFavouriteIDsKeepsOrderAndFirstWinsOnDuplicates() {
        // Stale restore must never wedge the UI: unknown ids drop,
        // duplicates collapse to their first occurrence, order survives.
        let cleaned = AppLauncher.validatedFavouriteIDs(
            ["whatsapp", "bogus", "calendar", "whatsapp", "calendar", "phone"])
        XCTAssertEqual(cleaned, ["whatsapp", "calendar", "phone"])
    }

    func testValidatedFavouriteIDsCapsAtEight() {
        let cleaned = AppLauncher.validatedFavouriteIDs(AppLauncher.catalog.map(\.id))
        XCTAssertEqual(cleaned.count, 8)
        XCTAssertEqual(cleaned, AppLauncher.catalog.prefix(8).map(\.id))
    }

    func testValidatedFavouriteIDsHonoursCustomCap() {
        let cleaned = AppLauncher.validatedFavouriteIDs(
            ["phone", "maps", "whatsapp", "telegram"], cap: 2)
        XCTAssertEqual(cleaned, ["phone", "maps"])
    }

    func testValidatedFavouriteIDsHandlesEmptyAndGarbageInput() {
        XCTAssertEqual(AppLauncher.validatedFavouriteIDs([]), [])
        XCTAssertEqual(AppLauncher.validatedFavouriteIDs(["nope", "", "also-nope"]), [])
    }

    // MARK: - Localized names (en + ne resolve for every catalog key)

    func testEveryCatalogNameKeyResolvesInEnglishAndNepali() {
        for app in AppLauncher.catalog {
            let english = L10n.str(app.nameKey, locale: en)
            let nepali = L10n.str(app.nameKey, locale: ne)
            XCTAssertNotEqual(english, app.nameKey,
                              "\(app.nameKey) must resolve in en.lproj")
            XCTAssertNotEqual(nepali, app.nameKey,
                              "\(app.nameKey) must resolve in ne.lproj")
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(nepali.isEmpty)
        }
    }

    func testWhatsAppNameResolvesInBothScripts() {
        let app = AppLauncher.app(for: "whatsapp")!
        XCTAssertEqual(L10n.str(app.nameKey, locale: en), "WhatsApp")
        XCTAssertEqual(L10n.str(app.nameKey, locale: ne), "ह्वाट्सएप")
    }

    func testMessengerAndCalendarNepaliNamesMatchExistingVocabulary() {
        XCTAssertEqual(L10n.str(AppLauncher.app(for: "messenger")!.nameKey, locale: ne),
                       "मेसेन्जर")
        XCTAssertEqual(L10n.str(AppLauncher.app(for: "calendar")!.nameKey, locale: ne),
                       "पात्रो")
    }

    // MARK: - Search (pure, catalog order, cross-script)

    func testSearchEmptyAndWhitespaceQueriesReturnNothing() {
        XCTAssertEqual(AppLauncher.search(query: "", in: en), [])
        XCTAssertEqual(AppLauncher.search(query: "   ", in: ne), [])
    }

    func testSearchIsCaseInsensitiveOnLatinNames() {
        XCTAssertEqual(AppLauncher.search(query: "WHATSAPP", in: en).map(\.id), ["whatsapp"])
        XCTAssertEqual(AppLauncher.search(query: "wHaTsApP", in: en).map(\.id), ["whatsapp"])
    }

    func testSearchFindsAppByDevanagariNameInNepaliSession() {
        XCTAssertEqual(AppLauncher.search(query: "ह्वाट्सएप", in: ne).map(\.id), ["whatsapp"])
        XCTAssertEqual(AppLauncher.search(query: "पात्रो", in: ne).map(\.id), ["calendar"])
    }

    func testSearchStillMatchesLatinNameAndIDInNepaliSession() {
        // A Nepali session must not hide English-name or raw-id matches —
        // "whatsapp" (id) and "Calendar" (English name) both resolve.
        XCTAssertEqual(AppLauncher.search(query: "whatsapp", in: ne).map(\.id), ["whatsapp"])
        XCTAssertEqual(AppLauncher.search(query: "Calendar", in: ne).map(\.id), ["calendar"])
    }

    func testSearchMatchesRawID() {
        // "googlemaps" (unspaced) can only hit the id haystack — the
        // English name is "Google Maps" (spaced) and the Nepali name is
        // Devanagari, so a Nepali session still finds the app by its id.
        XCTAssertEqual(AppLauncher.search(query: "googlemaps", in: ne).map(\.id),
                       ["googlemaps"])
    }

    func testSearchTrimsSurroundingWhitespace() {
        XCTAssertEqual(AppLauncher.search(query: "  whatsapp  ", in: en).map(\.id), ["whatsapp"])
    }

    func testSearchReturnsMatchesInCatalogOrder() {
        // "ma" hits Mail, Maps, Gmail and Google Maps — results must come
        // back in catalog (display) order, not arbitrary set order.
        XCTAssertEqual(AppLauncher.search(query: "ma", in: en).map(\.id),
                       ["mail", "maps", "gmail", "googlemaps"])
        XCTAssertEqual(AppLauncher.search(query: "map", in: en).map(\.id),
                       ["maps", "googlemaps"])
    }

    // MARK: - Installed probe & open (through the opener seam)

    func testIsInstalledProbesExactlyTheAppsSchemeRoot() {
        let opener = FakeCallLinkOpener(installed: ["whatsapp": true])
        let launcher = AppLauncher(opener: opener)
        let whatsapp = AppLauncher.app(for: "whatsapp")!

        XCTAssertTrue(launcher.isInstalled(whatsapp))
        XCTAssertFalse(launcher.isInstalled(AppLauncher.app(for: "imo")!))
        XCTAssertEqual(opener.canOpenChecks.map(\.absoluteString),
                       ["whatsapp://", "imo://"],
                       "the probe is the scheme root and only the scheme root")
    }

    func testOpenOpensExactlyTheAppsSchemeRoot() {
        let opener = FakeCallLinkOpener(installed: ["whatsapp": true])
        let launcher = AppLauncher(opener: opener)

        launcher.open(AppLauncher.app(for: "whatsapp")!)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["whatsapp://"])
    }

    // MARK: - Info.plist declares every probe scheme (≤ 50 cap)

    func testInfoPlistDeclaresEveryCatalogScheme() {
        let declared = Bundle.main
            .object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        for app in AppLauncher.catalog {
            XCTAssertTrue(declared.contains(app.scheme),
                          "\(app.scheme) (app \(app.id)) must be declared in " +
                          "LSApplicationQueriesSchemes or canOpenURL cannot answer honestly")
        }
        XCTAssertLessThanOrEqual(declared.count, 50,
                                 "iOS hard-caps query schemes at 50 — headroom must stay")
    }
}

/// Scripted `CallLinkOpening` — answers per-scheme so a test can fake some
/// apps installed and others absent, recording every check and open.
private final class FakeCallLinkOpener: CallLinkOpening {
    private let installed: [String: Bool]
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    init(installed: [String: Bool] = [:]) {
        self.installed = installed
    }

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return installed[url.scheme ?? ""] ?? false
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}
