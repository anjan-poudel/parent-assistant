# T-042 Implementation Notes — PluginCommand.transcript Contract + guide truth-up

- **Description:** Implementation record for T-042 — make every `PluginCommand` carry the quarantined-sanitised utterance by routing both router dispatch paths through one shared helper, and truth-up `docs/plugin-architecture.md` plus the stale in-code comments that called the ApplianceHelper plugin a skeleton.
- **Task:** T-042 (TG-09 plugin recognition & contract)
- **Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/agent-a0805e8a135d6eb8d`
- **Branch:** `worktree-agent-a0805e8a135d6eb8d` (base HEAD `84410de`, master)
- **Date:** 2026-09-12
- **Decision applied (recorded, not re-litigated):** fix the CODE, keep the documented contract.
  `PluginCommand.transcript` is the sanitised utterance. Both router dispatch paths now build
  the command through one shared helper that runs `InputSanitiser.sanitise(_:level: .quarantine)`
  — the same sanitiser the three interpreters use, reused, not duplicated.

## Code changes

| File:line | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift:2376` | New `makePluginCommand(actionName:entities:confidence:)` — the single `PluginCommand` construction point; `transcript = InputSanitiser.sanitise(pendingTranscript ?? "", level: .quarantine)`. |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift:2302` | Normal `.plugin` path now uses the helper (was `transcript: ""`). |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift:2340` | Guide-deferral path now uses the same helper (was the raw `pendingTranscript`); `sourceTranscript` local removed. |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift:2325-2332, 2348-2353` | `handleGuide` doc comment and the `.failed` branch comment no longer call the plugin a skeleton; they describe the live plugin and the honest fallback. |
| `ios/ElderlyAssistant/Services/Plugins/AssistantPlugin.swift:65-71` | `PluginCommand.transcript` doc now states the sanitisation policy, the "empty only when no voice utterance" rule, and points at `ApplianceHelperPlugin.extractQuestion`. |
| `ios/ElderlyAssistant/App/AppCoordinator.swift:5352-5355` | Comment documents why the screen-initiated `nepaliCalendarAnswer` passes `transcript: ""` (no voice utterance — the contract's empty case; input travels as the `question` entity). Code unchanged. |

All production `PluginCommand` construction sites were enumerated by grep: the two router paths
(fixed) and `AppCoordinator.nepaliCalendarAnswer` (documented, correctly empty). No other site.

NFR-016: the helper adds no observability and logs no transcript; the new tests use synthetic
plugin ids/actions and no PII.

## Documentation changes — `docs/plugin-architecture.md`

- 60-second version step 2: registration is `AppCoordinator.makePluginRegistry()`
  (`AppCoordinator.swift:1275-1285`), a lazy first-use factory (`:1156`), deliberately NOT built
  in `init` ([BOOT-REVIEW P0-1]).
- Flow section: "the ONLY core case" replaced by "the only plugin-action case in core's switch",
  followed by the two explicit exceptions — `appliance.identify` in `CommandRouter.handleGuide`
  (`CommandRouter.swift:2336`) and `nepali_calendar.query` in
  `AppCoordinator.nepaliCalendarAnswer` (`AppCoordinator.swift:5353`) — described as fixed
  core-owned flows, not per-plugin hooks.
- New per-brain recognition paragraph: cloud Gemini brain composes `promptFragment`
  (`GeminiCommandInterpreter.swift:72-75`); on-device brains do not
  (`LlamaCommandInterpreter.swift:319-326`; `LocalIntentInterpreter` unregistered) so plugin
  recognition is cloud-only today.
- New paragraph documenting `PluginCommand.transcript` semantics.
- ApplianceHelperPlugin reference entry now describes the live camera/vision flow
  (`ApplianceHelperPlugin.swift:69-106`; tests at `ApplianceHelperPluginTests.swift:73, 88`); the
  only honest failure is the unconfigured client (`ApplianceHelperPlugin.swift:70-74`).
- Reference list now names all four registered plugins: NepaliCalendarPlugin,
  ApplianceHelperPlugin, RoutinePlugin, YouTubePlugin.
- New "Invariants" section: compile-time-only registration (`PluginRegistry.swift:7-9`, no
  `dlopen`/`NSClassFromString`/bundle loading) and iOS-only runtime (no plugin code in Android;
  verified by scan — Android matches are Gradle `plugins {}` blocks only).
- "No silent stubs" hard rule reworded off the skeleton framing.

## Dead key and stale comments

- Removed `plugin.applianceHelper.notReady` from
  `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (was line 7687). Verified no Swift,
  test, tool or doc reference existed (repo-wide grep); catalogue re-validated with
  `python3 -m json.tool` (OK). No hard-coded replacement string introduced (NFR-023).
- `GuidePluginDispatchTests.swift:5-7` header corrected: the plugin is live; `.failed`
  (e.g. unconfigured client) or no registry falls back to the understand-call steps. The inline
  "skeleton" comment in the guide-fallback test (`testGuideFallsBackToSteps*` in that file) was
  updated too. Assertions are unchanged except additive transcript assertions.
- `ApplianceHelperPluginTests.swift:5-7` header already described live behaviour
  (intent vocabulary, question extraction, handle→present); left unchanged.

## Tests added (existing targets, no new dependencies)

| Test | Proves |
|---|---|
| `CommandRouterTests.testPluginIntentPassesSanitisedTranscriptToPlugin` (`CommandRouterTests.swift:262`) | Normal `.plugin` path delivers the sanitised utterance: the test's adversarial prefix (the instruction-override phrase used by the sanitiser fixtures, plus whitespace padding) → `"do the test thing"` (injection marker stripped, whitespace collapsed) — not `""`, not raw. |
| `CommandRouterTests.testNormalPluginDispatchReachesApplianceQuestionFallback` (`:295`) | Regression the fix exists for: normal dispatch of `"माइक्रोवेभ कसरी चलाउने"` with `pluginEntities: ["question": ""]` reaches `ApplianceHelperPlugin.extractQuestion`, which returns the sanitised transcript instead of nil. |
| `GuidePluginDispatchTests.testGuideDefersToPluginWhenItServes` (transcript assertion added) | Guide-deferral path carries the same sanitised utterance. |
| `GuidePluginDispatchTests.testGuidePathSanitisesTranscriptLikeTheNormalPluginPath` (`:80`) | Guide path sanitises too: adversarial prefix stripped → identical field semantics with the normal path (one shared helper). |

No PII in any fixture (synthetic plugin ids `test_plugin`/`appliance_helper`, synthetic actions).

## Verification — exact command and raw result

Command (canonical iOS gate, from the worktree root):

```
/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/agent-a0805e8a135d6eb8d/ios/build.sh test:unit
```

which runs, per `ios/build.sh:400-455`:

```
xcodebuild test -project <worktree>/ios/seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18 \
  -derivedDataPath <worktree>/ios/build/DerivedDataTests -skip-testing:ElderlyAssistantUITests
```

Raw result (tail of the run):

```
Test Suite 'ElderlyAssistantTests.xctest' failed at 2026-09-12 21:49:32.008.
	 Executed 2672 tests, with 9 tests skipped and 2 failures (0 unexpected) in 186.751 (193.192) seconds
Failing tests:
	BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList()
	InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact()
** TEST FAILED **
[exited with code 65]
```

Both failures are **pre-existing on master and unrelated to this task**: they assert the
pre-Qwen brain catalogue/default (`BrainModelSelectionTests.swift:14-19` expects
`[intentNepali1B, qwen3_4BInstruct, qwen3_1_7BInstruct]` while `ModelCatalog.swift:771-776` now
also offers `qwen4BNepali`; `InterpreterAvailabilityTests.swift:165-178` expects
`AppCoordinator.defaultBrainModelID == ModelCatalog.llama3_2_1B` while
`AppCoordinator.swift:1170` sets the fine-tune default). Those symbols are untouched by this
diff (which is limited to the files listed above). They were introduced by master commit
`7d42852` ("Qwen 4B Nepali brain entry … Qwen fine-tune as default brain") and need a separate
task; I did not touch them (out of scope, keep-diff-tight).

The task-relevant tests all passed in the same run (verified per-test in the `.xcresult`, not
inferred from the aggregate): `testPluginIntentPassesSanitisedTranscriptToPlugin`,
`testNormalPluginDispatchReachesApplianceQuestionFallback`,
`testGuideDefersToPluginWhenItServes`,
`testGuidePathSanitisesTranscriptLikeTheNormalPluginPath`,
`testPluginIntentDispatchesToRegisteredPlugin` — all `Passed`.

Precondition handled: this fresh worktree lacked two gitignored model resources required by
`project.yml`, so xcodegen refused the project (`whisper-medium-ne-q5_1.bin`, `kws`). Both path
patterns are gitignored (`.gitignore:33,47`); I symlinked them from the main checkout
(read-only links, never added to git) and the gate then generated and ran normally.

Additionally, the UI suite was not run (`test:unit` is the repository's unit gate; UI tests are
unaffected by these changes). No Android work (the guide records the iOS-only invariant).

### Earlier failed attempt (reported for completeness)

`./build.sh test:unit` first exited 1 at `xcodegen` because of the two missing gitignored model
resources. Symlinking them fixed the prerequisite; the run above is the result of the second
invocation.

## Unverified / open items

- T-039 and T-040 have not run. The guide's per-brain paragraph documents the **live** behaviour
  (cloud brain composes plugin fragments; on-device brains do not) and the two hard-coded
  core lookups are documented as fixed core-owned flows with the code left unchanged. If T-040's
  eventual decision is to replace those lookups with registry-provided constants, only the guide
  wording (not this diff's code) needs revisiting.
- The T-040 decision was supplied by the task instruction (fix the code) and applied as given;
  the why-doc (`docs/superpowers/specs/2026-09-05-plugin-architecture-design.md`) was not edited
  by this task.
- Working tree: 7 tracked modifications, this notes file (untracked), and the two model-resource
  symlinks under gitignored paths. Nothing committed, nothing pushed (per task instructions).

## Review follow-up (paired review, GO at 0.90 — doc-only corrections)

Three documentation imprecisions were corrected in `docs/plugin-architecture.md`; no code, test
or catalogue file was touched in this pass (verified: only the guide's mtime moved — 22:06 vs
21:37-21:38 for every other changed file; `git status --short` still lists exactly the same 7
tracked modifications as before the review).

1. **`nepali_calendar.query` citation (guide line 60).** Cited `AppCoordinator.swift:5353`, which
   is the comment this task added — self-referential. Now cites `AppCoordinator.swift:5349`, the
   registry lookup that carries the literal (the command construction follows at `:5355`).
   Re-checked with `sed -n '5347,5356p' ios/ElderlyAssistant/App/AppCoordinator.swift`.
2. **Per-brain consequence overstatement (guide lines 68-73).** The old text said an on-device
   turn "will not classify into your plugin and instead falls through to core/keyword handling".
   Corrected: the mechanism claim stands (on-device brains do not compose plugin fragments), but
   the consequence is now qualified — the on-device brain alone cannot emit plugin actions, while
   the on-device stack's opt-in cloud escalation (`applyVoiceEngineStack`, `.onDevice` branch,
   `AppCoordinator.swift:3691-3715` → `intentRouter?.cloudEnabled = fallbackEngages` at `:3715`)
   lets `IntentRouter` escalate to the `cloudBrain` (`AppCoordinator.swift:2153`;
   `IntentRouter.swift:177-248`), which does compose fragments; core's `.guide` flow also defers
   to `appliance.identify` on any brain (`CommandRouter.swift:2336`). Re-checked by reading all
   four cited regions and `GeminiCommandInterpreter.swift:72-75`.
3. **"all built in" `makePluginRegistry()` (guide line ~120).** Reworded: four plugins are
   registered there; three are built inside the factory, `RoutinePlugin` is constructed eagerly in
   `init` (`AppCoordinator.swift:1432`) and only registered by the factory (`:1279`). Re-checked
   with `sed -n '1275,1285p'` and `sed -n '1430,1433p'` of `AppCoordinator.swift`.

The earlier unit-gate result stands unchanged: the correction pass touched documentation only, so
the `ios/build.sh test:unit` run (2672 tests, 2 pre-existing unrelated failures, all
task-relevant tests passed) remains valid and was deliberately not re-run.
