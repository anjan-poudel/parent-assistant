# T-046 — Chat framing per offered brain id (EXPEDITE, production defect)

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/t046-chat-framing`
Branch: `worktree-t046-chat-framing` (base `840bcd7`; NOT merged, NOT pushed, NOT rebased)
Commits: `5104a0b` (per-id framing + raw scheme), `c83bd0a` (table to the measured
determination), `ca5d85d` + `ff9692a` (measurement evidence), `8b0e9a0` (routed follow-up T-051),
`42d7e0d` (these notes), `34af077` (merge helper). Every committed artifact is inside this worktree;
the only writes outside it were scratch: `/tmp/t046-*.py|sh` on this Mac and the model host's own
working directory `/mnt/nvme2/workspace/t046-chat-framing/` (models, per-run logs, row dumps) — no
other worktree and no other repository file was touched.

## 1. What was wrong, measured

`LlamaCommandInterpreter.chatFormat(for:)` switched on exactly the two stock Qwen3 ids and sent
everything else — including the shipped **default brain** `intentQwen4BS43` and the other
Qwen3-derived fine-tunes — through the LLaMA 3.2 `<|begin_of_text|>` wrapping, a scheme their
checkpoints were never trained on. The fine-tunes were trained on the bare prompt
(`tools/train-intent/src/train_qlora.py` `to_text`; the matching inference contract is stated in
`tools/train-intent/src/eval_golden.py`).

Reproduced on the golden corpus under the pre-fix framing, on the default brain
(`intent-ne-qwen4b-s43-q4km`, GGUF sha256 `5a296889…`):

| row | utterance (gold intent) | pre-fix `llama3` output | after `raw` |
|---|---|---|---|
| `gc-emergency-003` | "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" (`emergency`) | `{"intent": "guide", "response": "ठीक छ, म तपाईंलाई उठ्न सिकाउँछु।", …}` | `{"intent": "emergency", "response": "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ।", …}` |

An emergency plea was answered as a how-to. Aggregate for that id: pre-fix `llama3`
closed 0.941 / emergency 0.667 / 20 usable → `raw` 1.000 / 1.000 / 20 usable.

Note on safety: the LLM-independent keyword net, the router stage order and
`InputSanitiser.sanitise(.quarantine)` as the sole transcript entry (`LlamaCommandInterpreter.swift:444`,
FR-009 / NFR-013) were not touched, so the emergency *path* was never at the LLM's mercy — this was a
decode-quality defect, not a safety-gate defect.

## 2. How the determination was made (not a blind switch)

Harness: `tools/train-intent/src/framing_check.py` (new, 680 lines, committed in `5104a0b`) scores
each id under each candidate framing — LLaMA 3.2, Qwen3 `<|im_start|>`, raw no-template — against
`tools/train-intent/eval/golden_corpus.jsonl` through the app's own decode path: the
`commandJSONSchema` GBNF mirrored by `tools/train-intent/src/command_grammar.py`, per-family stop
strings, `INTENT_SCHEMA_STRICT=1`, `n_ctx 4096` with a per-row **runtime budget** (`--max-tokens 0`)
that mirrors the app's `LLM(from:maxTokenCount: 1024)` headroom. The `raw` renderer is
`{prompt}` only and ignores the system string, byte-matching the app's `.raw` case; the LLaMA and
Qwen3 renderers are byte-mirrors of `formattedPrompt`.

Applied rule (in `framing_determination.json` → `policy`, applied identically to every id):
reject a framing whose prompt overflows the 1,024-token runtime window (none did; max measured
prompt 838 tokens), then rank by **rows correct AND usable on device** (intent matches gold AND the
JSON parsed AND generation was not cut by the runtime budget), then emergency recall, then parse
rate, then smaller prompt. A tie keeps the incumbent. Scope: the app's own intent fine-tunes are
decided by the measurement; general-purpose brains are NOT (the corpus exercises only this app's
contract, which they were never trained on) — their measured rows are recorded in
`general_purpose_observations` and their publisher template stands.

Reproducing the verdicts: fetch the host's `out/summary-*.json` + `out/rows.jsonl` and run
`python3 tools/train-intent/src/framing_determination_merge.py <dir>` — re-running it over the
fetched evidence reproduces the three committed files with only the `generated_utc` stamp moving.

Run: model host `192.168.1.117`, harness `tools/train-intent/src/framing_check.py`, HF cache
`/storage/huggingface`, models under `/mnt/nvme2/workspace/t046-chat-framing/models`. Another
session's `train_qlora.py` job was on the GPU throughout (checked before each launch, never
signalled); the runs coexisted with it and completed with `EXIT=0`.

## 3. Per-id determination (all 9 ids the app can resolve, 3 framings, 20 rows = 540 measured rows)

`closed` = closed-intent accuracy, `em` = emergency recall, `parse` = JSON parse rate,
`usable` = rows correct-and-usable on device. Source: `tools/train-intent/eval/framing_summary.json`.

| id | offered | pre-fix | llama3 (closed/em/parse/usable) | qwen3 | raw | rule's required | shipped |
|---|---|---|---|---|---|---|---|
| `intentQwen4BS43` (default) | yes | llama3 | 0.941 / 0.667 / 1.000 / 20 | 0.941 / 1.000 / 0.950 / 19 | **1.000 / 1.000 / 1.000 / 20** | raw | **raw** (changed) |
| `intentQwenS43` | yes | llama3 | 0.529 / 0.667 / 0.650 / 13 | **0.647 / 1.000 / 0.650 / 13** | 0.471 / 0.333 / 0.500 / 10 | qwen3 | **qwen3** (changed) |
| `qwen4BNepali` | yes | llama3 | 0.412 / 1.000 / 0.400 / 8 | 0.412 / 0.667 / 0.400 / 8 | **0.706 / 0.667 / 0.700 / 13** | raw | **raw** (changed) |
| `intentNepali1B` (hidden, stale pref) | no | llama3 | 0.647 / 0.667 / 0.900 / 18 | 0.765 / 0.667 / 0.950 / 19 | **0.882 / 1.000 / 1.000 / 20** | raw | **raw** (changed) |
| `qwen3_4BInstruct` (stock) | yes | qwen3 | 0.824 / 1.000 / 0.900 / 18 | **0.824 / 0.667 / 0.950 / 19** | 0.882 / 0.667 / 0.950 / 19 | raw | qwen3 (unchanged, general-purpose) |
| `qwen3_1_7BInstruct` (stock) | yes | qwen3 | 0.059 / 0.000 / 0.100 / 2 | 0.235 / 0.000 / 0.300 / 6 | 0.353 / 0.667 / 0.450 / 9 | raw | qwen3 (unchanged, general-purpose) |
| `llama3_2_1B` (legacy) | no | llama3 | 0.353 / 0.000 / 0.650 / 13 | 0.353 / 0.000 / 0.700 / 14 | 0.588 / 0.000 / 1.000 / 20 | raw | llama3 (unchanged, general-purpose) |
| `llama3_2_3B` (legacy) | no | llama3 | 0.647 / 0.667 / 0.950 / 19 | **0.824 / 1.000 / 0.950 / 19** | 0.765 / 0.667 / 1.000 / 20 | qwen3 | llama3 (unchanged, general-purpose) |
| `intentGemma1B` (hidden) | no | llama3 | 0.706 / 0.667 / 0.900 / 18 | 0.706 / 0.333 / 0.850 / 17 | 0.765 / 0.667 / 0.850 / 17 | raw | llama3 (fallback — template not expressible) |

Provenance per id (entry comments): `ModelCatalog.swift:503-522` `llama3_2_1B`; `524-546`
`intentNepali1B`; `548-570` `intentQwen4BS43`; `572-594` `intentQwenS43`; `596-618` `intentGemma1B`;
`620-632` `llama3_2_3B`; `634-650` `qwen3_1_7BInstruct`; `652-667` `qwen3_4BInstruct`; `669-694`
`qwen4BNepali`. Model artifact sha256 values are in `framing_determination.json` per id.

Row-level evidence for the changed ids:
- `intentQwenS43` pre-fix: `gc-emergency-003` ran to `gen=209` and was cut by the runtime budget
  (`runtime_truncated=true`, pred `none`); under `qwen3` it is `emergency` in 138 tokens. That
  truncation is what made the pre-fix emergency recall 0.667.
- `qwen4BNepali` pre-fix: 12 of 20 rows wrong, of which 8 are runtime truncations; under `raw`
  6 of 20 wrong, 7 truncations. Its one emergency miss (`gc-emergency-001`, `raw`, `gen=377`) is a
  truncation, not a misclassification — recorded as such rather than papered over.
- `intentNepali1B`'s Qwen3 leg was missing in the first pass; it was measured afterwards
  (`ff9692a`) precisely because the id shares the shipped default's lineage and could have flipped
  the verdict. It did not: raw still ranks first on correct-and-usable rows.

## 4. Files changed

- `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift`
  - `ChatFormat` + `Kind` (`llama3` / `qwen3` / `raw`): 474-495; `formattedPrompt` 620-641;
  - `measuredFramings` table 529-540, `measuredFraming(for:)` 545-547, `chatFormat(for:)` 559-561,
    `chatFormat(kind:)` 565-611;
  - call sites unchanged in shape: `Self.chatFormat(for: preferredBaseId)` at 724 (the `Template`
    handed to `LLM(from:)`) and at 794, where it feeds `Self.formattedPrompt(...)` at 803 →
    `generateWithConstraints`;
  - **untouched**: `chatSystemPrompt` 347, `LLM(from:…)` 732-739 (`maxTokenCount: 1024` at 739),
    keyword net, router order, `InputSanitiser.sanitise(.quarantine)` 444.
- `ios/ElderlyAssistantTests/Services/Voice/BrainModelSelectionTests.swift`: the old
  two-case `testChatFormatIsQwen3OnlyForTheQwen3Brain` was replaced by an independent per-id
  determination pin (125-134) plus `testEveryOfferedBrainHasAMeasuredChatFraming` (139-162),
  `testMeasuredChatFramingMatchesTheDeterminationPerId` (166-179) and
  `testEveryDeterminedIdRendersItsOwnSchemeOnly` (187-218). The byte-identity tests for LLaMA
  (220-234) and Qwen3 (236-248) still pass. 9 → 11 test funcs. No assertion was deleted, skipped,
  commented out or weakened; the replaced assertion pinned `intentNepali1B` to llama3, which the
  measurement contradicted, so it was updated to the evidenced framing in the same change (the
  replacement is strictly stronger: it covers every resolvable id, byte-level, not one line).
- `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift`: per-id framing comments
  (`llama3_2_1B` 508-513, `intentNepali1B` 533-538, `intentQwen4BS43` 558-562, `intentQwenS43`
  580-586 with the measured numbers, `qwen4BNepali` 677-682); `intentGemma1B` and the
  general-purpose stock entries carry no framing comment because their framing did not change;
  curated list untouched.
- `tools/train-intent/src/framing_check.py` (new; renderers, per-row runner, summariser,
  `PRE_FIX_FRAMING`, `required_framing`) and `tools/train-intent/src/framing_determination_merge.py`
  (new; the committed merge that produces the three files below).
- `tools/train-intent/eval/framing_summary.json`, `framing_rows.jsonl` (540 rows),
  `framing_determination.json` (policy, per-id ranking keys, shipped framing + reason, `source_lines`
  evidence spans, `general_purpose_observations`).
- `.ai-sdd/outputs/plan-tasks/tasks/TG-03-on-device-ai/T-051-…md` + index row (routed follow-up).
- `specs/T-046-notes.md` (this file).

## 5. Regression tests

`BrainModelSelectionTests` now asserts: every offered brain has a measured framing (an offered id
without one fails *and names the id*); the production table matches the independently written
determination per id; each determined id renders only its own scheme's bytes (`.raw` renders the
bare prompt with no `<|begin_of_text|>` / `<|eot_id|>` / `<|im_start|>` / `<|im_end|>` and no system
turn); LLaMA 3.2 stays byte-identical to the shipped literal; Qwen3 follows the official template.
Framing is additive to integration coverage — the runtime path itself is exercised by
`QueryEndToEndRegressionTests` against the same `chatFormat(for:)`.

## 6. Gate

`./ios/build.sh test:unit` from the worktree, at `c83bd0a` (the last commit that touches Swift):

```
result: Passed
totalTestCount: 2695   passedTests: 2689   failedTests: 0   skippedTests: 6
expectedFailures: 0
```

xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.09.13_10-55-16-+1000.xcresult`
(`xcrun xcresulttool get test-results summary --path …` → the block above). The earlier run at
`5104a0b` (`Test-ElderlyAssistant-2026.09.13_09-29-20-+1000.xcresult`) is identical.

Reconciliation with the expected 2693: 2695 executed − the 2 net new tests = 2693; passed 2689 +
skipped 6 = 2695. The 6 skips are runtime-gated smoke/probe/alarm tests in files this task never
touched (`AlarmSchedulingBackendTests`, `WakeWordUserRecordingProbeTests`, `SherpaTTSEngineSmokeTests`,
`WakeWordAcousticSmokeTests`) and are identical across both runs. Commits `ca5d85d`…`ff9692a` add only
JSON/Markdown, so the gate above covers the final tree.

Two earlier gate attempts failed environmentally and were fixed inside the worktree, not by touching
anything outside: (a) xcodegen needed the standard worktree symlinks for large resources, and then
`installd` rejected those symlinks inside the built `.app` — replaced with real copies in this
worktree only; (b) another worktree's `xcodebuild` was using the same simulator (crash "signal kill
before establishing connection") — the gate was re-run after that run drained.

## 7. Paired review — NOT OBTAINED

No agent-spawn tool exists in this session, and the ai-sdd CLI exposes no review verb
(`ai-sdd --help`: run/status/approve/reject/complete-task/validate-config/init/hil). **An independent
`sdd-reviewer` verdict was therefore not obtained** — no approval is assumed here. What was done
instead: an adversarial self-pass over the diff, which verified that the harness's `raw` renderer
ignores the system turn exactly like the app's `.raw` case (so the measured numbers describe the
shipped bytes), that the LLaMA/Qwen3 renderers mirror `formattedPrompt` byte-for-byte, that the
harness's own `required_framing` helper differs from the local one only in helper code (the
measurement code that produced the rows is byte-identical to what is committed), that no
`XCTSkip`/`XCTExpectFailure` was introduced, and that the safety paths are untouched. That is a
self-check, not a challenger.

## 8. Disk

Free space on `/System/Volumes/Data` moved 1.7 GiB (start) → 2.6 → 5.1 → 11 → 25 → 27 → 34 → 29 →
**6.4 GiB** by the end (other sessions' builds grew meanwhile). No ENOSPC; the gate ran. This
worktree's `ios/build` is 4.5 GB; nothing was deleted outside the worktree.

## 9. Not done / open

- **Not merged, not pushed** (per instruction); `git status` clean on the branch.
- **Gemma 3** needs its own `<start_of_turn>` template, which `ChatFormat`'s fixed three-role layout
  cannot express → routed as **T-051** with file:line evidence; the id is hidden and not offered.
- **General-purpose brains** measured better under other framings in several rows (table above) but
  were deliberately not changed: the intent corpus cannot certify a template change for models that
  never saw that contract. Recorded in `general_purpose_observations`, scope handed to T-051.
- **Harness fidelity**: the eval harness samples with temp 0, repeatPenalty 1.05 (qwen) / 1.0 (others),
  n_ctx 4096 and a per-row runtime budget, while the app uses temp 0 / topK 40 / topP 0.95 /
  repeatPenalty 1.2 / `maxTokenCount: 1024`. Within-harness comparisons are the accepted evidence
  basis; the harness numbers are not device numbers, and the digit-looping truncations may be
  overstated relative to the device.
- **T-047** (catalogue comment reconciliation) consumes this task's outcome and remains open.
