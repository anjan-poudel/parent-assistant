# T-033 — Snapshot mode: the freeze-frame affordance on the live session view

Task: **T-033, snapshot mode (freeze-frame)**, dispatched by the orchestrator's directive. There is no
`specs/plan-tasks/tasks/**/T-033*.md` — the plan covers T-001 … T-030 — so the directive *is* this
task's specification, and every bullet of it is mapped to a named test below. Environment: worktree
`.claude/worktrees/live-camera-translation`, branch `worktree-live-camera-translation`, which was the
only checkout touched. Nothing was committed, no `ai-sdd` command was run, `.ai-sdd/` was not touched
(its `runs/live-camera-translation/` directory is the framework's own), and the concurrent agent's
files (`ios/tools/**`, `ElderlyAssistantTests/Services/LiveTranslate/HiINCapabilityProbeTests.swift`)
were neither edited nor run; its pinned simulator `990E1710-4805-46E2-8FED-BD1DE12D1BE8` was not used.

Requirements: the directive · **OD-13** — "OCR'd text strings ONLY (never images, never photos)",
`constitution.md:135` · **AM-10** — "zero image or media parts on every path including the retry",
`specs/security-design-review.md:249` · FR-LCT-001 (the session view), NFR-LCT-004 (copy),
NFR-LCT-011 (accessibility floors), NFR-LCT-012 (nothing pre-existing is removed, renamed or
re-meant).

## What was built

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateSnapshot.swift` (335 lines, new)

The whole of T-033's own state machine, in one file, so the freeze is a value the session model holds
rather than a mode spread across the view:

- `LiveTranslateSnapshot` — a freeze is *holding one publication*: `framePixelSize`, the raster
  `image: CGImage`, the `publication` the live cycle produced for that frame, and the derived
  `placements` / `hasVisibleText`. The picture and what is spoken from it are the same value, which
  is why tap-to-hear on a frozen frame cannot drift from the live path.
- `LiveTranslateFrozenRaster.image(from:)` — 32BGRA-only `CVPixelBuffer` → one `CGContext`, one
  `makeImage()`. No encoder, no URL, no `Photos`. A buffer in another format is refused (`nil`)
  rather than converted into a picture the follow-up pass would not match.
- `LiveTranslateSnapshotPath` — a stateless struct holding the *same* collaborators the live session
  already owns (`recogniser`, `cycle`, `cache`, `locale`, `targetLanguage`). `freeze(_:)` runs one
  `recognizeStillFrame` pass, builds the regions, resolves the device layers from the same cache,
  places with `LiveOverlayPlacement.place` and publishes through `cycle.nextPublicationSequence()`,
  so AM-6's monotone ordering covers frozen publications too. `outcomesAfterCloudAnswers(of:)` walks
  the publication and asks the same tier with `CloudTranslationTier.Item(id:text:language:)` — a type
  with no image field at all.
- `regions(from:)` builds `TextRegionStabilizer.StableTextRegion` values *directly*: one still pass
  has no "before" to stabilise against, so the tracker is not constructed, not consulted and not
  entered on this path. The identity it stamps is derived from the still pass's own geometry.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistant/Services/LiveTranslate/Views/LiveTranslateSnapshotControl.swift` (107 lines, new)

`LiveTranslateSnapshotSurface` — a pure, testable value: `isFrozen`, `isPresented`, `isEnabled`,
`locale`, and the two labels read from the catalog. `LiveTranslateSnapshotControl` — a labelled
button in the reserved top strip with
`accessibilityIdentifier = "livetranslate.snapshot.toggle"` (the handle the UI-test layer will use),
symbols `pause.circle.fill` / `play.circle.fill`, and a tap target at or above the 44 pt floor from
the shared design tokens. The surface carries what the control *says*; the view carries nothing.

### Changed in place (4 files)

1. `…/ios/ElderlyAssistant/Services/LiveTranslate/LiveTextDetector.swift` — one addition,
   `recognizeStillFrame(_:) -> Result<Pass, LiveTranslateError>`, which is the shipped `recognize(_:)`
   pass with the tracker hand-off removed. No second `VNRecognizeTextRequest`, no second channel:
   the same requests run at the same `.accurate` level over the frame's own full-resolution buffer.
2. `…/ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateSessionModel.swift` — `frozen:
   LiveTranslateSnapshot?` (the only freeze state in the feature), `frozenFrameImage`, `isFrozen`,
   `snapshotSurface`, `toggleSnapshot()`, and `activePublication` which returns
   `frozen?.publication ?? publication`. The overlay reads `activePublication`, so a frozen frame
   draws its own placements with no frozen-specific renderer. `thaw()` and `close()` cancel the one
   snapshot task and release the raster.
3. `…/ios/ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift` — the preview branch draws
   `Image(decorative: model.frozenFrameImage, scale: 1)` while frozen, the capture control is centred
   in the reserved top strip, and `topChromeRects` (height = `minTapTargetSize + 2 *
   interElementSpacing`) joins `occupiedRects` so no callout is placed under the new chrome.
4. `…/ios/ElderlyAssistant/Resources/Localizable.xcstrings` — two new keys, see "Shipped-file edits".

### Tests

| File | Tests | Note |
| --- | --- | --- |
| `…/ios/ElderlyAssistantTests/Services/LiveTranslate/SnapshotModeTests.swift` (1527 lines, new) | 25 | the whole T-033 contract |
| `…/ios/ElderlyAssistantTests/Services/LiveTranslate/OverlayRenderProbe.swift` (changed) | +0 | one generic `render<V: View>(_:size:scale:)` overload so the capture control's pixels are measured by the feature's existing probe instead of a second renderer |

## The directive's bullets, each mapped to a named test

| Directive bullet | Named test(s) |
| --- | --- |
| one capture button in the reserved chrome | `testTheSessionViewOffersExactlyOneCaptureControlInTheReservedChrome`, `testTheCaptureControlSitsInsideTheTopChromeStripAndIsUnavailableBeforeTheCameraIsUp`, `testTheCaptureControlIsAToggleWithOneMeaningPerTap` |
| …and it says what the tap will do | `testTheCaptureControlsTwoLabelsAreCatalogCopyAndSayWhatTheTapWillDo`, `testTheCaptureControlDrawsBothOfItsStatesDifferently` |
| capture the current buffer, in memory only | `testFreezingAFrameAtFullResolutionWritesNothingToDiskAndKeepsTheRasterInMemory` (file-system listing delta across a real freeze; the raster is the frame's own buffer at the frame's own size) |
| never written to Photos / no photo-output plumbing | `testNoSnapshotPathSourceReferencesPhotosAPIOrWritesAFrameToDisk`, `testThePhotoAndDiskScansDetectEveryShapeWhereItActuallyAppears` |
| the existing detector at full resolution | `testASnapshotRunsTheExistingDetectorOverTheFullResolutionFrame` (1920×1080 through the still path), `testTheStillPathAddsNoSecondDetectorAndNoSecondVisionRequest` |
| smart-mix overlay on the frozen frame, placed where it is drawn | `testFrozenFrameCalloutsArePlacedAgainstTheFrozenFramesGeometry` (live 1280×720 vs frozen 1080×1920), `testNoCalloutLandsUnderTheCaptureButtonOrTheOverlayChrome` |
| identical tap-to-hear | `testTapToHearOnAFrozenFrameSpeaksTheFrozenPlacementExactlyLikeTheLivePath`, `testAFrozenRegionWithNoTranslationIsNotSpoken` |
| reuse detector, tier ladder, cache and overlay renderer | `testTheSnapshotPathReusesTheSessionsCacheGateTierAndPlacement`, `testTheStillPathAddsNoSecondDetectorAndNoSecondVisionRequest` |
| no tracker / stabiliser involvement | `testTheSnapshotPathNeitherConstructsNorConsultsTheStabiliser` (source scan + behaviour), `testOneStillPassPaintsWithoutTheAppearHysteresisTheLivePathNeeds`, `testTheFreezeConsumesNoIdentityFromTheLiveCyclesTracker` |
| **OD-13 — never images** | `testASnapshotOriginatedRequestCarriesNoImageMediaOrAttachmentPart`, `testTheNoImageCheckCanSeeAnImagePartWhereOneLegitimatelyTravels` |
| events carry counts/mode tokens only | the shipped `LiveTranslateEventsTests` + `LiveTranslateAllowListTests` run in this gate; T-033 adds no event type and no metadata key, so the closed vocabulary and the no-Devanagari-in-metadata rule are pinned by the existing suites rather than restated |
| the freeze lives in the model, the view stays stateless | `testTheModelHoldsTheFreezeAndTheViewKeepsNoSnapshotState` |
| snapshot mode must not change the live path | `testTheLivePathIsUnchangedWhenNoFreezeIsEverTaken`, `testNoFrameIsProcessedWhileAFrameIsHeldAndTheCameraKeepsRunning`, `testThawingAndClosingReleaseTheHeldFrame` |

Two further tests in the suite are guards rather than bullet mappings:
`testTheFeaturesDevanagariChecksAreScalarTestsAndNotRegularExpressions` (below) and the render test
above.

## How "never images, never Photos" is enforced — structurally, not by convention

Four independent mechanisms, each of which can fail on its own, each with a test that fails if it
does:

1. **The type has no image field.** `CloudTranslationTier.Item` is `(id, text, language)`. A
   snapshot-originated request is built from that value, so there is nothing to serialise an image
   into. `testASnapshotOriginatedRequestCarriesNoImageMediaOrAttachmentPart` drives a real freeze
   with the cloud path live and walks the built request's JSON for `inlineData` / `inline_data` /
   `mimeType` / `media` / `attachment` / base64-shaped payloads, then asserts the same over the
   serialised body attached to the `URLRequest` — the request-building path *and* the transport, so
   the claim survives a later refactor of either.
2. **The scan is falsifiable in both directions.**
   `testTheNoImageCheckCanSeeAnImagePartWhereOneLegitimatelyTravels` feeds the very image part the
   shipped vision client sends (`GeminiClient+Vision.swift`, `inlineData(`) through the same check
   and asserts it is *found*, so the check cannot pass by being blind.
3. **No photos API exists on the path.** The source scan covers the snapshot files for 19 forbidden
   shapes (Photos APIs, photo-capture outputs, pickers, share sheet, encoders, `FileManager` /
   `FileHandle` / `write(to:` / `Data(contentsOf:`) plus the whole feature for the photo-library
   half; the control test replays every pattern against a synthetic source and against two shipped
   files that legitimately carry the shapes (the appliance picker, the appliance JPEG cache), so
   "absent here" is a measured absence.
4. **Nothing is written to disk.** Besides the scan, the behavioural test lists the temporary
   directory and the caches directory before and after a *real* freeze — raster, still pass, device
   lookup, cloud answers — and asserts the listing is unchanged, and that the raster's bytes come
   from the delivered frame's buffer. The raster lives only in `LiveTranslateSnapshot`,
   is released on thaw and on close, and the view draws it with `Image(decorative:)`.

## Shipped-file edits

### Two new catalog keys — **OD3 copy review owed**

`livetranslate.snapshot.capture` — en "Hold this picture", ne "यो दृश्य रोक्नुहोस्" — and
`livetranslate.snapshot.live` — en "Go live again", ne "फेरि चलाउनुहोस्" — both `state: translated`,
both carrying the catalog comment *"T-033 freeze-frame control. DRAFT: awaiting the owner's OD3 copy
review at final sign-off."* **These two keys are drafts.** No existing key said this, so they could
not be reused, but they are new elder-facing copy and must be reviewed by the owner with the rest of
the OD3 set at `final-sign-off`. `LiveTranslateCopyTests`' pinned key inventory was updated in the
same change, so a third key added later cannot slip in unreviewed. The suite is gated by
`testTheCaptureControlsTwoLabelsAreCatalogCopyAndSayWhatTheTapWillDo`, which asserts both labels come
from the catalog (not from a literal in the view) and that each names what the tap will do.

### A defect found in seven existing checks, and fixed

The gate went **red** on `LiveTranslateCopyTests` while this task's copy landed: the feature's
existing "does this string contain Devanagari?" checks used
`value.range(of: "[\\u0900-\\u097F]", options: .regularExpression)`, and that check cannot see
Devanagari in the elder's own words. Two compounding causes, both reproduced from scratch in a
scratch harness:

- `NSRegularExpression(pattern: "[\u{0900}-\u{097F}]")` **throws** (invalid ICU escape), and the
  helper swallowed the error;
- even with a valid range expression, `range(of:options:.regularExpression)` **declines any match
  whose range would split a grapheme cluster**. `"यो".range(of: "य", options: .regularExpression)`
  returns `nil` (य + ो is one cluster) while `NSRegularExpression("य").firstMatch(in: "यो")` matches.
  A leaked sentence in the elder's language could have satisfied a check written to forbid exactly
  that.

Every one of the feature's Devanagari checks (7 sites) was converted to the scalar idiom the app's
own code uses — `value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }` — in
`LiveTranslateCopyTests`, `CameraPermissionSurfaceTests`, `AlwaysShowOriginalToggleTests`,
`LiveTranslateOverlayViewTests`, `CloudActivityIndicatorTests`, `ConsentPromptAndRevocationTests`,
`LiveTranslateEventsTests`, and `ElderlyAssistantTests/Services/Observability/
LiveTranslateAllowListTests` (the console-sink assertion — the eighth site, outside the feature's own
directory). `testTheFeaturesDevanagariChecksAreScalarTestsAndNotRegularExpressions` pins the rule for
the future: it scans the suite directory for regex literals containing `0900` (there must be none)
and asserts the scalar form is present in the files that need it, with two falsifiability controls —
one that the scanner *does* fire on a synthetic regex form, and one that shows the scalar idiom
finding the Devanagari in `यो` where the regular expression cannot.

## Verification performed

One heavy command at a time, `./build.sh generate` first (XcodeGen; `project.pbxproj` was never
hand-edited), the feature's 18 suites, a private derived-data path and this task's own simulator
(`LCT-T033`, iPhone 17 / iOS 26.5 / x86_64), deleted afterwards:

```
ios$ ./build.sh generate
ios$ xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
    -destination "platform=iOS Simulator,id=C582ABE7-8A89-449B-BA3A-91165E42F42C" \
    -derivedDataPath build/T033DerivedData -skip-testing:ElderlyAssistantUITests \
    -enableCodeCoverage YES \
    -only-testing:ElderlyAssistantTests/{SnapshotModeTests,LiveTranslateCopyTests,LiveTranslateEventsTests,\
LiveTranslateOverlayViewTests,LiveTranslateSessionModelTests,LiveTranslateSourceHygieneTests,\
LiveTranslateAppLayerHygieneTests,LiveTranslateSpeechTests,LiveTranslationPipelineTests,\
LiveTextDetectorTests,LiveOverlayPlacementTests,LiveCameraCaptureGuaranteeTests,\
TextRegionStabilizerTests,AlwaysShowOriginalToggleTests,CameraPermissionSurfaceTests,\
CloudActivityIndicatorTests,ConsentPromptAndRevocationTests,LiveTranslateAllowListTests} \
    -resultBundlePath build/T033-gate.xcresult
```

Result — read from the bundle, not from the log:
`xcrun xcresulttool get test-results summary --path build/T033-gate.xcresult` →
`** TEST SUCCEEDED **`, `passed=307 failed=0 skipped=0 result=Passed`, 307 total, 0 expected
failures, on LCT-T033 (iPhone 17, iOS 26.5, build 23F77, x86_64).

Per-suite counts, from `xcrun xcresulttool get test-results tests` (every suite asserted to have run —
a suite missing from the generated project runs nothing and reports success):

| Suite | Passed | Failed |
| --- | --- | --- |
| AlwaysShowOriginalToggleTests | 11 | 0 |
| CameraPermissionSurfaceTests | 14 | 0 |
| CloudActivityIndicatorTests | 15 | 0 |
| ConsentPromptAndRevocationTests | 22 | 0 |
| LiveCameraCaptureGuaranteeTests | 6 | 0 |
| LiveOverlayPlacementTests | 28 | 0 |
| LiveTextDetectorTests | 17 | 0 |
| LiveTranslateAllowListTests | 24 | 0 |
| LiveTranslateAppLayerHygieneTests | 11 | 0 |
| LiveTranslateCopyTests | 10 | 0 |
| LiveTranslateEventsTests | 17 | 0 |
| LiveTranslateOverlayViewTests | 14 | 0 |
| LiveTranslateSessionModelTests | 17 | 0 |
| LiveTranslateSourceHygieneTests | 6 | 0 |
| LiveTranslateSpeechTests | 34 | 0 |
| LiveTranslationPipelineTests | 18 | 0 |
| **SnapshotModeTests** | **25** | **0** |
| TextRegionStabilizerTests | 18 | 0 |

Then, in the gate's order:

- `ios$ ./build.sh build` → `** BUILD SUCCEEDED **` (log `ios/build/T033-appbuild.log`), run after the
  last app-source edit at 08:01.
- `worktree$ bash ios/tools/check-release-log-safety.sh` → **exit 0**, re-run against the final tree
  after the last test edit: "no transcript content or raw error object can be printed in a non-Debug
  configuration, and the live-camera-translation sources carry no console write or content-bearing
  event field", 24 fixtures over 12 rules, every rule with a positive and a negative fixture
  (`ios/build/T033-logsafety.log`).

Coverage, same bundle (`xcrun xccov view --report --json build/T033-gate.xcresult`), for the files
this task touches:

| File | Coverage |
| --- | --- |
| `LiveTranslateSnapshot.swift` | 82.2% (129/157) |
| `LiveTranslateSnapshotControl.swift` | 100% (57/57) |
| `LiveTranslateSessionModel.swift` | 88.4% (427/483) |
| `LiveTextDetector.swift` | 69.2% (189/273) |
| `LiveOverlayPlacement.swift` | 98.0% (250/255) |
| `LiveTranslateOverlayView.swift` | 94.9% (282/297) |
| `LiveTranslateSpeech.swift` | 97.6% (123/126) |
| `TextRegionStabilizer.swift` | 89.8% (229/255) (untouched by T-033) |
| `LiveTranslateView.swift` | 2.9% (9/314) — **selection artefact**, not a gap: this gate does not
  include T-027's render suite, so the view's drawing code is exercised outside its selection |

The capture control sat at 22.8% before its render test was added; the probe's generic overload plus
`testTheCaptureControlDrawsBothOfItsStatesDifferently` took it to 100%, which is why the suite is 25
tests and the gate 307.

Determinism: the suite was run whole three times during the task and once more as the final gate
(307/307). The one earlier red — `LiveTranslationPipelineTests.
testScenarioThePipelineIsDeterministicForAFixedInputSequence` — was diagnosed rather than waved away
and is recorded under Environment findings (2).

## Decisions made during implementation

1. **The freeze is a value in the model, not a mode in the view.** The view asks the model for
   `frozenFrameImage`, `isFrozen` and `snapshotSurface` and owns no snapshot state, so the picture
   and the placements it is drawn with cannot disagree. Pinned by
   `testTheModelHoldsTheFreezeAndTheViewKeepsNoSnapshotState`.
2. **One still entry point, the same pass.** `recognizeStillFrame` is the shipped request with the
   tracker hand-off removed — not a second pass type — so "the detector is reused at full resolution"
   is a property of the call graph, not a claim. Pinned by
   `testASnapshotRunsTheExistingDetectorOverTheFullResolutionFrame` and
   `testTheStillPathAddsNoSecondDetectorAndNoSecondVisionRequest`.
3. **The frozen raster is 32BGRA-only.** Other formats are refused rather than converted: a
   converted picture is not the picture the pass saw, and the placement on screen would drift from
   the geometry it was measured against.
4. **No tracker on the still path.** One pass has no "before" to stabilise against, and running the
   stabiliser would also mean the live path's identity/hysteresis rules leaking into the freeze.
   The identity stamped on still regions is derived locally. Pinned by the three stabiliser tests.
5. **No new event type and no new metadata key.** The freeze reuses the live cycle's emissions, so
   the closed vocabulary, the counts-and-tokens-only rule and the sanitising bus are unchanged; the
   shipped suites that pin all three are in this gate.
6. **The Devanagari checks were fixed, not worked around.** The failing assertion was in code another
   group shipped, but leaving it would have left a check that silently passes on leaked content. The
   fix is the app's own scalar idiom, applied to all eight sites, with a guard test and two controls.
7. **Coverage of the new control earned its test.** Rather than report a low number with a
   justification, the render probe gained one generic overload and the control a two-state render
   assertion — the pixels say what the two states look like, which the pure surface cannot.

## Environment findings

1. **XcodeGen and per-suite verification are both load-bearing.** `./build.sh generate` ran before
   every gate, because a suite that is not in the generated project runs nothing and reports success
   — so every count below was read from the result bundle's own test listing, not from the log.
2. **One flaky test, honestly attributed and not caused by T-033.**
   `LiveTranslationPipelineTests.testScenarioThePipelineIsDeterministicForAFixedInputSequence` failed
   once inside the first 13-suite gate and passed in every later gate run; run alone three times it
   passed (0.386 s / 0.378 s / 0.359 s). The failure diff was exactly *when* the cloud answer was
   published — a region still pending versus the same region resolved one publication later — i.e. a
   wall-clock race against the test's fixed 120 ms sleep under simulator load, in T-026's pipeline
   synchronisation, not in anything T-033 added. It is reported, not fixed: the honest fix is a
   synchronisation redesign in a task that owns that file.
3. **`Foundation.range(of:options:.regularExpression)` is not safe for Devanagari** — it declines a
   match whose range splits a grapheme cluster — and `NSRegularExpression` rejects the `\u{0900}`
   escape that looks correct. Both are recorded in the shipped helpers' doc comments and pinned by
   `testTheFeaturesDevanagariChecksAreScalarTestsAndNotRegularExpressions`, so a future author
   reaching for the convenient form finds the measurement first.
4. **`-resultBundlePath` refuses to overwrite.** The bundle is removed before each run.
5. **One run produced a bundle with no `Info.plist`** while its log showed every suite completing;
   the two later bundles were complete. The notes' numbers come from the complete bundle, and the
   suite counts were cross-checked against the run's own `tests` listing rather than trusted from the
   summary alone.
6. **The unit baseline is genuinely red** — roughly 21 pre-existing failures outside this feature — so
   every gate here was scoped with `-only-testing:` to the 18 suites. All 18 were green; no scoped
   suite was skipped, disabled or weakened.

## Open items (reported, not silently closed)

1. **OD3 copy review owed** for `livetranslate.snapshot.capture` ("Hold this picture" /
   "यो दृश्य रोक्नुहोस्") and `livetranslate.snapshot.live` ("Go live again" / "फेरि चलाउनुहोस्").
   Both are marked DRAFT in the catalog and pinned in `LiveTranslateCopyTests`; they must be on the
   owner's OD3 list at `final-sign-off`.
2. **The pipeline determinism test is load-sensitive** (Environment findings, 2). Passed in the final
   gate and in isolation; its fix belongs to T-026's synchronisation, not to this task.
3. **`LiveTranslateView.swift` coverage reads 2.9% under this selection.** Stated rather than
   dressed up: the view is exercised by T-027's render suite, which is outside this gate's scope.
4. **The unit host cannot deliver a real touch.** The control's tap handler is asserted through
   `model.toggleSnapshot()` and the control's pixels through the render probe; the end-to-end tap —
   including VoiceOver focus and the 44 pt target under an actual finger — belongs to the UI-test
   layer, which is out of scope here.
5. **A freeze taken while the consent prompt is on screen** sends nothing: the frozen path resolves
   through the same consent gate, and the test asserts no request is built while a decision is
   outstanding. The prompt's own presentation over a frozen frame is T-015's surface and was not
   changed.
