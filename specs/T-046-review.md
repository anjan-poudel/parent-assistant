# T-046 — Paired Review (challenger)

- Reviewer: `sdd-reviewer` subagent (read-only), orchestrated by the main session
- Reviewed revisions: `840bcd7..acc4619` (9 commits) on `worktree-t046-chat-framing`
- Verdict: **GO** — Confidence **0.88**, conditional on the record amendments below
  (no rework of the code change required)
- Orchestrator note: I independently reproduced both [MAJOR] findings, the headline
  defect row and the disputed truncation counts before routing the fix round
  (see "Orchestrator reproduction"). The reviewer left the worktree clean; the
  reviewer's record is preserved verbatim in its per-claim wording below.

## Per-claim verdicts

- **1. Defect real, fix addresses it — SUPPORTED.** Base `840bcd7` `chatFormat(for:)`
  switches on exactly the two stock Qwen3 ids; every other id — including the shipped
  default `intentQwen4BS43` (verified) — fell to the LLaMA 3.2 branch. Reproduced from
  `framing_rows.jsonl`: default id / `llama3` / `gc-emergency-003` → pred `guide`;
  same row under `raw` → pred `emergency`. Verbatim match to the notes' table.
- **2. Determination measured, not asserted — SUPPORTED.** 540 rows = 9 ids × 3 framings
  × 20 corpus rows, all unique on (id, framing, row_id); gold/slot fields consistent with
  `golden_corpus.jsonl`. Reviewer recomputed every summary metric from the raw rows:
  **0 mismatches** across all 27 (id, framing) cells (including `per_intent`); all 9
  `ranking` arrays and every `keys` tuple under `usable_first_key` reproduce exactly.
  Renderers mirror `formattedPrompt` byte-for-byte. Embedded digests verify locally:
  `corpus_sha256` = `golden_corpus.jsonl`, `template_sha256` = `seeds/prompt_template.txt`,
  `swift_source_sha256` = the Swift file at `840bcd7`.
- **3. Rule override — VERIFIED, ACCEPTABLE with stated residual risk.** The two rules
  disagree on exactly three ids (gemma, qwen3-4b-nepali, stock qwen3-4b). Shipped winners
  agree with the applied rule for every fine-tune decision except `qwen4BNepali`
  (safety-first → llama3, applied → raw). Row-level facts reproduce: llama3 emergency 3/3,
  raw 2/3 with `gc-emergency-001` pred `none`, gen=377, `runtime_truncated=true`,
  `parsed=false`; wrong rows 12 → 6. Judgment: the override is acceptable — the
  pre-registered rule and the deviation's rationale are both committed (policy field,
  `framing_determination_merge.py:64-83`), and emergency routing is keyword-gated upstream
  of the LLM, so an LLM-level emergency miss was never a safety-gate failure. Residual
  risk: the user-selectable `qwen4BNepali` brain carries one truncation-prone emergency row
  under raw that llama3 decoded correctly, mitigated by 13 vs 8 usable rows and the keyword net.
- **4. No safety regression — VERIFIED.** Every `+`/`-` line in `840bcd7..HEAD` searched for
  sanitise/quarantine/keyword/maxTokenCount/chatSystemPrompt: only Markdown hits, zero Swift.
  The two Swift hunks are additive; unmapped ids keep the byte-identical `.llama3` fallback.
  `InputSanitiser.sanitise(.quarantine)` remains the sole transcript entry; the `.raw`
  stop-sequence choice is inert as claimed (`generateWithConstraints` never consults the
  Template's stop sequence).
- **5. Tests — STRONGER IN NET, with one honest caveat.** No `XCTSkip`/`XCTExpectFailure`
  anywhere; 9 → 11 test funcs (matches the gate arithmetic). Every-offered-id coverage,
  per-id table pin against an independently written determination, id-naming failures and
  per-scheme byte pins all present. Caveat (MINOR): the old test's exact
  `systemPrefix`/`stopSequence` assertions were dropped in the rewrite without a
  contradicting determination.
- **6. General-purpose scope + T-051 routing — SUPPORTED.** Scope reasoning stated in four
  places; all five general-purpose ids carry `general_purpose_observations` with
  `measured_best` vs `shipped` and rationale. T-051 file:line citations verified correct.
- **7. Gate — VERIFIED, not re-run.** xcresult summary: result Passed, total 2695,
  passed 2689, failed 0, skipped 6, expectedFailures 0; the 6 skips are the pre-existing
  smoke/probe/alarm tests; 2689 − 2 net new = 2687 master baseline.

## Findings (as routed)

- [MAJOR] **The default brain's evidence was measured on the wrong quant.** The catalog
  ships `intent-ne-qwen4b-s43-q3_k_m.gguf` (`ModelCatalog.swift:564-565`, v15 Q3_K_M —
  what the device downloads), but the harness mapped the id to
  `intent-ne-qwen4b-s43-q4_k_m.gguf` (`framing_check.py:98`) and
  `framing_determination.json` records that Q4 file + its digest. No "q3"/"Q3" appears
  anywhere in `framing_check.py`, `framing_summary.json`, `framing_determination.json`,
  or `specs/T-046-notes.md` — the mismatch is undisclosed. The `.raw` verdict itself is
  still sound (bare-template training is quant-independent; the catalog's own grammar-off
  gates for the Q3 artifact were produced through `eval_golden.py`'s bare-prompt contract),
  but the record's headline numbers for the most consequential id describe an artifact the
  device does not run. **Fix: amend the record — disclose, or re-measure the Q3 on the
  model host.** Re-measurement is feasible (see Orchestrator reproduction 1).
- [MAJOR] **The two app-faithful harness modules are not committed.** `framing_check.py:82-91`
  imports `intent_prompt.py` and `command_grammar.py`; neither exists in the repo (search
  over worktree and main checkout). `specs/T-046-notes.md:41` cites the grammar module at
  repo path `tools/train-intent/src/command_grammar.py` where no file exists; the grammar
  fingerprint and the exact rendered prompts cannot be regenerated from the repo. The script
  fails honestly without them (`framing_check.py:590`), but "re-runnable by a reviewer" holds
  only on the model host. Also `specs/T-046-notes.md:42` cites `INTENT_SCHEMA_STRICT=1`,
  which appears in no committed code. **Fix: commit the modules with the harness, or amend
  the record to mark them host-only.**
- [MINOR] Policy text says the primary key is "rows correct AND usable", but
  `usable_first_key` (`framing_determination_merge.py:188-199`) implements
  `closed_acc × rows_usable_on_device` — a product, not the literal count. Winners are
  identical under both readings; the text overstates precision.
- [MINOR] `framing_check.py:459-496` docstring says an overflowing framing is
  "disqualified outright" but implements it as a soft key component (equivalent here —
  zero overflow rows).
- [MINOR] Dead line at `framing_determination_merge.py:189`.
- [MINOR] The old test's exact `systemPrefix`/`stopSequence` assertions were dropped in the
  rewrite: `stopSequence` is unasserted for all schemes and `systemPrefix` only for `.raw`.
- [MINOR] Latent inconsistency for `.raw`: the Template handed to `LLM(from:)`
  (`LlamaCommandInterpreter.swift:725-731`) would still render systemPrompt+user on any
  future `respond(to:)` path — the "no system turn" invariant holds only in
  `formattedPrompt`. Inert today; add a comment.
- [MINOR] `specs/T-046-notes.md:92` says the `qwen4BNepali` llama3 leg had "8 runtime
  truncations"; the row data says **11** (reproduced by the orchestrator, see below).
- [MINOR] T-051 line-range drift: the Gemma entry is cited as "596-611" but ends at 617.
- [MINOR] llama.cpp reports `generated = headroom + 1` on 17 rows; the harness's
  `generated >= headroom` flag handles it conservatively and the notes' "truncations may be
  overstated" caveat covers the direction.

## Orchestrator reproduction (independent of the reviewer)

1. **Q3/Q4 mismatch — reproduced and scoped.** `ModelCatalog.swift:564-565` ships
   `intent-ne-qwen4b-s43-q3_k_m.gguf` (sha `c48e94d0…`, 2,075,616,032 bytes, v15 release
   URL); `framing_check.py:98` maps the id to the Q4 file; the determination records the Q4
   filename and sha prefix `5a29688902f1`; `grep -ci q3` is 0 in the harness, summary,
   determination and notes. Added evidence the reviewer did not have: the catalog's own
   comment for this id points the reader to "the T-046 framing record for this checkpoint's
   app-faithful numbers" (`ModelCatalog.swift:556-560`) — a pointer to numbers measured on a
   different quant than the artifact the entry ships. **Scope is exactly one id**: I compared
   every `MODEL_FILES` value against the catalog's shipped filename; the other 8 ids match.
   The host's `intent-ne-qwen3-4b-nepali-q3_k_m.gguf` is an unused artifact — the catalog
   ships the Q4 for `qwen4BNepali` (sha `eb5ce805…`). **Re-measurement is feasible**: the
   shipped Q3 artifact already sits on the model host
   (`…/tools/train-intent/models/intent-ne-qwen4b-s43-q3_k_m.gguf`, byte size equals the
   catalog's `sizeBytes`), so the 3-framing × 20-row pass can be re-run against it.
2. **Uncommitted harness modules — reproduced.** `intent_prompt.py` and `command_grammar.py`
   exist only on the model host under the T-046 scratch tree; no repo copy exists anywhere.
   `INTENT_SCHEMA_STRICT` appears in no committed file.
3. **Headline defect row — reproduced.** Default id, `gc-emergency-003`: `llama3` → pred
   `guide` (gen 134, not truncated); `raw` and `qwen3` → pred `emergency`.
4. **Disputed truncation counts — reproduced, reviewer is right.** Recount from
   `framing_rows.jsonl` for `qwen4BNepali`: `llama3` 12 wrong / 11 truncated (12 total
   truncated); `raw` 6 wrong / 4 truncated (7 total truncated). The notes' "8" matches
   neither and is a stale number; "7" matches raw's total.
5. **Gate arithmetic — spot-checked**: xcresult totals are as quoted (2695/2689/0/6).
6. **Reviewer hygiene**: nothing was modified in the worktree or main checkout by the review.

## Could not verify

- Model file digests (models live on the model host, not in the repo).
- GBNF grammar bytes / exact rendered prompts (host-only modules).
- Whether a Q4_K_M artifact of the default brain is even published — the catalog URL only
  serves Q3; the measured Q4 file's provenance is host-side.
- The iOS gate was read from its xcresult, not re-run.

## Routed fix round (record amendments; no code rework required)

1. [MAJOR] Disclose or re-measure the shipped Q3 for `intent-ne-qwen4b-s43-q4km`; if not
   re-measured, the disclosure must be explicit in `specs/T-046-notes.md`, the catalog
   comment, and the determination/summary metadata (e.g. `measured_quant` next to
   `model_file`).
2. [MAJOR] Commit `intent_prompt.py` + `command_grammar.py` with the harness, or mark them
   host-only in the notes and stop citing them as repo paths; drop or implement
   `INTENT_SCHEMA_STRICT=1`.
3. [MINOR] Notes truncation counts: "8" → 11 (llama3 leg).
4. [MINOR] Policy text vs `usable_first_key` (`closed_acc × rows_usable_on_device`).
5. [MINOR] Docstring "disqualified outright" at `framing_check.py:459-496`.
6. [MINOR] Dead line `framing_determination_merge.py:189`.
7. [MINOR] Restore or consciously retire the dropped `stopSequence`/`systemPrefix` pins.
8. [MINOR] Comment the `.raw` Template latent inconsistency.
9. [MINOR] T-051 Gemma line range 596-611 → 617.
