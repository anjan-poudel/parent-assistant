# T-051: Gemma 3 chat template kind + general-purpose framing audit

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** `LlamaCommandInterpreter.ChatFormat` (kinds + `formattedPrompt`), `ModelCatalog.intentGemma1B`, general-purpose brain ids
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-046](T-046-chat-framing-per-offered-brain-id.md)
- **Blocks:** —
- **Requirements:** FR-007, FR-008

## Description

T-046 measured every catalog id the app can resolve under the three framings
`ChatFormat` can express (LLaMA 3.2, Qwen3 `<|im_start|>`, raw) and shipped a
per-id table (`LlamaCommandInterpreter.measuredFramings`,
`LlamaCommandInterpreter.swift:529-540`). Two findings from that measurement
could not be acted on inside T-046 and are routed here.

**(1) Gemma 3's template is a fourth scheme `ChatFormat` cannot express.**
The Gemma intent fine-tune is a real hosted artifact (`intentGemma1B`
`ModelCatalog.swift:185`, entry 596-611, GGUF arch `gemma3` per the entry
comment at 606) but it is hidden because it fails the emergency hard gate. Its
reference template is `<bos><start_of_turn>user\n{…}<end_of_turn>\n<start_of_turn>model\n`
— system content has no turn of its own and must be folded into the FIRST user
turn. `ChatFormat` (`LlamaCommandInterpreter.swift:474-495`) is a fixed
three-role layout (`systemPrefix`/`systemSuffix`, `userPrefix`/`userSuffix`,
`botPrefix`/`botSuffix`, 488-494) and its composition (`formattedPrompt`,
613+) emits one turn per role, so the fold has no representation. Today the id
falls to `measuredFramings[id] ?? .llama3` (`chatFormat(for:)`, 559-561) and is
scored under LLaMA 3.2 bytes its checkpoint never saw.

T-046's rows for this id (`tools/train-intent/eval/framing_summary.json`,
`ids."intent-ne-gemma-q4km"`; verdict row in
`framing_determination.json` `general_purpose_observations`):

| framing | closed intent | emergency recall | JSON parse | usable rows |
|---|---|---|---|---|
| llama3 (shipped fallback) | 0.706 | 0.667 | 0.900 | 18 |
| qwen3 | 0.706 | 0.333 | 0.850 | 17 |
| raw | 0.765 | 0.667 | 0.850 | 17 |

None of the three is the model's own template, so none of these numbers can
certify the id: the correct next step is to ADD a `.gemma3` kind that renders
the reference template, extend `tools/train-intent/src/framing_check.py` with
that renderer (`MODEL_FILES` line 96, `PROVENANCE` 132 — the id is already
mapped there; the harness has `LLAMA3`/`QWEN3`/`RAW` renderers and no Gemma
one), and re-measure all four framings before any decision. Because the id is
hidden and gate-failing, offering it remains out of scope; the deliverable is
the representable framing + the measurement, so a future decision is made on
evidence.

**(2) The intent corpus cannot decide a framing for general-purpose brains.**
The same run re-framed the five general-purpose ids (stock Qwen3 4B/1.7B,
legacy LLaMA 1B/3B, Gemma 1B) and several measured BETTER under a framing other
than the one they ship, e.g. `llama-3.2-3b-instruct-q4km` closed 0.647 →
0.824 under qwen3; `qwen3-4b-instruct-2507-q4km` emergency 3/3 under llama3 vs
2/3 under qwen3; `llama-3.2-1b-instruct-q4km` closed 0.353 → 0.588 and parse
0.650 → 1.000 under raw. T-046 deliberately did NOT act on these: the golden
corpus only exercises this app's own intent contract (20 synthetic rows,
`tools/train-intent/eval/golden_corpus.jsonl`), which these checkpoints were
never trained on, so a corpus win does not certify a template change for
free-form device utterances. Every such row is recorded, not applied, in
`framing_determination.json` → `general_purpose_observations`. This task owns
the follow-up: decide these ids against an evaluation that actually models
their use (general Nepali utterances / the recognition contract), or record an
explicit Open Decision that their publisher template stands.

**What this task must NOT do.** It must not weaken the keyword safety net, the
router stage order, or the `InputSanitiser.sanitise(.quarantine)` sole-entry
rule (`LlamaCommandInterpreter.swift:444`; FR-009, NFR-013), and it must not
change any assertion by deletion or skip — where a determination contradicts a
pinned assertion, the assertion is updated to the evidenced behaviour in the
same change (the rule T-046 followed).

## Acceptance criteria

```gherkin
Feature: The two framing findings T-046 could not act on are closed with evidence

  Scenario: Gemma 3's own template becomes expressible
    Given intentGemma1B is a real hosted GGUF with arch gemma3 (ModelCatalog.swift:185, 596-611)
    And ChatFormat's fixed three-role layout (LlamaCommandInterpreter.swift:474-495, composition 613+) cannot fold system+user into one turn
    When the .gemma3 (or equivalently named) kind is added
    Then chatFormat(kind:) (565-611) renders the model's reference template byte-for-byte, including the fold of the system content into the first user turn
    And a unit test pins those bytes and asserts no LLaMA or Qwen3 special token leaks in, in the style of BrainModelSelectionTests.testEveryDeterminedIdRendersItsOwnSchemeOnly

  Scenario: The Gemma id's framing is decided by measurement, not by fallback
    Given the harness has no Gemma renderer today (tools/train-intent/src/framing_check.py; MODEL_FILES 96, PROVENANCE 132)
    When framing_check.py gains the reference-template renderer and is re-run for intent-ne-gemma-q4km across all four framings
    Then the per-row outcomes, prompt token counts and metrics are committed beside the T-046 tables (tools/train-intent/eval/)
    And measuredFramings (LlamaCommandInterpreter.swift:529-540) records the measured verdict for the id — or the record states why the measurement is inconclusive and the id stays hidden

  Scenario: The general-purpose ids are decided on an evaluation that fits them
    Given T-046 recorded, without applying, every case where a general-purpose id scored better under another framing (framing_determination.json → general_purpose_observations)
    When their framing is revisited
    Then the decision either names an evaluation that models those ids (not the 20-row intent corpus) and applies its verdict
    Or it records an explicit Open Decision in constitution.md §Open Decisions with an owner and a trigger
    And in both cases no silent template change and no undocumented divergence remains

  Scenario: No safety or safety-adjacent assertion is touched
    Given FR-009 keeps safety paths independent of the LLM and T-046 pinned the keyword net, the router stage order and the quarantine sole-entry rule (LlamaCommandInterpreter.swift:444)
    When this task lands
    Then none of those paths changes
    And no test assertion is deleted, skipped or commented out; where a determination contradicts a pinned assertion, that assertion is updated to the evidenced behaviour in the same change

  Scenario: The evidence is re-runnable by a reviewer
    Given T-046 committed tools/train-intent/src/framing_check.py and its result tables
    When this task's measurement is committed
    Then the harness invocation (model host, model file, grammar mode, max-tokens policy) is recorded with the results
    And no PII, secret or token appears in code, logs, tests or artifacts (NFR-016)
```

## Implementation notes

- Start from the T-046 record: `tools/train-intent/src/framing_check.py` (renderers, `MODEL_FILES`, `PROVENANCE`, `summarise`), `tools/train-intent/eval/framing_summary.json`, `framing_rows.jsonl`, `framing_determination.json` (policy + `general_purpose_observations`), and the per-id table at `LlamaCommandInterpreter.swift:529-540`.
- The T-046 harness runs on the model host over SSH; per-row evidence is in `framing_rows.jsonl` keyed by `(id, framing, row_id)`. Re-use that path rather than adding a second harness.
- ChatFormat's role affixes are pure data (474-495) but the fold is a composition concern — expect the new kind to need a branch in `formattedPrompt` (613+), not only a new `chatFormat(kind:)` case. Keep `LlamaCommandInterpreter` free of LLM package types.
- Sampling-fidelity caveat carried from T-046: the harness uses repeatPenalty 1.05 (qwen) / 1.0 (others) n_ctx 4096 and a per-row runtime-generation budget, while the app uses temp 0 / topK 40 / topP 0.95 / repeatPenalty 1.2 / `LLM(from:maxTokenCount: 1024)`. Within-harness comparisons are the accepted evidence basis; do not restate harness numbers as device numbers.
- Android: no chat-format code exists under `android/`; if that changes, the same kind table applies there.

## Definition of done
- [ ] `.gemma3` (or equivalent) kind added with byte-pinned unit tests and no cross-family token leakage
- [ ] Gemma id re-measured across all four framings on the model host; rows and metrics committed under tools/train-intent/eval/
- [ ] `measuredFramings` records the measured verdict for the Gemma id, or the inconclusive measurement is stated in the committed record
- [ ] General-purpose framing question resolved: an appropriate evaluation applied, or an explicit Open Decision with owner + trigger
- [ ] Keyword net, router stage order and quarantine sole-entry rule untouched; no assertion weakened, skipped or deleted
- [ ] Harness invocation recorded; no PII/secrets in any artifact (NFR-016)
