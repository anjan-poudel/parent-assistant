# T-038 — Eval-Harness Extension + On-Device Verification (groundwork): implementation notes

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md`
- **Branch:** `worktree-t038-eval-harness` (worktree `.claude/worktrees/t038-eval-harness`, base `840bcd7`) — branch tip, not merged, not pushed
- **Deliverable type:** harness + fixtures + measurement scaffolding. **No Swift touched, the iOS gate (`./ios/build.sh test:unit`) was not run** — device integration is T-037's. No `.ai-sdd/` state touched, no `complete-task`, no GPU/training.
- **Phase note:** groundwork. No encoder artifact exists yet, so every encoder/device number in the reports below is UNMEASURED; nothing here claims accuracy on a model that hasn't been trained.

## Artifacts committed (26 files, +2771 / −59)

| Path | What it is |
|---|---|
| `tools/train-intent/src/eval_golden.py` | Harness extended in place — same backends, same `results.csv` schema, 3 previously-unenforced gates wired, fixture backend, row/span validation |
| `tools/train-intent/config.yaml` | `gates:` gains `abstention_precision: 0.90`, `calibration_tolerance: 0.10`, `emergency_recall_nearmiss: 0.98`; 5 existing keys unchanged |
| `tools/train-intent/eval/golden_corpus.jsonl` | 189 rows (was 20), all 12 schema-v2 actions, span annotations + script markers |
| `tools/train-intent/eval/emergency_nearmiss.jsonl` | 50 rows: 30 emergency paraphrases + 20 calm pain/health questions |
| `tools/train-intent/eval/author_golden_corpus.py` | Reproducible authoring path (`--check` mode); offsets computed, never typed |
| `tools/train-intent/eval/fixtures/` | Control + 5 failing fixtures proving each new gate can fail the run |
| `tools/train-intent/src/build_dataset.py` | Leak guard now holds out **both** eval files; missing guard file warns instead of being silent |
| `tools/train-intent/src/measure_device.py` | Device latency/RAM harness (emit prompts, validate, score, evidence CSV) |
| `tools/train-intent/eval/device/` | `device-eval-protocol.md` (protocol + exact `devicectl` commands + report template), `prompts.jsonl` (100 held-out prompts), `measurements.csv` (header) |
| `tools/train-intent/tests/` | `test_eval_golden_gates.py`, `test_measure_device.py` — 36 tests, ~2 s, stdlib `unittest` |
| `tools/train-intent/README.md` | Ship-gate table, fixture recipe, device section, tests |
| `tools/train-intent/eval/results.csv` | One committed smoke run at the new corpus revision (label `t038-smoke-echo-189`); the `--manifest-out` sidecar for the same run was written to a scratch path (see risk 4) |

## Gates now enforced

| Gate | Threshold | Semantics |
|---|---|---|
| Abstention precision | ≥ 0.90 | `P(gold == none \| pred == none)`; zero abstentions ⇒ 1.0 (nothing was wrongly abstained); offenders = abstained rows whose gold is a real action |
| Calibration | ±0.10 | per populated confidence decile `min(int(conf*10), 9)`: `\|bucket accuracy − bucket mean confidence\|`; failing buckets flagged and their rows printed |
| Δ vs Gemini | ≥ −0.03 | closed-intent accuracy vs the newest `results.csv` row whose label starts with `gemini` (or `--gemini-label`); **missing baseline fails closed** (`gemini_gap_unevaluated`), the `gemini` backend itself is exempt |
| Emergency recall (near-miss) | ≥ 0.98 | `kind=emergency_paraphrase` rows must predict emergency; `kind=calm_pain_health` false fires printed |
| Emergency recall (corpus) | = 1.00 | unchanged gate; a single corpus miss exits non-zero and prints the missed row |

Existing gates (closed ≥0.95, slot F1 ≥0.90, side-effect precision ≥0.97) and the `results.csv` schema are untouched. New metrics go to stdout and the additive `--manifest-out` JSONL only.

## Corpus counts

- `golden_corpus.jsonl`: **20 → 189 rows**. Per action: ack_med 15, call 16, create_calendar_event 15, emergency 16, guide 16, health_query 16, music 16, none 16, query 16, send_message 16, set_reminder 16, suggest_video 15 (spec §9.1 target 15–25 each). Scripts: devanagari 161 / latin 23 / code_switched 5. 97 rows carry spans; all six T-034 labels present (contact 31, time 31, medication 27, message 14, topic 16, app 13).
- The original 20 rows keep **byte-identical pre-existing fields** (verified by diff against `HEAD`); only `spans` was added.
- `emergency_nearmiss.jsonl`: **0 → 50 rows** (30 paraphrase / 20 calm), disjoint from the corpus (guarded in the authoring script and in a test).

## Fixture evidence (observed, at branch tip)

Each failing fixture runs the `fixture` backend (prediction file keyed by row id; a missing id is a hard error) against a private `results.csv` copy and exits 1 with **exactly one** failed gate:

| Fixture | Exit | Last `results.csv` column | Printed evidence |
|---|---|---|---|
| control `preds_min_allpass` | 0 | `none` | `all gates passed` |
| `preds_abstention_fail` | 1 | `abstention_precision` | `abstention precision : 0.500 (gate 0.9; 1 genuine, 1 judged resolvable)` + `fx-query-001 gold=query pred=none conf=0.00 भोलि मौसम कस्तो हुन्छ` |
| `preds_calibration_fail` | 1 | `calibration` | `calibration : max \|acc-mean_conf\| 0.900 over 1 populated buckets (gate ±0.10)`, bucket row flagged `<-- FAIL`, `[calibration bucket 0.1 (acc 1.00 vs mean_conf 0.10)] 6 row(s)` |
| `preds_gemini_gap_fail` | 1 | `gemini_gap` | `[gemini gap] 0.964 is -0.036 vs gemini-fixture-baseline 1.000 — closed-intent errors behind the baseline:` + `fx-cl-music-13 gold=music pred=query conf=0.00 शान्त गीत बजाउ` |
| `preds_emergency_miss` | 1 | `emergency_recall` | `EMERGENCY RECALL : 0.500` + `fx-cl-emergency-02 gold=emergency pred=health_query conf=0.05 म लडेँ, उठ्न सकिन` |
| `preds_nearmiss_miss` | 1 | `emergency_nearmiss_recall` | `emergency near-miss : 0.750 (3/4 paraphrases)` + `fx-nm-003 gold=emergency pred=health_query conf=0.50 chhati dukhyo, madat garnus` |

A missing Gemini baseline also fails the run (`gemini_gap_unevaluated`, printed with "fail-closed"); a malformed fixture (span offsets no longer matching the utterance) exits 2 before scoring.

Smoke at the new corpus revision (`--backend echo`, committed ledger row):
`closed-intent accuracy : 0.000 (gate 0.95) … abstention precision : 0.085 … emergency near-miss : 0.000 (0/30 paraphrases; calm 0/20 correct, 0 false fires) … gemini gap : UNEVALUATED`, `GATES FAILED: [... 'gemini_gap_unevaluated']`, exit 1 — i.e. the harness runs the full 189-row corpus + 50 near-miss rows end-to-end and fails non-zero, as designed.

## Leakage guard

- Predicate level: every utterance in **both** held-out files is refused by `build_dataset.load_golden_keys()` + `normalize()` (test asserts zero non-refused rows).
- End-to-end: a real `build_dataset.py --smoke` run in a temp copy of the tree, fed one corpus utterance and one novel utterance, reports `'leak': 1` and writes only the novel utterance into `train.jsonl`/`valid.jsonl` — the corpus text never reaches training.
- The guard now also covers `emergency_nearmiss.jsonl` (without this, training on near-miss rows would inflate the new near-miss gate). A missing guard file prints a warning instead of silently dropping coverage.
- `eval/device/prompts.jsonl` is derived from the corpus, so the same guard covers it.

## On-device latency / RAM: UNMEASURED

No phone is attached to this box, so no device number is claimed. What is delivered instead:

- `src/measure_device.py` — `--emit-prompts` (deterministic 100-prompt set), `--replay` (validates the device JSONL contract: id, `pass` ∈ cold/warm, positive `latency_ms`, duplicate detection; scores nearest-rank p50/p95; gates ≤1000 ms / ≤2000 ms; exit 0/1/2), appends an evidence row to `eval/device/measurements.csv`.
- `eval/device/device-eval-protocol.md` — cold/warm protocol, 3-run requirement, exact iOS commands (`ios/device-install.sh`, `xcrun devicectl device copy to/from` verified against the installed `devicectl`, `--console` capture), the UNMEASURED latency table, the encoder-vs-GGUF-vs-Gemini regression table skeleton, and a NO-GO-until-measured verdict block.
- RAM is recorded (`peak_rss_mb`, observability only): spec §10 gates latency, not memory. No RAM gate was invented.

## Decisions

1. **Extend `eval_golden.py` in place** (no parallel script), keeping the `results.csv` schema and the existing printed gate lines verbatim so downstream consumers and past rows stay valid.
2. **A `fixture` replay backend keyed by row id** — each new gate is proven to fail *in isolation* (one failed gate per fixture), which echo-backend co-failure could not show. A missing prediction id is a hard error, not a silent skip.
3. **Fail-closed Gemini comparison.** A missing baseline is a failed gate, never a pass; the `gemini` backend is exempt from self-comparison.
4. **Span annotations are validated at load** (`utterance[start:end] == text`, label vocabulary, no overlaps) but span-level F1 scoring is deliberately not wired this phase (see omissions).
5. **Corpus authored by script** (`eval/author_golden_corpus.py`): offsets computed, cross-set disjointness enforced, `--check` in CI keeps the committed JSONL honest.
6. **Device harness refuses to invent numbers**: no measurements file ⇒ exit 2 with an UNMEASURED message; malformed rows are fatal (a dropped row would silently move percentiles).

## Deliberate omissions (and why)

- **Span-level F1 scoring** (contact/time F1 still uses resolver-ready `slots`, as before): the spec §10 slot gate is unchanged this phase; span→slot normalization and span scoring are T-035's contract follow-up (T-034 eval_note), and no encoder emits spans yet.
- **Encoder/GGUF/Gemini accuracy rows for the regression table** — need a trained artifact (T-036) and a Gemini API key; the table ships with UNMEASURED cells plus the exact commands.
- **`Android` device rows** — no Android client exists in this repo; marked `N/A (no client)`, not UNMEASURED.
- **No `ios/` change**: the on-device prompt/measurement harness inside the app is device-build work (T-037). The protocol file states the exact console/JSONL contract the app must satisfy.

## Open risks / hand-offs

1. **Stale baselines**: `eval/results.csv` still holds T-033 rows computed on the 20-row corpus (`corpus_sha256 1f4c059c…`). The Δ-vs-Gemini gate compares at the *current* revision, so the Gemini backend must be re-run on the 189-row corpus (`--backend gemini --label gemini-<rev>`) before any encoder comparison; until then the gate fail-closes by design.
2. **Near-miss set size** (30 paraphrases) means the 0.98 gate permits 0 misses (0.98 × 30 = 29.4 ⇒ ≥30 hits); a larger set would give the gate real slack. Flagged for T-036/T-037 to extend once a model candidate exists.
3. **Fixture baselines are synthetic** (`results_baseline_100.csv`, `…_096.csv`): they exist to pin gate arithmetic, and are labelled `gemini-fixture-baseline*` so they can never be mistaken for a real Gemini run — but a future harness change that relaxes the `gemini*` label match could let them into a real comparison.
4. The working rule forbids full 40+ char hex runs in any file. `eval/results_manifest.jsonl` (T-033's schema) stores full SHA-256 digests, so this branch does **not** modify it: the smoke run's `--manifest-out` sidecar was written to a scratch path and verified there (label, corpus prefix `c5e4c049`, near-miss prefix `4b4cb787`, new metrics present), and the commit contains no 40+ char hex run (scanned). The device CSV uses a 12-char prefix.

## Verification commands

```bash
cd tools/train-intent
python3 -m py_compile src/eval_golden.py src/build_dataset.py src/measure_device.py \
    eval/author_golden_corpus.py tests/test_eval_golden_gates.py tests/test_measure_device.py
python3 eval/author_golden_corpus.py --check          # committed corpus == authoring data
python3 -m unittest discover -s tests                 # 36 tests, OK
python3 src/eval_golden.py --backend echo --label t038-smoke-echo-189 \
    --manifest-out /tmp/t038-manifest.jsonl           # exit 1, gate list printed
```
