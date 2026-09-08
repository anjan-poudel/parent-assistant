import XCTest
@testable import ElderlyAssistant

/// [ACCENT-ADAPT] Dialect-tagged decode biasing (doc
/// docs/research-sections/accent-adaptation.md §6 P0.3) composed on top of
/// the P0 slice-D dialect ID: plan states (active / disabled / default-label
/// fallback / no-material), prompt composition order and budgets, term
/// sanitation + dedupe, lexicon + table corruption honesty, token merge,
/// the two recognizer seams (WhisperKit token application, whisper.cpp
/// prompt C-string), settings persistence, and shipped-artifact honesty.
/// All pure/injected — no model runtime is loaded.
final class DialectBiasComposerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTable(promptTokenIds: [String: [Int]] = [:],
                           corrupt: Bool = false) -> DialectCentroidTable {
        DialectCentroidTable(
            formatVersion: corrupt ? 99 : 1,
            encoder: "whisperkit-ne-medium",
            embeddingDimension: 3,
            similarityMetric: "cosine",
            confidenceGate: 0.6,
            generation: DialectCentroidTable.Generation(status: "SEED-CENTROIDS",
                                                        path: "test",
                                                        date: nil),
            clusters: ["eastern", "doteli"].enumerated().map { index, id in
                var centroid = [Float](repeating: 0, count: 3)
                centroid[index] = 1
                return DialectCentroidTable.Cluster(
                    id: id,
                    centroid: centroid,
                    promptTokenIds: promptTokenIds[id] ?? [],
                    promptText: []
                )
            }
        )
    }

    private func makeLexicon(tagLines: [String: String] = [
        "eastern": "पूर्वेली नेपाली बोली",
        "doteli": "डोटेली भाषा, सुदूरपश्चिम नेपाल",
    ],
    phrases: [String: [String]] = [
        "eastern": ["गइछ", "भइछ"],
        "doteli": ["भया", "रह्याको"],
    ],
    corrupt: Bool = false) -> DialectLexicon {
        DialectLexicon(
            formatVersion: corrupt ? 9 : 1,
            generation: DialectLexicon.Generation(status: "SEED-LEXICON",
                                                  path: "test",
                                                  date: nil),
            entries: tagLines.map { dialect, tagLine in
                DialectLexicon.Entry(dialect: dialect,
                                     tagLine: tagLine,
                                     phrases: phrases[dialect] ?? [])
            }
        )
    }

    private func makeProfile(contacts: [String] = [],
                             medications: [String] = [],
                             apps: [String] = []) -> DialectBiasProfile {
        var profile = DialectBiasProfile()
        profile.contactNames = contacts
        profile.medicationNames = medications
        profile.appNames = apps
        return profile
    }

    private func isolateDefaults() -> UserDefaults {
        let suite = "dialect-bias-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Plan states

    func testDisabledReturnsDisabledByUserWithNoMaterial() {
        let plan = DialectBiasComposer.plan(label: .doteli,
                                            table: makeTable(),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(contacts: ["Sita"]),
                                            enabled: false)
        XCTAssertEqual(plan.state, .disabledByUser)
        XCTAssertNil(plan.promptText)
        XCTAssertTrue(plan.calibratedTokenIds.isEmpty)
        XCTAssertTrue(plan.hasNoMaterial)
    }

    func testDefaultLabelIsByteIdenticalUnadaptedPath() {
        // The classifier returns .default for unknown/low-confidence
        // dialect ID — the plan must carry NO material at all, so the
        // recognizers leave DecodingOptions/WhisperParams untouched.
        let plan = DialectBiasComposer.plan(label: .default,
                                            table: makeTable(),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(contacts: ["Sita"],
                                                                 medications: ["Metformin"]),
                                            enabled: true)
        XCTAssertEqual(plan.state, .defaultLabel)
        XCTAssertNil(plan.promptText)
        XCTAssertTrue(plan.calibratedTokenIds.isEmpty)
        XCTAssertEqual(plan.contactCount, 0)
        XCTAssertEqual(plan.medicationCount, 0)
    }

    func testActiveComposesDocumentedOrder() {
        // Doc P0.3 order: contact names, medication names, app names,
        // known dialect words, then the dialect tag line.
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: makeTable(),
            lexicon: makeLexicon(),
            profile: makeProfile(contacts: ["Sita", "Ram Bahadur"],
                                 medications: ["Metformin"],
                                 apps: ["WhatsApp"]),
            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertEqual(plan.label, .doteli)
        XCTAssertEqual(
            plan.promptText,
            "Sita Ram Bahadur Metformin WhatsApp भया रह्याको "
                + "डोटेली भाषा, सुदूरपश्चिम नेपाल")
        XCTAssertEqual(plan.lexiconPhraseCount, 2)
        XCTAssertEqual(plan.contactCount, 2)
        XCTAssertEqual(plan.medicationCount, 1)
        XCTAssertEqual(plan.appCount, 1)
    }

    func testNoMaterialWhenLabelSetButNothingTrustworthyToBias() {
        // Label set, but lexicon missing AND profile empty AND no
        // calibrated ids: honest no-op, not a guess.
        let plan = DialectBiasComposer.plan(label: .eastern,
                                            table: makeTable(),
                                            lexicon: nil,
                                            profile: makeProfile(),
                                            enabled: true)
        XCTAssertEqual(plan.state, .noMaterial)
        XCTAssertNil(plan.promptText)
    }

    // MARK: - Term sanitation + budgets

    func testTermsAreTrimmedAndCollapsed() {
        let terms = DialectBiasComposer.sanitizedTerms(
            ["  Sita   Kumari ", "Ram\nBahadur", "   ", ""], maxCount: 10)
        XCTAssertEqual(terms, ["Sita Kumari", "Ram Bahadur"])
    }

    func testTermLengthCapped() {
        let long = String(repeating: "ख", count: 100)
        let terms = DialectBiasComposer.sanitizedTerms([long], maxCount: 10)
        XCTAssertEqual(terms.first?.count, DialectBiasComposer.maxTermLength)
    }

    func testPerCategoryCaps() {
        let contacts = (0..<100).map { "contact\($0)" }
        let medications = (0..<50).map { "med\($0)" }
        let apps = (0..<30).map { "app\($0)" }
        let plan = DialectBiasComposer.plan(
            label: .eastern,
            table: makeTable(),
            lexicon: makeLexicon(),
            profile: makeProfile(contacts: contacts,
                                 medications: medications,
                                 apps: apps),
            enabled: true)
        XCTAssertEqual(plan.contactCount, DialectBiasComposer.maxContactTerms)
        XCTAssertEqual(plan.medicationCount, DialectBiasComposer.maxMedicationTerms)
        XCTAssertEqual(plan.appCount, DialectBiasComposer.maxAppTerms)
        XCTAssertEqual(plan.state, .active)
    }

    func testCaseInsensitiveDedupePreservesFirstOccurrence() {
        // "Sita" the contact and "sita" the medication are the same term —
        // one prompt slot, first spelling wins. Cross-category.
        let plan = DialectBiasComposer.plan(
            label: .eastern,
            table: makeTable(),
            lexicon: makeLexicon(),
            profile: makeProfile(contacts: ["Sita"], medications: ["sita", "SITA"]),
            enabled: true)
        XCTAssertEqual(plan.contactCount, 1)
        XCTAssertEqual(plan.medicationCount, 2, "counts are per-category, pre-dedupe")
        XCTAssertEqual(plan.promptText,
                       "Sita गइछ भइछ पूर्वेली नेपाली बोली")
    }

    func testPromptTextCharacterBudgetAtWordBoundary() {
        // 20 capped-in terms of 40 chars + spaces ≈ 819 chars — well over
        // the 600-char budget, so the boundary truncation must fire.
        let contacts = (0..<60).map { index -> String in
            "contactnumber\(String(format: "%02d", index))"
                + String(repeating: "x", count: 25)
        }
        let plan = DialectBiasComposer.plan(label: .eastern,
                                            table: makeTable(),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(contacts: contacts),
                                            enabled: true)
        let text = try! XCTUnwrap(plan.promptText)
        XCTAssertLessThanOrEqual(text.count, DialectBiasComposer.maxPromptCharacters)
        XCTAssertFalse(text.hasSuffix(" "))
        // Every word in the capped prompt must be a COMPLETE member of
        // the uncapped material — a partial word proves a bad cut.
        let allowed = Set(contacts.prefix(DialectBiasComposer.maxContactTerms))
            .union(["गइछ", "भइछ", "पूर्वेली", "नेपाली", "बोली"])
        for word in text.split(separator: " ") {
            XCTAssertTrue(allowed.contains(String(word)),
                          "partial or unknown word '\(word)' in capped prompt")
        }
    }

    func testTruncationKeepsCompleteWordAtExactBoundary() {
        XCTAssertEqual(DialectBiasComposer.truncated(atWordBoundary: "aaa bbb ccc",
                                                     maxCharacters: 7),
                       "aaa bbb")
        XCTAssertEqual(DialectBiasComposer.truncated(atWordBoundary: "aaa bbbb ccc",
                                                     maxCharacters: 6),
                       "aaa")
        XCTAssertEqual(DialectBiasComposer.truncated(atWordBoundary: "aaaaaa",
                                                     maxCharacters: 3),
                       "aaa")
    }

    // MARK: - Lexicon + table honesty

    func testLexiconEntryPerLabelAndDefaultNil() {
        let lexicon = makeLexicon()
        XCTAssertEqual(lexicon.entry(for: .doteli)?.phrases, ["भया", "रह्याको"])
        XCTAssertEqual(lexicon.entry(for: .eastern)?.tagLine, "पूर्वेली नेपाली बोली")
        XCTAssertNil(lexicon.entry(for: .default))
    }

    func testLexiconValidationIssues() {
        XCTAssertEqual(makeLexicon(corrupt: true).issues(),
                       [.unsupportedFormatVersion(9)])
        XCTAssertEqual(makeLexicon(tagLines: [:], phrases: [:]).issues(),
                       [.emptyEntries])
        XCTAssertEqual(makeLexicon(tagLines: ["doteli": "", "eastern": "पूर्वेली"])
                       .issues(),
                       [.emptyTagLine("doteli")])
    }

    func testCorruptLexiconDegradesToProfileTermsOnly() {
        // Structural corruption must never bias; profile terms are the
        // trustworthy remainder.
        let plan = DialectBiasComposer.plan(label: .doteli,
                                            table: makeTable(),
                                            lexicon: makeLexicon(corrupt: true),
                                            profile: makeProfile(contacts: ["Sita"]),
                                            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertEqual(plan.promptText, "Sita")
        XCTAssertEqual(plan.lexiconPhraseCount, 0)
    }

    func testMissingLexiconDegradesToProfileTermsOnly() {
        let plan = DialectBiasComposer.plan(label: .doteli,
                                            table: makeTable(),
                                            lexicon: nil,
                                            profile: makeProfile(contacts: ["Sita"]),
                                            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertEqual(plan.promptText, "Sita")
        XCTAssertEqual(plan.lexiconPhraseCount, 0)
    }

    func testCorruptTableYieldsNoCalibratedIds() {
        // Mirrors the classifier's tableCorrupt refusal: a table with
        // issues contributes no token ids to the bias.
        let plan = DialectBiasComposer.plan(label: .eastern,
                                            table: makeTable(corrupt: true),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(),
                                            enabled: true)
        XCTAssertEqual(plan.state, .active, "lexicon alone still biases")
        XCTAssertTrue(plan.calibratedTokenIds.isEmpty)
    }

    func testValidTableYieldsCalibratedIds() {
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: makeTable(promptTokenIds: ["doteli": [7, 8, 9]]),
            lexicon: makeLexicon(),
            profile: makeProfile(),
            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertEqual(plan.calibratedTokenIds, [7, 8, 9])
    }

    // MARK: - Token merge

    func testMergeDedupesAndTruncatesToMax() {
        let many = Array(0..<(DialectBiasComposer.maxPromptTokenCount + 20))
        let merged = DialectBiasComposer.mergeTokenIDs(calibrated: [1, 2],
                                                       tokenized: many)
        XCTAssertEqual(merged.count, DialectBiasComposer.maxPromptTokenCount)
        XCTAssertEqual(merged.prefix(2), [1, 2], "calibrated ids lead")
        XCTAssertEqual(Set(merged).count, merged.count, "no duplicates")
    }

    func testMergeDropsDuplicatesAcrossSources() {
        let merged = DialectBiasComposer.mergeTokenIDs(calibrated: [1, 2, 3],
                                                       tokenized: [3, 4, 1])
        XCTAssertEqual(merged, [1, 2, 3, 4])
    }

    func testMergeEmptyInputsIsEmpty() {
        XCTAssertEqual(DialectBiasComposer.mergeTokenIDs(calibrated: [],
                                                         tokenized: []), [])
    }

    // MARK: - WhisperKit recognizer seam (static, no model)

    func testPromptTokensTokenizesAndMergesForActivePlan() {
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: makeTable(promptTokenIds: ["doteli": [500]]),
            lexicon: makeLexicon(),
            profile: makeProfile(contacts: ["Sita"]),
            enabled: true)
        // Placeholder tokenizer: each distinct word gets a fresh id (like
        // SherpaKWSWakeWordEngineTests, the seam test needs no real
        // runtime — only the merge/fallback logic matters). Distinct
        // words are guaranteed distinct ids, so the final count proves
        // calibration + tokenization merged without loss.
        var next = 700
        var idsByWord: [Substring: Int] = [:]
        let tokenizer: (String) -> [Int] = { text in
            text.split(separator: " ").map { word in
                if let id = idsByWord[word] { return id }
                let id = next
                next += 1
                idsByWord[word] = id
                return id
            }
        }
        switch WhisperKitSpeechRecognizer.promptTokens(for: plan,
                                                       tokenizer: tokenizer) {
        case .applied(let tokens):
            XCTAssertEqual(tokens.first, 500, "calibrated ids lead")
            // 1 calibrated + 7 distinct words (Sita, भया, रह्याको,
            // डोटेली, भाषा,, सुदूरपश्चिम, नेपाल) = 8, all unique.
            XCTAssertEqual(tokens.count, 8)
            XCTAssertEqual(Set(tokens).count, tokens.count)
        case .notApplied(let reason):
            XCTFail("expected applied, got \(reason)")
        }
    }

    func testPromptTokensTokenizerMissingFallsBackToCalibrated() {
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: makeTable(promptTokenIds: ["doteli": [500]]),
            lexicon: nil,
            profile: makeProfile(contacts: ["Sita"]),
            enabled: true)
        switch WhisperKitSpeechRecognizer.promptTokens(for: plan,
                                                       tokenizer: nil) {
        case .applied(let tokens):
            XCTAssertEqual(tokens, [500])
        case .notApplied(let reason):
            XCTFail("expected applied, got \(reason)")
        }
    }

    func testPromptTokensTokenizerMissingAndNoCalibratedRefuses() {
        let plan = DialectBiasComposer.plan(label: .doteli,
                                            table: makeTable(),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(),
                                            enabled: true)
        XCTAssertEqual(WhisperKitSpeechRecognizer.promptTokens(for: plan,
                                                               tokenizer: nil),
                       .notApplied("tokenizer_missing"))
    }

    func testPromptTokensInactivePlanRefuses() {
        let plan = DialectBiasComposer.plan(label: .default,
                                            table: makeTable(),
                                            lexicon: makeLexicon(),
                                            profile: makeProfile(),
                                            enabled: true)
        XCTAssertEqual(WhisperKitSpeechRecognizer.promptTokens(
            for: plan,
            tokenizer: { _ in [1] }), .notApplied("inactive"))
    }

    // MARK: - whisper.cpp recognizer seam

    func testDupPromptCStringRoundTrip() {
        let text = "Sita भया डोटेली भाषा"
        guard let buffer = WhisperSpeechRecognizer.dupPromptCString(text) else {
            return XCTFail("expected a buffer for non-empty text")
        }
        defer { free(buffer) }
        XCTAssertEqual(String(cString: buffer), text)
    }

    // MARK: - Settings seam

    func testSettingsDefaultEnabledPersistAndReset() {
        let defaults = isolateDefaults()
        XCTAssertTrue(DialectBiasSettings.isEnabled(defaults: defaults))

        DialectBiasSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(DialectBiasSettings.isEnabled(defaults: defaults))

        DialectBiasSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(DialectBiasSettings.isEnabled(defaults: defaults))

        DialectBiasSettings.reset(defaults: defaults)
        XCTAssertTrue(DialectBiasSettings.isEnabled(defaults: defaults),
                      "reset restores the default (enabled)")
    }

    // MARK: - Resolver + shipped artifacts

    func testResolverWithInjectablesMatchesPlan() {
        let resolved = DialectBiasResolver.resolve(
            profile: makeProfile(contacts: ["Sita"]),
            table: makeTable(),
            lexicon: makeLexicon(),
            enabled: true,
            label: .doteli)
        XCTAssertEqual(resolved.state, .active)
        XCTAssertEqual(resolved.promptText, "Sita भया रह्याको डोटेली भाषा, सुदूरपश्चिम नेपाल")
    }

    func testBundledSeedLexiconIsStructurallyValidAndHonest() throws {
        guard Bundle.main.url(forResource: DialectLexicon.bundledResourceName,
                              withExtension: "json") != nil else {
            // Mirrors the centroid-table test: the resource ships via
            // project.yml; before xcodegen generate it is absent.
            throw XCTSkip("DialectLexicon.json not bundled yet "
                          + "(run xcodegen generate + build)")
        }
        let lexicon = try DialectLexicon.bundled()
        let unwrapped = try XCTUnwrap(lexicon)
        XCTAssertEqual(unwrapped.formatVersion, 1)
        XCTAssertEqual(unwrapped.issues(), [], "shipped lexicon must validate")
        XCTAssertEqual(unwrapped.generation.status, "SEED-LEXICON",
                       "linguist review is pending — the shipped file must "
                       + "still declare itself a seed")
        XCTAssertEqual(unwrapped.entries.map(\.dialect).sorted(),
                       ["doteli", "eastern"])
        for entry in unwrapped.entries {
            XCTAssertFalse(entry.tagLine.isEmpty)
        }
        // The seed must actually be usable: every label resolves to an
        // active plan carrying its tag line.
        for label in [DialectLabel.eastern, .doteli] {
            let plan = DialectBiasComposer.plan(label: label,
                                                table: makeTable(),
                                                lexicon: unwrapped,
                                                profile: makeProfile(),
                                                enabled: true)
            XCTAssertEqual(plan.state, .active)
            XCTAssertTrue(plan.promptText?.isEmpty == false)
        }
    }

    func testBundledSeedLexiconAndTableComposeTogether() throws {
        // The shipped table (SEED-CENTROIDS, empty token ids) + the
        // shipped lexicon must compose without the seed table inventing
        // lexical bias: calibrated ids stay empty, text bias comes from
        // the lexicon only.
        guard Bundle.main.url(forResource: DialectCentroidTable.bundledResourceName,
                              withExtension: "json") != nil else {
            throw XCTSkip("DialectCentroids.json not bundled yet")
        }
        let table = try DialectCentroidTable.bundled()
        let lexicon = try DialectLexicon.bundled()
        let plan = DialectBiasComposer.plan(label: .doteli,
                                            table: table,
                                            lexicon: lexicon,
                                            profile: makeProfile(contacts: ["Sita"]),
                                            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertTrue(plan.calibratedTokenIds.isEmpty,
                      "seed table must not invent lexical bias")
        XCTAssertTrue(plan.promptText?.contains("Sita") == true)
        XCTAssertTrue(plan.promptText?.contains("डोटेली") == true)
    }
}
