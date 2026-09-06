import XCTest
@testable import ElderlyAssistant

/// Brain selectability (2026-09-06): the picker's catalog surface, the
/// per-model chat formats, and the interpreter's base-model hot-swap.
final class BrainModelSelectionTests: XCTestCase {

    // MARK: - Catalog surface

    func testAvailableBrainEntriesListsEveryRealBrainArtifact() {
        XCTAssertEqual(ModelCatalog.availableBrainEntries.map(\.id),
                       [ModelCatalog.llama3_2_1B,
                        ModelCatalog.llama3_2_3B,
                        ModelCatalog.qwen3_1_7BInstruct,
                        ModelCatalog.qwen3_4BInstruct])
        // The fine-tune placeholder must never be selectable: its URLs
        // are `.invalid` stubs and nothing could fetch it.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains { $0.id == ModelCatalog.intentNepali1B })
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
