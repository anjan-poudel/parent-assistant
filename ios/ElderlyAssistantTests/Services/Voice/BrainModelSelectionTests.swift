import XCTest
@testable import ElderlyAssistant

/// Brain selectability (2026-09-06): the picker's catalog surface, the
/// per-model chat formats, and the interpreter's base-model hot-swap.
final class BrainModelSelectionTests: XCTestCase {

    // MARK: - Catalog surface

    /// The picker list is CURATED (catalog declutter, 2026-09-12): the
    /// gate-passing Qwen 4B slim-template seed-43 intent fine-tune (added
    /// 2026-09-13, the default brain), the v14 slim-template seed-43
    /// Nepali 1.7B intent fine-tune (its own id so cached v12 seed-42
    /// devices re-download), the Nepali-specialized Qwen 4B (added
    /// 2026-09-12 for LAN testing), plus the two stock Qwen 3 sizes —
    /// biggest first. The pre-Qwen LLaMA brains and the superseded v12
    /// seed-42 fine-tune are legacy and the Gemma fine-tune fails the
    /// emergency hard gate — none may read as a choice.
    func testAvailableBrainEntriesIsTheCuratedList() {
        XCTAssertEqual(ModelCatalog.availableBrainEntries.map(\.id),
                       [ModelCatalog.intentQwen4BS43,
                        ModelCatalog.intentQwenS43,
                        ModelCatalog.qwen4BNepali,
                        ModelCatalog.qwen3_4BInstruct,
                        ModelCatalog.qwen3_1_7BInstruct])
    }

    /// Hidden brains stay in the catalog so a device that cached one can
    /// still see and delete it (the picker just must not offer it).
    func testHiddenBrainsStayInTheCatalogButAreNotOffered() {
        let offered = Set(ModelCatalog.availableBrainEntries.map(\.id))
        for id in [ModelCatalog.intentGemma1B,
                   ModelCatalog.intentNepali1B,
                   ModelCatalog.llama3_2_1B,
                   ModelCatalog.llama3_2_3B] {
            XCTAssertFalse(offered.contains(id),
                           "\(id.rawValue) is decluttered — must not be offered")
            XCTAssertNotNil(ModelCatalog.entry(for: id),
                            "\(id.rawValue) must stay in `all` so a cached "
                            + "device can still delete it")
            XCTAssertEqual(ModelCatalog.entry(for: id)?.kind, .llamaBase)
        }
    }

    func testGemmaIntentBrainEntryPinsRealArtifact() {
        guard let entry = ModelCatalog.entry(for: ModelCatalog.intentGemma1B) else {
            XCTFail("gemma intent brain entry missing")
            return
        }
        XCTAssertEqual(entry.kind, .llamaBase)
        XCTAssertEqual(entry.filename, "intent-ne-gemma-q4_k_m.gguf")
        // Pinned from the release artifact (export_history.tsv,
        // 2026-09-07 09:40:09 — tag `gemma`, base google/gemma-3-1b-it).
        XCTAssertEqual(entry.sizeBytes, 814_261_088)
        XCTAssertEqual(entry.sha256,
                       "58e59847cdd3c6a1607d0409478405bde9d15ae313e861a35c412cbafc966f95")
        XCTAssertTrue(entry.downloadURL.absoluteString
            .contains("github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v7"))
        XCTAssertTrue(entry.downloadURL.absoluteString.hasSuffix("intent-ne-gemma-q4_k_m.gguf"))
        // HIDDEN since the catalog declutter (2026-09-12): the artifact is
        // real, but the model fails the emergency hard gate, so it must
        // not be offered. It stays in `all` for cached-device deletion.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains { $0.id == ModelCatalog.intentGemma1B })
        XCTAssertNotNil(ModelCatalog.entry(for: ModelCatalog.intentGemma1B))
    }

    // MARK: - L10n naming for the Gemma brain

    func testGemmaBrainNameIsLocalizedEnAndNe() {
        let en = Locale(identifier: "en")
        let ne = Locale(identifier: "ne-NP")
        guard let entry = ModelCatalog.entry(for: ModelCatalog.intentGemma1B) else {
            XCTFail("gemma intent brain entry missing")
            return
        }
        // en L10n == the catalog displayName (the ModelCatalogSTTNaming
        // contract applied to the Gemma brain).
        XCTAssertEqual(entry.displayName(locale: en), entry.displayName)
        let neName = entry.displayName(locale: ne)
        XCTAssertNotEqual(neName, entry.displayName,
                          "Nepali picker row must actually be Nepali")
        // The Nepali row stays distinguishable from every other brain row.
        let otherNeNames = ModelCatalog.availableBrainEntries
            .filter { $0.id != ModelCatalog.intentGemma1B }
            .map { $0.displayName(locale: ne) }
        XCTAssertFalse(otherNeNames.contains(neName))
    }

    func testQwen3BrainEntryPinsRealArtifact() {
        guard let entry = ModelCatalog.entry(for: ModelCatalog.qwen3_4BInstruct) else {
            XCTFail("qwen3 brain entry missing")
            return
        }
        XCTAssertEqual(entry.kind, .llamaBase)
        XCTAssertEqual(entry.sizeBytes, 2_497_280_896)
        XCTAssertEqual(entry.sha256.count, 64)
        XCTAssertNotEqual(entry.sha256, String(repeating: "0", count: 64))
        XCTAssertTrue(entry.downloadURL.absoluteString.contains("huggingface.co"))
        XCTAssertTrue(entry.downloadURL.absoluteString.contains("Q4_K_M"))
    }

    // MARK: - Chat format per model family

    func testChatFormatIsQwen3OnlyForTheQwen3Brain() {
        for qwenID in [ModelCatalog.qwen3_1_7BInstruct, ModelCatalog.qwen3_4BInstruct] {
            let qwen = LlamaCommandInterpreter.chatFormat(for: qwenID)
            XCTAssertEqual(qwen.kind, .qwen3, "\(qwenID) must speak the Qwen3 scheme")
            XCTAssertEqual(qwen.systemPrefix, "<|im_start|>system\n")
            XCTAssertEqual(qwen.stopSequence, "<|im_end|>")
        }

        for other in [ModelCatalog.llama3_2_1B, ModelCatalog.llama3_2_3B, ModelCatalog.intentNepali1B] {
            let format = LlamaCommandInterpreter.chatFormat(for: other)
            XCTAssertEqual(format.kind, .llama3, "\(other) must keep the LLaMA scheme")
            XCTAssertEqual(format.systemPrefix,
                           "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n")
            XCTAssertEqual(format.stopSequence, "<|eot_id|>")
        }
    }

    func testLlama3FormattedPromptIsByteIdenticalToShippedLiteral() {
        // The exact bytes of the pre-selectability multiline literal
        // (verified against git HEAD): one leading newline, double
        // newlines between segments, triple at the end. If this string
        // ever drifts, the shipped 1B brain's instruction-following
        // drifts with it.
        let expected = "\n<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
            + "SYS<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
            + "USR<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n\n"
        let format = LlamaCommandInterpreter.chatFormat(for: ModelCatalog.llama3_2_1B)
        XCTAssertEqual(LlamaCommandInterpreter.formattedPrompt(prompt: "USR",
                                                               system: "SYS",
                                                               format: format),
                       expected)
    }

    func testQwen3FormattedPromptFollowsOfficialChatTemplate() {
        let format = LlamaCommandInterpreter.chatFormat(for: ModelCatalog.qwen3_4BInstruct)
        let prompt = LlamaCommandInterpreter.formattedPrompt(prompt: "USR",
                                                             system: "SYS",
                                                             format: format)
        XCTAssertEqual(prompt,
                       "<|im_start|>system\nSYS<|im_end|>\n"
                       + "<|im_start|>user\nUSR<|im_end|>\n"
                       + "<|im_start|>assistant\n")
        // No LLaMA tokens may leak into a Qwen3 prompt.
        XCTAssertFalse(prompt.contains("<|begin_of_text|>"))
        XCTAssertFalse(prompt.contains("<|eot_id|>"))
    }

    // MARK: - Base-model hot-swap

    func testSwitchBaseModelRepointsInferenceAndDropsLoadedHandle() {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-swap-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let bus = MockObservabilityBus()
        let store = try! ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)

        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        XCTAssertEqual(interp.baseModelID, ModelCatalog.llama3_2_1B)

        interp.applyLoRA(ModelCatalog.intentNepali1B)
        interp.switchBaseModel(to: ModelCatalog.qwen3_4BInstruct)

        XCTAssertEqual(interp.baseModelID, ModelCatalog.qwen3_4BInstruct)
        // The LoRA belonged to the old base — a swap must not carry it.
        XCTAssertNil(interp.activeLoRAID)
    }
}
