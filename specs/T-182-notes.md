# T-182 notes — Chat-variant config and the full ship gate over one candidate

Unit: T-182 (TG-37, v17 chat-aware training suite), depends on T-179/T-180/T-181.
Feature: conversational-nepali-replies (CNR); branch `feat/conversational-nepali-replies`;
worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`.
Design references: `specs/design-l1.md` §11.3 (variant config) / §11.4 (report) / §11.5 (run layout).
No network or billed calls were made anywhere in this unit (judge transport `fixture` only).

## What was built

### 1. `tools/train-intent/config.yaml` (+66/-0, purely additive; 218 lines)

One new top-level `chat:` section, 15 leaf keys, nothing else:

| key | value |
|---|---|
| `chat.enabled` | `false` (the variant is OFF in the checked-in config) |
| `chat.run_id` | `v17` |
| `chat.mix` | `ship` |
| `chat.corpus_root` | `build/chat-corpus` |
| `chat.mixture.conversation_share` | `0.70` |
| `chat.mixture.clawback_share` | `0.30` |
| `chat.layers.L1` | 3 source paths (indic_dialogue_ne, call_center_transcripts, devanagari_ecommerce) |
| `chat.layers.L2` | 7 source paths (dailydialog, personachat_convai2, empathetic_dialogues, taskmaster, soda, prosocial_dialog, oasst1) |
| `chat.layers.L3` | `[]` (teacher-generated; no file input) |
| `chat.layers.L4` | 3 source paths (data/teacher.jsonl, data/noised.jsonl, data/edge_cases.jsonl) |
| `chat.filters.spec_checks` | the 5 mechanical-review check names |
| `chat.filters.min_word_tokens` | `2` |
| `chat.filters.turn_token_ceiling` | `512` |
| `chat.filters.held_out_dedupe` | `true` |
| `chat.filters.near_duplicate_jaccard` | `0.80` |

No existing key or default changed: the flat non-chat configuration digest (64 keys,
sha256 over canonical JSON) is pinned in the tests as `0fcf33a1b24a3b9f393861e9223e2dc02b37adeed6ee5dad3532b211c19ddc1a`,
and the top-level section list is unchanged (8 sections). The fixed recipe constants
(r=16, alpha=32, lr 1.5e-4 inside the 1e-4..2e-4 band, epochs=3, max_seq_len=1024,
export Q4_K_M) are pinned; a deviation is detected as a variant check failure, not a knob.

### 2. `tools/train-intent/src/eval_golden.py` (+1382/-157; 2127 lines)

The full ship gate, orchestrated (never re-implemented) over the other units' interfaces:

* **Variant reader** (`chat_variant_config`): reads the variant FROM THE CONFIGURATION —
  a flag can never select it. Flag absent or false returns `None` and the legacy path runs
  unchanged. Flag true resolves run id, mix, corpus root, run/corpus directory layout
  (design §11.5), mixture, layer paths (resolved against the suite root, existence flagged
  per path), filters, and the provenance manifest path through T-179's own
  `build_chat_corpus.manifest_path_for` (`provenance-manifest.json` for ship,
  `provenance-manifest.<mix>.json` otherwise). Every missing, unknown or malformed key is
  a refusal naming it; the section must be complete before anything runs.
* **Fixed-constants checks**: `recipe_check` (the QLoRA recipe numbers above),
  `mixture_check` (70/30 against T-179's `CONVERSATION_SHARE`/`CLAWBACK_SHARE`),
  `filters_check` (spec_check names against `author_chat_golden.mechanical_review`'s
  emittable set plus the builder's `MIN_ASSISTANT_WORD_TOKENS=2`, `TURN_TOKEN_CEILING=512`,
  `NEAR_DUP_JACCARD=0.80`). A deviating key becomes `verdict.checks_failed` (exit 1) with
  the deviation named — no threshold or recorded number is ever moved.
* **Chat gates**: imported from T-181's `eval_chat_gates` (`evaluate`, judge wiring,
  `JudgeJournal`, `ChatGateRefusal`); thresholds come from the style spec via
  `thresholds_from_spec` (>=0.98 honorific, >=0.98 no-ai-isms, >=4.0 judge mean). The
  existing hard-gate harness is called through its own functions; `tests/test_eval_golden_gates.py`
  was not touched.
* **Latency**: replays `measure_device.py`'s own loader and scorer over recorded rows
  (`--device-measurements`/`--device-prompts`, pooled nearest-rank percentiles); gates
  1000.0 ms / 2000.0 ms over the 100-prompt floor; the tier name (`--tier`,
  `--tier-platform`, `---tier-device`, `--tier-os`, `--tier-build`) is required and is
  carried on the calibration and latency gate rows.
* **Provenance evidence**: reads the T-180 manifest and INDEPENDENTLY recomputes
  `content_hash` (canonical JSON minus hash fields), then cross-checks mix vs configured
  mix, corpus sha256 vs the file on disk, and `ship_mix_eligible`.
* **ONE report + ONE invocation**: `--full-gates` produces a single
  `full_gate_report/v1` JSON row on `--gate-report` plus a human summary on stdout.
  Every gate row carries value, threshold, denominator, status, tier where applicable,
  and (chat gates) fixture + artifact provenance; the report records fixture versions
  (style spec, golden corpus, chat golden, emergency near-miss, config sha256), the
  candidate artifact sha256, the provenance manifest hash, the named tier, the judge
  transport + scores hash + resume counts, and what the run spent (judge calls this run /
  reused / failed, hard-gate rows, chat turns, device rows, elapsed seconds).
* **Exit contract**: 0 = all gates green, checks pass, ship mix, complete evidence;
  1 = a red gate / not-measured gate / failed check / incomplete evidence / non-ship mix;
  2 = refusal before scoring (`no evidence report is written for a refusal`; no report
  file, no ledger row, results.csv byte-untouched).
* **Byte-identity**: with the flag absent or false nothing in the legacy path changes —
  no config path or digest leaks into stdout, no chat key is read.

### 3. `tools/train-intent/tests/test_eval_golden_chat_variant.py` (new; 1486 lines)

80 test methods in 10 classes, all offline:

* `ChatSectionStaticTests` (7): additive-only config pins (15 keys, 64-key non-chat digest,
  top-level sections, recipe constants, gate inventory/exit codes/report schema).
* `ChatVariantReaderTests` (19): flag absent/false inert; flag true resolves everything from
  the file (incl. the builder's manifest naming for ship and dev); 13 pinned refusals.
* `VariantChecksTests` (7): the three checks pass on the real config; each deviation class
  (recipe/lr/epochs+quant, mixture shares, dropped + unknown spec checks, length + dedupe
  numbers) is detected with the key named.
* `LegacyByteIdentityTests` (2): three legacy runs (repo config, chat-stripped copy,
  chat-enabled copy) — stdout bytes and results.csv bytes pairwise identical, one ledger
  row `byte-identity@<corpus_tag>,...,none`, committed ledgers never written.
* `HappyPathTests` (13): exit 0; one report row; every gate green with value/threshold/
  denominator; gate inventory exactly the pinned 14; identity (candidate sha256, fixture
  versions, provenance manifest hash recomputed independently); tier naming; variant
  recorded from the config; checks pass; judge `fixture` transport with `billed: False`
  under `spend.judge` and 500 calls; `spend` fields; determinism of the deterministic
  checks block; swap eligible; stdout GREEN lines; a cross-check that `measure_device.py`'s
  own CLI over the same files produces identical p50/p95/n.
* `ReproducibilityTests` (1): two invocations, identical gate results.
* `RedGateTests` (9): honorific 489/500 = 0.978 < 0.98; judge 3.9 < 4.0; hard emergency
  recall 0.5 < 1.0; latency p50 1200 > 1000 with p95 1500 green; the 1000.0-ms boundary
  passes; recipe/mixture/filters deviations fail checks not gates; dev mix is never swap
  evidence even all-green.
* `IncompleteEvidenceTests` (12): missing / tampered / malformed / hash-less manifest,
  ship-ineligible, corpus-sha mismatch, mix mismatch; artifact identity gone (chat gates
  not measured, judge `not_run`, hard gates still measured); latency absent / prompt set
  absent / partial pairs / below floor — each exit 1, report written and marked incomplete
  with the reason, swap ineligible.
* `RefusalTests` (9): flag disabled; missing tier/report/outputs/artifact/scores flags;
  ineligible fixture; malformed and unknown-id measurements — each exit 2 with the pinned
  stderr message, no report file, ledger bytes untouched.
* `JournalResumeTests` (1): 500 calls first run, 0 calls / 500 reused second run, swap
  still eligible.

The synthetic inputs are built through `author_chat_golden`'s own record builders (the
pattern of `tests/test_eval_chat_gates.py`), and the provenance manifest hashes are
computed by an independent implementation of the T-180 scope, so schema drift breaks the
tests instead of silently splitting the format. Child processes run with `GEMINI_API_KEY`
removed from the environment.

## Unit gate (per the wave cadence: compile-level only)

Executed, from `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/tools/train-intent`:

1. `python3 -m py_compile src/eval_golden.py tests/test_eval_golden_chat_variant.py`
   -> exit 0 (run twice: before and after the one test-module fix below).
2. Config-parse check (harness loader, fresh parser per call): `config.yaml` loads with
   exactly the 15 `chat.*` keys; the flat 64-key non-chat digest equals the pinned
   `0fcf33a1...`; the flag off resolves to `None`; the flag on resolves run_id `v17`,
   mix `ship`, manifest name `provenance-manifest.json`.

The authored suite was NOT executed in-unit. Per the amendment-4 cadence the coordinator
runs the one consolidated scoped Python pass at wave close; that pass is the first
execution of `tests/test_eval_golden_chat_variant.py`.

## Verification executed meanwhile (ad-hoc, recorded honestly)

Beyond the unit gate, and strictly offline:

1. Happy-path smoke (single CLI invocation): exit 0, all gates green, report written.
2. A 22-case behavioural sweep (ad-hoc script; tmp inputs persist) covering the exit-code
   matrix, red/not-measured/refusal/incomplete semantics, exact reason strings, ledger
   row behaviour, and journal resume (500 then 0 calls / 500 reused).
3. A pin check (~200 assertions) over the persisted sweep reports plus fresh CLI runs,
   verifying EVERY exact string and key path the new test module hard-codes: the happy
   report blocks (harness, gates, provenance recompute, judge, spend, tier, fixtures),
   the red cases, all incomplete reasons, journal spend, stdout formats
   (`GREEN <gate>`, `RED <gate>`, `swap eligible: True`, shortfall text, `CHECK FAILED
   recipe`, `INCOMPLETE`, `evidence report appended`), and the refusal write-nothing
   contract. It also ran four fresh CLI cases for paths the sweep had missed:
   a `content_hash`-less manifest (status `no_content_hash`, exit 1), prompts omitted with
   measurements present (`no prompt set supplied`, gates not measured), a filters deviation
   end-to-end (`checks_failed: ["filters"]`), and the refusal stdout/stderr formats.
   Result: all green.
4. Legacy byte-identity probe mirroring `LegacyByteIdentityTests` exactly: three runs
   (repo config / chat-stripped / chat-enabled) exit 0, stdout and results.csv bytes
   identical across all three, no `chat` substring in stdout, exactly one ledger row
   `byte-identity@9d932959,...,none`, committed `eval/results.csv` and the baseline fixture
   untouched.
5. `measure_device.py` CLI cross-check: the exact command the cross-check test issues
   exits 0 with p50 250.0 / p95 300.0 / n 200 / `gates_failed` `none`, matching the
   harness report's latency rows.

One defect was found in the test module during pin checking and fixed: it asserted a
`billed` key inside the judge block; the report records `billed` only under
`spend.judge` (the judge block carries transport/model/temperature/scores hash). The
assertion was removed; `spend.judge.billed is False` remains pinned twice. `py_compile`
was re-run green after that edit.

No invocation anywhere in this unit used a judge transport other than `fixture`; no
network or billed call was made.

## Red-gate / incomplete-evidence behaviour (as shipped and pinned)

* Red gate: exit 1, the gate and its shortfall named on stdout and in
  `verdict.shortfalls`; thresholds unmoved (0.978 < 0.98, 3.9 < 4.0, 0.5 < 1.0,
  1200 > 1000 ms); all other gates are still measured over the same candidate in the same
  invocation; swap ineligible. The ledger row is still appended (the run happened);
  refusals never touch the ledger.
* Incomplete evidence: the report is still written, marked `incomplete: {complete: false,
  reasons: [...]}` with every reason (missing/displaced manifest; tampered hash with the
  recomputed value recorded; unreadable; missing `content_hash`; `ship_mix_eligible=false`;
  corpus sha mismatch; manifest mix vs configured mix; artifact identity gone; latency
  absent / partial / below the 100-prompt floor), exit 1, and swap ineligible — an
  incomplete report cannot serve as swap evidence.
* A dev-mix run is complete evidence *about a non-ship run*: exit 1 with swap ineligible
  and the reason stated; it is not marked incomplete.
* Refusals (exit 2) happen before scoring and write nothing anywhere.

## Files changed

* `tools/train-intent/config.yaml` (+66/-0)
* `tools/train-intent/src/eval_golden.py` (+1382/-157)
* `tools/train-intent/tests/test_eval_golden_chat_variant.py` (new, 1486 lines)
* `specs/T-182-notes.md` (this file)

Nothing else in the worktree was touched by this unit. (The `ios/tools` modifications
visible in `git status` belong to the parallel unit T-185; they were not touched here.)

## Decisions and deviations

1. Chat gate thresholds are read from the style spec through T-181's
   `thresholds_from_spec`; the mechanical review and judge scoring are imported, never
   re-implemented. `tests/test_eval_golden_gates.py` is untouched.
2. The judge stage in every test/ad-hoc run is T-181's offline `fixture` replay
   (records the same call/reuse/failure counters as the billed transport, `billed: False`).
   The first real billed judge run over the human-reviewed fixture remains a later,
   owner-gated step of the feature; nothing in T-182 requires or performs it.
3. Latency evidence semantics: absent measurements mark the gates `not_measured` and the
   report incomplete (device evidence for the reference tier is simply not present on the
   dev host), while a measurements file that cannot be scored (malformed JSON, ids not in
   the prompt set) is REFUSED before scoring (exit 2) — a broken file is an input error,
   not absent evidence. The harness replays `measure_device.py`'s own loader/scorer
   (single implementation, cross-checked against that tool's CLI).
4. The 100-prompt floor is enforced in the harness too (a 50-prompt set is a partial
   measurement -> not measured); the percentile is nearest-rank and inclusive at the gate
   (exactly 1000.0 ms passes; 1000.1 does not).
5. The `billed` fact is recorded once, under `spend.judge`; the judge block records the
   transport, model, temperature, prompt/rubric hashes and the resume counters.
6. Mix-mismatched manifests are still validated as documents (hash verified, status
   `verified`) and refused by the cross-check; the report records both facts.

## Open items

* The authored test suite runs for the first time in the coordinator's consolidated
  scoped pass; every pinned string/value was pre-verified against live runs as above, and
  the one mismatch found that way was fixed in-unit.
* Real human-reviewed fixtures and real device measurements on the reference tier are
  T-183/T-188/T-189 inputs, not T-182 test material; the tests build schema-true synthetic
  inputs instead.
* `chat.enabled: false` ships as the checked-in default — the variant is inert until a
  run's config (or the training box's config) turns it on.

## Wave-close rework (consolidated pass, first real execution of the suite)

The coordinator's 8-module consolidated pass ran the authored suite for the first time:
480 tests, 7 reds in 2 groups, both in this unit's declared files. Both are fixed; three
more test-side defects surfaced by the first execution were fixed in the same pass.

### Root cause A (test-side): the run-layout directories were never created

`GateInputs.__init__` wrote the ship corpus file at
`<tmp>/build/chat-corpus/v17/ship/chat-corpus-ship.jsonl` without creating the parents
(6 setUpClass errors: HappyPathTests, IncompleteEvidenceTests, JournalResumeTests,
RedGateTests, RefusalTests, ReproducibilityTests). The earlier ad-hoc tests had created
the directories explicitly, which is why the in-unit probes never saw it.

Fix: `_write_jsonl` and `_write_manifest` now `path.parent.mkdir(parents=True,
exist_ok=True)` before every write; every other seeded target (fixture, candidate
artifact, outputs, scores, prompts, measurements, gate report, ledger copies) is written
under the already-existing tmp root. The layout itself is unchanged (design §11.5 paths
stay pinned by the resolver tests).

### Root cause B (impl-side): a legacy Path crash before the ledger row — NOT the gates_failed helper

The coordinator's named suspect (the legacy `gates_failed` helper / ledger assembly) was
not where the defect lived. Base-vs-current evidence:

* Base built the per-intent counters as `defaultdict(int)` and the legacy print loop read
  `per_intent_correct[intent]` straight off the defaultdict, so an intent with zero
  correct rows auto-read 0 (base lines 679-680, 792-793).
* The refactor moved the counters into `hard_gate_metrics`, which returned them as plain
  dicts (`dict(per_intent_correct)`). That strips the auto-read: `per_intent_correct` has
  no key for an intent whose rows were ALL wrong.
* The `preds_abstention_fail` fixture has exactly such an intent (`query`: 0/1). The
  legacy print loop (`c = m["per_intent_correct"][intent]`, line 2079) then raised
  `KeyError: 'query'`, killing the process BEFORE `hard_gate_failures` and
  `_append_results_row` executed. The results.csv contained only the copied baseline row;
  the `'none'` the failing test read was the BASELINE's `gates_failed`, and the exit 1
  was the interpreter crash, not a gate failure. That is why "the process still exits 1"
  and "the recorded list is wrong" appeared together — the run never recorded its own row.
* The legacy `gates_failed` computation itself is byte-equivalent to base (verified by
  diff: same gate/threshold table, same order, same calibration/gemini appends).

Fix (mechanism-level, not fixture-specific): the returned map now covers every intent of
`per_intent_total` with a 0 default —
`{intent: per_intent_correct.get(intent, 0) for intent in per_intent_total}` — restoring
base's defaultdict read semantics for every consumer (the only direct-index consumer is
the legacy print loop; the full-gate row builders already used `.get`). Manual
confirmation on the originally failing fixture: exit 1, empty stderr, `query 0/1` printed,
`GATES FAILED: ['abstention_precision']` printed, ledger row
`fx-abstention_fail@9d932959,1.000,1.000,1.000,1.000,1.000,abstention_precision`. A diff
of the only other `defaultdict` region (the coverage helper) against base shows a
docstring addition and no logic change.

Note for the record: the in-unit "legacy byte-identity probe" compared current-vs-current
configs, so it was structurally blind to base drift; the pre-existing module is the base
witness, and it is green again.

### Two further test-side defects (found by the first real execution)

1. `HappyPathTests.setUpClass` stored the happy run as `cls.run`, shadowing unittest's
   `TestCase.run` — the runner crashed with `TypeError: 'GateRun' object is not callable`.
   Renamed to `cls.gate_result` (attribute not reserved by unittest).
2. `GateInputs.gate()`'s `golden` parameter defaulted to `None`, but in that helper `None`
   means "leave the flag off": every invocation without an explicit fixture fell back to
   the repo placeholder `eval/chat_golden.jsonl` (ineligible, 50 pending batches) and
   refused. Fixed to the `"default"` sentinel, matching `artifact`/`outputs`/`scores`.

### Rework run verdicts (single-module runs per the recorded narrow exception)

* `python3 -m unittest tests.test_eval_golden_gates` — run 1: Ran 35, OK; run 2: Ran 35,
  OK (both after the impl fix; this module is the legacy base-behaviour checklist).
* `python3 -m unittest tests.test_eval_golden_chat_variant` — run 1: Ran 80, OK (18.4s);
  run 2: Ran 80, OK (19.0s).
* `python3 -m py_compile src/eval_golden.py tests/test_eval_golden_chat_variant.py` after
  the impl fix — exit 0.
* Before the `golden` sentinel fix, the first chat-module execution showed 27 failures /
  11 errors — all traced to the placeholder-fixture fallback plus the `cls.run` crash;
  no behavioural defect in the harness itself was found by that run.

Files touched in the rework: `tools/train-intent/src/eval_golden.py` (root cause B fix),
`tools/train-intent/tests/test_eval_golden_chat_variant.py` (root cause A + the two
further fixes), `specs/T-182-notes.md` (this section). The other 6 modules were not run;
the coordinator re-runs the full consolidated pass for the wave verdict.
