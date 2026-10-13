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
    /// and to 1,370 when the call-nearmiss merge (PR #166) added
    /// `router.call.didYouMeanPrefix`; then +5 call-dialer calling keys
    /// (PR #171) and +21 family-contacts keys (T-147) land on the same
    /// 1,389 base — the T-144 merge re-measured the combined catalog at
    /// 1,415, and this pin is the total minus the dialogue family's 19 keys
    /// (the 18 design-l2 §16 entries plus `dialogue.correction.ask`, moved
    /// into the family block at this rebase). The dialogue family adds
    /// exactly its keys and removes none, so the total is pinned (the
    /// Spotify-localisation suite's count discipline).
    private static let dialogueBaselineKeyCount = 1_396

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
        ("dialogue.correction.or", "Did you mean %@ or %@?",
         "तपाईंले %@ वा %@ भन्नुभएको हो?"),
        ("dialogue.didYouMean", "Did you mean %@?", "तपाईंले %@ भन्नुभएको हो?"),
        ("dialogue.option.conjunction", " or ", " वा "),
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

    /// The catalog total minus the calling family's five keys — re-measured
    /// at the T-144 merge (combined catalog 1,415 = 1,389 base + 5 calling
    /// + 21 family-contacts). The calling family adds exactly its five keys
    /// and removes none, so the total is pinned at 1,415; the dialogue and
    /// family pins are rebased in the same merge (one rebase point per
    /// merge, all three families accounted).
    private static let callingBaselineKeyCount = 1_410

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

    // MARK: T-147 — the family-contacts family (design-l2 §7, 21 frozen keys)

    /// The pinned inventory: design-l2 §7's frozen 21-key table, in table
    /// order — 8 `family.link.*`, 7 `family.photo.*`, 4 `family.nickname.*`,
    /// then the 2 `call.search.*` insertions. The three pre-existing
    /// `family.photo.add/change/remove` keys are deliberately NOT in this
    /// inventory: the contiguity pin names them at their in-place
    /// alphabetical positions instead (span entries 16-18).
    private static let familyContactsKeys: [String] = [
        "family.link.chip",
        "family.link.linkedTo",
        "family.link.unlink",
        "family.link.unlinkHint",
        "family.link.alreadyLinked",
        "family.link.stale",
        "family.link.pickHint",
        "family.link.sectionTitle",
        "family.photo.accessTitle",
        "family.photo.accessBody",
        "family.photo.accessDeniedBody",
        "family.photo.state.updatedInSystem",
        "family.photo.state.keptOnPhone",
        "family.photo.state.systemPhotoRemains",
        "family.photo.sourceSystem",
        "family.nickname.entryPlaceholder",
        "family.nickname.add",
        "family.nickname.removeLabel",
        "family.nickname.hint",
        "call.search.linkedBookName",
        "call.search.accessLimited",
    ]

    /// The design-l2 §7 frozen copy, verbatim, both languages. The rows
    /// mirror the design table 1:1; the copy review is upstream of this
    /// unit, so any wording change — including an "improvement" — must be a
    /// deliberate one rather than a drift.
    private static let familyContactsCopy: [(key: String, en: String, ne: String)] = [
        ("family.link.chip", "Linked",
         "जोडिएको"),
        ("family.link.linkedTo", "Linked to %@",
         "%@सँग जोडिएको"),
        ("family.link.unlink", "Remove link",
         "लिंक हटाउनुहोस्"),
        ("family.link.unlinkHint", "This only separates the two records. Nothing is deleted, and your phone's contact is not changed.",
         "यसले दुई रेकर्डलाई मात्र छुट्याउँछ। केही मेटिँदैन, र तपाईंको फोनको सम्पर्क परिवर्तन हुँदैन।"),
        ("family.link.alreadyLinked", "%@ is already a family contact.",
         "%@ पहिले नै परिवारको सम्पर्क हो।"),
        ("family.link.stale", "This phone contact is no longer in your address book. The link is ignored.",
         "यो फोन सम्पर्क अब तपाईंको फोनबुकमा छैन। लिंक बेवास्ता गरिएको छ।"),
        ("family.link.pickHint", "Choose the phone contact this person is in.",
         "यो व्यक्ति फोनमा कुन सम्पर्कको रूपमा छ, त्यो छान्नुहोस्।"),
        ("family.link.sectionTitle", "Phone contact",
         "फोन सम्पर्क"),
        ("family.photo.accessTitle", "Update this person's photo in your phone's contacts?",
         "यो व्यक्तिको फोटो फोनको सम्पर्कमा पनि अपडेट गर्ने हो?"),
        ("family.photo.accessBody", "Allowing contacts access lets the app copy the photo you choose onto this person's contact card. Nothing else in your contacts is changed. The app works fully even if you say no.",
         "सम्पर्क पहुँच अनुमति दिनुभयो भने, तपाईंले छान्नुभएको फोटो यो व्यक्तिको सम्पर्क कार्डमा प्रतिलिपि गर्न सकिन्छ। तपाईंको सम्पर्कमा अरू केही परिवर्तन हुँदैन। तपाईंले नभन्नुभए पनि एप पूरै चल्छ।"),
        ("family.photo.accessDeniedBody", "Contacts access is off, so the photo will be kept in this app only. You can change this in iPhone Settings.",
         "सम्पर्कको पहुँच बन्द छ, त्यसैले फोटो यही एपमा मात्र रहन्छ। तपाईं आईफोनको सेटिङमा यो बदल्न सक्नुहुन्छ।"),
        ("family.photo.state.updatedInSystem", "Photo updated in your phone's contacts.",
         "फोटो फोनको सम्पर्कमा अपडेट भयो।"),
        ("family.photo.state.keptOnPhone", "Kept in this app only.",
         "यही एपमा मात्र राखिएको।"),
        ("family.photo.state.systemPhotoRemains", "Your phone's contact still has its own photo. Change it in the Contacts app to remove it.",
         "तपाईंको फोनको सम्पर्कमा अझै आफ्नै फोटो छ। हटाउन कन्ट्याक्ट्स एपमा गएर बदल्नुहोस्।"),
        ("family.photo.sourceSystem", "Shown from your phone's contacts.",
         "फोनको सम्पर्कबाट देखाइएको।"),
        ("family.nickname.entryPlaceholder", "Add a name or variation (e.g. sanu, सानु)",
         "नाम वा अर्को रूप थप्नुहोस् (जस्तै sanu, सानु)"),
        ("family.nickname.add", "Add",
         "थप्नुहोस्"),
        ("family.nickname.removeLabel", "Remove %@",
         "%@ हटाउनुहोस्"),
        ("family.nickname.hint", "Any of these names finds this person — typed or spoken. Names are kept exactly as you enter them.",
         "यीमध्ये कुनै नामले यो व्यक्ति भेटिन्छ — टाइप गरेको वा बोलेको। नामहरू तपाईंले लेखेकै रूपमा राखिन्छ।"),
        ("call.search.linkedBookName", "Also in your phone book as %@",
         "फोनबुकमा %@ को रूपमा पनि छ"),
        ("call.search.accessLimited", "Searching shows only the contacts you allowed.",
         "खोज्दा तपाईंले अनुमति दिनुभएका सम्पर्कहरू मात्र देखिन्छन्।"),
    ]

    /// The exactly-four keys permitted to carry one `%@` (design-l2 §7). No
    /// other key in the family carries any `%`.
    private static let familyContactsPlaceholderKeys: [String] = [
        "family.link.linkedTo",
        "family.link.alreadyLinked",
        "family.nickname.removeLabel",
        "call.search.linkedBookName",
    ]

    /// design-l2 §7 wording note: the nicknames entry placeholder is the
    /// ONLY `ne` value in the family permitted to carry ASCII letters — it
    /// carries the romanized example "sanu" deliberately (the
    /// store-as-entered showcase). The Devanagari-presence rule still
    /// applies to it.
    private static let familyContactsRomanizedExampleKey = "family.nickname.entryPlaceholder"
    private static let familyContactsRomanizedExample = "sanu"

    /// The exact raw-catalog key lines between `family.emergencyToggleHint`
    /// and `family.relationship.brother` (both EXCLUDED), in file order —
    /// design-l2 §7's corrected 22-line contiguity pin: the 12 new
    /// `family.link.`/`family.nickname.` keys, then the 10 `family.photo.*`
    /// keys including the 3 PRE-EXISTING ones at their alphabetical
    /// positions 16-18 (19 new + 3 existing = 22).
    private static let familyContactsSpan: [String] = [
        "family.link.alreadyLinked",
        "family.link.chip",
        "family.link.linkedTo",
        "family.link.pickHint",
        "family.link.sectionTitle",
        "family.link.stale",
        "family.link.unlink",
        "family.link.unlinkHint",
        "family.nickname.add",
        "family.nickname.entryPlaceholder",
        "family.nickname.hint",
        "family.nickname.removeLabel",
        "family.photo.accessBody",
        "family.photo.accessDeniedBody",
        "family.photo.accessTitle",
        "family.photo.add",
        "family.photo.change",
        "family.photo.remove",
        "family.photo.sourceSystem",
        "family.photo.state.keptOnPhone",
        "family.photo.state.systemPhotoRemains",
        "family.photo.state.updatedInSystem",
    ]

    /// The catalog total minus this feature's 21 keys — re-measured at the
    /// T-144 call-dialer merge (combined catalog 1,415 = 1,389 base + 5
    /// calling + 21 family-contacts). The +21 delta is the constant, not
    /// the absolute; the absolute is re-measured per merge deliberately
    /// rather than guessed (TG-29 failure-path scenario: no stale pin, no
    /// guessing).
    private static let familyContactsBaselineKeyCount = 1_394

    /// Scenario: All 21 keys exist in both languages — the behavioural
    /// half. Every key resolves through the shipped lproj bundles in both
    /// languages; the Nepali resolution is Devanagari copy and the two
    /// values differ, so a forgotten or pasted translation fails here.
    func testEveryFamilyContactsKeyResolvesInBothLanguages() {
        for key in Self.familyContactsKeys {
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

    /// Scenario: All 21 keys exist in both languages — the source half.
    /// The catalog total is pinned to the freshly measured pre-unit count
    /// plus exactly the 21 insertions; the coverage check then runs its
    /// rules over the parsed catalog, and the neighbours pin the
    /// `call.search.*` insertion points against a clobbering textual edit.
    func testTheFamilyContactsFamilyPassesTheCoverageCheck() {
        let catalog = sourceCatalog()

        XCTAssertEqual(catalog.count,
                       Self.familyContactsBaselineKeyCount + Self.familyContactsKeys.count,
                       "the feature adds exactly \(Self.familyContactsKeys.count) keys "
                       + "and removes none (baseline \(Self.familyContactsBaselineKeyCount), "
                       + "measured on this tree)")

        let failures = Self.familyContactsCoverageFailures(in: catalog)
        XCTAssertTrue(failures.isEmpty,
                      "the family-contacts coverage check failed:\n"
                      + failures.joined(separator: "\n"))

        // The immediate alphabetical neighbours of the `call.search.*`
        // insertion points: if a textual insertion had clobbered an entry,
        // one of these would change. (The `family.*` block's own neighbours
        // are pinned by the raw-line span check.)
        assertCatalogValue("call.openWhatsAppContacts",
                           en: "WhatsApp contacts",
                           ne: "ह्वाट्सएप सम्पर्कहरू")
        assertCatalogValue("call.search.allowBody",
                           en: "Your phone book holds everyone — people you saved AND people added by WhatsApp, Messenger and other apps. Allow access, and the assistant can call any of them from this screen.",
                           ne: "तपाईंको फोन बुकमा सबै हुन्छन् — आफूले राखेका र व्हाट्सएप, मेसेन्जर लगायतका एपले थपेका मान्छेहरू पनि। पहुँच दिनुभयो भने असिस्टेन्टले यही स्क्रिनबाट जोसुकैलाई फोन गर्न सक्छ।")
        assertCatalogValue("call.search.familyChip",
                           en: "Family",
                           ne: "परिवार")
        assertCatalogValue("call.search.loadFailed",
                           en: "Couldn't read your contacts. Please try again.",
                           ne: "तपाईंका सम्पर्कहरू पढ्न सकिएन। फेरि प्रयास गर्नुहोस्।")
    }

    /// Scenario: Coverage test fails on a missing or moved key — and the
    /// failure-path scenario: Nepali key missing while English exists. Each
    /// fixture is a copy of the parsed catalog mutated in one way; the
    /// coverage check must fail naming the offending key.
    func testTheCoverageCheckFailsNamingTheMissingFamilyContactValue() {
        func setValue(_ value: String, key: String, language: String,
                      into catalog: inout [String: Any],
                      file: StaticString = #filePath, line: UInt = #line) {
            guard var entry = catalog[key] as? [String: Any],
                  var localizations = entry["localizations"] as? [String: Any],
                  var languageEntry = localizations[language] as? [String: Any],
                  var unit = languageEntry["stringUnit"] as? [String: Any] else {
                XCTFail("fixture setup: \(key).\(language) is missing",
                        file: file, line: line)
                return
            }
            unit["value"] = value
            languageEntry["stringUnit"] = unit
            localizations[language] = languageEntry
            entry["localizations"] = localizations
            catalog[key] = entry
        }
        func removeLanguage(_ language: String, key: String,
                            from catalog: inout [String: Any]) {
            guard var entry = catalog[key] as? [String: Any],
                  var localizations = entry["localizations"] as? [String: Any] else {
                XCTFail("fixture setup: \(key) is missing")
                return
            }
            localizations.removeValue(forKey: language)
            entry["localizations"] = localizations
            catalog[key] = entry
        }

        // Fixture 1: the Nepali value removed while English remains (the
        // failure-path scenario's exact case).
        var missingNE = sourceCatalog()
        removeLanguage("ne", key: "family.link.linkedTo", from: &missingNE)
        assertFamilyCoverageFails(missingNE, naming: "family.link.linkedTo")

        // Fixture 2: one key removed from the English catalog.
        var missingEN = sourceCatalog()
        removeLanguage("en", key: "family.link.linkedTo", from: &missingEN)
        assertFamilyCoverageFails(missingEN, naming: "family.link.linkedTo")

        // Fixture 3: the whole entry removed.
        var missingEntry = sourceCatalog()
        missingEntry.removeValue(forKey: "family.nickname.hint")
        assertFamilyCoverageFails(missingEntry, naming: "family.nickname.hint")

        // Fixture 4: a blank Nepali value.
        var blankNE = sourceCatalog()
        setValue("   ", key: "family.photo.state.updatedInSystem",
                 language: "ne", into: &blankNE)
        assertFamilyCoverageFails(blankNE, naming: "family.photo.state.updatedInSystem")

        // Fixture 5: the English value copied into the Nepali slot.
        var untranslatedNE = sourceCatalog()
        setValue("Linked", key: "family.link.chip", language: "ne", into: &untranslatedNE)
        assertFamilyCoverageFails(untranslatedNE, naming: "family.link.chip")

        // Fixture 6: the placeholder dropped from a format key's Nepali copy.
        var noPlaceholder = sourceCatalog()
        setValue("जोडिएको", key: "family.link.linkedTo", language: "ne",
                 into: &noPlaceholder)
        assertFamilyCoverageFails(noPlaceholder, naming: "family.link.linkedTo")

        // Fixture 7: a stray `%` in a key that must carry none.
        var strayPlaceholder = sourceCatalog()
        setValue("This phone contact is 100% gone.",
                 key: "family.link.stale", language: "en", into: &strayPlaceholder)
        assertFamilyCoverageFails(strayPlaceholder, naming: "family.link.stale")

        // Fixture 8: ASCII letters in a Nepali value outside the single
        // documented exemption (Devanagari present, so only the ASCII rule
        // can fire).
        var asciiNE = sourceCatalog()
        setValue("यही एपमा only", key: "family.photo.state.keptOnPhone",
                 language: "ne", into: &asciiNE)
        assertFamilyCoverageFails(asciiNE, naming: "family.photo.state.keptOnPhone")

        // Fixture 9: a stray key in a family-contacts namespace — the
        // "exactly the pinned inventory" rule.
        var stray = sourceCatalog()
        stray["family.link.stray"] = Self.sampleEntry(en: "Stray", ne: "थप")
        assertFamilyCoverageFails(stray, naming: "family.link.stray")

        // Fixture 10: an unpinned `family.photo.*` key (the pre-existing
        // three are named, so an eleventh fails).
        var strayPhoto = sourceCatalog()
        strayPhoto["family.photo.stray"] = Self.sampleEntry(en: "Stray", ne: "थप")
        assertFamilyCoverageFails(strayPhoto, naming: "family.photo.stray")

        // Fixture 11: the count pin's delta semantics — any extra key
        // breaks the baseline arithmetic, so a catalog that grew without a
        // deliberate re-measure cannot pass.
        var drifted = sourceCatalog()
        drifted["t147.driftProbe"] = Self.sampleEntry(en: "Drift", ne: "थप")
        XCTAssertNotEqual(drifted.count,
                          Self.familyContactsBaselineKeyCount + Self.familyContactsKeys.count,
                          "any added key must break the count pin until the "
                          + "baseline is re-measured deliberately")
    }

    /// Scenario: Coverage test fails on a missing or moved key — the
    /// placement half. The check itself rejects each mutant, so the
    /// contiguity rule is enforced by the gate and not only by the
    /// assertion on the real file.
    func testTheSpanCheckFailsOnAMovedOrSmuggledFamilyContactsKey() {
        let real = rawCatalogKeyLines()
        XCTAssertTrue(Self.familyContactsSpanFailures(in: real).isEmpty,
                      "the fixture must start from a passing scan")

        // Fixture 1: one key moved out of the span — removed from its
        // alphabetical position and appended at the end.
        var moved = real
        if let index = moved.firstIndex(of: "family.link.chip") {
            moved.remove(at: index)
        }
        moved.append("family.link.chip")
        XCTAssertTrue(Self.familyContactsSpanFailures(in: moved)
                        .contains { $0.contains("family.link.chip") },
                      "moving family.link.chip out of the span must fail "
                      + "naming it")

        // Fixture 2: the `call.search.linkedBookName` insertion moved past
        // its pinned successor.
        var swapped = real
        if let index = swapped.firstIndex(of: "call.search.linkedBookName"),
           index + 1 < swapped.count {
            swapped.swapAt(index, index + 1)
        }
        XCTAssertTrue(Self.familyContactsSpanFailures(in: swapped)
                        .contains { $0.contains("call.search.linkedBookName") },
                      "swapping the pinned neighbours must fail naming "
                      + "call.search.linkedBookName")

        // Fixture 3: an unpinned key smuggled into the span.
        var smuggled = real
        if let index = smuggled.firstIndex(of: "family.link.chip") {
            smuggled.insert("family.link.stray", at: index)
        }
        XCTAssertTrue(Self.familyContactsSpanFailures(in: smuggled)
                        .contains { $0.contains("family.link.stray") },
                      "an unpinned key inside the span must fail naming it")
    }

    /// Implementation note: the raw catalog key lines between
    /// `family.emergencyToggleHint` and `family.relationship.brother` are
    /// EXACTLY the pinned 22, in order (JSONSerialization loses key order,
    /// so this pin reads the raw file), and the two `call.search.*`
    /// insertions sit between their named neighbours.
    func testTheFamilyContactsBlockSitsContiguouslyBetweenItsNeighbours() {
        let keyLines = rawCatalogKeyLines()
        XCTAssertGreaterThan(keyLines.count, 1_000,
                             "the key-line scan found too few entries — the "
                             + "catalog layout changed and this pin is blind")
        let failures = Self.familyContactsSpanFailures(in: keyLines)
        XCTAssertTrue(failures.isEmpty,
                      "the family-contacts span check failed:\n"
                      + failures.joined(separator: "\n"))
    }

    /// DoD evidence: every value is the design-l2 §7 frozen copy, verbatim,
    /// in both languages — a dropped translation or an English copy pasted
    /// into the `ne` slot fails here.
    func testTheFamilyContactsCopyMatchesTheDesignFrozenTableVerbatim() {
        XCTAssertEqual(Self.familyContactsCopy.map { $0.key }, Self.familyContactsKeys,
                       "the copy table and the pinned inventory must agree")
        for (key, expectedEN, expectedNE) in Self.familyContactsCopy {
            assertCatalogValue(key, en: expectedEN, ne: expectedNE)
        }
    }

    /// design-l2 §7 wording note: `family.nickname.entryPlaceholder` is the
    /// ONLY key whose Nepali value may carry ASCII letters, and its
    /// exemption covers exactly the pinned romanized example ("sanu") — no
    /// other ASCII may hide there, and no other key may carry any.
    func testOnlyTheNicknamesPlaceholderCarriesASCIIInNepali() {
        for key in Self.familyContactsKeys {
            guard let ne = catalogValue(key, language: "ne") else {
                XCTFail("\(key) is missing a ne value")
                continue
            }
            if key == Self.familyContactsRomanizedExampleKey {
                XCTAssertTrue(ne.contains(Self.familyContactsRomanizedExample),
                              "the exemption must actually carry the romanized "
                              + "example — otherwise it is dead copy: \(ne)")
                let withoutExample = ne.replacingOccurrences(
                    of: Self.familyContactsRomanizedExample, with: "")
                XCTAssertFalse(Self.containsASCIILetters(withoutExample),
                               "the exemption permits exactly the pinned example, "
                               + "no other ASCII: \(ne)")
            } else {
                XCTAssertFalse(Self.containsASCIILetters(ne),
                               "\(key) ne carries ASCII letters (only "
                               + "\(Self.familyContactsRomanizedExampleKey) may): \(ne)")
            }
        }
    }

    /// design-l2 §7: exactly four keys carry one `%@`; no key carries any
    /// other `%`, and the en/ne counts agree or a composition site would
    /// mis-place its argument.
    func testTheFamilyContactsPlaceholderRuleHoldsInBothLanguages() {
        XCTAssertEqual(Set(Self.familyContactsPlaceholderKeys),
                       ["family.link.linkedTo", "family.link.alreadyLinked",
                        "family.nickname.removeLabel", "call.search.linkedBookName"],
                       "the placeholder-key pin must be the design's four")
        for key in Self.familyContactsKeys {
            guard let en = catalogValue(key, language: "en"),
                  let ne = catalogValue(key, language: "ne") else {
                XCTFail("\(key) is missing an en or ne value")
                continue
            }
            let expected = Self.familyContactsPlaceholderKeys.contains(key) ? 1 : 0
            XCTAssertEqual(Self.placeholderCount(in: en), expected,
                           "\(key): en must carry \(expected) `%` placeholder(s)")
            XCTAssertEqual(Self.placeholderCount(in: ne), expected,
                           "\(key): ne must carry \(expected) `%` placeholder(s)")
            if expected == 1 {
                XCTAssertTrue(en.contains("%@") && ne.contains("%@"),
                              "\(key): the single placeholder must be `%@` in both languages")
            }
        }
    }

    // MARK: T-147 — the contacts usage disclosure (design-l2 §7, frozen)

    /// The frozen replacement string (design-l2 §7), verbatim.
    private static let frozenContactsDisclosure = "Searching from the phone screen can call anyone in your phone book — including people added by WhatsApp, Messenger and other apps. When you set a photo for a family contact who is also in your phone book, the app can save that photo onto the person's contact card if you allow it; it changes nothing else. The app works fully even if you say no."

    /// The usage-description keys as shipped before this unit (pinned so
    /// "no new usage keys" is a checked claim).
    private static let pinnedUsageDescriptionKeys: [String] = [
        "NSAlarmKitUsageDescription",
        "NSCalendarsFullAccessUsageDescription",
        "NSCalendarsUsageDescription",
        "NSCameraUsageDescription",
        "NSContactsUsageDescription",
        "NSLocalNetworkUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
        "NSRemindersFullAccessUsageDescription",
        "NSRemindersUsageDescription",
        "NSSpeechRecognitionUsageDescription",
    ]

    /// Scenario: Contacts disclosure matches actual usage. The app's first
    /// write into the shared address book makes the old read/search-only
    /// string false by omission; the frozen replacement names the write,
    /// its one-contact limit and the honest no-permission state.
    func testTheContactsDisclosureStatesReadingAndThePhotoWrite() {
        let disclosure = sourceInfoPlist()["NSContactsUsageDescription"] as? String ?? ""

        XCTAssertEqual(disclosure, Self.frozenContactsDisclosure,
                       "the disclosure must be the design-l2 §7 frozen copy, "
                       + "verbatim")
        XCTAssertFalse(disclosure.contains("other apps. The app works fully"),
                       "the old read/search-only string must be gone")
        let lowered = disclosure.lowercased()
        XCTAssertTrue(lowered.contains("call anyone in your phone book"),
                      "the read/search use must stay disclosed")
        XCTAssertTrue(lowered.contains("save that photo onto the person's contact card"),
                      "the photo write into the linked system contact must be disclosed")
        XCTAssertTrue(lowered.contains("if you allow it")
                        && lowered.contains("it changes nothing else"),
                      "the write permission gate and its one-contact limit must be stated")
        XCTAssertTrue(lowered.contains("works fully even if you say no"),
                      "the honest no-permission state must stay")
        XCTAssertFalse(Self.containsDevanagari(disclosure),
                       "usage-description strings are English-only by the "
                       + "accepted security residual (design-l2 §7 note)")
    }

    /// design-l2 §7: the disclosure replacement is the ONLY plist change —
    /// no new usage keys. In particular no separate write-only contacts
    /// descriptor may appear: the designed write seam needs read-and-write
    /// access, so a write-only key would license a different flow.
    func testThePlistAddsNoNewUsageDescriptionKeys() {
        let usage = sourceInfoPlist().keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        XCTAssertEqual(usage, Self.pinnedUsageDescriptionKeys,
                       "the usage-description key set must be unchanged by this unit")
        XCTAssertFalse(usage.contains("NSContactsWriteOnlyAccessUsageDescription"),
                       "no write-only contacts descriptor may appear")
    }

    // MARK: T-147 helpers

    /// The family-contacts coverage check as a pure function over a parsed
    /// catalog, so every rule can be exercised against fixtures. Each
    /// failure names the offending key and the rule it broke.
    static func familyContactsCoverageFailures(in catalog: [String: Any]) -> [String] {
        var failures: [String] = []
        let inventory = Set(familyContactsKeys)
        let newNamespaces = ["family.link.", "family.nickname."]
        let photoInventory = inventory.union(["family.photo.add",
                                              "family.photo.change",
                                              "family.photo.remove"])

        // Keys in the namespaces this unit owns that are not pinned. The
        // `family.photo.*` family is pinned as the 10 = 3 existing + 7 new.
        for key in catalog.keys {
            if newNamespaces.contains(where: { key.hasPrefix($0) })
                && !inventory.contains(key) {
                failures.append("\(key): unpinned key in a family-contacts "
                                + "namespace (the inventory is exactly "
                                + "\(familyContactsKeys.count) keys)")
            }
            if key.hasPrefix("family.photo.") && !photoInventory.contains(key) {
                failures.append("\(key): unpinned family.photo.* key")
            }
        }

        for key in familyContactsKeys {
            guard let entry = catalog[key] as? [String: Any] else {
                failures.append("\(key): missing from the catalog")
                continue
            }
            if entry["extractionState"] as? String != "manual" {
                failures.append("\(key): extractionState is not `manual`")
            }
            guard let localizations = entry["localizations"] as? [String: Any] else {
                failures.append("\(key): no localizations")
                continue
            }
            var values: [String: String] = [:]
            for language in ["en", "ne"] {
                guard let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                        as? [String: Any],
                      let value = unit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failures.append("\(key): missing or empty \(language) value")
                    continue
                }
                values[language] = value
                if unit["state"] as? String != "translated" {
                    failures.append("\(key): \(language) is not marked `translated`")
                }
                if language == "ne" {
                    if key != familyContactsRomanizedExampleKey && containsASCIILetters(value) {
                        failures.append("\(key): Nepali value carries ASCII "
                                        + "letters — \(value)")
                    }
                    if !containsDevanagari(value) {
                        failures.append("\(key): Nepali value is not Devanagari "
                                        + "— \(value)")
                    }
                }
            }
            // The placeholder rule (design-l2 §7): exactly the four named
            // keys carry one `%@`; no key carries any other `%`.
            let mustCarryPlaceholder = familyContactsPlaceholderKeys.contains(key)
            for (language, value) in values {
                let count = placeholderCount(in: value)
                if mustCarryPlaceholder {
                    if count != 1 || !value.contains("%@") {
                        failures.append("\(key): \(language) must carry exactly "
                                        + "one %@ placeholder (found \(count) %)")
                    }
                } else if count != 0 {
                    failures.append("\(key): \(language) carries a % but no key "
                                    + "outside the four placeholder keys may")
                }
            }
            if let en = values["en"], let ne = values["ne"], en == ne {
                failures.append("\(key): en and ne resolve to the same value — "
                                + "the Nepali copy is missing")
            }
        }
        return failures
    }

    /// The exact-span placement check as a pure function over the raw
    /// file's key lines, so the "moved key" scenario can run against a
    /// fixture. Both named neighbour keys are EXCLUDED from the span; the
    /// span comparison is order-sensitive (a reordered block fails), and
    /// the two `call.search.*` insertions are pinned to their immediate
    /// neighbours by name.
    static func familyContactsSpanFailures(in keyLines: [String]) -> [String] {
        var failures: [String] = []
        guard let predecessor = keyLines.firstIndex(of: "family.emergencyToggleHint") else {
            return ["family.emergencyToggleHint: the span's predecessor is "
                    + "missing — the placement pin is blind"]
        }
        guard let successor = keyLines.firstIndex(of: "family.relationship.brother") else {
            return ["family.relationship.brother: the span's successor is "
                    + "missing — the placement pin is blind"]
        }
        if successor <= predecessor + 1 {
            return ["no family-contacts span between "
                    + "family.emergencyToggleHint and family.relationship.brother"]
        }
        let span = Array(keyLines[(predecessor + 1)..<successor])
        if span != familyContactsSpan {
            for key in familyContactsSpan where !span.contains(key) {
                failures.append("\(key): not inside the pinned 22-line span "
                                + "(moved or removed)")
            }
            for key in span where !familyContactsSpan.contains(key) {
                failures.append("\(key): inside the family span but not in the "
                                + "pinned 22 — unpinned or wrongly placed")
            }
            if Set(span) == Set(familyContactsSpan) {
                failures.append("the family span carries the pinned keys but "
                                + "not in the pinned order (or with a duplicate)")
            }
            if span.count != familyContactsSpan.count {
                failures.append("the family span has \(span.count) key lines — "
                                + "expected \(familyContactsSpan.count)")
            }
        }

        let neighbours: [(predecessor: String, key: String, successor: String)] = [
            ("call.openWhatsAppContacts", "call.search.accessLimited",
             "call.search.allowBody"),
            ("call.search.familyChip", "call.search.linkedBookName",
             "call.search.loadFailed"),
        ]
        for (before, key, after) in neighbours {
            guard let index = keyLines.firstIndex(of: key) else {
                failures.append("\(key): missing from the catalog")
                continue
            }
            if index == 0 || keyLines[index - 1] != before {
                failures.append("\(key): predecessor is "
                                + "\(index == 0 ? "none" : keyLines[index - 1]) "
                                + "— expected \(before)")
            }
            if index + 1 >= keyLines.count || keyLines[index + 1] != after {
                failures.append("\(key): successor is "
                                + "\(index + 1 >= keyLines.count ? "none" : keyLines[index + 1]) "
                                + "— expected \(after)")
            }
        }
        return failures
    }

    /// Asserts the family-contacts check fails naming `key`, showing every
    /// failure it produced.
    private func assertFamilyCoverageFails(_ catalog: [String: Any],
                                           naming key: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let failures = Self.familyContactsCoverageFailures(in: catalog)
        XCTAssertTrue(failures.contains { $0.contains(key) },
                      "the coverage check must fail naming \(key); it produced: "
                      + "\(failures)", file: file, line: line)
    }

    /// The raw catalog's key lines, in file order (the dialogue pin's scan
    /// convention: the catalog ships Xcode's unspaced `"key": {` form, the
    /// spaced variant is tolerated so a formatter re-run cannot blind the
    /// pin).
    private func rawCatalogKeyLines() -> [String] {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return []
        }
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { ($0.hasSuffix(" : {") || $0.hasSuffix(": {"))
                && $0.hasPrefix("    \"") }
            .map { line in
                let suffixWidth = line.hasSuffix(" : {") ? 5 : 4
                return String(line.dropFirst(5).dropLast(suffixWidth))
            }
    }

    /// The source `Info.plist`, parsed as the artifact under review.
    private func sourceInfoPlist() -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("could not read the source Info.plist at \(url.path)")
            return [:]
        }
        return plist
    }

    /// The parsed catalog's value for `key` in `language`, or nil.
    private func catalogValue(_ key: String, language: String) -> String? {
        let catalog = sourceCatalog()
        guard let entry = catalog[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                        as? [String: Any],
              let value = unit["value"] as? String else {
            return nil
        }
        return value
    }

}
