# T-138 — Release log gate: dialogue feature roots and fixtures — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`, base 3b44c0c — W1+W2 committed). Unit:
C-MTC-10, TG-27, wave W3. Design references: design-l2 §17 (C-MTC-10 release-gate
edits) and §26; design-l1 §22 / ADR-MTC-14; NFR-MTC-004, NFR-MTC-012.

## Status

Done and green. The four dialogue source files joined `FEATURE_ROOTS` (17 → 21
entries) and each new root now has per-root fixture plants in both rule trees the
design names, with `expect` tokens pinning the planted paths. The full gate
(`check-release-log-safety.sh`: engine + fixtures suite) exits 0, the opt-in
`--falsify` discipline stays green, and the gate ran green inside a real scoped
build under the shared lock (`./build.sh test:unit DialogueOptionCatalogTests`,
rc=0). No rule was widened, no allow-list entry was added, no `build.sh` edit, no
git actions.

## Files modified

- MODIFIED `ios/tools/check-release-log-safety.py` — `FEATURE_ROOTS` gains exactly
  four entries, with a tagged comment block in the shipped style:
  `Services/Voice/DialogueManager.swift`, `Services/Voice/DialogueAnswerPath.swift`,
  `Services/Voice/DialogueCandidateBuilder.swift`, `Services/Voice/DialogueOptionCatalog.swift`
  (per-file form, as design-l2 §17 pins and the Spotify/point-ask/profile-interview
  entries establish; the rest of `Services/Voice/` stays out of scope). Diff is
  +12 lines, appended after the Spotify block, nothing else touched — no rule
  (`RULES`), no allow-list default, no scan logic.
- MODIFIED `ios/tools/log-safety-fixtures/feature-console-write/positive/expect` —
  the four new planted paths appended after the existing
  `App/ProfileInterviewSteps.swift` token.

## Files created

Fixture trees (16 Swift plants, 8 positive + 8 negative, all at the four roots'
exact source-root-relative paths), per design §17's two shapes:

- NEW `ios/tools/log-safety-fixtures/feature-console-write/positive/ElderlyAssistant/Services/Voice/`
  — `DialogueManager.swift`, `DialogueAnswerPath.swift`, `DialogueCandidateBuilder.swift`,
  `DialogueOptionCatalog.swift`: one content-free Release console write each
  (rule `feature-console-write`; no `#if DEBUG`, no content word, so the tree
  stays orthogonal for `--falsify`).
- NEW `ios/tools/log-safety-fixtures/feature-console-write/negative/ElderlyAssistant/Services/Voice/`
  — the same four paths, clean (no console write, no event field): the roots scan
  clean sources quietly; the existing negative files were not touched.
- NEW `ios/tools/log-safety-fixtures/feature-content-print/positive/ElderlyAssistant/Services/Voice/`
  — the same four paths, each a console write rendering that file's content
  (`probeText`, `rawText`, `candidateTexts`, `optionTexts`) inside `#if DEBUG`:
  the content rule is judged in every configuration and must reach where the
  Release-framed write rule cannot look, keeping the two rules orthogonal.
- NEW `ios/tools/log-safety-fixtures/feature-content-print/positive/expect` — the
  four planted paths, one token per line.
- NEW `ios/tools/log-safety-fixtures/feature-content-print/negative/ElderlyAssistant/Services/Voice/`
  — the same four paths with the content words present as *data* (read/counted,
  never rendered): the rule is scoped to console writes, so these must pass.
- NEW `specs/T-138-notes.md` (this file).

Nothing else was touched. `specs/implement-notes.md` shows as modified in the
worktree but that predates this unit (the session's own W2 gate-r2 edits); it was
not opened for edit. No `.ai-sdd/` file, no test file, no production Swift file,
no `project.yml` edit. No git commands.

## What was built

### 1. Root extension (the "scanned set" half)

The four dialogue files now classify as `feature` sources, so rules 3-6
(`feature-console-write`, `feature-content-print`, `feature-unlisted-metadata-key`,
`feature-text-interpolated-into-event`) apply to them on top of the
transcript/raw-error family. Verified mechanically with the engine's own
predicate (path == root or path.startswith(root + "/"), the exact join the
scanner uses): all four real files resolve `feature`, `exists=True`. The engine
over the real tree stays exit 0 (the T-131 integration note — the file carries
its own source-scan test and was clean by construction — held: zero console
writes, zero `emit(`, zero metadata literals in the four files; only comments
mention those words).

### 2. Per-root fixtures (the "proven guarded" half)

The fixture model is per-rule trees under
`log-safety-fixtures/<rule>/{positive,negative}/ElderlyAssistant/…`, run by the
harness as subprocesses of the real engine (not imported, not stubbed). A
positive tree must exit 1, name the rule, and contain every `expect` token in the
gate's output; `expect` exists precisely to pin WHICH file was caught — the new
tokens are the evidence that the four new roots are the files being caught, not
their older siblings. The two shapes §17 names are planted per root: the
printed console line (rule 3) and the raw content write (rule 4).

No count assertions exist in the tooling (checked): the harness prints
`N case(s) over M rule(s)` but never asserts it, and the counts stay **24 cases
over 12 rules** because the change adds files inside existing rule trees, not
new trees. Fixture **files** go 38 → 55 (16 Swift + 1 expect added; +this notes
file outside the tree). So nothing in `check-release-log-safety-fixtures.py` or
`.sh` needed updating — and nothing was updated there.

### 3. What was deliberately NOT done

No rule widened, no allow-list entry added, no negative fixture edited, no
`build.sh` change (the gate is already wired after `xcodegen generate`;
verified in the scoped build log). Rules 5/6 (metadata key, text-interpolated
event field) also apply to these four roots structurally — the role is
path-scoped, per-file — but §17's fixture obligation names the two console
shapes, so no per-root plant was added for those two rules; their existing
fixtures keep exercising them. Recorded here rather than left implied.

## Tests

### Gherkin coverage (fixtures suite cases are the automated tests)

| Scenario | Automated coverage |
|---|---|
| The four new roots are scanned | Fixture plants at all four exact relative paths trip the gate (direct runs below); engine-predicate check resolves the four real files to `feature`; real-tree engine run rc=0. |
| Every new root caught and named by its expect token | Both `expect` files list the four paths; `feature-console-write/positive` and `feature-content-print/positive` pass the harness with those tokens present in the output. |
| Existing negative fixtures stay green; no rule relaxed | Existing negative files byte-unchanged; new negative pairs rc=0; gate diff touches no rule/allow-list; fixtures suite green; `--falsify` green (every rule still load-bearing alone). |
| Full gate exits zero as wired into the build | Scoped build ran `check-release-log-safety.sh` in-build before the test scope: engine ✓, all 24 fixture cases ✓, then 10/10 tests. |

### Evidence — gate runs (2026-10-10 AEDT)

1. Full gate, `bash ios/tools/check-release-log-safety.sh` (16:46:35–16:46:39,
   log `/tmp/mtc-t138-gate.log`): **rc=0**.

```
  ✓ no transcript content or raw error object can be printed in a non-Debug
    configuration, and the live-camera-translation sources carry no console
    write or content-bearing event field
  log-safety fixtures: 24 case(s) over 12 rule(s)
    ✓ … (24 cases, all ✓, incl. feature-console-write/positive+negative,
      feature-content-print/positive+negative)
  ✓ every rule has a positive and a negative fixture, and every fixture behaves
```

2. Fixtures suite with the optional falsification discipline,
   `python3 check-release-log-safety-fixtures.py --falsify`: **rc=0** — all 12
   rules still load-bearing (disabling a rule makes its positive tree pass),
   i.e. the new plants trip their intended rule and nothing else.

3. Direct engine runs over the modified positive trees (the "planted violation
   inside any of them fails" line, with the planted file named):

```
feature-console-write/positive → rc=1, 8 violations, incl.:
  ElderlyAssistant/Services/Voice/DialogueManager.swift:15: [feature-console-write] …
  ElderlyAssistant/Services/Voice/DialogueAnswerPath.swift:14: [feature-console-write] …
  ElderlyAssistant/Services/Voice/DialogueCandidateBuilder.swift:14: [feature-console-write] …
  ElderlyAssistant/Services/Voice/DialogueOptionCatalog.swift:14: [feature-console-write] …
feature-content-print/positive → rc=1, 8 violations, incl.:
  ElderlyAssistant/Services/Voice/DialogueManager.swift:14: [feature-content-print] …
  ElderlyAssistant/Services/Voice/DialogueAnswerPath.swift:13: [feature-content-print] …
  ElderlyAssistant/Services/Voice/DialogueCandidateBuilder.swift:14: [feature-content-print] …
  ElderlyAssistant/Services/Voice/DialogueOptionCatalog.swift:13: [feature-content-print] …
feature-console-write/negative → rc=0;  feature-content-print/negative → rc=0
```

4. Engine over the real tree with the extended roots: **rc=0** (the clean-tree
   pass the fixtures suite then proves is not vacuous).

### Evidence — in-build wiring (E4 producer half)

Scoped build under the shared lock (`mkdir /tmp/mtc-w1-build.lock` protocol), run
`cd ios && ./build.sh test:unit DialogueOptionCatalogTests`:
lock acquired 16:45:29, **rc=0** 16:46:05, lock released. Log
`/tmp/mtc-t138-build.log`; xcresult
`ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_16-45-44-+1100.xcresult`.
The build log's privacy-guard block (lines 17-46) shows the engine pass, then
`log-safety fixtures: 24 case(s) over 12 rule(s)` with every case ✓ including
`feature-console-write/positive` and `feature-content-print/positive`, then
`✓ every rule has a positive and a negative fixture, and every fixture behaves`.
Per-suite: `DialogueOptionCatalogTests` — **10 executed, 10 passed, 0 failures**
(`Executed 10 tests, with 0 failures (0 unexpected)`), `** TEST SUCCEEDED **`,
`✓ unit tests passed`, `=== Scoped unit run passed (baseline not advanced) ===`.

## DoD checklist

- [ ] Code reviewed and merged — not this unit's to close (integration).
- [x] All Gherkin scenarios covered by automated tests (fixtures suite cases;
  mapping table above).
- [x] E4 DoD line: the gate exits 0 including its fixtures suite over the four
  new roots (in-build evidence above; T-140 adds the runtime log-capture half).
- [x] No existing rule relaxed; negative fixtures unchanged and green
  (`--falsify` green; existing negative files untouched; no rule/allow-list edit).
- [x] Focused gate run green locally; no new full-suite failures — the scoped
  build is rc=0 and the change touches only `ios/tools/` (not compiled); the
  recorded master baseline (~21 pre-existing failures in unrelated suites) is
  unaffected.

## Open items / deviations

1. **"Mirror the spotify fixture cases" (task file) has no referent.** There are
   no Spotify-named fixture cases in this repo — verified in this worktree and
   the main checkout (`grep -rl Spotify ios/tools/log-safety-fixtures/` empty)
   and in the fixtures dir's git history (only live-translate, profile-interview
   and near-miss commits). The shipped per-root precedent actually followed is
   the profile-interview pair in `feature-console-write`
   (`App/ProfileInterviewSteps.swift` positive+negative, with the `expect` token)
   plus the live-translate per-rule trees. From Spotify, the mirrored form is the
   `FEATURE_ROOTS` per-file entry style the task file itself cites (`:141`).
2. **Rules 5/6 per-root plants not added** — see "What was deliberately NOT
   done"; §17 names two shapes, so two rule trees received per-root plants.
3. **Fixture case counts unchanged (24/12)** by construction (files, not trees,
   were added); reported so nobody reads the unchanged printed number as
   "nothing ran".
4. No `build.sh` edit was needed and none was made; the build log proves the
   gate's own invocations run unchanged.

## Integration notes for sibling units

- **T-140** (cache-bypass/log-capture/egress): the runtime log-capture half of
  E4 is yours; this unit's half is the static gate exit 0 with per-root fixtures
  (evidence above). The gate is now a live backstop over all four dialogue files
  for anything landing in W3-W7.
- **T-133/T-136** wiring work in the four files (or their callers): the roots are
  live now — any console write, any content-worded event field, any unlisted
  metadata key introduced into the four files fails `ios/tools/check-release-log-safety.sh`
  on the next build, so the six T-137 keys (`intake`, `probe_kind`, `attempt`,
  `option_count`, `capture_form`, `merge_source`; `reason` reused) are the only
  metadata vocabulary available there.
- **T-139/T-141/T-142**: no interface change; the gate is unchanged in shape,
  and its known static limits (engine docstring, "Known limitations") are
  unmodified and remain part of the evidence wording.
