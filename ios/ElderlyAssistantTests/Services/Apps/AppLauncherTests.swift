import XCTest
@testable import ElderlyAssistant

/// `AppLauncher` — the catalog + launch seam behind the Home quick-access
/// row and the Settings picker (Quick Access Apps feature, 2026-09-06).
///
/// Pins the catalog invariants (28 apps, unique storage keys / name keys /
/// symbols, one `.camera` entry with no URL, Apple built-ins first,
/// scheme-only root URLs with the tel:/sms: slashes-less exception and the
/// Settings panes' full `App-Prefs:root=…` form, cap 8), the pure
/// restore/validation and search rules, and — through a scripted opener —
/// that installed-probes and opens use exactly the launch URL. The
/// `launchPlan` section pins what a launch actually opens when the probe
/// fails (the public Settings fallback for the App-Prefs panes, the web
/// fallback, or the honest refusal), and the vocabulary section pins that
/// every catalog id and alias resolves — the one vocabulary the keyword
/// rules and the `launcher.open` prompt both read. Also pins
/// the Info.plist contract that every catalog scheme is declared in
/// `LSApplicationQueriesSchemes` (the honest `canOpenURL` answer depends
/// on it) with headroom under the 50-scheme cap — checked both against
/// the running app bundle and against the Info.plist source file the
/// launcher design calls out.
final class AppLauncherTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// The 10 entries the voice app launcher (2026-09-16) added to the
    /// 18 the Quick Access picker shipped with.
    private let launcherAppIDs = ["camera", "photos", "settings", "settingswifi",
                                  "settingsbluetooth", "settingsdisplay",
                                  "settingsaccessibility", "weather", "magnifier",
                                  "health"]

    /// Apple built-ins — the entries that ship with iOS, whose official
    /// glyph IS the SF Symbol (so they carry no brand-logo asset) —
    /// followed by the third-party apps.
    private let builtInIDs = ["phone", "messages", "facetime", "mail", "calendar", "maps"]
        + ["camera", "photos", "settings", "settingswifi", "settingsbluetooth",
           "settingsdisplay", "settingsaccessibility", "weather", "magnifier", "health"]

    // MARK: - Catalog invariants

    func testCatalogHas28Apps() {
        XCTAssertEqual(AppLauncher.catalog.count, 28)
    }

    func testCatalogIDsNameKeysAndSymbolsAreAllUnique() {
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.id)).count, 28)
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.nameKey)).count, 28)
        XCTAssertEqual(Set(AppLauncher.catalog.map(\.systemImage)).count, 28)
    }

    func testEveryCatalogEntryButCameraHasASchemeAndAProbeableURL() {
        // `scheme` is nil for exactly one entry — the camera — whose
        // in-app picker has no URL to probe (Kind.camera). It is also
        // the only `.camera` entry, and it must carry no scheme/URL of
        // its own: a stray URL there would send a launch to a scheme iOS
        // ignores.
        let noScheme = AppLauncher.catalog.filter { $0.scheme == nil }
        XCTAssertEqual(noScheme.map(\.id), ["camera"])
        XCTAssertTrue(noScheme.allSatisfy { $0.kind == .camera })
        XCTAssertTrue(noScheme.allSatisfy { $0.rootURL == nil && $0.urlOverride == nil })

        // The surviving duplicate scheme is intentional: the Settings
        // panes all ride the one `App-Prefs` scheme (each pane differs
        // only by its `App-Prefs:root=…` URL).
        XCTAssertEqual(Set(AppLauncher.catalog.compactMap(\.scheme)).count, 23)

        for app in AppLauncher.catalog where app.kind == .url {
            XCTAssertNotNil(app.scheme, "\(app.id) launches by URL and needs a scheme")
            XCTAssertNotNil(app.rootURL,
                            "\(app.id) must have a parseable launch URL — a typo would " +
                            "otherwise degrade silently to a canOpenURL miss")
        }
    }

    func testLauncherAddedTenEntries() {
        let launcherEntries = launcherAppIDs.map { AppLauncher.app(for: $0) }
        XCTAssertTrue(launcherEntries.allSatisfy { $0 != nil },
                      "every launcher catalog entry must exist")
        // The existing 18 are untouched: the picker's old favourites must
        // keep resolving through `AppLauncher.apps(for:)`.
        XCTAssertEqual(AppLauncher.catalog.count - launcherAppIDs.count, 18)
    }

    func testOfficialBrandLogosCoverEveryThirdPartyAppExceptIMO() {
        // Official multicolor logos (Wikimedia Commons PNGs, 2026-09-07 —
        // see AppIcons.xcassets/README.md for sources) for every
        // third-party app EXCEPT imo — simple-icons removed IMO's logo
        // over trademark concerns and Commons hosts none, so the catalog
        // must not pretend a stand-in is official. Apple built-ins keep
        // SF Symbols (their official glyphs) with nil imageName — the
        // launcher entries (Camera, Photos, Settings, Weather, Magnifier,
        // Health) are Apple apps too.
        let withLogo = AppLauncher.catalog.filter { $0.imageName != nil }
        XCTAssertEqual(withLogo.map(\.id),
                       ["whatsapp", "messenger", "facebook", "instagram", "youtube",
                        "gmail", "googlemaps", "chrome", "zoom", "telegram", "viber"])
        XCTAssertNil(AppLauncher.app(for: "imo")?.imageName)
        // Logo asset names are unique and namespaced.
        let names = withLogo.compactMap(\.imageName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("appIcon.") })
        // Built-ins: SF Symbols ARE the official Apple glyphs.
        let builtIns = AppLauncher.catalog.filter { builtInIDs.contains($0.id) }
        XCTAssertEqual(builtIns.count, builtInIDs.count)
        XCTAssertTrue(builtIns.allSatisfy { $0.imageName == nil })
    }

    func testCatalogStartsWithAppleBuiltInsInHomeScreenOrder() {
        // Display order: Apple built-ins first (phone → maps), then the
        // launcher's other built-ins, then third-party apps — so a fresh
        // picker feels like the home screen.
        XCTAssertEqual(AppLauncher.catalog.prefix(6).map(\.id),
                       ["phone", "messages", "facetime", "mail", "calendar", "maps"])
        XCTAssertEqual(AppLauncher.catalog[6].id, "camera",
                       "the launcher's built-ins follow the original built-ins")
        XCTAssertEqual(AppLauncher.catalog[16].id, "whatsapp",
                       "the first third-party app still follows every built-in")
    }

    func testMaxFavouritesIsEight() {
        XCTAssertEqual(AppLauncher.maxFavourites, 8)
    }

    func testEveryCatalogAppRootURLIsItsSchemeOnly() {
        // The probe/open URL is the bare scheme root — never a path that
        // depends on a third-party app's URL grammar. Two exceptions:
        //
        //  - Apple's own telephony schemes (tel-scheme fix, 2026-09-07):
        //    their root URLs carry NO slashes (`tel:`, `sms:`) because
        //    iOS does not handle the slashed form for an empty number.
        //  - The launcher's Settings panes (2026-09-16), pinned exactly
        //    below: iOS opens a pane only from the full `App-Prefs:root=…`
        //    URL, which has no `//` at all.
        //
        // The camera is the one entry with no URL (Kind.camera).
        for app in AppLauncher.catalog where app.urlOverride == nil {
            guard let scheme = app.scheme, let rootURL = app.rootURL else { continue }
            let expected = (scheme == "tel" || scheme == "sms")
                ? "\(scheme):"
                : "\(scheme)://"
            XCTAssertEqual(rootURL.absoluteString, expected,
                           "\(app.id) must probe/open its scheme root")
        }
    }

    func testLauncherEntryLaunchURLsArePinnedExactly() {
        // A typo in one of these strings would not crash and would not
        // fail to open anything visible — it would just make `canOpenURL`
        // answer false, i.e. the assistant would claim a perfectly
        // installed app is missing. Pinned character for character.
        let expected: [String: String] = [
            // Community-tier scheme roots (device-verified per the design).
            "photos": "photos-redirect://",
            "weather": "weather://",
            "magnifier": "apple-magnifier://",
            // Apple-documented.
            "health": "x-apple-health://",
            // Settings panes: full App-Prefs URLs, no slashes.
            "settings": "App-Prefs:root=",
            "settingswifi": "App-Prefs:root=WIFI",
            "settingsbluetooth": "App-Prefs:root=Bluetooth",
            "settingsdisplay": "App-Prefs:root=DISPLAY",
            "settingsaccessibility": "App-Prefs:root=ACCESSIBILITY",
            // Already-whitelisted third-party roots the launcher reuses.
            "facebook": "fb://",
            "instagram": "instagram://",
            "youtube": "youtube://",
            "whatsapp": "whatsapp://",
            "calendar": "calshow://"
        ]
        for (id, url) in expected {
            XCTAssertEqual(AppLauncher.app(for: id)?.rootURL?.absoluteString, url,
                           "\(id) must launch exactly \(url)")
        }
    }

    func testSettingsPanesAllProbeTheOneAppPrefsScheme() {
        // Every pane is a deep link into the SAME app, so they share the
        // `App-Prefs` scheme — which is also why the Info.plist
        // whitelist needs both casings of it, not one per pane.
        let panes = ["settings", "settingswifi", "settingsbluetooth",
                     "settingsdisplay", "settingsaccessibility"]
        for id in panes {
            let app = AppLauncher.app(for: id)!
            XCTAssertEqual(app.scheme, "App-Prefs", "\(id) rides the App-Prefs scheme")
            XCTAssertEqual(app.kind, .url, "\(id) launches by URL")
            XCTAssertTrue(app.urlOverride?.hasPrefix("App-Prefs:root=") == true,
                          "\(id) must carry a full App-Prefs:root= URL")
        }
    }

    func testCameraEntryHasNoURLAndResolvesToTheInAppPicker() {
        // iOS has no camera URL scheme a third-party app can use (the
        // community `camera://` only resolves inside Shortcuts), so the
        // camera is catalogued WITHOUT a URL and flagged for the in-app
        // UIImagePickerController instead. Anything else here would send
        // the launch into a scheme iOS ignores.
        let camera = AppLauncher.app(for: "camera")!
        XCTAssertEqual(camera.kind, .camera)
        XCTAssertNil(camera.scheme)
        XCTAssertNil(camera.rootURL)
        XCTAssertNil(camera.urlOverride)
        // The camera UI is in-process, so the seeded probe is honestly
        // "available" — whether the DEVICE has a camera it can use is
        // answered at capture time, not here.
        let opener = FakeCallLinkOpener()
        XCTAssertTrue(AppLauncher(opener: opener).isInstalled(camera))
        XCTAssertTrue(opener.canOpenChecks.isEmpty,
                      "an in-app entry must not probe a URL")
    }

    func testPhoneRootURLIsSlashesLessTel() {
        // [PHONE-DEEPLINKS-REVERT] (2026-09-19) Device-verified: the
        // mobilephone-* schemes are NOT registered by the Phone app on
        // stock iOS (canOpenURL fails with OSStatus -10814). The Phone
        // tile returns to the slashes-less `tel:` dialer — the only
        // honest public surface Apple exposes. Pinned so neither the
        // slashed tel form nor the dead mobilephone schemes can regress.
        XCTAssertEqual(AppLauncher.app(for: "phone")?.rootURL?.absoluteString, "tel:")
    }

    func testMessagesRootURLIsSlashesLessSMS() {
        // Same slashes-less Apple-telephony exception as `tel:` above —
        // `sms://` with no body is not a URL Messages handles.
        XCTAssertEqual(AppLauncher.app(for: "messages")?.rootURL?.absoluteString, "sms:")
    }

    func testOtherAppleBuiltInRootURLsKeepSlashes() {
        // Only Apple's telephony schemes (tel/sms) shed the slashes —
        // every other catalog root stays `scheme://`.
        for id in ["facetime", "mail", "calendar", "maps"] {
            let app = AppLauncher.app(for: id)!
            let scheme = app.scheme!
            XCTAssertEqual(app.rootURL?.absoluteString, "\(scheme)://",
                           "\(id) keeps the slashed scheme root")
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

    func testLauncherNepaliNamesReuseTheAppVocabulary() {
        // The launcher's names must read the way the rest of the app
        // already speaks: Settings is सेटिङ, Weather is मौसम, Photo is
        // फोटो, Health is स्वास्थ्य (see briefing.weather,
        // appliance.takePhoto, settings.title, router.healthNotAvailable).
        let expected = ["settings": "सेटिङ",
                        "weather": "मौसम",
                        "health": "स्वास्थ्य",
                        "camera": "क्यामेरा",
                        "photos": "फोटो"]
        for (id, nepali) in expected {
            XCTAssertEqual(L10n.str(AppLauncher.app(for: id)!.nameKey, locale: ne), nepali,
                           "\(id) must use the app's existing Nepali word")
        }
    }

    // MARK: - Spoken aliases (keyword-rule vocabulary) & web fallbacks

    func testLauncherKeywordEntriesCarryDevanagariAndLatinAliases() {
        // The keyword fast-path (launcher plan T5) matches these exact
        // full lexemes, in both scripts, for the highest-frequency
        // launches.
        let keywordIDs = ["camera", "photos", "settings", "weather",
                          "whatsapp", "youtube", "facebook"]
        for id in keywordIDs {
            let aliases = AppLauncher.app(for: id)!.aliases
            XCTAssertFalse(aliases.isEmpty, "\(id) needs at least one spoken alias")
            XCTAssertTrue(aliases.contains { $0.allSatisfy(\.isASCII) },
                          "\(id) needs a Latin alias")
            XCTAssertTrue(aliases.contains { $0.contains { !$0.isASCII } },
                          "\(id) needs a Devanagari alias")
        }
    }

    func testOnlyTheFourSpecdThirdPartyAppsCarryAWebFallback() {
        // Spec §v1 catalog: "web" fallback for Facebook, Instagram,
        // YouTube, WhatsApp — and for nobody else. A fallback invented
        // for, say, Settings would open Safari on a page that does not
        // exist.
        let withFallback = AppLauncher.catalog
            .filter { $0.webFallback != nil }
            .map(\.id)
        XCTAssertEqual(withFallback, ["whatsapp", "facebook", "instagram", "youtube"])
        for id in withFallback {
            let url = AppLauncher.app(for: id)!.webFallback!
            XCTAssertEqual(url.scheme, "https", "\(id)'s fallback must be a web URL")
        }
        XCTAssertEqual(AppLauncher.app(for: "facebook")?.webFallback?.absoluteString,
                       "https://www.facebook.com/")
        XCTAssertEqual(AppLauncher.app(for: "whatsapp")?.webFallback?.absoluteString,
                       "https://web.whatsapp.com/")
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
        // "ma" hits Mail, Maps, Magnifier, Gmail and Google Maps — results
        // must come back in catalog (display) order, not arbitrary set
        // order.
        XCTAssertEqual(AppLauncher.search(query: "ma", in: en).map(\.id),
                       ["mail", "maps", "magnifier", "gmail", "googlemaps"])
        XCTAssertEqual(AppLauncher.search(query: "map", in: en).map(\.id),
                       ["maps", "googlemaps"])
    }

    func testSearchFindsTheLauncherEntriesByEnglishAndNepaliName() {
        XCTAssertEqual(AppLauncher.search(query: "camera", in: en).map(\.id), ["camera"])
        XCTAssertEqual(AppLauncher.search(query: "क्यामेरा", in: ne).map(\.id), ["camera"])
        XCTAssertEqual(AppLauncher.search(query: "मौसम", in: ne).map(\.id), ["weather"])
        XCTAssertEqual(AppLauncher.search(query: "settings", in: en).map(\.id),
                       ["settings", "settingswifi", "settingsbluetooth",
                        "settingsdisplay", "settingsaccessibility"])
    }

    // MARK: - Installed probe & open (through the opener seam)

    func testIsInstalledProbesExactlyTheAppsLaunchURL() {
        let opener = FakeCallLinkOpener(installed: ["whatsapp": true,
                                                    "App-Prefs": true])
        let launcher = AppLauncher(opener: opener)
        let whatsapp = AppLauncher.app(for: "whatsapp")!

        XCTAssertTrue(launcher.isInstalled(whatsapp))
        XCTAssertFalse(launcher.isInstalled(AppLauncher.app(for: "imo")!))
        XCTAssertTrue(launcher.isInstalled(AppLauncher.app(for: "settingswifi")!))
        XCTAssertEqual(opener.canOpenChecks.map(\.absoluteString),
                       ["whatsapp://", "imo://", "App-Prefs:root=WIFI"],
                       "the probe is the entry's launch URL and nothing else")
    }

    func testOpenOpensExactlyTheAppsLaunchURL() {
        let opener = FakeCallLinkOpener(installed: ["whatsapp": true])
        let launcher = AppLauncher(opener: opener)

        launcher.open(AppLauncher.app(for: "whatsapp")!)
        launcher.open(AppLauncher.app(for: "settingsaccessibility")!)
        XCTAssertEqual(opener.opened.map(\.absoluteString),
                       ["whatsapp://", "App-Prefs:root=ACCESSIBILITY"],
                       "a Settings pane opens its own full App-Prefs URL")
    }

    func testOpenOfTheCameraEntryOpensNothing() {
        // The camera has no URL — its launch is the in-app picker the
        // launcher plugin presents. `open` must never invent a URL for
        // it (an unknown scheme would just be a silent no-op with an
        // "Opening Camera" announcement attached).
        let opener = FakeCallLinkOpener()
        AppLauncher(opener: opener).open(AppLauncher.app(for: "camera")!)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    // MARK: - Spoken resolution (app(matchingSpoken:), 2026-09-16)

    func testMatchingSpokenResolvesIDsAliasesAndDisplayNames() {
        // id
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "whatsapp", locale: ne)?.id, "whatsapp")
        // spoken alias, English and Devanagari
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "brightness", locale: en)?.id,
                       "settingsdisplay")
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "क्यामेरा", locale: ne)?.id, "camera")
        // the localized display name, in the active locale …
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "वाइफाइ सेटिङ", locale: ne)?.id,
                       "settingswifi")
        // … and the English one, even in a Nepali session
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "Wi-Fi Settings", locale: ne)?.id,
                       "settingswifi")
    }

    func testMatchingSpokenIsCaseAndDiacriticFoldedAndTrims() {
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "  WhatsApp  ", locale: en)?.id, "whatsapp")
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "WHATSAPP", locale: en)?.id, "whatsapp")
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "Zoôm", locale: en)?.id, "zoom",
                       "diacritic folding is the same net the search box uses")
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "फोटो", locale: ne)?.id, "photos")
    }

    /// The regression this resolver exists to avoid (the Devanagari
    /// substring-grapheme lesson): matching is exact, full-lexeme.
    /// A phrase that CONTAINS an app name must not resolve to it — the
    /// wrong app opened on an elder's phone is worse than an honest
    /// "I don't know that app".
    func testMatchingSpokenNeverMatchesASubstring() {
        XCTAssertNil(AppLauncher.app(matchingSpoken: "क्यामेरा खोल", locale: ne),
                     "a phrase is not an app name")
        XCTAssertNil(AppLauncher.app(matchingSpoken: "open camera", locale: en))
        XCTAssertNil(AppLauncher.app(matchingSpoken: "whatsapp को सन्देश", locale: ne))
        XCTAssertNil(AppLauncher.app(matchingSpoken: "you", locale: en),
                     "'you' ⊂ 'youtube' but must not launch it")
        XCTAssertNil(AppLauncher.app(matchingSpoken: "map", locale: en),
                     "'map' ⊂ 'Maps'/'Google Maps' but is not either name")
        XCTAssertNil(AppLauncher.app(matchingSpoken: "face", locale: en))
    }

    func testMatchingSpokenReturnsNilForEmptyAndUnknownInput() {
        XCTAssertNil(AppLauncher.app(matchingSpoken: "", locale: en))
        XCTAssertNil(AppLauncher.app(matchingSpoken: "   ", locale: ne))
        XCTAssertNil(AppLauncher.app(matchingSpoken: "tiktok", locale: en),
                     "an app outside the catalog is not a launch candidate")
    }

    func testMatchingSpokenResolvesTheCameraEntryLikeAnyOther() {
        // The camera has no URL and no alias-bearing scheme, but it is
        // still a catalog entry a voice launch may name — resolution must
        // not quietly skip it and leave "क्यामेरा खोल" unanswered.
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "camera", locale: en)?.id, "camera")
        XCTAssertEqual(AppLauncher.app(matchingSpoken: "Camera", locale: ne)?.id, "camera")
    }

    // MARK: - Web fallback (openWebFallback(_:))

    func testOpenWebFallbackOpensTheWebURLThroughTheOpenerSeam() {
        let opener = FakeCallLinkOpener()
        let launcher = AppLauncher(opener: opener)

        XCTAssertTrue(launcher.openWebFallback(AppLauncher.app(for: "whatsapp")!))
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://web.whatsapp.com/"])
        XCTAssertTrue(opener.canOpenChecks.isEmpty,
                      "the fallback is opened directly — the https probe cannot " +
                      "distinguish the app from Safari, so it is not consulted")
    }

    func testOpenWebFallbackRefusesEntriesThatHaveNone() {
        let opener = FakeCallLinkOpener()
        let launcher = AppLauncher(opener: opener)

        XCTAssertFalse(launcher.openWebFallback(AppLauncher.app(for: "settings")!))
        XCTAssertFalse(launcher.openWebFallback(AppLauncher.app(for: "imo")!))
        XCTAssertTrue(opener.opened.isEmpty,
                      "no fallback means the honest 'not installed' line, never a " +
                      "blind Safari launch")
    }

    // MARK: - Info.plist declares every probe scheme (≤ 50 cap)

    /// The launcher catalog's schemes, in a stable order, as
    /// `(scheme, the entry that uses it)` — the camera contributes none.
    private var catalogSchemes: [(scheme: String, appID: String)] {
        AppLauncher.catalog.compactMap { app in
            app.scheme.map { (scheme: $0, appID: app.id) }
        }
    }

    func testRunningAppBundleDeclaresEveryCatalogScheme() {
        // The plist the DEVICE actually reads: without the declaration,
        // `canOpenURL` answers false for a perfectly installed app and
        // the assistant tells the elder it is missing (the classic silent
        // launcher bug this test exists to catch).
        let declared = Bundle.main
            .object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        XCTAssertFalse(declared.isEmpty,
                       "the running test host must expose the app's Info.plist — an " +
                       "empty list would make this whole check vacuous")
        for (scheme, appID) in catalogSchemes {
            XCTAssertTrue(declared.contains(scheme),
                          "\(scheme) (app \(appID)) must be declared in " +
                          "LSApplicationQueriesSchemes or canOpenURL cannot answer honestly")
        }
        XCTAssertLessThanOrEqual(declared.count, 50,
                                 "iOS hard-caps query schemes at 50 — headroom must stay")
    }

    func testSourceInfoPlistDeclaresEveryCatalogScheme() {
        // Same contract, checked against the SOURCE Info.plist
        // (ios/ElderlyAssistant/Info.plist) rather than the built bundle:
        // a scheme added to the catalog and to the source file, but lost
        // on the way into the bundle (build-setting override, a
        // second plist), is exactly the failure the design's consistency
        // test (§Testing 1) calls for. Located relative to this test file
        // so it reads the file under review, not a copy.
        let testFile = URL(fileURLWithPath: #filePath)          // …/ElderlyAssistantTests/Services/Apps/
        let sourcePlist = testFile
            .deletingLastPathComponent()                        // …/Services/Apps
            .deletingLastPathComponent()                        // …/Services
            .deletingLastPathComponent()                        // …/ElderlyAssistantTests
            .deletingLastPathComponent()                        // …/ios
            .appendingPathComponent("ElderlyAssistant/Info.plist")

        guard let data = try? Data(contentsOf: sourcePlist),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("cannot read the source Info.plist at \(sourcePlist.path) — the " +
                    "catalog/plist consistency check cannot run")
            return
        }
        let declared = plist["LSApplicationQueriesSchemes"] as? [String] ?? []
        XCTAssertFalse(declared.isEmpty, "LSApplicationQueriesSchemes is missing or empty")
        for (scheme, appID) in catalogSchemes {
            XCTAssertTrue(declared.contains(scheme),
                          "\(scheme) (app \(appID)) must be declared in the source " +
                          "Info.plist's LSApplicationQueriesSchemes")
        }
        XCTAssertLessThanOrEqual(declared.count, 50,
                                 "iOS hard-caps query schemes at 50 — headroom must stay")
    }

    // MARK: - Settings fallback (voice app launcher code-review F9)
    //
    // The Settings entries ride the PRIVATE `App-Prefs` scheme, and the
    // pane ids behind it are undocumented — Apple may not answer the probe
    // at all, and a launch that then claimed "not installed" would hide an
    // app that ships with iOS (and read to review as private-API-only).
    // `launchPlan` is the one place the probe, the web fallback and the
    // public-settings fallback are weighed together.

    private let settingsEntryIDs = ["settings", "settingswifi", "settingsbluetooth",
                                    "settingsdisplay", "settingsaccessibility"]

    /// [F9] The defect: a pane whose `App-Prefs` probe fails was reported
    /// "not installed". The fix falls back to the public
    /// `UIApplication.openSettingsURLString` deep link.
    func testASettingsEntryFallsBackToThePublicSettingsDeepLink() {
        let opener = FakeCallLinkOpener()          // nothing answers the probe
        let publicSettings = URL(string: "app-settings:")!
        let launcher = AppLauncher(opener: opener,
                                   settingsFallbackURL: { publicSettings })
        let pane = AppLauncher.app(for: "settingswifi")!

        XCTAssertEqual(launcher.launchPlan(for: pane), .settingsFallback,
                       "an unanswered pane probe resolves to the Settings root")
        XCTAssertTrue(launcher.isInstalled(pane),
                      "Settings is on every iPhone — a failed PANE probe must not " +
                      "hide the Settings row")
        XCTAssertTrue(pane.isSettingsSurface)
        XCTAssertTrue(launcher.openSettingsFallback())
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["app-settings:"],
                       "the public deep link is what opens — never the private pane URL")
    }

    /// The probe keeps its job: every Settings entry still opens its OWN
    /// pane when the App-Prefs URL answers. The fallback is a consequence
    /// of a failed probe, never a replacement for the probe.
    func testEverySettingsEntryStillOpensItsOwnPaneWhenTheProbeAnswers() {
        let opener = FakeCallLinkOpener(installed: ["App-Prefs": true])
        let launcher = AppLauncher(opener: opener,
                                   settingsFallbackURL: { URL(string: "app-settings:") })

        for id in settingsEntryIDs {
            let app = AppLauncher.app(for: id)!
            XCTAssertTrue(app.isSettingsSurface, "\(id) is a Settings surface")
            XCTAssertEqual(launcher.launchPlan(for: app), .app,
                           "\(id) must open its own App-Prefs pane when the probe answers")
        }
        XCTAssertEqual(opener.canOpenChecks.map(\.absoluteString),
                       settingsEntryIDs.map { AppLauncher.app(for: $0)!.rootURL!.absoluteString },
                       "each pane is probed by its own URL — no shared shortcut")
        XCTAssertTrue(opener.opened.isEmpty, "planning opens nothing by itself")
    }

    /// A pane that cannot answer AND has no fallback URL at all is
    /// honestly unavailable: nothing is announced that will not appear.
    func testASettingsEntryWithoutAFallbackURLIsHonestlyUnavailable() {
        let opener = FakeCallLinkOpener()
        let launcher = AppLauncher(opener: opener, settingsFallbackURL: { nil })
        let pane = AppLauncher.app(for: "settingsaccessibility")!

        XCTAssertEqual(launcher.launchPlan(for: pane), .unavailable)
        XCTAssertFalse(launcher.isInstalled(pane))
        XCTAssertFalse(launcher.openSettingsFallback())
        XCTAssertTrue(opener.opened.isEmpty)
    }

    /// The fallback is for SETTINGS surfaces only. An absent third-party
    /// app must never be answered with the Settings app — that would hand
    /// the elder a screen with nothing to do with what they asked for.
    func testTheSettingsFallbackNeverStandsInForAMissingThirdPartyApp() {
        let opener = FakeCallLinkOpener()
        let launcher = AppLauncher(opener: opener,
                                   settingsFallbackURL: { URL(string: "app-settings:") })

        let whatsapp = AppLauncher.app(for: "whatsapp")!
        let imo = AppLauncher.app(for: "imo")!
        XCTAssertFalse(whatsapp.isSettingsSurface)
        XCTAssertEqual(launcher.launchPlan(for: whatsapp), .webFallback,
                       "an absent app with a website goes to the web, never to Settings")
        XCTAssertEqual(launcher.launchPlan(for: imo), .unavailable,
                       "and one without a fallback is honestly unavailable")
        XCTAssertFalse(launcher.isInstalled(whatsapp),
                       "an absent app is absent: a website fallback must not make the " +
                       "picker's 'Installed' caption true")
        XCTAssertEqual(launcher.launchPlan(for: AppLauncher.app(for: "camera")!),
                       .camera, "the camera plan is the in-app picker, probe-free")
    }

    /// The two lines the Settings fallback adds — the question the elder
    /// answers and the announcement they hear — resolve in both locales
    /// and never reuse another outcome's wording (a borrowed "Opening
    /// Wi-Fi Settings." would claim the pane opened when it did not).
    func testSettingsFallbackLinesAreDistinctAndTranslated() {
        for locale in [en, ne] {
            let question = L10n.str("launcher.confirmOpenSettings", locale: locale)
            let announcement = L10n.str("apps.announce.openingSettings", locale: locale)
            XCTAssertFalse(question.isEmpty)
            XCTAssertFalse(announcement.isEmpty)
            XCTAssertNotEqual(question, "launcher.confirmOpenSettings",
                              "\(locale) is missing the fallback question")
            XCTAssertNotEqual(announcement, "apps.announce.openingSettings",
                              "\(locale) is missing the fallback announcement")
            XCTAssertNotEqual(question, L10n.str("launcher.confirmOpen", locale: locale))
            XCTAssertNotEqual(question, L10n.str("launcher.confirmOpenWeb", locale: locale))
            XCTAssertNotEqual(announcement, L10n.str("apps.announce.opened", locale: locale))
            XCTAssertNotEqual(announcement,
                              L10n.str("apps.announce.notInstalled", locale: locale))
            XCTAssertNotEqual(announcement,
                              L10n.str("apps.announce.openingWeb", locale: locale))
        }
    }

    // MARK: - One vocabulary, both paths (voice app launcher code-review
    // F11, F12)

    /// [F12] A keyword-only spelling is a defect by construction: the fast
    /// path fires on words the interpreter then rejects. The romanized
    /// `mausam` and the two extra WhatsApp spellings Whisper produces are
    /// catalog aliases now, so `app(matchingSpoken:)` — the model path's
    /// resolver — accepts exactly what the keyword rules match.
    func testKeywordOnlySpellingsArePartOfTheCatalogVocabulary() {
        let weather = AppLauncher.app(for: "weather")!
        let whatsapp = AppLauncher.app(for: "whatsapp")!
        XCTAssertTrue(weather.aliases.contains("mausam"))
        for spelling in ["व्हाट्सएप", "वाट्सएप"] {
            XCTAssertTrue(whatsapp.aliases.contains(spelling),
                          "\(spelling) is a spelling an elder says — the model path " +
                          "must accept it too")
        }
        for (spelling, expected) in [("mausam", "weather"),
                                     ("व्हाट्सएप", "whatsapp"),
                                     ("वाट्सएप", "whatsapp"),
                                     ("ह्वाट्सएप", "whatsapp")] {
            XCTAssertEqual(AppLauncher.app(matchingSpoken: spelling, locale: ne)?.id,
                           expected,
                           "\(spelling) reached the fast path but not the resolver")
        }
    }

    /// [F8, F11] The whole catalog is the vocabulary: every id and every
    /// spoken alias of every entry resolves back to that entry. This is
    /// the property the plugin's prompt depends on — anything it offers
    /// the model must be matchable, and anything the keyword rules read
    /// must resolve through the model path.
    func testEveryCatalogIDAndAliasResolvesToItsOwnEntry() {
        for app in AppLauncher.catalog {
            for token in [app.id] + app.aliases {
                XCTAssertEqual(AppLauncher.app(matchingSpoken: token, locale: ne)?.id,
                               app.id,
                               "\"\(token)\" is offered to the model and must resolve " +
                               "to \(app.id)")
                XCTAssertEqual(AppLauncher.app(matchingSpoken: token, locale: en)?.id,
                               app.id,
                               "\"\(token)\" must resolve in an English session too")
            }
        }
    }

    /// [F8] The four entries the deterministic rules now cover carry the
    /// aliases those rules read (`KeywordIntentRule`'s `appWords`): an
    /// entry with no alias makes its rule silent, so the coverage would
    /// vanish without a compile error.
    func testTheNewlyCoveredEntriesCarryTheAliasesTheirRulesRead() {
        let expected: [String: [String]] = [
            "magnifier": ["magnifier", "म्याग्निफायर"],
            "health": ["health", "स्वास्थ्य"],
            "instagram": ["instagram", "इन्स्टाग्राम"],
            "calendar": ["calendar", "पात्रो"]
        ]
        for (id, aliases) in expected {
            guard let app = AppLauncher.app(for: id) else {
                XCTFail("catalog entry missing for \(id)")
                continue
            }
            for alias in aliases {
                XCTAssertTrue(app.aliases.contains(alias),
                              "\(id) must carry \"\(alias)\" — its keyword rule reads the " +
                              "catalog aliases and nothing else")
            }
        }
    }

    // MARK: - Confirmation arbitration (voice app launcher code-review F1,
    // F2, F6, F10)
    //
    // The launcher shares the ONE confirmation window with the medication
    // challenge, so these are pure-policy tests of the rules that decide
    // who owns an answer, what a tap means, what a chip may say, and which
    // flywheel path a launch came from. They are the executable form of the
    // decisions `AppCoordinator.handleConfirmationResponse`,
    // `AppCoordinator.performAppLaunch`, `ConfirmationChips` and
    // `PendingAppLaunch.capturePath` make.

    /// [F1] A pended launch NEVER owns the next yes/no while a dose
    /// challenge is pended: the medication block in
    /// `handleConfirmationResponse` (FR-D03 double-dose check) has to
    /// receive the answer, so the launch block must not return early.
    func testMedicationChallengeOwnsTheAnswerWhenBothArePended() {
        XCTAssertEqual(
            AppCoordinator.ConfirmationArbitration.owner(pendingAppLaunch: "camera",
                                                         hasMedicationChallenge: true),
            .medication)
        XCTAssertEqual(
            AppCoordinator.ConfirmationArbitration.owner(pendingAppLaunch: "camera",
                                                         hasMedicationChallenge: false),
            .appLaunch)
        XCTAssertEqual(
            AppCoordinator.ConfirmationArbitration.owner(pendingAppLaunch: nil,
                                                         hasMedicationChallenge: true),
            .medication)
        XCTAssertEqual(
            AppCoordinator.ConfirmationArbitration.owner(pendingAppLaunch: nil,
                                                         hasMedicationChallenge: false),
            .none)
    }

    /// [F6] A tap that opens the app the question named IS the yes; a tap
    /// for a different app supersedes the question (recorded as the
    /// unanswered verdict, never as a confirmation).
    func testTileResolutionOfAPendedLaunchQuestion() {
        XCTAssertEqual(AppCoordinator.ConfirmationArbitration.tileResolution(
            pending: "camera", opened: "camera"), .confirmed)
        XCTAssertEqual(AppCoordinator.ConfirmationArbitration.tileResolution(
            pending: "camera", opened: "photos"), .superseded)
    }

    /// [F10] The flywheel's path label. A launch pended WITHOUT a
    /// confidence came from the deterministic keyword fast path — no model
    /// saw it — so it must not be recorded as "model". A launch with a
    /// confidence came from the interpreter/plugin path.
    func testLaunchCapturePathNamesTheKeywordStage() {
        XCTAssertEqual(AppCoordinator.PendingAppLaunch(appID: "camera",
                                                       confidence: nil).capturePath,
                       "keyword")
        XCTAssertEqual(AppCoordinator.PendingAppLaunch(appID: "camera",
                                                       confidence: 0.88).capturePath,
                       "model")
    }

    /// [F10] …and the path is actually threaded into the record: the
    /// capture's verdict row carries the path the recorder was given.
    func testLaunchCaptureRecordsTheKeywordPath() {
        let launch = AppCoordinator.PendingAppLaunch(appID: "photos", confidence: nil)
        let record = launch.capture.record(.confirmed, path: launch.capturePath)
        XCTAssertEqual(record.path, "keyword")
        XCTAssertEqual(record.action, "launcher.open")
        XCTAssertEqual(record.slots?["app"], "photos")
    }

    /// [F13] A launch question that expired names itself: one observable
    /// event carrying the catalog id (never user content, C9) and a card
    /// that says what did not happen. The bare spoken line it used to be
    /// left the question card on screen and the bus empty.
    func testLaunchTimeoutIsObservableAndNamed() {
        XCTAssertEqual(AppCoordinator.LaunchTimeout.eventType, "launch_timeout")
        XCTAssertEqual(AppCoordinator.LaunchTimeout.outcome(appID: "camera"),
                       "camera:timeout")
        XCTAssertFalse(AppCoordinator.LaunchTimeout.icon.isEmpty)
        for locale in [en, Locale(identifier: "ne-NP")] {
            let text = L10n.str(AppCoordinator.LaunchTimeout.speechKey, locale: locale)
            XCTAssertFalse(text.isEmpty, "\(locale) has no timeout line")
            XCTAssertNotEqual(text, AppCoordinator.LaunchTimeout.speechKey,
                              "\(locale) is missing the timeout translation")
        }
    }

    /// [F2] The chip's generic follow-up line ("Okay, marked as taken") is
    /// medication-flavored, so every flow that speaks its own outcome must
    /// be exempt — an app launch above all: a chip-yes on "क्यामेरा खोल्ने
    /// हो?" was announcing a recorded dose while the camera opened.
    func testConfirmationChipStaysSilentForEverySelfSpeakingFlow() {
        XCTAssertFalse(ConfirmationChipSpeech.speaksGenericYesNo(
            .init(isAppLaunch: true)))
        XCTAssertFalse(ConfirmationChipSpeech.speaksGenericYesNo(
            .init(isCall: true)))
        XCTAssertFalse(ConfirmationChipSpeech.speaksGenericYesNo(
            .init(isNavigationDisambiguation: true)))
        XCTAssertFalse(ConfirmationChipSpeech.speaksGenericYesNo(
            .init(isCalendarEvent: true)))
        XCTAssertFalse(ConfirmationChipSpeech.speaksGenericYesNo(
            .init(isCall: true, isAppLaunch: true)))
        XCTAssertTrue(ConfirmationChipSpeech.speaksGenericYesNo(.init()),
                      "the medication challenge is the flow that still needs the line")
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
