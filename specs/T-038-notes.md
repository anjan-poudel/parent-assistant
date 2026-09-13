# T-038 — Eval-Harness Extension + On-Device Verification (groundwork): implementation notes

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md`
- **Branch:** `worktree-t038-eval-harness` (worktree `.claude/worktrees/t038-eval-harness`, base `840bcd7`) — branch tip, not merged, not pushed
- **Commits:** `01a494f` implementation → `889e9a9` reviewer NO_GO report (`specs/T-038-review.md`) → `b3e59ee` review response; `run_fixture_sweep.sh` + this notes update sit on top (branch tip)
- **Deliverable type:** harness + fixtures + measurement scaffolding. **No Swift touched, the iOS gate (`./ios/build.sh test:unit`) was not run** — device integration is T-037's. No `.ai-sdd/` state touched, no `complete-task`, no GPU/training.
- **Phase note:** groundwork. No encoder artifact exists yet, so every encoder/device number in the reports below is UNMEASURED; nothing here claims accuracy on a model that hasn't been trained.
- **Change size vs base:** 30 files, +3338 / −63 (implementation + review report + review response).

## Artifacts committed

| Path | What it is |
|---|---|
| `tools/train-intent/src/eval_golden.py` | Harness extended in place — same backends, same `results.csv` schema, 4 previously-unenforced §10 gates wired, corpus-revision binding, fixture backend, row/span validation |
| `tools/train-intent/config.yaml` | `gates:` gains `abstention_precision: 0.90`, `calibration_tolerance: 0.10`, `calibration_min_n: 5`, `calibration_max_underfloor_fraction: 0.20`, `emergency_recall_nearmiss: 0.98`; 5 existing keys unchanged |
| `tools/train-intent/eval/golden_corpus.jsonl` | 189 rows (was 20), all 12 schema-v2 actions, span annotations + script markers |
| `tools/train-intent/eval/emergency_nearmiss.jsonl` | 50 rows: 30 emergency paraphrases + 20 calm pain/health questions |
| `tools/train-intent/eval/author_golden_corpus.py` | Reproducible authoring path (`--check` mode); offsets computed, never typed; same-label adjacency rejected at authoring |
| `tools/train-intent/eval/fixtures/` | Control + 6 failing fixtures (one per new gate incl. `calibration_coverage`) + `run_fixture_sweep.sh` (runs all of them, prints each failed-gate column; a test guards its file references) |
| `tools/train-intent/src/build_dataset.py` | Leak guard now holds out **both** eval files; missing guard file warns instead of being silent |
| `tools/train-intent/src/measure_device.py` | Device latency/RAM harness (emit prompts, validate, coverage policy, score, evidence CSV) |
| `tools/train-intent/eval/device/` | `device-eval-protocol.md` (protocol + exact `devicectl` commands + report template), `prompts.jsonl` (100 held-out prompts), `measurements.csv` (header) |
| `tools/train-intent/tests/` | `test_eval_golden_gates.py`, `test_measure_device.py` — 52 tests, ~3 s, stdlib `unittest` |
| `tools/train-intent/README.md` | Ship-gate table, fixture recipe, baseline-binding rules, device section, tests |
| `tools/train-intent/eval/results.csv` | One committed smoke run at the new corpus revision — **refreshed** in `b3e59ee`: the untagged `t038-smoke-echo-189` row was replaced by `t038-smoke-echo-189@c5e4c049` (same run, now corpus-tagged; the stale line is not kept as a duplicate) |

## Gates now enforced

| Gate | Threshold | Semantics |
|---|---|---|
| Abstention precision | ≥ 0.90 | `P(gold == none \| pred == none)`; zero abstentions ⇒ 1.0 (nothing was wrongly abstained); offenders = abstained rows whose gold is a real action |
| Calibration | ±0.10 | per confidence decile `min(int(conf*10), 9)` with **n ≥ `calibration_min_n` (5)**: `\|bucket accuracy − bucket mean confidence\|`; failing buckets flagged and their rows printed |
| Calibration coverage | ≤ 20% of rows under min-n | buckets below min-n are printed `EXCLUDED from the gate`; if rows stranded under the floor exceed `calibration_max_underfloor_fraction`, the run fails `calibration_coverage` (a model can't dodge calibration by being confidently wrong in tiny buckets) |
| Δ vs Gemini | ≥ −0.03 | closed-intent accuracy vs the newest `results.csv` row whose label starts with `gemini` (or `--gemini-label`) **and is bound to this run's corpus revision**; unbound legacy rows are reported UNEVALUATED and the gate fails closed (`gemini_gap_unevaluated`), the `gemini` backend itself is exempt |
| Emergency recall (near-miss) | ≥ 0.98 | `kind=emergency_paraphrase` rows must predict emergency; `kind=calm_pain_health` false fires printed |
| Emergency recall (corpus) | = 1.00 | unchanged gate; a single corpus miss exits non-zero and prints the missed row |

Existing gates (closed ≥0.95, slot F1 ≥0.90, side-effect precision ≥0.97) and the `results.csv` schema are untouched. New metrics go to stdout and the additive `--manifest-out` JSONL only.

**Corpus-revision binding (new).** Every result row is stamped with the first 8 hex chars of the scored corpus file's sha256, appended to the label (`label@c5e4c049`) and emitted as `corpus_tag` in the manifest. `read_gemini_baseline()` only accepts a row whose label carries *this* run's tag; other `gemini*` rows are listed in the fail-closed message with the exact re-run command. The task note ("record the corpus hash with every result row in `eval/results.csv`") is satisfied without changing the 6-column schema.

## Corpus counts

- `golden_corpus.jsonl`: **20 → 189 rows**. Per action: ack_med 15, call 16, create_calendar_event 15, emergency 16, guide 16, health_query 16, music 16, none 16, query 16, send_message 16, set_reminder 16, suggest_video 15 (spec §9.1 target 15–25 each). Scripts: devanagari 161 / latin 23 / code_switched 5. 97 rows carry spans; all six T-034 labels present (contact 31, time 31, medication 27, message 14, topic 16, app 13).
- The original 20 rows keep **byte-identical pre-existing fields** (verified by diff against `HEAD` at the time); only `spans` was added.
- `emergency_nearmiss.jsonl`: **0 → 50 rows** (30 paraphrase / 20 calm), disjoint from the corpus (guarded in the authoring script and in a test).

## Fixture evidence (observed, re-verified at the notes tip)

Each failing fixture runs the `fixture` backend (prediction file keyed by row id; a missing id is a hard error) against a private `results.csv` copy and exits 1 with **exactly one** failed gate:

| Fixture | Baseline copy (tag) | Exit | Last `results.csv` column | Printed evidence |
|---|---|---|---|---|
| control `preds_min_allpass` | `results_baseline_min_100.csv` (`@9d932959`) | 0 | `none` | `all gates passed`; `calibration : max \|acc-mean_conf\| 0.050 over 1 scored bucket(s) (n >= 5; gate ±0.10; 0 excluded…)` |
| `preds_abstention_fail` | `results_baseline_min_100.csv` | 1 | `abstention_precision` | `abstention precision : 0.500 (gate 0.9; 1 genuine, 1 judged resolvable)` + offender row |
| `preds_calibration_fail` | `results_baseline_min_100.csv` | 1 | `calibration` | `calibration : max \|acc-mean_conf\| 0.900 over 1 scored bucket(s) …` + `[calibration bucket 0.1 (acc 1.00 vs mean_conf 0.10)] 6 row(s)` |
| `preds_calibration_coverage_fail` | `results_baseline_min_100.csv` | 1 | `calibration_coverage` | `max \|acc-mean_conf\| 0.000 over 0 scored bucket(s) (n >= 5; gate ±0.10; 6 excluded holding 100.0% of rows — OVER 20% underfloor gate)` |
| `preds_gemini_gap_fail` | `results_baseline_28_100.csv` (`@273e326d`, 1.000) | 1 | `gemini_gap` | `gemini gap : -0.036 (0.964 vs gemini-fixture-baseline-28@273e326d 1.000) (gate -0.03)` + offender row |
| `preds_emergency_miss` | `results_baseline_28_096.csv` (`@273e326d`, 0.960) | 1 | `emergency_recall` | `EMERGENCY RECALL : 0.500` + missed row |
| `preds_nearmiss_miss` | `results_baseline_min_100.csv` | 1 | `emergency_nearmiss_recall` | `emergency near-miss : 0.750 (3/4 paraphrases)` + false-fire row |

Two more negative paths, both fail-closed and verified at the tip:

- **Unbound legacy Gemini row**: a correct-numbers but untagged `gemini-legacy` row ⇒ `gemini gap : UNEVALUATED — 1 baseline row(s) … not bound to this corpus revision (9d932959): gemini-legacy; re-run --backend gemini --label gemini-<rev>`, exit 1, `gemini_gap_unevaluated`.
- **Malformed fixture** (span offsets no longer matching the utterance) exits 2 before scoring; so do fixture preds files with a missing `action` (would have read as a silent abstention), an unknown id, or a non-numeric/out-of-range confidence.

Smoke at the new corpus revision (`--backend echo`, committed ledger row `t038-smoke-echo-189@c5e4c049`):
`closed-intent accuracy : 0.000 (gate 0.95) … abstention precision : 0.085 … emergency near-miss : 0.000 (0/30 paraphrases; calm 0/20 correct, 0 false fires) … gemini gap : UNEVALUATED`, `GATES FAILED: [... 'gemini_gap_unevaluated']`, **exit 1** (re-checked on a scratch CSV copy: `exit code on gate failure = 1`) — i.e. the harness runs the full 189-row corpus + 50 near-miss rows end-to-end and fails non-zero, as designed.

## On-device latency / RAM: UNMEASURED

No phone is attached to this box, so no device number is claimed. What is delivered instead:

- `src/measure_device.py` — `--emit-prompts` (deterministic 100-prompt set), `--replay` (validates the device JSONL contract: id, `pass` ∈ cold/warm, positive `latency_ms`, duplicate detection; scores nearest-rank p50/p95; gates ≤1000 ms / ≤2000 ms), appends an evidence row to `eval/device/measurements.csv`.
- **Exit codes are 0 / 1 / 2**: 0 = gates passed on a complete run (or an explicit `--allow-partial` run), 1 = latency gate failed, 2 = input/validation error (stderr + message, so automation can tell bad data from a bad build).
- **Coverage policy**: a §10 verdict requires `--prompts` (the committed 100-prompt set, `--min-prompts` default 100) with **every prompt in both passes**. Missing `--prompts`, unknown ids, incomplete coverage, or a sub-minimum prompt set are exit 2 — a one-row file can no longer pass vacuously. `--allow-partial` is the explicit override: it stamps `partial=true` in the CSV and prints `latency gates passed ON A PARTIAL RUN — not a §10 ship verdict`. The CSV persists `partial`, `prompt_count`, and per-pass `cold_n/cold_p50/cold_p95` + `warm_*` columns alongside the aggregate.
- `eval/device/device-eval-protocol.md` — cold/warm protocol, 3-run requirement, exact iOS commands (`ios/device-install.sh`, `xcrun devicectl device copy to/from` verified against the installed `devicectl`, `--console` capture), the UNMEASURED latency table, the encoder-vs-GGUF-vs-Gemini regression table skeleton, and a NO-GO-until-measured verdict block.
- RAM is recorded (`peak_rss_mb`, observability only): spec §10 gates latency, not memory. No RAM gate was invented.

## Decisions

1. **Extend `eval_golden.py` in place** (no parallel script), keeping the `results.csv` schema and the existing printed gate lines verbatim so downstream consumers and past rows stay valid.
2. **A `fixture` replay backend keyed by row id** — each new gate is proven to fail *in isolation* (one failed gate per fixture), which echo-backend co-failure could not show. A missing prediction id is a hard error, not a silent skip; every replayed row must carry `action` (in the taxonomy) and a numeric confidence in [0,1], and extra ids are rejected — otherwise a missing `action` would silently read as an abstention.
3. **Fail-closed Gemini comparison, bound to the corpus revision.** A missing baseline is a failed gate, never a pass, and so is a baseline scored on a different corpus (unbound/legacy rows are named in the error). The `gemini` backend is exempt from self-comparison.
4. **Span annotations are validated at load** (`utterance[start:end] == text`, label vocabulary, no overlaps, **no same-label adjacency** — that merge belongs at authoring) but span-level F1 scoring is deliberately not wired this phase (see omissions). `author_golden_corpus.py` enforces the same adjacency rule so the committed corpus can always pass validation.
5. **Corpus authored by script** (`eval/author_golden_corpus.py`): offsets computed, cross-set disjointness enforced, `--check` in CI keeps the committed JSONL honest.
6. **Device harness refuses to invent numbers**: no measurements file ⇒ exit 2 with an UNMEASURED message; malformed rows are fatal (a dropped row would silently move percentiles).
7. **Calibration min-sample policy**: min-n 5 with a 20% underfloor budget. Small buckets are excluded from the ±10-point judgement (a 1-row bucket is noise) but cannot be used to dodge it — stranding >20% of rows below the floor is its own gate failure with its own fixture.
8. **Device coverage policy**: partial runs are allowed only on explicit request and are visibly not a ship verdict, rather than being silently indistinguishable from a full run.

## Deliberate omissions (and why)

- **Span-level F1 scoring** (contact/time F1 still uses resolver-ready `slots`, as before): the spec §10 slot gate is unchanged this phase; span→slot normalization and span scoring are T-035's contract follow-up (T-034 eval_note), and no encoder emits spans yet.
- **Encoder/GGUF/Gemini accuracy rows for the regression table** — need a trained artifact (T-036) and a Gemini API key; the table ships with UNMEASURED cells plus the exact commands.
- **`Android` device rows** — no Android client exists in this repo; marked `N/A (no client)`, not UNMEASURED.
- **No `ios/` change**: the on-device prompt/measurement harness inside the app is device-build work (T-037). The protocol file states the exact console/JSONL contract the app must satisfy.

## Open risks / hand-offs

1. **Baseline re-run required**: `eval/results.csv` still holds T-033 rows computed on the 20-row corpus, and they are now correctly treated as unbound. The Gemini backend must be re-run on the 189-row corpus (`--backend gemini --label gemini-<rev>`) before any encoder comparison; until then the gate fail-closes with the exact command in the message.
2. **Near-miss set size** (30 paraphrases) means the 0.98 gate permits 0 misses (0.98 × 30 = 29.4 ⇒ ≥30 hits); a larger set would give the gate real slack. Flagged for T-036/T-037 to extend once a model candidate exists.
3. **Fixture baselines are synthetic** (`results_baseline_min_100.csv`, `results_baseline_28_100.csv`, `results_baseline_28_096.csv`): they pin gate arithmetic, are labelled `gemini-fixture-baseline*`, and now carry the fixture corpora's tags, so a fixture row can only ever bind to a fixture corpus — a real corpus run cannot pick them up.
4. The working rule forbids full 40+ char hex runs in any file. `eval/results_manifest.jsonl` (T-033's schema) stores full SHA-256 digests, so this branch does **not** modify it: the smoke run's `--manifest-out` sidecar was written to a scratch path and verified there (label, corpus prefix `c5e4c049`, near-miss prefix `4b4cb787`, new metrics present), and the commits contain no 40+ char hex run (scanned; the only match is the commit SHA in the commit object itself). The device CSV uses a 12-char prefix.

## Review response — `specs/T-038-review.md` (NO_GO 0.80, 4 majors + 2 minors)

All six findings were accepted and fixed in `b3e59ee` (none rejected).

| # | Finding | Change | Evidence |
|---|---|---|---|
| 1 | MAJOR: `measure_device.py` exit-code contract false — `SystemExit(string)` yields 1, docs claimed 2 | `die()` prints to stderr and `sys.exit(2)`; 1 is reserved for a real latency-gate failure; the module docstring, README, and protocol file now state 0/1/2 identically | `test_measure_device.py`: subprocess tests assert exit 0 (complete pass), 1 (`gates_failed=latency_p95`), 2 (missing file / no mode / malformed rows), plus `capture_die()` asserting exit code **and** stderr message in-process |
| 2 | MAJOR: latency gate passed vacuously (1-row file passes, `--prompts` optional, missing ids only warned) | `--prompts` required for a verdict (or explicit `--allow-partial`); unknown ids fatal; incomplete coverage fatal; prompt set < `--min-prompts` (100) fatal; `partial` + `prompt_count` + per-pass columns persisted in the CSV; partial runs print "not a §10 ship verdict" | `test_replay_without_prompts_is_exit_2_not_a_pass`, `test_incomplete_coverage_is_exit_2`, `test_prompt_set_below_minimum_is_exit_2`, `test_partial_override_passes_but_is_stamped_partial`, `test_replay_appends_evidence_and_passes` (asserts `cold_p95_ms`/`warm_p95_ms` columns) |
| 3 | MAJOR: Gemini baseline not bound to a corpus revision | Result rows stamped `label@<8-hex corpus tag>` (+ `corpus_tag` in the manifest); `read_gemini_baseline()` requires the tag; unbound/legacy rows → `gemini_gap_unevaluated` fail-closed with the re-run command; 6-column schema unchanged | Fixture-baseline tags regenerated; `test_…` revision-bound/unbound/tag-stamp cases; fixture sweep row 8 (untagged `gemini-legacy` ⇒ `UNEVALUATED … not bound to this corpus revision (9d932959)`, exit 1) |
| 4 | MAJOR: calibration had no min-sample policy | `calibration_min_n: 5` and `calibration_max_underfloor_fraction: 0.20` in `config.yaml`; only qualifying buckets carry gate weight; excluded buckets printed; over-budget underfloor mass trips the new `calibration_coverage` gate | `preds_calibration_coverage_fail.jsonl` + `test_…calibration_coverage_fixture`; sweep shows `0 scored bucket(s) … 6 excluded holding 100.0% of rows — OVER 20% underfloor gate`, `gates_failed=calibration_coverage` |
| 5 | MINOR: fixture backend silently defaulted missing `action` to abstention and ignored unknown ids | Replayed predictions are validated before scoring: duplicate ids, `action` ∈ taxonomy, confidence numeric in [0,1], extra ids → all exit 2 with a specific stderr message | `test_…` fixture-preds validation tests (missing action / unknown id / bad confidence), each asserting exit 2 **and** the message |
| 6 | MINOR: `validate_rows` only rejected cross-label overlaps | Same-label overlap and same-label adjacency are separate errors ("must be merged at authoring"); `author_golden_corpus.py` rejects adjacency too, with a parity test | `test_…same-label overlap/adjacency`; `author_golden_corpus.py --check` still exits 0 on the committed corpus (189 + 50 rows) |

**Smoke row refresh: YES.** The committed echo smoke row was regenerated at the current corpus revision and the stale untagged line (`t038-smoke-echo-189`) was **replaced** by `t038-smoke-echo-189@c5e4c049` in `eval/results.csv` — same backend, same corpus, now carrying the corpus tag; it is not duplicated in the ledger. The row still shows all eight gates failing (echo abstains on everything), which is the expected smoke behaviour.

## Verification commands

```bash
cd tools/train-intent
python3 -m py_compile src/eval_golden.py src/build_dataset.py src/measure_device.py \
    eval/author_golden_corpus.py tests/test_eval_golden_gates.py tests/test_measure_device.py
python3 eval/author_golden_corpus.py --check          # committed corpus == authoring data
python3 -m unittest discover -s tests                 # 52 tests, OK (~3 s, CPU only)
bash eval/fixtures/run_fixture_sweep.sh               # 7 fixtures + unbound-legacy control, all as expected
python3 src/eval_golden.py --backend echo --label t038-smoke-echo-189 \
    --manifest-out /tmp/t038-manifest.jsonl           # exit 1, gate list printed
```

Final state at the notes commit: 52 tests OK, `py_compile` clean on six files, `--check` clean (189 + 50 rows), fixture sweep verified, no 40+ char hex run in the tree.
