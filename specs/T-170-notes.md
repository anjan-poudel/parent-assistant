# T-170 — Prompt mirror discipline: chat template seed, persona clauses, guard lexicons (implement notes)

**Status: implemented; code/build verification green; the unit's test suite is AUTHORED but NOT
executed at unit time (amendment-4 cadence — the wave close runs the consolidated scoped pass).**
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). No commits, no pushes, no `ai-sdd` mutating commands.

## What was built (the four declared files, exactly)

### 1. `ios/tools/check-prompt-mirror.py` — extended (T-094 checker → the seven-check gate)

T-094's intent-prompt leg is preserved with its exact semantics:
`extract_build_literal` (Swift multiline-literal dedent: dedent by the closing delimiter's
indentation; the newline before the closing delimiter is not part of the value), the four
interpolations each appearing exactly once, `validate_seed`, the byte compare, `byte_diff_excerpt`
("first divergence at line N (swift X bytes / seed Y bytes)"), and the CLI flags. New behavior,
all byte-identity (design-l1 §6.3):

1. **The intent prompt's recorded pin (check 2, FR-CNR-023).** The seed is rendered by the
   training suite's OWN renderer (`tools/train-intent/src/intent_prompt.render_prompt` with its
   documented defaults: hint `"ne"`, medications `"(none)"`, empty clause) for the two fixtures
   `IntentPromptTests` pins, and the digests must reproduce the constants the Swift suite records
   (`18003ddd…24b8b78` for `"test transcript"`, `bd47910d…16e00ff` for `"भोलिको मौसम कस्तो छ?"`).
   No pin is added or moved: `INTENT_PIN_FIXTURES` ARE the shipped pins, and the test suite
   cross-checks them against the quoted digests in `IntentPromptTests.swift`.
2. **The chat template seed (check 3).** `IntentPrompt.buildChat`'s literal ↔
   `seeds/chat_prompt_template.txt` via the same mechanism with the chat's three interpolations
   (`{language_hint}`, `{address_as_clause}`, `{transcript}`); each interpolation and each
   placeholder must appear exactly once. Missing seed → a failure naming the regeneration command.
3. **Both personas (check 4).** `LlamaCommandInterpreter.chatPersonaSystemPrompt` (the local chat
   system prompt — the shipped T-167 name; design §6.2/§10's `chatSystemPrompt` label is the
   untouched COMMAND slot) and `GeminiCommandInterpreter.replyPersona` (the cloud system
   instruction): the literal must end with `style_spec.load().persona_clause()` byte-for-byte,
   exactly once, inside a transport wrapper (≥2 lines).
4. **The guard's four machine blocks (check 5).** `NepaliGrammarGuard.swift`'s
   `// @style-spec-block: <name>` regions (`register`, `particles`, `code_switch`,
   `guard_checks`) must equal the spec's fenced block BODIES byte-for-byte. The fence rules are
   `style_spec.py`'s own (`_BLOCK_OPEN_RE`/`_BLOCK_CLOSE_RE`); the extraction is cross-checked
   against `style_spec.load().block(name)` so a checker/loader divergence fails loudly.
5. **The chat token budget (check 6, NFR-CNR-004).** See decisions 1–2.

The self-test grew from 6 to 19 drift classes over a temp copy of the real tree (each must be
rejected by name): the six intent classes, the intent-pin digest, five chat-template classes
(seed byte flip, placeholder drop, builder edit without regen, interpolation drop, missing seed),
four persona classes (local drift, cloud drift, duplicated clause, wrapper removed), two guard
classes (block byte flip, marker typo), and one **consistent overrun** class (the builder grows
AND the seed is regenerated, so every byte check stays green and only the budget check can fire —
proof the budget leg is load-bearing). The shell gate runs the checker and then `--self-test`; the
self-test is not optional and has no skip knob.

`--regen-chat-seed` writes the seed byte-exactly from the builder's literal (the ONE regeneration
path, documented in both scripts' headers: edit the builder → regenerate → re-run). `--quiet` is
now consistently silent on success (previously the self-test's per-mutation lines printed anyway).

### 2. `ios/tools/check-prompt-mirror.sh` — header rewritten, invocations unchanged

The header now enumerates checks (a)–(f) and the 19 mutation classes, and documents the
regeneration command and the intent-prompt rule. The two invocations (plain, then `--self-test`)
and the failure semantics are unchanged — `ios/build.sh`'s `run_tests` wiring is untouched and
still runs the gate ahead of every test scope.

### 3. `tools/train-intent/seeds/chat_prompt_template.txt` — new, generated (not hand-written)

725 bytes, sha256 `abacefc6…34a8721`, three placeholders, trailing newline (the literal's final
blank line before the closing delimiter is part of the byte contract). Generated with:

```
python3 ios/tools/check-prompt-mirror.py --regen-chat-seed
```

Independently re-verified for this note: `chat_seed_from_builder(builder) == seed` is `True`.

### 4. `tools/train-intent/tests/test_prompt_mirror_chat.py` — new (64 test methods, 10 classes)

Stdlib-only (`python3 -m unittest tests.test_prompt_mirror_chat` from `tools/train-intent`;
the checker is loaded by path so its dashed filename is not an issue). Coverage:
pass path on the live tree (7 check lines, measured pins); Swift literal extraction incl. the
under-indented (non-compiling) case and every missing-anchor case; every chat drift class
in-process asserting the failure names BOTH files and the differing line; every persona drift
class; guard-block drift + marker-typo + the prose-mention-is-not-a-marker case + duplicated and
unclosed spec blocks; the budget (the pinned 80-Character worst-case clause, the estimator's
conservativeness against the recorded 696/677-token measurement, the consistent-overrun class);
the regeneration round trip through the real CLI (exit 0, byte-exact, derives from the CURRENT
builder, missing builder → exit 1); the CLI end-to-end (exit 0 with all seven lines, exit 1 with
both files named on stderr, `--quiet` silent); the wiring (the gate runs in `run_tests` before
`xcodebuild`); and the gate's own surface (Tree fields, guard block names, stdlib-only import
scan, the shell gate's two invocations, no skip knob).

## Decisions

1. **The token budget is a documented conservative ESTIMATE, not a tokenizer run.** The task's
   implementation note asks for the shipped tokenizer; the same task requires a zero-dependency
   script. No tokenizer artifact for the on-device brain ships in this repo (verified:
   no `*.gguf`/`tokenizer.json`/`vocab*` anywhere in the worktree; the GGUF is fetched at install
   by `ModelCatalog`; `xlmr_unigram_ref.py` is the ENCODER's XLM-R reference and needs
   `regex` + a `tokenizer.json` that is not in-repo). The check therefore computes a
   deliberately over-counting estimate: Devanagari at 2 chars/token (the corpus builder's own
   `CHARS_PER_TOKEN`, one rule two sites), everything else at 3 chars/token, ceilings summed per
   class. Calibration (recorded in the code): the weather-fixture intent prompt measures 2,540
   scalars = 2,506 Swift Characters = 696 qwen3 / 677 gemma tokens; the estimator scores it ≈861,
   i.e. the margin it computes is a LOWER bound. The exact-tokenizer legs remain T-167's recorded
   measurement + 3,000-Character ceiling in the Swift suite and T-186's sweep with the shipped
   model. Recorded as a deviation (below) and in the check's own output.
2. **The budget model.** The prompt side's share = 1,024 − 512 = 512 tokens, where 512 is the
   turn/reply allowance the chat corpus enforces (`build_chat_corpus.TURN_TOKEN_CEILING`, half
   the context, pinned "one rule two sites" by a test that reads the builder's constants from its
   source). Prompt side = the local persona literal + the worst-case chat template render
   (`{language_hint}` = "ne", `{address_as_clause}` = the shipped clause shape with a 24-Character
   term = exactly the 80-Character bound `IntentPromptTests` pins, `{transcript}` = empty — the
   turn's text is the allowance's business). At unit time: template ≈255 + persona ≈200 = ≈455 of
   512, **margin ≈57 tokens**, printed on the check line for T-186.
3. **No new pins; the pin is asserted, not re-recorded.** `INTENT_PIN_FIXTURES` are the digests
   `IntentPromptTests` already records; the check fails if the seed + training renderer stop
   reproducing them, and the suite pins the checker's constants against the Swift file's own
   quoted digests so the two origins cannot drift apart.
4. **The style spec is read through its own loader.** `style_spec.py` is imported (stdlib-only,
   relocated via `sys.path` to `tools/train-intent/src`), so the spec has exactly ONE parser. The
   loader exposes parsed dicts, not raw bodies — the gate extracts the raw BODIES with the
   loader's own fence regexes (byte equality is the contract) and cross-checks the parse against
   `spec.block(name)`; a disagreement fails the check by name rather than silently comparing the
   wrong thing.
5. **Guard markers match exactly** (`line.strip() == "// @style-spec-block: <name>"`), so the
   guard's header prose that mentions the marker form (line 18) is not mistaken for a begin
   marker — pinned by a synthetic test.
6. **Persona mutation fragility (self-test design).** The clause text appears twice in each
   persona file (the doc-comment citation and the constant). A naive `str.replace` over the file
   would move only the comment and the gate would rightly pass — so the self-test derives the
   clause line as "the line above the closing delimiter of that constant's literal" and mutates
   that, and the CLI test targets the line whose stripped text equals the clause. Both fail loudly
   if the shape changes.
7. **The chat path has no medications slot** (a chat turn executes nothing): the seed must not
   contain `{medications}`, pinned by test; the three placeholders are exactly
   `{language_hint}`, `{address_as_clause}`, `{transcript}`.
8. **`--quiet` made consistent.** A small behavior addition: the self-test's per-mutation lines
   now honor `--quiet` like the check lines do (success output can be silenced as one contract).
   The gate's exit semantics are unchanged.

## DoD mapping

| DoD item | Where |
|---|---|
| Chat template seed present and byte-identical to the builder's output | Check 3 + the seed file; pass path + 5 drift classes + the regen round trip |
| Persona-clause check covers both personas, fails on drift with the pair named | Check 4; the message names the constant file and the spec file; 4 drift classes; the both-constants subTest |
| Guard-lexicon check covers the particle budget and lexicon tables | Check 5: all four blocks, incl. `particles` (budget + units); byte equality + marker and pairing failures |
| Token-budget check runs and prints the recorded margin | Check 6: "margin ≈57 tokens" on the check line (T-186's reading point); overrun class proves it fires |
| The pinned intent prompt, its seed and its pin are asserted byte-identical | Check 1 (unchanged) + check 2 (the digest reproductions) + the Swift-digest cross-check test |
| Check executes in the scoped flow and the drift-failure path is exercised by tests | Wiring untouched (`run_tests` runs the gate before every `xcodebuild`; pinned by the wiring test); every drift class in-process and through the CLI |

Gherkin: the four pass scenarios are checks 3/4/5/6 (+ 1/2 for the pin scenario and the wiring
test for "wired into the build"); the two failure scenarios are the ChatDriftFailureTests /
PersonaMirrorTests / GuardBlockMirrorTests / budget-overrun classes (subprocess exit 1, both
files, the differing line) and the IntentPinTests (the pinned prompt untouched).

## Verification performed (amendment-4 cadence: code + build/typecheck only)

```
$ python3 -m py_compile ios/tools/check-prompt-mirror.py tools/train-intent/tests/test_prompt_mirror_chat.py
$ bash -n ios/tools/check-prompt-mirror.sh
→ ALL SYNTAX OK   (both, exit 0)

$ python3 ios/tools/check-prompt-mirror.py --regen-chat-seed
  ✓ wrote /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/tools/train-intent/seeds/chat_prompt_template.txt
    from /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift — 725 bytes, 3 placeholders, sha256 abacefc6…34a8721
    Now re-run the gate (bash ios/tools/check-prompt-mirror.sh) and commit the builder + the seed in the SAME change.
→ exit 0
```

**The gate run (final state, `./ios/tools/check-prompt-mirror.sh`) — exact output, exit 0:**

```
  ✓ the seed mirrors IntentPrompt.build byte-for-byte (2717 bytes, 4 placeholders)
  ✓ the pinned intent prompt is untouched: the seed + the training renderer reproduce both recorded IntentPromptTests digests (18003ddd…24b8b78, bd47910d…16e00ff)
  ✓ the chat seed mirrors IntentPrompt.buildChat byte-for-byte (725 bytes, 3 placeholders)
  ✓ the local chat system prompt embeds the spec persona_clause byte-for-byte (519 bytes, wrapper + clause, 2 lines)
  ✓ the cloud system instruction embeds the spec persona_clause byte-for-byte (519 bytes, wrapper + clause, 2 lines)
  ✓ the guard's 4 machine blocks mirror the style spec byte-for-byte (register 1435B, particles 191B, code_switch 671B, guard_checks 375B; spec version=1 sha256=64ada91d…0a46788)
  ✓ chat token budget: worst-case template ≈255 + persona ≈200 = ≈455 of the 512-token prompt side (1024 − 512 turn/reply allowance); margin ≈57 tokens
    (conservative estimator: 2 chars/Devanagari token, 3 chars/other — it over-counts the recorded reference measurement (the weather-fixture intent prompt: 696 qwen3 / 677 gemma tokens, estimated ≈861 here), so the margin is a lower bound; the exact-tokenizer leg is T-167's Character ceiling and T-186's sweep)
  prompt-mirror gate self-test (mutations must be rejected):
    ✓ self-test/pristine: pristine copy passes
    ✓ self-test/seed-byte-flip: drift rejected
    ✓ self-test/seed-placeholder-dropped: drift rejected
    ✓ self-test/seed-line-altered: drift rejected
    ✓ self-test/swift-interpolation-dropped: drift rejected
    ✓ self-test/swift-interpolation-duplicated: drift rejected
    ✓ self-test/extraction-broken: drift rejected
    ✓ self-test/intent-pin-digest-broken-both-sides: drift rejected
    ✓ self-test/chat-seed-byte-flip: drift rejected
    ✓ self-test/chat-seed-placeholder-dropped: drift rejected
    ✓ self-test/chat-builder-line-altered: drift rejected
    ✓ self-test/chat-interpolation-dropped: drift rejected
    ✓ self-test/chat-seed-missing: drift rejected
    ✓ self-test/local-persona-clause-drift: drift rejected
    ✓ self-test/cloud-persona-clause-drift: drift rejected
    ✓ self-test/persona-clause-duplicated: drift rejected
    ✓ self-test/persona-wrapper-removed: drift rejected
    ✓ self-test/guard-block-byte-flip: drift rejected
    ✓ self-test/guard-block-marker-removed: drift rejected
    ✓ self-test/budget-overrun-consistent: drift rejected
  ✓ every drift class is rejected; the gate is load-bearing
```

Honesty note on runs: the gate was run twice by hand — once on the pre-final checker state, then
once after two output-text edits (the estimator calibration wording) and the `--quiet` cleanup.
Both runs were exit 0 with identical check results; the block above is the FINAL state's output
verbatim. The unit's unittest suite was NOT executed (amendment-4); its first execution is the
wave-close consolidated pass.

Also verified read-only: the seed equals the builder's normalized literal byte-for-byte
(independent recomputation), and `git diff --stat` shows exactly the two declared script files
modified (`check-prompt-mirror.py` +960/−93 lines, `check-prompt-mirror.sh` header) plus the two
new declared files. Nothing else in the worktree was touched by this unit (the other dirty paths
belong to concurrent units T-174/T-176/T-179/T-181).

## Deviations and open items

1. **DEVIATION — budget check uses a calibrated estimator, not the shipped tokenizer.** Reason and
   calibration recorded in decision 1; the margin is a lower bound, the exact-tokenizer legs are
   T-167's Swift ceiling and T-186's device sweep. If the owner wants a real-tokenizer leg in this
   gate, it needs the GGUF in-tree or a tokenizer artifact — a scope/cost decision, not a code
   tweak (zero-dependency is a hard constraint of the check).
2. **DEVIATION — the design doc's `chatSystemPrompt` label for the persona constant.** Design §6.2
   and the task prompt name the persona-bearing constant `chatSystemPrompt`; the shipped T-167
   constant is `chatPersonaSystemPrompt` (the COMMAND slot keeps `chatSystemPrompt`). I mirrored
   the shipped file (per T-167's notes and the T-168 handoff). If the naming is ever unified, the
   checker's declaration string, the tests' declaration strings and the doc comments move together.
3. **The measured pins** (2717 intent bytes / 725 chat bytes / 519-byte clause / margin ≈57) are
   recorded as measured facts on 2026-10-14; a legitimate template change is expected to move the
   chat pair CONSCIOUSLY (builder + seed + the tests' numbers + this file).
4. **Open — wave close:** run `cd tools/train-intent && python3 -m unittest tests.test_prompt_mirror_chat`
   (and the wave's consolidated pass). The suite has never executed; first-run failure is
   possible and would be a real signal, not a formality.
5. **Open — T-186:** the margin line ("margin ≈57 tokens" at unit time) is the reading point; the
   exact-tokenizer double-check against the shipped model belongs to the sweep.
6. **Unchanged by this unit (asserted, not just claimed):** the pinned intent prompt, its seed
   (2,717 bytes) and its recorded pin — the gate's check line for it is the unchanged T-094
   string (`check()` was preserved verbatim in the rewrite; a test pins the exact line);
   `IntentPrompt.build` and its tests; the style spec artifact; the guard; both persona
   CONSTANTS' bytes; `ios/build.sh`. T-169's recorded golden-set decision point (4 reviewed
   replies flag under the positional dangling rule) is unrelated and untouched.

## Wave-close rework (2026-10-14)

The wave-close consolidated pass executed this unit's suite for the first time: **63/64**, one
genuine failure. This section supersedes the "suite was NOT executed" paragraph above: its first
execution happened at wave close, one failure was found, triaged, and fixed here — no assertion
was weakened.

- **Failure:** `ChatDriftFailureTests.test_a_duplicated_chat_interpolation_is_rejected` (then at
  line 351) — `AssertionError: Drift not raised`.

### Root cause: (b) incorrect test construction — with a real coverage gap behind it

Proven by probe, not assumed:

- `grep -n 'User said: "' …/Services/Voice/IntentPrompt.swift` →
  **line 123 (inside `IntentPrompt.build`)** and **line 207 (inside `buildChat`)** — the same line
  text occurs in both literals.
- The test's file-wide `.replace(…, 1)` hit the FIRST occurrence: build()'s line 123. The chat
  literal was never mutated, so the chat check rightly passed. Probe A (the test's exact
  construction, in a temp copy):
  `probe A: duplicated at file line(s) [123]` →
  `probe A: chat check PASSED  -> reproduces the failure`.
- Probe B (duplication INSIDE the buildChat literal's line range):
  `probe B: duplicated at buildChat content line 207` →
  `probe B: Drift raised -> the Swift chat literal carries 2 occurrence(s) of the interpolation
  '\(transcript)' — exactly 1 required (missing or duplicated, no partial pass)`.

So the checker's contract genuinely rejects a true duplicated-interpolation drift — **no checker
gap**; the test constructed the drift in the wrong literal. The gap it masked: the chat leg's
duplication rule had NO self-test class (the existing `swift-interpolation-duplicated` class
duplicates build()'s line, which the intent leg rejects first), so a real chat-duplication
regression would have shipped silent. Both halves are fixed.

### Fix (declared files only; iOS sources untouched)

1. `ios/tools/check-prompt-mirror.py`
   - New module-level `literal_line_range(lines, function_anchor)` → the (open, close) delimiter
     line indexes of a function's `return """` literal, with a docstring stating the
     two-occurrence hazard. `extract_return_literal` refactored to use it; its `Drift` messages
     are byte-identical (pinned by the existing extraction tests, which pass).
   - New self-test drift class **`chat-interpolation-duplicated`** (region-scoped: duplicates
     `\(transcript)` only on a line inside the `buildChat` range; raises `AssertionError` if no
     such line exists). The self-test now runs **20 classes** — the "19 drift classes" figures
     earlier in this file are superseded.
2. `tools/train-intent/tests/test_prompt_mirror_chat.py`
   - `test_a_duplicated_chat_interpolation_is_rejected` rewritten: mutates only a line inside the
     `buildChat` range via `mirror.literal_line_range` (`self.fail` if none), then asserts
     `assertIn("2 occurrence(s)")` — the original assertion, unchanged — plus
     `assertIn("transcript")`.
   - New pin `test_the_transcript_line_occurs_in_both_builders` (`count == 2`): documents WHY the
     region scoping is mandatory, so the construction bug cannot quietly return.
   - `SELF_TEST_LABELS` gains `chat-interpolation-duplicated` (now 20 labels, matching the gate).

### Rework verification (minimal recorded exception to amendment-4, exactly as ordered)

All commands from the worktree root unless noted; verbatim results:

```
$ python3 -m py_compile ios/tools/check-prompt-mirror.py tools/train-intent/tests/test_prompt_mirror_chat.py
py_compile OK

$ cd tools/train-intent && python3 -m unittest \
    tests.test_prompt_mirror_chat.ChatDriftFailureTests.test_a_duplicated_chat_interpolation_is_rejected \
    tests.test_prompt_mirror_chat.ChatDriftFailureTests.test_the_transcript_line_occurs_in_both_builders
Ran 2 tests in 0.006s
OK

$ cd tools/train-intent && python3 -m unittest tests.test_prompt_mirror_chat
Ran 65 tests in 1.972s
OK          # 64 before the rework; +1 = the new dual-occurrence pin

$ python3 ios/tools/check-prompt-mirror.py --self-test    # one read-only invocation
    ✓ self-test/chat-interpolation-dropped: drift rejected
    ✓ self-test/chat-interpolation-duplicated: drift rejected      # <- the new class fires
    … (all 20 classes + pristine green)
  ✓ every drift class is rejected; the gate is load-bearing
```

The module's pass-path tests re-verified the live tree (7 check lines, chat seed 725 bytes / 3
placeholders, intent line byte-unchanged) — the pinned intent prompt, its seed and its recorded
pin are untouched, and no regeneration ran during the rework. No other suites and no
`./build.sh` invocation were executed (per the rework order); nothing was committed.
