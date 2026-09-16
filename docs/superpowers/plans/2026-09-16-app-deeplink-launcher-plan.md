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
