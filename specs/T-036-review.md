# T-036 — Paired Review (challenger), leak-counter waiver + fixture realignment

- Reviewer: `sdd-reviewer` subagent (read-only), orchestrated by the main session
- Reviewed revision: `8836350` on `worktree-t036-waiver` (base `e28165c`)
- Reviewed commits: `2c4214e` (version), `8a4bb11` (leak-counter waiver),
  `91307a7` (fixture realignment), `8836350` (notes)
- Verdict: **GO** — claims 1, 2, 4, 5, 6 verified in full; claim 3's wording
  verified, its exact 118/22 measurement not independently reproducible from this
  worktree (not refuted either). Residuals recorded below.
- Orchestrator note: I ran the suite on this branch myself before the review
  (179 passed / 4 skipped / 12 subtests, 183 collected — matches the claim) and
  launched the validation run at this revision (see "Orchestrator reproduction").
  The reviewer left the worktree clean.

## Check verdicts

- **Row-level guard is never waivable: PASS** — `train_encoder.py:553-565` reads
  `build.get("leak_waiver", {}).get("waived")`; the trainer's `add_argument` list
  (477-492) has no waiver option at all, so the source-level guard can only open
  through the recorded report. `train_encoder.py:582-588` runs `leak_refusals()`
  on the delivered rows unconditionally, before any smoke/floor branch. Proof by
  test: `tests/test_train_encoder_guards.py:169-190`
  (`test_the_row_level_guard_is_never_waivable`) asserts the `leak counter waived:
  105` banner appears AND the run still exits 3 with the golden-corpus refusal.
  Reproduced: `pytest tests/test_train_encoder_guards.py::TestLeakCounterWaiver -v`
  -> 3 passed.
- **Two audit records, reason verbatim, build-stage-only forwarding: PASS** — E1
  writes the reason verbatim (`build_encoder_dataset.py:600-611`; reason required
  at 536-538). The pipeline reads the recorded reason back
  (`run_encoder_pipeline.py:273`: `lw.get("waive_reason") or reason`) and the
  manifest consumes that block (561-564), so the two records reconcile rather than
  diverge. Missing reason refuses with EXIT_GUARD (203-221, returned 393-397).
  `build_stage_cmd` (177-200) is the only construction site for the flags; train
  (476-486), calibrate (496-498), eval (538-539) and export (528-529) carry none —
  no second, unaudited copy of the decision. `queue_encoder.sh:58-77` passes them
  once. Reproduced: `pytest -k Waiver tests/test_encoder_pipeline.py` -> 13 passed.
- **Scope/note honesty: PASS (wording) / UNVERIFIABLE (exact counts)** — the
  recorded `scope` states the counter covers "EXACT normalized-utterance matches
  against the golden corpus only; parent-derived noised rows are invisible to this
  counter (and to the row-level guard)", and the pipeline's manifest note states
  explicitly that a waiver "is NOT 'contamination handled'"
  (`run_encoder_pipeline.py:224-230`). No overclaim exists in either record. The
  blind spot is real in kind, not just in wording: both leak checks read only
  `row["utterance"]` (`build_encoder_dataset.py:504`, `train_encoder.py:584`),
  while `stt_noise.py:142` puts the parent in `clean_utterance` and nothing
  inspects it. The note's exact figures (teacher 67/25, noised 32/2 plus 118
  parent-derived / 22 keys, edge_cases 6/5) cannot be reproduced from this
  worktree — `tools/train-intent/data` does not exist here and the server corpus
  is out of scope for the reviewer. The same text is now recorded verbatim in the
  validation run's manifest, where it is checkable against the corpora.
- **Fixture realignment is test-only and weakens nothing: PASS** — `git show
  --stat 91307a7` touches only `tests/fixtures.py` and
  `tests/data/encoder_rows_sample.jsonl`. `git diff --stat e28165c..8836350 --
  tools/train-intent/eval/golden_corpus.jsonl` is empty (corpus still 189 rows).
  Membership was re-derived independently with `golden_keys()` + `normalize()`:
  all six old utterances are golden, all six replacements are not; the conflict
  pair is preserved so the `conflict_keys_clean_devanagari` counter still
  exercises. A fixture build after the change gives leak 0, conflict 1,
  dup_clean 1, kept 9 (train 8 / valid 1), and the regen byte-equality test
  (`test_build_encoder_dataset.py:39-45`) passes. No assertion was changed, so the
  tests now pass for the intended structural reason rather than a relaxed one.
- **Suite green: PASS** — `python3 -m pytest tests -q -p no:cacheprovider`
  (pytest 9.0.2 / Python 3.12.11): **179 passed, 4 skipped, 12 subtests passed,
  0 failed in 136.00s** (183 collected). The commit message's "183 tests, all
  pass, 4 skipped" is accurate.
- **PII/secret hygiene: PASS** — added lines carry no utterance text
  (`git show 8a4bb11 | grep -i utterance` -> policy/scope strings only); the new
  fields are counts and policy sentences; the queue echo prints environment
  variable names only (`queue_encoder.sh:66`); the pre-existing report-PII test
  (`test_build_encoder_dataset.py:105-110`) still passes. Residual: the operator
  reason is logged verbatim by design, with no sanitizer if an operator pastes
  sensitive text into it.

## Findings / residuals

- [MINOR] **E2 trusts the report boolean and does not require a reason.**
  `train_encoder.py:553-565` opens the source-level guard on `waived: true` alone;
  only the E1 and pipeline paths enforce that a reason accompanies it. A
  hand-edited build report could therefore claim a waiver with no recorded
  decision. Not a bypass of the row-level guard, which stays unconditional.
- [MINOR] **`--smoke` records `leak_waiver.waived: true` when the counter is 0**
  (`build_encoder_dataset.py:600-602`) — the field means "flag seen", not "a
  counter was actually waived". Harmless in the tested flow, but a reader of a
  smoke report could misread it as a waived violation.
- [MINOR] **Pre-existing, outside the reviewed commits:**
  `build_encoder_dataset.py:591-593` comments that a waived floor is "never a
  trainable corpus" while `:594` sets `usable_for_training` true whenever
  `unwaived` is empty. Inherited from `d4c7bdca`; flagged not attributed.
- [OPEN RISK] **A waived corpus that clears the gates would still publish.**
  `publish_reasons()` gained no waiver condition, and `config.yaml` now carries
  `0.1.0-internal`. "Internal testing only" is a version-string label, not an
  enforced gate — the artifact must fail the calibration/harness gates on its own
  merits, which is what currently stops publication (exit 5). If a future corpus
  both waives a guard and clears the gates, publication proceeds with no explicit
  human decision. Worth a deliberate call before any non-internal version.

## Independent check: the 12:04:39 refused-launch account

**UNVERIFIABLE locally, mechanism corroborated.** The pre-change trainer at
`9ebd739` contained exactly
`if build.get("counters", {}).get("leak", 0): raise GuardError("build report records leaked rows — refusing this corpus")`
(`git show 9ebd739:tools/train-intent/src/train_encoder.py`, 548-549), matching
the quoted refusal, so the described mechanism is real. But no run artifact for
that launch exists in the worktree (no manifest, no pipeline log; the account
lives in `specs/T-036-notes.md:408-433` and the branch author's commit messages).
The claimed `leak = 105` is not reproducible locally — the real corpora are absent
from this tree. The notes' evidence table records sha256s for the smoke runs but
no artifact or digest for the refused launch, so that episode remains
self-attested. The validation run launched at this revision does settle the
forward-looking part: with the cleaned sources the counter is 0 and the waiver is
recorded as belt-and-braces, in the run manifest, against the corpora themselves.

## Orchestrator reproduction (independent of the reviewer)

- Suite at `8836350`: `python3 -m pytest tests -q` -> 179 passed, 4 skipped, 12
  subtests passed (183 collected).
- Validation launch at this revision
  (`runs/t036-validate-8836350-20260913-121622`): build 2.15s, train 41.83s,
  calibrate 5.4s, eval 6.96s, pipeline **exit 5** (publish withheld). Build report
  records `counters.leak = 0` and `leak_waiver {requested: true, waived: true,
  counter: 0}` with the parent-derived scope/note; floor violations 12, all three
  waived with the reason verbatim. Gates: closed_intent 0.5287, contact_f1 0.0667,
  time_f1 0.0, emergency_recall 0.9375, side_effect 0.6364, abstention 0.4138,
  calibration deviation 0.2644 -> 9 failures, nothing published.
- Artifact from that run: sha256 prefix `26ee1ec9b5ce` — distinct from the
  `6d2989e95785` checkpoint that was exported to CoreML, so the device zip is the
  earlier run's artifact, as instructed.

## Decision

**GO.** Commits `2c4214e`, `8a4bb11`, `91307a7` and `8836350` are accepted as
reviewed, with the residuals above recorded. The row-level integrity guard remains
non-waivable, the waiver is recorded in both audit records with the reason
verbatim and forwarded to the build stage only, and the fixture realignment is
test-only. The open risk about publication under a waiver is a policy decision for
the release step, not a defect in these commits.
