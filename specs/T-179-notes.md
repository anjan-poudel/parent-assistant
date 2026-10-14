# T-179 — Four-layer chat corpus pipeline with spec-driven filters and teacher GEC (implement notes)

**Status: implemented; scoped suites green (126/126 + 42/42 style-spec cross-check).**
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`, HEAD `95354ef7`). Declared files only.

| File | Role |
|---|---|
| `tools/train-intent/src/build_chat_corpus.py` (2,294 lines, new) | the four-layer builder: source registry, layers L1–L4, spec-driven filters, held-out guard, teacher GEC, STT-noise stage, 70/30 mixture, dev/ship split, deterministic outputs, offline CLI |
| `tools/train-intent/tests/test_build_chat_corpus.py` (2,005 lines, new) | 126 unittest cases: units, registry/licence pins, held-out dedupe vectors, GEC stage, L2/L3/L4 pipelines, mixture, output contract, CLI end-to-end, the real fixtures, the unit spec's acceptance scenarios |

Inputs consumed (interfaces, never re-authored): `src/style_spec.py` +
`seeds/nepali-chat-style-spec` (the ONLY source of the honorific checker and
the AI-ism blacklist — `render_rules()` renders every prompt from it and the
filters execute `author_chat_golden.mechanical_review`, one rule / one source);
`eval/author_chat_golden.py` (`CHAT_GOLDEN_PATH`, `held_out_keys()`,
`mechanical_review()`, record builders); `src/pipeline_guards.py`
(`golden_keys`, `assert_not_golden_input`, exit codes, `write_json`);
`src/build_dataset.py` (`normalize` / `lossless_key`).

## How each acceptance criterion is executed

1. **Four layers represented and counted** — `SOURCE_REGISTRY` (18 entries:
   L1 5, L2 7, L3 1 generated, L4 5) drives `_stage_l1_l2` / `_stage_l3` /
   `_stage_l4`; every layer reports `candidates / admitted / selected /
   target / target_rationale`. The mixture is **70/30 conversation/claw-back**
   (`CONVERSATION_SHARE` 0.70, `CLAWBACK_SHARE` 0.30): the surplus side is
   sampled down (`assemble_mixture`, seeded), the scarce side anchors the
   total; **TARGET and ACHIEVED are both recorded** and the target is never
   changed at run time; an under-delivering layer is a `shortfalls` entry with
   a reason. Claw-back carries the STT-noised turns at the suite's existing
   rate (`mixture.stt_noised` 0.60; `STT_NOISE_RATE_DEFAULT`), with backends
   `none | recorded | hf | cli | auto`; the `recorded` backend applies ONLY
   recorded (clean → noisy) pairs when the clean text matches exactly; a
   variant is a NEW turn (`:noise` suffix, `clean_utterance` in its
   provenance, reply carried over with its GEC record); a no-op round trip is
   not added; an unavailable backend is recorded, never fabricated.
2. **Filters are the spec's machine checks and counted** —
   `apply_filters()` = `author_chat_golden.mechanical_review(reply, spec)`
   (violation class names `honorific_agreement`, `no_ai_isms`,
   `dangling_particle`, `devanagari_purity`, `sentence_shape` — the same
   function the held-out fixture is authored under) **plus** the pipeline
   length rule (floor 2 word tokens; ceiling ~512 tokens of turn content).
   Every rejection bumps `rejections[rule]`. The style-spec-as-single-source
   property is pinned two ways: every prompt embeds `render_rules()` (spec
   version/register/particle lexicon/budget/sentence shape/small talk/
   code-switch nouns/AI-ism ids + descriptions/persona), and a drift test
   asserts no spec lexicon entry (≥2 Devanagari chars) appears literally in
   the builder's own source.
3. **Every assistant turn teacher-GEC'd before admission** — `GecStage` runs
   over ALL kept candidates before the filters; content-hash cache
   `sha256(model \x00 spec_sha256 \x00 text)`, batches of 20, temperature
   **0.0** (the correction override of the config's generation temperature),
   call budget (default 2000) with `budget_exhausted`; a turn with no result
   is HELD (`gec_missing`), never admitted; the stage is resumable (a re-run
   replays from `gec-cache.jsonl` at 0 calls) and reports calls, cache hits,
   cache entries, token usage, transport and refusals.
4. **Held-out set protected at admission** — `HeldOutGuard` loads
   `author_chat_golden.held_out_keys()` VERBATIM (lossless keys of the 500
   held-out elder turns), the normalize-skeleton sets of the chat golden set
   and of `eval/golden_corpus.jsonl` + `eval/emergency_nearmiss.jsonl`, and a
   token-Jaccard near-duplicate pool (0.80 @ ≥4 tokens). Every candidate's
   user turn AND reply is checked; an exclusion is `held_out_user_turn` /
   `held_out_reply` / `held_out_eval_fixture`, counted under both `rejections`
   and `exclusions`. The guard STOPS the run (`BuildStopped`, CLI exit 3) if
   the chat set or the golden corpus cannot load — nothing is admitted
   unguarded. Per the dispatch, admission does **NOT** gate on
   `require_gate_fixture()`: the fixture's human review is pending, its keys
   protect either way, and eligibility is reported
   (`eligible_gate_fixture: false` + NOTE) in every run's counters.
   The chat golden fixture version is pinned in the tests and the counters:
   revision **83283663**, sha256
   **`8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1569fcb1519`**.
5. **Dev/ship separation is a first-class build parameter** — `--mix
   ship|dev`; each registry entry carries `admissibility`. CC BY-NC /
   research-gated sources (IndicDialogue, the call-center transcripts,
   DailyDialog, PersonaChat/ConvAI2, EmpatheticDialogues) are `dev` only:
   refused from the ship mix per row (`dev_only_source`, counted) and — for
   L2 — skipped BEFORE any translation or post-edit spend. The unclassified
   nepali-sft sets are refused from BOTH mixes (`unclassified_source`).
   `_write_outputs` asserts no dev-only source was admitted in the ship mix.
6. **Determinism** — seeded RNG, stable orderings, no wall-clock anywhere in
   the corpus/counters (the run record's only timestamp is inside the human
   spot-check record). Byte-identical dual runs and the modulo-`from_cache`
   resume identity are pinned by tests.

## The recorded deviation: the eval-fixture claw-back

Design-l1 §11.1 / FR-CNR-017 name `eval/golden_corpus.jsonl` and
`eval/emergency_nearmiss.jsonl` as L4 claw-back sources. Those files ARE the
suite's held-out eval set (`pipeline_guards.assert_not_golden_input`: "no
stage may be pointed at the eval set, whatever the reason"); training on them
would turn the emergency-recall / abstention gates into memorization checks.
The builder therefore:

* refuses both at **source level** (`held_out_eval_fixture_source`, counted
  per source, `refused` reason recorded) — every run;
* excludes their rows at **admission** (`held_out_eval_fixture`, counted);
* carries the retention function on the suite's existing training material
  (`intent_training` + `abstain_honesty` components);
* writes the deviation into every run's `deviations` with the design
  reference, the executed behaviour, and `fixture_sources_refused` /
  `fixture_rows_excluded` counts — never a silent note.

## Executed vs recorded (honesty record)

**A. Real-inventory run against this worktree (no network, no teacher calls):**

```
cd tools/train-intent
python3 src/build_chat_corpus.py --mix ship --run-id t179-local-inventory \
    --l3-target-turns 0 --noise-backend none
```

* exit **4** (`EXIT_FLOOR`: the run completed; 5 shortfalls recorded).
* ACHIEVED locally against the REAL source root: **L1 0, L2 0, L3 0, L4 0**
  (candidates/admitted/selected all 0). The locally present held-out fixtures
  loaded and executed: chat golden 500 turns / revision 83283663 / exact keys
  500; golden corpus + near-miss merged into the skeleton guard.
* refusals counted: `held_out_eval_fixture_source` 2,
  `unclassified_source` 2. Notes: **13 absent sources**, each named with its
  path — "recorded, not substituted (T-183 training-box item)", including the
  suite's own `data/teacher.jsonl`, `data/noised.jsonl`,
  `data/edge_cases.jsonl`.
* counters written to
  `tools/train-intent/build/chat-corpus/t179-local-inventory/ship/chat-corpus-counters.json`
  (counters = the run record; `build/` is gitignored).

**B. Pipeline-executed ACHIEVED counts (recorded/injected seams; asserted by
the tests — these are numbers RUN, not planned):** ship E2E with the recorded
teacher fixture: L1 1 admitted (Devanagari-Ecommerce), L2 1 admitted (Taskmaster
translated + post-edited, held at admission pending its human spot-check),
L3 110 admitted from 11 batches (usage 5,500 + 2,200), L4 3 admitted (teacher 2,
edge 1; `missing_reply` 1 counted); GEC 6 calls / 60 + 30 tokens / 1 cache
entry; mixture 7 conversation + 3 claw-back = **exactly 70/30**; corpus 10 rows
written. Dev mix: 4-row corpus while both post-edit batches are pending, 6 rows
after one spot-check; STT-noise with recorded pairs: 2 eligible, 1 variant,
rate 0.5 vs target 0.6.

**C. Recorded, not executed locally (T-183 training-box items):** the 13
absent source files (chat-sources/l1 ×3 named + l2 ×7 named sets, plus the
suite's 3 L4 files — two additional unclassified L1 sets are refused by
policy without path reads), the real teacher transports (gemini/openrouter),
the translation tier, and the piper→Whisper STT round trip (`hf`/`cli`
backends gate on host toolchains and are reported unavailable). Nothing was
downloaded and nothing substituted.

## Test results (exact commands)

1. `cd tools/train-intent && python3 -m unittest tests.test_build_chat_corpus`
   → `Ran 126 tests in 12.940s` — **OK** (exit 0). No network: the teacher,
   translator and noise seams are injected; the CLI E2E replays a recorded
   teacher fixture written by the test itself.
2. `python3 -m unittest tests.test_style_spec` (cross-check, must stay green)
   → `Ran 42 tests in 0.640s` — **OK**.
3. `python3 -m py_compile src/build_chat_corpus.py tests/test_build_chat_corpus.py`
   → clean.
4. `python3 src/build_chat_corpus.py --plan` → exit 0, prints the registry
   with licence / admissibility / present-absent / REFUSED lines, the tooling
   inputs, and "mixture: conversation 70% / claw-back 30%".
5. The local-inventory build above (exit 4, verified counters).

What the suite pins (highlights): registry licences + eval-fixture refusals;
spec-lexicon drift; filter rejection per rule on crafted turns (honorific
disagreement, banned AI-ism, under-floor fragment, over-budget particles,
dangling clitic, Latin, 3-sentence reply) AND the same texts getting the same
verdict from `author_chat_golden.mechanical_review`; the held-out guard's
exact/lossless, normalize-skeleton (en-dash vector) and near-duplicate
(jaccard) paths on both user turns and replies, plus its stop-on-missing
failure modes; the GEC batching/resume/budget/refusal/cache-key/usage; the L2
translation→post-edit→spot-check chain including every failure path
(unavailable / failing / short translation, failing post-edit, pending and
rejected batches, batch chunking at 20, the accept/reject CLI); L3 plan math
(11 classes, 11 calls at the target, 22 at 220), batch-id uniqueness, resume,
empty/failing classes, malformed turns; L4 accounting incl. `already_noised`
exclusion, recorded-pairs variants, no-op and failure paths; the mixture's
exact 70/30, surplus sampling, degenerate case and the no-rebalancing pin; the
output contract (file set, row schema, counters schema, byte-identical dual
runs, resume, GEC budget exhaustion, the `execute=False` dry run); the CLI
(`--plan`, offline replay E2E with byte-identical corpus + counters and exit 4,
missing-fixture stop with exit 3 and the stopped counters, usage errors);
the REAL fixtures (sha/revision/500 turns, `require_gate_fixture` refusing
while `HeldOutGuard.load` protects, real texts excluded, a real-guard build
rejecting fixture material); and the unit spec's 10 acceptance scenarios.

## Decisions and deviations

1. **Eval-fixture claw-back refusal** (above) — the one design deviation,
   recorded in every run's `deviations`, doubled by admission exclusions.
2. **No `require_gate_fixture()` gate at admission** — per the dispatch; the
   decision is itself recorded in the counters NOTE and tested (`load`
   succeeds, `require_gate_fixture` raises, `eligible_gate_fixture: false`).
   Verified against the real fixture: sha256 pinned, 500 keys.
3. **L2 post-edit is not cached** (GEC and L3 are the resumable stages): each
   build re-runs the post-edit calls, but the batch key (`source#NNNN`) is
   stable, so the human review record survives re-runs — pinned in the resume
   test (0 GEC calls / 0 regenerated L3 batches / 1 post-edit call re-run).
4. **Skeleton dedupe uses the suite's `normalize`** (`build_dataset.py`), the
   same function `pipeline_guards.golden_keys` reads — deliberately NOT
   re-implemented; its Mc-matra mangling is covered by the lossless exact
   layer and pinned with an en-dash vector.
5. **Builder edits made during this unit** (all inside the declared file):
   (a) STT-noise variants now extend `admitted` so the layer files and the
   per-source accounting match the per-layer counter bumps; (b) the `none`
   noise backend note distinguishes "disabled for this run" from
   "unavailable on this host"; (c) `_intent_candidates` carries
   `clean_utterance` into the row provenance so a suite-noised L4 turn's
   `user_turn_source` is self-contained (same field the 60% stage writes).
6. **`execute=False` is a dry counters run**: it skips the L1/L2 source reads
   and the L2/L3 teacher generation, but still reads/counts the L4 claw-back
   supply and GEC-corrects it (the quantity the dry run exists to measure).
   Documented as-is by test.
7. **Generated L3 has no file**, so it has no `counters.sources` entry (that
   list is the FILE-BACKED accounting); the layer is recorded in
   `layers.L3` + `stages.l3_generation`. Pinned by test.
8. A **rejected** L2 batch is counted under the held reason
   `pending_spot_check` (the admission check is `status != spot_checked`) and
   additionally listed under `rejected_batches`; both are reported.
9. **Declared files only; no commits, no pushes, no ai-sdd mutating commands.**
   The only artifacts outside the two declared files are the gitignored build
   output of the local-inventory run and this notes file.

## Open items

* The 13 absent source files are the T-183 execution items (the builder reads
  the documented JSONL interchange shapes and never downloads).
* Real teacher / translation tier / piper→Whisper round trip on the training
  box; the backends are pre-wired and reported per run.
* Human spot-check of every L2 post-edit batch (the pending gate), recorded
  through `record_spot_check` / `--record-spot-check` before those rows count
  toward the mixture.
* Human review of the chat golden set (T-178's pending gate); no builder
  change is needed when eligibility flips.
* T-180's manifest can consume `sources` (licences/admissibility/refused),
  `tooling`, `deviations`, `stages` and `held_out_guard` verbatim from
  `chat-corpus-counters.json`.
