import XCTest
@testable import ElderlyAssistant

/// T-117 — the Spotify localisation inventory (design-l2 §31): 20 keys in
/// `Localizable.xcstrings`, `ne` and `en` both mandatory, spoken lines
/// resolving through `L10n.str` / `L10n.fmt`, and the baseline around the
/// insertion points unchanged.
///
/// **M-2 provenance.** `security-design-review` (M-2, must-fix) requires
/// `spotifySettings.privacy` to name the requests *including play commands*
/// and the playback control, not search alone — FR-SP-016's acceptance
/// criterion names both, and the §31 table's pre-amendment sentence
/// ("…to find the music; nothing else is sent.") covers search only. The
/// amended copy shipped here is what T-123's disclosure evidence
/// (obligation 7) is checked against and what T-120 consumes.
///
/// **F-7 recorded deviation.** `spotifySettings.removeConfirm` keeps the
/// design's "Music will use YouTube only." wording although the unlinked
/// path can still open the `spotify:search:` hand-off when YouTube cannot
/// serve (matrix row 8). The stronger sentence is the design-l2 §31 choice
/// (honest-line rules and DV-4 unaffected); T-120 carries the same note.
/// The copy is pinned below so any change to it is a deliberate one.
final class SpotifyLocalizationTests: XCTestCase {

    // MARK: The pinned inventory (design-l2 §31)

    /// The eight spoken outcome lines.
    private let spokenKeys = [
        "spotify.playing",
        "spotify.openApp",
        "spotify.openSearch",
        "spotify.notFound",
        "spotify.unavailable",
        "spotify.notLinked",
        "spotify.appMissing",
        "spotify.rolloutLimited"
    ]

    /// The ten settings-surface keys.
    private let settingsKeys = [
        "spotifySettings.title",
        "spotifySettings.status.linked",
        "spotifySettings.status.freeTier",
        "spotifySettings.status.notLinked",
        "spotifySettings.status.linkFailed",
        "spotifySettings.link",
        "spotifySettings.unlink",
        "spotifySettings.removeConfirm",
        "spotifySettings.privacy",
        "spotifySettings.rolloutNote"
    ]

    /// Combined with the two namespace singletons, the 20 keys of §31.
    private var inventory: [String] {
        spokenKeys + settingsKeys + ["plugin.spotify.name", "toolLog.kind.spotify"]
    }

    /// The branch-point baseline (review-l2, verification method: 1,341 keys,
    /// no `spotify*` keys yet), refreshed at T-141 (W6) per the W1 review's
    /// F-4: three unrelated master entries landed between the branch point
    /// and this feature's base (catalog 1,364 at `0cbe4e6`, already 3 past
    /// the stale 1,361 expectation), and the multi-turn-conversation
    /// feature added its 17 `dialogue.*` keys (T-129; catalog 1,381 at
    /// feature HEAD). 1,341 + 3 + 17 = 1,361: the catalog total must stay
    /// exactly this plus the 20 added keys — the feature's edit list adds
    /// keys and modifies none.
    private let baselineKeyCount = 1361

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    // MARK: Scenario: Every new key exists in both languages

    func testEveryNewKeyResolvesInBothLanguages() {
        for key in inventory {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)

            XCTAssertNotEqual(en, key, "\(key) does not resolve in English")
            XCTAssertNotEqual(ne, key, "\(key) falls back to the raw identifier in Nepali")
            XCTAssertTrue(hasDevanagari(ne), "\(key) has no Devanagari value: \(ne)")
            XCTAssertNotEqual(ne, en, "\(key) falls back to the English value in the Nepali locale")
        }
    }

    func testEveryNewKeyCarriesBothTranslationsInTheSourceCatalog() {
        let catalog = sourceCatalog()
        for key in inventory {
            guard let entry = catalog[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let en = localizations["en"] as? [String: Any],
                  let ne = localizations["ne"] as? [String: Any],
                  let enUnit = en["stringUnit"] as? [String: Any],
                  let neUnit = ne["stringUnit"] as? [String: Any],
                  let enValue = enUnit["value"] as? String,
                  let neValue = neUnit["value"] as? String else {
                XCTFail("\(key) is missing an en or ne stringUnit in the source catalog")
                continue
            }

            XCTAssertEqual(entry["extractionState"] as? String, "manual",
                           "\(key) must use the catalog's manual extraction convention")
            XCTAssertEqual(enUnit["state"] as? String, "translated",
                           "\(key) en is not marked translated")
            XCTAssertEqual(neUnit["state"] as? String, "translated",
                           "\(key) ne is not marked translated")
            XCTAssertFalse(enValue.isEmpty, "\(key) has an empty English value")
            XCTAssertFalse(neValue.isEmpty, "\(key) has an empty Nepali value")
            XCTAssertFalse(hasASCIILetters(neValue),
                           "\(key) contains English prose in its Nepali value: \(neValue)")
        }
    }

    func testThePlayingLineCarriesTheRuntimeTitleInBothLanguages() {
        let key = "spotify.playing"

        XCTAssertTrue(L10n.str(key, locale: english).contains("%@"),
                      "the playing line must embed the remote-sourced title")
        XCTAssertTrue(L10n.str(key, locale: nepali).contains("%@"),
                      "the playing line's Nepali value must embed the title")

        let en = L10n.fmt(key, locale: english, "Test Song")
        let ne = L10n.fmt(key, locale: nepali, "भजन")

        XCTAssertTrue(en.contains("Test Song") && en.contains("Spotify"),
                      "the formatted English line must name the track and the provider: \(en)")
        XCTAssertTrue(ne.contains("भजन") && ne.contains("स्पोटिफाइ"),
                      "the formatted Nepali line must name the track and the provider: \(ne)")
        XCTAssertFalse(en.contains("%@"), "the placeholder must be substituted: \(en)")
        XCTAssertFalse(ne.contains("%@"), "the placeholder must be substituted: \(ne)")
    }

    func testTheSpotifyNamespaceHoldsExactlyThePinnedInventory() {
        let catalog = sourceCatalog()
        let namespaced = catalog.keys.filter {
            $0.hasPrefix("spotify.")
                || $0.hasPrefix("spotifySettings.")
                || $0 == "plugin.spotify.name"
                || $0 == "toolLog.kind.spotify"
        }
        XCTAssertEqual(namespaced.sorted(), inventory.sorted(),
                       "a Spotify catalog entry with no pinned consumer (or a pinned key "
                       + "with no entry) is a drift")
    }

    // MARK: Scenario: The privacy disclosure names the playback activity (M-2)

    func testThePrivacyDisclosureNamesPlaybackActivityInBothLanguages() {
        let key = "spotifySettings.privacy"
        let en = L10n.str(key, locale: english)
        let lowercased = en.lowercased()
        let ne = L10n.str(key, locale: nepali)

        // The request side, including the play commands the remote-control
        // path sends.
        XCTAssertTrue(lowercased.contains("play commands"),
                      "the disclosure must name the play commands it sends: \(en)")
        // The playback side, not search alone (M-2's core requirement).
        XCTAssertTrue(lowercased.contains("control playback"),
                      "the disclosure must name the playback activity it controls: \(en)")
        XCTAssertTrue(lowercased.contains("to find music"),
                      "the disclosure must still name the search the request performs: \(en)")
        XCTAssertTrue(lowercased.contains("spotify"),
                      "the disclosure must name the destination: \(en)")
        XCTAssertTrue(lowercased.contains("no other app data is sent"),
                      "the disclosure must bound what is sent: \(en)")

        XCTAssertTrue(ne.contains("स्पोटिफाइ"),
                      "the Nepali disclosure must name Spotify: \(ne)")
        XCTAssertTrue(ne.contains("बजाउने आदेश"),
                      "the Nepali disclosure must name the play commands: \(ne)")
        XCTAssertTrue(ne.contains("बजाउन"),
                      "the Nepali disclosure must name playback: \(ne)")
        XCTAssertTrue(ne.contains("खोज्न"),
                      "the Nepali disclosure must name the search: \(ne)")
        XCTAssertTrue(ne.contains("पठाइन्छ"),
                      "the Nepali disclosure must say data is sent: \(ne)")
    }

    func testThePrivacyDisclosureDoesNotClaimANarrowerDataFlow() {
        let key = "spotifySettings.privacy"
        let en = L10n.str(key, locale: english)
        let ne = L10n.str(key, locale: nepali)

        // The pre-amendment copy covered search only and its second clause can
        // be read as excluding the play commands (security-design-review M-2).
        XCTAssertFalse(en.contains("nothing else is sent"),
                       "the pre-amendment English clause must not survive the (M-2) amendment: \(en)")
        XCTAssertFalse(ne.contains("अरू केही पठाइँदैन"),
                       "the pre-amendment Nepali clause must not survive the (M-2) amendment: \(ne)")

        // Both languages must state the same flow.
        XCTAssertTrue(en.lowercased().contains("play commands")
                        && ne.contains("बजाउने आदेश"),
                      "en names the play commands, ne must too (parity of disclosure)")
        XCTAssertTrue(en.lowercased().contains("control playback") && ne.contains("बजाउन"),
                      "en names the playback control, ne must too")
    }

    // MARK: Scenario: The catalog stays valid against the existing inventory

    func testTheCatalogParsesAndKeepsTheBaselineInstrumentation() {
        let catalog = sourceCatalog()

        XCTAssertEqual(catalog.count, baselineKeyCount + inventory.count,
                       "the feature adds exactly \(inventory.count) keys and removes none "
                       + "(baseline \(baselineKeyCount))")

        // The immediate alphabetical neighbours of each insertion point: if a
        // textual insertion had clobbered an entry, one of these would move.
        assertCatalogValue("plugin.routine.unavailable",
                           en: "Sorry, I couldn't set the reminder right now.",
                           ne: "माफ गर्नुहोस्, अहिले सम्झना राख्न सकिएन।")
        assertCatalogValue("plugin.youtube.name", en: "YouTube", ne: "युट्युब")
        assertCatalogValue("settings.voices.useHint",
                           en: "Asks you to confirm before switching to this voice.",
                           ne: "यो आवाजमा बदल्नुअघि पुष्टि माग्छ।")
        assertCatalogValue("startup.degraded",
                           en: "Some features are running with reduced functionality",
                           ne: "केही सुविधा कम क्षमतामा चलिरहेका छन्")
        assertCatalogValue("toolLog.kind.search", en: "Web search", ne: "वेब खोज")
        assertCatalogValue("toolLog.kind.weather", en: "Weather", ne: "मौसम")
    }

    /// ADR-SP-11 / design-l2 §29 edit list: the stub branch is deleted, but the
    /// `router.musicStub` key is **retained in the catalog** with no reachable
    /// call site. It is not deleted by this feature.
    func testTheOrphanedMusicStubKeyIsRetainedPerTheEditList() {
        assertCatalogValue("router.musicStub",
                           en: "Music isn't ready yet. Coming soon.",
                           ne: "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।")
    }

    /// F-7: the design-l2 §29 copy is kept verbatim; the recorded deviation is
    /// that the unlinked path can still open the `spotify:search:` hand-off
    /// when YouTube cannot serve (matrix row 8). This pin makes any future
    /// wording change a deliberate decision, not a drift.
    func testTheRemoveConfirmationCopyIsRetainedAsDesigned() {
        assertCatalogValue("spotifySettings.removeConfirm",
                           en: "Remove the Spotify connection? Music will use YouTube only.",
                           ne: "स्पोटिफाइ जडान हटाउने हो? संगीत युट्युबबाट मात्र बज्नेछ।")
    }

    // MARK: Helpers

    /// The source String Catalog, parsed as the artifact that ships —
    /// asserting on the file the feature edits rather than on a built copy.
    private func sourceCatalog() -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return [:]
        }
        return strings
    }

    private func assertCatalogValue(_ key: String,
                                    en expectedEN: String,
                                    ne expectedNE: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let catalog = sourceCatalog()
        guard let entry = catalog[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let en = localizations["en"] as? [String: Any],
              let ne = localizations["ne"] as? [String: Any],
              let enValue = (en["stringUnit"] as? [String: Any])?["value"] as? String,
              let neValue = (ne["stringUnit"] as? [String: Any])?["value"] as? String else {
            XCTFail("\(key) is missing from the source catalog", file: file, line: line)
            return
        }
        XCTAssertEqual(enValue, expectedEN,
                       "\(key) English value changed", file: file, line: line)
        XCTAssertEqual(neValue, expectedNE,
                       "\(key) Nepali value changed", file: file, line: line)
    }

    /// Devanagari (U+0900–U+097F), by scalar — not by regular expression
    /// (the shipped live-translate copy tests record the grapheme-cluster
    /// defect `range(of:options:.regularExpression)` has here).
    private func hasDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// ASCII letters, the "English prose" signal design-l2 §31 forbids in a
    /// `ne` value (the provider loanwords are Devanagari: स्पोटिफाइ, युट्युब).
    private func hasASCIILetters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }
}
