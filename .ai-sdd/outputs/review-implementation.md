# Review: review-implementation (T-042)

## Decision: **GO**

All T-042 acceptance criteria and Definition-of-Done items are met. The transcript decision ("fix the
code, keep the documented contract") is implemented exactly as designed: both router dispatch paths
build `PluginCommand` through one shared helper that sanitises the pending utterance with
`InputSanitiser.sanitise(_:level: .quarantine)`, the extraction fallback is reachable and pinned by a
regression test, the guide's load-bearing claims match the code they cite, the dead localisation key is
gone with no hard-coded replacement, and the change stays in scope. The canonical unit gate passes
(2672 tests, 0 failures) and all task-relevant tests pass individually.

## Artifact under review

- Task: `review-implementation` (ai-sdd project `elderly-ai-assistant-sdd`)
- Code artifact: commit **`6e3eb93`** ("iOS: fix PluginCommand.transcript contract + plugin-architecture.md
  truth-up (TG-09 T-042)") on `master` of `/Users/anjan/workspace/projects/elderly-ai-assistant`.
  Its content is the byte-identical equivalent of worktree commit `fb7113c` on branch
  `worktree-agent-a0805e8a135d6eb8d` (verified: `git diff 6e3eb93 fb7113c --` over the seven tracked
  files is empty).
- Notes artifact: `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant/specs/implement-notes.md`
  (cosmetically edited after the commit; see Limitations).
- Task spec: `.ai-sdd/outputs/plan-tasks/tasks/TG-09-plugin-recognition-contract/T-042-transcript-contract-and-doc-truth.md`.

## Scope examined

Commit `6e3eb93` (8 files: 7 tracked modifications + the task's own `.ai-sdd/outputs/implement-notes.md`):

| File | Reviewed change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | new `makePluginCommand` helper (`:2376-2384`); both dispatch paths use it (`:2302`, `:2340`); skeleton wording removed from `handleGuide` doc + `.failed` branch |
| `ios/ElderlyAssistant/Services/Plugins/AssistantPlugin.swift` | `PluginCommand.transcript` doc rewritten (`:65-71`) |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 3-line comment documenting the screen-initiated empty-transcript case (`:5352-5354`) |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | dead key `plugin.applianceHelper.notReady` removed (was `:7687`) |
| `docs/plugin-architecture.md` | registration, flow/exceptions, per-brain paragraph, transcript paragraph, reference list, invariants, hard-rule rewording |
| `ios/ElderlyAssistantTests/Services/Intents/GuidePluginDispatchTests.swift` | header corrected; additive transcript assertions; one new test |
| `Services/Voice/CommandRouterTests.swift` (under `ios/ElderlyAssistantTests/`) | two new tests (transcript contract + fallback regression) |

Context examined: parent commit `d19a8de`, master commit `7d42852` (claimed source of the two
pre-existing failures), later repair commit `a952a1b`, and the current `master` HEAD `967b163`. The
seven reviewed files are identical at HEAD to `6e3eb93` except `AppCoordinator.swift` (one unrelated
line: brain default) and `CommandRouterTests.swift` (an unrelated calculator-wait flake fix).

## Criteria table

### T-042 acceptance criteria (Gherkin)

| Criterion | Verdict | Evidence |
|---|---|---|
| Transcript decision implemented at every production construction site | PASS | Production `PluginCommand(...)` sites by repo grep: `CommandRouter.swift:2379` (the shared helper) and `AppCoordinator.swift:5355` (screen-initiated, `transcript: ""`, now commented as the contract's empty case). No others. |
| Fix-the-code branch: transcript is `InputSanitiser.sanitise(_:level: .quarantine)`-processed | PASS | `CommandRouter.swift:2380` calls `InputSanitiser.sanitise(pendingTranscript ?? "", level: .quarantine)`; same sanitiser the interpreters use (`InputSanitiser.swift:42-75`). |
| Non-empty only when the user actually spoke | PASS | `pendingTranscript` is set to the raw utterance immediately before `dispatchInterpreted` on both entry paths (`CommandRouter.swift:587`, `:1087-1089`) and cleared after; the only voice-less site passes `""` and is documented. |
| Both dispatch paths built by one shared helper with identical field semantics | PASS | `makePluginCommand` (`:2376`) called at `:2302` (normal `.plugin`) and `:2340` (guide deferral); the old raw `sourceTranscript` local is removed (diff). |
| Regression test asserts the transcript is present on the normal path | PASS | `CommandRouterTests.testPluginIntentPassesSanitisedTranscriptToPlugin` (`CommandRouterTests.swift:262`): adversarial prefix → asserts `"do the test thing"` (not `""`, not raw). |
| `extractQuestion` fallback reachable on the normal path | PASS | `CommandRouterTests.testNormalPluginDispatchReachesApplianceQuestionFallback` (`:295`) routes `"माइक्रोवेभ कसरी चलाउने"` with `pluginEntities: ["question": ""]` through `router.route` and asserts `ApplianceHelperPlugin.extractQuestion(from: handled)` returns the sanitised transcript (`ApplianceHelperPlugin.swift:88-95`). |
| Test pins the regression (empty path cannot return silently) | PASS | The new test fails against the pre-fix code (`transcript: ""` → `extractQuestion` nil); it asserts both the transcript field and the fallback return. |
| Registration step: lazy first-use factory, not `init` | PASS | Guide (`:10-14`) vs code: `private(set) lazy var pluginRegistry = makePluginRegistry()` at `AppCoordinator.swift:1156` (with `[BOOT-REVIEW P0-1]` comment), factory at `:1275-1285`. |
| Reference list names all four registered plugins | PASS | Guide names NepaliCalendarPlugin, ApplianceHelperPlugin, RoutinePlugin, YouTubePlugin; `makePluginRegistry()` registers exactly those (`AppCoordinator.swift:1277-1283`). |
| ApplianceHelperPlugin described as live, not a skeleton | PASS | Guide (`:133-138`) cites the live camera flow (`ApplianceHelperPlugin.swift:69-106`; tests at `ApplianceHelperPluginTests.swift:73, 88` — both line references verified). Skeleton claims removed from guide, `handleGuide`/`.failed` comments, and the test header. |
| Only honest failure = unconfigured client | PASS | `ApplianceHelperPlugin.swift:70-74` returns `.failed` with `plugin.applianceHelper.notConfigured` (key exists at `Localizable.xcstrings:7670`). |
| "Recognised regardless of brain" replaced by per-brain reality | PASS | Guide (`:66-79`); verified: Gemini composes fragments (`GeminiCommandInterpreter.swift:72-75`), on-device Llama deliberately does not (`LlamaCommandInterpreter.swift:319-326`), `LocalIntentInterpreter` builds `IntentPrompt.build(transcript:context:)` with no registry (`:106`); escalation qualification verified (`AppCoordinator.swift:3691-3715`, `cloudEnabled = fallbackEngages` at `:3715`; `cloudBrain` wiring `:2153`; `IntentRouter.swift:177-248`). |
| "ONLY core case" wording corrected; two hard-coded lookups documented | PASS | Guide (`:54-64`). Verified `.plugin` is the only plugin-action case in `dispatchInterpreted` (`CommandRouter.swift:2106-2150`) and the only direct lookups are `CommandRouter.swift:2336` (`appliance.identify`) and `AppCoordinator.swift:5349` (`nepali_calendar.query`); no others by grep. |
| Compile-time-only and iOS-only invariants stated | PASS | Guide `Invariants` section cites `PluginRegistry.swift:7-9` (verified). No `dlopen`/`NSClassFromString`/bundle loading in `ios/ElderlyAssistant` (grep empty); Android has no plugin code (grep for `AssistantPlugin`/`pluginRegistry`/`PluginCommand`/action literals in `android/` returns nothing). |
| Dead key removed; no hard-coded replacement | PASS | Removed in the diff; `git grep notReady 6e3eb93` finds only unrelated `settings.voiceEngine.*.notReady` keys and task/notes prose; catalogue is valid JSON at both `6e3eb93` and HEAD (`python3 -m json.tool`). |
| Stale test header corrected without changing guide-fallback assertions | PASS | `GuidePluginDispatchTests.swift:5-8` now describes live behaviour; fallback tests keep their assertions (`:92-:121`); the only assertion change is additive (`:74-75`). `ApplianceHelperPluginTests.swift:5-7` already accurate, untouched. |
| No PII in observability (NFR-016); sanitisation preserved (NFR-013) | PASS | `makePluginCommand` emits nothing; router `emit` (`CommandRouter.swift:2606`) carries empty metadata; dispatch events unchanged. Commit touches no interpreter file (verified), and all three still sanitise: `GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, `LocalIntentInterpreter.swift:101`. New test fixtures are synthetic. |

### Definition of Done

| Item | Verdict | Evidence |
|---|---|---|
| Transcript decision at every production construction site, tests for both paths | PASS | As above. |
| Regression test pins the extraction fallback | PASS | `CommandRouterTests.swift:295-334`. |
| Guide corrected (registration, four plugins, ApplianceHelper, per-brain, core-case, invariants) | PASS | Guide lines cited above; every spot-checked file:line resolves to the claimed code at `6e3eb93`. |
| Dead key removed, no hard-coded replacement | PASS | Diff + catalogue JSON validation. |
| Stale GuidePluginDispatchTests header corrected | PASS | `:5-8`. |
| Doc and code landed in the same commit | PASS | `6e3eb93` contains code + tests + guide + catalogue; `git diff 6e3eb93 fb7113c` over these files is empty, so the integrated commit equals the reviewed worktree commit. |
| No PII in events; NFR-013 preserved | PASS | As above. |

### Standards checklist (constitution + reviewer checklist)

| Item | Verdict | Evidence |
|---|---|---|
| Explicit error return types on interface methods (not any/unknown) | PASS / N-A | No interface change; `AssistantPlugin.handle` returns `PluginResult` with an explicit `.failed` case (`AssistantPlugin.swift:87-94`). |
| Async/external calls have documented failure mode and recovery path | PASS | `handleGuide` doc now states the honest fallback ("no registry/client, or `handle` fails"); `.failed` branch comment updated (`CommandRouter.swift:2350-2355`); guide's "No silent stubs" rule (`:110-112`). |
| Timeouts/retries configurable, not hardcoded | N-A | This diff introduces no timeout or retry; `makePluginCommand` and `InputSanitiser` are synchronous and pure. |
| Every element traces to an FR/NFR | PASS | FR-008 (plugin recognition), NFR-013 (quarantine sanitisation), NFR-016 (no PII in logs/events), NFR-023 (no hard-coded user-facing strings). |
| Operator-visible success and failure described | PASS | Guide describes spoken results, the presented camera sheet, and the heard `.failed` fallback; runtime behaviour is unchanged except the (intended) now-reachable appliance fallback. |

### Scope

| Item | Verdict | Evidence |
|---|---|---|
| Diff stays in scope; 7 tracked files match subjects; no unrelated edits | PASS | `git diff 6e3eb93^ 6e3eb93 --name-status` = 7 tracked modifications + the task's own notes file. Every hunk belongs to the transcript contract, the truth-up, the dead key, or the stale comments. No unrelated edits found. |

## Test-gate result

I ran the canonical gate myself: `./ios/build.sh test:unit` in the main checkout (prerequisites present:
Xcode 26.6, xcodegen 2.46.0, model resources). Raw tail of the run:

```
Test Suite 'ElderlyAssistantTests.xctest' passed at 2026-09-13 01:45:21.535.
	 Executed 2672 tests, with 6 tests skipped and 0 failures (0 unexpected) in 223.984 (228.165) seconds
Test Suite 'All tests' passed at 2026-09-13 01:45:21.539.
** TEST SUCCEEDED **
	 ✓ unit tests passed
[exited with code 0]
```

Per-test verdicts extracted from the `.xcresult` (`Test-ElderlyAssistant-2026.09.13_01-40-48-+1000.xcresult`),
not inferred from the aggregate: `testPluginIntentPassesSanitisedTranscriptToPlugin` Passed,
`testNormalPluginDispatchReachesApplianceQuestionFallback` Passed,
`testGuideDefersToPluginWhenItServes` Passed,
`testGuidePathSanitisesTranscriptLikeTheNormalPluginPath` Passed,
`testPluginIntentDispatchesToRegisteredPlugin` Passed, plus all four existing
`GuidePluginDispatchTests` fallback tests Passed.

## The two cited pre-existing failures — confirmed pre-existing and unrelated

The notes claim the two failures observed in the worktree run
(`BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList`,
`InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact`) are pre-existing on
master and introduced by `7d42852`. **Confirmed**, by three independent checks:

1. `7d42852` ("Qwen 4B Nepali brain entry (LAN testing) + Qwen fine-tune as default brain") is an
   ancestor of `6e3eb93` and of its parent `d19a8de`; it added `qwen4BNepali` to
   `ModelCatalog.availableBrainEntries` and moved `defaultBrainModelID` from `llama3_2_1B` to
   `intentNepali1B`, while the two test files still asserted the old snapshot
   (`BrainModelSelectionTests.swift:14-19`; `InterpreterAvailabilityTests.swift:164-178`).
2. `6e3eb93` touches neither those test files nor `ModelCatalog.swift`/the default-brain symbol, so it
   cannot have caused or affected those failures.
3. A later master commit, `a952a1b` ("iOS tests: repair two stale brain-catalogue/default
   expectations"), repaired exactly those two assertions and its message names exactly these causes
   ("7d42852 added qwen4BNepali ... and moved defaultBrainModelID off the legacy LLaMA 1B"). That is
   why my HEAD run shows 0 failures where the worktree run showed these 2.

## Findings

No blocking findings. Non-blocking observations for the record:

1. **Stale statements in the notes (explicitly flagged, not re-litigated).** The notes' final section
   ("Working tree: 7 tracked modifications ... Nothing committed, nothing pushed") is stale: the work
   is committed as `6e3eb93` on `master` (and exists as worktree commit `fb7113c` on branch
   `worktree-agent-a0805e8a135d6eb8d`), and the worktree directory
   `.claude/worktrees/agent-a0805e8a135d6eb8d` no longer exists. Per the review brief, this is noted
   rather than treated as a missing artifact; content equivalence between `fb7113c` and `6e3eb93` was
   verified directly (empty diff over all seven tracked files).
2. **Second production construction site.** `AppCoordinator.nepaliCalendarAnswer` (`:5355`) constructs
   `PluginCommand` directly, bypassing the router's private helper. It satisfies the documented contract
   (empty only when no voice utterance) and is now commented, and the task's design decision scoped the
   helper to the two router dispatch paths, so this is compliant. Residual risk: if transcript
   semantics ever change again, that site must be updated manually.
3. **Notes artifact drift.** The committed `.ai-sdd/outputs/implement-notes.md` differs cosmetically
   from `specs/implement-notes.md` (one added Description bullet; the adversarial fixture described in
   prose instead of a literal). No factual consequence for this review.
4. **Comment-range citations in the notes are approximate** (e.g. `CommandRouter.swift:2325-2332,
   2348-2353`) but the content they describe is present at those locations; the guide's citations,
   which are load-bearing, all resolve exactly (including the previously self-referential
   `AppCoordinator.swift:5349`, now the guard that carries the literal, with the command construction at
   `:5355`).

## Verification limitations and residual risk

- The reviewed worktree no longer exists; equivalence with the committed artifact was established via
  `fb7113c` (byte-identical for all seven tracked files).
- The unit gate was run at `master` HEAD `967b163`, not at `6e3eb93` itself. This is materially the
  reviewed code: the six reviewed files are identical at HEAD, and the only two deltas are unrelated
  (`AppCoordinator.swift` brain-default line; `CommandRouterTests.swift` calculator-wait flake fix).
- The notes' original gate run reported "9 tests skipped"; my HEAD run reported 6 skipped. Different
  runs/configuration; immaterial to the verdict.
- Review was static plus the unit gate: no manual/simulator interaction with the live appliance camera
  flow was performed (not required by T-042, which specifies unit-level verification).
- Pre-existing, untouched by this diff: `InputSanitiser.maxLength` is a hard-coded 200-character clamp,
  and `GeminiCommandInterpreter.swift:67-69` has a DEBUG-only raw-transcript `print`. Neither is
  introduced or modified by `6e3eb93`; noted only as residual risk outside this task's scope.

## Conclusion

**GO.** The implementation matches T-040's decision and every T-042 acceptance criterion, the guide's
load-bearing claims were re-verified against the cited code (line references resolve correctly,
including the corrections made after the paired review), the dead key is fully removed, and the
canonical unit gate passes with all task-relevant tests green. The two test failures recorded in the
implementation notes are confirmed pre-existing on master (introduced by `7d42852`, repaired later by
`a952a1b`) and unrelated to this change.
