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

---

# T-049 + T-050 Implementation Notes — Release transcript prints (B1) + API-key/error-code log leak (B2)

- **Description:** security rework of findings B1 and B2 from `.ai-sdd/outputs/security-test.md`
  (SECURITY-NO_GO), one commit per task.
- **Tasks:** T-049 (`plan-tasks/tasks/TG-02-voice-interface/T-049-release-build-transcript-prints.md`,
  finding B1); T-050 (`plan-tasks/tasks/TG-01-foundation-infrastructure/T-050-api-key-error-code-log-leak.md`,
  finding B2).
- **Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/sec-rework-b1-b2`
- **Branch:** `worktree-sec-rework-b1-b2`, base HEAD `87ccbee` (master tip)
- **Date:** 2026-09-13
- **Commits:** `02f22dd` (T-049); the T-050 commit on this branch is the one titled
  `iOS: T-050 keep the Gemini API key and upstream bodies out of logs` (final SHA in the
  hand-back report — not self-cited here to avoid a circular reference).

## T-049 — finding B1: Release-compiled transcript prints

**Mechanism chosen** (of the options the task allows): `#if DEBUG` guards — the construct the two
Gemini engines already use (`GeminiSpeechRecognizer.swift:122-125, 129-135`;
`GeminiCommandInterpreter.swift:62-70`) — **plus** a content-free reduction of the raw-error
prints. `project.yml` sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` for the Debug
configuration only, so a guarded print is not compiled into Release at all: the transcript cannot
reach *any* Release sink, present or future. A test-only guard was rejected as the primary
mechanism because the unit suite itself runs in Debug, where a re-introduced unguarded print
still reads as "present and working".

| File:line | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/WhisperSpeechRecognizer.swift:819` | `print("[whisper_stt] transcript=" + joined)` wrapped in `#if DEBUG` with a comment recording why (WER-review aid; NFR-016 content; bypasses the sanitised bus). |
| `ios/ElderlyAssistant/Services/Voice/WhisperKitSpeechRecognizer.swift:495` | Same wrap for `print("[whisperkit_stt] transcript=" + joined)`. |
| `WhisperKitSpeechRecognizer.swift:501-508` | Raw-`error` print replaced by `#if DEBUG` + `domain=\(nsError.domain) code=\(nsError.code)` (content-free even in Debug). |
| `WhisperSpeechRecognizer.swift:836-845` | Raw-`error` print reduced to `domain` + numeric `code` and left **unguarded on purpose**: the bus event (`errorCode: "whisper_error"`) carries the Release-side signal, while attempt/duration diagnostics survive in Release and they are PII-free. This site was not on the task's list; the AC ("no raw error object … printed by either engine") covers it, so it was fixed with the same shape. |

**Preserved in Release (PII-free, intentionally still compiled in):**
`WhisperSpeechRecognizer.swift:789` and `:809-812` (`empty_transcript attempt=…`;
`transcribed attempt=… duration_ms=… audio_seconds=… chars=…`) and
`WhisperKitSpeechRecognizer.swift:482, 487` (`empty_transcript duration_ms=…`;
`transcribed duration_ms=… chars=…`). Counts and durations, never content.

**Regression guard (landed, not deferred):** `ios/tools/check-unguarded-transcript-prints.sh`
— a source gate wired into every test run from `ios/build.sh` `run_tests()` (fails the run before
the scope `case`). It walks `ios/ElderlyAssistant/**/*.swift`, tracks the `#if` stack per file in
awk (a `#else` inside a `#if DEBUG` region flips the region to *not* Debug, so the guard cannot
be defeated by an `#else` that holds the print), skips comment lines, and flags
`print(`/`NSLog(`/`os_log(` lines that mention `transcript` as a word of its own (bare
`empty_transcript` event names are not content; `transcript=` is). It also exits 1 if either
engine file is missing, so the guard cannot silently pass once the code it guards has moved.

Proof the guard can fail (a guard that cannot fail is not a guard):
- synthetic regression — an unguarded `print("[whisper_stt] transcript=…")` added to a copy of the
  tree → exit 1 with the exact `file:line`;
- missing engine file → exit 1 with "guarded engine file is missing";
- real tree → exit 0, printed in both gate runs as
  `✓ no transcript-content print can be compiled into a non-Debug configuration`.

**Android verification (verified, not assumed):** `android/` has 20 Kotlin files and **no STT or
speech-recognition code at all** (`grep -ri whisper|stt|speech` → no sources), so there is no
counterpart of this fix on Android. The only transcript-shaped string in the tree is iOS-side.

## T-050 — finding B2: the API key and raw upstream bodies must not reach a log sink

**The leak of record:** the key rode in the request URL query (`…?key=<API_KEY>`), a transport
failure rethrew URLSession's `URLError` (whose description embeds the failing URL), the emitter
sites stringified it with `String(describing: error)` into `error_code`, and `LogSanitiser`
copied `error_code` through unscrubbed. Four independent fixes:

**(a) The key travels in a header, never a URL** — `GeminiClient.swift:233-254` (streaming) and
`:400-416` (unary): both URL builders dropped `?key=…` / `&key=…`, both requests now
`setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")`. URLs are recorded by error
descriptions, proxies and crash reports; headers are not. The URL-shape-asserting tests were
updated to assert the header and the absence of `key=` (`GeminiKeyLogBoundaryTests`, new).

**(b) One shared mapping helper, six `String(describing: error)` sites replaced** — new
`ios/ElderlyAssistant/Services/Observability/ErrorCodeMapper.swift`:
`static func code(for: Error) -> String` consults the `LogSafeErrorCode` protocol first (domain
error types name themselves: `GeminiClientError` → `not_configured`/`invalid_url`/
`invalid_response`/`http_<status>`/`empty_response`/`blocked_by_provider`/`daily_cap_reached`;
`RecognitionError` → e.g. `timed_out`, `recognition_failed`) and otherwise falls back to the
`NSError` bridge: `url_error_<code>` for `NSURLErrorDomain` (so `-1004` unreachable host /
`-1001` timeout stay diagnosable), else a charset-filtered domain token + numeric code. It never
reads `localizedDescription`, `String(describing:)`, `userInfo` or any URL. Call sites are one
line each:

| Site | Was | Now |
|---|---|---|
| `GeminiSpeechRecognizer.swift:144` | `String(describing: error)` | `ErrorCodeMapper.code(for: error)` |
| `GeminiCommandInterpreter.swift:111` | `String(describing: error)` | `ErrorCodeMapper.code(for: error)` |
| `VoicePipeline.swift:857-864` | `String(describing: err)` **and** `let msg = "STT: \(err)"` | `let code = ErrorCodeMapper.code(for: err)`; `errorCode: code`; `msg = "STT: \(code)"` |
| `GeminiClient+Vision.swift:120` | `String(describing: error)` | `ErrorCodeMapper.code(for: error)` |
| `ApplianceHelperSession.swift:192` | `String(describing: error)` | `ErrorCodeMapper.code(for: error)` |
| `NepaliCalendarPlugin.swift:92` | `String(describing: error)` | `ErrorCodeMapper.code(for: error)` |

**(c) The boundary now bounds `error_code` whatever an emitter does** —
`LogSanitiser.swift:24-38, 79, 85-98`: `boundErrorCode(_:)` scrubs first (phone/e-mail/BP
patterns), then requires a code charset (`^[A-Za-z0-9][A-Za-z0-9._:,;\-]*$`); a value that fails
it is *not a code* and becomes `"[redacted]"`; a charset-valid value is capped at
`maxErrorCodeLength = 64`. The allow-list (`:41-55`), the unscrubbed `stages` guarantee, router
event codes (`jsonRemnant`, `dup_source`, `reason.rawValue`), plugin collision lists (comma-joined),
`"429"` and `"a,b"` all still pass verbatim (regression tests).

**(d) The raw upstream body is dropped** — `GeminiClientError.httpError(status:body:)` became
`httpError(status: Int)` (`GeminiClient.swift:50-57`); the throw at `:444` no longer builds a
`String(data:)`; the `gemini_http_error` event still carries the status (`errorCode: "429"`), so
diagnostics survive without upstream text. The two pattern-matching tests
(`GeminiClientTests.swift:59`, `GeminiCostGovernorTests.swift:291`) were updated
compile-driven; assertion strength is unchanged.

**Tests added (19, all passing in the gate run — verified per-test in the `.xcresult`):**

| Test | Proves |
|---|---|
| `GeminiKeyLogBoundaryTests` (9) | unary + streaming requests carry the key in `x-goog-api-key` and not in the URL; `ErrorCodeMapper` emits content-free codes and never reads descriptions (a `LocalizedError` whose `errorDescription` carries the sentinel maps to a code without it); the interpreter (`interpret_failed`) and STT (`transcribe_failed`) emitter sites map a key-bearing `URLError` to `url_error_-1004`/`url_error_-1001`; a *rogue* future emitter that stringifies a key-bearing error is still bounded at the `ConsoleObservabilityBus` sink; an HTTP 429 whose body contains the sentinel keeps the status and loses the body. |
| `LogSanitiserTests` (10) | the existing contract (allow-list/drop, `stages` verbatim, PII scrub, top-level fields unchanged) plus the new bound: content-free codes verbatim, nil/empty → nil, a key-bearing `URLError` *description* → `[redacted]` (with a sanity assertion that the raw description really does contain the sentinel), bare URL and quoted descriptions redacted, over-long code-shaped value truncated to 64. |

**How the end-to-end test exercises the real path** —
`testForcedTransportFailureLeaksNoKeyMaterialToTheConsoleSink`: a real `GeminiClient` configured
with the sentinel key, a transport that fails exactly the way URLSession does (throws `URLError`
carrying the attempted request URL in `NSURLErrorFailingURLErrorKey`/`…URLStringErrorKey`), and
the real `ConsoleObservabilityBus` (`LogSanitiser` + `print`) as the sink, driven through the real
`identifyAppliance` → `send` → error-handling path. Process stdout is redirected to a temp file
with `dup`/`dup2`/`fflush` around the call, and the assertions are made against the *printed
line*, not an in-memory event copy — with anti-vacuous-capture guards
(`logged.contains("gemini_vision_identify")` and `errorCode=url_error_`) so a silent capture
cannot pass. NFR-016: the sentinel `sentinel-not-a-real-key-000` is deliberately not key-shaped,
and the upstream bodies in the tests are synthetic.

**Android verification (verified, not assumed):** `android/` has no Gemini client
(`grep -ri gemini|generativelanguage` → 0 matches) and no URL-borne key, so (a), (b) and (d) have
no counterpart. Its only `error_code` emitters are `null` and the constant
`"fcm_delivery_failed"` (`FamilyNotifier.kt:32`), and `LogcatObservabilityBus`
(`PreferencesEncryptedStorage.kt:70-78`, still a documented dev stub pending T-004) logs only
component/eventType/outcome/metadata — never `errorCode` — so (c) has no counterpart either.

## Gate — exact command and raw result

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/sec-rework-b1-b2/ios
./build.sh test:unit
```

Result: `Executed 2691 tests, with 6 tests skipped and 3 failures (0 unexpected) in 311.921 s`
→ **2683 passed, 2 distinct failing tests, 6 skipped**; exit 65.

Both failing tests are **pre-existing at the base `87ccbee` and unrelated to this rework**, and
were not touched (the coordinator confirmed this and instructed not to edit them):

- `BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList()`
  (`…swift:18`) — expects 4 brain ids; `ModelCatalog.availableBrainEntries` (`ModelCatalog.swift:812-818`)
  now lists 5, headed by `intentQwen4BS43` = `intent-ne-qwen4b-s43-q4km`.
- `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact()`
  (`…swift:172, 182`) — expects `intentQwenS43`; `AppCoordinator.swift:1170` sets
  `defaultBrainModelID = ModelCatalog.intentQwen4BS43` (a LAN/local URL, hence the second failure).

Root cause: commit `34c81b9` ("ship the gate-passing 4B intent brain (slim, seed 43)"), which is an
**ancestor of the base** `87ccbee`. Proof of non-causation without a bisect: those four files
(`ModelCatalog.swift`, `AppCoordinator.swift`, the two test files) are byte-identical on this
branch to `87ccbee` — `git diff 87ccbee -- <the four files>` is 0 lines — and
`git diff --name-only 87ccbee..HEAD` contains no file under `Services/ModelStore`, `App/` or the
two test files. The base therefore already fails these assertions; deciding which brain is the
default is a product call outside T-049/T-050 (it sits next to the descoped B5 LAN-URL finding),
and weakening the assertions to force green was explicitly not done.

All 19 new tests passed in the same run (checked per-test in
`Test-ElderlyAssistant-2026.09.13_05-21-17-+1000.xcresult`, not inferred from the aggregate), as
did the pre-existing Gemini, LogSanitiser, STT and voice suites.

**Precondition handled:** this fresh worktree lacked the three gitignored model resources
`project.yml` validates. Symlinking them (`kws`, `tts/*`, `whisper-medium-ne-q5_1.bin`) got the
build through but the simulator installer rejected the bundle —
`invalid symlink at …/ElderlyAssistant.app/tts/en_US-lessac-medium-int8`, `MIInstallerErrorDomain
Code=70` — so the fix was: real copies for `kws` (5.3 MB) and the two `tts/` voice dirs (75 MB),
and a **hardlink** for the 559 MB `whisper-medium-ne-q5_1.bin` (no extra disk; this is the
existing repo practice — the main checkout's copy already had link count 19). Nothing under the
main checkout was written; no gitignored resource is tracked or committed.

## Open items / residual risk

- The B1 guard is scoped to the two known engine files by name (plus a missing-file failure). A
  *third* on-device STT engine added later would not be covered until it is added to
  `ENGINE_FILES` — named follow-up, not silently assumed.
- The `LogSanitiser` bound protects `error_code` only; metadata values are still pattern-scrubbed
  (unchanged, defence in depth). A future *new* allow-listed key carrying free text would need its
  own treatment — that is the pre-existing design, not a regression.
- `GeminiClientError.blockedByProvider(reason:)` still holds provider text as an associated value
  but is never mapped into `error_code` (the dedicated `gemini_blocked` event carries the provider
  enum `blockReason`, itself charset-shaped and bounded at the sink).
- No secret material was added to tests or fixtures (NFR-016); no assertion was weakened, skipped
  or deleted.
