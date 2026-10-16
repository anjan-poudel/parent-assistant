# Implementation Plan — Voice App Launcher (Deeplink + Camera)

**Spec:** `docs/superpowers/specs/2026-09-16-app-deeplink-launcher-design.md`
**Worktree/branch:** `.claude/worktrees/app-launcher` / `worktree-app-launcher`
**Execution:** subagents in the worktree (project rule: task work never in main checkout). Integrate via PR to master.

## Task order (each task = one commit)

### T1 — Extend app catalog + consistency test
- Add new entries to `AppLauncher.catalog` (`ios/ElderlyAssistant/Services/Apps/AppLauncher.swift:72`): camera (special, no URL), photos, settings (+ Wi-Fi/Bluetooth/Display/Accessibility panes), weather, magnifier, health, calendar, facebook, instagram, youtube, whatsapp. Each: display name, `rootURL`, web fallback where applicable, reliability tier, Nepali aliases.
- Add unit test asserting every catalog scheme string appears in `LSApplicationQueriesSchemes` (parse `ios/ElderlyAssistant/Info.plist`).
- Run `xcodebuild test` (project convention: `test` not `build` — swift-syntax shims).

### T2 — Info.plist keys
- `ios/ElderlyAssistant/Info.plist`: add `NSPhotoLibraryAddUsageDescription`; extend `NSCameraUsageDescription` (:71) to cover general photo capture; add to `LSApplicationQueriesSchemes` (:34-55): `App-Prefs`, `app-prefs` (casing verified on device), `photos-redirect`, `weather`, `x-apple-health`, `apple-magnifier`.

### T3 — `AppLauncherPlugin` (AssistantPlugin)
- New `ios/ElderlyAssistant/Services/Plugins/AppLauncherPlugin.swift`: pluginID `app_launcher`, action `launcher.open`, entity `app`; `intentContribution` exposes catalog IDs.
- Register in `AppCoordinator.makePluginRegistry()` (`AppCoordinator.swift:1746-1763`).
- First read the existing confirmation-follow-up flow in `CommandRouter.route` (`CommandRouter.swift:582`) and the call-confirmation path; reuse that machinery — plugin registers pending launch, speaks "Should I open X?", resumes on yes/no, auto-dismiss on timeout.
- Launch via injected `CallLinkOpening` seam (`Services/Intents/CallLinks.swift:37`), main-thread safe; reuse `performAppLaunch`-style honesty for not-installed (`AppCoordinator.swift:5224`).

### T4 — Camera special path
- Present `UIImagePickerController` (`.camera`) via injectable presenter seam; delegate → `PHPhotoLibrary.performChanges` add-only save → speak "photo saved" / honest failure.
- No-camera / permission-denied → spoken guidance, no crash.

### T5 — Keyword fast-path rules
- `KeywordIntentRule` entries for camera, photos, settings, weather, whatsapp, youtube, facebook — Nepali + English, exact full-lexeme matching (no partial-substring matching; Devanagari cluster regression).

### T6 — Tests
- Confirmation state machine: yes / no / timeout.
- Launch flows with mock `CallLinkOpening` opener (no real app switching).
- Camera seams (picker presenter + photo saver mocks); simulator no-camera path.
- Catalog↔Info.plist consistency (from T1).
- Voice phrase lists (Nepali + English) per catalog app for encoder evaluation.
- Run full `xcodebuild test` — all green before next task.

### T7 — Device verification checklist (manual, before PR)
- Each community-tier scheme opens its target app on physical device.
- Voice confirmation yes/no/timeout with real speech.
- Camera: capture → photo in library → spoken confirmation.
- Not-installed path: honest speech + web fallback offer.

## Out of scope (spec §Out of scope)
No Shortcuts execution, no parameterized launches, no custom camera UI, no return-to-assistant automation, no core `InterpretedCommand.Action` changes.

## Integration
Push `worktree-app-launcher`, raise PR against master (project rule: integrate via PRs). Include spec + plan docs in the PR.

---

## Verification (T6)

Full-bundle run on `worktree-app-launcher` @ `e9693ff`, no `-only-testing`:

```
xcodebuild test -project ios/seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18" \
  -derivedDataPath build/DerivedDataTests
```

Raw log `build/testlogs/fullrun-HEAD-e9693ff.log` (under the gitignored `build/`),
result bundle `build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.09.16_16-24-20-+1000.xcresult`,
baseline log `/tmp/tt6-baseline-run.log`.

**Pre-test gate — `ios/tools/check-release-log-safety.sh`: PASS** (exit 0,
`✓ no transcript content or raw error object can be printed in a non-Debug configuration`).

### Totals

| Bundle | Test cases executed | Failures | Crashes |
|---|---|---|---|
| `ElderlyAssistantTests` | 3401 | 25 | 1 runner crash, recovered |
| `ElderlyAssistantUITests` | 6 | 5 | 0 |
| **Total** | **3407** | **30** | **1** |

18 per-suite skip records. The unit runner crashed once mid-run —
`Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range` in
`VoiceTurnTimingSeamTests.testBreakdownEventIsEmittedOncePerTurnThroughTheSeam`,
after two async-wait assertion failures at `VoiceTurnTimingSeamTests.swift:589/594`.
xcodebuild printed *"Restarting after unexpected exit, crash, or test timeout"* and
resumed the remaining 218 cases, all of which passed; the 3183 pre-crash and 218
post-restart cases are disjoint, so 3401 is the distinct unit count. This is the
known flaky `VoiceTurnTimingSeamTests` behaviour, and it reproduces identically on
baseline (below).

### Feature suites — green in the full run

| Suite | Result |
|---|---|
| `AppLauncherTests` | passed — 47 tests, 0 failures |
| `AppLauncherPluginTests` | passed — 14 tests, 0 failures |
| `CameraCaptureFlowTests` | passed — 10 tests, 0 failures |
| `PhotoCameraPresenterTests` | passed — 19 tests, 0 failures |
| `PhotosLibraryPhotoSaverTests` | passed — 8 tests, 0 failures |
| `KeywordIntentRuleTests` | passed — 19 tests, 0 failures |
| `CommandRouterKeywordIntentTests` | passed — 20 tests, 0 failures |
| `CommandRouterTests` | passed — 30 tests, 0 failures |

167 tests across the eight suites, 0 failures.

### Failure classification — all 30 PRE-EXISTING, no NEW failures

Every failing test is on the known pre-existing list, and every one was reproduced
on a clean baseline. **The set difference (HEAD failures) − (baseline failures) is
empty.**

Baseline procedure: `git worktree add /tmp/tt6-baseline origin/master` (cd0c0f6),
copied the two gitignored build inputs into it from this worktree
(`ios/ElderlyAssistant/Resources/Models/whisper-medium-ne-q5_1.bin` and
`.../Models/kws/`), ran the same failing classes plus `ElderlyAssistantUITests`
with `-only-testing`, then `git worktree remove /tmp/tt6-baseline --force`.

| Failing class | Test cases | Failure records @ HEAD | Failure records @ baseline | Verdict |
|---|---|---|---|---|
| `DialectIdentifierTests` | 97 | 107 | 107 | PRE-EXISTING |
| `IntentEncoderArtifactTests` | 11 | 4 | 4 | PRE-EXISTING |
| `IntentEncoderInterpreterTests` | 36 | 3 | 3 | PRE-EXISTING |
| `IntentEncoderSideloadTests` | 11 | 1 | 1 | PRE-EXISTING |
| `IntentEncoderWiringTests` | 22 | 2 | 2 | PRE-EXISTING |
| `InterpreterAvailabilityTests` | 8 | 3 | 3 | PRE-EXISTING |
| `LocalBrainChainTests` | 28 | 2 | 2 | PRE-EXISTING |
| `ModelCatalogSTTNamingTests` | 12 | 3 | 3 | PRE-EXISTING |
| `MultipartDownloadTests` | 15 | 5 | 5 | PRE-EXISTING |
| `PiperVoiceSpeakerTests` | 13 | 1 | 1 | PRE-EXISTING |
| `VoiceTurnLatencyTracerTests` | 24 | 1 | 1 | PRE-EXISTING |
| `VoiceTurnTimingSeamTests` (crash, re-ran green) | 15 | crash | crash | PRE-EXISTING (flaky) |
| `ElderlyAssistantUITests` | 6 | 5 | 6 | PRE-EXISTING |

Per-class failure counts are byte-identical between HEAD and baseline — the only
difference runs the other way: the baseline UI run failed one extra test,
`ElderlyAssistantUITests.testQuickAccessPickerSearchWorks`, which passed on HEAD
(UI flake, not a launcher failure).

Representative baseline evidence (`/tmp/tt6-baseline-run.log`):

```
/tmp/tt6-baseline/.../DialectIdentifierTests.swift:656: error: -[... testEveryShippedRuleHasAPinnedInOutPair] :
  XCTAssertEqual failed: ("["stt-ins-0008", ...]") is not equal to ("["east-lex-rat", ...]")
/tmp/tt6-baseline/.../IntentEncoderArtifactTests.swift:63: error: -[... testCatalogEntryIsPinnedAndMarkedInternalTesting] :
  XCTAssertEqual failed: ("109079441") is not equal to ("109086647")
/tmp/tt6-baseline/.../InterpreterAvailabilityTests.swift:173: error: -[... testDefaultBrainModelIsTheRealHostedLlamaArtifact] :
  XCTAssertEqual failed: ("intent-ne-qwen4b-s43-q4km") is not equal to ("intent-ne-qwen4b-slotcanon-q4km")
/tmp/tt6-baseline/.../MultipartDownloadTests.swift:501: error: -[... testCancelCancelsEveryPartAndDeletesTheTempFiles] :
  XCTAssertTrue failed - cancelling must delete the part temp files
/tmp/tt6-baseline/.../PiperVoiceSpeakerTests.swift:195: error: -[... testCancelDuringPlaybackSettlesPromptly] :
  XCTAssertLessThan failed: ("2.570525884628296") is not less than ("1.5")
/tmp/tt6-baseline/.../VoiceTurnTimingSeamTests.swift:589: error: -[... testBreakdownEventIsEmittedOncePerTurnThroughTheSeam] :
  Asynchronous wait failed: Exceeded timeout of 2 seconds, with unfulfilled expectations: "breakdown reported".
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
```

Secondary evidence: the five launcher commits (`616d12c`, `6e3910f`, `fbce35a`,
`87a23bb`, `e9693ff`) touch only `Info.plist`, `Localizable.xcstrings`,
`AppCoordinator.swift`, `CommandRouter.swift`, `KeywordIntentRule.swift`,
`AppLauncher.swift`, the three camera files, `AppLauncherPlugin.swift`, the
launcher/voice test files and `project.pbxproj`. No source file of any failing
class above is in that set.

**Conclusion: no NEW failures. The feature is clear to integrate.**

### Deliverables added by T6

- `docs/voice-launcher-phrases.md` — the English + Nepali phrase inventory the
  keyword rules and plugin catalog recognize, grouped by app, for the follow-up
  encoder evaluation.
- This section.
