import XCTest
@testable import ElderlyAssistant

/// Pins the language tags on the catalog (2026-09-13) — every model the
/// app can select says which language(s) it serves, and the per-kind
/// default lookup picks by that tag. The tags are what makes the
/// app-language switch safe: an untagged Nepali STT engine (or a
/// wrong-language tag) would leave an English household transcribing with
/// a Devanagari fine-tune.
final class ModelCatalogLanguageTests: XCTestCase {

    // MARK: - Tags: the Nepali STT family

    func testNepaliSTTFamilyIsTaggedNepali() {
        let nepaliSTT: [ModelID] = [
            ModelCatalog.whisperMediumFinetunedNepali,
            ModelCatalog.whisperMediumV5,
            ModelCatalog.whisperMediumV6,
            ModelCatalog.whisperKitMediumV5,
            ModelCatalog.whisperKitMediumV6,
            ModelCatalog.whisperKitNepali,
            ModelCatalog.whisperKitNepaliLargeBase,
            ModelCatalog.whisperKitNepaliMedium,
            ModelCatalog.whisperLargeV3Nepali,
            ModelCatalog.whisperLargeV3NepaliV2,
            ModelCatalog.whisperFinetunedNepali,
            ModelCatalog.whisperFinetunedNepaliQ8,
            ModelCatalog.whisperSmallNepali
        ]
        for id in nepaliSTT {
            XCTAssertEqual(ModelCatalog.entry(for: id)?.languages, ["ne"],
                           "\(id.rawValue) is a Nepali model — it must be tagged [\"ne\"]")
        }
    }

    func testEnglishAndMultilingualSTTAreTaggedForTheirLanguages() {
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.whisperBaseEn)?.languages,
                       ["en"])
        // "Multilingual" ([]) is the any-language tag, not an English one —
        // tagging it "en" would make a ne→en switch pick a general model
        // instead of the English-tuned one.
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.whisperSmallMultilingual)?.languages,
                       [])
    }

    // MARK: - Tags: brains

    func testNepaliIntentBrainsAreTaggedNepali() {
        let nepaliBrains: [ModelID] = [
            ModelCatalog.intentNepali1B,
            ModelCatalog.intentQwenS43,
            ModelCatalog.intentQwen4BS43,
            ModelCatalog.intentQwen4BSlotCanon,
            ModelCatalog.intentGemma1B,
            ModelCatalog.qwen4BNepali
        ]
        for id in nepaliBrains {
            XCTAssertEqual(ModelCatalog.entry(for: id)?.languages, ["ne"],
                           "\(id.rawValue) is a Nepali fine-tune — tag [\"ne\"]")
        }
    }

    /// The live-translate tier's head model (round-2b EN→NE, 2026-09-18) is
    /// tagged for the language it translates INTO — and it is deliberately
    /// not an assistant-brain picker choice, which is the reason it carries
    /// a tag no picker consumes.
    func testTheTranslationBrainIsTaggedNepaliAndNotOfferedAsABrain() {
        let entry = ModelCatalog.entry(for: ModelCatalog.nmtEnNeQwen17bR2bQ8)
        XCTAssertEqual(entry?.languages, ["ne"],
                       "it translates INTO Nepali — [\"ne\"]")
        XCTAssertEqual(entry?.kind, .llamaBase)
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains {
            $0.id == ModelCatalog.nmtEnNeQwen17bR2bQ8
        })
        // The tag has to be one the language machinery understands, and the
        // tier's target language is the one it must match.
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(entry!,
                                                                language: AppLanguage.nepali.rawValue))
    }

    /// [TRANSLATION-MODEL-ROW] (2026-09-18) The AI-models screen's
    /// translation section offers exactly the tier's head, through the
    /// catalog's own list — not a literal in the view.
    ///
    /// Two things are pinned here, and they are the two ways this row can
    /// go wrong: an offered id with no catalog entry can never be installed
    /// (the row would render a Download that cannot exist), and an offered
    /// id that is not the tier's head leaves the row fetching a model the
    /// tier does not lead with — the download would land and change nothing.
    /// The fallbacks behind the head are deliberately NOT offered: they are
    /// assistant brains with rows of their own in the brain section.
    ///
    /// [TEMPORARY OFFER] (Q6-vs-Q8 ARM-kernel A/B) One entry is a second row
    /// for the duration of that run — the round-4 Q8_0 — so a single build can
    /// fetch both quants for a same-device comparison. The revert is deleting
    /// it from the catalog's list; the expectation below is the only assertion
    /// that has to move with it.
    func testTheOfferedTranslationRowsAreExactlyTheTiersHead() {
        let offered = ModelCatalog.availableTranslationEntries.map(\.id)
        XCTAssertEqual(offered, [ModelCatalog.nmtEnNeQwen17bR4Q6,
                                 ModelCatalog.nmtEnNeQwen17bR4Q8],
                       "the tier's shipped head, plus the temporary A/B offer "
                       + "riding behind it")
        // Round 4 (2026-09-21) re-decided which artifact that head is: the
        // round-4 Q5 failed the S11 gate under the shipped prompt and the
        // verdict promoted the Q6_K. The row moved with the verdict, which is
        // the property this assertion guards — an offered row that did NOT
        // move would leave a household downloading a quant the gate refused.
        XCTAssertEqual(LiveTranslateConfig.default.brainTranslationModelIDs.first,
                       offered.first,
                       "the tier leads with the quant the row offers")
        for id in offered {
            XCTAssertNotNil(ModelCatalog.entry(for: id),
                            "\(id.rawValue) is offered but not in the catalog")
        }
        // One model, one row: nothing offered here may also be offered by
        // the brain picker (its rows would duplicate in the brain section).
        let brainIDs = Set(ModelCatalog.availableBrainEntries.map(\.id))
        XCTAssertTrue(Set(offered).isDisjoint(with: brainIDs),
                      "the translation row is not an assistant-brain choice")
    }

    /// [MODEL-KIND] (2026-09-21 review) The filename family IS the
    /// classification: every `.llamaBase` artifact exported for the tier's
    /// translation contract (`translate-en-ne-qwen17b-*.gguf`) must be in
    /// `allTranslationEntries`, and nothing else may be.
    ///
    /// This is the regression a round-4 export exposed: it became the tier's
    /// head without being added to the hand-list, so the artifact the
    /// translation row offered classified as a BRAIN — `brainEntries` is
    /// derived by subtraction, so the head grew a second row on the brain card
    /// (the two-places hazard both lists exist to prevent), and a picker that
    /// filters the ladder by translation-kind lost the head entirely. The
    /// verdict has since moved the head from the round-4 Q5 to the Q6_K, which
    /// is the same trap one export later. Held by family rather than by
    /// re-listing the ids, so the next export fails here instead of on a
    /// device.
    func testEveryTranslationArtifactIsClassifiedAsOne() {
        let family = "translate-en-ne-qwen17b-"
        let byFamily = ModelCatalog.entries(kind: .llamaBase)
            .filter { $0.filename.hasPrefix(family) }
            .map(\.id)
        XCTAssertFalse(byFamily.isEmpty,
                       "the family must exist — without it this test proves nothing")

        let classified = ModelCatalog.allTranslationEntries.map(\.id)
        XCTAssertEqual(Set(classified), Set(byFamily),
                       "the list and the filename family are the same set")
        // The head, asked of the config rather than spelled here: the verdict
        // moves it, and this test must not have to move with it.
        XCTAssertEqual(classified.first, ModelCatalog.availableTranslationEntries.first?.id,
                       "the list leads with the row the translation section offers")
        XCTAssertEqual(classified.first,
                       LiveTranslateConfig.default.brainTranslationModelIDs.first,
                       "…which is the quant the tier leads with")

        for id in byFamily {
            XCTAssertTrue(ModelCatalog.isTranslationModel(id),
                          "\(id.rawValue) is exported for the translation contract")
            XCTAssertFalse(ModelCatalog.brainEntries.contains { $0.id == id },
                           "a translation artifact is never a brain-card row")
        }

        // And the ladder's fallback tail is deliberately the other way round:
        // those are assistant brains the tier may resolve, not translation
        // models — which is why the named path's check is membership in the
        // tier's own translation ladder and not a kind lookup.
        XCTAssertFalse(ModelCatalog.isTranslationModel(ModelCatalog.intentQwen4BS43))
        XCTAssertFalse(ModelCatalog.isTranslationModel(ModelCatalog.intentQwen4BSlotCanon))
    }

    /// The row's title is copy, so it lives in the string table like every
    /// other row's — in both shipped languages. The English value is the
    /// catalog's own `displayName` verbatim; a row that drifted from it
    /// would read differently in Settings than in the catalog's docs.
    func testTheTranslationRowIsNamedInBothLanguages() {
        // Two entries need copy, not one: the translation row that is OFFERED,
        // and the superseded artifact a device that upgraded still holds — the
        // installed-hidden row renders beside the new one, and the names must
        // read as different rows.
        //
        // The round-4 Q6_K's `model.name.<id>` row landed with the swap
        // (2026-09-21), so the offered head is named here rather than the
        // demoted Q5 the previous revision had to fall back to; the Q5 is
        // still pinned as the second row because a round-4 tester's device
        // holds it and renders it. Both strings are the catalog's own
        // `displayName` verbatim, in both shipped languages.
        let entries = [ModelCatalog.nmtEnNeQwen17bR4Q6, ModelCatalog.nmtEnNeQwen17bR4Q5]
            .compactMap { ModelCatalog.entry(for: $0) }
        XCTAssertEqual(entries.count, 2, "both translation entries resolve")
        let en = Locale(identifier: "en")
        let ne = Locale(identifier: "ne-NP")
        for entry in entries {
            let key = "model.name.\(entry.id.rawValue)"
            XCTAssertNotEqual(L10n.str(key, locale: en), key,
                              "\(key) must have an English value")
            XCTAssertNotEqual(L10n.str(key, locale: ne), key,
                              "\(key) must have a Nepali value")
            XCTAssertEqual(entry.displayName(locale: en), entry.displayName,
                           "the English string IS the catalog displayName")
            XCTAssertNotEqual(entry.displayName(locale: ne), entry.displayName,
                              "the Nepali row must not fall back to English")
        }
        // The names must DIFFER: identical copy on two rows is exactly the
        // "which one do I delete?" the superseded rename exists to prevent.
        XCTAssertNotEqual(entries[0].displayName, entries[1].displayName,
                          "the ship quant and the superseded artifact must not "
                          + "read as the same row")
    }

    func testStockQwenAndLlamaBrainsAreLanguageNeutral() {
        let neutral: [ModelID] = [
            ModelCatalog.qwen3_1_7BInstruct,
            ModelCatalog.qwen3_4BInstruct,
            ModelCatalog.llama3_2_1B,
            ModelCatalog.llama3_2_3B
        ]
        for id in neutral {
            XCTAssertEqual(ModelCatalog.entry(for: id)?.languages, [],
                           "\(id.rawValue) is a general instruct model — [] (any language)")
        }
    }

    // MARK: - Tags: voices, VAD, KWS

    func testTTSVoicesCarryTheirLanguage() {
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.piperNepali)?.languages, ["ne"])
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.piperNepaliChitwan)?.languages, ["ne"])
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.piperEnglishUS)?.languages, ["en"])
    }

    func testVADAndKWSAreLanguageNeutral() {
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.sileroVAD)?.languages, [])
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.sherpaKWSGigaSpeech)?.languages, [])
    }

    // MARK: - Tag hygiene

    func testEveryTagIsASupportedAppLanguageCode() {
        let supported = Set(AppLanguage.allCases.map(\.rawValue))
        for entry in ModelCatalog.all {
            for code in entry.languages {
                XCTAssertTrue(supported.contains(code),
                              "\(entry.id.rawValue) tags unknown language \"\(code)\" "
                              + "— tags must be AppLanguage raw values")
            }
        }
    }

    // MARK: - Per-kind default lookup

    func testDefaultEntryPrefersExactLanguageMatch() {
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "en")?.id,
                       ModelCatalog.whisperBaseEn)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "en")?.id,
                       ModelCatalog.piperEnglishUS)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "ne")?.id,
                       ModelCatalog.piperNepali)
    }

    func testNepaliDefaultsAreNepaliTagged() {
        // The EXPLICIT map's ne pick (fix 1), retargeted 2026-09-16 to the
        // default rule: best measured accuracy AND the ANE build, which is
        // the v6 WhisperKit model — also the curated list's own leader.
        let stt = ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")
        XCTAssertEqual(stt?.id, ModelCatalog.whisperKitMediumV6)
        XCTAssertEqual(stt?.languages, ["ne"])
        let brain = ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")
        XCTAssertEqual(brain?.id, ModelCatalog.intentQwen4BSlotCanon,
                       "the map keeps the curated brain list's own ne leader "
                       + "(the gate-passing v16 4B, not the superseded seed-43)")
    }

    func testDefaultEntryFallsBackToLanguageNeutralThenFirst() {
        // German: nothing tagged "de" — the multilingual STT is the honest
        // answer (it really does transcribe German); for a kind with no
        // neutral entry, the curated list's own first entry wins.
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "de")?.id,
                       ModelCatalog.whisperSmallMultilingual)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "de")?.id,
                       ModelCatalog.qwen3_4BInstruct)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "de")?.id,
                       ModelCatalog.piperNepali)
    }

    func testDefaultEntryIsCaseInsensitive() {
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "NE")?.id,
                       ModelCatalog.whisperKitMediumV6)
        XCTAssertEqual(ModelCatalog.explicitDefaultEntry(kind: .llamaBase, language: "EN")?.id,
                       ModelCatalog.qwen3_1_7BInstruct)
    }

    /// The curated picker order IS the preference order, and (since
    /// 2026-09-16) it leads with the per-language ne default — so the first
    /// row a household sees is the model an app-language switch lands on,
    /// and the "best / ANE where one exists" default rule is legible in one
    /// place. The list is pinned exactly; the STT naming suite pins the same
    /// array for its names.
    func testCuratedSTTListLeadsWithTheNepaliANEDefault() {
        let entries = ModelCatalog.availableSTTEntries
        XCTAssertEqual(entries.first?.id, ModelCatalog.whisperKitMediumV6,
                       "the v6 ANE leads — best accuracy on the fast path")
        XCTAssertEqual(entries.first?.id,
                       ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")?.id,
                       "the picker's first row and the ne auto-switch target agree")
        // Every entry the list offers is actually usable in its own
        // language — the English pick must not be a Devanagari fine-tune.
        XCTAssertEqual(ModelCatalog.availableSTTEntries.last?.id,
                       ModelCatalog.whisperBaseEn,
                       "the en pick stays last (60 MB, English-tuned)")
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "en")?.id,
                       ModelCatalog.whisperBaseEn)
    }

    // MARK: - Explicit per-language map (fix 1)

    func testExplicitMapAndGenericLookupAgreeOnTags() {
        // Whatever the map answers must be tagged for the language it
        // answers for — the map overrides the LOOKUP, never the tag rule.
        for (kind, picks) in ModelCatalog.languageDefaultPicks {
            for (code, id) in picks {
                let entry = ModelCatalog.entry(for: id)
                XCTAssertEqual(entry?.kind, kind)
                XCTAssertTrue(entry?.languages.contains(code) ?? false
                              || entry?.languages.isEmpty == true,
                              "\(id.rawValue) must serve \(code)")
            }
        }
    }

    // MARK: - The catalog stays device-blind ([MODEL-WARDEN] 2026-09-18)

    /// The language default is a statement about LANGUAGE, never about the
    /// phone: the ne brain default is the 4B even though
    /// `ModelBudgetPolicy.standard` refuses it beside a warm ANE STT on a
    /// 6 GB device. That is deliberate, not an oversight — the memory-aware
    /// question is `LanguageModelResolver.resolvedAutomaticPick(…)`, which
    /// takes THIS answer as its first rung and steps down the ladder from
    /// there. Moving a device probe into the catalog would make one lookup
    /// answer differently on two phones and break the picker ordering this
    /// file pins from `[DEFAULTS 2026-09-16]`.
    func testTheDefaultEntryStaysDeviceBlind() {
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")?.id,
                       ModelCatalog.intentQwen4BSlotCanon,
                       "the ne brain default is unchanged — the policy gate "
                       + "lives in the resolver, not in the catalog lookup")
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")?.id,
                       ModelCatalog.whisperKitMediumV6)
    }

    func testKindsWithoutAnExplicitPickStillResolve() {
        // VAD / KWS / LoRAs are not in the map — the generic path answers.
        XCTAssertNotNil(ModelCatalog.curatedEntries(kind: .vad).first)
        XCTAssertNotNil(ModelCatalog.defaultEntry(kind: .vad, language: "ne"))
        XCTAssertNotNil(ModelCatalog.defaultEntry(kind: .vad, language: "en"))
        XCTAssertNil(ModelCatalog.explicitDefaultEntry(kind: .vad, language: "ne"))
    }
}
