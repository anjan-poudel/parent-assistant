import XCTest
@testable import ElderlyAssistant

/// T-005 — every new user-visible string is a catalog entry with a Nepali
/// (Devanagari) value, the command phrases exist in both languages, the
/// camera purpose string discloses the live-translation use and the
/// conditional text-only send, and the degraded wording stays true whatever
/// the cause (NFR-LCT-004, FR-LCT-002, OD3 draft).
///
/// The copy itself is a **draft awaiting the owner's OD3 review**; these tests
/// assert properties (present, localised, cause-neutral, disclosed), not the
/// reviewer's final wording, so an approved reword does not need the gate to
/// be rewritten — except where a string is functional (the command phrase
/// table), which is pinned deliberately.
final class LiveTranslateCopyTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    /// The feature's copy surfaces. Every one must resolve in both languages.
    private let featureKeys = [
        "livetranslate.empty.hint",
        "livetranslate.state.pending",
        "livetranslate.state.unavailable",
        "livetranslate.state.quarantined",
        "livetranslate.consent.title",
        "livetranslate.consent.body",
        "livetranslate.consent.grant",
        "livetranslate.consent.decline",
        "livetranslate.consent.revoke",
        // T-015: the control's two extra states and the honest failure line.
        // The owner's OD3 copy review covers these with the rest of the
        // consent wording.
        "livetranslate.consent.failed",
        "livetranslate.consent.grantedTitle",
        "livetranslate.consent.grantedNote",
        "livetranslate.consent.revokeFailedTitle",
        "livetranslate.consent.revokeFailedNote",
        "livetranslate.cloudIndicator.label",
        "livetranslate.toggle.showOriginal",
        "livetranslate.camera.explanation",
        "livetranslate.camera.denied",
        "livetranslate.command.readAll",
        "livetranslate.command.stop",
        "livetranslate.command.showOriginal",
        "livetranslate.command.hideOriginal",
        "livetranslate.command.repeatLast",
        "livetranslate.command.close",
        // T-033: the freeze-frame control's three labels (one control, two
        // states, and the wait between the tap and the held picture — the
        // owner's device-testing follow-up: "could not tell if it was working,
        // slow, or broken"). **These three keys are the only feature copy added
        // after the OD3 draft review, and they are drafts awaiting it** — see
        // `specs/T-033-notes.md`'s open items. They are listed here because
        // the pinned inventory is what makes that debt visible: an entry
        // without a surface, or a surface without an entry, is a drift.
        "livetranslate.snapshot.capture",
        "livetranslate.snapshot.holding",
        "livetranslate.snapshot.live",
        // Owner directive, 2026-09-19: the cloud tier's master switch, drawn
        // on the Settings consent leaf. Two keys — the row's title and the
        // line under it that says what "off" means. Drafts awaiting the same
        // OD3 copy review as the consent wording around them.
        "livetranslate.settings.cloud.title",
        "livetranslate.settings.cloud.note",
        // 2026-09-19: the warden's two moments. The owner's directive is
        // explicit that the elder is not left wondering about the silences —
        // one sentence for a model that is loading ("hold on a sec"), one for
        // a model the voice stack has taken. Both are drafts awaiting the
        // same OD3 review as the rest of this list; the tests below assert
        // that a notice cannot exist without a sentence in both languages.
        "livetranslate.warden.loading",
        "livetranslate.warden.offloaded",
        // Workstream B (2026-09-22): the focused read, the master switch and
        // the spoken "translate here". Four surfaces in one change — the two
        // anchored actions ("Translate this" — the value cannot be the bare
        // word "Translate", because that word is a substring of the feature's
        // own identifier `LiveTranslate` and would fire
        // `testEveryFeatureStringIsCatalogBackedRatherThanASwiftLiteral` in
        // every file of the feature; "What is it?" is the point-ask chip's own
        // shipped key, deliberately not duplicated), the focused read's back
        // control and its "more below" value, the Settings leaf's row for the
        // feature's master switch, and the sentence the refusal speaks. Drafts
        // awaiting the same OD3 copy review as the rest.
        "livetranslate.command.translateHere",
        "livetranslate.disabled",
        "livetranslate.focus.back",
        "livetranslate.focus.scrolls",
        "livetranslate.focus.translate",
        "livetranslate.settings.enabled.note",
        "livetranslate.settings.enabled.title"
    ]

    private let commandPhrases: [(key: String, english: String, nepali: String)] = [
        ("livetranslate.command.readAll", "read this to me", "यो पढेर सुनाउनुहोस्"),
        ("livetranslate.command.stop", "stop reading", "पढ्न रोक्नुहोस्"),
        ("livetranslate.command.showOriginal", "show the original", "मूल अक्षर देखाउनुहोस्"),
        ("livetranslate.command.hideOriginal", "hide the original", "मूल अक्षर लुकाउनुहोस्"),
        ("livetranslate.command.repeatLast", "say that again", "फेरि भन्नुहोस्"),
        ("livetranslate.command.close", "close translation", "अनुवाद बन्द गर्नुहोस्"),
        // Workstream B: the focus mode's spoken half. The same *action* the
        // anchored box's Translate button performs, so an elder who cannot
        // reach the button can read the thing they are pointing at.
        ("livetranslate.command.translateHere", "translate here", "यहाँ अनुवाद गर्नुहोस्")
    ]

    /// Devanagari (U+0900–U+097F), by scalar.
    ///
    /// **Not by regular expression.** `range(of:options:.regularExpression)`
    /// declines any match whose range would split a grapheme cluster, so the
    /// `य` inside `यो` (य + ो, one cluster) cannot be reached: an entirely
    /// Devanagari value — T-033's `livetranslate.snapshot.capture`,
    /// `यो दृश्य रोक्नुहोस्` — was reported as having none, while values whose
    /// first bare Devanagari character happens to sit on a cluster boundary
    /// passed. The check therefore answered by the *shape* of the text rather
    /// than by its script. (Its old pattern also used the braced ICU escape
    /// `\u{0900}`, which `NSRegularExpression` rejects outright; both defects
    /// are recorded in `specs/T-033-notes.md`.)
    ///
    /// The app's own Devanagari tests are scalar tests
    /// (`ApplianceLabelLocalizer`, `FeedLanguageSorter`,
    /// `LiveTranslateCommandParserTests`), and so is this one.
    private func hasDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    // MARK: Scenario: every new user-visible string is a catalog entry with Nepali first

    func testEveryFeatureStringResolvesInNepaliAndEnglish() {
        for key in featureKeys {
            let ne = L10n.str(key, locale: nepali)
            let en = L10n.str(key, locale: english)

            XCTAssertNotEqual(ne, key, "\(key) does not resolve in Nepali")
            XCTAssertNotEqual(en, key, "\(key) does not resolve in English")
            XCTAssertTrue(hasDevanagari(ne), "\(key) has no Devanagari value: \(ne)")
            XCTAssertNotEqual(ne, en, "\(key) has the same value in both languages")
        }
    }

    func testEveryFeatureStringIsCatalogBackedRatherThanASwiftLiteral() {
        let values = featureKeys.flatMap { key in
            [L10n.str(key, locale: english), L10n.str(key, locale: nepali)]
        }
        let files = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        for file in files {
            let code = FeatureSourceScan.codeText(of: file)
            for value in values {
                XCTAssertFalse(code.contains(value),
                               "\(FeatureSourceScan.relativePath(of: file)) contains the user-visible string \(value.debugDescription) as a literal")
            }
        }
    }

    /// A pinned inventory, in the project's convention for a shared surface:
    /// a later task that adds feature copy (T-021's overlay labels,
    /// T-023's parser strings) extends this list in the same change, so an
    /// entry with no surface — or a surface with no entry — is a deliberate
    /// decision rather than a drift.
    func testTheCatalogHoldsExactlyTheFeaturesDeclaredKeys() {
        let catalog = sourceCatalog()
        let featureEntries = catalog.keys.filter { $0.hasPrefix("livetranslate.") }.sorted()
        XCTAssertEqual(featureEntries, featureKeys.sorted(),
                       "a catalog entry that no surface uses (or a surface with no entry) is a drift")
    }

    /// The close control reuses the shipped `common.close` entry rather than
    /// adding a second copy of the same words.
    func testTheCloseControlReusesTheShippedEntry() {
        XCTAssertFalse(sourceCatalog().keys.contains("livetranslate.close"))
        let ne = L10n.str("common.close", locale: nepali)
        XCTAssertNotEqual(ne, "common.close")
        XCTAssertTrue(hasDevanagari(ne))
    }

    // MARK: Scenario: the cloud switch says what "off" means, in both languages

    /// Owner directive, 2026-09-19. The generic resolver test above already
    /// covers "resolves in en + ne" for these keys; this pins the part of the
    /// copy a reword could quietly drop — that off means *the phone
    /// translates by itself and nothing is sent anywhere*, which is the state
    /// a household that never touches the switch stays in, and that the title
    /// names the service being asked for rather than "online" in the abstract.
    func testTheCloudSwitchCopySaysWhatOffMeansInBothLanguages() {
        let title = GeminiCloudToggleSurface.titleKey
        let note = GeminiCloudToggleSurface.noteKey

        XCTAssertEqual(title, "livetranslate.settings.cloud.title")
        XCTAssertEqual(note, "livetranslate.settings.cloud.note")

        let enNote = L10n.str(note, locale: english).lowercased()
        XCTAssertTrue(enNote.contains("off"),
                      "the note must name the state it explains: \(enNote)")
        XCTAssertTrue(enNote.contains("by itself") || enNote.contains("on its own")
                        || enNote.contains("on the phone"),
                      "the note must say the phone translates on its own: \(enNote)")
        XCTAssertTrue(enNote.contains("nothing is sent") || enNote.contains("nothing leaves"),
                      "the note must say nothing leaves the phone: \(enNote)")

        let neNote = L10n.str(note, locale: nepali)
        XCTAssertTrue(hasDevanagari(neNote))
        XCTAssertTrue(neNote.contains("बन्द"),
                      "the Nepali note must name the off state: \(neNote)")
        XCTAssertTrue(neNote.contains("फोन"),
                      "the Nepali note must name the phone: \(neNote)")
        XCTAssertTrue(neNote.contains("पठाइँदैन"),
                      "the Nepali note must say nothing is sent: \(neNote)")

        // The provider is named in the title in both languages: the household
        // is being asked to let one particular service do the work.
        XCTAssertTrue(L10n.str(title, locale: english).contains("Gemini"))
        XCTAssertTrue(L10n.str(title, locale: nepali).contains("Gemini"))
    }

    // MARK: Scenario: every warden notice has a sentence (2026-09-19)

    /// The indicator path is `LocalBrainWardenNotice`; this is the test that
    /// keeps it renderable. A case with no catalog entry — or an entry in the
    /// catalog that no notice points at — is a drift, in the same way the
    /// pinned inventory above is.
    func testEveryWardenNoticeResolvesToCopyInBothLanguages() {
        for notice in LocalBrainWardenNotice.allCases {
            XCTAssertTrue(featureKeys.contains(notice.copyKey),
                          "\(notice.rawValue) renders \(notice.copyKey), which "
                          + "the pinned inventory does not list")
            let ne = L10n.str(notice.copyKey, locale: nepali)
            let en = L10n.str(notice.copyKey, locale: english)
            XCTAssertNotEqual(en, notice.copyKey, "\(notice.copyKey) has no English value")
            XCTAssertTrue(hasDevanagari(ne), "\(notice.copyKey) has no Devanagari value: \(ne)")
            XCTAssertNotEqual(ne, en)
        }
        XCTAssertEqual(LocalBrainWardenNotice.allCases.count, 2,
                       "a load and a hand-off: the two moments the elder is "
                       + "owed a sentence for")
    }

    /// The owner's own words for the hand-off, kept where a reword has to be
    /// deliberate: this sentence is what replaces a session that silently
    /// stops translating.
    func testTheOffloadCopySaysTheVoiceRequestTookTheModel() {
        let en = L10n.str(LocalBrainWardenNotice.offloadedForVoiceTurn.copyKey,
                          locale: english).lowercased()
        XCTAssertTrue(en.contains("voice"),
                      "the sentence must name what took the model: \(en)")
        XCTAssertTrue(en.contains("switch"),
                      "and say that the model was swapped, not lost: \(en)")

        let loading = L10n.str(LocalBrainWardenNotice.loadingModel.copyKey,
                              locale: english).lowercased()
        XCTAssertTrue(loading.contains("hold on"),
                      "the owner asked for 'hold on a sec' verbatim: \(loading)")
        XCTAssertTrue(L10n.str(LocalBrainWardenNotice.loadingModel.copyKey, locale: nepali)
                        .contains("पर्खनुहोस्"),
                      "the Nepali sentence must ask for the same wait")
    }

    // MARK: Scenario: the notice reaches the screen as a sentence (2026-09-19)

    /// The notice's last step before it is read: `WardenNoticeSurface` is what
    /// `LiveTranslateSessionModel` publishes and
    /// `LiveTranslateWardenNoticeBanner` draws, so this is where "the banner
    /// renders the catalog's sentence, in the active language" is asserted —
    /// for both languages, and per notice, because the two moments must never
    /// collapse into one wording.
    ///
    /// The assertions are the ones a key-instead-of-a-sentence bug or a
    /// frozen-language bug would fail: not the key, not the case name,
    /// Devanagari where the elder reads Nepali, and two languages that are not
    /// the same string.
    func testEveryWardenNoticeSurfaceRendersASentenceInBothLanguages() {
        for notice in LocalBrainWardenNotice.allCases {
            let en = WardenNoticeSurface(notice: notice, locale: english)
            let ne = WardenNoticeSurface(notice: notice, locale: nepali)

            XCTAssertFalse(en.copy.isEmpty)
            XCTAssertFalse(ne.copy.isEmpty)
            XCTAssertNotEqual(en.copy, notice.copyKey,
                              "\(notice.rawValue) drew its catalog key instead of a sentence")
            XCTAssertNotEqual(en.copy, notice.rawValue,
                              "\(notice.rawValue) drew its case name instead of a sentence")
            XCTAssertNotEqual(en.copy, ne.copy,
                              "\(notice.rawValue) renders the same words in both languages")
            XCTAssertTrue(hasDevanagari(ne.copy),
                          "\(notice.rawValue) draws no Devanagari in a Nepali session: \(ne.copy)")
        }

        // The two moments say different things, in both languages: one wait,
        // one hand-off.
        XCTAssertNotEqual(WardenNoticeSurface(notice: .loadingModel, locale: english).copy,
                          WardenNoticeSurface(notice: .offloadedForVoiceTurn, locale: english).copy)
        XCTAssertNotEqual(WardenNoticeSurface(notice: .loadingModel, locale: nepali).copy,
                          WardenNoticeSurface(notice: .offloadedForVoiceTurn, locale: nepali).copy)
    }

    // MARK: Scenario: the command phrases exist in both languages

    func testTheCommandPhraseTableExistsInBothLanguages() {
        for phrase in commandPhrases {
            XCTAssertEqual(L10n.str(phrase.key, locale: english), phrase.english,
                           "\(phrase.key) is the C12 phrase table's matcher input; a reword must be deliberate")
            XCTAssertEqual(L10n.str(phrase.key, locale: nepali), phrase.nepali,
                           "\(phrase.key) is the C12 phrase table's matcher input; a reword must be deliberate")
            XCTAssertTrue(hasDevanagari(phrase.nepali))
        }
        XCTAssertEqual(commandPhrases.count, 7,
                       "read-all, stop, set-show-original on and off, repeat-last, close, translate-here")
    }

    // MARK: Scenario: the camera purpose string discloses live translation and the conditional text send

    func testThePurposeStringDisclosesLiveTranslationAndTheConditionalTextOnlySend() {
        let purpose = cameraPurposeString().lowercased()

        XCTAssertTrue(purpose.contains("live translation"),
                      "the purpose string must state that live translation uses the camera")
        XCTAssertTrue(purpose.contains("camera"),
                      "the purpose string must name the camera")
        XCTAssertTrue(purpose.contains("text") && purpose.contains("cloud"),
                      "the purpose string must name the conditional cloud send")
        XCTAssertTrue(purpose.contains("never") || purpose.contains("only"),
                      "the purpose string must state the text-only limit")
        XCTAssertTrue(purpose.contains("photo") || purpose.contains("image"),
                      "the purpose string must say that images are not sent")
    }

    func testTheShippedMedicationAndApplianceDisclosuresAreStillPresent() {
        let purpose = cameraPurposeString().lowercased()
        XCTAssertTrue(purpose.contains("medication"),
                      "the shipped medication-verification disclosure must not be weakened")
        XCTAssertTrue(purpose.contains("appliance"))
        XCTAssertTrue(purpose.contains("photos") && purpose.contains("sent"),
                      "the shipped appliance-photo disclosure must still say photos are sent")
        XCTAssertTrue(purpose.contains("cloud service"))
    }

    // MARK: Scenario: the unavailable wording stays true in every failure case

    /// The elder can see this string for a spent budget, a withheld consent,
    /// an unreadable record, a missing key or a network failure. Naming any
    /// one of those causes would be a lie in the other four cases.
    func testTheUnavailableCopyNamesNoSpecificCause() {
        let causeWords = ["internet", "network", "connection", "online", "consent",
                          "permission", "budget", "limit", "offline", "cloud",
                          "इन्टरनेट", "नेटवर्क", "अनुमति", "बजेट", "सहमति"]
        for key in ["livetranslate.state.unavailable", "livetranslate.state.quarantined"] {
            for locale in [english, nepali] {
                let copy = L10n.str(key, locale: locale).lowercased()
                for word in causeWords {
                    XCTAssertFalse(copy.contains(word.lowercased()),
                                   "\(key) names a specific cause ('\(word)') — it must stay true for all of them")
                }
            }
        }
    }

    func testTheDegradedCopyStillPromisesTheOriginalText() {
        let ne = L10n.str("livetranslate.state.unavailable", locale: nepali)
        XCTAssertTrue(ne.contains("मूल"),
                      "the degraded state must say the original text is shown, not leave a blank bubble")
    }

    // MARK: Scenario: the draft copy is version-stamped for the consent record

    func testTheDisclosureVersionIdentifiesThisCopyRevision() {
        let version = LiveTranslateConfig.default.disclosureVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: "r[0-9]+", options: .regularExpression),
                        "the stamp carries a revision ordinal, so an approved copy change bumps it: \(version)")
        XCTAssertTrue(version.hasPrefix("livetranslate.disclosure"),
                      "the stamp names the copy it belongs to: \(version)")

        // It must survive the log surface, or the consent evidence loses the
        // stamp that makes a stale grant detectable.
        let clean = LogSanitiser().sanitise(ObservabilityEvent(
            component: "livetranslate", eventType: "consent_recorded", durationMs: nil,
            outcome: "success", errorCode: nil, metadata: ["disclosureVersion": version]))
        XCTAssertEqual(clean.metadata["disclosureVersion"], version,
                       "the stamp must not be scrubbed by the shipped PII guard")
    }

    // MARK: Helpers

    /// The source String Catalog, parsed as the artifact that ships —
    /// asserting on the file this task edits rather than on a built copy.
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

    private func cameraPurposeString() -> String {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let purpose = plist["NSCameraUsageDescription"] as? String else {
            XCTFail("could not read NSCameraUsageDescription from \(url.path)")
            return ""
        }
        return purpose
    }
}
