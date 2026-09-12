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
        XCTAssertEqual(resolved, ModelCatalog.qwen3_4BInstruct)
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
}
