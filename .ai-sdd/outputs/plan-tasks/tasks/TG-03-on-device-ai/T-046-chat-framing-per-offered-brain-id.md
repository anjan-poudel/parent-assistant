# T-046: Chat framing per offered brain id

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** LlamaCommandInterpreter (chat format + prompt construction, Services/Voice), ModelCatalog brain entries (Services/ModelStore)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH — EXPEDITE (production defect; the default brain is prompted with the wrong scheme)
- **Depends on:** —
- **Blocks:** [T-047](T-047-catalogue-comment-reconciliation.md)
- **Requirements:** FR-007, FR-008, NFR-002

## Description

`LlamaCommandInterpreter.chatFormat(for:)` (ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift:490-515) switches on exactly two ids — `ModelCatalog.qwen3_1_7BInstruct` (ModelCatalog.swift:161) and `ModelCatalog.qwen3_4BInstruct` (ModelCatalog.swift:165), both mapped to the Qwen3 `<|im_start|>` scheme (switch case at LlamaCommandInterpreter.swift:492) — while every other id falls to `default:` (LlamaCommandInterpreter.swift:503-514), the LLaMA 3.2 `<|begin_of_text|>`/`<|eot_id|>` framing that the function's own doc comment calls "gibberish" to Qwen models (LlamaCommandInterpreter.swift:486-489). Two Qwen3-derived brains offered in the picker therefore run on the LLaMA scheme today:

- `intentQwenS43` (id ModelCatalog.swift:175; entry 533-548) — the Qwen3-1.7B QLoRA v14 slim-template seed-43 fine-tune, first `availableBrainEntries` element (ModelCatalog.swift:793-798, position 794) and the app's default brain (`AppCoordinator.defaultBrainModelID`, AppCoordinator.swift:1170);
- `qwen4BNepali` (id ModelCatalog.swift:168; entry 622-641) — the assembled Qwen3-4B Nepali model (extended Devanagari tokenizer + SFT LoRA merged + CPT embedding restore, entry comment ModelCatalog.swift:626-630), offered at ModelCatalog.swift:795.

The same default branch frames the hidden v12 `intentNepali1B` (id ModelCatalog.swift:172; entry 516-532), which a stale stored preference can still resolve (`resolvedBrainModelID`, AppCoordinator.swift:1176-1179) and which the existing unit test pins to the LLaMA scheme (BrainModelSelectionTests.swift:104 at `2061566`).

Nothing in the runtime has ever checked framing against what the models were trained on. The fine-tunes were trained on raw text: `tools/train-intent/src/train_qlora.py:45-58` builds training text from `seeds/prompt_template.txt` plus the JSON label plus the family EOS with no chat-template wrap, and `tools/train-intent/src/eval_golden.py:120-126` states the matching inference contract explicitly ("never pass the prompt through a chat template here"); `IntentPrompt.swift:44-55` declares the training/inference prompt-identity requirement a hard requirement. At runtime the prompt is instead rendered through `chatFormat(for:)` in two places: the `Template` passed to `LLM(from:)` (LlamaCommandInterpreter.swift:620-627) and the manually built string passed to `generateWithConstraints` (`formattedPrompt`, LlamaCommandInterpreter.swift:522-537; call site 699-703).

This task determines, with measured evidence, which framing each offered brain id actually requires; fixes the ids the evidence shows are wrong; leaves ids whose framing is proven correct byte-identical; and pins all of it with a regression test covering every offered id.

## Acceptance criteria

```gherkin
Feature: Chat framing per offered brain id

  Scenario: The wrong framing is reproduced for every mis-framed offered id
    Given chatFormat(for:) sends every id except the two stock Qwen3 ids to the LLaMA 3.2 branch (LlamaCommandInterpreter.swift:492, 503-514)
    And the running prompt is built from that format (formattedPrompt, LlamaCommandInterpreter.swift:522-537, used at 690-703)
    When the offline framing check runs each offered id (availableBrainEntries, ModelCatalog.swift:793-798) under the framing the runtime chooses today
    Then for every id whose framing is wrong the check reproduces the wrong-framing failure on the project's own golden corpus (tools/train-intent/eval/golden_corpus.jsonl) or an equivalent pinned probe set, with the failing outputs recorded
    And the failure is reproduced for intentQwenS43 and qwen4BNepali — the two Qwen3-derived ids currently sent the LLaMA scheme — before any fix is made

  Scenario: Every offered brain id's required framing is determined with evidence
    Given the candidate framings: LLaMA 3.2 (LlamaCommandInterpreter.swift:503-514), Qwen3 <|im_start|> (492-502), and the raw no-chat-template shape the models were trained on (train_qlora.py:45-58; eval_golden.py:120-126)
    When the check scores each offered id under each candidate framing
    Then the record states, per id — intentQwenS43, qwen4BNepali, qwen3_4BInstruct, qwen3_1_7BInstruct — the required framing, the measured evidence, and the model provenance (entry comments ModelCatalog.swift:537-541, 626-630, 591-595, 609-612)
    And intentNepali1B is recorded as its own row because a stored preference can still resolve it (AppCoordinator.swift:1176-1179)
    And the record states what each id needs even where no change is required

  Scenario: The fix proves itself fixed
    Given the wrong framing for the mis-framed ids is reproduced and recorded
    When chatFormat(for:) is corrected for the ids the evidence names
    Then the offline check is re-run on the same ids and inputs and shows the corrected framing meeting the recorded bar where the old framing failed
    And the check script and its result table are committed with the task so a reviewer can re-run them

  Scenario: Regression test covers every offered brain id
    Given the existing chat-format test covers only the two stock Qwen3 ids and pins intentNepali1B to the LLaMA scheme (BrainModelSelectionTests.swift:96-111 at 2061566)
    When the regression test is extended
    Then it iterates ModelCatalog.availableBrainEntries and asserts the determined format for every offered id
    And an offered id with no determined framing fails the test instead of silently inheriting the default branch
    And a failure names the offending id in its message

  Scenario: Ids whose framing is proven correct are not changed
    Given an id whose current framing passes the offline check
    When the fix lands
    Then chatFormat(for:) returns byte-identical ChatFormat values for that id
    And the byte-identity tests still pass (BrainModelSelectionTests.swift:113-127 and 129-143 at 2061566)
    And if intentNepali1B is shown mis-framed, its pinned expectation is updated to the evidenced framing rather than weakened or skipped

  Scenario: No framing change can degrade the safety path
    Given the keyword safety net is the LLM-independent emergency backstop (FR-009)
    And the golden corpus carries the emergency rows and gates recorded in docs/OPEN-ITEMS.md:88-108
    When the framing determination and fix land
    Then the check records emergency-row outcomes under the old and the new framing per id
    And no change touches the keyword net, the router stage order, or InputSanitiser.sanitise(.quarantine) as the sole transcript entry into the prompt (LlamaCommandInterpreter.swift:444)

  Scenario: An unfixable framing requirement is routed, not hacked
    Given the check finds an id needs a framing the current ChatFormat shape cannot express, or a framing that overflows the 1,024-token context (LlamaCommandInterpreter.swift:635; IntentPrompt.swift:76-84)
    When the result is recorded
    Then the required runtime design change is filed as its own task with file:line evidence
    And the id is not left silently on a framing the evidence rejects
```

## Implementation notes

- Determination is per id and evidence-first. For each candidate framing, score the id against `tools/train-intent/eval/golden_corpus.jsonl` through the existing GGUF eval path (`eval_golden.py:120-157`, including its per-family stop strings) and record per-row outcomes and the failure mode. The check runs on the model host where that harness lives; it is not an iOS build.
- Reproduce-then-fix: run the check under today's `chatFormat(for:)` output first, record the failing outputs for `intentQwenS43` and `qwen4BNepali`, then change the framing and re-run the identical check. Commit the script + result table.
- Offered ids and entries at master `2061566`: `intentQwenS43` 175 / 533-548; `qwen4BNepali` 168 / 622-641; `qwen3_1_7BInstruct` 161 / 587-604; `qwen3_4BInstruct` 165 / 605-621. Curated list: `availableBrainEntries` 793-798.
- Hidden-but-resolvable ids to record: `intentNepali1B` 172 / 516-532 (same Qwen3-1.7B lineage as `intentQwenS43`; still resolvable via `resolvedBrainModelID` 1176-1179). The hidden legacy ids `llama3_2_1B` (158 / 498-515) and `llama3_2_3B` (182) may legitimately keep the LLaMA scheme; their rows belong in the record for completeness.
- Context budget: the runtime creates the LLM with a 1,024-token context (LlamaCommandInterpreter.swift:635) and the `IntentPrompt` template is pinned at 696 qwen3 / 677 gemma tokens (IntentPrompt.swift:76-84). The check records prompt token counts per framing and rejects a framing that overflows the window.
- Regression test: extend `testChatFormatIsQwen3OnlyForTheQwen3Brain` (BrainModelSelectionTests.swift:96-111 at `2061566`; 100-115 at `d31c4be`) into a per-offered-id mapping driven by the determination table; keep `testLlama3FormattedPromptIsByteIdenticalToShippedLiteral` (113-127 at `2061566`) and `testQwen3FormattedPromptFollowsOfficialChatTemplate` (129-143 at `2061566`) passing.
- No assertion may be weakened, skipped (`XCTSkip` / `XCTExpectFailure`), commented out or deleted; a determination that contradicts an existing assertion updates the assertion to the evidenced behaviour in the same change.
- Safety: do not alter the keyword net, the router stage order, or `InputSanitiser.sanitise(.quarantine)` as the sole transcript entry (LlamaCommandInterpreter.swift:444; NFR-013). No transcript or entity value may reach observability output (NFR-016).
- iOS-only: no Android counterpart exists — a search for `ModelCatalog`, `availableBrainEntries`, `defaultBrainModelID` and chat-format code across `android/` returns nothing (only Gradle `org.jetbrains` strings match a model-name search) — so this is a single iOS task with no platform split.
- T-047 depends on this task and reconciles the catalogue comments afterwards, so any comment edits that record the per-id framing requirement land here first.

## Definition of done
- [ ] Per-id framing determination recorded with measured evidence and file:line provenance, explicitly including `intentQwenS43`, `qwen4BNepali`, `intentNepali1B` and both stock Qwen3 ids
- [ ] Wrong framing for the mis-framed offered ids reproduced before the fix, and the same check proves the fix after
- [ ] `chatFormat(for:)` corrected for every id the evidence names, including `intentNepali1B` when the check shows it is mis-framed; byte-identical output preserved for ids proven correct
- [ ] Regression test iterates every `availableBrainEntries` id and fails on an offered id with no recorded framing
- [ ] Prompt token counts per framing recorded against the 1,024-token context
- [ ] Emergency-row outcomes recorded under old vs new framing; keyword net, router order and quarantine sanitisation untouched (FR-009, NFR-013)
- [ ] Check script + result table committed/attached; no new PII in observability output (NFR-016)
- [ ] Code reviewed and merged
