# TG-07 — Smart-mix placement, overlay rendering and the toggle: implementation notes

Tasks: **T-020 `LiveOverlayPlacement`** (C11), **T-021 overlay view, states and accessibility** (C11 view),
**T-022 the "always show original" preference's touch entry point** (C11 + C14).
Worktree: `.claude/worktrees/live-camera-translation`. Uncommitted, per the workflow (no commits were made).
Requirements: FR-LCT-015, FR-LCT-016, FR-LCT-017, FR-LCT-018 · NFR-LCT-002, NFR-LCT-003, NFR-LCT-004,
NFR-LCT-005, NFR-LCT-010, NFR-LCT-012 · **D1** · OD2, OD5 · **CL-3**, **CL-8** (`specs/review-l2.md`).

## What was built

### T-020 — `LiveOverlayPlacement` (C11)

`ios/ElderlyAssistant/Services/LiveTranslate/LiveOverlayPlacement.swift` (538 lines) and its one measurer
`ios/ElderlyAssistant/Services/LiveTranslate/LiveOverlayTextMetrics.swift` (73 lines).

- **One pure, total function.** `LiveOverlayPlacement.place(regions:results:containerSize:framePixelSize:
  safeArea:occupiedRects:policy:stateCopy:measure:)` takes values and returns values. No clock, no I/O, no
  camera, no storage, no `await`; the same inputs produce identical placements (asserted), and a source
  scan of the file forbids `Date`, `CFAbsoluteTime`, `URLSession`, `FileManager`, `DispatchQueue`, `Task`,
  `await`, `NotificationCenter`, `UserDefaults`, `Bundle`, `ProcessInfo`, `print(`, `NSLog` and `os_log`.
- **One predicate, four conditions (D1).** `inPlaceEligibility(...) -> InPlaceEligibility` is the only
  implementation; `inlineEligible` and `place` both delegate to it, so a fifth condition cannot be added at
  one call site and not the other. `InPlaceCondition` names the condition a caller violated
  (`sourceTierIsNotDictionary`, `sourceExceedsWordBound`, `translationDoesNotFitRegion`,
  `alwaysShowOriginalIsOn`), which is what makes "breaking any one of the four produces a callout" a test
  that says *which* one it broke. The word count uses the feature's own normalization
  (`LiveTranslateTextNormalization`: trim, collapse, case-fold) and the bound `inPlaceMaxSourceWordCount`
  from the config; the fit uses the injected `Measure` at `policy.minPointSize` against the region's rect.
- **A cloud string is never drawn in place (CL-3).** The tier is an input (`TranslationTier?`, `.dictionary`
  the only value that can satisfy the condition) and the source string's length is not. A cloud translation
  that would fit perfectly is still a callout — the test that says so is named for the cached case, because
  that is where "infer eligibility from the string" would go wrong.
- **The measurement is the render.** `Measure = (String, CGFloat, LiveOverlayTextWeight) -> CGSize`, default
  `LiveOverlayTextMetrics.measure`. The emitted `lines` carry the exact text, point size and weight that
  were measured, so the view has no font to choose and nothing to re-derive: a measurement that had drifted
  from the drawing would put pixels outside the rect the placement measured, and the pixel tests see it.
- **A callout never covers its own region's printed text (FR-LCT-016).** Anchors are tried in the fixed
  order above, below, right, left. The hard constraint (`pill ∩ region == ∅`) outranks the preferences:
  among the anchors that satisfy it, the fewest overlapping *other* regions wins, then the nearest (pill to
  region rect distance), then the anchor order. A conflict is never resolved by covering the text the pill
  is about.
- **The geometric corner case is recorded, not absorbed (OD5).** When no candidate can satisfy the hard
  constraint — the region effectively is the safe area — the pill is clamped inside the safe area on the
  side with the most free space and the placement is flagged `isClampedFallback`. That flag is the manual
  device-validation item T-030 consumes; it is the only way the corner case is visible to a later task.
- **The letterboxing math is the shipped one (CL-8).** `screenRect(for:containerSize:framePixelSize:)`
  delegates to `ApplianceOverlayMapper.displayedImageRect(containerSize:imageSize:)` unchanged. Rotation is
  a recomputation from the normalized box against the new container, never a transformation of a stale
  on-screen rect. The expected-value rectangles the math was missing are added as tests.
- **Bounded output, bounded cost.** Output is in reading order (top to bottom, then left to right, then
  identity), so determinism is comparable; work per region is a fixed number of rect operations (a counting
  `Measure` proves the call count does not grow with the scene).
- Every constant arrives in `Policy`, built by the app layer from `LiveTranslateConfig` and `DesignTokens`;
  nothing in this file spells a value (T-001's `LiveTranslateSourceHygieneTests` scans for that).

### T-021 — the overlay view, its states and its accessibility

`ios/ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift` (409 lines).

- **`RegionPresentation` is the pure value the view draws *and* announces.** `State` is
  `pending`/`resolved`/`degraded`, derived from `TranslationOutcome` and nothing else; `lines` are the
  placement's measured lines; `accessibilityLabel` is the translation for a resolved region and the
  recognized text otherwise; `accessibilityValue` is the original beside a translation, or the honest state
  sentence when there is none; `speaksTranslation` tells C12's tap-to-hear whether there is anything to say.
- **No region disappears because a tier failed (NFR-LCT-010).** A degraded region is still placed, with its
  original text and a catalog sentence naming the reason — never a translated-looking string, and no
  spinner (nothing about a degraded region implies success is coming). Pending carries the catalog's
  in-progress sentence and its own glyph; both glyphs are paired with a sentence, never shown alone, and a
  resolved region has no glyph at all.
- **The empty state is calm copy, not an error.** `livetranslate.empty.hint` in a card, in the active
  language.
- **The render path decides nothing and awaits nothing (NFR-LCT-002).** `LiveTranslateOverlaySurface` stores
  the placements, the policy they were computed with and the locale; the view has no `@State`, no `@StateObject`,
  no `onAppear`, no `.task`, no `await`. One `Path` draws every leader line; one `ForEach(surface.presentations)`
  keyed by region identity draws every bubble, at the rect the placement measured, with `.frame` +
  `.offset` — so a result arriving for one region changes one element and views are reused rather than
  accumulated (NFR-LCT-005).
- **The chrome is reserved space, not an afterthought.** `chromeRects(containerSize:)` returns the
  full-width bottom strip of `minTapTargetSize + 2 * interElementSpacing` (and nothing for a container that
  cannot hold it). It is passed to the placement as `occupiedRects`, so a callout can never cover the
  FR-LCT-017 control; the test asserts a pill in the strip's own row stays clear of it.
- Sizes and colours come from `DesignTokens` only (T-003's token table); all copy by catalog key, Nepali
  first (T-005).

### T-022 — the FR-LCT-017 control and its one writer

`ios/ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift` (119 lines); the setting itself is
T-001's `LiveTranslateSettings` (`UserDefaults`, key `livetranslate.alwaysShowOriginal`, default
`alwaysShowOriginalDefault` = false from the config).

- **`AlwaysShowOriginalSurface`** is the pure surface: `isOn` plus the label from
  `livetranslate.toggle.showOriginal` in the active language. **`AlwaysShowOriginalControl`** is the elder's
  control: ≥ `minTapTargetSize` in both directions, the on-state carried by the selected accessibility
  trait and not by colour alone, and a stable accessibility identifier.
- **`AlwaysShowOriginalBinding` is the one writer.** `set(_:)` is the touch path (an explicit value: the tap
  says what it meant, even if the surface it was drawn from is a frame old), `toggle()` is the voice path
  T-023 uses. Both go through the same `LiveTranslateSettings` setter and the same key, so the two cannot
  disagree; the test pinning `LiveTranslateSettings.featureKeys == [alwaysShowOriginalKey]` is what makes
  "a second setting" impossible without deleting a test.
- **The preference is a display preference and reaches exactly one field of the placement contract.** It is
  the fourth in-place condition, so "on" means every resolved region is a callout showing the original
  alongside the translation ("pure callout mode", FR-LCT-017). `policy(config:alwaysShowOriginal:)` differs
  in that one field and no other — asserted field by field — and the same `TranslationResult` renders in
  both states.
- **It is never presented as a privacy control.** It is drawn in the overlay's chrome, away from the consent
  surface and the cloud indicator; the copy never speaks of consent, sending or the network; withdrawing
  consent stops every send in both states and the gate never reads the preference.

### Tests (all new, under `ios/ElderlyAssistantTests/Services/LiveTranslate/`)

| File | Lines | Tests |
|---|---|---|
| `OverlayRenderProbe.swift` (shared helper) | 135 | — |
| `LiveOverlayPlacementTests.swift` | 606 | 28 |
| `LiveOverlayPlacementGeometryTests.swift` | 257 | 10 |
| `LiveTranslateOverlayViewTests.swift` | 536 | 14 |
| `AlwaysShowOriginalToggleTests.swift` (two classes) | 596 | 11 + 11 |

## Shipped-file edits (NFR-LCT-012)

**None.** Every production file this group wrote is new and untracked: `Services/LiveTranslate/LiveOverlayPlacement.swift`,
`Services/LiveTranslate/LiveOverlayTextMetrics.swift`, `App/LiveTranslate/LiveTranslateOverlayView.swift`,
`App/LiveTranslate/AlwaysShowOriginalControl.swift`. No catalog key was added — the four keys the overlay
consumes (`livetranslate.empty.hint`, `.state.pending`, `.state.unavailable`, `.state.quarantined`,
`.toggle.showOriginal`) were added by T-001/T-005 and are already in `LiveTranslateCopyTests.featureKeys`,
which validates them in both languages.

The only tracked-file change this group produced is `ios/seniOS.xcodeproj/project.pbxproj`, regenerated by
`./build.sh generate` (XcodeGen) — generated output, never hand-edited. The other modified files in
`git status` (`AppCoordinator.swift`, `SettingsView.swift`, `Localizable.xcstrings`, `Info.plist`,
`LogSanitiser.swift`, `InputSanitiser.swift`, `Services/Appliance/*`) belong to TG-01–TG-06 and TG-08.

## Gherkin coverage — scenario to test

### T-020 `LiveOverlayPlacement`

| Scenario | Tests |
|---|---|
| In-place requires all four conditions | `testAllFourConditionsProduceTheInPlaceForm`, and one test per broken condition: `testBreakingTheTierAloneProducesACallout`, `testBreakingTheWordBoundAloneProducesACallout`, `testBreakingTheFitAloneProducesACallout`, `testTurningTheToggleOnAloneProducesACallout` (each asserts the *named* violated condition) |
| A cloud translation is never drawn in place | `testACachedCloudStringIsNeverDrawnInPlaceEvenWhenItFits`, `testAnUnresolvedOutcomeIsIneligibleForTheTierAlone` |
| Measurement and rendering share one measurer | `testThereIsExactlyOneFontPathBetweenMeasuringAndDrawing` (source scan: the placement constructs no `UIFont`/`Font.system`/`size(withAttributes:)` at all; the overlay's bubble text is drawn through `LiveOverlayTextMetrics.font(`, the measurer's own constructor), `testTheFitDecisionMeasuresThroughTheInjectedClosureAtThePolicysSize` (the closure is called with the rendered point size and the primary weight), `testAMeasurementExactlyTheSizeOfTheRegionIsAFit`, and the pixel tests below — a font that drifted from the measurement would leave the rect |
| A callout never covers its own region's text | `testNoCalloutCoversItsOwnRegionAcrossAScriptedRectSet` (scripted rect set), `testTheAnchorOrderIsTheDesignsDeterministicOrder`, `testThePreferredAnchorIsTheOneOverlappingTheFewestOtherRegions`, `testAFullySymmetricRegionTakesTheFirstAnchorInOrder`, `testTheLeaderLineTargetsTheClosestPointOnTheRegion` |
| A callout shows both texts | `testAResolvedCalloutShowsTheTranslationAndTheOriginal`, `testAnUnresolvedCalloutShowsTheRecognizedTextAndTheHonestStateLine`, `testTheInPlaceTranslationIsDrawnInsideTheRectItWasMeasuredFor` (pixels), `testACalloutKeepsItsTextHorizontallyInsideItsPill` (pixels) |
| The full-screen corner case is recorded, not silently accepted | `testWhenNoAnchorCanSatisfyTheHardConstraintThePillIsClampedAndRecorded` (full-screen region: every candidate intersects, the flag is set, the pill is inside the safe area and pinned to the roomiest side), `testARoomySceneIsAnchoredAndNotFlagged` |
| Placement is pure, deterministic and bounded | `testTheSameInputsProduceIdenticalPlacementsTwice`, `testTheCostPerRegionIsBounded` (counting `Measure`), `testThePlacementReadsNoClockPerformsNoIOAndAwaitsNothing` (source scan), `testTheOutputIsInReadingOrder` |
| The mapping math is covered by expected rectangles | `testTheLetterboxedRectIsTheExpectedRectangleInAPortraitContainer`, `testThePillarboxedRectIsTheExpectedRectangleInALandscapeContainer`, `testAnUnletterboxedContainerMapsOneToOne`, `testTheMappingIsTheShippedMappersOwnMath` (value-for-value against `ApplianceOverlayMapper`), `testRotatingTheContainerRecomputesTheRectFromTheNormalizedBox`, `testADegenerateFrameHasNoRectToDrawInto` |
| The source tier is carried through to presentation | `testACachedCloudStringIsNeverDrawnInPlaceEvenWhenItFits` (the emitted placement's `result.sourceTier`), `testTheSameTranslationIsRenderedInBothPreferenceStates` (tier attribution is the tier's, not the display preference's) |
| DoD: `ios/build.sh` passes | see Verification |

### T-021 overlay view and states

| Scenario | Tests |
|---|---|
| Each outcome state renders its own presentation | `testEachOutcomeStateRendersItsOwnPresentation`, `testAPendingRegionShowsTheOriginalWithAnInProgressIndication`, `testADegradedRegionIsStillPresentWithItsOriginalTextAndAnHonestReason` (all nine `TranslationUnavailableReason` cases), `testTheQuarantinedWordingIsItsOwnHonestSentence`, `testEveryStateRendersInNepaliAndTheStatesAreDistinguishable` (four rendered states, four distinct ink signatures) |
| No region disappears because a tier failed | `testADegradedRegionIsStillPresentWithItsOriginalTextAndAnHonestReason` (present in every reason, never a translated-looking string), `testEachOutcomeStateRendersItsOwnPresentation` |
| The original text is always reachable | `testTheOriginalTextStaysReachableForAResolvedRegion`, `testEnablingKeepsTheOriginalVisibleOnTheNextRenderedFrame` |
| The empty state tells the truth without being an error | `testTheEmptyStateIsACalmCatalogSentence` |
| Text and controls meet the accessibility standards | `testTextRendersAtOrAboveTheMinimumPointSizeInThePrimaryWeight`, `testEveryHitTargetIsAtLeastTheTokensMinimum`, `testEveryColourAndSizeComesFromTheTokenTable`, `testAResolvedTranslationIsTheBubblesAccessibilityLabel`, `testEveryStateAnnouncesInTheActiveLanguage`, `testTheControlsOnStateIsNotCarriedByColourAlone` |
| The render path never waits on a tier | `testAResultArrivingChangesOnlyItsOwnRegionsPresentation`, `testTheRenderPathHoldsNoStateAndStartsNoWork` (source scan: no `@State`, no `.task`, no `await`), `testTheOverlayDrawsOneIdentityKeyedListPerFrame` |
| Recycling keeps the view cost bounded | `testALongSyntheticSessionKeepsTheViewCostBounded` (60 passes, three text-changing signs keeping one identity each, the cap reached), `testTheOverlayDrawsOneIdentityKeyedListPerFrame` |
| (chrome, T-022's reachability precondition) | `testCalloutsStayClearOfTheOverlaysChrome`, `testADegenerateContainerReservesNoChrome` |

### T-022 always-show-original

| Scenario | Tests |
|---|---|
| The control is reachable by touch in the overlay | `testTheControlIsLabelledInTheActiveLanguage`, `testTheControlIsDrawnInTheChromeInBothStates` (rendered ink in the chrome strip in both states), `testEveryHitTargetIsAtLeastTheTokensMinimum`, `testCalloutsStayClearOfTheOverlaysChrome` |
| Enabling keeps originals visible alongside translations | `testEnablingKeepsTheOriginalVisibleOnTheNextRenderedFrame` (same session, same settings value, next frame: the callout shows translation **and** original, the translation is still what is announced first) |
| The preference survives relaunch | `testThePreferenceRoundTripsAcrossASimulatedRelaunch` (a fresh settings value over the same store; the unset case reads the config's nominal default), plus T-001's `LiveTranslateSettingsTests` round-trip tests |
| The preference changes nothing else | `testThePreferenceChangesNothingAboutHowTextIsPlacedExceptTheForm` (field-by-field policy diff: exactly one field moves), `testTheSameTranslationIsRenderedInBothPreferenceStates`, `testThePreferenceIsTheOnlySettingThisFeatureOwns`, `testTheSurfacesThatMustNotSeeThePreferenceCannotSeeIt` (13 named surfaces: tier, cache, consent gate, prompt controller, sanitiser, camera, detector, stabiliser, events, indicator model + view, Gemini client, cost governor) |
| The preference is never a consent or privacy control | `testWithdrawingConsentStopsSendsInBothPreferenceStates`, `testThePreferenceCannotMakeConsentExistOrVanish`, `testTheChromeNeverSpeaksOfConsentOrEgress` |
| A voice command and the touch control agree | `testTheVoicePathAndTheTouchPathWriteTheSameSetting` (one key, written by both; each path reads what the other wrote), `testTheTwoWritePathsShareOneSetting` (one setter call site in the app layer), `testTheOverlayHandsTheControlsTapToTheCallersWriter`, plus T-001's pinned `LiveTranslateSettingsTests.testTouchControlAndVoiceCommandWriteTheSameSetting` |
| DoD: `ios/build.sh` passes | see Verification |

## Decisions made during implementation

1. **`Measure` takes the line's weight.** The design sketches the measuring closure as text + point size. It
   takes the weight too, because the primary line is bold and the supporting line is not, and their widths
   differ: a closure that could not tell them apart would make the pill's measurement a lie for exactly one
   of its two lines. It is a widening of the seam's signature, not a change to the contract — the default is
   still the feature's one measurer, and `LiveOverlayTextLine` carries the same weight to the view.

2. **`Form` and `PlacedOverlay` are the design's shape, with two additive fields.** `Form` is exactly
   `.inPlace(regionID:rect:)` / `.callout(regionID:anchor:pillRect:)`; `PlacedOverlay` adds `lines` (the
   measured lines, so the view has no font to choose) and `isClampedFallback` (OD5's record). Both are
   additive reads of values the placement already had, and neither changes what the view or T-024's spoken
   ordering consumes.

3. **The clamped fallback is a shift, never a resize.** `clamp` moves a pill into the safe area and never
   shrinks it: a resized pill would clip text that was measured to fit, which would make the measurement
   false at exactly the moment the elder most needs the words. A pill wider than the safe area is aligned to
   the leading edge so the *start* of the text stays on screen. Wrapping instead of shifting is not
   implemented (open item 2).

4. **`sideWithMostFreeSpace` ties go to `above`.** The four sides are evaluated in the anchor order and a
   tie keeps the first, so a region filling the screen (every side has zero free space) is clamped above —
   deterministic, and the test asserts the pinned edge rather than "somewhere inside".

5. **Pixels instead of the accessibility tree.** SwiftUI does not vend its accessibility elements to UIKit
   in a unit-test host, so an a11y-tree read-back would assert on an empty tree and pass for the wrong
   reason. `OverlayRenderProbe` (extracted once, so three suites share one renderer) draws the overlay off
   screen with `ImageRenderer` and measures the ink: "the translation was drawn inside the rect it was
   measured for", "the callout's text stays inside its pill", "each state draws something different",
   "the control is drawn in the chrome". The announcements are asserted on `RegionPresentation` and
   `AlwaysShowOriginalSurface`, which carry them as values.

6. **Every source-level scan is scoped by a named list, never by a directory walk.** The app-layer scan
   names the two files this group owns; the "surfaces that must not see the preference" scan names 13 files
   and fails if one is missing. A directory walk would police files other groups have not written yet, and a
   list that grows by itself proves nothing. The counterpart scans for the pipeline sources are T-001's
   `LiveTranslateSourceHygieneTests` (also in the gate below).

7. **The app-layer literal scan derives its inventory from the config's own source text.** The operational
   literals are read out of `LiveTranslateConfig.swift` with the same regex the config is written in, rather
   than re-listed in the test: NFR-LCT-011 says the config is the only place those values may be spelled, so
   an inventory copied into a test is a second place they are spelled. A positive control
   (`testTheLiteralScanDetectsItsInventoryWhereItLegitimatelyLives`) proves the pattern both detects and,
   in the app layer, would fire.

8. **The chrome strip is what makes FR-LCT-017 reachable.** The control is drawn in a reserved full-width
   bottom strip (`minTapTargetSize + 2 * interElementSpacing`), and the same rect list is passed to the
   placement as `occupiedRects`. That is what turns "the toggle is always one touch away" into a geometric
   property of the placement rather than a hope about z-order.

## Verification performed

Command (the flags `ios/build.sh test:unit` uses, scoped to this group's suites plus the three neighbouring
suites this work touches):

```
cd ios
./build.sh generate                       # XcodeGen — mandatory before testing new files
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveOverlayPlacementTests \
  -only-testing:ElderlyAssistantTests/LiveOverlayPlacementGeometryTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateOverlayViewTests \
  -only-testing:ElderlyAssistantTests/AlwaysShowOriginalToggleTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateAppLayerHygieneTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSettingsTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCopyTests \
  -resultBundlePath build/TG07-gate.xcresult
```

Result: **`** TEST SUCCEEDED **`**, and
`xcrun xcresulttool get test-results summary --path build/TG07-gate.xcresult` →
`result: Passed · totalTestCount: 99 · passedTests: 99 · failedTests: 0 · skippedTests: 0 ·
expectedFailures: 0`, on iPhone 17 (iOS 26.5, 23F77, x86_64), `ElderlyAssistant · Built with macOS 26.6.2`,
Xcode 26.6, XcodeGen 2.46.0.

Per-suite (from the same result bundle): `LiveOverlayPlacementTests` **28/28**,
`LiveOverlayPlacementGeometryTests` **10/10**, `LiveTranslateOverlayViewTests` **14/14**,
`AlwaysShowOriginalToggleTests` **11/11**, `LiveTranslateAppLayerHygieneTests` **11/11** — **74 new tests,
all passing** — plus the neighbouring suites this work depends on: `LiveTranslateSettingsTests` 9,
`LiveTranslateSourceHygieneTests` 6, `LiveTranslateCopyTests` 10.

`./build.sh build` (all three tasks' DoD, run after the last source change): **`** BUILD SUCCEEDED **`**,
zero compiler errors.

The gate was run four times while the failures below were found and fixed; the run reported here is the
final one, after the last source edit. Failures found and fixed during that loop:

- `testAnUnletterboxedContainerMapsOneToOne` compared `CGRect`s for equality and failed on
  `120.00000000000001` vs `120.0` — the mapping was right, the comparison was not → component-wise
  assertions with `accuracy: 1e-9`.
- `testNoCalloutCoversItsOwnRegionAcrossAScriptedRectSet` failed ten times on "the leader line must land on
  the region": `CGRect.contains` is half-open on `maxX`/`maxY`, and right/left-anchored pills place the
  anchor exactly on the boundary → assert containment with a hairline inset.
- `testACalloutKeepsItsTextHorizontallyInsideItsPill` measured the whole rendering, which includes the
  overlay's own chrome — the FR-LCT-017 control's ink spans the width by design and was read as the bubble
  escaping its pill → the scan is restricted to the area above the chrome strip.
- `testWhenNoAnchorCanSatisfyTheHardConstraintThePillIsClampedAndRecorded` used a region with a margin
  above it, so a candidate anchor *could* satisfy the hard constraint and the fallback was (correctly) not
  taken → the fixture is a genuinely full-screen region, which is the case OD5 is about.
- `testALongSyntheticSessionKeepsTheViewCostBounded` asserted "the session churned more identities than the
  cap"; identities are content-free and IoU-matched, so three stationary signs keep the same identity across
  their text changes — the assertion described the wrong property → it now asserts per-sign identity
  *stability* (one identity across all of a sign's text changes, i.e. the view is reused) and keeps the
  cap-reached assertion.

One further failure in that loop was not a defect in this code: the first gate run lost its test runner
mid-suite (see environment finding 2).

## Environment findings

1. **The unit baseline in this checkout is genuinely red** (≈21 pre-existing failures across ~10 unrelated
   suites, e.g. the voice-turn timing suites), which is why verification is scoped rather than a full
   `./build.sh test:unit`.
2. **Concurrent agents on one simulator destroy each other's runs.** The first gate run failed
   `LiveTranslateOverlayViewTests.testEveryStateRendersInNepaliAndTheStatesAreDistinguishable` with no
   assertion failure at all: the log shows XPC interruptions, then
   `[EventDelivery] ... backboardd must have unloaded, exiting…`, then
   `Simulator device failed to launch ... RequestDenied` — while two other `xcodebuild test` processes
   (the TG-06 agent's, same device id) were running. The device had been shut down underneath the runner.
   Nothing in the test was wrong; the re-run passed in 10 s. Worth serialising simulator use across agents,
   or giving each agent its own device.
3. **XcodeGen must be re-run before testing new files — and a missing file fails silently.** A raw
   `xcodebuild test -only-testing:…/<NewSuite>` whose class is not in the generated project runs nothing and
   reports success; check the per-suite counts in the result bundle, not just the exit code.
4. The simulator must be pinned (`id=990E1710-4805-46E2-8FED-BD1DE12D1BE8`); `xcodebuild` boots it.
5. `CGRect` equality is not a float-safe assertion (see `120.00000000000001` above); `accuracy: 1e-9` on
   each component is.
6. `CGRect.contains` is half-open on `maxX`/`maxY` — a point exactly on a rect's right or bottom edge is
   *not* contained. Assertions about anchors landing on an edge need a hairline inset (or a growing inset).
7. `ImageRenderer` renders the whole overlay, chrome included. An ink scan that is about a bubble must
   exclude the chrome strip, or the FR-LCT-017 control's by-design full-width ink becomes the assertion's
   subject.
8. The render-based tests are the expensive ones (2–10 s each; the eleven-test geometry run is ~8 s of its
   suite's 10 s). They are worth it — they are the only checks that can catch a measurement/rendering drift
   — but they are why the suites are not instant.

## Open items (reported, not silently closed)

1. **OD5 / T-030's manual device validation.** The full-screen corner case is detected, clamped and flagged
   (`isClampedFallback`), and the flag survives into `RegionPresentation`. What is *not* done here is the
   judgement T-030 owns: whether the clamped result is good enough on a real device, or whether the overlay
   needs a different rule for that case.
2. **No text wrapping or truncation in pills.** `clamp` shifts, never resizes, so a pill wider than the safe
   area overflows on the trailing side (the start of the text stays visible). For the strings this feature
   translates at 21 pt this is a corner case, but a long cloud translation in a narrow container is the
   shape that would expose it — a later polish task should decide between wrapping, trimming and a wider
   allowance.
3. **"The largest supported dynamic type size" cannot be exercised in a unit-test host.** The content size
   category is not settable there, so the accessibility scenario is covered as: every point size and hit
   target comes from `DesignTokens`, whose floors are `UIFontMetrics`-scaled by construction
   (`minBodyPointSize` = `scaled(21)`, `minCaptionPointSize` = `scaled(18)`, `minTapTargetSize` 44), and the
   render tests run at the default category. A UI test (or the T-030 device pass) is the honest way to close
   it; nothing in this code hard-codes a size that would not scale.
4. **The overlay has no on-screen home yet.** `LiveTranslateOverlayView` is built and tested, but the
   session pipeline that presents it over the camera is T-026's; until it lands, nothing in the app
   constructs the view.
5. **`occupiedRects` currently carries only the chrome strip.** The seam is general (the placement takes any
   list of rects); T-026 should pass the session view's real controls, so callouts avoid them too.
6. **T-023's voice path must keep using the one writer.** `LiveTranslateCommandParser` currently calls
   `settings.setAlwaysShowOriginal(showOriginal)` — the same key and the same setter the touch control
   writes, so the two agree today. `AlwaysShowOriginalBinding.toggle()` is the documented seam for the
   command; a future editor who reaches for `UserDefaults` directly would break
   `testTheVoicePathAndTheTouchPathWriteTheSameSetting`'s premise rather than its assertion, so it is worth
   a look when T-023 lands.
7. **The copy is a draft.** The overlay's strings ride the draft disclosure version
   (`LiveTranslateConfig.disclosureVersion`); the OD3 review at `final-sign-off` covers them, and this group
   added no new keys for it to review.

## Out of scope (adjacent capabilities, for the reader's map)

- **Tap-to-hear and the spoken ordering** (C12, T-024) consume `Form`/`PlacedOverlay` and
  `speaksTranslation`; this group only provides them.
- **Session presentation of the overlay** (T-026) — see open item 4.
- **The UI-test target**: `ElderlyAssistantUITests` is skipped in the gate above and was not extended; the
  VoiceOver-level checks would live there.
