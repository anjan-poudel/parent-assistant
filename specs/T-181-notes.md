# T-181 — Chat gate harness: honorific rate, AI-ism rate and the recorded judge (implement notes)

**Status: implemented, scoped suite green (55/55) + both cross-checks green.** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`, base HEAD `95354ef7`). Declared files only.
No commits, no `ai-sdd` mutating commands. The worktree is shared with sibling wave-2
agents; their files (T-174/T-176/T-179 notes, `build_chat_corpus.py`, `CommandRouter.swift`,
…) were not touched by this unit.

## What was built

| File | Role |
|---|---|
| `tools/train-intent/src/eval_chat_gates.py` (new, 1318 lines) | The three chat gates of FR-CNR-020 / NFR-CNR-008 over the held-out set: deterministic honorific agreement + AI-ism pass rates executing the spec's machine blocks (via `author_chat_golden`'s review functions — the same execution site the fixture's own mechanical review runs), the reported positional particle count, and the recorded LLM judge (temperature 0.0; model, prompt template + sha256, rubric + sha256 in every result). Exit contract 0/1/2, JSONL evidence row, resumable judge journal. sha256 `e7ac148fdbdea817a3a2d2e89b490f0543fcbefcf15da43c15b750c55f4ac905`. |
| `tools/train-intent/tests/test_eval_chat_gates.py` (new, 1112 lines) | 55 unittest cases: spec-source pins, data-not-code spec mutations, gate shapes + the 0.98 boundary, judge parsing/run/report semantics, journal reuse/stale/refusals, outputs denominator contract, and 16 end-to-end CLI runs (happy path, each red gate, partial failure, abort, mismatch refusals, resume, the real fixture's refusal). No network calls — the judge is replayed through the `fixture` transport or injected. sha256 `484bf06c81454b612205ef9658605cd7acb031374dd9aec17538ed7510c84e5d`. |

## The contract as shipped

### Thresholds — the spec's own numbers, never re-authored

`thresholds_from_spec()` reads the spec's `rubric` machine block: honorific agreement
`>= 0.98`, no-AI-isms `>= 0.98`, judge mean `>= 4.0` (a result exactly at the threshold
passes — `>=`). A criterion with a missing/non-numeric threshold is a refusal, not a
default. The particle criterion ships as `measure: count`, `threshold: null` — it is
**reported, never gated** (T-166 decision 8); inventing a fourth gate would be a second
rule beside the spec.

### Deterministic gates — one rule, two execution sites

Both gates iterate the fixture's turns and delegate per reply to
`author_chat_golden.honorific_violations` / `ai_ism_violations` / `particle_occurrences` +
`particles_within_budget` — the functions that execute the spec's
`guard_check_inputs()` (register, ai_isms, particles blocks) and mirror the runtime
`NepaliGrammarGuard`. The particle check is the spec's **positional rule** (count within
budget AND no dangling clitic), the guard's reading. No lexicon, pattern or threshold is
restated in the module; the data-not-code tests mutate a spec copy (add a forbidden address
form, raise the particle budget, add an AI-ism) and the gates move with it.

### Judge — recorded, reproducible, resumable

- Temperature **0.0**; transports `gemini` (lazy `google.genai` client, `GEMINI_API_KEY`,
  `response_mime_type: application/json` — the house pattern of `gen_teacher.py` /
  `eval_golden.py`) and `fixture` (replay recorded scores offline; the scores file's sha256
  is part of the judge identity).
- Every result records: model id, transport, temperature, the prompt builder + full
  template + template sha256, the rubric (criteria ids, statements, scale, mean threshold,
  rubric sha256, spec provenance), the judge fingerprint (judge config + fixture sha256),
  the judge call count this run, reused-from-journal count, failed calls, unattempted
  turns, and the journal path + stale-entry count.
- The response parser is strict: exactly a JSON object with exactly `scores`, exactly the
  spec's criterion ids, true integers 1..5 (bools/floats/strings rejected). A malformed
  response is a **failed call**, never a coerced score.
- A failed call leaves the judge gate **`not_measured`** (`value: null`); the partial
  `scored_turns` count and failure ids are recorded for diagnosis but no partial mean is
  ever the gate value. The error limit (default 10) stops a dead endpoint from burning the
  whole call budget; `aborted_early` + `unattempted_turns` are recorded.
- A measured result carries the mean **with its spread**: per-criterion means, per-turn
  mean min/max/stdev and a 2-decimal histogram of per-turn means — a 4.0 hiding a 2.0 is
  visible (`turn_mean_min`), pinned by test.

### Evidence, denominators, identity

One JSON result block per run (also appended as a JSONL row with `--manifest-out`):
fixture path/schema/revision/sha256/turns/denominators/eligible; candidate artifact
path + sha256 + label; style-spec evidence (version + sha256); thresholds; the judge block;
each gate with value/threshold/denominator/offenders (capped at 20, with total) and a
`provenance` sub-block carrying fixture revision/sha256 + artifact sha256 — **the identity
T-182 consumes**. `verdict` states `chat_gates_green`, `red_gates`, `unmeasured_gates`,
`chat_exit_code`; `swap.eligible` is always false here with the reason naming the standing
hard gates (emergency recall 1.00, abstention ≥ 0.90, closed-intent ≥ 0.95, calibration,
latency) as `src/eval_golden.py`'s, run by T-182/T-183 over the same candidate identity.

### Exit contract

`0` = all three gates measured and green; `1` = any gate red **or not measured** (the
shortfall is named — gate, value, threshold, denominator — and never absorbed by moving a
threshold); `2` = refused **before scoring**: fixture invalid or not an eligible gate
fixture, artifact missing, outputs/ids mismatch (a mismatched denominator is not a gate
result), malformed journal or recorded-scores file, usage errors. Refusals write no
manifest row. There is no bypass flag; the parser test pins that.

### Resumability

`--journal PATH` appends one record per scored turn
(`{"schema", "id", "fingerprint", "reply_sha256", "scores", "at"}`). Reuse requires BOTH
the fingerprint match (judge config + fixture version) and the scored reply's sha256; a
changed reply, a changed scores file, a changed model or a changed fixture marks entries
stale and re-judges them. Corrupt/whitespace/duplicate/unknown-schema lines are refusals
(nothing silently skipped).

## Test results (exact commands, executed)

1. `cd /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/tools/train-intent && python3 -m unittest tests.test_eval_chat_gates`
   → `Ran 55 tests in 10.580s` — `OK` (exit 0). (An earlier full run on the same content: 55 in 11.092s, OK.)
2. Cross-check: `python3 -m unittest tests.test_style_spec` → `Ran 42 tests in 0.651s` — `OK`.
   Extra cross-check on the imported module's own suite:
   `python3 -m unittest tests.test_chat_golden` → `Ran 70 tests in 12.830s` — `OK`.
3. `python3 -m py_compile src/eval_chat_gates.py tests/test_eval_chat_gates.py` → clean.

Test distribution: SpecSourceTests 8, DataNotCodeTests 5, DeterministicGateTests 5,
JudgeParsingTests 4, JudgeRunTests 6, JournalTests 5, OutputsLoaderTests 6,
EndToEndCliTests 15, CommittedFixtureRefusalTests 1.

The end-to-end runs are real subprocess CLI invocations over a 500-turn synthetic fixture
built through `author_chat_golden`'s own record builders (all batches human-accepted →
eligible), with the judge replayed from a recorded-scores file — **no network calls**.
They pin: happy path exit 0 with fixture sha256/revision/denominators, artifact sha256,
spec sha256, judge config + `calls_this_run == 500`; red honorific (489/500 = 0.978, exit
1, stdout names gate/value/denominator); red AI-ism (489/500, exit 1); red judge (mean 3.9,
histogram `{"3.00": 50, "4.00": 450}`, exit 1); mean exactly 4.0 passes; partial judge
failure → `not_measured`, `value: null`, exit 1, deterministic gates still measured;
judge error-limit abort (calls 2, unattempted 498); mismatched outputs → exit 2, no
manifest; missing artifact → exit 2; ineligible fixture (pending batch) → exit 2 naming
"NOT an eligible gate fixture" + "human review pending", no manifest; empty scores file →
exit 2; journal resume (second run: 0 calls, 500 reused); changed reply → 1 call, 499
reused, 1 stale; changed scores file → 500 stale, 500 calls; `--judge fixture` without
`--judge-scores` → usage exit 2.

## Executed vs recorded (honesty record)

- **Executed (this unit):** every deterministic path, every judge path through the
  `fixture` transport / injected judge, every exit code, the journal lifecycle, and the
  CLI end to end. The **shipped fixture's refusal ran against the real file** (test not
  skipped): exit 2, message
  `… eval/chat_golden.jsonl is NOT an eligible gate fixture (50 batch finding(s)): [b001: human review pending]; …`.
- **Executed (probe, outside the suite):** `gemini_judge_fn` constructs without a network
  call and refuses an empty model id; the SDK call config carries `temperature=JUDGE_TEMPERATURE`
  (source-level check on `_call_gemini_judge`).
- **Recorded, NOT executed:** live Gemini judge calls — tests make no network calls by
  contract; the `gemini` transport is exercised only at the configuration level. The
  judge model recorded in CLI runs defaults to config.yaml's `gemini.model`
  (`gemini-2.5-flash-lite`), pinned in the happy-path test.
- **No real chat-gate RESULTS exist yet**: the shipped fixture's 50 human reviews are
  still `pending`, so `require_gate_fixture()` refuses and this harness produces refusals,
  not a verdict, against it. That is the designed surface — the refusal is exercised, the
  eligibility gate is never bypassed, and no synthetic number is presented as a real
  candidate result. T-182 consumes the same identity once the reviews land.
- The 500-turn fixture in the e2e tests is synthetic and per-run (built into a temp dir in
  ~0.03 s); nothing synthetic was committed.

## Decisions and deviations

1. **Particle budget reported, not gated** — the spec records `threshold: null`; the
   result (violations, per-reply count + dangling reasons, budget) is evidence, and the
   exit contract stays with the three thresholded gates.
2. **Not-measured semantics**: any failed/unattempted judge turn makes the judge gate
   `not_measured`; the partial scored count is recorded for diagnosis but excluded from
   the gate value. Exit is 1 either way (red or unmeasured both block the swap).
3. **Denominators are the fixture's turn count** for all three gates; the outputs id set
   must equal the fixture's exactly (a mismatch is refused before scoring — no partial
   denominator is ever scored).
4. **Artifact identity is required**, not optional: `--artifact PATH` is hashed and
   recorded with every result; a missing artifact is a refusal. T-182 can therefore join
   gate rows by `artifact_sha256`.
5. **`swap.eligible` is always false from this harness alone**; the reason string points
   the reader to the standing hard gates (`src/eval_golden.py`, T-182/T-183) and their
   thresholds are echoed from `config.yaml` into the verdict block.
6. **Journal fingerprint includes the fixture version and (for the fixture transport) the
   recorded scores file's sha256** — a different judge file or fixture version never
   silently inherits scores. Stale counts travel in the evidence.
7. **Stdlib-only module.** The CLI imports `config.load_config` (PyYAML is already a
   suite dependency through `config.py`); the gates themselves import only the stdlib plus
   the suite's `style_spec` / `author_chat_golden`.
8. **Human output** (`[gates] …` lines at meaningful intervals: fixture, candidate, spec,
   judge config, judge calls, per-gate verdicts) — progress is visible and matches the
   recorded JSON.
9. **Offenders capped at 20** (with `offenders_total`/`offenders_truncated`) and judge
   failures capped at 20 in the result — one red run cannot balloon the evidence row.
10. **No commits; declared files only** (`src/eval_chat_gates.py`, `tests/test_eval_chat_gates.py`).

## Open items

- **The 50 human reviews (owner gate)** — until they land, the shipped fixture is not
  eligible and this harness (correctly) refuses it. No real candidate gate result exists
  yet; T-182's full-harness run needs the reviews first.
- **Live judge cost path not executed here** — `--judge gemini` is implemented and
  configuration-recorded; the first real judging run (billed) is a T-182/T-183 step with
  `GEMINI_API_KEY` set. The journal makes that run resumable.
- **Fixture identity pin for T-182:** the shipped fixture remains revision `83283663`,
  sha256 `8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1569fcb1519` (currently
  ineligible); all harness results carry whatever version actually scored.
