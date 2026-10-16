# T-166 notes — Nepali chat style spec and its loader

**Status:** complete, tests green (42/42). Declared files only, nothing committed.
**Branch/worktree:** `feat/conversational-nepali-replies` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`

## Files written

| File | Role |
|---|---|
| `tools/train-intent/seeds/nepali-chat-style-spec` | THE single source of truth: prose rule text + machine blocks. version 1; sha256 `64ada91d2562bb71f446ea95d4e24d66e294184b4395ad2f99494ab5d0a46788` (of this revision — the hash changes with any spec edit; T-179/T-181 record it with run evidence). |
| `tools/train-intent/src/style_spec.py` | Stdlib-only loader, typed accessors, executable drift check, CLI. |
| `tools/train-intent/tests/test_style_spec.py` | 42 unittest cases incl. subprocess CLI end-to-end runs. |

## What was built

### Artifact format (the T-166 contract)
Plain UTF-8 sectioned text. Header carries `style_spec_version: 1` and the format/consumer/drift prose. Each section begins with `## section: <name>`; inside a section, prose lines are the **rule text** (what consumers mirror) and fenced ` ```json <block-name> ` blocks carry machine data. Rule text must have no trailing whitespace (enforced) so it can be mirrored byte-exactly. No `#` comments inside sections; JSON was chosen for the machine blocks because it is a strict subset of YAML and parses with the stdlib alone (T-166 mandates a stdlib-only loader; design §6.1's "PyYAML-parseable" intent is kept — every JSON block is valid YAML).

**Sections (all required, no defaults):** `register`, `particles`, `sentence_shape`, `small_talk`, `code_switch`, `ai_isms`, `persona_clause`, `rubric`, `guard_checks`, `coverage`.
- `rubric` added because the T-166 acceptance criteria require the eval rubric criteria by name and T-181 lists it as an input.
- `coverage` added because T-178 ("the style spec's coverage inventory") and T-179 cite a conversation-class inventory.
- `persona_clause` is prose-only: the clause text itself is the section rule text, so both personas can cite and embed it byte-identically.

### Drift-check marker contract (documented in the spec header; generic, language-agnostic)
```
# @style-spec-section: register
# <rule text, comment-prefixed or verbatim>
# @style-spec-section-end: register
```
Prefix tokens accepted: `#`, `//`, `///`, `/*`, `*`, or none. When every non-blank content line shares one prefix, that prefix + at most one space is stripped; otherwise content is verbatim. Whitespace inside the text is significant.

### Loader interface (the names downstream units cite)
`import style_spec as ss` from `tools/train-intent/src` (or `python3 src/style_spec.py` as CLI).

| Call | Returns | Cited by |
|---|---|---|
| `load(path=None)` | `StyleSpec` (default: the seeds artifact; resolves relative to the module) | all |
| `.version`, `.sha256`, `.evidence()` | version + sha256 of file bytes for run evidence | T-179/T-181/T-183 |
| `.section_text(name)` | rule text by section name | drift check, T-170 |
| `.block(name)` / `.block_names()` | machine block by name | T-179 |
| `.register()` | register block (pairs, banned familiar forms, forbidden address forms, हजुर/तपाईं) | T-167, T-169 |
| `.particle_budget()` | `1` (OD-4, single origin = `particles`) | T-169, T-181 |
| `.particle_lexicon()` | tuple, longest-match-first ordered (`हुन्छ नि`, `होला नि`, `हो नि`, `छ नि`, `अनि`, `है`, `नि`, `ला`, `ल`) | T-169, T-181 |
| `.respectful_forms()` | composed: attention marker + pronoun + honorific partners | T-167, T-171 |
| `.sentence_shape()` | SOV, `max_sentences: 2`, `one_idea_per_sentence`, `no_echo_user_words` | T-167, T-171 |
| `.small_talk_topics()` / `.code_switch_nouns()` / `.coverage_classes()` | tuples of entries | T-167, T-171, T-178, T-179 |
| `.forbidden_ai_isms()` | ban list entries (`kind: substring|regex`, `patterns`) | T-167, T-168, T-179, T-181 |
| `.persona_clause()` | the canonical byte-mirrored clause (single paragraph) | T-167, T-168, T-170 |
| `.rubric_criteria()` | deterministic criteria (honorific 0.98, no-AI-ism 0.98, particle count), judge criteria (naturalness/grammar/warmth/brevity, 1–5), `judge_mean_threshold: 4.0` | T-181 |
| `.guard_checks()` | check inventory + `latin_allowlist: []` | T-169, T-170 |
| `.guard_check_inputs()` | guard's executable inputs composed from their single origins (register/particles/code_switch/ai_isms) | T-169 |
| `check_consumer_file(path, spec)` / `check_consumers(paths, spec=None)` | `list[DriftDefect]` | T-170 |
| `main(argv)` / CLI | exit 0 ok, 1 spec load/validate failure, 2 drift defects | T-170, gates |

No default substitution anywhere: a missing section/block fails at `load()` (all missing names reported in one error); a missing block field fails at the accessor, naming `section` + `field` + "no default is substituted".

## Tests

Command (also run via discover mode, same 42):
```
cd tools/train-intent && python3 -m unittest tests.test_style_spec -v
```
Result: **42 tests, OK** (1.2 s). Coverage of the acceptance criteria:
- artifact loads; every required section returned by name; version + sha256 == hashlib of file bytes (happy path);
- missing `register` / missing `particles` → `StyleSpecError` naming the section, CLI exits 1, no default (failure path);
- drift check: clean fixture (real spec section, `#`- and `//`-prefixed and verbatim forms) passes, CLI exits 0; drifted fixture reported as `DEFECT consumer=… line=… section=…` , CLI exits 2 (failure path); unknown-section, unterminated and mixed-prefix citations also defect;
- single-origin: `budget` appears in exactly one block (`particles`), `forbidden` in exactly one (`ai_isms`), `units` in exactly one (`particles`); `guard_check_inputs()` composes from those origins;
- structural: duplicate section, invalid JSON, mis-ordered particle units, trailing whitespace, missing version all rejected;
- stdlib-only held by an AST import scan and a `python3 -I` isolated-interpreter CLI run; cwd-independence covered by subprocess tests (and manually from the worktree root).

## Decisions, assumptions, deviations

1. **JSON machine blocks in a sectioned text document** instead of a whole-file YAML document: the T-166 implementation contract says "stdlib-only Python 3 … no third-party imports", which rules out PyYAML for the loader. Each block is valid YAML (JSON ⊂ YAML 1.2), so the design's YAML intent is preserved for any future YAML consumer. Recorded as the one deviation from design §6.1's format sentence.
2. **`rubric` and `coverage` are required sections** beyond design §6.1's list — both are cited by the T-166 acceptance criteria / downstream units (T-181, T-178) and cannot live anywhere else without inventing a second home.
3. **No corpus length floor invented.** T-179's "under the length floor" filter will need a bound; the design fixes no word count for chat style (the runtime polisher's *brief* profile is 2 sentences/25 words but the shipped chat call site uses the default profile), so `sentence_shape` carries only the design-fixed bounds (`max_sentences: 2`, SOV, one idea per sentence). If T-179 wants the floor as spec data, that is a spec change (version bump), not a loader default.
4. **Particle units ordering is validated at load** (word count then character count, descending) because OD-4's longest-match tokenization depends on it; the error message says exactly that.
5. **Curated banned familiar forms** exclude `भयो`/`छ` (ambiguous in neutral/speaker-side sentences) while keeping them in `honorific_pairs` — the honest lexicon bound design §7.2/§20 records.
6. **`latin_allowlist` lives in `guard_checks`** (empty by default, per design §7.2); `code_switch` carries the Devanagari renderings and the mirror-the-user rule, so T-169 reads the allowance instead of hard-coding it.
7. **`ai_isms` entries are data** (`kind` + `patterns` + `description`): `lists_and_markdown` (regex incl. Devanagari numerals), `ai_identity` ("म एक AI हुँ", "As an AI", …), `canned_service_phrase`, `translation_ese`, `hedging_boilerplate`, `over_politeness_stacking`.
8. **Rubric numbers** mirror NFR-CNR-008/design §11.4 (0.98, 0.98, 4/5); the particle criterion is a count (`threshold: null`) because T-181 requires it *counted*, not as a third pass-rate gate — no threshold invented.
9. **anjan-ubuntu execution not performed here** (box not reachable from this unit): the loader is pure stdlib, platform-free, UTF-8, and proved under `python3 -I` without `PYTHONPATH`; DV/training-box use is the honest remaining verification, owned by T-179/T-183.
10. **No user content anywhere** — the spec is authored text with normative Nepali examples only; the loader never logs content (it prints path/version/hash and defect locations only).

## For the next units

- T-167/T-168: author both personas so they embed `persona_clause()` byte-identically inside their own wrappers, and render rules from `register()`/`forbidden_ai_isms()` — the drift check is the enforcement.
- T-170: the marker contract above is the generic check; Swift-literal extraction (like the existing `check-prompt-mirror.py`) belongs to the mirror script, which should compare against `persona_clause()`/`block(...)` values. `check_consumers()` can be called directly (stdlib import) or via `python3 src/style_spec.py --check-consumers`.
- T-169/T-181: read the budget/lexicons via `guard_check_inputs()` (composed, single-origin) — do not re-list them.
- Any spec edit is a version bump + re-recorded sha256; nothing downstream holds a copy.
