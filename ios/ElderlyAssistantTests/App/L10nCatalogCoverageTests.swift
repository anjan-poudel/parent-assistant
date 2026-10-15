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
///
/// T-147 extends it with the family-contacts family (design-l2 §7).
///
/// T-171 extends it with the conversational-nepali-replies cloud-chat
/// family (design-l1 §17): the 18 consent/disclosure/indicator/
/// revocation/state/safe-template keys, the bounded safe-template set
/// (the register bar, mirrored from T-166's style spec) and a sweep that
/// reports user-visible copy hardcoded on the feature's surfaces.
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
    /// Spotify-localisation suite's count discipline). Re-measured at the
    /// news-feed-images merge (2026-10-14): three non-dialogue keys landed
    /// on master since the T-147 measurement (`launcher.chipCancel`,
    /// `launcher.chipOpen`, `settings.gemini.change`), and that branch
    /// adds `feeds.readerTitle` — total 1,421, so this baseline is 1,402.
    /// Re-measured at the T-171 cloud-chat copy landing (2026-10-14): the
    /// 18-key cloud-chat family (design-l1 §17) lands on the same tree —
    /// total 1,439 — so this baseline is 1,420. Re-measured at the home
    /// medium-fit dock labels (2026-10-15): two medium-mode dock keys
    /// (`home.dock.appliance`, `home.dock.translate`) land on the same
    /// tree — total 1,441; and at the T-012 medication localisation
    /// landing (2026-10-15): the 42-key medication family (design-l2 C13)
    /// lands on this W0 tree — total 1,483 — so this baseline is 1,464.
    private static let dialogueBaselineKeyCount = 1_464

    /// The design-l2 §16 draft copy, verbatim, both languages. The owner
    /// copy review is a later step recorded in the plan; this pin makes
    /// every wording change — including an "improvement" — a deliberate
    /// one rather than a drift.
    private static let dialogueCopy: [(key: String, en: String, ne: String)] = [
        ("dialogue.cancelled", "OK.", "ठीक छ।"),
        ("dialogue.candidate.appLaunch", "open %@", "%@ खोल्ने"),
        ("dialogue.candidate.music", "play %@", "%@"),
        ("dialogue.candidate.news", "the news", "समाचार"),
        ("dialogue.candidate.youtube", "%@ on YouTube", "युट्युबमा %@"),
        ("dialogue.correction.ask", "I heard «%@» — %@?",
         "«%@» सुनें। %@ भन्ने?"),
        ("dialogue.didYouMean", "You mean %@?", "तपाईंले %@ भन्नुभयो?"),
        ("dialogue.escape", "Go ahead, say it again.", "फेरि भन्नुस् न।"),
        ("dialogue.exhausted", "Didn't get it — we'll try again later.",
         "बुझिन, पछि फेरि भन्नुहोस् न।"),
        ("dialogue.option.anyPlay", "just play anything", "जे पनि बजाऊ"),
        ("dialogue.option.bhajan.bishnu", "bishnu", "विष्णु"),
        ("dialogue.option.bhajan.devi", "devi", "देवी"),
        ("dialogue.option.bhajan.durga", "durga", "दुर्गा"),
        ("dialogue.option.bhajan.shiva", "shiva", "शिव"),
        ("dialogue.option.conjunction", " or ", " वा "),
        ("dialogue.probe.bhajanKind", "Whose bhajan?", "कसको भजन लगाऊ?"),
        ("dialogue.probe.musicAny", "What shall I play?", "के सुन्ने हो?"),
        ("dialogue.retry", "One more time.", "फेरि भन्नुस् न।"),
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
            XCTAssertTrue(Self.isDevanagariOrPlaceholderOnly(ne),
                          "\(key) resolves to non-Devanagari Nepali copy: \(ne)")
        }
    }

    /// A Nepali value must be Devanagari — unless it is placeholder-only
    /// (`%@`, the casual-copy candidate labels that fill from the user's
    /// own words and carry no translatable text of their own; 2026-10-13).
    private static func isDevanagariOrPlaceholderOnly(_ value: String) -> Bool {
        let spoken = value.replacingOccurrences(of: "%@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spoken.isEmpty || containsDevanagari(value)
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
    /// merge, all three families accounted). Re-measured at the
    /// news-feed-images merge (2026-10-14): total 1,421 (three post-T-144
    /// master keys plus `feeds.readerTitle`), so this baseline is 1,416.
    /// Re-measured at the T-171 cloud-chat copy landing (2026-10-14): the
    /// 18-key cloud-chat family (design-l1 §17) lands on the same tree —
    /// total 1,439 — so this baseline is 1,434. Re-measured at the home
    /// medium-fit dock labels (2026-10-15): two medium-mode dock keys
    /// (`home.dock.appliance`, `home.dock.translate`) land on the same
    /// tree — total 1,441; and at the T-012 medication localisation
    /// landing (2026-10-15): the 42-key medication family (design-l2 C13)
    /// lands on this W0 tree — total 1,483 — so this baseline is 1,478.
    private static let callingBaselineKeyCount = 1_478

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
            XCTAssertTrue(Self.isDevanagariOrPlaceholderOnly(ne),
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
                    if !isDevanagariOrPlaceholderOnly(value) {
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
                    if !isDevanagariOrPlaceholderOnly(value) {
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
        "family.dialerOverride.default",
        "family.dialerOverride.title",
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
        ("family.dialerOverride.default", "Default", "पहिलेजस्तै"),
        ("family.dialerOverride.title", "Call app for this person",
         "यो व्यक्तिलाई कुन एपले फोन गर्ने?"),
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
        "family.dialerOverride.default",
        "family.dialerOverride.title",
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
    /// guessing). Re-measured at the news-feed-images merge (2026-10-14):
    /// total 1,421 (three post-T-144 master keys plus
    /// `feeds.readerTitle`), so this baseline is 1,398. Re-measured at the
    /// T-171 cloud-chat copy landing (2026-10-14): the 18-key cloud-chat
    /// family (design-l1 §17) lands on the same tree — total 1,439 — so
    /// this baseline is 1,416. Re-measured at the home medium-fit dock
    /// labels (2026-10-15): two medium-mode dock keys land on the same
    /// tree — total 1,441; and at the T-012 medication localisation
    /// landing (2026-10-15): the 42-key medication family (design-l2 C13)
    /// lands on this W0 tree — total 1,483 — so this baseline is 1,460.
    private static let familyContactsBaselineKeyCount = 1_460

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
            XCTAssertTrue(Self.isDevanagariOrPlaceholderOnly(ne),
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
                    if !isDevanagariOrPlaceholderOnly(value) {
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

    // MARK: T-171 — the conversational-nepali-replies cloud-chat family (design-l1 §17)

    /// The 15-key chat block of the family, alphabetical, as it sits in the
    /// catalog file between `caregiverNotify.shareHint` and
    /// `cloudCascade.holdCue` (design-l1 §17): the four safe templates, the
    /// consent question and its two answers, the indicator pair, the
    /// revocation trio and the two spoken state answers.
    private static let cloudChatChatBlockKeys: [String] = [
        "chat.safeTemplate.danglingParticle",
        "chat.safeTemplate.devanagariPurity",
        "chat.safeTemplate.generic",
        "chat.safeTemplate.honorificAgreement",
        "cloud.chat.consent.allow",
        "cloud.chat.consent.body",
        "cloud.chat.consent.notNow",
        "cloud.chat.consent.title",
        "cloud.chat.indicator",
        "cloud.chat.indicatorSpoken",
        "cloud.chat.revoke.body",
        "cloud.chat.revoke.done",
        "cloud.chat.revoke.title",
        "cloud.chat.state.spoken.off",
        "cloud.chat.state.spoken.on",
    ]

    /// The three Settings keys, alphabetical, as they sit between
    /// `settings.cloudCascade.toggleNote` and `settings.diagnostics.title`.
    private static let cloudChatSettingsKeys: [String] = [
        "settings.cloudChat.title",
        "settings.cloudChat.toggleLabel",
        "settings.cloudChat.toggleNote",
    ]

    /// The pinned inventory: design-l1 §17's family — 18 keys, the two
    /// blocks in file order. The design's optional
    /// `chat.cloudFallback.notice` is deliberately NOT here: §8.8 chooses
    /// "no user-visible error where a reply is expected", so the key would
    /// ship as dead copy (recorded in the unit notes).
    private static let cloudChatKeys: [String] =
        cloudChatChatBlockKeys + cloudChatSettingsKeys

    /// The safe-template keys alone — the bounded set the guard's check
    /// classes select from (the `L10n.SafeTemplate` enum is the enumerable
    /// form; the two are pinned to each other below).
    private static let cloudChatSafeTemplateKeys: [String] = [
        "chat.safeTemplate.danglingParticle",
        "chat.safeTemplate.devanagariPurity",
        "chat.safeTemplate.generic",
        "chat.safeTemplate.honorificAgreement",
    ]

    /// The catalog total minus this family's 18 keys. Re-measured at this
    /// unit's landing (2026-10-14): the tree carried 1,421 keys (the
    /// news-feed-images measurement, 1,402 + 19 dialogue keys) and this
    /// unit adds exactly its 18 — total 1,439 — so the baseline is 1,421.
    /// The +18 delta is the constant, not the absolute; a later landing on
    /// the same tree re-measures this pin deliberately rather than guessing.
    /// Re-measured at the home medium-fit dock labels (2026-10-15): two
    /// medium-mode dock keys land on the same tree — total 1,441; and at
    /// the T-012 medication localisation landing (2026-10-15): the 42-key
    /// medication family (design-l2 C13) lands on this W0 tree — total
    /// 1,483 — so this baseline is 1,465.
    private static let cloudChatBaselineKeyCount = 1_465

    /// The design-l1 §17 copy as authored by this unit, verbatim, both
    /// languages. T-176 owns the final disclosure-copy review; this pin
    /// makes every wording change — including an "improvement" — a
    /// deliberate one rather than a drift.
    private static let cloudChatCopy: [(key: String, en: String, ne: String)] = [
        ("chat.safeTemplate.danglingParticle",
         en: "I enjoy listening to you. Tell me that again, please.",
         ne: "सुन्दा रमाइलो लाग्छ हजुर। फेरि भन्नुहोस् न।"),
        ("chat.safeTemplate.devanagariPurity",
         en: "Say that once more — I'm listening carefully.",
         ne: "फेरि एक चोटि सुनाउनुहोस् न हजुर। म ध्यान दिएर सुन्छु।"),
        ("chat.safeTemplate.generic",
         en: "Tell me that again, please.",
         ne: "हजुर, त्यो कुरा फेरि भन्नुहोस् न।"),
        ("chat.safeTemplate.honorificAgreement",
         en: "My words came out muddled. Tell me that again, please.",
         ne: "मेरो कुरा अलि अलमल भयो। फेरि भन्नुहोस् न हजुर।"),
        ("cloud.chat.consent.allow",
         en: "Yes, use the internet",
         ne: "हो, इन्टरनेट प्रयोग गर्नुहोस्"),
        ("cloud.chat.consent.body",
         en: "What you say to me is sent to the internet. The answer comes from there. Everything else stays on this phone. It's fine to say no. Even if you say no, I keep answering on this phone.",
         ne: "हजुरले मसँग भन्नुभएको कुरा इन्टरनेटमा पठाइन्छ। जवाफ त्यही इन्टरनेटबाट आउँछ। बाँकी सबै कुरा यही फोनमै रहन्छ। होइन भन्नुभए पनि हुन्छ। त्यसो भन्नुभए पनि म यही फोनमै जवाफ दिइरहन्छु।"),
        ("cloud.chat.consent.notNow",
         en: "No, keep it on this phone",
         ne: "होइन, यही फोनमै राख्नुहोस्"),
        ("cloud.chat.consent.title",
         en: "Get answers from the internet?",
         ne: "कुराको जवाफ इन्टरनेटबाट ल्याउने?"),
        ("cloud.chat.indicator",
         en: "Answering online",
         ne: "अनलाइन जवाफ आउँदैछ"),
        ("cloud.chat.indicatorSpoken",
         en: "This answer is coming from the internet.",
         ne: "हजुर, यो जवाफ इन्टरनेटबाट आउँदैछ।"),
        ("cloud.chat.revoke.body",
         en: "Answers come from this phone again. Chat keeps working just as before. Nothing is lost.",
         ne: "जवाफ फेरि यही फोनबाट आउँछ। कुराकानी पहिलेजस्तै चलिरहन्छ। केही गुम्दैन।"),
        ("cloud.chat.revoke.done",
         en: "Done — answers come from this phone now.",
         ne: "भयो हजुर — जवाफ अब यही फोनबाट आउँछ।"),
        ("cloud.chat.revoke.title",
         en: "Turn off answers from the internet?",
         ne: "इन्टरनेटबाट जवाफ ल्याउन बन्द गर्ने?"),
        ("cloud.chat.state.spoken.off",
         en: "No — answers come from this phone right now.",
         ne: "होइन हजुर — अहिले जवाफ यही फोनबाट आउँछ।"),
        ("cloud.chat.state.spoken.on",
         en: "Yes — answers are coming from the internet right now.",
         ne: "हो हजुर — अहिले जवाफ इन्टरनेटबाट आउँदैछ।"),
        ("settings.cloudChat.title",
         en: "Answers from the internet",
         ne: "इन्टरनेटबाट आउने जवाफ"),
        ("settings.cloudChat.toggleLabel",
         en: "Get answers from the internet",
         ne: "इन्टरनेटबाट जवाफ ल्याउने"),
        ("settings.cloudChat.toggleNote",
         en: "When this is on, the answers to our talks come from the internet. When it is off, answers come from this phone. Chat keeps working just as before.",
         ne: "खुला हुँदा कुराको जवाफ इन्टरनेटबाट आउँछ। बन्द हुँदा जवाफ यही फोनबाट आउँछ, र कुराकानी पहिलेजस्तै चलिरहन्छ।"),
    ]

    /// T-166's style spec `ai_isms` substring classes (the seed file
    /// `tools/train-intent/seeds/nepali-chat-style-spec`, read at authoring
    /// time; mirrored here as the copy gate — the runtime guard is T-169's)
    /// plus this unit's apology bar ("sorry, I am an AI" boilerplate is
    /// banned by the task's register rule). A value carrying any of these
    /// is a defect, not a style choice.
    private static let cloudChatBannedBoilerplate: [String] = [
        "म एक AI हुँ", "म एउटा AI हुँ", "म कृत्रिम बुद्धिमत्ता हुँ",
        "As an AI", "I am an AI", "I'm an AI", "AI language model",
        "कृपया नम्र निवेदन", "तपाईंको अनुरोध स्वीकार गरियो",
        "Your request has been processed",
        "यो प्रश्नको उत्तर", "यस प्रश्नको जवाफ", "यो जानकारीको आधारमा",
        "I hope this helps", "आशा छ यसले सहयोग गर्छ",
        "यदि तपाईंलाई अरू केही चाहिए भने मलाई भन्नुहोस्", "If you need anything else",
        "sorry", "apolog", "क्षमा", "माफ",
    ]

    /// The register block's banned forms (T-166's style spec): the familiar
    /// address forms and the curated familiar finite verb forms. They are
    /// checked against Nepali values only (the Nepali values carry no ASCII,
    /// so a Latin-script name can never false-positive them).
    private static let cloudChatForbiddenFamiliarForms: [String] = [
        "तँ", "तलाई", "तँलाई", "तेरो", "तेरी", "तिमी", "तिमीलाई",
        "तिम्रो", "तिम्री", "तिम्रा", "तिमीहरू",
    ]
    private static let cloudChatNonHonorificVerbForms: [String] = [
        "भन्यो", "गर्यो", "खायो", "पियो", "हेर्यो", "लियो", "दियो",
        "आयो", "गयो", "सुत्यो", "सक्यो",
    ]

    /// The plainness bar (the task's register rule over design-l1
    /// §17/§8.4): consent, disclosure, indicator, revocation, state and
    /// Settings copy names what happens — never a provider, a model, a
    /// route, a server or a setting-category term, in either language. The
    /// Nepali list additionally bans the shipped legacy nouns this copy
    /// deliberately does not reuse (`क्लाउड` in the pre-existing
    /// `settings.cloudCascade.toggleNote` is that other feature's key, not
    /// this family's).
    private static let cloudChatForbiddenEnglishTerms: [String] = [
        "cloud", "server", "gemini", "model", "api",
    ]
    private static let cloudChatForbiddenNepaliTerms: [String] = [
        "क्लाउड", "सर्भर", "जेमिनी", "मोडेल", "दिमाग", "इन्जिन",
        "एपीआई", "राउटर",
    ]

    /// The sentence-shape caps (T-166's style spec `sentence_shape` and the
    /// family's own bar): safe templates run at most TWO short sentences —
    /// the spec's `max_sentences` — and every other key stays at most five,
    /// so the disclosure cannot grow into a wall of text. The character
    /// caps are the authored bar, set above the measured maxima
    /// (2026-10-14, in code points — Swift's grapheme count is at or below
    /// these on Devanagari: template sentences en 44 / ne 32, the family's
    /// sentences en 64 / ne 63), so a growing paragraph fails while
    /// ordinary wording edits do not.
    private static let cloudChatMaxTemplateSentences = 2
    private static let cloudChatMaxPlainSentences = 5
    private static let cloudChatMaxTemplateSentenceCharacters = (en: 70, ne: 65)
    private static let cloudChatMaxPlainSentenceCharacters = (en: 80, ne: 70)

    /// Scenario: Every new key resolves in both languages — the behavioural
    /// half. Every key resolves through the shipped lproj bundles in both
    /// languages; the Nepali resolution is Devanagari copy and the two
    /// values differ, so a forgotten half or an English copy pasted into
    /// the `ne` slot fails here.
    func testEveryCloudChatKeyResolvesInBothLanguages() {
        for key in Self.cloudChatKeys {
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
            XCTAssertTrue(Self.isDevanagariOrPlaceholderOnly(ne),
                          "\(key) resolves to non-Devanagari Nepali copy: \(ne)")
        }
    }

    /// Scenario: Every new key resolves in both languages — the source
    /// half. The catalog total is pinned to the freshly measured pre-unit
    /// count plus exactly the 18 insertions; the coverage check runs its
    /// rules over the parsed catalog; and the four neighbours of the two
    /// insertion points are pinned so a clobbering edit cannot pass.
    func testTheCloudChatFamilyPassesTheCoverageCheck() {
        let catalog = sourceCatalog()

        XCTAssertEqual(catalog.count,
                       Self.cloudChatBaselineKeyCount + Self.cloudChatKeys.count,
                       "the feature adds exactly \(Self.cloudChatKeys.count) keys "
                       + "and removes none (baseline \(Self.cloudChatBaselineKeyCount), "
                       + "measured on this tree)")

        let failures = Self.cloudChatCoverageFailures(in: catalog)
        XCTAssertTrue(failures.isEmpty,
                      "the cloud-chat coverage check failed:\n"
                      + failures.joined(separator: "\n"))

        // The immediate alphabetical neighbours of the two insertion
        // points: if a textual insertion had clobbered an entry, one of
        // these would change. (The blocks' own contiguity is pinned by the
        // raw-line span check below.)
        // The neighbours keep their verbatim pins: a clobbering
        // alphabetical insertion would change one of them.
        assertCatalogValue("caregiverNotify.shareHint",
                           en: "Family members can also be invited to see these events on their own calendar. These switches choose who is invited — but an emergency contact is always invited. Set up in Calendar sharing.",
                           ne: "परिवारका सदस्यहरूलाई यी कार्यक्रम आफ्नै क्यालेन्डरमा देख्न पनि निम्ता दिन सकिन्छ। कसलाई निम्ता जान्छ यी स्विचले तय गर्छन् — तर आपतकालीन सम्पर्कलाई सधैँ निम्ता जान्छ। यो क्यालेन्डर साझा भन्ने ठाउँमा मिलाइन्छ।")
        assertCatalogValue("cloudCascade.holdCue",
                           en: "One moment — this is taking a little longer…",
                           ne: "एक छिन — अलि बढी समय लाग्दैछ…")
        assertCatalogValue("settings.cloudCascade.toggleNote",
                           en: "On, an answer the large local brain gives below the confidence shown below goes to the configured cloud provider — after the spoken hold cue; off, the local answer stands. Inert while no cloud provider is configured.",
                           ne: "खुला हुँदा, तल देखाइएको विश्वासभन्दा कम भएको स्थानीय जवाफ क्लाउडमा जान्छ — पहिले 'एक छिन' भनिन्छ; बन्द हुँदा स्थानीय जवाफ नै रहन्छ। क्लाउड मिलाइएको नभए यसले केही गर्दैन।")
        assertCatalogValue("settings.diagnostics.title",
                           en: "Diagnostics",
                           ne: "निदान")
    }

    /// DoD evidence: every value is the copy this unit authored, verbatim,
    /// in both languages — a dropped translation or an English copy pasted
    /// into the `ne` slot fails here. T-176's disclosure review changes
    /// these deliberately (the pin is updated in the same commit).
    func testTheCloudChatCopyIsPinnedVerbatim() {
        XCTAssertEqual(Self.cloudChatCopy.map { $0.key }, Self.cloudChatKeys,
                       "the copy table and the pinned inventory must agree")
        for (key, expectedEN, expectedNE) in Self.cloudChatCopy {
            assertCatalogValue(key, en: expectedEN, ne: expectedNE)
        }
    }

    /// Scenario: A missing translation (the failure path). Each fixture is
    /// a copy of the parsed catalog mutated in one way; the coverage check
    /// must fail NAMING the offending key — and, for a one-language value,
    /// the missing language too. An English copy pasted into the `ne` slot
    /// fails as well (the two values must differ), and a slot added to one
    /// language only is a defect (the family's format-slot contract).
    func testTheCloudChatCoverageCheckFailsNamingTheMissingValue() {
        // Fixture 1: the ne value removed — the scenario's exact case (a
        // key added with only one language fails naming the key AND the
        // missing language).
        var missingNE = sourceCatalog()
        Self.removeCloudChatLanguage("ne", from: "cloud.chat.consent.body",
                                     in: &missingNE)
        assertCloudChatCoverageFails(missingNE, naming: "cloud.chat.consent.body",
                                     language: "ne")

        // Fixture 2: the en value removed.
        var missingEN = sourceCatalog()
        Self.removeCloudChatLanguage("en", from: "chat.safeTemplate.generic",
                                     in: &missingEN)
        assertCloudChatCoverageFails(missingEN, naming: "chat.safeTemplate.generic",
                                     language: "en")

        // Fixture 3: the whole entry removed.
        var missingEntry = sourceCatalog()
        missingEntry.removeValue(forKey: "cloud.chat.indicator")
        assertCloudChatCoverageFails(missingEntry, naming: "cloud.chat.indicator")

        // Fixture 4: a blank Nepali value.
        var blankNE = sourceCatalog()
        Self.setCloudChatValue("   ", language: "ne",
                               key: "cloud.chat.revoke.title", in: &blankNE)
        assertCloudChatCoverageFails(blankNE, naming: "cloud.chat.revoke.title",
                                     language: "ne")

        // Fixture 5: the English value copied into the Nepali slot.
        var untranslatedNE = sourceCatalog()
        Self.setCloudChatValue("Turn off answers from the internet?", language: "ne",
                               key: "cloud.chat.revoke.title", in: &untranslatedNE)
        assertCloudChatCoverageFails(untranslatedNE, naming: "cloud.chat.revoke.title")

        // Fixture 6: a `%@` added to ONE language only — the parity rule
        // the family's zero-slot contract enforces.
        var slotDrift = sourceCatalog()
        Self.setCloudChatValue("पर्दैन %@", language: "ne",
                               key: "cloud.chat.consent.notNow", in: &slotDrift)
        assertCloudChatCoverageFails(slotDrift, naming: "cloud.chat.consent.notNow",
                                     language: "ne")

        // Fixtures 7-9: a stray key in each owned namespace.
        for stray in ["chat.safeTemplate.stray", "cloud.chat.stray",
                      "settings.cloudChat.stray"] {
            var fixture = sourceCatalog()
            fixture[stray] = Self.sampleEntry(en: "Stray", ne: "थप")
            assertCloudChatCoverageFails(fixture, naming: stray)
        }

        // Fixture 10: the count pin's delta semantics — any extra key
        // breaks the baseline arithmetic until it is deliberately
        // re-measured.
        var drifted = sourceCatalog()
        drifted["t171.driftProbe"] = Self.sampleEntry(en: "Drift", ne: "थप")
        XCTAssertNotEqual(drifted.count,
                          Self.cloudChatBaselineKeyCount + Self.cloudChatKeys.count,
                          "any added key must break the count pin")
    }

    /// The parameter contract: no key in this family takes a format
    /// argument in either language (T-174's selection and T-176/T-177's
    /// surfaces compose none), so each value carries ZERO `%` placeholders
    /// — and a slot present in one language only can never ship, because
    /// the zero-slot rule and the parity rule are the same assertion here.
    func testTheCloudChatPlaceholderContractIsZeroSlotsInBothLanguages() {
        for key in Self.cloudChatKeys {
            for language in ["en", "ne"] {
                guard let value = catalogValue(key, language: language) else {
                    XCTFail("\(key).\(language) is missing from the catalog")
                    continue
                }
                XCTAssertEqual(Self.placeholderCount(in: value), 0,
                               "\(key): \(language) must carry no `%` placeholder "
                               + "— no key in this family takes an argument: \(value)")
            }
        }
    }

    /// Scenario: Safe templates are a bounded, spec-authored set — the
    /// closed-set half. The set is the guard's three check classes plus the
    /// generic entry: four keys, no more. The `L10n.SafeTemplate` enum is
    /// the enumerable form, its cases are exactly the pinned keys, the
    /// selection is deterministic (the first KNOWN class wins; an unknown
    /// name is dropped, never echoed into a key), and the catalog carries
    /// no fifth `chat.safeTemplate.*` entry.
    func testTheSafeTemplateSetIsBoundedAndEnumerable() {
        XCTAssertEqual(L10n.SafeTemplate.allCases.map(\.catalogKey).sorted(),
                       Self.cloudChatSafeTemplateKeys,
                       "the enum's cases and the pinned inventory must agree — "
                       + "the set is enumerable, not free-form text at runtime")
        XCTAssertEqual(L10n.SafeTemplate.allCases.count, 4,
                       "the set is a handful: the guard's three check classes "
                       + "plus the generic entry")

        // The deterministic selection keyed by the guard's check classes.
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: []), .generic)
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["notAClass"]), .generic,
                       "an unknown class must never become a key — it resolves "
                       + "to the generic template")
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["honorificAgreement"]),
                       .honorificAgreement)
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["devanagariPurity"]),
                       .devanagariPurity)
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["danglingParticle"]),
                       .danglingParticle)
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["mystery",
                                                           "devanagariPurity"]),
                       .devanagariPurity,
                       "the first KNOWN class wins, in the guard's own order")
        XCTAssertEqual(L10n.safeTemplate(forCheckClasses: ["danglingParticle",
                                                           "honorificAgreement"]),
                       .danglingParticle)

        // Each case resolves in both languages through the helper, to the
        // pinned values — a helper wired to the wrong key would pass an
        // existence check but fail this one.
        for template in L10n.SafeTemplate.allCases {
            let key = template.catalogKey
            XCTAssertNotNil(Self.cloudChatCopy.first { $0.key == key },
                            "\(key): every case must be pinned in the copy table")
            XCTAssertEqual(L10n.safeTemplate(template, locale: english),
                           catalogValue(key, language: "en") ?? "",
                           "\(key): the helper and the catalog must agree in en")
            XCTAssertEqual(L10n.safeTemplate(template, locale: nepali),
                           catalogValue(key, language: "ne") ?? "",
                           "\(key): the helper and the catalog must agree in ne")
        }

        // No fifth template key may sit in the catalog.
        let catalog = sourceCatalog()
        let templateKeys = catalog.keys
            .filter { $0.hasPrefix("chat.safeTemplate.") }
            .sorted()
        XCTAssertEqual(templateKeys, Self.cloudChatSafeTemplateKeys,
                       "the catalog must carry exactly the pinned templates")
    }

    /// Scenario: Safe templates are a bounded, spec-authored set — the
    /// register half. Each template (and, for the shared bar, every key in
    /// the family) is compared with T-166's style-spec register: a short,
    /// warm sentence from the register — the polite forms only, at most
    /// two sentences for a template, no list or markdown, no emoji, no
    /// apology boilerplate and no "I am an AI" line.
    func testTheCloudChatCopyMeetsTheRegisterBar() {
        let catalog = sourceCatalog()
        var values: [String: [String: String]] = [:]
        for key in Self.cloudChatKeys {
            guard let entry = catalog[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                XCTFail("\(key) is missing from the catalog")
                continue
            }
            var pair: [String: String] = [:]
            for language in ["en", "ne"] {
                guard let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                        as? [String: Any],
                      let value = unit["value"] as? String else {
                    XCTFail("\(key).\(language) is missing from the catalog")
                    continue
                }
                pair[language] = value
            }
            values[key] = pair
            let failures = Self.cloudChatRegisterFailures(key: key, values: pair)
            XCTAssertTrue(failures.isEmpty,
                          "the register check failed:\n"
                          + failures.joined(separator: "\n"))
        }

        // The templates carry the register's warmth marker explicitly.
        for key in Self.cloudChatSafeTemplateKeys {
            XCTAssertEqual(values[key]?.count, 2,
                           "\(key): the template copy must be readable from "
                           + "the source catalog in both languages")
            XCTAssertTrue(values[key]?["ne"]?.contains("हजुर") == true,
                          "\(key): the template must address the elder with "
                          + "the polite attention marker हजुर")
        }

        // The check is not a rubber stamp: apology boilerplate, a list, an
        // emoji AND a familiar-register form each fail, so the assertions
        // above mean something.
        let offences: [(marker: String, en: String, ne: String)] = [
            ("apology boilerplate",
             "Sorry, I am an AI and cannot answer.",
             "क्षमा गर्नुहोस्, म जवाफ दिन सक्दिन।"),
            ("a list",
             "Here is the answer:",
             "जवाफ यहाँ छ:\n1. हुन्छ हजुर"),
            ("an emoji",
             "Tell me again 🙂",
             "फेरि भन्नुहोस् न हजुर 🙂"),
            ("a familiar form",
             "Tell me that again.",
             "फेरि तिमी भन।"),
        ]
        for offence in offences {
            let failures = Self.cloudChatRegisterFailures(
                key: "chat.safeTemplate.generic",
                values: ["en": offence.en, "ne": offence.ne])
            XCTAssertFalse(failures.isEmpty,
                           "the register check must fail the \(offence.marker) case")
        }
    }

    /// The mirror rule (FR-CNR-001 / NFR-CNR-005): the register bar's lists
    /// are MIRRORS of T-166's style spec, not a second source. The suite
    /// reads the seed's machine blocks and fails when the spec grows a ban
    /// this file does not carry. The mirror may be a SUPERSET — this unit's
    /// apology bar is deliberately wider than the spec's list — but never a
    /// subset: a rule changes in the spec first.
    func testTheRegisterMirrorCoversTheStyleSpecsBans() throws {
        guard let aiIsms = try Self.styleSpecBlock("ai_isms"),
              let forbidden = aiIsms["forbidden"] as? [[String: Any]] else {
            return XCTFail("the style spec carries no readable ai_isms block")
        }
        let specSubstrings = forbidden.compactMap { entry -> [String]? in
            entry["kind"] as? String == "substring" ? entry["patterns"] as? [String] : nil
        }.flatMap { $0 }
        XCTAssertFalse(specSubstrings.isEmpty,
                       "the ai_isms block's substring bans must be readable")
        for pattern in specSubstrings {
            XCTAssertTrue(Self.cloudChatBannedBoilerplate.contains {
                $0.lowercased() == pattern.lowercased()
            }, "the spec bans \"\(pattern)\" and the register mirror does not "
               + "carry it — mirror the spec, never the other way around")
        }

        guard let register = try Self.styleSpecBlock("register"),
              let addressForms = register["forbidden_address_forms"] as? [String],
              let familiarVerbs = register["non_honorific_verb_forms"] as? [String] else {
            return XCTFail("the style spec carries no readable register block")
        }
        XCTAssertFalse(addressForms.isEmpty || familiarVerbs.isEmpty,
                       "the register block's lexicons must be readable")
        for form in addressForms {
            XCTAssertTrue(Self.cloudChatForbiddenFamiliarForms.contains(form),
                          "the spec bans the address form \"\(form)\" and the "
                          + "mirror does not carry it")
        }
        for form in familiarVerbs {
            XCTAssertTrue(Self.cloudChatNonHonorificVerbForms.contains(form),
                          "the spec bans the verb form \"\(form)\" and the "
                          + "mirror does not carry it")
        }

        guard let shape = try Self.styleSpecBlock("sentence_shape"),
              let maxSentences = shape["max_sentences"] as? Int else {
            return XCTFail("the style spec carries no readable sentence_shape block")
        }
        XCTAssertEqual(maxSentences, Self.cloudChatMaxTemplateSentences,
                       "the template cap IS the spec's max_sentences — the "
                       + "style contract's own number, not a local constant")
    }

    /// Scenario: The copy speaks to a person. No consent, disclosure,
    /// indicator, revocation, state or Settings string names a model, a
    /// provider, a route, a server or a setting-category term — in either
    /// language (design-l1 §17/§8.4; the task's register bar). The term
    /// lists themselves are pinned so they cannot be quietly emptied.
    func testTheCloudChatCopyNamesNoInternals() {
        XCTAssertEqual(Set(Self.cloudChatForbiddenEnglishTerms),
                       ["cloud", "server", "gemini", "model", "api"],
                       "the English term ban must be the pinned list")
        XCTAssertEqual(Set(Self.cloudChatForbiddenNepaliTerms),
                       ["क्लाउड", "सर्भर", "जेमिनी", "मोडेल", "दिमाग",
                        "इन्जिन", "एपीआई", "राउटर"],
                       "the Nepali term ban must be the pinned list")

        for key in Self.cloudChatKeys {
            for language in ["en", "ne"] {
                guard let value = catalogValue(key, language: language) else {
                    XCTFail("\(key).\(language) is missing from the catalog")
                    continue
                }
                XCTAssertNil(Self.cloudChatForbiddenTerm(in: value, language: language),
                             "\(key): \(language) copy names an internal — the "
                             + "copy must speak to a person: \(value)")
            }
        }

        // The ban is enforced, not decorative: a fixture that names the
        // term fails the coverage check by key and language.
        var fixture = sourceCatalog()
        Self.setCloudChatValue("तपाईंको कुरा क्लाउडमा पठाइन्छ।", language: "ne",
                               key: "cloud.chat.consent.body", in: &fixture)
        assertCloudChatCoverageFails(fixture, naming: "cloud.chat.consent.body",
                                     language: "ne")
    }

    /// Implementation note: the entries were inserted at their alphabetical
    /// positions as two contiguous blocks — the 15 `chat.*`/`cloud.chat.*`
    /// keys between `caregiverNotify.shareHint` and `cloudCascade.holdCue`,
    /// the 3 settings keys between `settings.cloudCascade.toggleNote` and
    /// `settings.diagnostics.title`. JSONSerialization loses key order, so
    /// this pin reads the raw file.
    func testTheCloudChatBlocksSitAlphabeticallyAndContiguouslyInTheFile() {
        let keyLines = rawCatalogKeyLines()
        XCTAssertGreaterThan(keyLines.count, 1_000,
                             "the key-line scan found too few entries — the "
                             + "catalog layout changed and this pin is blind")
        let failures = Self.cloudChatSpanFailures(in: keyLines)
        XCTAssertTrue(failures.isEmpty,
                      "the cloud-chat span check failed:\n"
                      + failures.joined(separator: "\n"))
    }

    /// The span rule enforced by the check itself: a moved key, a smuggled
    /// key and a reordered block each fail naming the offender, so the
    /// passing assertion above is not vacuous.
    func testTheCloudChatSpanCheckFailsOnAMovedOrSmuggledKey() {
        let real = rawCatalogKeyLines()
        XCTAssertTrue(Self.cloudChatSpanFailures(in: real).isEmpty,
                      "the fixture must start from a passing scan")

        var moved = real
        if let index = moved.firstIndex(of: "cloud.chat.indicator") {
            moved.remove(at: index)
            moved.append("cloud.chat.indicator")
        }
        XCTAssertTrue(Self.cloudChatSpanFailures(in: moved)
                        .contains { $0.contains("cloud.chat.indicator") },
                      "a key moved out of the span must fail naming it")

        var smuggled = real
        if let index = smuggled.firstIndex(of: "cloud.chat.consent.title") {
            smuggled.insert("cloud.chat.stray", at: index)
        }
        XCTAssertTrue(Self.cloudChatSpanFailures(in: smuggled)
                        .contains { $0.contains("cloud.chat.stray") },
                      "an unpinned key inside the span must fail naming it")

        var swapped = real
        if let index = swapped.firstIndex(of: "settings.cloudChat.title"),
           index + 1 < swapped.count {
            swapped.swapAt(index, index + 1)
        }
        XCTAssertTrue(Self.cloudChatSpanFailures(in: swapped)
                        .contains { $0.contains("settings.cloudChat.title") },
                      "a reordered settings block must fail naming the key")
    }

    /// Scenario: A hardcoded user-visible string (the failure path). The
    /// sweep inspects the feature's surfaces — the `CloudChat` sources and
    /// the five files the feature's plan wires into — with every family
    /// value in hand, and reports each finding with its file, line and
    /// text; the fix is a catalogue key in both languages, never a string
    /// left in code.
    func testNoCloudChatCopyIsHardcodedOnTheFeatureSurfaces() {
        let values = Self.cloudChatKeys.compactMap { catalogValue($0, language: "en") }
            + Self.cloudChatKeys.compactMap { catalogValue($0, language: "ne") }
        XCTAssertEqual(values.count, Self.cloudChatKeys.count * 2,
                       "every family value must resolve before the sweep can "
                       + "claim anything")

        var findings: [String] = []
        for (relative, devanagariScan) in Self.cloudChatSweepFiles() {
            let url = FeatureSourceScan.iosDirectory()
                .appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("the swept surface \(relative) is missing — the sweep "
                        + "must not claim anything about files it cannot read")
                continue
            }
            findings += Self.hardcodedCopyFindings(
                path: relative,
                codeText: FeatureSourceScan.codeText(of: url),
                devanagariScan: devanagariScan,
                catalogValues: values)
        }
        XCTAssertTrue(findings.isEmpty,
                      "user-visible copy must live in the catalogue (both "
                      + "languages), not in code:\n"
                      + findings.joined(separator: "\n"))
    }

    /// The sweep's own failure path: a sample source carrying Nepali copy
    /// and a duplicated catalogue value is reported with its file, line and
    /// text; an internal ASCII literal is not.
    func testTheHardcodedCopySweepReportsTheStringAndItsLocation() {
        let sample = [
            "func speak() {",
            "    say(\"Yes, use the internet\")",
            "    say(\"ठीक छ हजुर\")",
            "    say(\"OK\")",
            "}",
        ].joined(separator: "\n")
        let findings = Self.hardcodedCopyFindings(
            path: "ElderlyAssistant/Services/Intents/CloudChat/Sample.swift",
            codeText: sample,
            devanagariScan: true,
            catalogValues: ["Yes, use the internet"])
        XCTAssertEqual(findings.count, 2,
                       "one finding per offending line: \(findings)")
        XCTAssertTrue(findings.contains {
            $0.contains("Sample.swift:2") && $0.contains("Yes, use the internet")
        }, "the hardcoded catalogue value must be reported with its file, "
           + "line and text: \(findings)")
        XCTAssertTrue(findings.contains {
            $0.contains("Sample.swift:3") && $0.contains("ठीक छ हजुर")
        }, "the hardcoded Nepali copy must be reported with its file, line "
           + "and text: \(findings)")
        XCTAssertFalse(findings.contains { $0.contains("Sample.swift:4") },
                       "an internal ASCII literal must not be flagged: \(findings)")
    }

    // MARK: T-171 helpers

    /// The cloud-chat coverage check as a pure function over a parsed
    /// catalog, so every rule can be exercised against fixtures. Each
    /// failure names the offending key and the rule it broke; a missing or
    /// lost value names the language too (the "one language only"
    /// scenario's exact message shape). The family is membership in the
    /// three namespaces this unit owns — a key shaped like a family key but
    /// outside the pinned inventory is a nineteenth user-visible string.
    static func cloudChatCoverageFailures(in catalog: [String: Any]) -> [String] {
        var failures: [String] = []
        let inventory = Set(cloudChatKeys)
        let familyPrefixes = ["chat.safeTemplate.", "cloud.chat.",
                              "settings.cloudChat."]

        for key in catalog.keys.sorted() where familyPrefixes.contains(where: {
            key.hasPrefix($0)
        }) && !inventory.contains(key) {
            failures.append("\(key): in the cloud-chat family but not in the "
                            + "pinned inventory (exactly \(cloudChatKeys.count) "
                            + "keys)")
        }
        for key in cloudChatKeys {
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
                guard let unit = ((localizations[language] as? [String: Any])?["stringUnit"]
                                    as? [String: Any]),
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
                    if containsASCIILetters(value) {
                        failures.append("\(key): Nepali value carries ASCII "
                                        + "letters — \(value)")
                    }
                    if !isDevanagariOrPlaceholderOnly(value) {
                        failures.append("\(key): Nepali value is not Devanagari "
                                        + "— \(value)")
                    }
                }
                if let term = cloudChatForbiddenTerm(in: value, language: language) {
                    failures.append("\(key): \(language) copy names the technical "
                                    + "term \"\(term)\" — the copy must speak to "
                                    + "a person: \(value)")
                }
                let placeholders = placeholderCount(in: value)
                if placeholders != 0 {
                    failures.append("\(key): \(language) carries \(placeholders) "
                                    + "`%` placeholder(s) — no key in this family "
                                    + "takes an argument")
                }
            }
            failures += cloudChatRegisterFailures(key: key, values: values)
            if let en = values["en"], let ne = values["ne"], en == ne {
                failures.append("\(key): en and ne resolve to the same value — "
                                + "the Nepali copy is missing")
            }
        }
        return failures
    }

    /// The register bar as a pure function (T-166's style spec register and
    /// `ai_isms` sections, plus this unit's apology rule), so every clause
    /// can be exercised against fixtures. Applies to both languages; the
    /// register-lexicon clauses apply to the Nepali value.
    static func cloudChatRegisterFailures(key: String,
                                          values: [String: String]) -> [String] {
        var failures: [String] = []
        let isTemplate = key.hasPrefix("chat.safeTemplate.")
        for (language, value) in values.sorted(by: { $0.key < $1.key }) {
            if containsEmoji(value) {
                failures.append("\(key): \(language) copy carries an emoji — "
                                + "spoken copy is prose: \(value)")
            }
            if carriesListOrMarkdownMarker(value) {
                failures.append("\(key): \(language) copy carries a list, "
                                + "numbering, bullet or markdown marker: \(value)")
            }
            let lowered = value.lowercased()
            for banned in cloudChatBannedBoilerplate
            where lowered.contains(banned.lowercased()) {
                failures.append("\(key): \(language) copy carries banned "
                                + "boilerplate \"\(banned)\": \(value)")
            }
            if stacksAddressForms(value) {
                failures.append("\(key): \(language) copy piles the address "
                                + "forms up (हजुर/तपाईं twice within a short "
                                + "span): \(value)")
            }
            let sentenceLimit = isTemplate ? cloudChatMaxTemplateSentences
                                           : cloudChatMaxPlainSentences
            let sentences = cloudChatSentences(in: value, language: language)
            if sentences.count > sentenceLimit {
                failures.append("\(key): \(language) copy runs \(sentences.count) "
                                + "sentence(s) — the cap is \(sentenceLimit)")
            }
            let charCap = isTemplate
                ? (language == "ne" ? cloudChatMaxTemplateSentenceCharacters.ne
                                    : cloudChatMaxTemplateSentenceCharacters.en)
                : (language == "ne" ? cloudChatMaxPlainSentenceCharacters.ne
                                    : cloudChatMaxPlainSentenceCharacters.en)
            for sentence in sentences where sentence.count > charCap {
                failures.append("\(key): \(language) sentence runs "
                                + "\(sentence.count) characters — the cap is "
                                + "\(charCap) (short sentences, one idea each): "
                                + sentence)
            }
            guard language == "ne" else { continue }
            for form in cloudChatForbiddenFamiliarForms where value.contains(form) {
                failures.append("\(key): Nepali copy uses the familiar form "
                                + "\"\(form)\" — the elder is addressed with "
                                + "तपाईं/हजुर: \(value)")
            }
            for form in cloudChatNonHonorificVerbForms where value.contains(form) {
                failures.append("\(key): Nepali copy uses the familiar verb form "
                                + "\"\(form)\": \(value)")
            }
            if isTemplate && !value.contains("हजुर") {
                failures.append("\(key): the template must carry the polite "
                                + "attention marker हजुर: \(value)")
            }
        }
        return failures
    }

    /// The plainness rule: the first banned term the value carries, or nil.
    /// English terms match case-insensitively; the Nepali list is matched
    /// verbatim (Devanagari has no case).
    static func cloudChatForbiddenTerm(in value: String,
                                       language: String) -> String? {
        guard language == "ne" else {
            let lowered = value.lowercased()
            return cloudChatForbiddenEnglishTerms.first { lowered.contains($0) }
        }
        return cloudChatForbiddenNepaliTerms.first { value.contains($0) }
    }

    /// The exact-span placement check as a pure function over the raw
    /// file's key lines: the 15-key chat block must sit contiguously
    /// between its pinned neighbours, and the 3 settings keys between
    /// theirs. A moved, removed, smuggled or reordered key fails naming
    /// itself.
    static func cloudChatSpanFailures(in keyLines: [String]) -> [String] {
        var failures: [String] = []
        failures += cloudChatSpanFailures(in: keyLines,
                                          between: "caregiverNotify.shareHint",
                                          and: "cloudCascade.holdCue",
                                          expected: cloudChatChatBlockKeys)
        failures += cloudChatSpanFailures(in: keyLines,
                                          between: "settings.cloudCascade.toggleNote",
                                          and: "settings.diagnostics.title",
                                          expected: cloudChatSettingsKeys)
        return failures
    }

    private static func cloudChatSpanFailures(in keyLines: [String],
                                              between predecessor: String,
                                              and successor: String,
                                              expected: [String]) -> [String] {
        var failures: [String] = []
        guard let before = keyLines.firstIndex(of: predecessor) else {
            return ["\(predecessor): the span's predecessor is missing — the "
                    + "placement pin is blind"]
        }
        guard let after = keyLines.firstIndex(of: successor) else {
            return ["\(successor): the span's successor is missing — the "
                    + "placement pin is blind"]
        }
        if after <= before + 1 {
            return ["no cloud-chat span between \(predecessor) and \(successor)"]
        }
        let span = Array(keyLines[(before + 1)..<after])
        if span != expected {
            for key in expected where !span.contains(key) {
                failures.append("\(key): not inside the pinned span between "
                                + "\(predecessor) and \(successor) "
                                + "(moved or removed)")
            }
            for key in span where !expected.contains(key) {
                failures.append("\(key): inside the cloud-chat span but not in "
                                + "the pinned inventory — unpinned or wrongly "
                                + "placed")
            }
            if Set(span) == Set(expected) {
                for index in 0..<min(expected.count, span.count) {
                    if span[index] != expected[index] {
                        failures.append("\(expected[index]): out of pinned order "
                                        + "(found \(span[index]) at its position)")
                    }
                }
            }
            if span.count != expected.count {
                failures.append("the cloud-chat span between \(predecessor) and "
                                + "\(successor) has \(span.count) key lines — "
                                + "expected \(expected.count)")
            }
        }
        return failures
    }

    /// The hardcoded-copy sweep as a pure function over one file's
    /// comment-stripped code, reporting file, line and text. Two probes:
    /// (a) any Devanagari in the code is Nepali copy that must live in the
    /// catalogue; (b) any literal equal to a catalogue value is that copy
    /// duplicated in code. `devanagariScan` is false for files whose
    /// Devanagari is a spoken-INPUT lexicon or another feature's output
    /// copy, which only probe (b) may judge.
    static func hardcodedCopyFindings(path: String,
                                      codeText: String,
                                      devanagariScan: Bool,
                                      catalogValues: [String]) -> [String] {
        var findings: [String] = []
        let lines = codeText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for (offset, line) in lines.enumerated() {
            if devanagariScan && containsDevanagari(line) {
                findings.append("\(path):\(offset + 1): Nepali copy in code — "
                                + "add it to the catalogue in both languages: "
                                + line.trimmingCharacters(in: .whitespaces))
            }
            for value in catalogValues {
                if line.contains(value) {
                    findings.append("\(path):\(offset + 1): catalogue copy "
                                    + "hardcoded — resolve it via its key "
                                    + "instead: "
                                    + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return findings
    }

    /// The swept surfaces: the feature's own source directory (any
    /// Devanagari outside comments there can only be user-visible copy —
    /// the guard's lexicons live under `Services/Voice`, checked by their
    /// own suite) plus the five files this feature's plan wires the family
    /// into — T-176's sheet lives under `CloudChat`, the consent sheet's
    /// host and the indicator/revocation surfaces are the three `App/`
    /// files, the revoke/state keyword rules are `KeywordIntentRule`, and
    /// the safe template is spoken from `CommandRouter`'s chat dispatch
    /// (T-174) (pinned-copy probe only for the five: those files
    /// legitimately carry other features' Devanagari, e.g.
    /// `KeywordIntentRule`'s spoken stimuli).
    private static func cloudChatSweepFiles() -> [(relative: String, devanagari: Bool)] {
        var files: [(relative: String, devanagari: Bool)] = FeatureSourceScan
            .swiftFiles(in: "ElderlyAssistant/Services/Intents/CloudChat")
            .map { (FeatureSourceScan.relativePath(of: $0), true) }
        files += [
            ("ElderlyAssistant/App/AppCoordinator.swift", false),
            ("ElderlyAssistant/App/HomeSubviews.swift", false),
            ("ElderlyAssistant/App/SettingsView.swift", false),
            ("ElderlyAssistant/Services/Voice/CommandRouter.swift", false),
            ("ElderlyAssistant/Services/Voice/KeywordIntentRule.swift", false),
        ]
        return files.sorted { $0.relative < $1.relative }
    }

    /// One machine block of T-166's style spec (`tools/train-intent/seeds/
    /// nepali-chat-style-spec`), parsed from its fenced ` ```json <name> `
    /// form — the register mirror's authority, read from the artifact
    /// itself (the `ChatSamplingTests.specSection` pattern). A block that
    /// cannot be read is nil, and the calling test fails rather than
    /// passing blind.
    private static func styleSpecBlock(_ name: String) throws -> [String: Any]? {
        let seed = FeatureSourceScan.iosDirectory(file: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("tools/train-intent/seeds/nepali-chat-style-spec")
        let text = try String(contentsOf: seed, encoding: .utf8)
        guard let opener = text.range(of: "```json \(name)"),
              let closer = text.range(of: "```",
                                      range: opener.upperBound..<text.endIndex) else {
            return nil
        }
        let json = String(text[opener.upperBound..<closer.lowerBound])
        guard let data = json.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The sentences of a value, split on the language's terminators (the
    /// Devanagari danda for Nepali — the family's Nepali copy carries no
    /// ASCII period) and trimmed; the spoken prose has no other punctuation.
    private static func cloudChatSentences(in value: String,
                                           language: String) -> [String] {
        let terminators: Set<Character> = language == "ne"
            ? ["।", "?", "!"] : [".", "?", "!"]
        return value.split(whereSeparator: { terminators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Emoji — the U+1F000 block and the common symbol ranges a keyboard
    /// inserts — pinned as a bar: spoken copy is prose. The em dash and the
    /// ellipsis sit outside these ranges deliberately; they are
    /// punctuation, not pictographs.
    private static func containsEmoji(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x1F000...0x1FAFF).contains(scalar.value)
                || (0x2600...0x27BF).contains(scalar.value)
                || (0x2B00...0x2BFF).contains(scalar.value)
                || scalar.value == 0xFE0F
                || scalar.value == 0x200D
        }
    }

    /// The spec's "no lists, numbering, bullets or markdown" class: a
    /// list/numbering/bullet opener at the start of any line, or a markdown
    /// marker anywhere in the value.
    private static func carriesListOrMarkdownMarker(_ value: String) -> Bool {
        if value.contains("**") || value.contains("__") || value.contains("`") {
            return true
        }
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let first = trimmed.first, "-*•".contains(first),
               trimmed.dropFirst().first == " " {
                return true
            }
            let digits = trimmed.prefix(while: { $0.isNumber })
            if !digits.isEmpty,
               let after = trimmed.dropFirst(digits.count).first,
               after == "." || after == ")" {
                return true
            }
        }
        return false
    }

    /// The spec's over-politeness class, approximated on the value: an
    /// address marker (हजुर or तपाईं) twice within 12 characters.
    private static func stacksAddressForms(_ value: String) -> Bool {
        for marker in ["हजुर", "तपाईं"] {
            var search = value.startIndex..<value.endIndex
            var hits: [String.Index] = []
            while let found = value.range(of: marker, range: search) {
                hits.append(found.lowerBound)
                search = found.upperBound..<value.endIndex
            }
            for (first, second) in zip(hits, hits.dropFirst()) {
                if value.distance(from: first, to: second) <= 12 {
                    return true
                }
            }
        }
        return false
    }

    /// Asserts the cloud-chat check fails naming `key` — and, when given,
    /// that some failure for `key` also names the lost `language` (the
    /// one-language scenario's requirement), showing every failure the
    /// check produced.
    private func assertCloudChatCoverageFails(_ catalog: [String: Any],
                                              naming key: String,
                                              language: String? = nil,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) {
        let failures = Self.cloudChatCoverageFailures(in: catalog)
        XCTAssertTrue(failures.contains { $0.contains(key) },
                      "the coverage check must fail naming \(key); it produced: "
                      + "\(failures)", file: file, line: line)
        if let language {
            XCTAssertTrue(failures.contains {
                $0.contains(key) && $0.contains(language)
            }, "the failure for \(key) must also name the missing/lost language "
               + "\(language); it produced: \(failures)",
               file: file, line: line)
        }
    }

    /// Fixture-only: drops one language's localization from `key`.
    private static func removeCloudChatLanguage(_ language: String,
                                                from key: String,
                                                in catalog: inout [String: Any]) {
        guard var entry = catalog[key] as? [String: Any],
              var localizations = entry["localizations"] as? [String: Any] else {
            XCTFail("fixture setup: \(key) is missing from the catalog")
            return
        }
        localizations.removeValue(forKey: language)
        entry["localizations"] = localizations
        catalog[key] = entry
    }

    /// Fixture-only: overwrites one language's value for `key`.
    private static func setCloudChatValue(_ value: String, language: String,
                                          key: String,
                                          in catalog: inout [String: Any]) {
        guard var entry = catalog[key] as? [String: Any],
              var localizations = entry["localizations"] as? [String: Any],
              var languageEntry = localizations[language] as? [String: Any],
              var unit = languageEntry["stringUnit"] as? [String: Any] else {
            XCTFail("fixture setup: \(key).\(language) is missing from the catalog")
            return
        }
        unit["value"] = value
        languageEntry["stringUnit"] = unit
        localizations[language] = languageEntry
        entry["localizations"] = localizations
        catalog[key] = entry
    }

    // MARK: T-012 — the medication schedules family (design-l2 C13)

    /// The pinned inventory: design-l2 C13's key sets for the medication
    /// schedules feature — 42 new keys, the slot/meal/quantity labels, the
    /// Medicine-times mapping section, the editor controls, the walk's
    /// sanctioned clarification forms and its honest ended line, the
    /// evidence lines, the two new significant-event family alert bodies,
    /// and the three calendar significant-event phrases. The amended
    /// `calendarShare.consent.whoCanSee` is deliberately NOT here: it is a
    /// modified shipped key, not a new one, and its M-1 pin lives in
    /// `CalendarShareConsentCopyTests`.
    private static let medicationKeys: [String] = [
        // Slot / meal / quantity labels (C1, C2; design-l2 C13).
        "meds.slot.morning",
        "meds.slot.afternoon",
        "meds.slot.evening",
        "meds.meal.before",
        "meds.meal.after",
        "meds.quantity.amount",
        "meds.quantity.unit",
        "meds.quantity.customUnit",
        "meds.unit.tablet",
        "meds.unit.capsule",
        "meds.unit.milliliter",
        "meds.unit.teaspoon",
        "meds.unit.drop",
        "meds.unit.puff",
        "meds.unit.sachet",
        // The Medicine-times mapping section (C8; m-5's one-shot note).
        "settings.meds.times.title",
        "settings.meds.times.morning",
        "settings.meds.times.afternoon",
        "settings.meds.times.evening",
        "settings.meds.times.reset",
        "settings.meds.times.saveFailed",
        "settings.meds.times.unresolved",
        "settings.meds.times.retimeNote",
        "settings.meds.times.retimeNote.dismiss",
        // The editor's slot/quantity/meal controls (C8).
        "settings.meds.useSlotModel",
        "settings.meds.keepTimes",
        "settings.meds.slotRequired",
        "meds.addDose",
        // The walk: the sanctioned forms and the honest ended line (C4).
        "meds.ack.clarifyOne",
        "meds.ack.clarifyPair",
        "meds.ack.clarifyEnded",
        // Evidence (C5; the spoken line names the bound medication, D11).
        "meds.evidence.capture",
        "meds.evidence.spoken",
        "meds.evidence.attached",
        "meds.evidence.failed",
        "meds.evidence.notYetDelivered",
        "meds.takenToday.title",
        // The two new significant-event bodies and the calendar phrases
        // (C6, C10, C11).
        "family.alertIntakeRecorded",
        "family.alertEscalationStarted",
        "calendarShare.alert.missed",
        "calendarShare.alert.doubleDose",
        "calendarShare.alert.escalation",
    ]

    /// Scenario: A key resolves in ne and en, differently. Every new key
    /// resolves through the shipped lproj bundles in both languages, both
    /// resolutions exist (non-empty — `L10n.str` answers a total miss with
    /// ""), neither returns the key itself, and the two resolutions differ,
    /// so a key whose `ne` copy was forgotten or copy-pasted from `en`
    /// fails here rather than shipping a screen that reads English to a
    /// Nepali household. The Nepali resolution is Devanagari (or `%@`
    /// only), the catalog convention every family in this suite carries.
    func testMedicationFamiliesResolveInBothLanguages() {
        XCTAssertEqual(Self.medicationKeys.count, 42,
                       "the family is exactly the 42 keys design-l2 C13 adds "
                       + "(25 `meds.*` + 12 `settings.meds.*` + 2 `family.*` "
                       + "+ 3 `calendarShare.*`)")

        for key in Self.medicationKeys {
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
            XCTAssertTrue(Self.isDevanagariOrPlaceholderOnly(ne),
                          "\(key) resolves to non-Devanagari Nepali copy: \(ne)")
        }
    }

}
