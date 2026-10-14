# T-178 — Held-out chat evaluation set (`chat_golden.jsonl`) (implement notes)

**Status: implemented, scoped suites green (70/70 + 42/42).** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). Declared files only. No commits, no
`ai-sdd` mutating commands.

## What was built

| File | Role |
|---|---|
| `tools/train-intent/eval/chat_golden.jsonl` | THE held-out set (FR-CNR-019): 501 lines — 1 header + 500 turns; 50 batches × 10. Fixture revision **83283663**; sha256 **`8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1569fcb1519`** (the version record for T-179/T-181 gate results). |
| `tools/train-intent/eval/author_chat_golden.py` | Plan (derived from the spec, never a local copy), teacher loop (gemini SDK or the recorded openrouter transport), the mechanical review executing the spec's guard inputs, `record_review` (human dispositions), `correct_output` (recorded pre-review corrections), loader/eligibility/`evidence()`/`held_out_keys()`/`require_gate_fixture()`, offline CLI (`--plan`, `--check`, `--check --manifest-out`, `--record-review`, `--correct-turn`). |
| `tools/train-intent/tests/test_chat_golden.py` | 70 unittest cases incl. subprocess CLI runs and an in-process CLI correction round trip. |

Held-out seam: `CHAT_GOLDEN_PATH = <repo>/tools/train-intent/eval/chat_golden.jsonl`
— the single constant, the loader default, and the path the header records as
`path_constant: eval/author_chat_golden.py:CHAT_GOLDEN_PATH`. `held_out_keys()`
returns the 500 `lossless_key`s (the T-179 admission-dedupe input);
`require_gate_fixture()` refuses an ineligible set.

Set composition (all pinned by tests): 500 turns, 500 unique dedupe keys;
coverage classes greeting 40, farewell 40, thanks 40, wellbeing 50,
health_adjacent_small_talk 50, food_and_meals 40, sleep 40, family 50,
weather_and_time 50, reminiscence 50, code_switched_nouns 50; hard cases
short_turn 90, code_switched_input 50, reminiscence_prompt 50; 24 context
entries across 20 turns; no empty notes; declared synthetic content only.

## The particle-rule alignment and the recorded corrections

T-169's completed runtime guard (`NepaliGrammarGuardTests`) cross-checked the
written set: **exactly 4** reference replies opened with a dangling clitic
(class `danglingParticle`, count 1 — positional, not a budget failure):
`cg-b026-06`, `cg-b034-02`, `cg-b034-09`, `cg-b035-10`.

Fix, minimal and recorded (pre-review authoring corrections — NOT a review
override; all four turns remain `human: pending` like the rest of their batches):

| Turn | Old text | Corrected text | Why |
|---|---|---|---|
| cg-b026-06 | `भात खान मन छ? ल, म तपाईंलाई भात दिन्छु।` | `भात खान मन छ? म तपाईंलाई भात दिन्छु नि।` | reply-initial `ल` had no clause to attach to; the particle now attaches to the sentence's clause, intent unchanged |
| cg-b034-02 | `अनि, के भन्नुभएको थियो हजुर छोरीले?` | `के भन्नुभएको थियो हजुर छोरीले?` | reply-initial `अनि`; the continuation cue is dropped rather than miss-attached — the user_turn already carries the follow-up context |
| cg-b034-09 | `अनि, के भयो कुरा अगाडि बढ्यो?` | `के भयो कुरा अगाडि बढ्यो?` | same reply-initial `अनि`; the question itself is unchanged |
| cg-b035-10 | `अनि कहिले आउँदैछ हजुर?` | `कहिले आउँदैछ हजुर?` | same reply-initial `अनि`; dropped (short_turn hard case preserved) |

Applied through the designed path (`correct_output` / `--correct-turn
--new-output --correction-reason`), so each turn carries a
`provenance.revisions` entry
`{field: "acceptable_output", from: <old text>, to, reason, by:
"authoring-correction", at}` — the file never presents a reworded reference as
the teacher's recorded output. `correct_output` refuses a non-pending
(reviewed) turn, an unknown turn, an identical text, a blank reason, and any
new text that fails the mechanical review.

**Nothing else changed** (evidence below): turn count 500, coverage/hard-case
counters, 24 context entries, 0 empty notes, 500 unique dedupe keys — and the
whole-set `teacher_output_sha256` reconstruction test proves all 50 per-batch
hashes still recompute after undoing exactly two documented mutations (the
recorded human dispositions and the 4 revisions), i.e. the 4 reworded texts are
the ONLY divergence from the teacher's output.

### The check now executes the positional rule (aligned with T-169)

`particle_occurrences` mirrors `NepaliGrammarGuard` exactly: token-gap
tokenization (whitespace/punctuation/symbols separate, each token keeps its
preceding gap), longest-match-first over the spec lexicon, a multi-word unit
holds together only inside one clause (a sentence terminator `।॥!?\n` in the
gap between its words breaks it), only a one-token clitic can be dangling — the
reply's first token, or one following only a sentence terminator.
`particles_within_budget` = count ≤ the spec's budget **AND** no dangling
occurrence; `mechanical_review` reports violations under the guard's own class
name `dangling_particle` (the guard flags over-budget under the same class,
per its pinned vectors — count alone is not the rule). The full
spec-machine-block mirror and drift machinery is deliberately NOT built here;
that is T-170's (wave 2) scope.

Pins added in `tests/test_chat_golden.py`:
- `ParticleRuleTests.test_the_guard_vectors_get_the_same_verdict` — the 16
  particle vectors pinned in `NepaliGrammarGuardTests` (budget boundary,
  multi-word unit at reply start, bare clitic at reply start, clitic after only
  a terminator, `हुन्छ। नि` never spanning the terminator, comma tolerated,
  token equality) get the same verdict from the eval's check.
- `ParticleRuleTests.test_occurrences_carry_position_and_reason` — position +
  reason of the dangling occurrences.
- `ParticleRuleTests.test_corrected_openings_carry_their_revision_record` — the
  4 corrected turns: current text == corrected text, old text fails the rule,
  1 revision with the old text preserved, human disposition still pending.
- `RealSetTests.test_every_reference_reply_passes_the_positional_particle_rule`
  — the whole-fixture pin: every one of the 500 reference replies passes the
  positional rule and every turn's `particles_within_budget` claim is true of
  its text.
- `RealSetTests.test_teacher_output_hashes_recompute_through_recorded_revisions`
  — the integrity pin above (all 50 batch hashes recompute; the corrected-id
  set is exactly the 4 turns).
- `AuthoringLoopTests.test_author_batch_refuses_a_reply_with_a_dangling_particle`
  — a teacher candidate with a reply-initial clitic is recorded as a
  `mechanical review` refusal with the `dangling_particle` check, and the check
  name feeds the retry prompt.
- `CorrectionTests` (6 cases) — the correction path end to end: revision
  recording and loader validation, reviewed-turn refusal, review-failing text
  refused (file untouched), bad requests refused, malformed revision entries
  refused at load naming the turn, and the CLI round trip
  (`main(["--correct-turn", ...])` with `CHAT_GOLDEN_PATH` monkeypatched to a
  temp fixture, restored in `finally`).

## Test results (exact commands)

1. `cd /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/tools/train-intent && python3 -m unittest tests.test_chat_golden`
   → `Ran 70 tests in 13.813s` — `OK` (exit 0). A second full run: 15.651 s, OK.
2. `python3 -m unittest tests.test_style_spec`
   → `Ran 42 tests in 0.684s` — `OK` (exit 0).
3. `python3 eval/author_chat_golden.py --check` → exit 0:
   - `[check] ... 500 turn(s), 50 batch(es), revision 83283663`
   - `[check] coverage: greeting 40, farewell 40, thanks 40, wellbeing 50, health_adjacent_small_talk 50, food_and_meals 40, sleep 40, family 50, weather_and_time 50, reminiscence 50, code_switched_nouns 50`
   - `[check] hard cases: short_turn 90, code_switched_input 50, reminiscence_prompt 50`
   - `[check] requirements: all_batches_mechanically_passed=yes, all_batches_human_accepted=no, turns_complete=yes, coverage_complete=yes, declared_classes_and_hard_cases_realized=yes, reference_outputs_clean=yes`
   - `[check] fixture version sha256=8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1569fcb1519 revision=83283663`
   - the only eligibility findings are the 50 human-review-pending batches.
4. `python3 -m py_compile` on the two Python files → clean.

Tests make no network calls (the teacher is injected; CLI tests run offline).

## Executed vs recorded (honesty record)

- **Executed:** all 50 batches were authored by real teacher calls
  (`gemini-2.5-flash-lite`) through the **openrouter** transport; the header,
  each batch record and each turn's provenance record it. `--check` re-reviews
  every reference offline; the counts above are from executed runs.
- **Recorded, not executed here:** all 50 human reviews are `pending` →
  `all_batches_human_accepted=no`, and `eligibility` correctly reports NOT an
  eligible gate fixture (50 findings). The human review pass is the outstanding
  owner gate; it is exercised by tests against synthetic fixtures only.
- No real user data anywhere; the header declares synthetic content.

## Decisions and deviations

1. **Two batches (b001, b004) were re-authored during this unit's
   implementation** through the designed `--force-batch` path to clear
   assistant-side mechanical flags
   (a 3-sentence reply; an `over_politeness_stacking` regex hit). Their teacher
   output was fully replaced; backups of the pre-repair file are kept at
   `/tmp/t178-backup/chat_golden.jsonl.pre-repair`
   (sha256 `60ae2947...dccdbd`). No other batch's text was touched.
2. **Corrected turns keep their batch's composition cell** (coverage class,
   hard case, context, note, user_turn untouched) — asserted by the counters in
   `--check` and by the corrected-openings pin.
3. **The 4 revisions are bundled with the review disposition in the
   `teacher_output_sha256` reconstruction test.** The hash covers the record as
   written at authoring time; `record_review` mutates
   `provenance.review.human` and `correct_output` appends
   `provenance.revisions`, so the reconstruction normalizes exactly those two
   fields (disposition → `pending`, revisions popped with `from` restored) and
   reproduces all 50 recorded hashes. This is documented in the test.
4. **History naming:** batches authored before this alignment record their
   `review.mechanical.checks` list with `"particle_budget"`; new code writes
   `"dangling_particle"` (the guard's class name). Both name the same spec
   check; the recorded lists are history and were not rewritten.
5. **Residual mechanical findings outside `acceptable_output`** (elder
   `user_turn` / context register forms) are the elder's idiolect — the spec's
   register rules bind the assistant's reply; e.g. `आयो` in an elder's context
   is first-person and spec-sanctioned. These are not reference violations and
   do not gate eligibility.
6. **No commits, no `ai-sdd` mutating commands, declared files only** (per the
   execution contract). The worktree is shared with sibling unit agents, so
   `git status` also shows their files; none of them were modified by this unit.

## Open items

- Human review of the 50 batches (the eligibility gate). The 4 corrected turns
  are `pending` like the rest of their batches — the correction is pre-review
  text, not an approval.
- T-179/T-181 consume `CHAT_GOLDEN_PATH`, `evidence()` and `held_out_keys()`;
  gate results should record the fixture sha256
  `8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1569fcb1519`.
- Regeneration (if ever) uses whichever transport is configured; the current
  file records openrouter for all 50 batches.
