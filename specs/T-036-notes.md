# T-036 — Encoder Training & Distillation Pipeline (groundwork): implementation notes

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-036-training-distillation-pipeline.md`
- **Branch:** `worktree-t036-encoder-training` (worktree `.claude/worktrees/t036-encoder-training`, base master `840bcd7`) — **not merged, not pushed**
- **Phase:** groundwork — scripts + environment + smoke proof. **The full training run was deliberately NOT launched** (see "What was run").
- **Deliverable shape:** runnable pipeline (build → train → calibrate → harness → publish gate), contract-driven, torch-free guards, tested on the Mac and smoke-run end-to-end on the server CPU.

## Artifacts committed

| Path | Lines | What it is |
|---|---|---|
| `tools/train-intent/src/pipeline_guards.py` | 191 | sha256/canonical-JSON helpers, same-file detection, golden-corpus refusal (normalized matra-stripped membership), GPU snapshot/free check, exit codes |
| `tools/train-intent/src/encoder_rules.py` | 216 | T-034 annotation-rule loader (12 labels, 13 BIO tags, offsets, edge bands) + `T035PendingError`/`require_t035` |
| `tools/train-intent/src/encoder_align.py` | 195 | pure alignment: canonical-text check, word offsets, span validation, word→tag, sentencepiece projection, span decode |
| `tools/train-intent/src/encoder_contract.py` | 296 | T-035 contract loader (`encoder-contract/v1`), element-wise identity assertion against T-034, canonical logit order, loss/calibration/meta keys, teacher selection, `soft_targets`, `distill_loss` (tau²·KL), `dtype_conformance()`, `check_max_len()` |
| `tools/train-intent/src/build_encoder_dataset.py` | 605 | stage E1 — BIO dataset builder on the T-034 row format, all guards preserved |
| `tools/train-intent/src/train_encoder.py` | 929 | stage E2 — contract-driven joint intent + 13-tag BIO fine-tune, resumable; writes the conformance record into `meta.json` |
| `tools/train-intent/src/calibrate_encoder.py` | 404 | stage E3 — temperature scaling + tri-state calibration gate |
| `tools/train-intent/src/run_encoder_pipeline.py` | 482 | stage E4 — streamed pipeline, single publish decision, run manifest (incl. `conformance`) |
| `tools/train-intent/queue_encoder.sh` | 67 | full-run-only GPU queue wrapper (waits for strangers, re-checks the card) |
| `tools/train-intent/src/bakeoff_export_coreml.py` | 288 | T-033-owned, additive: `WIRE_INPUT_DTYPE = int32` + the export-dtype conformance note (no behaviour change to its other steps) |
| `tools/train-intent/tests/` | 1452 | 107 tests (4 torch-only skips) |
| `tools/train-intent/config.yaml` | — | new `encoder:` section (was `M`) |
| `tools/train-intent/src/bakeoff_encoder.py` | — | additive only: `JointEncoder(tags=…)`, `load_model` passes `meta["tags"]` and refuses a slot head that disagrees with its own meta |
| `tools/train-intent/README.md` | — | encoder pipeline section (commands, stages, exit codes, tri-state calibration) |
| `tools/train-intent/annotation_rules.yaml` | — | **byte copy** of T-034's file (see "Consumed inputs") |
| `tools/train-intent/encoder_contract.yaml` | — | **byte copy** of T-035's file (see "Consumed inputs") |

Commits on the branch, in order:

```
32d0740 consume T-034 annotation rules + T-035 encoder contract (byte copies)
0f2c064 guard + alignment + contract modules (torch-free core)
d4c7bdc E1: BIO dataset builder consuming T-034 rules
91b3294 E2/E3: contract-driven trainer + temperature-scaling calibration
2964b3f E4: streamed pipeline with a single publish decision + GPU queue script
e700955 config, harness loader support for 13 tags, README
f8d19ec test suite — 94 tests, torch-free, guards observed through the CLI
00b6a27 fixes found by the server CPU smoke run (wiring bugs, no silent passes)
9ce9cee tests for the smoke-run fixes (102 tests)
14bcfa4 T-035 export conformance: dtype reconciliation, runtime.config, max_len lock (107 tests)
```

## Consumed inputs (revisions recorded, not invented)

| Input | Owner | Revision consumed | sha256 prefix |
|---|---|---|---|
| `tools/train-intent/annotation_rules.yaml` | T-034 | branch `worktree-t034-training-data`, commit `029f6a3`, blob `1b12ac1` | `8670ff29633a` |
| `tools/train-intent/encoder_contract.yaml` | T-035 | branch `worktree-t035-encoder-design`, commit `b54d527` (branch head, blob `bb71f47`); re-verified byte-identical to the T-035 worktree file at hand-back (468 lines, grew from 432 at `8bc8be9`) | `60e0211c53ce` |

The T-035 **fix commit** (`b54d527`, "address challenger review") was consumed as well: it adds
notes, `heads.logit_order: is_contract`, param-accounting corrections, the interpreter-side
`runtime.config` block (timeout/retry parameters that belong to T-037, not to training) and the
`proxy_measured_on_legacy_corpus` gate wording. **It does not touch the logit order, the 13 tags,
the loss or the calibration gate** — verified by diff against the first consumed revision
(`8bc8be9`, sha prefix `9926c7c93f87`) before switching. The consumed revision is recorded in
`config.yaml:encoder.contract_path` comments and inside every artifact's `meta.json` provenance.

Both files are committed on this branch **as byte copies of the other tasks' outputs** so the branch
is runnable and testable before those tasks land on master. At integration, identical blobs merge
cleanly; a diverging blob is a real conflict and must not be resolved silently — the logit order
**is** the contract. `annotation_rules.yaml` carries T-034's own 40-char HF revision string; that is
upstream content, not new content written by this task.

## What was built (decisions)

1. **One loader, two assertions, zero duplicated constants.** `encoder_contract.load_contract()`
   asserts element-wise equality between the T-035 contract and the T-034 rules at every stage
   startup, and against `build_dataset.VALID_ACTIONS` as a set. The canonical logit order
   (`ack_med, call, emergency, set_reminder, health_query, music, send_message, guide,
   create_calendar_event, suggest_video, query, none`) comes from the contract, never from a literal
   in the code, and `meta.json:intents` **is** that order (a test asserts `intents[2] == "emergency"`,
   which sorted order would break).
2. **Guards run before torch is imported.** Every refusal (golden corpus, missing build provenance,
   leaky row, drifted resume, missing contract, GPU busy) happens in the torch-free phase, so the
   refusal is identical on a laptop with no torch — which is how the CLI refusal tests run on the Mac
   with the real exit codes observed.
3. **The harness is never forked.** `run_encoder_pipeline.py` shells out to the unmodified
   `src/eval_golden.py --backend encoder --model-path … --manifest-out …` (T-038-owned) and reads its
   JSONL manifest to decide the publish. The 13-tag checkpoint loads through the harness's own
   `load_model` because `bakeoff_encoder.JointEncoder` now takes the tag list from `meta` (the first
   five tags are unchanged, so the harness's contact/time decoding is intact) — proven by the smoke
   run, where the harness scored the artifact.
4. **Distillation is implemented, conditional, and reported.** `tau² · KL` exactly as the contract
   states, `soft_targets()` builds the contract's stated construction (p[gold] = row confidence, rest
   uniform), and the run **skips stage 2 by default with the reason recorded** — the preferred teacher
   (`incumbent_local_llm`) is `availability: tooling_not_in_repo`, and the only available teacher is a
   stated construction, not a measured distribution. Opt in with `encoder.distillation.enabled: true`;
   `config.yaml` carries `null` for tau/`lambda_kd`/student size so the contract value always wins.
5. **Calibration ships with the artifact.** One parameter fitted on the **valid** split by golden-section
   search on log T (no scipy on the server), written to `artifact/calibration.json` and mirrored to
   `meta.json:calibration_temperature` (`shipped_as` in the contract: the graph emits raw logits; the
   interpreter divides then softmaxes). Golden evaluation is read-only and never a fit split.
6. **Tri-state calibration gate — no silent pass.** `gate.passed` is `true`, `false`, or `null`
   (not measurable: below the contract's `corpus_floor` / `measurable_today=false`). `null` withholds
   publication like `false` does. Rationale found the hard way: with 20 golden rows every bucket
   under-fills, pools into one bucket below `min_samples_per_bucket`, the violation list is empty —
   and the naive implementation called that a **pass**.
7. **Publish is a decision with named reasons.** All of: harness exit 0 with empty `gates_failed`,
   calibration passed, `model.pt` unchanged between eval and publish, not `--smoke`, and
   `encoder.artifact.version` set. The version is still `null` (the T-035 contract names no artifact
   version) so publication is **refused with that exact reason** — recorded, not stubbed.
8. **Paths are absolute before they reach a stage.** Stages run with `cwd=tools/train-intent/`; the
   pipeline resolves `--sources`, `--build-report`, `--publish-dir`, `--work-dir` against the caller's
   cwd once, and logs the resolved work dir.
9. **Stage timeout/retry are parameters.** `encoder.pipeline.stage_timeout_seconds` / `stage_retries`
   (default 0 = no watchdog) plus CLI overrides. Only a **timed-out** stage is retried; a refusal or a
   gate failure is deterministic and stays an operator decision.

## What was run (verification evidence)

### 1. `py_compile` on every script (Mac)

```
$ python3 -m py_compile src/{pipeline_guards,encoder_rules,encoder_align,encoder_contract,\
build_encoder_dataset,train_encoder,calibrate_encoder,run_encoder_pipeline,bakeoff_encoder}.py
py_compile OK
$ zsh -n queue_encoder.sh          # shell syntax OK
$ python3 -m pyflakes src/<T-036 files> tests/*.py     # exit 0, no findings
```

### 2. Test suite (Mac, no torch — 107 tests, 4 torch-only skips)

```
$ cd tools/train-intent && python3 -m unittest discover -s tests -t .
Ran 107 tests in 7.3s
OK (skipped=4)
```

The 4 skips are the torch-only paths (distill loss, model loading); everything that can be asserted
without torch is asserted, because the guards are the part that must be host-independent.

### 3. Leakage guard — observed output (Mac, exit code captured without a pipe)

```
$ python3 src/build_encoder_dataset.py --sources eval/golden_corpus.jsonl \
    --out-dir /tmp/t036-leak-demo --report /tmp/t036-leak-demo/build_report.json
exit=3
[guard] REFUSED: --sources: refusing eval/golden_corpus.jsonl — it IS the held-out golden corpus
(/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/t036-encoder-training/tools/train-intent/eval/golden_corpus.jsonl).
The corpus is the eval set (spec §10); training on it means flying blind.
```

The same refusal exists, with its own test, in `train_encoder.py` (a row-level leak in a train JSONL
is exit 3) and in `calibrate_encoder.py` (the golden corpus is refused as a **fit** split). The test
that satisfies the AC "a test fails if `eval/golden_corpus.jsonl` is passed as a training input to any
encoder training script" is `tests.test_build_encoder_dataset.TestGoldenCorpusRefusals` plus
`tests.test_train_encoder_guards.TestCliRefusals.test_golden_corpus_as_train_input_is_refused`, both of
which run the CLI and assert the observed message and exit code.

### 4. Server CPU smoke run — build → train → calibrate → harness → publish gate

- Server: `anjan@192.168.1.117` (RTX 3090 24 GB)
- Scratch: `~/workspace/projects/rnd/t036-encoder/` (code synced from the Mac worktree; **nothing in
  `~/workspace/projects/parent-assistant` was touched**)
- Interpreter: `~/workspace/projects/rnd/t033-encoder-bakeoff/venv/bin/python` — Python 3.12.3,
  torch 2.6.0+cu124 (CUDA available), transformers 4.56.2

Backbone cache (own `HF_HOME`, `HF_HUB_DISABLE_XET=1`): the C3 snapshot at revision `08dc4816…`
**matches the T-034 pin**, downloaded complete (13/13 files, `model.safetensors` + `pytorch_model.bin`
+ tokenizer + sentencepiece).

Exact command (wrapped for readability; the work dir was reused across runs):

```
cd ~/workspace/projects/rnd/t036-encoder
HF_HOME=$HOME/workspace/projects/rnd/t036-encoder/hf-cache HF_HUB_DISABLE_XET=1 \
  ~/workspace/projects/rnd/t033-encoder-bakeoff/venv/bin/python -u code/src/run_encoder_pipeline.py \
    --sources code/tests/data/encoder_rows_sample.jsonl \
    --work-dir $HOME/workspace/projects/rnd/t036-encoder/runs/smoke-<stamp> \
    --device cpu --max-steps 2 --smoke
```

Output tail (final run, abridged to the decision-relevant lines):

```
[pipeline] work_dir=…/runs/smoke-20260913-103235 device=cpu smoke=True label=t036-smoke
           rules_sha=8670ff29633a contract_sha=60e0211c53ce
[pipeline] stage policy: timeout_s=0.0 (0=no watchdog) retries=0 (only timeouts are retried)
[stage] build: exit=0 in 0.2s
[build] kept 9 rows (train 8, valid 1)
[build] buckets: stt_noised 4 (44.4%), clean_devanagari 4 (44.4%), romanized_codeswitched 1 (11.1%)
[build] refusals: ack_refusal_marker=1, action_alias_intent=1, conflict_keys_clean_devanagari=1,
        dup_clean=1, edge_band_abstain_low_confidence=1, edge_band_gibberish_to_none=1,
        non_alignable=1, relabel_or_drop=1, resolved_value=1, schema_id=1, span_omitted_under_noise=4,
        whitespace_noncanonical=1, …   (counters only — no utterance text, NFR-016)
[build] floors waived: corpus_floor, per_action_floor, stt_noised_floor (smoke) — smoke/wiring use only
[stage] train: …
[train] [contract] encoder_contract.yaml sha=60e0211c53ce schema=encoder-contract/v1 task=T-035
[train] [gpu] 1 busy process(es), 12064 MiB resident; device=cpu
[train] [distill] stage 2 skipped: contract loss.distillation.enabled='conditional' and the only
        available teacher (gemini_teacher_rows) is a STATED construction from a scalar confidence …
[train] [tok] tokenizer_vocab=250002 embedding_rows=250037 pin=250037 repo=cartesinus/…
[train] [model] params=117663385 revision=08dc4816 pinned=08dc4816
[train] [state] partial run (max-steps 2) — resume with the same command; state -> …/train/state.pt
[train] [valid] {"intent_accuracy": 0.0, "rows": 1, "slot_f1": 0.0, …}
[train] [ckpt] step=2 -> …/train/artifact
[stage] train: exit=0 (32 s, CPU)
[calibrate] [contract] calibration.gate buckets=10 tolerance=0.1 min_samples_per_bucket=30
            below_floor=pool_upward_and_report measurable_today=False
[calibrate] [fit] rows=1 T=2.856374 nll 2.489134 -> 2.483251
[calibrate] [golden] rows=20 acc=0.05 ece 0.0554 -> 0.0408
[calibrate] [golden] bucket [0.0,1.0) n=20 acc=0.05 conf=0.0908 gap=0.0408
            pooled_from=[0.0, 0.1, …, 0.9]
[calibrate] [golden] NOTE: the contract marks this gate measurable_today=False with corpus_floor=8000
            rows; 20 golden rows cannot fill the buckets — pooled result is indicative only.
[calibrate] [gate] NOT MEASURABLE: golden corpus has 20 rows; the contract requires
            measurable_today=true and >= 8000 rows — reporting no claim rather than a pass
[stage] calibrate: exit=1 (16 s)
[pipeline] calibration did not pass or was not measurable — continuing to the harness for the full
           picture; publication is withheld
[stage] eval: src/eval_golden.py --backend encoder --model-path …/train/artifact --label t036-smoke
[stage] eval: exit=1 (18 s)
[eval] GATES FAILED: ['closed_intent_accuracy', 'contact_f1', 'time_f1', 'emergency_recall',
       'side_effect_precision'] — this checkpoint must not ship
[publish] WITHHELD: smoke run (wiring only): never publishes; harness gates failed; calibration gate
          not measurable (corpus below the contract floor) — no calibrated claim can be made;
          encoder.artifact.version is unset — the T-035 contract names no artifact version, so the
          release step must set one
[pipeline] run manifest -> …/run_manifest.json
```

Evidence of record:

| Item | Value |
|---|---|
| Run manifest | `~/workspace/projects/rnd/t036-encoder/runs/smoke-20260913-103235/run_manifest.json` |
| Run manifest sha256 prefix | `e0f1119d48fe` |
| Artifact digest (`meta.json:artifact_digest`, sha256 prefix) | `d84a0fa7296b` |
| Harness manifest row | `eval_manifest.jsonl`, `checkpoint_sha256` prefix `d84a0fa7296b`, `corpus_sha256` prefix `1f4c059cd9b1`, `config_sha256` prefix `fd888f5cb992` |
| Harness metrics on the smoke artifact | closed_intent_accuracy 0.2941, contact_f1 0.0, time_f1 0.3636, emergency_recall 0.0, side_effect_precision 0.3333 → 5 gates failed (expected: 2 CPU steps on 9 fixture rows) |
| `meta.json` required keys present | `intents` (canonical order), `tags` (13), `max_len` 64, `calibration_temperature`, `artifact_digest` |
| Stages executed | build 0, train 0, calibrate 1, eval 1 → publish withheld, `EXIT_GATE` 5 |
| `full_training_run_launched` in the run manifest | `false` |
| **Re-run after the conformance change** (`…/runs/smoke-20260913-104512`, same command, exit 5) | run_manifest sha256 prefix `d92bd18ec211`; meta.json prefix `ef7b96c85692`; model.pt / `artifact_digest` prefix `7d6d15f1ae5a`; eval_manifest.jsonl prefix `78355f2cd8b9`; `conformance` present in both JSONs; `calibration_temperature` 20.0 (fitted) with `calibration.method` recorded; harness metrics closed-intent 0.294, emergency_recall 1.000, side_effect_precision 1.000 → 3 gates failed (fixture-scale noise, not a claim) |

### 5. Resumability demonstrated on the server (not just asserted)

```
$ … run_encoder_pipeline.py … --max-steps 2 --smoke      # prints:
[train] [state] partial run (max-steps 2) — resume with the same command; state -> …/train/state.pt
$ python -c "…torch.load('state.pt')…"                     # state step=2 epoch=1
$ … run_encoder_pipeline.py … --max-steps 4 --smoke      # prints:
[train] [resume] step=2 epoch=1
[train] [ckpt] step=4 -> …/train/artifact
[train] [done] steps=4
```

The same command with a changed config or dataset is **refused** (`resume_mismatch`), the contract sha
is part of `cfg_hash`, and `--fresh` discards the state deliberately.

### 6. GPU state observed — no contention

```
$ nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader
4111014, 18622 MiB        # before my runs (util 74%)
4111014, 12064 MiB        # during and after all smoke runs
```

One foreign compute process throughout (another session's job); **no second process ever appeared**,
nothing was killed, interrupted or queued onto the card. Every stage of the smoke ran `--device cpu`,
and the trainer's GPU gate printed `[gpu] 1 busy process(es), 12064 MiB resident; device=cpu` — i.e.
the CUDA path would have refused to start into that card.

### 7. Conformance with the T-035 / T-037-a export contract (hand-back, commit 14bcfa4)

Three constraints arrived from `sdd-run` after the first smoke run; all three are now satisfied, two
of them needed a code change and none changed the scope:

**a. Consume the contract, not the T-033 spike (already done — re-verified).** The loader reads
`heads.logit_order: is_contract`, `maxSequenceLength`, `spans-not-resolved-values` and
`slots.offsets.unit: unicode_scalar` from the T-035 file. The in-repo copy was re-verified
**byte-identical** to the current file on the T-035 worktree at hand-back (468 lines — the fix commit
grew it from the 432 of `8bc8be9`; sha prefix unchanged at `60e0211c53ce`).

**b. Input dtype — decided and recorded, not silently divergent.** The contract declares `int64`
graph inputs (`runtime.graph.inputs`), while the compiled T-033 CoreML artifact's `metadata.json`
declares Int32 `[1, 1...64]` and the shipped iOS runner (`IntentEncoderInterpreter.swift`, T-037-a)
sends Int32. Decision: **the iOS wire dtype stays int32** — coremltools inserts the int32 → int64 cast
at the graph input, so the runner needs no change and the torch/ONNX graphs keep the contract's
int64. The reconciliation (contract dtype, training dtype, wire dtype, evidence, and the flag that an
int64 CoreML export *would* require a matching runner change) is written by
`EncoderContract.dtype_conformance()` into `artifact/meta.json:conformance` and
`run_manifest.json:conformance`, and declared at the one place the CoreML spec is written
(`bakeoff_export_coreml.py:WIRE_INPUT_DTYPE`) so no export can flip it silently.

**c. `meta.json:calibration_temperature` is required, present and honest.** It is now always numeric:
identity `1.0` with `calibration.status='uncalibrated'` before stage E3 fits one (never `null`, which
the interpreter would have to special-case), and after E3 the fitted value plus `calibration.method`
("temperature scaling (single parameter, NLL, golden-section)"), the fit split's sha256 and the
calibration file's sha256. `runtime.config` (confidenceThreshold 0.4, maxSequenceLength 64,
timeoutSeconds 2.0, maxRetries 0, retryOnArtifactLoadRace true) is parsed, checked for completeness
and recorded in the same provenance blocks — the trainer neither drives nor overrides it, because it
is the interpreter's (T-037).

One more lock came out of the same review: `encoder.max_len` must equal the contract's
`runtime.config.maxSequenceLength` (64) — the trainer and the calibrator now refuse a mismatch before
torch is imported, because that value *is* `meta.json:max_len` and the exported graph shape.

Re-validation: the same CPU smoke pipeline was re-run on the server after these changes (work dir
`…/runs/smoke-20260913-104512`, exit 5 as expected, `full_training_run_launched: false`) and both
`meta.json` and `run_manifest.json` carried the new `conformance` block with `int64` contract /
`int32` iOS wire and the full `runtime_config`.

## What is runnable now vs waiting

**Runnable now (no GPU, no teacher):**
- `python3 src/build_encoder_dataset.py --sources … --out-dir … --smoke` (Mac or any box),
- `python3 src/run_encoder_pipeline.py --sources … --work-dir … --device cpu --max-steps N --smoke`,
- `python3 src/run_encoder_pipeline.py --dry-run` (prints the exact stage plan, executes nothing),
- the whole test suite (`python3 -m unittest discover -s tests -t .`),
- `src/calibrate_encoder.py` against any artifact directory written by the trainer.

**Waiting on other inputs (not this task's to invent):**
- the **full run** — needs the stage 1–3 corpora (`data/teacher.jsonl`, `data/noised.jsonl`,
  `data/edge_cases.jsonl`) at the floors (`corpus ≥ 8000`, `stt_noised ≥ 0.55`, per-action
  ≥ 0.25 × target). Those come from `gen_teacher.py` / `stt_noise.py` / T-034's data work; a GPU leg
  for `stt_noise` is the only GPU consumer on the path and is queued by the other script.
- `encoder.artifact.version` (T-035 names none) and the model catalogue location for publication.
- the teacher gap metric (`max_gap_vs_gemini` / per-intent gap table): the harness owns it
  (`eval_golden.py`), and the incumbent teacher is `tooling_not_in_repo`.
- per-row emergency misses: not available at the current harness revision (aggregate metrics only) —
  recorded in the run manifest under `dependencies.T-038` rather than approximated here.

## Environment quirks worth knowing

- **`HF_HOME` lives in `~/.zshrc` only** — a non-interactive `ssh` command does not see it and silently
  uses the wrong cache. Every server command here sets `HF_HOME` explicitly to the scratch cache.
- **`HF_HUB_DISABLE_XET=1` is required** on this box (the Xet transfer path stalls).
- The C3 checkpoint's `config.json:vocab_size` is **250037** (embedding rows, what T-033/T-034 pinned)
  while its tokenizer reports **250002**. Same checkpoint, two different quantities — a naive equality
  check refuses a correct model (it did). `tokenizer_pin_problem()` now compares both sides explicitly.
- The golden corpus spells its label **`intent`**; stage-E1 rows spell it **`action`**. Both are read.
- The server venv has **no pytest and no coverage** — the suite is `unittest`-only by design.
- `state.pt` is ~1.4 GB for this model (full optimizer state); a partial `--max-steps` run leaves it by
  design so a continuation resumes mid-epoch.
- The scratch venv is `~/workspace/projects/rnd/t033-encoder-bakeoff/venv` (not `.venv`).

## Acceptance-criteria status

| AC | Status |
|---|---|
| Pipeline committed under `tools/train-intent`, reusing config/resumability conventions | done |
| Dataset builder extended to BIO + intent rows; leakage guard verified by test | done (observed refusal + CLI test) |
| Published artifact set: model, tokenizer, calibration params, thresholds, versioned manifest with sha256 | assembled (`artifact/` carries all of them; `meta.json` has the sha256 + contract provenance) — **publication withheld until `artifact.version` is set** (T-035 names none) |
| Spec §10 gates enforced in the run | enforced by the harness the pipeline calls (never forked); the smoke run exited non-zero and withheld publication on 5 failed gates |
| Run exits non-zero with no publication on any gate failure | done (`EXIT_GATE` 5; reasons recorded in `run_manifest.json`) |
| Provenance manifest per run; consented exports referenced by opaque id | done (data/contract/rules hashes, row counts per register/bucket/source family, base revision; `--consent-export` refuses and the manifest carries the NFR-015 block: real-user ingestion is an ops gate) |
| No PII in logs, manifests or eval fixtures | done (counters/hashes/paths only; fixtures are synthetic; manifests carry a `pii` block) |
| Fresh-run reproducibility (byte-identical artifact) | **not yet measurable** — needs a published artifact and a full run; seeds are fixed, `cfg_hash`/`data_hash` pin the inputs, and the run manifest records every digest needed to compare |
| Distillation target met or fail loudly | stage 2 is **conditional and off** (no measured teacher); the loss, targets and skip reason are implemented and reported — the gap gate itself is blocked on the teacher |
| Resumable + GPU-serialised | demonstrated (step 2 → resumed → step 4); `queue_encoder.sh` waits for strangers and the trainer re-checks the card before a CUDA leg |
| Lead engineer review; artifacts handed to T-037/T-038 | handed over in `run_manifest.json:dependencies`; review is the integration step |

## Open risks / handoffs

1. **No artifact version** → publication is impossible until T-035 (or the release step) names one.
   This is deliberate: `null` produces a refusal with an actionable message, never a silent publish.
2. **Emergency-recall diagnosis.** The harness reports only aggregate `gates_failed`; per-row emergency
   misses (AC) need T-038 to expose them. Recorded as a dependency, not approximated.
3. **Calibration is not measurable today.** `measurable_today=false` and 20 golden rows vs a floor of
   8000: the gate reports `null`. Once the corpus is large enough the same command gates for real.
4. **Smoke metrics are noise** (2 CPU steps on 9 fixture rows) — they exist to prove wiring, and the
   pipeline labels the run `t036-smoke` in the harness manifest so it can never be mistaken for a
   candidate.
5. **Byte-copied dependencies.** If T-034/T-035 land a diverging `annotation_rules.yaml` /
   `encoder_contract.yaml`, resolve the conflict by re-running the identity assertion — a silent pick
   would change the meaning of every checkpoint's logits.
6. **`stt_noise` is the only GPU leg on this path** and belongs to the other tool; `queue_encoder.sh`
   waits for it rather than competing with it.
7. **Export dtype is a stated decision, not a free choice.** If the CoreML export ever declares
   `int64` inputs, the T-037-a runner must change in the same commit — the `conformance` blocks in
   `meta.json`/`run_manifest.json` and `bakeoff_export_coreml.py:WIRE_INPUT_DTYPE` exist so that
   cannot happen silently.

## Not done (explicitly out of scope for this phase)

- The full training run was **not launched** — no GPU leg, no published artifact, no
  `models/` output. `full_training_run_launched: false` is recorded in each smoke run manifest.
- No merge, no push, no `.ai-sdd/` state touched, no `complete-task` from this session.

## 8. Waiver plumbing + first full-run launch (worktree `t036-waiver`, 2026-09-13)

### What was built (commits 9af1d59, 2c4214e)

Commits on `worktree-t036-waiver` (base `e28165c`):

- `9af1d59` — `--waive-floor` / `--waive-reason` in `run_encoder_pipeline.py`: refused with
  EXIT_GUARD (3) before any stage when a waiver has no reason, or when the build stage will not
  run (`--skip-build` / no `--sources`); forwarded **only** to the E1 build command
  (`build_stage_cmd`); recorded in `run_manifest.json:waiver` with the build report's own keys
  (`violations` / `waived` / `unwaived` / `waive_reason`) plus `violations_waived` and
  `zero_row_actions`. An unwaived floor hold now surfaces as EXIT_FLOOR (4), not a generic
  EXIT_STAGE. `queue_encoder.sh` forwards `T036_WAIVE_FLOOR` / `T036_WAIVE_REASON` (both unset =
  the floor-enforcing default). No new publish-withholding reason: publication still requires the
  calibration + harness gates on the artifact's own merits.
- `2c4214e` — `encoder.artifact.version: "0.1.0-internal"` in `config.yaml` (release-step
  decision; feeds `cfg_hash`), the matching deferral-test update, and a stale header line in
  `queue_encoder.sh`.

Tests (Mac, no torch): full `tools/train-intent` suite **172 tests, 167 pass, 5 fail, 4 skipped**.
The 5 failures are **pre-existing**: the same suite on pristine `master` (archived to `/tmp`) gives
the identical 5 failures out of 161. They are all one root cause — the golden corpus grew to 189
rows in T-038 (`01a494f`) and now collides with the fixture rows and the leak-count expectations
(`TestFixtureBuild.test_no_leak_into_training_rows`, `TestFixtureIntegrity`, two `TestCliRefusals`
message assertions). 11 of the 17 new tests exercise the waiver parse/refusal/forwarding/audit path.

### First full-run launch — build passed with the waiver, train leg refused

Launched at 2026-09-13 12:04:39 server time, work dir
`~/workspace/projects/rnd/t036-encoder/runs/t036-full-0.1.0-internal-20260913-120439`, sources
`parent-assistant/tools/train-intent/data/{teacher,noised,edge_cases}.jsonl` (digests
`3b81e3f4aa6b` / `cff510f31b8f` / `6d75b0460b57`), waiver names
`corpus_floor,stt_noised_floor,per_action_floor`, reason = the instructed sentence verbatim,
followed by the reproduced 2,561-row figures and the two zero-row actions
(`create_calendar_event`, `suggest_video`).

- E1 build: **exit 0 in 2.2 s**, `kept 2561 rows (train 2433, valid 128)`, printed
  `floors waived: corpus_floor, stt_noised_floor, per_action_floor (...) — smoke/wiring use only`
  and **no HOLD**. The waiver plumbing works end to end on the real corpora.
- E2 train: **exit 3 in 0.1 s — `[guard] REFUSED: build report records leaked rows — refusing
  this corpus`**. No GPU work, no CUDA leg, nothing published.
- The refusal is `train_encoder.py`'s check on `build_report.counters.leak > 0`; this build's
  counter is **leak = 105** — 105 source rows dropped by E1's leak guard because their normalized
  utterance is in the (now 189-row) golden corpus. Those rows never entered `train.jsonl`; the
  counter records exclusions, and the trainer refuses the corpus anyway.
- Consequence: **any** run of this pipeline over these corpora dies at E2, waiver or not — the
  earlier floor HOLD simply hid this second gate. The 5 pre-existing fixture failures are the same
  collision at fixture scale.

Open decision (not mine to take, nothing changed): either the leak counter becomes a recorded
exclusion with an explicit waiver of its own, or the sources/golden corpus are de-overlapped; the
guard's condition in `train_encoder.py` was left untouched.

- Notes to self about the run: the waiver's reason string is stored verbatim in the run's
  `build_report.json:floors.waive_reason`; no utterance text is in any log or manifest.

## 9. Leak-counter waiver + fixture realignment (commits 8a4bb11, 91307a7, on top of 9af1d59)

**Why.** The 12:04:39 run died at E2 on `train_encoder.py`'s unconditional refusal when the
build report's `counters.leak > 0` (leak = 105: rows E1 had already excluded as exact
golden matches). That made the real corpora untrainable with or without the floor waiver.

**What was built (`8a4bb11`).** `--waive-leak` mirrors the floor waiver end to end:
`build_encoder_dataset.py` records a `leak_waiver` block (requires `--waive-reason`) and
prints the exclusion; `train_encoder.py` honors the recorded waiver and keeps the row-level
belt-and-braces guard non-waivable, with its refusal message unchanged;
`run_encoder_pipeline.py` refuses (EXIT_GUARD/3) before any stage when the reason is missing
or the build stage will not run, forwards the flag only to E1, and records `leak_waiver` in
`run_manifest.json` alongside the floor record; `queue_encoder.sh` forwards
`T036_WAIVE_LEAK=1`. The help text, build-report `scope`/`note` and manifest note all state
the limit measured by the coordinator: the counter is **exact normalized-utterance matches
only** (teacher 67 hits / 25 keys, noised 32 / 2, edge_cases 6 / 5) and cannot see the 118
noised rows whose `clean_utterance` parent is a golden utterance (22 keys) — so "waived"
means "exact matches were excluded", never "contamination handled". The earlier rationale
that "E1 already excluded the rows, so the counter documents exclusion, not contamination"
holds for the exact 105 rows and NOT for the parent-derived ones; a waiver alone is not a
de-overlap.

**Fixture realignment (`91307a7`).** The T-038 golden-corpus expansion (`01a494f`, 189 rows)
put six fixture utterances inside the held-out skeleton, which is why five tests had been red
on master. The six rows were replaced with verified non-golden text and the JSONL
regenerated — test data only; no guard or assertion changed. The suite is green again:
**183 tests, all pass, 4 skipped** (torch-only) on the Mac.

**Still true:** no run launched from this round; publication would still be withheld at E3
(calibration not measurable) and E4 (harness gates) as measured in the coordinator's run.
