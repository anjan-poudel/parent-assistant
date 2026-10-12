import XCTest
@testable import ElderlyAssistant

/// Catalog coverage for the profile-interview's new user-visible keys
/// (profile-interview, T-093 / C09, NFR-PI-006).
///
/// Every interview/Settings string is keyed; this suite is what makes
/// "the key resolves" a claim with evidence: each key must resolve in
/// BOTH shipped languages (en + ne) to something that is not the key
/// itself, and the two resolutions must differ — a key whose ne copy was
/// forgotten by copy-pasting the en value fails here rather than shipping
/// a screen that reads English to a Nepali household.
///
/// Resolution goes through `L10n.str`, the same path non-View code uses,
/// so this pins the shipped lproj bundles, not the source JSON.
///
/// T-129 extends the same suite with the multi-turn-conversation dialogue
/// family (design-l2 §16; C-4: exactly 17 keys, `dialogue.timeout`
/// deliberately absent). The dialogue half is deliberately split: the
/// **source** half runs a pure coverage function over the parsed catalog
/// (so the "one value removed fails naming the key" scenario can run
/// against a fixture), the **resolution** half goes through `L10n.str` in
/// both shipped languages.
///
/// T-155 extends the suite again with the call-dialer calling family
/// (design-l2 §12; C7): exactly five keys — the two settings section
/// titles, the confirmation disclosure and the two announcements — with
/// the same split (a pure coverage function over the parsed catalog,
/// fixtures for the fails-naming-the-key scenario, and resolution through
/// `L10n.str`).
final class L10nCatalogCoverageTests: XCTestCase {

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    /// The feature's new keys (plus `profile.field.addressAs`, which the
    /// shared `AddressAsField` has rendered since T-098 — the coverage
    /// check is how its absence would have been caught).
    private static let interviewKeys: [String] = [
        // C05 — the wake acknowledgment template (design-given copy).
        "wakeAck.personalized",
        // C06 — About-you step: title/body + field labels.
        "onboarding.aboutYou.title",
        "onboarding.aboutYou.body",
        "onboarding.aboutYou.name",
        "onboarding.aboutYou.addressAs",
        "onboarding.aboutYou.dateOfBirthToggle",
        // About-you selfie (2026-10-06): the capture button + the soft
        // no-camera note.
        "onboarding.aboutYou.takePhoto",
        "onboarding.aboutYou.photoUnavailable",
        // C11 — emergency contacts step: title/body + kin/GP/hospital.
        "onboarding.emergency.title",
        "onboarding.emergency.body",
        "onboarding.emergency.kinTitle",
        "onboarding.emergency.doctor",
        "onboarding.emergency.hospital",
        // C12 — voice fingerprint step + its controls.
        "onboarding.stepVoiceFingerprint.title",
        "onboarding.stepVoiceFingerprint.body",
        "onboarding.voiceFingerprint.progress",
        "onboarding.voiceFingerprint.record",
        "onboarding.voiceFingerprint.stop",
        "onboarding.voiceFingerprint.done",
        // C08 — the Settings editor.
        "settings.profile.title",
        "settings.profile.explanation",
        "profile.field.name",
        "profile.field.addressAs",
        "profile.field.dateOfBirth",
        "profile.field.doctor",
        "profile.field.hospital",
        // The stored selfie's read-only thumbnail label (2026-10-06).
        "profile.field.photo",
        "profile.kin.note",
        "profile.save",
        "profile.saved",
        "profile.error.saveFailed",
    ]

    func testEveryInterviewKeyResolvesInBothLanguages() {
        for key in Self.interviewKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key,
                              "\(key) does not resolve in en — the catalog "
                              + "entry is missing")
            XCTAssertNotEqual(ne, key,
                              "\(key) does not resolve in ne — the catalog "
                              + "entry is missing")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty en copy")
            XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty ne copy")
        }
    }

    func testNoInterviewKeyShipsTheEnglishCopyUntranslated() {
        for key in Self.interviewKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, ne,
                              "\(key) resolves to the SAME string in en and ne "
                              + "— the Nepali copy is missing (or the key was "
                              + "forgotten in one language)")
        }
    }

    /// The number of `%d`/`%@` placeholders must match between the two
    /// languages: a translator who drops or duplicates a placeholder
    /// would make `L10n.fmt` crash or mis-place an argument. Only the
    /// format-string keys carry them; this pins those two.
    func testTheFormattedKeysKeepTheirPlaceholderCounts() {
        for key in ["wakeAck.personalized", "onboarding.voiceFingerprint.progress"] {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertEqual(Self.placeholderCount(in: en),
                           Self.placeholderCount(in: ne),
                           "\(key): the en and ne copies disagree on how many "
                           + "arguments the format string takes")
        }
    }

    private static func placeholderCount(in value: String) -> Int {
        var count = 0
        var index = value.startIndex
        while let found = value[index...].range(of: "%") {
            count += 1
            index = value.index(after: found.lowerBound)
            if index >= value.endIndex { break }
        }
        return count
    }

    // MARK: T-129 — the multi-turn-conversation dialogue family (design-l2 §16)

    /// The pinned inventory: design-l2 §16 minus the `dialogue.timeout` row,
    /// which the design lists only to declare it missing — the silent
    /// expiry path speaks nothing by construction (C-4, review-l2: the
    /// counts are 17 keys, not the 16 the §16 prose still says). Two keys
    /// post-date §16: `dialogue.option.conjunction` (the "or" joiner the
    /// narrowed choice probes speak with, owner feedback 2026-10-11) and
    /// `dialogue.correction.ask` (correction-revive, PR #162), making the
    /// family 19.
    private static let dialogueKeys: [String] = [
        "dialogue.cancelled",
        "dialogue.candidate.appLaunch",
        "dialogue.candidate.music",
        "dialogue.candidate.news",
        "dialogue.candidate.youtube",
        "dialogue.correction.ask",
        "dialogue.didYouMean",
        "dialogue.escape",
        "dialogue.exhausted",
        "dialogue.option.anyPlay",
        "dialogue.option.bhajan.bishnu",
        "dialogue.option.bhajan.devi",
        "dialogue.option.bhajan.durga",
        "dialogue.option.bhajan.shiva",
        "dialogue.option.conjunction",
        "dialogue.probe.bhajanKind",
        "dialogue.probe.musicAny",
        "dialogue.retry",
        "dialogue.understood.no",
    ]

    /// The catalog at this feature's branch point: 1,364 keys, zero
    /// `dialogue.*` entries — rebased at integration: to 1,366 when
    /// af69135 (RAM-tier owner override) added its two settings keys,
    /// to 1,369 when the call-deterministic-fallback (PR #161) and
    /// correction-revive merges added five further non-dialogue keys,
    /// to 1,370 when the call-nearmiss merge (PR #166) added
    /// `router.call.didYouMeanPrefix`, and to 1,375 when the call-dialer
    /// primary/secondary family (T-155) added its five calling keys (the
    /// calling half's own pin reads 1,389 as its branch point). The
    /// dialogue family is 19 keys (the 18 design-l2 §16 entries plus
    /// `dialogue.correction.ask`, moved into the family block at this
    /// rebase); the family adds exactly its keys and removes none, so the
    /// total is pinned (the Spotify-localisation suite's count discipline).
    private static let dialogueBaselineKeyCount = 1_375

    /// The design-l2 §16 draft copy, verbatim, both languages. The owner
    /// copy review is a later step recorded in the plan; this pin makes
    /// every wording change — including an "improvement" — a deliberate
    /// one rather than a drift.
    private static let dialogueCopy: [(key: String, en: String, ne: String)] = [
        ("dialogue.cancelled", "OK.", "ठीक छ।"),
        ("dialogue.candidate.appLaunch", "Open %@?", "%@ खोल्ने हो?"),
        ("dialogue.candidate.music", "Play %@?", "%@ बजाउने हो?"),
        ("dialogue.candidate.news", "The news?", "समाचार सुनाउने हो?"),
        ("dialogue.candidate.youtube", "Watch %@ on YouTube?", "युट्युबमा %@ हेर्ने हो?"),
        ("dialogue.correction.ask", "I heard «%@». Did you mean %@?",
         "मैले «%@» सुनें। के तपाईंले %@ भन्न खोज्नुभएको थियो?"),
        ("dialogue.didYouMean", "Did you mean %@?", "के तपाईंको मतलब %@ हो?"),
        ("dialogue.escape", "OK, tell me again.", "ठीक छ, फेरि भन्नुहोस्।"),
        ("dialogue.exhausted", "I didn't understand. Try again later.",
         "मैले बुझिन। पछि फेरि भन्नुहोस्।"),
        ("dialogue.option.anyPlay", "just play anything", "जे पनि बजाऊ"),
        ("dialogue.option.bhajan.bishnu", "bishnu", "विष्णु"),
        ("dialogue.option.bhajan.devi", "devi", "देवी"),
        ("dialogue.option.bhajan.durga", "durga", "दुर्गा"),
        ("dialogue.option.bhajan.shiva", "shiva", "शिव"),
        ("dialogue.option.conjunction", " or ", " वा "),
        ("dialogue.probe.bhajanKind", "What kind of bhajan? %@ … or say it yourself",
         "कस्तो भजन? %@ … वा आफैँ भन्नुहोस्"),
        ("dialogue.probe.musicAny", "What kind of music? Say the name.",
         "कस्तो संगीत चाहियो? नाम भन्नुहोस्।"),
        ("dialogue.retry", "Let me ask again —", "फेरि सोध्छु —"),
        ("dialogue.understood.no", "I didn't understand.", "मैले बुझिन।"),
    ]

    /// Scenario: All dialogue keys exist in both languages — the
    /// behavioural half. Every spoken line resolves through the shipped
    /// lproj bundles in both languages, and the Nepali resolution is
    /// Devanagari copy (NFR-MTC-009: every line is spoken text).
    func testEveryDialogueKeyResolvesInBothLanguages() {
        for key in Self.dialogueKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key,
                              "\(key) does not resolve in en — the catalog "
                              + "entry is missing")
            XCTAssertNotEqual(ne, key,
                              "\(key) does not resolve in ne — the catalog "
                              + "entry is missing")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty en copy")
            XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty ne copy")
            XCTAssertNotEqual(en, ne,
                              "\(key) resolves to the SAME string in en and ne "
                              + "— the Nepali copy is missing (or the key was "
                              + "forgotten in one language)")
            XCTAssertTrue(Self.containsDevanagari(ne),
                          "\(key) resolves to non-Devanagari Nepali copy: \(ne)")
        }
    }

    /// Scenario: All dialogue keys exist in both languages — the source
    /// half. The family is exactly the 17 pinned keys; each is `manual`,
    /// both string units are `translated`, and the Nepali value carries no
    /// ASCII letters (the catalog convention the Spotify inventory set:
    /// provider loanwords are Devanagari, e.g. युट्युब). The catalog total
    /// is pinned to the branch-point count plus the 17.
    func testTheDialogueFamilyPassesTheCoverageCheck() {
        let catalog = sourceCatalog()

        XCTAssertEqual(catalog.count,
                       Self.dialogueBaselineKeyCount + Self.dialogueKeys.count,
                       "the feature adds exactly \(Self.dialogueKeys.count) keys "
                       + "and removes none (baseline \(Self.dialogueBaselineKeyCount))")

        let failures = Self.dialogueCoverageFailures(in: catalog)
        XCTAssertTrue(failures.isEmpty,
                      "the dialogue coverage check failed:\n"
                      + failures.joined(separator: "\n"))

        // The immediate alphabetical neighbours of the insertion point: if a
        // textual insertion had clobbered an entry, one of these would move.
        assertCatalogValue("common.emergency", en: "Emergency", ne: "आपतकालीन")
        assertCatalogValue("directions.cancelled",
                           en: "Okay, I'll cancel that.",
                           ne: "ठिक छ, त्यो रद्द गर्दैछु।")
    }

    /// Scenario: The silent timeout is not a string. `dialogue.timeout` is
    /// deliberately absent (C-4): the expiry path speaks nothing by
    /// construction, and the coverage check rejects a catalog that grows
    /// such an entry.
    func testTheDialogueFamilyHasNoTimeoutEntry() {
        let catalog = sourceCatalog()
        let family = catalog.keys.filter { $0.hasPrefix("dialogue.") }

        XCTAssertFalse(family.contains("dialogue.timeout"),
                       "dialogue.timeout must stay absent — the timeout path "
                       + "is silent by construction")
        XCTAssertFalse(family.contains { $0.lowercased().contains("timeout") },
                       "no dialogue key may encode the silent expiry: "
                       + "\(family.filter { $0.lowercased().contains("timeout") })")
        XCTAssertFalse(Self.dialogueKeys.contains("dialogue.timeout"),
                       "the pinned inventory must not carry a timeout key")

        // The check itself rejects a fixture that grows one, so the rule is
        // enforced by the gate and not only by this assertion.
        var fixture = catalog
        fixture["dialogue.timeout"] = Self.sampleEntry(en: "Timeout",
                                                       ne: "समय सकियो")
        XCTAssertTrue(Self.dialogueCoverageFailures(in: fixture)
                        .contains { $0.contains("dialogue.timeout") },
                      "the coverage check must fail when a timeout entry "
                      + "appears in the family")
    }

    /// Scenario: A missing translation fails the gate. Each fixture is a
    /// copy of the parsed catalog mutated in one way; the coverage check
    /// must fail naming the offending key — a missing value, a missing
    /// entry, a blank value, a stray key and an untranslated state.
    func testTheCoverageCheckFailsNamingTheMissingDialogueValue() {
        // Fixture 1: one dialogue value removed (the scenario's exact case).
        let key = "dialogue.retry"
        var missingNE = sourceCatalog()
        if var entry = missingNE[key] as? [String: Any] {
            var localizations = entry["localizations"] as? [String: Any] ?? [:]
            localizations.removeValue(forKey: "ne")
            entry["localizations"] = localizations
            missingNE[key] = entry
        }
        assertCoverageFails(missingNE, naming: key)

        // Fixture 2: the whole entry removed.
        var missingEntry = sourceCatalog()
        missingEntry.removeValue(forKey: "dialogue.exhausted")
        assertCoverageFails(missingEntry, naming: "dialogue.exhausted")

        // Fixture 3: a blank Nepali value.
        var blankNE = sourceCatalog()
        if var entry = blankNE["dialogue.escape"] as? [String: Any],
           var localizations = entry["localizations"] as? [String: Any],
           var ne = localizations["ne"] as? [String: Any],
           var unit = ne["stringUnit"] as? [String: Any] {
            unit["value"] = "   "
            ne["stringUnit"] = unit
            localizations["ne"] = ne
            entry["localizations"] = localizations
            blankNE["dialogue.escape"] = entry
        }
        assertCoverageFails(blankNE, naming: "dialogue.escape")

        // Fixture 4: an English value copied into the Nepali slot.
        var untranslatedNE = sourceCatalog()
        if var entry = untranslatedNE["dialogue.cancelled"] as? [String: Any],
           var localizations = entry["localizations"] as? [String: Any],
           var ne = localizations["ne"] as? [String: Any],
           var unit = ne["stringUnit"] as? [String: Any] {
            unit["value"] = "OK."
            ne["stringUnit"] = unit
            localizations["ne"] = ne
            entry["localizations"] = localizations
            untranslatedNE["dialogue.cancelled"] = entry
        }
        assertCoverageFails(untranslatedNE, naming: "dialogue.cancelled")

        // Fixture 5: a stray dialogue key outside the pinned inventory —
        // the "exactly 17" rule.
        var stray = sourceCatalog()
        stray["dialogue.stray"] = Self.sampleEntry(en: "Stray", ne: "थप")
        assertCoverageFails(stray, naming: "dialogue.stray")
    }

    /// DoD evidence: every value is the design-l2 §16 draft, verbatim, in
    /// both languages — a translation dropped or an English copy pasted
    /// into the `ne` slot fails here.
    func testTheDialogueCopyMatchesTheDesignDraftVerbatim() {
        XCTAssertEqual(Self.dialogueCopy.map { $0.key }, Self.dialogueKeys,
                       "the copy table and the pinned inventory must agree")
        for (key, expectedEN, expectedNE) in Self.dialogueCopy {
            assertCatalogValue(key, en: expectedEN, ne: expectedNE)
        }
    }

    /// Implementation note: the 17 entries are written as one contiguous,
    /// alphabetically ordered block in the catalog file. JSONSerialization
    /// loses key order, so this pin reads the raw file's key lines.
    func testTheDialogueFamilySitsAlphabeticallyAndContiguouslyInTheFile() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return
        }
        let keyLines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            // The catalog ships Xcode's unspaced `"key": {` form; the
            // spaced `"key" : {` variant is tolerated so a formatter
            // re-run cannot blind the pin (the dropLast width follows
            // whichever suffix matched).
            .filter { ($0.hasSuffix(" : {") || $0.hasSuffix(": {"))
                && $0.hasPrefix("    \"") }
            .map { line in
                let suffixWidth = line.hasSuffix(" : {") ? 5 : 4
                return String(line.dropFirst(5).dropLast(suffixWidth))
            }

        XCTAssertGreaterThan(keyLines.count, 1_000,
                             "the key-line scan found too few entries — the "
                             + "catalog layout changed and this pin is blind")

        // Family membership, not a prefix sweep: the family is the
        // pinned inventory (19 keys incl. `dialogue.correction.ask`,
        // moved into the block at the rebase), so a bare prefix filter
        // would let an unpinned `dialogue.*` key pass silently.
        let family = Set(Self.dialogueKeys)
        let indices = keyLines.enumerated()
            .filter { family.contains($0.element) }
            .map(\.offset)
        XCTAssertEqual(indices.count, Self.dialogueKeys.count,
                       "exactly \(Self.dialogueKeys.count) dialogue keys must "
                       + "sit in the file")
        guard let first = indices.first, let last = indices.last else { return }

        XCTAssertEqual(Array(indices), Array(first...last),
                       "the dialogue family must be one contiguous block")
        XCTAssertEqual(Array(keyLines[first...last]), Self.dialogueKeys,
                       "the family must be in alphabetical order")
        if first > 0 {
            XCTAssertEqual(keyLines[first - 1], "common.emergency",
                           "the alphabetical predecessor moved")
        }
        if last + 1 < keyLines.count {
            XCTAssertEqual(keyLines[last + 1], "directions.cancelled",
                           "the alphabetical successor moved")
        }
    }

    /// NFR-MTC-009: every line is spoken through `L10n.fmt`; the `%@`
    /// counts must agree between languages or the composed line mis-places
    /// its argument.
    func testTheDialoguePlaceholdersMatchBetweenLanguages() {
        let catalog = sourceCatalog()
        for key in Self.dialogueKeys {
            guard let entry = catalog[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let en = ((localizations["en"] as? [String: Any])?["stringUnit"]
                              as? [String: Any])?["value"] as? String,
                  let ne = ((localizations["ne"] as? [String: Any])?["stringUnit"]
                              as? [String: Any])?["value"] as? String else {
                XCTFail("\(key) is missing an en or ne value")
                continue
            }
            XCTAssertEqual(Self.placeholderCount(in: en),
                           Self.placeholderCount(in: ne),
                           "\(key): the en and ne copies disagree on how many "
                           + "arguments the format string takes")
        }
    }

    // MARK: T-155 — the call-dialer calling family (design-l2 §12)

    /// The five frozen keys of the calling feature (design-l2 §12,
    /// FR-CDP-017 / NFR-CDP-007): exactly these and no sixth user-visible
    /// string (SA-8). The keys and their parameter contracts are the
    /// frozen part; the copy itself is catalog-time work inside C7
    /// (design-l2 §31).
    private static let callingKeys: [String] = [
        "call.announce.fallbackRouted",
        "call.announce.launchFailedFallback",
        "router.call.fallbackDisclosure",
        "settings.calling.primaryTitle",
        "settings.calling.secondaryTitle",
    ]

    /// The catalog total at this unit's branch point — the dialogue pin's
    /// expected total (1,370 + 19). The calling family adds exactly its
    /// five keys and removes none, so the total is pinned at 1,394; the
    /// dialogue pin is rebased to 1,375 in the same change (one rebase
    /// point per merge, both families accounted).
    private static let callingBaselineKeyCount = 1_389

    /// The authored copy, both languages. The design freezes the keys and
    /// the parameter contracts, not the wording (catalog-time copy), so
    /// this pin makes every wording change — including an "improvement" —
    /// a deliberate one rather than a drift.
    private static let callingCopy: [(key: String, en: String, ne: String)] = [
        ("call.announce.fallbackRouted",
         "%1$@ isn't available — calling %2$@ via %3$@.",
         "%1$@ उपलब्ध छैन — %2$@ लाई %3$@ बाट कल गर्दैछु।"),
        ("call.announce.launchFailedFallback",
         "%1$@ didn't open for %2$@ — trying %3$@.",
         "%2$@ को %1$@ खुलेन — %3$@ मार्फत प्रयास गर्दैछु।"),
        ("router.call.fallbackDisclosure",
         "%1$@ isn't available, so I'll call %2$@ via %3$@.",
         "%1$@ उपलब्ध छैन, त्यसैले %2$@ लाई %3$@ बाट कल गर्नेछु।"),
        ("settings.calling.primaryTitle",
         "Primary dialer",
         "मुख्य डायलर"),
        ("settings.calling.secondaryTitle",
         "Fallback dialer",
         "वैकल्पिक डायलर"),
    ]

    /// Scenario: All five keys resolve in both languages — the
    /// behavioural half. Each key resolves through the shipped lproj
    /// bundles in both languages, the Nepali resolution is Devanagari and
    /// the two resolutions differ (no English copy pasted into `ne`).
    func testEveryCallingKeyResolvesInBothLanguages() {
        for key in Self.callingKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key,
                              "\(key) does not resolve in en — the catalog "
                              + "entry is missing")
            XCTAssertNotEqual(ne, key,
                              "\(key) does not resolve in ne — the catalog "
                              + "entry is missing")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty en copy")
            XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) resolves to empty ne copy")
            XCTAssertNotEqual(en, ne,
                              "\(key) resolves to the SAME string in en and ne "
                              + "— the Nepali copy is missing (or the key was "
                              + "forgotten in one language)")
            XCTAssertTrue(Self.containsDevanagari(ne),
                          "\(key) resolves to non-Devanagari Nepali copy: \(ne)")
        }
    }

    /// The binding parameter contract (design-l2 §12): the three template
    /// keys take three placeholders in BOTH languages; the two section
    /// titles take none. A translator dropping or duplicating a
    /// placeholder would make `L10n.fmt` mis-place an argument or crash.
    func testTheCallingPlaceholdersMatchBetweenLanguages() {
        let catalog = sourceCatalog()
        let contractCounts: [String: Int] = [
            "call.announce.fallbackRouted": 3,
            "call.announce.launchFailedFallback": 3,
            "router.call.fallbackDisclosure": 3,
            "settings.calling.primaryTitle": 0,
            "settings.calling.secondaryTitle": 0,
        ]
        for key in Self.callingKeys {
            guard let entry = catalog[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let en = ((localizations["en"] as? [String: Any])?["stringUnit"]
                              as? [String: Any])?["value"] as? String,
                  let ne = ((localizations["ne"] as? [String: Any])?["stringUnit"]
                              as? [String: Any])?["value"] as? String else {
                XCTFail("\(key) is missing an en or ne value")
                continue
            }
            let enCount = Self.placeholderCount(in: en)
            let neCount = Self.placeholderCount(in: ne)
            XCTAssertEqual(enCount, neCount,
                           "\(key): the en and ne copies disagree on how many "
                           + "arguments the format string takes")
            XCTAssertEqual(enCount, contractCounts[key],
                           "\(key): the copy does not bind the design's "
                           + "parameter contract")
        }
    }

    /// Scenario: The parity check names a missing value. The pure
    /// coverage check fails naming the offending key — the dialogue
    /// half's fixture discipline, applied to the calling family.
    func testTheCallingCoverageCheckFailsNamingTheMissingValue() {
        // Fixture 1: the ne value removed (the scenario's exact case).
        let key = "call.announce.launchFailedFallback"
        var missingNE = sourceCatalog()
        if var entry = missingNE[key] as? [String: Any],
           var localizations = entry["localizations"] as? [String: Any] {
            localizations.removeValue(forKey: "ne")
            entry["localizations"] = localizations
            missingNE[key] = entry
        }
        assertCallingCoverageFails(missingNE, naming: key)

        // Fixture 2: the whole entry removed.
        var missingEntry = sourceCatalog()
        missingEntry.removeValue(forKey: "settings.calling.secondaryTitle")
        assertCallingCoverageFails(missingEntry,
                                   naming: "settings.calling.secondaryTitle")

        // Fixture 3: a plausible sixth key in the family namespace.
        var stray = sourceCatalog()
        stray["router.call.fallbackNotice"] = Self.sampleEntry(en: "Stray",
                                                               ne: "थप")
        assertCallingCoverageFails(stray, naming: "router.call.fallbackNotice")
    }

    /// The explicit named assertion: the family is exactly the five
    /// pinned keys — present, `manual`, both units `translated`, Nepali
    /// Devanagari — and the catalog total is pinned, so no sixth
    /// user-visible string can slip in (SA-8).
    func testTheCallingFamilyPassesTheCoverageCheck() {
        let catalog = sourceCatalog()

        XCTAssertEqual(catalog.count,
                       Self.callingBaselineKeyCount + Self.callingKeys.count,
                       "the calling feature adds exactly "
                       + "\(Self.callingKeys.count) keys and removes none "
                       + "(baseline \(Self.callingBaselineKeyCount))")

        let failures = Self.callingCoverageFailures(in: catalog)
        XCTAssertTrue(failures.isEmpty,
                      "the calling coverage check failed:\n"
                      + failures.joined(separator: "\n"))
    }

    /// DoD evidence: the pinned copy, verbatim, both languages — a
    /// translation dropped or an English copy pasted into the `ne` slot
    /// fails here.
    func testTheCallingCopyIsPinnedVerbatim() {
        XCTAssertEqual(Self.callingCopy.map { $0.key }, Self.callingKeys,
                       "the copy table and the pinned inventory must agree")
        for (key, expectedEN, expectedNE) in Self.callingCopy {
            assertCatalogValue(key, en: expectedEN, ne: expectedNE)
        }
    }

    /// Implementation note: the inserted entries sit at their
    /// alphabetical positions inside the shipped families (the dialogue
    /// block's contiguity discipline, extended to intra-family
    /// insertions). The predecessor/successor pins catch a textual
    /// insertion that clobbered an entry.
    func testTheCallingKeysSitAlphabeticallyInTheFile() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return
        }
        let keyLines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { ($0.hasSuffix(" : {") || $0.hasSuffix(": {"))
                && $0.hasPrefix("    \"") }
            .map { line in
                let suffixWidth = line.hasSuffix(" : {") ? 5 : 4
                return String(line.dropFirst(5).dropLast(suffixWidth))
            }
        XCTAssertGreaterThan(keyLines.count, 1_000,
                             "the key-line scan found too few entries — the "
                             + "catalog layout changed and this pin is blind")

        var positions: [String: Int] = [:]
        for (offset, key) in keyLines.enumerated() where positions[key] == nil {
            positions[key] = offset
        }
        func neighbour(_ key: String, _ offset: Int) -> String? {
            guard let index = positions[key],
                  keyLines.indices.contains(index + offset) else { return nil }
            return keyLines[index + offset]
        }

        for key in Self.callingKeys {
            XCTAssertNotNil(positions[key],
                            "\(key) does not sit in the catalog file as a "
                            + "top-level entry")
        }
        XCTAssertEqual(neighbour("call.announce.fallbackRouted", -1),
                       "call.announce.faceTimeVideo",
                       "the alphabetical predecessor of fallbackRouted moved")
        XCTAssertEqual(neighbour("call.announce.fallbackRouted", 1),
                       "call.announce.launchFailedFallback",
                       "the announcing pair must sit contiguously")
        XCTAssertEqual(neighbour("call.announce.launchFailedFallback", 1),
                       "call.announce.messenger",
                       "the alphabetical successor of launchFailedFallback moved")
        XCTAssertEqual(neighbour("router.call.fallbackDisclosure", -1),
                       "router.call.facetimeUnavailable",
                       "the alphabetical predecessor of fallbackDisclosure moved")
        XCTAssertEqual(neighbour("router.call.fallbackDisclosure", 1),
                       "router.call.messengerNoHandle",
                       "the alphabetical successor of fallbackDisclosure moved")
        XCTAssertEqual(neighbour("settings.calling.primaryTitle", -1),
                       "settings.calendarSharing",
                       "the alphabetical predecessor of primaryTitle moved")
        XCTAssertEqual(neighbour("settings.calling.primaryTitle", 1),
                       "settings.calling.secondaryTitle",
                       "the two section titles must sit contiguously")
        XCTAssertEqual(neighbour("settings.calling.secondaryTitle", 1),
                       "settings.calling.title",
                       "the two section titles must precede settings.calling.title")
    }

    // MARK: T-155 helpers

    /// The calling coverage check as a pure function over a parsed
    /// catalog, so the gate's rules can be exercised against fixtures.
    /// Every failure names the offending key and the rule it broke. The
    /// family is membership in the calling namespaces — a key shaped like
    /// a calling key but outside the pinned inventory is a sixth
    /// user-visible string (SA-8).
    static func callingCoverageFailures(in catalog: [String: Any]) -> [String] {
        var failures: [String] = []
        let inventory = Set(callingKeys)
        let familyShaped = catalog.keys.filter { key in
            key.hasPrefix("call.announce.fallback")
                || key.hasPrefix("call.announce.launchFailed")
                || key.hasPrefix("router.call.fallback")
                || (key.hasPrefix("settings.calling.") && key.hasSuffix("Title"))
        }

        for key in familyShaped.sorted() where !inventory.contains(key) {
            failures.append("\(key): in the calling family but not in the "
                            + "pinned inventory (exactly \(callingKeys.count) "
                            + "keys)")
        }
        for key in callingKeys where catalog[key] == nil {
            failures.append("\(key): missing from the catalog")
        }
        for key in callingKeys {
            guard let entry = catalog[key] as? [String: Any] else { continue }
            if entry["extractionState"] as? String != "manual" {
                failures.append("\(key): extractionState is not `manual`")
            }
            guard let localizations = entry["localizations"] as? [String: Any] else {
                failures.append("\(key): no localizations")
                continue
            }
            for language in ["en", "ne"] {
                guard let unit = ((localizations[language] as? [String: Any])?["stringUnit"]
                                    as? [String: Any]),
                      let value = unit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failures.append("\(key): missing or empty \(language) value")
                    continue
                }
                if unit["state"] as? String != "translated" {
                    failures.append("\(key): \(language) is not marked `translated`")
                }
                if language == "ne" {
                    if containsASCIILetters(value) {
                        failures.append("\(key): Nepali value carries ASCII "
                                        + "letters — \(value)")
                    }
                    if !containsDevanagari(value) {
                        failures.append("\(key): Nepali value is not Devanagari "
                                        + "— \(value)")
                    }
                }
            }
        }
        return failures
    }

    /// Asserts the calling check fails naming `key`, with a message that
    /// shows every failure it produced.
    private func assertCallingCoverageFails(_ catalog: [String: Any],
                                            naming key: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let failures = Self.callingCoverageFailures(in: catalog)
        XCTAssertTrue(failures.contains { $0.contains(key) },
                      "the coverage check must fail naming \(key); it produced: "
                      + "\(failures)", file: file, line: line)
    }

    // MARK: T-129 helpers

    /// The dialogue coverage check as a pure function over a parsed
    /// catalog, so the gate's rules can be exercised against fixtures.
    /// Every failure names the offending key and the rule it broke.
    static func dialogueCoverageFailures(in catalog: [String: Any]) -> [String] {
        var failures: [String] = []
        let inventory = Set(dialogueKeys)
        let family = catalog.keys.filter { $0.hasPrefix("dialogue.") }

        for key in family where !inventory.contains(key) {
            failures.append("\(key): in the dialogue family but not in the "
                            + "pinned inventory (exactly \(dialogueKeys.count) "
                            + "keys)")
        }
        for key in dialogueKeys where !family.contains(key) {
            failures.append("\(key): missing from the catalog")
        }
        for key in dialogueKeys {
            guard let entry = catalog[key] as? [String: Any] else { continue }
            if entry["extractionState"] as? String != "manual" {
                failures.append("\(key): extractionState is not `manual`")
            }
            guard let localizations = entry["localizations"] as? [String: Any] else {
                failures.append("\(key): no localizations")
                continue
            }
            for language in ["en", "ne"] {
                guard let unit = ((localizations[language] as? [String: Any])?["stringUnit"]
                                    as? [String: Any]),
                      let value = unit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failures.append("\(key): missing or empty \(language) value")
                    continue
                }
                if unit["state"] as? String != "translated" {
                    failures.append("\(key): \(language) is not marked `translated`")
                }
                if language == "ne" {
                    if containsASCIILetters(value) {
                        failures.append("\(key): Nepali value carries ASCII "
                                        + "letters — \(value)")
                    }
                    if !containsDevanagari(value) {
                        failures.append("\(key): Nepali value is not Devanagari "
                                        + "— \(value)")
                    }
                }
            }
        }
        return failures
    }

    /// Asserts the check fails naming `key`, with a message that shows
    /// every failure it produced.
    private func assertCoverageFails(_ catalog: [String: Any],
                                     naming key: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let failures = Self.dialogueCoverageFailures(in: catalog)
        XCTAssertTrue(failures.contains { $0.contains(key) },
                      "the coverage check must fail naming \(key); it produced: "
                      + "\(failures)", file: file, line: line)
    }

    /// A minimal catalog entry with both languages translated, for the
    /// fixtures that add a key rather than remove one.
    private static func sampleEntry(en: String, ne: String) -> [String: Any] {
        [
            "extractionState": "manual",
            "localizations": [
                "en": ["stringUnit": ["state": "translated", "value": en]],
                "ne": ["stringUnit": ["state": "translated", "value": ne]],
            ],
        ]
    }

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

    /// Devanagari (U+0900–U+097F), by scalar.
    private static func containsDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// ASCII letters, the "English prose" signal the catalog forbids in a
    /// `ne` value (provider loanwords are Devanagari: युट्युब).
    private static func containsASCIILetters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }
}
