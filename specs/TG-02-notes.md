# TG-02 — Camera capture and on-device detection: implementation notes

**Group:** TG-02 — Camera Capture and On-Device Text Detection (tasks T-006, T-007, T-008)
**Worktree:** `.claude/worktrees/live-camera-translation` (branch `worktree-live-camera-translation`)
**Scope discipline:** no commit, no workflow state touched, no file outside TG-02's scope edited.
**No shipped file was modified by TG-02** (NFR-LCT-012): all three components and every test below are **new
files**. The tracked-file delta in this working tree is TG-01's (`Info.plist`, `Localizable.xcstrings`,
`LogSanitiser.swift`, `InputSanitiser.swift`) plus XcodeGen's registration of the new files in the generated
`ios/seniOS.xcodeproj/project.pbxproj` — `134 insertions(+), 0 deletions(-)`, i.e. additive by construction.
TG-02 therefore has nothing to declare under "shipped code extended additively": it extended nothing.

## What was built

| Task | Created | Shipped file extended |
|------|---------|----------------------|
| T-006 | `Services/LiveTranslate/LiveCameraSession.swift` (638 lines) | — |
| T-007 | `Services/LiveTranslate/LiveTextDetector.swift` (396) | — |
| T-008 | `Services/LiveTranslate/Views/CameraPermissionView.swift` (178) | — |

Tests mirror under `ios/ElderlyAssistantTests/Services/LiveTranslate/`: `LiveCameraSessionTests.swift` (514),
`LiveCameraCaptureGuaranteeTests.swift` (215), `LiveTextDetectorTests.swift` (594, including
`VisionTextRecognitionEngineTests` and the scripted engine), `CameraPermissionSurfaceTests.swift` (279), and
two test-only helpers written for this group: `LiveCameraCaptureStub.swift` (132, T-006's stubbed capture
layer) and `ResultVoidAssertions.swift` (19). `VisionProbeTests.swift`, a scratch probe used to establish the
Vision findings below, was deleted before the gate; nothing references it.

### T-006 — the capture stack as one drop policy
`LiveCameraCaptureLayer` is the seam: `session`, `authorizationStatus`, `requestAccess()`,
`configureVideoOnly(onSampleBuffer:queue:)`, `startRunning()`, `stopRunning()`, `isRunning`, `thermalState`.
There is no photo/file entry point in the protocol, so a capture layer that captured stills could not satisfy
it. `AVFoundationCaptureLayer` is the shipped implementation: one `AVCaptureVideoDataOutput` on a serial video
queue with `alwaysDiscardsLateVideoFrames`, no other output.

`CameraFrame` is a buffer, a pixel size and a timestamp — and nothing else. `LiveCameraSession` owns the
policy: the tap drops (a paused/stopped session, then a pass in flight, then a sample inside the
thermal-adjusted interval), the stream holds `bufferingNewest(1)`, `start()` is the two-step permission
contract, the lifecycle observers pause/resume once per foreground transition, and `stop()` removes every
observer, finishes the stream and announces the end exactly once. Thermal response is
`config.ocrSampleInterval × config.thermalCadenceFactor` at or above `config.thermalStateThreshold`; no
operational literal appears in the file.

### T-007 — two non-interchangeable request kinds
`LiveTextRecognitionEngine` has three entries: `recognizeText(in:) -> [DetectedTextRegion]`,
`followRememberedRectangles(in:) -> [String: NormalizedBox]`, `forgetRememberedRectangles()`. The tracking
entry returns **geometry keyed by string and nothing else**, so no implementation of it can produce or change
recognized text; `Pass.regions` and `Pass.trackedBoxes` are the same split at the detector's boundary.
`VisionTextRecognitionEngine` runs the shipped Vision path: `VNRecognizeTextRequest` at `.accurate` with
`automaticallyDetectsLanguage = true` (iOS 16+), `VNSequenceRequestHandler` +
`VNTrackRectangleRequest(rectangleObservation:)` for tracking, re-anchoring on each tracked rectangle.
`LiveTextDetector` owns the cadence (`passKind(at:)`), the degradation policy, the failure policy and the
content-free events (`ocr_pass`, `ocr_pass_failed`, `tracking_unsupported`).

### T-008 — three states, one of which offers nothing
`CameraPermissionSurface` is the whole logic as a value type: `state(for:)` maps the session's **own** start
result (`.success` → `nil`, `.cameraPermissionNotDetermined` → `.explanation`,
`.cameraPermissionDenied` → `.denied`, everything else → `.unavailable`), and `message` / `actionTitle` /
`action` / `settingsURL` are computed from it. `.unavailable` carries **no error at all**, so no rendering
path can leak a cause. `CameraPermissionView` draws it as a card (message at `minBodyPointSize`, one control
at `minTapTargetSize`, `DesignTokens.card`) with stable accessibility identifiers.

## Gherkin coverage — scenario to test

### T-006 `LiveCameraSession` (+ `CameraFrame`)
| Scenario | Tests |
|---|---|
| Live preview starts with no photo output configured | `LiveCameraSessionTests.testThePreviewLayerIsAspectFitOverTheCaptureSessionsOwnLayer` (`.resizeAspect` over the session's own layer), `testASuccessfulStartConfiguresOneVideoPipelineRunsItAndAnnouncesTheSession`; `LiveCameraCaptureGuaranteeTests.testNoFeatureSourceCanConstructAnotherCaptureOutputOrWriteBytes` (all feature sources scanned for 15 forbidden tokens), `testTheScanDetectsEveryForbiddenShapeWhereItActuallyAppears` (the scanner finds every token it forbids, so a blind scan fails), `testTheCaptureLayerConfiguresOneVideoDataOutputAndNoOther` (construction sites == `{AVCaptureVideoDataOutput}`), `testTheCaptureSeamExposesNoPhotoOrFileEntryPoint` |
| A sampled frame is used in memory and released | `testASampledFrameCarriesItsInMemoryPixelBufferSizeAndTimestamp` (identity of the delivered buffer), `testTheStreamBuffersAtMostOneFrame`; `LiveCameraCaptureGuaranteeTests.testAFrameCarriesNoPersistableRepresentation`, `testRunningTheFramePathLeavesTheFileSystemUntouched` (temp/Documents/Caches path-set snapshot around a real frame path) |
| Frames are dropped, not queued, while a pass is in flight | `testASampleDuringAnInFlightPassIsDroppedRatherThanQueued`, `testSamplingDegradesUnderAnInFlightPassRatherThanAccumulatingWork` (10 in-flight samples → no backlog), `testASampleInsideTheConfiguredIntervalIsDropped`, `testNoFramesAreDeliveredWhileTheSessionIsBackgrounded` |
| Permission outcomes are explicit and non-retryable where they must be | `testTheFirstStartReturnsNotDeterminedWithoutStartingCaptureOrPrompting`, `testTheSystemPromptIsRaisedOnlyAfterTheCallerHasExplained`, `testADenialIsItsOwnResultAndNeverRaisesAPromptOrStartsCapture`, `testADenialInsideTheSystemPromptIsReportedAsADenial`, `testAMissingCaptureDeviceIsReportedAsSuchAndNeverRetriedAutomatically`, `testAConfigurationFailureIsReportedAsItsOwnReason`, `testAResourceInUseFailureIsReportedAsItsOwnReason`, `testAStoppedSessionIsNotRestartedBehindTheCallersBack` |
| Backgrounding and interruption pause, foregrounding resumes once | `testBackgroundingPausesCaptureAndForegroundingResumesItExactlyOnce` (one resume per transition, no loop), `testASystemInterruptionSurfacesAsAnHonestDegradedState`, `testThermalPressureIsReportedAsAThermalInterruption`, `testAnInterruptionArrivingWhileStartingKeepsCaptureOutOfTheBackground`, `testTheCadenceSlowsByTheConfiguredFactorAtOrAboveTheThermalThreshold`, `testTheReducedCadenceActuallyDropsTheSampleThatTheBaseCadenceWouldHaveTaken` |
| Stopping tears everything down | `testStopStopsCaptureFinishesTheStreamAndRemovesEveryObserver`, `testAFrameDeliveredAfterStopIsNotHandedOn`, `testStoppingASessionThatNeverStartedAnnouncesNothingAndIsIdempotent`, `testTheSessionEmitsOnlyCataloguedContentFreeEvents` |

### T-007 `LiveTextDetector`
| Scenario | Tests |
|---|---|
| English and Nepali text are recognized on device | `VisionTextRecognitionEngineTests.testEnglishTextIsRecognizedOnDeviceWithAValidBoxInReadingOrientation` (real Vision on a CoreText-rendered frame: text found, valid box, top-left orientation), `testTheRuntimeHasNoDevanagariRecognitionLanguage`, `testADevanagariFrameIsNotAnErrorAndNeverInventsTextOrLanguage`; on-device: `LiveTextDetectorTests.testTheDetectorReachesNoNetworkAndDownloadsNoModel` (scans the detector for 11 network/model-download tokens). **The Nepali half of this scenario is not satisfiable by Vision on this runtime — Open item 1.** |
| The OCR pass is the only source of recognized text | `testAnOCRPassProducesTextAndNoTrackedGeometry`, `testATrackingPassProducesGeometryOnlyAndCannotChangeText`, `testTrackingIsNotEvenAttemptedWhenAnOCRPassRecognizedNothing`, `testTrackingIsNeverTheFirstPassOfASession`; `VisionTextRecognitionEngineTests.testTheTrackingPassFollowsARememberedRectangleAndNeverReturnsText` (the shipped engine's tracking entry, typed to have no string in its result) |
| Tracking carries position between OCR passes and degrades gracefully | `testThePassKindFollowsTheConfiguredCadence`, `testATrackingLossOmitsTheKeyRatherThanMovingOrDroppingTheRegion`; `VisionTextRecognitionEngineTests.testTheTrackingPassFollowsARememberedRectangleAndNeverReturnsText`, `testForgettingTheRectanglesEndsTracking` |
| An unreadable frame is not an error | `testAnEmptyPassSucceedsWithNoRegionsAndReportsTheEmptyOutcome` (`ocr_pass` outcome `empty`, no error) |
| A failed pass is dropped, never surfaced | `testAFailedPassIsReportedAsAFailureRecordedOnceAndNotLatched` (`.failure(.ocrPassFailed(.requestFailed))`, one `ocr_pass_failed`, flag cleared, retry succeeds), `testNoRecognizedTextReachesTheEvents` |
| Unsupported tracking degrades to OCR-only | `testUnsupportedTrackingIsAnnouncedOnceAndTheDetectorKeepsWorkingWithOCR`, `testTurningTrackingOffInConfigIsNotADegradationAndIsNotReported`, `testATrackingRequestTheDeviceRefusesDegradesTheDetectorAtThatMoment` |
| The detected language is never invented and the source language is never hard-coded | `testAnOCRPassProducesTextAndNoTrackedGeometry` (no substituted language), `VisionTextRecognitionEngineTests.testEnglishTextIsRecognizedOnDeviceWithAValidBoxInReadingOrientation` (`detectedLanguage == nil` where Vision reports none), `testADevanagariFrameIsNotAnErrorAndNeverInventsTextOrLanguage`, `testRecognizingBeforeBeginIsReportedRatherThanRun` (the API takes no language parameter at all) |

### T-008 camera permission surfaces
| Scenario | Tests |
|---|---|
| The rationale precedes the OS prompt | `CameraPermissionSurfaceTests.testAStartThatHasNotYetBeenAskedMapsToTheExplanation`, `testTheExplanationIsShownInTheActiveLanguage`, `testTheExplanationOffersTheContinueActionAndNothingElse`, `testTheRationaleDescribesTheCameraAndNeverTheCloud`; end-to-end through the real session: `testAnUnresolvedPermissionStartsNothingAndRequestsNoFrame` |
| Denied permission is recoverable without a dead end | `testTheRefusalMapsToTheDeniedStateWithTheAppsOwnSettingsPage` (URL == `UIApplication.openSettingsURLString`), `testTheDenialCopyPointsAtSettingsInBothLanguages`, `testTheCardLeavesTheRestOfTheFeaturePresented` |
| The unavailable state carries no blame and no false cause | `testEveryCameraFailureThatIsNotAPermissionOutcomeMapsToTheUnavailableState`, `testTheUnavailableSurfaceIsIdenticalWhateverTheCause` (four causes → one `Equatable` surface), `testTheUnavailableStateOffersNoActionBecauseNoRetryCanSucceed`, `testTheUnavailableCopyClaimsNeitherOfflineNorAnotherCause`, `testTheViewCannotStartCaptureOrSkipTheExplanation` (no retry affordance in the source) |
| Permission is never assumed or auto-skipped | `testAnUnresolvedPermissionStartsNothingAndRequestsNoFrame` (drives the real `LiveCameraSession`: 0 configure, 0 requestAccess, state `.idle`), `testTheViewCannotStartCaptureOrSkipTheExplanation` (the view cannot name a session, an `AVCapture` type or `requestAccess`) |
| Rendered in the Nepali locale (DoD) | `testTheRenderedCardCarriesTheNepaliCopyAndNoControlWhenThereIsNone` (off-screen `ImageRenderer`; the Nepali and English message bands differ, so the copy reached the pixels; the `.unavailable` card is at least one `minTapTargetSize` shorter than the `.denied` card, so it drew no control) |

## Decisions made during implementation

- **The drop rule is kept as a drop, and the tap gained one guard.** `passInFlight` still makes the tap
  *discard* the sample — no queue was introduced. One state guard was added ahead of it: a sample that
  arrives while the session is not `.running` is dropped too. That is the case a real capture stack produces
  (a sample already in flight when `stopRunning()` lands, and the stubbed layer reproduces it); without the
  guard, `testNoFramesAreDeliveredWhileTheSessionIsBackgrounded` failed for the right reason — the tap was
  handing on a frame from a session the elder had already left.
- **One box representation (NFR-LCT-012).** The design's nested `x/y/width/height` sketch was **not**
  duplicated: the engine converts Vision's bottom-left box into the shipped top-level `NormalizedBox`
  (0–1, origin top-left) that the stabiliser, the placement mapper and the shipped overlay maths already
  consume. The conversion is a private static in the detector, values are clamped (a float a hair outside the
  frame is a rounding artifact, not geometry to drop) and an invalid box is skipped rather than emitted.
- **`detectedLanguage` is Vision's own report or `nil` — never a substitute.** The shipped engine currently
  reports `nil`: `VNRecognizeTextRequest.h` exposes `recognitionLanguages` (what to use) and
  `supportedRecognitionLanguages` (what exists), and `VNRecognizedText` has no per-candidate language
  property in this API. `automaticallyDetectsLanguage = true` still makes Vision choose the model itself, so
  the capability is on and the field is there for an engine that can report it. No caller can pass a source
  language in; the API has no such parameter.
- **Tracking degradation has three distinct outcomes, and only two are reported.** `supportsTracking == false`
  at `begin()` → announce `tracking_unsupported` **once** and run OCR-only. A tracking request the device
  refuses at run time → degrade at that moment (same event, once) and return
  `.failure(.trackingUnsupported)`. A mere **loss** (the tracker has no result for a key on this frame) is not
  a degradation at all: the key is simply absent from `trackedBoxes`, and the stabiliser keeps the last
  OCR-confirmed geometry. A configured "off" (`trackingEnabled == false`) is deliberate, so it is **not**
  reported as a degradation — pinned by `testTurningTrackingOffInConfigIsNotADegradationAndIsNotReported`.
- **`supportsTracking { true }` for the shipped engine, with the honest justification in the source.**
  `VNTrackRectangleRequest(rectangleObservation:)` is a non-failable initializer on a supported OS, so there
  is no probe that could honestly answer "no" before the first pass. A device where the request cannot be
  *run* is handled where that happens (the pass throws → degrade), which is the same honest event.
- **Tracking is never the first pass, and a failing scene is not a retry loop.** `passKind(at:)` answers
  `.tracking` only when tracking is available, something was remembered **and** an OCR pass has happened;
  otherwise `.ocr`. `lastOCRPassAt` is stamped at the *start* of an OCR pass, before recognition, so a scene
  that fails every pass cannot become a per-frame retry loop — the cadence bounds Vision on failure exactly
  as it does on success.
- **`trackedBoxes` is keyed by the recognized string.** The design says "region id"; region identity, merging
  of duplicates and the region cap are T-009's (the T-007 spec forbids capping here). Two observations with
  the same string collapse to the later one in this map — a case the stabiliser's own merge handles — and it
  is documented at the map in the source.
- **T-008's unavailable state carries no error, by construction.** The type holds only the three-case
  `State`; there is no field a cause could travel in, so "the elder is never told a cause the code cannot
  verify" is a property of the type rather than a discipline in the view. `settingsURL` is produced only for
  `.openSettings` from the same `action` switch, so the deep link cannot appear on a state whose recovery it
  is not.
- **No twentieth catalog key (T-005's pin holds).** The copy is composed from the 19 keys T-005 pinned:
  `livetranslate.camera.explanation` + `onboarding.stepPermissions.allow` (explanation),
  `livetranslate.camera.denied` + `state.error.openSettings` (denial), `livetranslate.state.unavailable`
  (unavailable — the cause-neutral wording the T-008 spec asks for). The nuance is reported as an open item
  for OD3 rather than smuggled in as a new key that would break T-005's exact-set test.
- **The rendering test measures pixels, not the accessibility tree.** A probe established that SwiftUI's
  accessibility tree is not vended through UIKit in a unit-test host: the `_UIHostingView` reported
  `accessibilityElements` 0 and `accessibilityElementCount()` 0/no UIKit subviews at all. A label read-back
  would have asserted on an empty tree and passed for the wrong reason, so the DoD's "snapshot or
  accessibility test" is satisfied by an off-screen `ImageRenderer` comparison instead (see Open item 6).
- **The scanners are falsifiable.** The forbidden-capture scan is re-run over synthetic source containing
  every shape it forbids (`testTheScanDetectsEveryForbiddenShapeWhereItActuallyAppears`), and the Devanagari
  sentinel asserts the *absence* of recognition support, so the day Vision gains a Devanagari language the
  sentinel fails and points at the integration test to extend. Tokens are converted with
  `NSRegularExpression.escapedPattern(for:)`: `FeatureSourceScan.firstMatch` takes a regular expression and
  fails the test on an invalid pattern, so `write(to:` had to stop being one.

## Verification performed

**Gate (scoped): PASS — exit 0, 68 tests, 0 failures.**

```
cd ios
xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveCameraSessionTests \
  -only-testing:ElderlyAssistantTests/LiveCameraCaptureGuaranteeTests \
  -only-testing:ElderlyAssistantTests/LiveTextDetectorTests \
  -only-testing:ElderlyAssistantTests/VisionTextRecognitionEngineTests \
  -only-testing:ElderlyAssistantTests/CameraPermissionSurfaceTests \
  -resultBundlePath build/TG02-gate.xcresult
```

`** TEST SUCCEEDED **`, `Executed 68 tests, with 0 failures (0 unexpected) in 10.244 (10.331) seconds`.
Per suite: `CameraPermissionSurfaceTests` 14, `LiveCameraCaptureGuaranteeTests` 6, `LiveCameraSessionTests`
26, `LiveTextDetectorTests` 17, `VisionTextRecognitionEngineTests` 5. All five suites pass, and each was also
run alone while the failures below were being fixed.

`ios/build.sh test:unit` cannot scope, so the raw `xcodebuild` invocation above mirrors its flags exactly
(`seniOS.xcodeproj`, scheme `ElderlyAssistant`, warm `build/DerivedDataTests`,
`-skip-testing:ElderlyAssistantUITests`) and pins the destination to this worktree's own device.

**Corroboration in the full unit bundle.** The same command without `-only-testing`:
**3408 tests, 3380 passed, 21 failed, 7 skipped** (`xcrun xcresulttool get test-results summary`). The
baseline was 3340 (3312/21/7), so the bundle grew by exactly TG-02's 68 tests and the failure count did not
move. All five TG-02 suites passed inside it, and none of the 21 failures is TG-02's: they are the
pre-existing red baseline, 20 of them enumerated in the log across the same unrelated suites
(`DialectIdentifierTests` 5, `IntentEncoderInterpreterTests` 3, `IntentEncoderArtifactTests` 2,
`IntentEncoderWiringTests` 2, `LocalBrainChainTests` 2, `ModelCatalogSTTNamingTests` 2,
`IntentEncoderSideloadTests` 1, `InterpreterAvailabilityTests` 1, `MultipartDownloadTests` 1,
`VoiceTurnLatencyTracerTests` 1). `VoiceTurnTimingSeamTests` — one of the 11 suites TG-01 recorded — passed
this time, which is the same pre-existing flakiness seen from the other side; TG-02 did not diagnose or touch
any of it.

Two TG-01 guarantees that now read TG-02's sources also passed inside that bundle:
`LiveTranslateSourceHygieneTests` (the "no operational literal" scan covers `LiveCameraSession.swift`,
`LiveTextDetector.swift` and `Views/CameraPermissionView.swift`) and `LiveTranslateEventsTests` /
`LiveTranslateCopyTests` (every event and every key the new code uses is a catalogued one).

### T-006 DoD
- "A test asserts no photo output is constructed and no file is written by the frame path" —
  `testNoFeatureSourceCanConstructAnotherCaptureOutputOrWriteBytes`,
  `testTheCaptureLayerConfiguresOneVideoDataOutputAndNoOther`,
  `testRunningTheFramePathLeavesTheFileSystemUntouched`.
- "A test asserts a sampled frame during an in-flight pass is dropped, not queued" —
  `testASampleDuringAnInFlightPassIsDroppedRatherThanQueued`,
  `testSamplingDegradesUnderAnInFlightPassRatherThanAccumulatingWork`.
- "A test asserts observers are removed on stop and one resume per foreground transition" —
  `testStopStopsCaptureFinishesTheStreamAndRemovesEveryObserver`,
  `testBackgroundingPausesCaptureAndForegroundingResumesItExactlyOnce`.
- "Integration test against a stubbed capture layer, including the interruption path" — the whole suite runs
  against `LiveCameraCaptureStub`; `testAnInterruptionArrivingWhileStartingKeepsCaptureOutOfTheBackground`
  posts `wasInterruptedNotification` from inside `startRunning()`, and `testStopStopsCaptureFinishesTheStreamAndRemovesEveryObserver`
  asserts the observers stop firing afterwards.

### T-007 DoD
- "A test asserts an OCR pass is the only text source and a tracking pass changes no text" —
  `testATrackingPassProducesGeometryOnlyAndCannotChangeText` (the tracking path's result type has no string
  in it), `testAnOCRPassProducesTextAndNoTrackedGeometry`.
- "A test asserts an empty pass reports success-with-empty and no error" —
  `testAnEmptyPassSucceedsWithNoRegionsAndReportsTheEmptyOutcome`.
- "A test asserts a failed pass is dropped with no user-visible state" —
  `testAFailedPassIsReportedAsAFailureRecordedOnceAndNotLatched`.
- "A test asserts the tracking-unsupported path degrades to OCR-only" —
  `testUnsupportedTrackingIsAnnouncedOnceAndTheDetectorKeepsWorkingWithOCR`,
  `testATrackingRequestTheDeviceRefusesDegradesTheDetectorAtThatMoment`.

### T-008 DoD
- "A test asserts capture is not started before permission resolves" —
  `testAnUnresolvedPermissionStartsNothingAndRequestsNoFrame` (real session + stubbed layer: 0 configurations,
  0 prompt requests).
- "A snapshot or accessibility test covers the three states in the Nepali locale" — satisfied by
  `testTheRenderedCardCarriesTheNepaliCopyAndNoControlWhenThereIsNone` plus the copy assertions in both
  locales; see Open item 6 for what this does and does not prove.
- `ios/build.sh` — see Open item 7.

## Environment findings (not source changes; the next task in this worktree will hit them)

- **SwiftUI's accessibility tree is not readable from a unit-test host.** `UIHostingController` in a
  `UIWindow`, with a real `UIWindowScene`, made key and visible, laid out and given a run-loop turn, reports
  `_UIHostingView` with `accessibilityElements == 0`, `accessibilityElementCount() == 0` and **no UIKit
  subviews**, so neither `accessibilityLabel` nor a recursive `UIAccessibilityElement` walk finds anything.
  `ImageRenderer` (off screen, no window) is the working substitute for "what did the view draw".
- **Vision on this runtime recognizes English and has no Devanagari.** `VNRecognizeTextRequest` at
  `.accurate`/revision 3 reads a rendered "EXIT" (valid box, top-left orientation after the mirror) and
  returns **no text and no error** for a rendered Devanagari frame. `supportedRecognitionLanguages(for:
  .accurate, revision: 3)` contains no `ne`/`hi`/`sa`/`mr` entry.
- **`AsyncSequence` has no parameterless `first()`,** and `XCTUnwrap(await …)` is a compile error
  ("`'async' call in an autoclosure that does not support concurrency`"): awaited values must be hoisted into
  a local first.
- **`Result<Void, E>` is not `Equatable` and bare `.success` does not compile** ("member 'success' expects
  argument of type 'Void'"); tests read outcomes through `ResultVoidAssertions` (`isSuccess`,
  `failureError`) and production writes `.success(())`.
- **`FeatureSourceScan.firstMatch` takes a regular expression and fails the test on an invalid pattern**
  ("bad scan pattern"). Any token containing regex metacharacters must go through
  `NSRegularExpression.escapedPattern(for:)`.
- **An unbounded wait on a frame the cadence will never deliver hangs the whole suite** (it happened: the
  guarantee test awaited 4 frames while the injected clock stood still, so only the first was sampled). Every
  frame wait in this group is bounded, and a test that injects `now:` must advance it.
- **The pinned simulator** `990E1710-4805-46E2-8FED-BD1DE12D1BE8` is an iPhone 17 (iOS 26.5, x86_64) private
  to this worktree; another worktree (`model-lifecycle`) was building on its own derived data at the same
  time with no interference.

## Open items (reported, not silently closed)

1. **FR-LCT-003's "English and Nepali text are recognized" is only half satisfiable on this runtime.**
   Vision has no Devanagari recognition language here (sentinel test
   `testTheRuntimeHasNoDevanagariRecognitionLanguage`), so a Nepali scene renders as an empty, error-free
   pass (`testADevanagariFrameIsNotAnErrorAndNeverInventsTextOrLanguage`). Nothing is stubbed and nothing
   reports success it did not achieve. The seam that makes this fixable cheaply is C02's
   `LiveTextRecognitionEngine`: a Devanagari-capable recognizer is a swap of the engine, not a rewrite of the
   detector, cadence or degradation policy. The owner decision this needs is product-level: add such an
   engine, or accept that Nepali *scene* text is out of scope for this revision (the feature's own Nepali↔
   English translation path is unaffected — this is about reading Devanagari off a camera frame).
2. **OD3 copy review of the permission surfaces.** Three of the four strings are reused rather than new:
   the explanation's body is `livetranslate.camera.explanation` and its control is the onboarding
   `onboarding.stepPermissions.allow`; the unavailable state shows the generic
   `livetranslate.state.unavailable`. They read truthfully in both locales (pinned), but if the copy owner
   wants camera-specific or device-specific wording, that is a new catalog key — which would break T-005's
   exact-19-key pin and therefore needs to be a deliberate change to T-005, not a side effect of T-008.
3. **Camera cadence vs detector cadence (wiring, T-026/T-027).** The tap throttles samples to
   `config.ocrSampleInterval`, and the detector's OCR cadence is the same value, so in the shipped wiring a
   sampled frame is normally "due" for an OCR pass and tracking passes carry geometry for frames delivered
   sooner than the cadence. If the pipeline wants tracking to carry frames *between* OCR passes at the
   configured interval, either the tap must sample faster than the detector's OCR cadence or the interval's
   owner must be split. No new config knob was invented for this in TG-02.
4. **`trackedBoxes` keys are recognized strings, not region ids (T-009).** The stabiliser owns region
   identity, duplicate merging and the cap; if it needs ids, the mapping belongs there. Noted at the map in
   the source.
5. **`LiveTextDetector.isPassInFlight` and `LiveCameraSession.ocrPassInFlight` are deliberately not joined.**
   The session's flag is what makes the tap drop samples; the detector exposes its own state so the pipeline
   (T-026) can drive the first from the second. TG-02 wires nothing between them (the detector does not
   reference the session at all), which is why `testIsPassInFlightIsTrueForTheWholePassAndFalseAfterwards`
   exercises the detector's flag directly.
6. **T-008's "snapshot or accessibility test" is a rendering test, not an accessibility read-back** (see the
   environment finding: UIKit is handed nothing to read in a unit-test host). What it proves: the Nepali and
   English message bands differ on screen, so the localised copy is drawn; the `.unavailable` card is at
   least one tap target shorter, so it draws no control. What it does not prove: that VoiceOver announces a
   specific label/identifier, or the control's measured height. Completing that needs an XCUITest, which the
   unit gate skips (`-skip-testing:ElderlyAssistantUITests`); the identifiers are in the source
   (`livetranslate.camera.message`, `livetranslate.camera.action`) so a UI test can be added when the
   presenting view lands (T-027).
7. **`ios/build.sh` DoD line.** `build.sh test:unit` runs the whole unit bundle, which is red on master
   independent of this work (21 failures, unrelated suites — see "Verification performed"). The scoped
   invocation above mirrors its flags; the full bundle was run anyway and grew by exactly TG-02's 68 tests
   with the failure count unchanged. `Code reviewed and merged` remains the driver's step for all three
   tasks.

## Out-of-scope capabilities — confirmed absent, not stubbed

A scan of the three production files for the forbidden capture shapes (`AVCapturePhotoOutput`,
`AVCapturePhotoSettings`, `AVCaptureMovieFileOutput`, `AVCaptureFileOutput`, `AVAssetWriter`,
`UIImagePickerController`, `PHPickerViewController`, `PHPhotoLibrary`, `UIImageWriteToSavedPhotosAlbum`,
`UIActivityViewController`, `FileManager`, `FileHandle`, `write(to:`, `Data(contentsOf:`, `NSData`) finds
**none**, and the scanner is falsified against synthetic source containing every one of them. The only capture
output constructed anywhere is `AVCaptureVideoDataOutput`. The detector contains no `URLSession`, `URLRequest`,
`dataTask`, `URLComponents`, `NWConnection`, `http(s)://`, `GeminiClient`, `VNCoreMLModel`, `MLModel` or
`url(forResource` — recognition is Vision's and it is local. The permission view contains no session, no
`AVCapture` type, no `requestAccess`, no `livetranslate.consent` key and no retry affordance. There is no
placeholder that returns success for any of it.
