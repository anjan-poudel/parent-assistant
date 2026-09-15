# Round-2 prep — implementation notes (CPU-side)

**Task:** prepare the ENCODER QUALITY ROUND-2 campaign so it can be fired the
moment the training box is reachable. No training, no GPU job, no `xcodebuild`,
no merge, no change to the pinned corpus.
**Worktree:** `.claude/worktrees/round2-prep` (branch `worktree-round2-prep`,
base `master` @ `41daeb6`).
**Plan:** `docs/superpowers/specs/2026-09-15-round2-quality-campaign-plan.md` —
this file records the *decisions and the fill-in-the-blank launch command*; the
plan carries the recipes, quotas and arithmetic.

## What was built

| Artifact | What it is | Ran here? |
|---|---|---|
| `tools/train-intent/src/gen_round2_requests.py` | the teacher request-list generator: recipes (a) emergency coverage EC-1…EC-8 and (b) confusion pairs CP-1a…CP-5b, with the quota table, per-register allocation, held-out de-duplication by construction, and a `--confusion` alignment hook for the v5 numbers | yes — 622 requests / 1,866 rows / 0 short classes / 70 held-out seed drops |
| *(box-side)* `gen_distill.py` | the local teacher runner named in the brief — **absent from this repo**; may exist on the box as out-of-repo tooling. The request list and QA gate define the schema it must speak (§4.4 of the plan) | n/a |
| `tools/train-intent/src/qa_round2_rows.py` | the post-generation QA gate: attribution, schema, taxonomy/span/edge-band via `build_encoder_dataset.convert_row` **by import**, held-out leak against the golden corpus **and** `eval/emergency_nearmiss.jsonl`, duplicates, class-cue fidelity, quota fill, optional noised-twin audit | yes — exit 0 clean, 4 degenerate/quota-hold, 3 refused input; leak 60/60 adversarial, near-miss 50/50 |
| `tools/train-intent/src/stt_noise.py` | **additive** `--in`/`--out` overrides so round-2 rows get their own file-level accounting (defaults unchanged) | import-checked only (needs piper+whisper) |
| the plan doc | recipes, quota table, distillation-leg design, v6 launch template, order of operations, risks | — |

## Decisions

1. **Quotas are a plan, not a guess, and they are one table.** Every class quota
   lives in the `ASK` list at the top of `gen_round2_requests.py`. Re-quotaing is
   an edit there plus a re-run (deterministic, seconds). Nothing else encodes a
   count.
2. **Distinctness is enforced by construction, not asserted.** Candidate seeds
   whose `build_dataset.normalize()` form is in the golden corpus **or** the
   near-miss set are dropped at generation time (70/692), and the QA gate
   re-checks every generated row. The generator reports the drop count so a class
   that converges on the corpus is visible rather than silently thinned.
3. **The QA gate is stricter than E1, on purpose.** `build_encoder_dataset`
   guards only `eval/golden_corpus.jsonl`; the round-2 gate adds
   `eval/emergency_nearmiss.jsonl`, because an emergency row that paraphrases the
   adversarial set would weaken an emergency gate the build cannot see. Verified
   by feeding all 50 near-miss utterances: 50/50 rejected.
4. **No gate logic was copied.** Attribution/schema/quota logic is new; taxonomy,
   JSON, span, edge-band, refusal-marker, duplicate and leak logic is imported
   from the stage that owns it (`convert_row`, `encoder_align.validate_spans`,
   `build_dataset.normalize`/`lossless_key`/`load_golden_keys`,
   `encoder_rules.load_rules`, `pipeline_guards.*`).
5. **`stt_noise.py` gained two optional flags, nothing else.** The round-2 clean
   set must be noisable without hand-appending rows to `data/teacher.jsonl`;
   defaults are untouched, so every existing call site behaves identically.
   A documented fallback (back up and append) covers a box without the patch.
6. **Priority-keep was *not* changed.** Round-2 sources match none of
   `EDGE_SOURCE_PREFIXES`, so the mixer's "edge rows are never sampled away"
   rule does not cover them. Rather than silently extend a T-034-owned semantic,
   the plan offers Option A (two-line addition, inert until round-2 sources
   exist) and Option B (run E1 — CPU, seconds — and read
   `buckets.*.supply_capped`). E1's report decides; the operator applies.
7. **The distillation leg is designed, not enabled, and v6 does not depend on
   it.** Three facts forced this: the local teacher runner does not exist in the
   repo; `annotation_rules.yaml` still says `local_teacher: forbidden` (the
   sanction in the T-036 task spec and the contract's preference order have not
   been carried into the rules file); and the KD branch can only consume the
   contract's *stated* construction (`p[gold] = confidence`), so enabling it
   today would report "distillation ACTIVE" while distilling nothing. §5 of the
   plan states the tool, the amendment, the contract status flip, and the three
   code touchpoints.
8. **KD is not confounded with the authored supply.** v6 = recipes only;
   v6-KD = recipes + KD, so the objective change is attributable.
9. **Floors stay unwaived; only the leak counter is waived, verbatim.** The
   leak counter is exact-match-only and blind to parent-derived noised rows (the
   build report already measures 118 such rows in the round-1 corpora), so
   `T036_WAIVE_LEAK=1` + a recorded reason keeps a known counting limitation from
   holding a clean run. A non-zero `held_out_leak` in the QA report is still a
   stop: fix the teacher output, never fire on a leak.
10. **The v5 numbers are consumed through one file.** `--confusion` takes a
    `confusion/v1` JSON (pairs + recall) and reports, per class, measured errors
    per planned rows plus the pairs no class covers. It is advisory: it never
    rewrites a quota, because a campaign that re-sizes itself from a file nobody
    read is a campaign nobody can audit. §1.4 of the plan has the ops snippet
    that produces the file from the v5 artifact using the harness's own
    `predict_gguf`.
11. **The corpus's own reminder came first.** An E1 dry run over a clean-only
    source keeps **zero** rows (`total = ceil(n_noised / 0.60)`, so with no
    noised supply both clean targets are 0). The STT-noise stage is therefore
    mandatory, and the round-2 rows only exist for the trainer through their
    twins. This is in the plan's order of operations and in the pre-flight.
12. **Nothing was written outside the worktree** except two `/tmp` test harnesses
    (a stub teacher and a synthetic near-miss/adversarial file). The pinned
    corpus, the near-miss set and the TG-11/TG-12/8k artifacts were read but
    never written.

## The fill-in-the-blank launch command

Two `<…>`s to fill; everything else is literal. Run from `tools/train-intent/`
on the box, after the §6.0 pre-flight has passed (teacher rows produced, QA exit
0, twins noised, E1 dry run read).

```bash
cd tools/train-intent
export T036_PY=.venv/bin/python
export T036_WORK_DIR="artifacts/t036-full-0.1.0-internal-v6-round2-8kcal-$(date +%Y%m%d-%H%M%S)"
export T036_PUBLISH_DIR="<v5's publish dir, version-suffixed v6>"

export T036_WAIVE_LEAK=1
export T036_WAIVE_REASON="round-2: 1866 authored rows (EC-1..8, CP-1..5b) QA'd against the held-out golden corpus AND eval/emergency_nearmiss.jsonl by qa_round2_rows.py (data/round2/round2_qa_report.json); exact-match leak counter waived as belt-and-braces. The counter sees exact normalized matches only and cannot see parent-derived noised rows; the E2 row-level guard is not waived."
# T036_WAIVE_FLOOR stays UNSET — floors: none.

./queue_encoder.sh \
  "<v5's source list, verbatim from $V5/build_report.json sources[]>" \
  data/round2/round2_clean.jsonl \
  data/round2/round2_noised.jsonl
```

If the box lacks the `stt_noise.py --in/--out` patch, append instead and drop
the clean file from `--sources`:

```bash
cp -a data/teacher.jsonl data/teacher.jsonl.bak-$(date +%Y%m%d%H%M%S)
cat data/round2/round2_clean.jsonl >> data/teacher.jsonl
```

## Verification performed here (CPU-only)

- Generator: `python3 src/gen_round2_requests.py` → 622 requests, 1,866 rows,
  **0 quota shortfalls**, 66–70 held-out seed drops across runs (seed-dependent).
  `--confusion` exercised against a synthetic `confusion/v1` file: per-class
  rows-per-error printed, `UNCOVERED guide->none: 11` and `call->guide: 7`
  surfaced with no class — the intended advisory behaviour.
- QA gate: exit **0** on 1,866 varied stub rows (1,866 clean, 0 rejected);
  exit **4** on a degenerate stub that repeats each seed (1,237 duplicates) and
  on an all-near-miss file; exit **3** when `--rows` *is* the golden corpus and
  when unattributed ids exceed `--max-unattributed`; the noised audit separated
  600 good rows from 1 unattributed + 1 parent-action mismatch + 1 held-out leak.
- E1 build (the stage the rows must survive): clean-only source → `kept 0`
  (anchor rule); clean + twins → `kept 375` (stt_noised 225 = 60.0%, clean 94+56),
  zero schema/span refusals, `edge_families: {}` (the priority-keep finding).
- Each script was also run with `--dry-run`/`--only` where applicable; the two
  `/tmp` harnesses were not added to the repo.
- No file under `eval/` was written; `git status` in the worktree shows only the
  three source files plus the plan and this note.

## Open questions carried into the plan (not resolved here)

- **OQ-1** priority-keep for round-2 sources — Option A or B (plan §4.1); E1
  decides empirically.
- **OQ-2** the KD leg as a sibling run or a later round (plan §5.3).
- **OQ-3** per-family emergency recall from v5 (the corpus's own family tags +
  the near-miss `kind` field); the confusion file carries the aggregate only.
- **OQ-4** the exact `stt_noise.variants_per_utterance` on the box (`config.yaml`
  says 2; the round-1 LLM path used 6) — read it before estimating the noise
  stage's wall-clock.
- **OQ-5** whether the local-teacher amendment (plan §5.2 item 2) belongs to
  T-034 or T-036; this prep deliberately did not edit `annotation_rules.yaml`.
