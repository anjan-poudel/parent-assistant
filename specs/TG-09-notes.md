# TG-09 — The join point and the entry: T-026 `LiveTranslationPipeline` + `LiveTranslateSessionModel`, T-027 `LiveTranslatePlugin` + `LiveTranslateView`

Tasks: **T-026 the session pipeline and observable model** (C13) and **T-027 the plugin entry, the
session view and the lifecycle**. Environment: worktree
`.claude/worktrees/live-camera-translation`, branch `worktree-live-camera-translation`;
`.claude/worktrees/live-camera-translation` was the only checkout touched. Nothing was committed, no
`ai-sdd` command was run, `.ai-sdd/` was not touched, and the concurrent agent's
`ElderlyAssistantTests/Services/LiveTranslate/HiINCapabilityProbeTests.swift` was not edited.

Requirements: FR-LCT-001, FR-LCT-018, FR-LCT-022, FR-LCT-023, NFR-LCT-004, NFR-LCT-010,
NFR-LCT-011, NFR-LCT-012 · **AM-6** (applied to publication ordering), **AM-8**, **CL-1**.

## What was built

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslationPipeline.swift` (608 lines, new)

C13, the join point: an `actor` that owns the `TextRegionStabilizer` value type exclusively, the
`ocrPassInFlight` backpressure flag, and the `settledKeys` set behind AM-8/CL-1. It sequences
T-009/T-010 (stabilisation), T-019 (classification/degradation), T-017 (sanitisation), T-014 (the
consent gate), T-018/T-019 (the tier ladder) and T-020 (placement) and publishes one
`LiveTranslatePublication` per cycle: the placements, the policy they were measured under and the
monotone `sequence`. `ingest(_:)` is the frame tick; the next tick is the retry at the OCR cadence,
so a slow pass or a failed request cannot build a backlog. `close()` cancels the one session-scoped
task tree and drops every outcome, and `publish()` refuses after close.

No classification, placement, consent or sanitisation rule is re-implemented in this file — it calls
the components and carries their answers, which is what the task's implementation notes demand.

### `…/ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateSessionModel.swift` (627 lines, new)

The `@MainActor ObservableObject` that is the session's life and the view's single observation
surface: `start()` (idempotent), `close()`, the frame loop (`ingest` on every delivered sample),
lifecycle observation (pause on background, resume once on foreground), `updateLayout(containerSize:safeArea:occupiedRects:)`,
the consent prompt/answers, the cloud indicator the tier drives, the read-all / tap-to-hear /
repeat / stop-speaking voice surface, the always-show-original toggle, `listenForCommand()` and the
command outcome path (including the one re-prompt).

`LiveTranslateSessionDependencies` is the value the app layer hands over: capture session, detector,
cache, consent gate, cost governor, client, speech path, capture device, audio session, settings,
notification centre, bus and config. The app layer resolves it once, on the path that opens the
feature; the model composes the session from it and owns no factory, so "what a production session
is made of" is decided in exactly one place. Two stores arrive injected and are never constructed
here: `LabelTranslationCache` and `LiveTranslateConsentGate` (the process's own instances, over the
process's own cipher).

The model builds the per-session `ConsentPromptController` in `init` because the plugin factory is
nonisolated (`AssistantPlugin` is not main-actor) while the controller is main-actor-isolated — that
is the honest place for the isolation seam, and it keeps the app layer's factory a value. It also
owns the `CloudActivityIndicatorModel` and hands that instance to the tier, so the thing the tier
turns on and the thing the elder sees are one object with one counter.

### `…/ios/ElderlyAssistant/Services/Plugins/LiveTranslatePlugin.swift` (199 lines, new)

T-027's entry. One identifier (`live_translate`), one display-name key
(`settings.livetranslate.title`, reused so the Settings row and the Home tile say the same words),
universal applicability, one namespaced action (`livetranslate.open`), and a prompt fragment that
teaches the encoder the `plugin`/`pluginAction`/`pluginEntities` shape for this capability.

`handle` opens unconditionally — **no provider-availability guard** — and returns
`.spokenAndPresented` with `livetranslate.camera.explanation` (the same sentence T-008 shows before
the camera prompt). `presentationView(for:)` builds `LiveTranslateView` from the session `handle`
assembled, so opening builds exactly one. `tileView(locale:)` is the Home tile's entry: the same
construction, minus the utterance. A `nil` from the injected factory is the one thing that can stop
entry, and it is spoken (`router.pluginUnavailable`), never a silent no-op and never a
cloud-availability refusal.

`LiveTranslateEntry` (labelKey, iconName) is the one place the three surfaces that must agree about
the feature's name and glyph read from.

### `…/ios/ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift` (256 lines, new)

The full-bleed session view and the overlay's on-screen home. It renders the model — the preview
layer, `LiveTranslateOverlayView(surface: model.surface, …)`, the consent prompt, the cloud
indicator, the always-show-original control and the camera permission card — and holds no session
state of its own (one `@StateObject`, no other `@State`).

The chrome is composed *around* the overlay, never inside it: the close control and the indicator in
the top strip, the consent prompt and the permission card over everything, and T-021's own control
strip left where T-021 put it. The view reports the geometry the pipeline cannot derive — container,
safe area and the two strips a callout must not land under (`occupiedRects` = the overlay's
`chromeRects` + this view's `topChromeRects`) — on appear and on every size change. `onAppear` starts
the session (re-entrant appearing cannot start a second), `onDisappear` closes it, and closing is the
same teardown as the close control (the model's `close()` is idempotent).

### Tests (new)

| File | Tests |
|---|---|
| `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslationPipelineTests.swift` | 18 |
| `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateSessionModelTests.swift` | 17 |
| `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateSessionTestHarness.swift` | shared doubles + the one composition |
| `ios/ElderlyAssistantTests/Services/Plugins/LiveTranslatePluginTests.swift` | 10 |

The harness file is shared by the session and plugin suites so there is one composition and one set
of platform doubles (capture layer, recognition engine, speech path, capture device, audio session,
clock, log, bus) rather than one per suite; it was extracted from the session suite mid-task and the
session suite was re-run green after the extraction.

## Shipped-file edits

Three shipped files, all additive (NFR-LCT-012 — nothing is built at launch):

1. `ios/ElderlyAssistant/App/AppCoordinator.swift` — registers `LiveTranslatePlugin` with a factory
   closure; `makeLiveTranslateDependencies(locale:)` composes one session on demand over the
   process's own `labelTranslationCache` and `liveTranslateConsentGate` (no second cipher, no second
   gate); `presentLiveTranslate()` presents the plugin's tile view, or speaks the apology when the
   factory cannot assemble one. The registry, the router and the shell are otherwise untouched: the
   `.plugin` dispatch already routes `pluginAction` → `registry.plugin(handling:locale:)` → `handle`
   → `presentationView`, so **the voice entry needed no change to `CommandRouter`**.
2. `ios/ElderlyAssistant/App/HomeSubviews.swift` — `HomeDock` gains `onLiveTranslate` and one
   `translateItem` tile (`LiveTranslateEntry.iconName`, `LiveTranslateEntry.labelKey`).
3. `ios/ElderlyAssistant/App/HomeView.swift` — wires the dock's callback to
   `coordinator.presentLiveTranslate()`.

Two production defects found by the new suites and fixed in the files above (both are in TG-09's own
new code, not in shipped components):

- `LiveTranslationPipeline.reconcile()` — `settledKeys` was not intersected with the currently
  visible keys, so an answer that arrived for a string nothing was showing (a resume released the
  regions and the attempt landed afterwards) stayed "answered" forever: when the same text came back
  there was no outcome to render from the last cycle *and* no dispatch, leaving the region pending
  for good. It is now `settledKeys.formIntersection(visibleKeys)` — the settled set means "an answer
  is attached to a region on screen", which is what CL-1 actually claims.
- `LiveTranslateSessionModel.close()` — the session was torn down but the last publication stayed on
  the observation surface, so a view torn down a moment later could paint callouts for a camera that
  had already stopped. `close()` now sets `publication = nil`: "nothing renders after close" is the
  surface being empty, not the view being trusted to have gone.

No catalog key was added. Every string this group needed already existed and resolves in both
languages (asserted by `LiveTranslateCopyTests`, which pins the key set and passes unchanged), so
there is **no OD3 copy debt** from T-026/T-027 — including the re-prompt, which reuses the shipped
`router.reprompt` ("say that again") rather than inventing a second sentence for the same meaning
(T-024's recorded open item is closed this way: the `Outcome.reprompt` now has copy, and it is copy
that has already been reviewed).

## Gherkin coverage — scenario to test

### T-026 — pipeline (10 scenarios)

| Scenario | Test |
|---|---|
| A full cycle produces one coherent publication | `testScenarioAFullCycleProducesOneCoherentPublication` (placements and outcomes arrive as one value; nothing partially updated is observable), `testScenarioAFullCycleProducesOneCoherentPublicationThroughTheModel` (the same property through the model, end to end over a delivered sample buffer) |
| The dictionary path needs no network at all | `testScenarioTheDictionaryPathNeedsNoNetworkAtAll` (no consent prompt, no send, `requestCount == 0` for every curated string), `testScenarioAStringTheDeviceCanAnswerNeverPromptsOrSends` |
| Unresolved strings reach the cloud tier only through the gate | `testScenarioAnUnresolvedStringIsResolvedThroughTheGate` (the gate is consulted first, asserted at the transport and at the gate's own record), `testScenarioALosingDecisionDegradesTheRegionWithTheHonestReason`, `testScenarioAnUnansweredPromptKeepsTheRegionPendingAndSendsNothing`, `testScenarioAStringTheDeviceCanAnswerNeverPromptsOrSends` |
| Publication ordering is monotone and never wall-clock derived | `testScenarioPublicationOrderingIsMonotoneAndNeverWallClockDerived` (strictly increasing `sequence`, and the publication type carries no time field to derive order from), `testAM6TheMonotoneOrderingCounterNeverRegresses`, `testPublicationOrderIsEnforcedAtTheModelBoundary` |
| One terminal outcome per region per cycle | `testScenarioOneTerminalOutcomePerRegionPerCycle` (a resolved region seen unchanged never returns to pending), and the converse — a settled string is not re-sent on every tick |
| Resume after an interruption recovers honestly | `testScenarioResumeAfterAnInterruptionRecoversHonestly` (stabiliser restarts from empty, visible text re-enters resolution, the already-resolved string comes back **with a second request asserted impossible**: `requests(carrying:) == 1`), `testResumeReattemptsADegradedStringOnceUnderTheGate` (one re-attempt, and only the interrupted string is asked) |
| A component failure degrades one region, not the session | `testScenarioACloudFailureDegradesOneRegionAndTheOtherStillResolves`, `testScenarioADetectionFailureDropsNoRegionAndStopsNothing`, `testScenarioACacheReadFailureIsAMissAndNotAnElderFacingError`, and the quarantine wording asserted in T-017's own suite |
| Per-cycle work is bounded | `testScenarioPerCycleWorkIsBounded` (a long synthetic session: requests and retained outcomes stay flat), `testScenarioNoFrameIsProcessedWhileAPassIsInFlight` (the tap drops, it does not queue) |
| The pipeline is deterministic for a fixed input sequence | `testScenarioThePipelineIsDeterministicForAFixedInputSequence` (two runs, identical publications) |
| Closing cancels in-flight work and tears everything down | `testScenarioClosingCancelsInFlightWorkAndTearsEverythingDown` (real ordered log: in-flight cancelled, speech drained, capture and recognition released), `testNothingRendersOrCallsBackAfterClose` (the model: no publication, no callback, empty surface) |

### T-027 — entry and view (8 scenarios)

| Scenario | Test |
|---|---|
| The plugin follows the shipped pattern | `testScenarioAFullSessionOpensFromTheSharedPluginPattern` (identifier, display-name key, universal applicability, one namespaced action in the fragment the encoder reads, `handle` → `.spokenAndPresented`, `presentationView` only for that result) |
| The plugin opens with no provider key and no network | `testScenarioTheFeatureOpensWithNoProviderKeyAndNoNetwork` (premise asserted: `client.isAvailable == false`; the open path returns `.spokenAndPresented`, asks the provider nothing, starts nothing — **and the source scan names `ApplianceHelperPlugin`'s `geminiClient.isAvailable` guard as the template's shape that must not be copied**, with the template itself as the scan's positive control) |
| The shared intent vocabulary is not extended | `testScenarioTheSharedIntentVocabularyIsNotExtended` (`composed.hasPrefix(baseline)` — the core prompt is byte-identical; the fragment is appended only; the no-plugin prompt is unchanged byte for byte; the registry, not the vocabulary, routes `livetranslate.open`) |
| The feature is reachable in one clear action | `testScenarioTheFeatureIsReachableInOneClearAction` (one name, localised; the Home tile is titled and glyph'd from `LiveTranslateEntry`; the tap runs `coordinator.presentLiveTranslate()`; the coordinator presents the plugin's tile view or speaks the apology) |
| The close control is always reachable and tears the session down | `testScenarioClosingIsAlwaysReachableAndIsTheSameTeardown` (shipped `common.close`, localised; real tap target; `model.close()` + `dismiss()`; `onDisappear` is the same teardown; the chrome is not behind a condition; nothing session-scoped is nested in the overlay; both reserved strips), `testTheRenderedSessionDrawsItsExitAtTheTopLeadingEdge` (off-screen render: the exit is *drawn* in the reserved strip, at least a tap target tall) |
| Backgrounding pauses rather than running a background session | `testScenarioBackgroundingPausesAndForegroundingResumesOnce` (the model owns lifecycle; a second foreground cannot resume twice), `testScenarioNoFrameIsProcessedWhileAPassIsInFlight` |
| The entry point costs nothing when unused | `testScenarioTheEntryCostsNothingUntilTheFeatureIsOpened` (construction, registration and every launch-time inspection leave the factory at `callCount == 0`; the first open assembles exactly one session and presenting reuses it; building the view starts no camera and no pass), `testNothingIsBuiltUntilStart` |
| The surface is usable at the app's accessibility settings | `testScenarioTheSurfaceIsReadableInNepaliAtTheAppsAccessibilityFloors` (every word of the session's chrome in Nepali — close, camera card and its action, consent title/disclosure/choices, indicator, empty hint; the tap-target and type-scale floors; the view keeps no session state of its own) — see *Open items* for what a unit host cannot set |

Supporting properties asserted by the same suites: `testTheModelIsTheSingleObservationSurface`,
`testConsentAnswersRouteThroughTheModelToTheGate`, `testCommandsRouteThroughTheModel`,
`testTheMicrophoneGateSeesTheFeaturesOwnSpeech` (the capture gate is T-024's `isSpeaking` — one
speech path, not two), `testTheCloudIndicatorTheTierDrivesIsTheOneOnScreen`,
`testStartFailureIsRenderedAsThePermissionSurface`, `testLayoutReportedBeforeStartIsFlushedIntoThePipeline`,
`testAnUnchangedLayoutIsDropped`, `testStartIsIdempotentAcrossAReentrantAppear`,
`testThePluginsEventsCarryTokensAndNeverText`.

## Definition of done

T-026:

| DoD bullet | Evidence |
|---|---|
| All Gherkin scenarios covered | table above; 18 + 17 tests pass |
| Integration test over the whole pipeline with stubbed capture, client and speech | `testIntegrationThePipelineDrivesTheRealDetectorThroughTheSeam`, `testScenarioAFullCycleProducesOneCoherentPublicationThroughTheModel` (real camera session over a stubbed capture *layer*, real detector over a stubbed recognition *engine*, real cache, gate, tier and client; only the platform seams are doubled) |
| A determinism test over a fixed pass and response sequence | `testScenarioThePipelineIsDeterministicForAFixedInputSequence` |
| A test asserts no publication or callback after close | `testNothingRendersOrCallsBackAfterClose`, `testScenarioClosingCancelsInFlightWorkAndTearsEverythingDown` |
| A test asserts the monotone ordering counter never regresses (AM-6) | `testAM6TheMonotoneOrderingCounterNeverRegresses`, `testPublicationOrderIsEnforcedAtTheModelBoundary` |
| A test asserts one terminal outcome per region per cycle (AM-8) | `testScenarioOneTerminalOutcomePerRegionPerCycle` |
| A test asserts resume restarts the stabiliser and serves previously resolved strings from cache with no request | `testScenarioResumeAfterAnInterruptionRecoversHonestly` (the cache claim is made by request counts, since the cache's own `Origin.persisted` maps to the cloud tier — there is no `.cache` tier to assert on) |
| A boundedness test over a long synthetic session asserting memory and in-flight work stay flat | `testScenarioPerCycleWorkIsBounded` (+ incremental per-cycle counts, not a single end-state assertion) |
| Integration test against stubbed platform APIs | as above; the platform seams are `LiveCameraCaptureLayer`, `LiveTextRecognitionEngine`, `LiveTranslateUtteranceCapturing`, `AudioSessionControlling`, `LiveTranslateSpeechPath` |
| Verified that a crash or hang of the model cannot affect capture, dictionary or presentation paths | **partially** — see *Open items* 1. What is covered: a stalled cloud send does not block the frame loop or the cycle (the in-flight tests plus the boundedness test), a failed component degrades one region and the session keeps publishing, and the dictionary path is a separate injected component asserted without any network. What is *not* covered: a process-level crash/hang of the model, which no in-process unit test can express |
| `ios/build.sh` passes | `./build.sh build` → `** BUILD SUCCEEDED **` |

T-027:

| DoD bullet | Evidence |
|---|---|
| All Gherkin scenarios covered | table above; 10 tests pass |
| A test asserts the plugin opens with no provider key and no network (no availability guard) | `testScenarioTheFeatureOpensWithNoProviderKeyAndNoNetwork` (+ the source scan that names the template's guard, and the template as the scan's control) |
| A test asserts a re-entrant appear does not start a second session | `testStartIsIdempotentAcrossAReentrantAppear` (the view's `onAppear` calls `model.start()`, whose second call is a no-op) |
| A test asserts nothing is created at launch when the feature is not opened | `testScenarioTheEntryCostsNothingUntilTheFeatureIsOpened`, `testNothingIsBuiltUntilStart` |
| A test asserts backgrounding stops frame processing and foregrounding resumes once | `testScenarioBackgroundingPausesAndForegroundingResumesOnce`, `testScenarioNoFrameIsProcessedWhileAPassIsInFlight` |
| An accessibility test covers the root view and its chrome in the Nepali locale | `testScenarioTheSurfaceIsReadableInNepaliAtTheAppsAccessibilityFloors`, `testTheRenderedSessionDrawsItsExitAtTheTopLeadingEdge`; **maximum dynamic type + VoiceOver are not settable in a unit-test host** — see *Open items* 2 |
| `ios/build.sh` passes | `./build.sh build` → `** BUILD SUCCEEDED **` |

## Decisions made during implementation

1. **The seams were connected, not rebuilt.** `LiveTranslateCommandCapture`'s gate is T-024's
   `LiveTranslateSpeech.isSpeaking`; the pipeline calls T-019/T-020/T-014/T-017 rather than
   re-deriving anything; the cache and the consent gate arrive injected. The source-hygiene suite
   (`LiveTranslateSourceHygieneTests`, 6/6 green) polices the "no second copy" rule mechanically.
2. **The plugin does not copy the availability guard** (the task's one deliberate divergence), and
   the test asserts the divergence by *naming the template's guard* and proving the scan can see it
   in `ApplianceHelperPlugin.swift`. A style-only assertion would not have caught a future
   copy-paste; this one does.
3. **The voice entry goes through the shared encoder's `pluginAction`, not a keyword table.** The
   design sketch (2026-09-16 §) mentions plugin-owned keyword matching at the router, but T-027's
   acceptance criteria require the encoder to read the plugin's own fragment and no global
   vocabulary to be added; the router's existing `.plugin` dispatch already does exactly that, so
   nothing in the core was changed. Residual risk recorded in *Open items* 3.
4. **The re-prompt reuses `router.reprompt`.** T-024 left `Outcome.reprompt` with no copy; T-026 owns
   the outcome-meets-copy seam. Reusing the shipped "say that again" line keeps the key set (and its
   pinned test) unchanged and invents no copy that would need the OD3 review.
5. **`LiveTranslateSessionModel` composes the per-session `ConsentPromptController`, the indicator
   and the pipeline; the app layer composes the session's dependencies.** The seam is the plugin
   protocol's isolation boundary (the factory is nonisolated, the controller is `@MainActor`), and it
   keeps one place that decides what a production session is made of.
6. **The model owns lifecycle, the view owns geometry and SwiftUI.** Backgrounding/foregrounding is
   the model's (a second foreground cannot resume twice); the view reports container/safe area/
   occupied rects and nothing else. T-026's model therefore also carries T-027's backgrounding
   scenario — that is where the property lives, and it is asserted there.
7. **`occupiedRects` are stated as arithmetic, not measured after the fact.** The placement needs the
   rects before the controls are laid out, so each strip is the app's minimum tap target plus its
   spacing, full width (Devanagari at a large text size is not narrow). Both strips are asserted to
   be at least a tap target tall and inside the container, and a zero-size container reserves nothing.
8. **The publication returns to empty on close** rather than keeping the last scene, and the settled
   set is intersected with the visible keys — the two defects recorded above, both found by the
   suites and fixed in TG-09's own code.
9. **The render probe is not `OverlayRenderProbe.ink`.** That probe counts anything *not near-white*,
   which on a black session view is every pixel: the "the exit drew" check would have passed for the
   wrong reason. The plugin suite scans for the app's own card colour instead (a fixed, non-adaptive
   near-white), which on the black preview only the chrome draws. Recorded because the trap is
   subtle and a future reader will reach for the shared probe first.
10. **The wire-id contract** (learned by reading `CloudTranslationTier.send` and
   `TranslationResponseParser.parse`): requested translation ids are positional (`String(index)`), and
    a reply keyed by anything else — text, or the cache's normalization key — carries no requested id
    and degrades the whole batch as `cloudResponseUnusable`. The pipeline suite's `okJSON` helper was
    rebuilt positionally and the resume test now asserts its own premise ("the string resolved before
    the interruption") instead of assuming it. This was a **test-harness** defect, not a production
    one.
11. **"Namespaced" means the plugin's own namespace, not `pluginID + "."`.** The shipped plugins spell
    it in short form (`appliance_helper` → `appliance.identify`, `routine.set`, `youtube.play`), so
    the assertion checks `livetranslate.open`'s namespace and, beyond that, that no other plugin
    source in `Services/Plugins/` claims the name. The first version of the assertion was wrong about
    the convention, not the code.

## Verification performed

Gate (the task's shape, with the three TG-09 suites plus the four suites that police the same files):

```
cd ios
./build.sh generate                            # XcodeGen — mandatory before testing
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/TG09DerivedData -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslationPipelineTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSessionModelTests \
  -only-testing:ElderlyAssistantTests/LiveTranslatePluginTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCopyTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateEventsTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateOverlayViewTests \
  -resultBundlePath build/TG09-gate.xcresult
```

Result: **`** TEST SUCCEEDED **`**, and `xcrun xcresulttool get test-results summary --path
build/TG09-gate.xcresult` → `result: Passed · totalTestCount: 92 · passedTests: 92 · failedTests: 0 ·
skippedTests: 0` on iPhone 17 (iOS 26.5), x86_64.

Per suite, read from the same bundle with `xcrun xcresulttool get test-results tests` (never from the
exit code — a suite whose class is missing from the generated project runs nothing and reports
success):

| Suite | Tests | Result |
|---|---|---|
| `LiveTranslationPipelineTests` | 18 | all passed |
| `LiveTranslateSessionModelTests` | 17 | all passed |
| `LiveTranslatePluginTests` | 10 | all passed |
| `LiveTranslateOverlayViewTests` | 14 | all passed |
| `LiveTranslateEventsTests` | 17 | all passed |
| `LiveTranslateCopyTests` | 10 | all passed |
| `LiveTranslateSourceHygieneTests` | 6 | all passed |

The suite names of the individual test cases are listed under *Gherkin coverage* above; the plugin
suite's ten names are verbatim in the bundle (`testScenarioAFullSessionOpensFromTheSharedPluginPattern`
… `testThePluginsEventsCarryTokensAndNeverText`).

Coverage (`-enableCodeCoverage YES`, bundle `build/TG09-cov.xcresult`, the three TG-09 suites,
read with `xcrun xccov view --report --json`):

| File | Line coverage | Covered / executable |
|---|---|---|
| `LiveTranslationPipeline.swift` | **98.6 %** | 291 / 295 |
| `LiveTranslateSessionModel.swift` | **91.4 %** | 330 / 361 |
| `LiveTranslatePlugin.swift` | **100.0 %** | 69 / 69 |
| `LiveTranslateView.swift` | **74.4 %** | 201 / 270 |

The first three are above the 80 % bar. The view is reported as it is: a SwiftUI body cannot be
executed in a unit-test host, and the off-screen render probe is what lifted it from 4.4 % to 74.4 %.
The uncovered lines, read per line with `xcrun xccov view --archive --file …`, are exactly the
closures only a real interaction reaches: the `.onDisappear` teardown (77–81), the preview-host
branch once a layer exists (89–90), the close button's *action* closure (116–119 — the rendering
proves the control is drawn, not that a tap runs it), the consent-prompt body (153–161), the
permission-card body (166–170) and `LiveTranslatePreviewHost`'s `UIViewRepresentable` methods
(225–254). Everything a *decision* depends on in that file (the two strips, the close key, the
chrome composition, the single observation surface) is asserted as a value, not as a pixel.

`ios/build.sh build` (after the last source change): **`** BUILD SUCCEEDED **`**, exit 0.

`bash ios/tools/check-release-log-safety.sh`: exit 0,
`✓ no transcript content or raw error object can be printed in a non-Debug configuration`.

Falsifiability controls the suites carry (so a green run means something): the plugin source scan's
positive control is `ApplianceHelperPlugin.swift`'s guard; the pixel probe distinguishes "the app's
card colour drew" from "the preview is black"; the pipeline's `requests(carrying:)` counts a specific
string's requests rather than a total; the plugin factory spy is asserted at zero *before* the open
and at one *after* it, in the same test.

## Environment findings

1. **The unit baseline in this checkout is genuinely red** (≈21 pre-existing failures in unrelated
   intent-engine/voice suites); `./build.sh test:impact` exits 65 for that reason. Verification here
   is scoped with `-only-testing:`, and every suite in scope is green. Nothing in TG-09's scope failed.
2. **XcodeGen must be re-run before testing, and a missing file fails silently.** A suite whose class
   is not in the generated project runs nothing and reports success — every count above was read from
   the result bundle. (`LiveTranslatePluginTests.swift` had to be picked up by `./build.sh generate`
   before it ran at all.)
3. **`ElderlyAssistantTests` compiles as one unit**, so a concurrent agent's mid-edit test file can
   break this build. No such error occurred in this session's runs; the concurrent
   `HiINCapabilityProbeTests.swift` compiled as part of the target.
4. **`-resultBundlePath` refuses to overwrite**: an existing bundle makes `xcodebuild` exit with
   `error: Existing file at -resultBundlePath`. Every gate run here removes the bundle first.
5. **`xccov view --file` needs `--archive`** with an `.xcresult` (`xcrun xccov view --archive --file
   <path> <bundle>`); without it the tool reports `unrecognized file format`, and a bare
   `xcrun xccov view <path> <bundle>` means "view this *file* in this archive".
6. A private `-derivedDataPath` (`build/TG09DerivedData`, `build/TG09CovDerivedData`) and the pinned
   simulator (`id=990E1710-4805-46E2-8FED-BD1DE12D1BE8`) were used for every run, per the task's
   environment rules. No "never finished bootstrapping" contention occurred in this session.

## Open items (reported, not silently closed)

1. **A crash or hang of the model cannot be verified in a unit-test host** (T-026's DoD line). What a
   unit test can express is asserted: a stalled provider send does not stall the frame loop or the
   cycle, a component failure degrades one region and the session keeps publishing, and the
   dictionary path never touches the network. The remaining claim ("cannot affect capture, dictionary
   or presentation paths") is a process/runtime isolation property; it would need either an
   out-of-process fault injection or a UI/instrumented test. Not claimed here.
2. **Maximum dynamic type with VoiceOver on is not settable in a unit-test host** (T-027's DoD line).
   Asserted instead: every string of the session chrome resolves in Nepali, the tap-target floor is
   the app's (`DesignTokens.minTapTargetSize >= 44`), the overlay's type scale is floored by the app's
   body/caption minimums, the reserved strips are at least a control's legal size, and the exit is
   *drawn* in the strip. The setting-dependent half belongs to a UI test (`ElderlyAssistantUITests`,
   skipped in this gate).
3. **No keyword fallback for the voice entry.** The feature opens through the shared encoder's
   `plugin`/`pluginAction` classification of the plugin's fragment. The design sketch mentions
   plugin-owned keyword matching at the command router (the router has one such hardcoded
   special-case, for the appliance helper's camera phrase); live translation has none, so an
   utterance the encoder does not classify as `live_translate.*` will not open the feature. T-027's
   acceptance criteria require the encoder route and no global vocabulary, which is what is built —
   but if the intent model misses the phrase in the field, there is no fallback, and the fix belongs
   in a follow-up (a keyword entry beside the appliance helper's, or a retrained encoder), not in a
   second parser inside this plugin.
4. **No on-screen microphone control for the session's voice commands.** The model exposes
   `listenForCommand()` and the command path is fully tested, but nothing in `LiveTranslateView`
   calls it and no other production code does either (verified by grep across the app target): today
   the elder has tap-to-hear, read-all and repeat, and the command route is reachable only when
   something else opens a window. T-024/T-025/T-026/T-027 do not require such a control, so it is
   reported rather than invented; it would slot into the top strip beside the close control (and into
   `occupiedRects`' top reservation, which is already full width).
5. **No withdraw-consent control in the session chrome.** `LiveTranslateConsentGate.revoke()` and
   `ConsentPromptController.revoke()` exist and are tested (T-014/T-015), but the session model
   exposes only `grantCloudConsent()`/`declineCloudConsent()` and the view has no withdraw affordance.
   AM-4's "withdrawal is immediate and total" therefore holds at the gate and at the model's
   command surface, not yet at an on-screen control. Where it belongs is a design decision (a settings
   row or session chrome); reported, not invented.
6. **`LiveTranslateSpeech.swift` / `LiveTranslateCommandCapture.swift` coverage under this narrower
   run** (60.3 % / 45.9 %) is T-024/T-025's number under *this* bundle's suite selection, not a
   regression: their own suites are not in this gate and were reported green in the TG-08 notes.

## Forward notes (not built, by instruction)

- **The snapshot / freeze-frame affordance** (a later task: one capture button plus a static renderer
  variant) has a clean slot: the session view's top strip already reserves full-width chrome
  (`LiveTranslateView.topChromeRects`) and its `occupiedRects` arithmetic is the one place to extend,
  the model is the single observation surface a frozen publication would be read from, and
  `LiveTranslatePublication` is already a value — a freeze is holding one, not a second renderer path.
  Nothing in TG-09 assumes the live preview is always the thing on screen (the overlay is a pure
  function of a surface, and the view's preview branch is one `if`), so the affordance can be added
  without reworking either.
- The dashboard/`OD3` copy review: no new catalog key was added by this group, so nothing here needs
  that review before sign-off.
