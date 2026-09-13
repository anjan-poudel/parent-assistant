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

    // MARK: - Chat format per brain id (T-046)

    /// The framing T-046 DETERMINED for each catalog id the app can
    /// resolve, written out here independently of the production table so a
    /// silent edit to `LlamaCommandInterpreter.measuredFramings` fails this
    /// test instead of shipping.
    ///
    /// Provenance: `tools/train-intent/src/framing_check.py` scored every id
    /// under the LLaMA 3.2, Qwen3 `<|im_start|>` and raw no-chat-template
    /// framings against the held-out golden corpus through the app's own
    /// decode grammar; the per-row outcomes and per-framing metrics are
    /// committed at `tools/train-intent/eval/framing_summary.json` /
    /// `framing_rows.jsonl`.
    ///
    /// Before T-046 every one of these ids was sent the LLaMA 3.2 scheme by
    /// the `default:` branch — except the two stock Qwen3 ids, which were the
    /// only ones the old two-case switch knew. The `.raw` ids are the
    /// Qwen3-derived fine-tunes that decode as trained on the bare prompt
    /// (`train_qlora.py` tokenizes the template with no chat-template wrap);
    /// `intentQwenS43` is the one fine-tune whose measurement put the Qwen3
    /// wrap ahead of the bare shape once the app's own decode grammar was in
    /// the loop, so its row is `.qwen3` — per id, from the check, not by
    /// family.
    private static let determinedFramings: [(ModelID, LlamaCommandInterpreter.ChatFormat.Kind)] = [
        (ModelCatalog.intentQwen4BS43, .raw),        // default brain, offered
        (ModelCatalog.intentQwenS43, .qwen3),        // offered, measured wrap
        (ModelCatalog.qwen4BNepali, .raw),           // offered
        (ModelCatalog.qwen3_4BInstruct, .qwen3),     // offered (stock Qwen3)
        (ModelCatalog.qwen3_1_7BInstruct, .qwen3),   // offered (stock Qwen3)
        (ModelCatalog.intentNepali1B, .raw),         // hidden, stale pref
        (ModelCatalog.llama3_2_1B, .llama3),         // hidden legacy LLaMA
        (ModelCatalog.llama3_2_3B, .llama3)          // hidden legacy LLaMA
    ]

    /// Every OFFERED brain must carry a measured framing. An offered id with
    /// no determination FAILS here rather than silently inheriting
    /// `chatFormat(for:)`'s legacy fallback, and the failure names the id.
    func testEveryOfferedBrainHasAMeasuredChatFraming() {
        for entry in ModelCatalog.availableBrainEntries {
            guard let kind = LlamaCommandInterpreter.measuredFraming(for: entry.id) else {
                XCTFail("offered brain \(entry.id.rawValue) has no measured chat "
                        + "framing — record one in "
                        + "LlamaCommandInterpreter.measuredFramings before it is "
                        + "offered (evidence: "
                        + "tools/train-intent/src/framing_check.py)")
                continue
            }
            XCTAssertEqual(LlamaCommandInterpreter.chatFormat(for: entry.id).kind, kind,
                           "offered brain \(entry.id.rawValue) must speak its "
                           + "measured scheme, not the default branch")
        }
        // The determination table covers exactly the offered brains plus the
        // hidden ones a stale stored preference can still resolve — no
        // offered id may be missing from it.
        let offered = Set(ModelCatalog.availableBrainEntries.map(\.id))
        let determinedOffered = Set(Self.determinedFramings.map { $0.0 })
        XCTAssertTrue(offered.isSubset(of: determinedOffered),
                      "offered brains missing from the determination: "
                      + offered.subtracting(determinedOffered)
                        .map(\.rawValue).sorted().joined(separator: ", "))
    }

    /// The production table matches the determination written down above,
    /// per id, with the offending id named on failure.
    func testMeasuredChatFramingMatchesTheDeterminationPerId() {
        for (id, kind) in Self.determinedFramings {
            XCTAssertEqual(LlamaCommandInterpreter.measuredFraming(for: id), kind,
                           "\(id.rawValue): measured framing drifted from the "
                           + "T-046 determination — re-run "
                           + "tools/train-intent/src/framing_check.py before "
                           + "changing it")
            XCTAssertEqual(LlamaCommandInterpreter.chatFormat(for: id).kind, kind,
                           "\(id.rawValue) must speak the determined scheme")
        }
        XCTAssertEqual(ModelCatalog.availableBrainEntries.count,
                       Self.determinedFramings.filter { offeredIDs.contains($0.0) }.count,
                       "the determination table and the picker list disagree")
    }

    private let offeredIDs: Set<ModelID> = Set(ModelCatalog.availableBrainEntries.map(\.id))

    /// Byte-level pin per determined id: each scheme renders its own bytes
    /// and no other scheme's special tokens leak in. The `.raw` ids must
    /// render the prompt ALONE — no system turn, no wrapper — which is what
    /// `train_qlora.py` trained on.
    func testEveryDeterminedIdRendersItsOwnSchemeOnly() {
        for (id, kind) in Self.determinedFramings {
            let format = LlamaCommandInterpreter.chatFormat(for: id)
            let rendered = LlamaCommandInterpreter.formattedPrompt(
                prompt: "USR", system: "SYS", format: format)
            let context = "\(id.rawValue) (\(kind))"
            switch kind {
            case .raw:
                XCTAssertEqual(rendered, "USR",
                               "\(context) must send the bare prompt")
                for token in ["<|begin_of_text|>", "<|eot_id|>",
                              "<|im_start|>", "<|im_end|>"] {
                    XCTAssertFalse(rendered.contains(token),
                                   "\(context) must not carry \(token)")
                }
                XCTAssertEqual(format.systemPrefix, "",
                               "\(context) must not open a system turn")
                XCTAssertEqual(format.userPrefix, "",
                               "\(context) must not wrap the user turn")
                XCTAssertEqual(format.botPrefix, "",
                               "\(context) must not open a bot turn")
                // The fine-tunes were taught to emit the family EOS after
                // the JSON label; the stop sequence stays explicit rather
                // than empty (inert on the constrained decode path, load-
                // bearing for any streaming path).
                XCTAssertEqual(format.stopSequence, "<|endoftext|>",
                               "\(context) must keep the trained terminator")
            case .llama3:
                XCTAssertTrue(rendered.hasPrefix("\n<|begin_of_text|>"),
                              "\(context) must keep the shipped LLaMA literal")
                XCTAssertFalse(rendered.contains("<|im_start|>"),
                               "\(context) must not carry Qwen3 tokens")
                XCTAssertEqual(format.stopSequence, "<|eot_id|>",
                               "\(context) stop token drifted")
                XCTAssertEqual(
                    format.systemPrefix,
                    "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n",
                    "\(context) system turn drifted")
                XCTAssertEqual(format.botPrefix,
                               "<|start_header_id|>assistant<|end_header_id|>\n\n",
                               "\(context) bot turn drifted")
            case .qwen3:
                XCTAssertTrue(rendered.hasPrefix("<|im_start|>system\n"),
                              "\(context) must follow the official Qwen3 template")
                XCTAssertFalse(rendered.contains("<|begin_of_text|>"),
                               "\(context) must not carry LLaMA tokens")
                XCTAssertFalse(rendered.contains("<|eot_id|>"),
                               "\(context) must not carry LLaMA tokens")
                XCTAssertEqual(format.stopSequence, "<|im_end|>",
                               "\(context) stop token drifted")
                XCTAssertEqual(format.systemPrefix, "<|im_start|>system\n",
                               "\(context) system turn drifted")
                XCTAssertEqual(format.systemSuffix, "<|im_end|>\n",
                               "\(context) system turn drifted")
                XCTAssertEqual(format.botPrefix, "<|im_start|>assistant\n",
                               "\(context) bot turn drifted")
            }
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
