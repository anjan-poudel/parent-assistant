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
                       ModelCatalog.intentQwen4BS43)
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
                       ModelCatalog.whisperMediumFinetunedNepali)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "en")?.id,
                       ModelCatalog.whisperBaseEn)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")?.id,
                       ModelCatalog.intentQwen4BS43)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase, language: "en")?.id,
                       ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "ne")?.id,
                       ModelCatalog.piperNepali)
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .tts, language: "en")?.id,
                       ModelCatalog.piperEnglishUS)
    }

    func testNepaliSTTDefaultIsTheBundledModel() throws {
        let entry = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .whisperBase,
                                                            language: "ne"))
        XCTAssertEqual(entry.id, ModelCatalog.whisperMediumFinetunedNepali)
        XCTAssertNotNil(entry.bundledResourceName,
                        "the ne auto-switch target is the BUNDLED medium — "
                        + "switching the app language back to Nepali downloads nothing")
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
        // whisperMediumV6 leads the curated STT list (and is []-free), so
        // the generic lookup alone would pick it; the explicit map must win.
        XCTAssertEqual(ModelCatalog.explicitDefaultEntry(kind: .whisperBase,
                                                         language: "ne")?.id,
                       ModelCatalog.whisperMediumFinetunedNepali)
        XCTAssertNotEqual(ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")?.id,
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
}
