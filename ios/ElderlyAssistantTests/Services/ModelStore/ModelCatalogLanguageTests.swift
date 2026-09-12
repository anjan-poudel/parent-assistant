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
            ModelCatalog.intentGemma1B,
            ModelCatalog.qwen4BNepali
        ]
        for id in nepaliBrains {
            XCTAssertEqual(ModelCatalog.entry(for: id)?.languages, ["ne"],
                           "\(id.rawValue) is a Nepali fine-tune — tag [\"ne\"]")
        }
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
        let stt = ModelCatalog.defaultEntry(kind: .whisperBase, language: "ne")
        XCTAssertEqual(stt?.id, ModelCatalog.whisperMediumV6,
                       "first curated Nepali entry is the ne default (curated order)")
        XCTAssertEqual(stt?.languages, ["ne"])
        let brain = ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne")
        XCTAssertEqual(brain?.id, ModelCatalog.intentQwen4BS43,
                       "the intent fine-tune leads the curated brain list")
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
                       ModelCatalog.whisperMediumV6)
    }
}
