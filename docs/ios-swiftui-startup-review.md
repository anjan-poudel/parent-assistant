# iOS SwiftUI Startup, Performance, and Design Review

## Purpose

Implementation handoff for improving the iOS application's startup latency, perceived responsiveness, SwiftUI update efficiency, and elderly-focused visual design.

Review scope: `ios/` only. The review used `avdlee/swiftui-agent-skill@swiftui-expert-skill` and inspected the current application on an iPhone 16 Pro simulator.

## Verified baseline

- Current iOS source builds successfully for the iPhone 16 Pro simulator.
- The rendered Home screen was reviewed in the running simulator.
- The Debug simulator application bundle measured approximately **768 MB**.
- The bundle contains `whisper-medium-ne-q5_1.bin` at approximately **559 MB**, two TTS model trees, a KWS model, ONNX Runtime, Sherpa, and `llama.framework`.
- `project.yml` resolves a 55-target dependency graph and links SwiftWhisper, LLM, WhisperKit, ZIPFoundation, and sherpa-onnx into the application target.

## Executive decision

Keep the immediate Home shell usable and gate capabilities independently. Do not make a single global boot phase stand for data restoration, safety scheduling, wake-word construction, pipeline readiness, and optional model warming.

Target startup sequence:

1. Render the stable Home shell.
2. Keep emergency and settings controls immediately available.
3. Restore safety-critical schedules promptly without blocking the first frame.
4. Show stable skeletons for data-dependent content.
5. Gate the Talk control on actual voice-pipeline readiness.
6. Warm optional STT/TTS engines after minimum voice readiness, without a global spinner.
7. Load network and secondary-feature services on demand.

## Findings and implementation tasks

### P0 — Make the pre-first-frame composition root lightweight

#### Problem

`AppCoordinator` is created before the first SwiftUI frame in `ios/ElderlyAssistant/App/ElderlyAssistantApp.swift:5`. Its initializer, `ios/ElderlyAssistant/App/AppCoordinator.swift:1019-1550`, still performs synchronous storage reads, filesystem setup, service creation, audio/AI construction, plugin registration, and callback wiring.

Notable synchronous work includes:

- Gemini Keychain reads: `Services/Gemini/GeminiConfigStore.swift:30-33`.
- Gemini cost-governor Keychain read: `Services/Gemini/GeminiCostGovernor.swift:98-118`.
- Alarm/timer restoration: `Services/Alarms/AlarmTimersService.swift:450-461`.
- Routine seed read/write: `App/AppCoordinator.swift:1118-1120` and `Services/Reminders/RoutineStore.swift:86-92`.
- Application Support lookup and directory creation: `Services/ModelStore/ModelStore.swift:33-53`.

`AppCoordinator.start()` also performs substantial synchronous work before `startupBoot.begin()` at `App/AppCoordinator.swift:1823`, including schedule rearming and most voice/speech/router composition.

#### Change

- Introduce a lightweight root/bootstrap model containing only:
  - persisted UI preferences required for the first frame;
  - onboarding state;
  - startup state;
  - minimum navigation and safety-control state.
- Move secondary service construction out of `AppCoordinator.init()`.
- Call `startupBoot.begin()` before synchronous post-frame composition.
- Yield one main-actor turn before starting expensive work so SwiftUI can commit the loading state.
- Lazily construct feed, manuals, Gemini, local LLM, contact search, media, and appliance services when their feature first becomes relevant.
- Preserve immediate restoration of safety-critical reminders, but execute storage reads and schedule reconciliation outside the render-critical path.

#### Acceptance

- No Keychain read, large filesystem operation, model lookup, or AI runtime construction occurs before the first meaningful SwiftUI frame.
- Home, Settings, and Emergency controls appear before service restoration completes.
- Startup instrumentation proves first-frame timing separately from capability readiness.

---

### P0 — Gate Talk on actual voice readiness

#### Problem

The global boot can reach `.ready` at `App/AppCoordinator.swift:2055` while `voicePipeline.start` is still awaiting its asynchronous callback at `App/AppCoordinator.swift:2116-2132`.

`TalkButton` remains enabled for `.stopped` and `.error` in `App/HomeView.swift:866-870`. Tapping during startup can enter recovery behavior instead of presenting an honest loading state.

#### Change

Add a dedicated voice-readiness model, independent of `StartupBootStage`:

```swift
enum VoiceReadiness: Equatable {
    case loading(VoiceLoadingStage)
    case ready
    case failed(VoiceStartupFailure)
}
```

- Publish `.ready` only from the successful `voicePipeline.start` callback.
- While loading:
  - keep the Talk hero in its final dimensions;
  - display `ProgressView` inside the hero;
  - show a localized stage label;
  - disable Talk activation and recovery gestures.
- On failure, show one specific explanation and one recovery action.
- Keep wake-word readiness separate from manual Talk readiness. Manual Talk should become usable even if wake-word activation degrades to its Null implementation.

#### Acceptance

- Talk cannot invoke recovery merely because startup has not completed.
- The UI never says “Ready” before the voice pipeline callback succeeds.
- Wake-word failure does not prevent manual Talk when the microphone/STT pipeline is usable.
- Failure states identify the unavailable capability and offer a deterministic recovery action.

---

### P0 — Replace the 2.5-second minimum spinner duration

#### Problem

`StartupBoot.spinnerMinVisibleSeconds` is 2.5 seconds at `App/StartupBoot.swift:81-90`. A fast boot therefore looks slow after work has completed.

#### Change

Use delayed spinner appearance rather than delayed dismissal:

- Do not show the indicator for the first 150–250 ms.
- If the operation finishes before the delay, never show it.
- Once shown, dismiss as soon as the represented capability is ready, using only a short visual transition.
- Reserve final layout dimensions so appearance and removal do not shift surrounding controls.

#### Acceptance

- A sub-delay boot shows no spinner.
- Completion never remains visually “loading” for an artificial multi-second floor.
- Slow operations still show localized, capability-specific progress.

---

### P0 — Remove main-thread ONNX construction on physical devices

#### Problem

`bootPrepareVoiceEngine()` invokes `makeWakeWordEngine()` synchronously on main at `App/AppCoordinator.swift:1889-1895`. The documented off-main crash applies to the x86_64 simulator, but the workaround currently affects every runtime target.

#### Change

- Preserve the main-thread workaround only where proven necessary, initially behind `#if targetEnvironment(simulator)`.
- On physical devices, construct the wake-word ONNX session on one dedicated serial executor.
- If physical-device profiling proves that Sherpa requires main-thread construction, perform it only when wake-word listening is enabled and gate only wake-word status.
- Add a signpost around KWS model resolution and session construction.

#### Acceptance

- Physical-device KWS construction does not block main-thread animation or input.
- Simulator behavior remains crash-free.
- Main Thread Checker, startup trace, and wake-word functional smoke test pass.

---

### P1 — Stop copying the bundled 559 MB model during global boot

#### Problem

`bootFinishSetup()` invokes bundled model installation at `App/AppCoordinator.swift:2027-2041`. The large copy is off-main but still creates disk contention, storage duplication, thermal pressure, and a long global startup phase.

#### Change

- Prefer reading immutable bundled model files directly.
- Copy only artifacts that require writable or transformed storage.
- If copying is unavoidable, perform it when the relevant local model is selected or first used.
- Show determinate byte progress in the model-specific UI.
- Run housekeeping at utility QoS rather than competing with initial UI work.
- Review whether SwiftWhisper, LLM, WhisperKit, and Sherpa are all still required in the production path. Remove superseded runtime and model combinations rather than retaining duplicate inference stacks indefinitely.

#### Acceptance

- Normal application startup never copies hundreds of megabytes.
- The application does not retain duplicate bundle and Application Support copies without a documented runtime requirement.
- Missing or preparing local models affect only local-AI controls, not Home readiness.

---

### P1 — Move general application data out of Keychain

#### Problem

`StartupDataBatch.load` performs multiple separate encrypted-storage reads at `App/AppCoordinator.swift:2152-2171`. Keychain is also used for histories, contacts, schedules, feeds, and appointments.

#### Change

Use Keychain only for small secrets and encryption keys. Store larger structured data in encrypted files or SQLite under Application Support with Data Protection Complete.

Suggested split:

- Keychain: API credentials, authentication secrets, database/file encryption key.
- Encrypted Application Support storage: contacts, appointments, histories, reminder state, feed configuration, cached presentation data.

Provide a transactional migration that reads existing Keychain payloads, writes and verifies the new encrypted store, then removes only the successfully migrated legacy item.

#### Acceptance

- Startup data restoration uses one transactional database/file open rather than numerous `SecItemCopyMatching` operations.
- Existing user data survives migration.
- Data remains unavailable while the device is locked where required by the security constitution.

---

### P1 — Split broad SwiftUI invalidation boundaries

#### Problem

`HomeView` observes the entire `AppCoordinator` at `App/HomeView.swift:56`. The coordinator exposes dozens of `@Published` properties and forwards nested object changes wholesale at `App/AppCoordinator.swift:1522-1538`.

`HomeView.swift` is over 1,200 lines. Most sections are computed properties or functions, which do not establish separate SwiftUI invalidation boundaries.

#### Change

While iOS 16 remains supported, split published UI into focused `ObservableObject` models:

- `HomePresentationState`
- `VoicePresentationState`
- `StartupState`
- `NavigationPresentationState`
- feature-specific presentation models

Extract real `View` types with narrow value inputs:

- `HomeTopBar`
- `QuickAccessStrip`
- `TalkStage`
- `FeedbackRegion`
- `HomeDock`

Publish derived notification count only when reminder or briefing state changes. Do not recompute/filter/sort widget rows for every unrelated Home invalidation.

If minimum deployment later moves to iOS 17, migrate focused models to `@Observable`; do not simply convert the existing monolithic coordinator.

#### Acceptance

- Feed translation, model-download progress, settings changes, and unrelated timers do not re-evaluate the Talk hero.
- Voice animation/state updates do not rebuild the dock and top bar.
- Instruments SwiftUI cause graph shows materially narrower update fan-out.

---

### P2 — Remove repeated work from view evaluation

#### Evidence

- New date formatters in `App/AlarmsTimersSettingsView.swift:209-213`, `App/HistoryView.swift:320-324`, and `App/LeafViews.swift:675-680`.
- Sorting/filtering in computed view properties.
- Contact photo resolution during row composition.
- Repeated dynamic-size calculations through computed token properties.

#### Change

- Cache formatters by locale.
- Build row presentation values when source data changes.
- Keep encrypted storage and image-file reads out of `body`.
- Downsample contact and manual images to their rendered size and retain bounded decoded-image caches.

#### Acceptance

- Scrolling and state updates do not perform file access or construct formatters repeatedly.
- Image decoding does not cause visible row hitches or unbounded memory growth.

## Recommended startup presentation

### Immediately visible and interactive

- Home background and stable layout.
- Settings.
- Emergency action.
- Static navigation that does not require restored data.

### Individually gated

| Capability | Presentation |
|---|---|
| Date/history/contact data | Same-size skeleton or neutral placeholder |
| Voice pipeline | Spinner inside Talk hero; disabled until callback success |
| Wake-word engine | Separate status; must not block manual Talk |
| Optional STT/TTS warm | Detached; no global startup spinner |
| Feed/network features | Load on entry with local card spinner |
| Large model preparation | Model-specific determinate progress |
| Failure | Named feature, persistent degraded state, one recovery action |

Cached content should remain visible while refreshing. Never replace useful cached content with a spinner.

## Design and accessibility improvements

### Existing strengths

- Calm, approachable Home surface.
- Clear visual priority for the central Talk control.
- Voice phases use icon, text, and color rather than color alone.
- Warm palette is friendlier than a clinical dashboard.
- Emergency styling is distinct.
- Tappable controls generally use `Button` or `NavigationLink`.
- Breathing motion respects Reduce Motion.
- Launch screen has no network, model, or custom-font dependency.

### Clarify ready versus optional setup

The rendered Home showed a ready Talk control alongside a warning-style “3 tasks remaining” treatment. Pending onboarding steps are optional, but the visual language can imply that the application is not usable.

Recommended copy:

- “3 optional setup items”
- “Talk now, or finish setup”

Use warning styling only when a capability is genuinely unavailable.

### Simplify the six-item dock

The two-row dock gives six destinations equal priority. For an elderly audience, retain three persistent shortcuts—Medication, Phone, and Reminders—and place Appliance, Directions, and Feeds behind a clearly labeled secondary surface such as “More.” User-selected quick apps can remain optional.

This creates room for practical 52–60 pt targets rather than relying only on the generic 44 pt minimum.

### Reduce category-color noise

`DesignTokens.BadgeTint` defines many unrelated hues. Prefer four semantic roles:

- brand/action;
- voice state;
- emergency;
- neutral category.

Use symbols and labels for category identity. Reserve strong color changes for state and urgency.

### Fix text-size inconsistencies

The constitution requires at least 18 pt body text, but the UI includes hardcoded 14, 15, and 17 pt labels. `StartupProgressOverlay` uses `.footnote` at `App/StartupBoot.swift:223-237`, below the project's caption floor.

- Use the 18 pt caption token for status and secondary labels.
- Use at least 18 pt for navigation labels.
- Keep primary action text around 20–24 pt or larger.
- Avoid `minimumScaleFactor` for essential localized text; allow wrapping.
- Verify Nepali at Accessibility XXL and XXXL.

### Replace fixed heights with minimum heights

Many text fields and buttons use fixed 44, 56, 60, or 64 pt heights. Allow vertical expansion:

```swift
.frame(minHeight: 56)
.fixedSize(horizontal: false, vertical: true)
```

The bottom navigation and all forms must remain usable without clipping at Accessibility XXXL.

### Improve launch-screen continuity

The launch screen is solid brand green with centered “seniOS”; the first Home frame is cream with a blue Talk hero. For better continuity, use the Home's neutral cream background and a static brand/voice mark near the final hero position. The live hero can replace that mark without a full-screen color flash.

### Make degraded states actionable

`startup.degraded` currently says only “Some features are running with reduced functionality” and disappears after six seconds.

Replace it with capability-specific state:

- “Voice activation is unavailable.”
- “Your saved contacts could not be loaded.”
- “The local speech model is still preparing.”

Keep the affected control visibly degraded and provide one recovery action. Detailed diagnostics belong in Settings, not a transient capsule.

### Rebalance Home without adding dashboard clutter

The rendered Home has considerable empty space between the setup strip and dock. Empty space helps focus; do not fill it with more cards. Prefer vertically centering the Talk stage, moving the dock slightly upward, or increasing the hero modestly. Show at most one contextual instruction or outcome.

## Modern SwiftUI cleanup — lower priority

Because the deployment target is iOS 16, these updates are available without raising it:

- Use `.toolbar(.hidden, for: .navigationBar)` instead of `.navigationBarHidden(true)`.
- Prefer `.foregroundStyle` over `.foregroundColor` in new or touched code.
- Replace remaining `.disableAutocorrection(true)` with `.autocorrectionDisabled()`.
- Remove the conditional `.if` modifier at `App/HomeView.swift:1015-1027`; it changes view identity when reset eligibility changes. Use a stable wrapper or modifier whose internal gesture behavior is enabled/disabled without changing the outer view type.

Do not perform a project-wide cosmetic API rewrite in the startup work. Update touched surfaces and schedule the rest separately.

## Instrumentation and performance budgets

Add `OSSignposter` intervals for:

1. Application/bootstrap initialization.
2. First meaningful SwiftUI appearance.
3. Safety data restored.
4. Voice pipeline start requested.
5. KWS session ready.
6. Voice pipeline callback completed.
7. Optional STT/TTS warm completed.

Track separate metrics on a physical iPhone 12-class device:

- time to first meaningful frame;
- time to Home interaction;
- time to manual Talk readiness;
- time to wake-word readiness;
- main-thread hangs during KWS construction;
- peak memory and disk IO during model preparation.

Do not collapse these into one “startup complete” duration.

## Suggested implementation order

1. Add startup signposts and establish physical-device baseline traces.
2. Add independent voice readiness and gate the Talk control correctly.
3. Replace the spinner minimum-duration rule with delayed appearance.
4. Move `startupBoot.begin()` ahead of synchronous `start()` composition.
5. Split pre-frame coordinator construction from post-frame services.
6. Move physical-device KWS construction off main where validated.
7. Remove the global bundled-model copy and review redundant AI runtimes.
8. Migrate bulk structured data out of Keychain.
9. Split Home presentation state and extract real invalidation-boundary views.
10. Apply accessibility typography, target-size, and degraded-state improvements.
11. Re-profile and compare first frame, Home interaction, voice readiness, memory, and IO against the baseline.

## Required verification for implementation

- Build the iOS application for the supported simulator runtime.
- Run the actual application and visually verify Home startup, loading, ready, and failure states.
- Exercise a manual Talk request during startup and after readiness.
- Verify wake-word degradation does not block manual Talk.
- Verify reminder restoration and emergency controls remain available throughout startup.
- Verify VoiceOver announces loading-stage changes and capability failures.
- Verify Reduce Motion, Increase Contrast, Bold Text, and Accessibility XXXL.
- Capture a Time Profiler trace on simulator if necessary, but use the SwiftUI Instruments template on a physical device for final startup/update evidence.
