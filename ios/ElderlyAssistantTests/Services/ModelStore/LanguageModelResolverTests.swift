import XCTest
@testable import ElderlyAssistant

/// The auto-switch matrix behind the app-language change (2026-09-13):
/// when the language moves to a language the currently selected models do
/// not serve, the preferences follow it to the per-kind default — and a
/// model that DOES serve the language (including a user's own intent-brain
/// pick) is never disturbed.
final class LanguageModelResolverTests: XCTestCase {

    // MARK: - Compatibility rule

    func testLanguageNeutralEntryIsCompatibleWithEveryLanguage() {
        let multilingual = ModelCatalog.entry(for: ModelCatalog.whisperSmallMultilingual)!
        for language in ["ne", "en", "de", ""] {
            XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(multilingual,
                                                                    language: language))
        }
    }

    func testTaggedEntryIsCompatibleWithItsOwnLanguageOnly() {
        let nepali = ModelCatalog.entry(for: ModelCatalog.whisperMediumV6)!
        let english = ModelCatalog.entry(for: ModelCatalog.whisperBaseEn)!
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(nepali, language: "ne"))
        XCTAssertFalse(LanguageModelResolver.isLanguageCompatible(nepali, language: "en"))
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(english, language: "en"))
        XCTAssertFalse(LanguageModelResolver.isLanguageCompatible(english, language: "ne"))
        // Case-insensitive: a stored "NE" can never strand a preference.
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(nepali, language: "NE"))
    }

    // MARK: - ne → en: the Nepali models step aside

    func testNepaliToEnglishSwitchesSTTToTheEnglishModel() {
        let resolved = LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperMediumFinetunedNepali, language: "en")
        XCTAssertEqual(resolved, ModelCatalog.whisperBaseEn)
    }

    func testNepaliToEnglishSwitchesBrainToALanguageNeutralStockQwen() {
        let resolved = LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwen4BS43, language: "en")
        let entry = resolved.flatMap(ModelCatalog.entry(for:))
        XCTAssertEqual(entry?.languages, [],
                       "the English brain must be a language-neutral model")
        XCTAssertEqual(resolved, ModelCatalog.defaultEntry(kind: .llamaBase,
                                                           language: "en")?.id)
        // The EXPLICIT map's en brain (fix 1): the 1.7B stock Qwen, not the
        // 2.5 GB 4B the generic []-fallback would pick — an app-language
        // change must never kick off a multi-GB download by itself.
        XCTAssertEqual(resolved, ModelCatalog.qwen3_1_7BInstruct)
    }

    func testNepaliToEnglishSwitchesTheReplyVoice() {
        let chosen = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)
        let resolved = LanguageModelResolver.resolvedVoicePreference(current: chosen,
                                                                    language: "en")
        XCTAssertEqual(resolved, ResponseVoice(voiceID: ModelCatalog.piperEnglishUS,
                                               speakerID: 0))
    }

    // MARK: - en → ne: the Nepali defaults come back

    func testEnglishToNepaliSwitchesSTTBackToANepaliModel() throws {
        let resolved = LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperBaseEn, language: "ne")
        XCTAssertEqual(resolved, ModelCatalog.defaultEntry(kind: .whisperBase,
                                                           language: "ne")?.id)
        let entry = try XCTUnwrap(resolved.flatMap(ModelCatalog.entry(for:)))
        XCTAssertEqual(entry.languages, ["ne"],
                       "the ne default must actually be a Nepali model")
    }

    func testLanguageNeutralBrainSurvivesTheSwitchBackToNepali() {
        // A `[]`-tagged (stock Qwen) brain works in every language, so the
        // switch to Nepali leaves the household's pick where it is — the
        // compatibility rule covers `[]` entries in BOTH directions (see
        // the task report: the only non-neutral brains shipped are Nepali
        // ones, so the ne-direction brain switch has no shipped trigger).
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.qwen3_4BInstruct, language: "ne"),
                       ModelCatalog.qwen3_4BInstruct)
    }

    func testBrainTaggedForAnotherLanguageSwitchesToTheNepaliFineTune() {
        // The generic path, pinned with an injected en-tagged brain: a
        // model that does NOT serve the new language is swapped for the
        // per-kind default — here the curated ne brain.
        let englishOnly = ModelCatalogEntry(
            id: ModelID("synthetic-en-only-brain"),
            kind: .llamaBase,
            displayName: "Synthetic English brain",
            filename: "synthetic.gguf",
            downloadURL: URL(string: "https://example.invalid/synthetic.gguf")!,
            sizeBytes: 1,
            sha256: "",
            minDeviceRAMBytes: 1,
            languages: ["en"])
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: englishOnly.id, language: "ne", catalog: [englishOnly]),
                       ModelCatalog.intentQwen4BSlotCanon)
    }

    func testEnglishToNepaliSwitchesTheReplyVoiceToTheNepaliDefault() {
        let chosen = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        let resolved = LanguageModelResolver.resolvedVoicePreference(current: chosen,
                                                                    language: "ne")
        XCTAssertEqual(resolved, ResponseVoice(voiceID: ModelCatalog.piperNepali,
                                               speakerID: 0))
    }

    // MARK: - The preference is preserved when it still fits

    func testUserSelectedIntentBrainIsPreservedWhenTheLanguageMatches() {
        // The whole point of requirement 1: the intent model stays
        // selectable. A ne→ne (or an untouched) language must never swap
        // the brain the household chose.
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwenS43, language: "ne"),
                       ModelCatalog.intentQwenS43)
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwen4BS43, language: "ne"),
                       ModelCatalog.intentQwen4BS43)
    }

    func testMultilingualSelectionSurvivesBothLanguages() {
        // whisper-small-multilingual is [] — language-neutral, so neither
        // direction touches it.
        for language in ["ne", "en"] {
            XCTAssertEqual(LanguageModelResolver.resolvedPreference(
                current: ModelCatalog.whisperSmallMultilingual, language: language),
                           ModelCatalog.whisperSmallMultilingual)
        }
    }

    func testCompatibleVoiceKeepsItsSpeakerChoice() {
        let chosen = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 7)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(current: chosen,
                                                                    language: "ne"),
                       chosen)
    }

    // MARK: - Never touched: automatic, stale, unknown

    func testAutomaticPreferenceIsNeverTouched() {
        // nil = "Automatic": the app decides, so a language switch has
        // nothing to correct (documented scope decision — see the task
        // report; automatic resolution per language is a follow-up).
        XCTAssertNil(LanguageModelResolver.resolvedPreference(current: nil,
                                                              language: "en"))
        XCTAssertNil(LanguageModelResolver.resolvedPreference(current: nil,
                                                              language: "ne"))
        XCTAssertNil(LanguageModelResolver.resolvedVoicePreference(current: nil,
                                                                   language: "en"))
    }

    func testStaleModelIdIsLeftAlone() {
        // An id no longer in the catalog: the existing restore path
        // already ignores it — the resolver must not clear it here either.
        let stale = ModelID("retired-model-q4km")
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(current: stale,
                                                                language: "en"),
                       stale)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: ResponseVoice(voiceID: stale, speakerID: 0), language: "en"),
                       ResponseVoice(voiceID: stale, speakerID: 0))
    }

    // MARK: - The coordinator's write rule (resolved != current)

    func testNoWriteIsSignalledWhenThePreferenceStillFits() {
        // The coordinator only assigns on a real difference; a compatible
        // preference must compare equal so nothing is rewritten (and no
        // download is kicked).
        let current = ModelCatalog.intentQwen4BS43
        let resolved = LanguageModelResolver.resolvedPreference(current: current,
                                                                language: "ne")
        XCTAssertEqual(resolved, current)
    }

    // MARK: - Fix 1: the explicit per-language default map

    func testExplicitDefaultMapPinsTheAutoSwitchTargets() {
        // The curated map is what an app-language switch lands on. Pinned
        // EXACTLY so a reordering of the curated pickers (whose order the
        // generic lookup follows) can never move these targets back onto a
        // multi-GB download.
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")?.id,
                       ModelCatalog.whisperKitMediumV6)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "en")?.id,
                       ModelCatalog.whisperBaseEn)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")?.id,
                       ModelCatalog.intentQwen4BSlotCanon)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "en")?.id,
                       ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "ne")?.id,
                       ModelCatalog.piperNepali)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "en")?.id,
                       ModelCatalog.piperEnglishUS)
    }

    func testNepaliSTTDefaultIsTheBestANEBuild() throws {
        let entry = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .whisperBase,
                                                            language: "ne"))
        XCTAssertEqual(entry.id, ModelCatalog.whisperKitMediumV6)
        // The default rule (2026-09-16): best measured accuracy AND, where
        // the catalog has one, the ANE-accelerated build. The WhisperKit
        // path is what marks an entry as the ANE one.
        XCTAssertNotNil(entry.whisperKitZipURL,
                        "the ne default must be the ANE (WhisperKit) build")
        XCTAssertEqual(entry.languages, ["ne"])
        XCTAssertEqual(entry.id, ModelCatalog.availableSTTEntries.first?.id,
                       "…and it leads the curated picker list, so the first row "
                       + "a household sees is the model an auto-switch lands on")
    }

    /// The ne default is a DOWNLOAD again (it was the bundled medium before
    /// 2026-09-16). Pinned deliberately: with the default no longer on disk
    /// at first run, the honest convergence path is the auto-restore in PR 3,
    /// and the app must never silently fall back to the bundled medium on the
    /// CPU path (the 2026-09-16 device bug this PR series exists to fix).
    func testTheANEDefaultIsADownloadNotABundledResource() throws {
        let entry = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .whisperBase,
                                                            language: "ne"))
        XCTAssertNil(entry.bundledResourceName,
                     "the v6 ANE is not bundled — a fresh install downloads it")
        // The bundled medium is still reachable as an explicit pick…
        XCTAssertTrue(ModelCatalog.availableSTTEntries.contains {
            $0.id == ModelCatalog.whisperMediumFinetunedNepali
        })
        // …but is not what a language switch (or a fresh install) lands on.
        XCTAssertNotEqual(entry.id, ModelCatalog.whisperMediumFinetunedNepali)
    }

    func testEnglishBrainDefaultIsTheLighterStockQwen() throws {
        let entry = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .llamaBase,
                                                            language: "en"))
        let generic = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.qwen3_4BInstruct))
        XCTAssertEqual(entry.id, ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertEqual(entry.languages, [],
                       "…and is still language-neutral, so English is served")
        XCTAssertLessThan(entry.sizeBytes, generic.sizeBytes,
                          "the explicit en brain must be lighter than the "
                          + "[]-fallback the generic lookup would pick")
    }

    func testExplicitMapOverridesTheGenericLookupAndOtherLanguagesKeepIt() {
        // The brain map is where the override is still observable: the
        // generic lookup for "en" finds no en-tagged brain and falls to the
        // first []-tagged one (Qwen3 4B, the curated list's 4th entry), while
        // the explicit map names the lighter 1.7B. The map must win.
        //
        // (Until 2026-09-16 the STT kind proved this too, by naming the
        // bundled medium while `whisperMediumV6` led the list. The ne STT
        // default is now the list's own leader — the v6 ANE — so that
        // particular inequality is gone by design: the picker's first row
        // and the auto-switch target are deliberately the same model now.)
        XCTAssertNotEqual(ModelCatalog.explicitDefaultEntry(kind: .llamaBase,
                                                            language: "en")?.id,
                          ModelCatalog.curatedEntries(kind: .llamaBase).first?.id)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "en")?.id,
                       ModelCatalog.qwen3_1_7BInstruct)
        // The STT default and the picker's leader agree (the new rule).
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")?.id,
                       ModelCatalog.curatedEntries(kind: .whisperBase).first?.id)
        // A language with no explicit pick is untouched: generic logic.
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "de")?.id,
                       ModelCatalog.whisperSmallMultilingual)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "de")?.id,
                       ModelCatalog.qwen3_4BInstruct)
    }

    func testEveryExplicitPickIsALiveEntryOfTheRightKindForItsLanguage() {
        for (kind, picks) in ModelCatalog.languageDefaultPicks {
            for (code, id) in picks {
                let entry = ModelCatalog.entry(for: id)
                XCTAssertNotNil(entry, "\(kind)/\(code) → \(id.rawValue) is not in the catalog")
                XCTAssertEqual(entry?.kind, kind,
                               "\(id.rawValue) must be of the kind it defaults for")
                XCTAssertTrue(entry.map {
                    LanguageModelResolver.isLanguageCompatible($0, language: code)
                } ?? false,
                              "\(id.rawValue) must actually serve \(code)")
                // The curated-membership rule the generic path keeps (a
                // hidden/superseded entry can never be auto-selected).
                XCTAssertTrue(ModelCatalog.curatedEntries(kind: kind)
                    .contains { $0.id == id },
                              "\(id.rawValue) must be a CURATED \(kind) entry, "
                              + "not a hidden/superseded one")
            }
        }
    }

    // MARK: - Fix 3 (2026-09-16): remembered per-language STT/brain picks

    func testRememberedSTTForTheTargetLanguageBeatsTheDefaultMap() {
        // The household picked the v5 CPU engine for Nepali; the round trip
        // back must return it, not the default map's v6 ANE.
        let current = ModelCatalog.whisperBaseEn
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: current, language: "ne",
            remembered: ["ne": ModelCatalog.whisperMediumV5]),
                       ModelCatalog.whisperMediumV5,
                       "the household's own ne pick returns — not the ne default")
    }

    func testRememberedBrainForTheTargetLanguageBeatsTheDefaultMap() {
        // The direction the brain memory actually fires in: an ne-tagged
        // intent fine-tune cannot serve English, so the switch consults the
        // en memory — the household's own en pick (the 4B stock Qwen)
        // returns instead of the default map's lighter 1.7B.
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwenS43, language: "en",
            remembered: ["en": ModelCatalog.qwen3_4BInstruct]),
                       ModelCatalog.qwen3_4BInstruct,
                       "the household's own en pick beats the default map")
    }

    /// The ne leg of the brain round trip is LATENT in the shipped catalog:
    /// every non-neutral brain is ne-tagged, and a `[]`-tagged stock Qwen is
    /// compatible with ne — so the resolver never switches it, exactly as
    /// `testLanguageNeutralBrainSurvivesTheSwitchBackToNepali` pins. With a
    /// current brain that IS tagged for another language the memory restores
    /// the ne pick in that direction too, which is what this pins: the
    /// mechanism is not STT-specific.
    func testRememberedBrainRestoresOnTheNepaliLegForATaggedCurrentBrain() throws {
        let englishOnly = ModelCatalogEntry(
            id: ModelID("synthetic-en-only-brain"),
            kind: .llamaBase,
            displayName: "Synthetic English brain",
            filename: "synthetic.gguf",
            downloadURL: URL(string: "https://example.invalid/synthetic.gguf")!,
            sizeBytes: 1,
            sha256: "",
            minDeviceRAMBytes: 1,
            languages: ["en"])
        let nePick = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43))
        let defaultNe = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .llamaBase,
                                                               language: "ne")?.id)
        XCTAssertNotEqual(nePick.id, defaultNe, "fixture must be a NON-default pick")
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: englishOnly.id, language: "ne",
            remembered: ["ne": nePick.id],
            catalog: [englishOnly, nePick]),
                       nePick.id,
                       "the remembered ne brain returns — not the ne default")
    }

    func testRememberedSTTIsCaseInsensitiveAboutTheLanguageCode() {
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperBaseEn, language: "NE",
            remembered: ["ne": ModelCatalog.whisperMediumV5]),
                       ModelCatalog.whisperMediumV5)
    }

    func testRememberedSTTOnlyAnswersForItsOwnLanguage() {
        // A ne memory must never leak into an en switch — the en default is
        // the only correct answer there.
        let current = ModelCatalog.whisperMediumV5
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: current, language: "en",
            remembered: ["ne": ModelCatalog.whisperKitMediumV6]),
                       ModelCatalog.whisperBaseEn)
    }

    func testStaleRememberedSTTIsIgnored() {
        let current = ModelCatalog.whisperBaseEn
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: current, language: "ne",
            remembered: ["ne": ModelID("whisper-engine-that-never-existed")]),
                       ModelCatalog.whisperKitMediumV6,
                       "a remembered id that no longer resolves is ignored "
                       + "(never applied, never deleted) — the default answers")
    }

    func testRememberedSTTOfTheWrongKindIsIgnored() {
        // Corrupt or foreign storage naming a brain for the STT slot: the
        // memory must not be able to put the recognizer on a GGUF brain.
        let current = ModelCatalog.whisperBaseEn
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: current, language: "ne",
            remembered: ["ne": ModelCatalog.intentQwenS43]),
                       ModelCatalog.whisperKitMediumV6)
        // …and vice versa, through an injected en-tagged brain (the shipped
        // brains are either ne-tagged or language-neutral, so the ne
        // direction has no catalog fixture — same seam as
        // `testBrainTaggedForAnotherLanguageSwitchesToTheNepaliFineTune`).
        let englishOnly = ModelCatalogEntry(
            id: ModelID("synthetic-en-only-brain"),
            kind: .llamaBase,
            displayName: "Synthetic English brain",
            filename: "synthetic.gguf",
            downloadURL: URL(string: "https://example.invalid/synthetic.gguf")!,
            sizeBytes: 1,
            sha256: "",
            minDeviceRAMBytes: 1,
            languages: ["en"])
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: englishOnly.id, language: "ne",
            remembered: ["ne": ModelCatalog.whisperMediumV5],
            catalog: [englishOnly]),
                       ModelCatalog.intentQwen4BSlotCanon,
                       "an STT id in the brain memory is ignored")
    }

    func testRememberedSTTIncompatibleWithItsKeyLanguageIsIgnored() {
        // Storage claiming a Nepali engine for "en": the memory must not put
        // the app back on a model that cannot serve the language it says it
        // serves.
        let current = ModelCatalog.whisperMediumV5
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: current, language: "en",
            remembered: ["en": ModelCatalog.whisperMediumV5]),
                       ModelCatalog.whisperBaseEn)
    }

    func testRememberedSTTIsIgnoredWhenTheCurrentSTTStillFits() {
        // A compatible current model is never disturbed by a memory — the
        // memory only answers the question the switch actually asks.
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperMediumV5, language: "ne",
            remembered: ["ne": ModelCatalog.whisperKitMediumV6]),
                       ModelCatalog.whisperMediumV5)
    }

    func testRememberedSTTRestoresADeclutteredEngine() {
        // A remembered pick only has to be a live entry of the right kind —
        // NOT a curated one. Decluttering the picker must never cost a
        // household the engine it is already running (the voice memory's
        // rule, applied to the two ModelID-backed kinds).
        let hidden = ModelCatalog.whisperLargeV3Nepali
        XCTAssertFalse(ModelCatalog.availableSTTEntries.contains { $0.id == hidden },
                       "fixture must be an entry the picker does not offer")
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperBaseEn, language: "ne",
            remembered: ["ne": hidden]),
                       hidden)
    }

    // MARK: - Fix 2: remembered per-language voice picks

    func testRememberedVoiceForTheTargetLanguageBeatsTheDefaultMap() {
        let chitwan = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)
        let current = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "ne", remembered: ["ne": chitwan]),
                       chitwan,
                       "the household's own ne pick returns — not piperNepali")
    }

    func testRememberedVoiceKeepsItsSpeakerChoice() {
        let chosen = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 5)
        let current = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "ne", remembered: ["ne": chosen]),
                       chosen,
                       "the remembered pick is the whole voice, speaker included")
    }

    func testRememberedVoiceIsCaseInsensitiveAboutTheLanguageCode() {
        let chitwan = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)
        let current = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "NE", remembered: ["ne": chitwan]),
                       chitwan)
    }

    func testRememberedVoiceOnlyAnswersForItsOwnLanguage() {
        let chitwan = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)
        let current = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "en", remembered: ["ne": chitwan]),
                       ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0),
                       "a ne memory must never leak into an en switch")
    }

    func testStaleRememberedVoiceFallsBackToTheDefaultMap() {
        let stale = ResponseVoice(voiceID: ModelID("piper-retired-voice"), speakerID: 0)
        let current = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "ne", remembered: ["ne": stale]),
                       ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0),
                       "a remembered id that no longer resolves is ignored "
                       + "(never applied, never deleted)")
    }

    func testRememberedVoiceWithAnImpossibleSpeakerIsIgnored() {
        let impossible = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 99)
        let current = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "ne", remembered: ["ne": impossible]),
                       ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0),
                       "an out-of-range speaker falls back to the default map "
                       + "(speaker 0), not to a nonexistent sid")
    }

    func testRememberedVoiceIncompatibleWithItsKeyLanguageIsIgnored() {
        // Foreign/corrupt storage claiming an English voice for "ne": the
        // memory must not be able to put the app back on a voice that
        // cannot speak the language it says it serves.
        let english = ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: english, language: "ne", remembered: ["ne": english]),
                       ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0))
    }

    func testRememberedVoiceIsIgnoredWhenTheCurrentVoiceStillFits() {
        let chitwan = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)
        let current = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 3)
        XCTAssertEqual(LanguageModelResolver.resolvedVoicePreference(
            current: current, language: "ne", remembered: ["ne": chitwan]),
                       current,
                       "a compatible current voice is never disturbed")
    }

    // MARK: - [MODEL-WARDEN] The policy-aware AUTOMATIC pick (2026-09-18)
    //
    // The D1 hole: "Automatic" resolved through the catalog's LANGUAGE
    // default, which knows nothing about memory — so a 6 GB Nepali phone
    // landed on the 4B the class policy refuses beside a warm ANE STT, the
    // ledger admitted it through `soloOverBudget` anyway, and every turn
    // paid a cold STT load. The resolution now consults the policy and
    // steps down the ladder; these are the rungs, per class.

    private let compactPhone: UInt64 = 4_000_000_000     // < 5 GB
    private let standardPhone: UInt64 = 6_000_000_000    // 5–7 GB
    private let roomyPhone: UInt64 = 8_000_000_000       // ≥ 7 GB

    private func automaticPick(_ kind: ModelKind,
                               _ language: String,
                               on memory: UInt64,
                               warmSTTLiveBytes: UInt64? = nil)
    -> LanguageModelResolver.AutomaticPick? {
        LanguageModelResolver.resolvedAutomaticPick(
            kind: kind,
            language: language,
            policy: ModelBudgetPolicy.policy(forPhysicalMemoryBytes: memory),
            physicalMemoryBytes: memory,
            warmSTTLiveBytes: warmSTTLiveBytes)
    }

    private func automaticBrain(_ language: String,
                                on memory: UInt64,
                                warmSTTLiveBytes: UInt64? = nil)
    -> ModelID? {
        automaticPick(.llamaBase, language, on: memory,
                      warmSTTLiveBytes: warmSTTLiveBytes)?.entry.id
    }

    /// The headline: on the class the mechanism exists for, Automatic no
    /// longer lands on the 4B the policy refuses.
    func testAutomaticPickOnASixGBPhoneStepsDownToTheLighterBrain() throws {
        let pick = try XCTUnwrap(automaticPick(.llamaBase, "ne", on: standardPhone))
        // The language default is still the 4B — the catalog is device-blind
        // (pinned in `ModelCatalogLanguageTests`) …
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")?.id,
                       ModelCatalog.intentQwen4BSlotCanon)
        // … and Automatic is what moves off it, to the 1.7B the class CAN
        // hold beside the warm ANE STT.
        XCTAssertEqual(pick.entry.id, ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertNotEqual(pick.entry.id, ModelCatalog.intentQwen4BSlotCanon)
        XCTAssertTrue(pick.availability.isAvailable,
                      "the model Automatic lands on must be one the class can hold")
        // The record: WHY it is not the 4B. The 3.40 GB live footprint is
        // over the 3.2 GB budget on its own, which is `over_class_budget` —
        // not the STT-co-residency sentence, and the two lead a household
        // to different choices.
        XCTAssertEqual(pick.declinedDefaultReason, .overClassBudget)
        XCTAssertEqual(pick.recordedReason, .overClassBudget)
    }

    /// The class that CAN hold the pairing keeps it: nothing about this
    /// change may move the pick on a device that was already right.
    func testAutomaticPickOnARoomyPhoneKeepsTheFourB() throws {
        let pick = try XCTUnwrap(automaticPick(.llamaBase, "ne", on: roomyPhone))
        XCTAssertEqual(pick.entry.id, ModelCatalog.intentQwen4BSlotCanon)
        XCTAssertEqual(pick.entry.id,
                       ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")?.id)
        XCTAssertTrue(pick.availability.isAvailable)
        XCTAssertNil(pick.declinedDefaultReason)
        XCTAssertNil(pick.recordedReason,
                     "a resolution that took the default has nothing to explain")
    }

    /// The ladder only ever steps DOWN. The explicit `en` pick is the light
    /// 1.7B precisely so an app-language switch never kicks off a multi-GB
    /// download (fix 1), and a roomy device must not "upgrade" it back to
    /// the 4B — the policy gate is a memory question, not a taste one.
    func testAutomaticPickNeverUpgradesPastTheLanguageDefault() throws {
        let pick = try XCTUnwrap(automaticPick(.llamaBase, "en", on: roomyPhone))
        XCTAssertEqual(pick.entry.id, ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertEqual(pick.entry.id,
                       ModelCatalog.defaultEntry(kind: .llamaBase, language: "en")?.id)
        XCTAssertNil(pick.recordedReason)
    }

    /// The compact-class finding, seen from the resolver: no shipped brain
    /// fits a 4 GB phone beside the STT its voice turn needs, so there is no
    /// "fits" to resolve to. The pick degrades to the lightest brain and
    /// says what it costs — it does not crash, loop, or silently admit the
    /// model the policy refused.
    func testAutomaticPickOnACompactPhoneDegradesToTheLightestBrainAndSaysSo() throws {
        let pick = try XCTUnwrap(automaticPick(.llamaBase, "ne", on: compactPhone))
        // The lightest language-compatible CURATED brain — 1.11 GB against
        // the 1.28 GB 1.7B and the 2.50 GB 4B class. It is a real model the
        // device can run; the point is that it cannot run it *and* keep the
        // STT warm, which is exactly what the pick's reason says.
        XCTAssertEqual(pick.entry.id, ModelCatalog.intentQwenS43)
        XCTAssertEqual(pick.entry.id,
                       ModelCatalog.availableBrainEntries
                           .filter { LanguageModelResolver.isLanguageCompatible($0,
                                                                               language: "ne") }
                           .min { $0.sizeBytes < $1.sizeBytes }?.id,
                       "…and it is the smallest of the entries a pick may draw from")
        XCTAssertFalse(pick.availability.isAvailable,
                       "the compact finding: nothing this class can hold")
        XCTAssertEqual(pick.availability.reason, .requiresEvictingWarmSTT)
        XCTAssertEqual(pick.recordedReason, .requiresEvictingWarmSTT,
                       "the STT-eviction consequence is stated, not hidden")
        // The default it declined was refused for its own reason — the
        // pick's own sentence is the more useful one, so it wins.
        XCTAssertEqual(pick.declinedDefaultReason, .overClassBudget)
    }

    /// A step-down may never land the household on a model that cannot
    /// serve its language: the lightest BRAIN on the ne path is a Nepali
    /// fine-tune, and an English household must not be handed one.
    func testAutomaticPickServesTheLanguageItResolvesFor() throws {
        let english = try XCTUnwrap(automaticPick(.llamaBase, "en", on: compactPhone))
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(english.entry,
                                                                 language: "en"))
        XCTAssertEqual(english.entry.id, ModelCatalog.qwen3_1_7BInstruct)
        // The ne path's lightest brain is a Nepali-only fine-tune, and the
        // en path must NOT degrade onto it: an English household talking to
        // an ne-tagged intent model is the failure the language rule is
        // there to prevent.
        let nepali = try XCTUnwrap(automaticPick(.llamaBase, "ne", on: compactPhone))
        XCTAssertEqual(nepali.entry.languages, ["ne"])
        XCTAssertNotEqual(nepali.entry.id, english.entry.id)
        XCTAssertTrue(LanguageModelResolver.isLanguageCompatible(nepali.entry,
                                                                 language: "ne"))
        XCTAssertTrue(english.entry.languages.isEmpty,
                      "the en pick is the language-neutral 1.7B")
    }

    /// The warm-STT footprint is a real input, not a decoration: it is the
    /// quantity that decides whether a brain fits BESIDE the resident the
    /// latency contract insists stays warm. A heavier STT than the ANE
    /// graph's 1.0 GB pushes the 1.7B out of the 6 GB class and the pick
    /// steps down again to the 1.1 GB intent fine-tune.
    func testTheWarmSTTFootprintMovesThePick() throws {
        let ane = try XCTUnwrap(automaticBrain("ne", on: standardPhone))
        XCTAssertEqual(ane, ModelCatalog.qwen3_1_7BInstruct)
        let heavier = try XCTUnwrap(automaticBrain("ne", on: standardPhone,
                                                   warmSTTLiveBytes: 1_300_000_000))
        XCTAssertEqual(heavier, ModelCatalog.intentQwenS43,
                       "1.98 GB + 1.3 GB is over the 3.2 GB budget; 1.81 GB + 1.3 GB is not")
        XCTAssertNotEqual(heavier, ane)
    }

    /// Only brains are the policy's business. The light residents — the
    /// reply voice, the VAD, the wake-word spotter — co-reside by design,
    /// so the automatic pick must hand them straight through on every class
    /// (refusing one would be the failure mode the gate exists to avoid).
    func testAutomaticPickLeavesTheLightResidentsAlone() throws {
        let voice = try XCTUnwrap(automaticPick(.tts, "ne", on: compactPhone))
        XCTAssertEqual(voice.entry.id, ModelCatalog.piperNepali)
        XCTAssertEqual(voice.availability, .available)
        XCTAssertNil(voice.recordedReason)
        let vad = try XCTUnwrap(automaticPick(.vad, "ne", on: compactPhone))
        XCTAssertTrue(vad.availability.isAvailable)
        XCTAssertNil(vad.declinedDefaultReason)
    }

    /// The STT ladder is not re-pointed. The recognizer's own default is
    /// the best-accuracy ANE build on every class — the policy has no
    /// business choosing a worse recognizer because a brain is not
    /// resident, and the automatic pick must not "help" by moving it.
    func testAutomaticPickDoesNotRePointTheSTTDefault() throws {
        let pick = try XCTUnwrap(automaticPick(.whisperBase, "ne", on: compactPhone))
        XCTAssertEqual(pick.entry.id, ModelCatalog.whisperKitMediumV6)
        XCTAssertTrue(pick.availability.isAvailable)
        XCTAssertNil(pick.recordedReason)
    }

    /// The explicit path is untouched: the policy gates Automatic, never a
    /// stored preference. A household that picked the 4B on a 6 GB phone
    /// keeps it (the ledger's `soloOverBudget` escape hatch is what serves
    /// it), and a nil preference stays nil — Automatic is not rewritten
    /// into a stored pick.
    func testThePolicyDoesNotOverrideAnExplicitPreference() {
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwen4BSlotCanon, language: "ne"),
                       ModelCatalog.intentQwen4BSlotCanon,
                       "an explicit over-budget pick keeps today's semantics")
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.qwen3_4BInstruct, language: "ne"),
                       ModelCatalog.qwen3_4BInstruct)
        XCTAssertNil(LanguageModelResolver.resolvedPreference(current: nil,
                                                              language: "ne"),
                     "Automatic stays Automatic — the resolver never invents a pick")
    }

    /// Pure and deterministic: same device, same language, same answer —
    /// no clock, no ledger, no accumulated state, so two calls (and two
    /// devices of the same class) cannot disagree.
    func testTheAutomaticPickIsDeterministic() {
        XCTAssertEqual(automaticPick(.llamaBase, "ne", on: standardPhone),
                       automaticPick(.llamaBase, "ne", on: standardPhone))
        XCTAssertEqual(automaticPick(.llamaBase, "ne", on: compactPhone),
                       automaticPick(.llamaBase, "ne", on: compactPhone))
        // The class boundary, not the exact byte count, is what decides:
        // two phones on the same side of it resolve identically.
        XCTAssertEqual(automaticPick(.llamaBase, "ne", on: 5_000_000_000),
                       automaticPick(.llamaBase, "ne", on: 6_900_000_000))
        XCTAssertEqual(automaticPick(.llamaBase, "ne", on: 7_000_000_000),
                       automaticPick(.llamaBase, "ne", on: 8_000_000_000))
    }

    /// A kind that ships nothing has no pick to invent.
    func testAnEmptyKindResolvesToNothing() {
        XCTAssertNil(LanguageModelResolver.resolvedAutomaticPick(
            kind: .whisperLoRA,
            language: "ne",
            policy: ModelBudgetPolicy.standard,
            physicalMemoryBytes: standardPhone))
    }
}
