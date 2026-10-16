# TG-08 — Spoken output and in-session capture: T-024 `LiveTranslateSpeech` + T-025 `LiveTranslateCommandCapture` implementation notes

Tasks: **T-024 tap-to-hear and "read this to me"** (C12 spoken output) and
**T-025 in-session capture and audio arbitration** (C01 capture configuration + C12 command capture).
Worktree: `.claude/worktrees/live-camera-translation`. Uncommitted, per the workflow (no commits were made).
Requirements: FR-LCT-021, FR-LCT-023, NFR-LCT-004, NFR-LCT-009 · **CL-8** (T-024) ·
FR-LCT-021, NFR-LCT-005, NFR-LCT-011 (T-025).

## What was built

### `ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateSpeech.swift` (296 lines, new)

C12's spoken output: **two entry points, and no others**.

- `speakTappedRegion(_:in:)` speaks exactly one region — the one that was tapped, resolved by identity
  in the placements it was handed. `readAll(_:)` speaks the readable regions top-to-bottom, each once,
  sequentially on the shipped queue. Both build `Announcement(priority: .interactive)` and hand it to
  `SpeakQueue`; `sourceID` is the feature's own component token (`LiveTranslateEventCatalogue.component`),
  so anything of this feature's can be found and drained later.
- `orderedForReading(_:)` **delegates** to `LiveOverlayPlacement.readingOrder` — the placement's own
  canonical order (T-020) — so the reading order and the draw order cannot drift apart. The design's
  sketch of `LiveTranslateSpeech.orderedForReading` (left unbuilt by T-023, notes item 7) is this method.
- `spokenText(of:)` returns the placement's primary line — the very string the bubble draws and
  `RegionPresentation` announces. A translation is never re-derived here, so what is heard cannot differ
  from what is seen. `isReadable(_:)` decides what read-all includes: `.resolved` yes, `.degraded` yes
  (read as its **original text**, which is what is on screen), `.degraded(.textQuarantined)` **never**,
  `.pending` no (reading unfinished work as if it were the answer would be a lie).
- `isTappableToHear(_:)` is `sourceTier != nil` — only a region that actually has a translation is a
  "hear this" affordance. A tap on a region with nothing to say is refused with `speak_failed` rather
  than degraded into reading the original, because reading the original is the *command*'s behaviour and
  it is worth keeping the two apart.
- `repeatLast()` (CL-8) replays the **exact `Announcement` values** the last speaking request enqueued —
  no re-derivation, no re-translation, no new construction — after draining the feature's own in-flight
  utterance so "say that again" restarts rather than queueing a second copy behind the first. With
  nothing spoken yet it records `speak_failed` with the `repeat_last` mode token; a silent no-op would be
  a turn the elder spoke into and heard nothing back from.
- `stop()` and `close()` both `drain(sourceID:)`. `close()` additionally empties what is repeatable and
  makes the instance inert, so a view teardown that races a tap cannot start speech into a session the
  elder has left.
- `isSpeaking` answers the source-scoped question T-025's microphone gate needs.
- Events are `speak_requested` / `speak_failed` with a `mode` token (`LiveTranslateSpeechMode`) only. The
  text being spoken has no parameter to travel in.

`LiveTranslateSpeechPath` is the shipped queue narrowed to what C12 uses (`enqueue`, `drain(sourceID:)`,
`isSpeaking(sourceID:)`), with `extension SpeakQueue: LiveTranslateSpeechPath {}` as production. It is
deliberately **not** a second speech abstraction: `enqueue` is `SpeakQueueProtocol`'s own contract, and
the other two are the additive seam below.

### `ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateCommandCapture.swift` (400 lines, new)

C12's command microphone: one utterance at a time, paused while the feature speaks.

- `LiveTranslateUtteranceCapturing` (start / cancel) is the shipped single-utterance capture's own
  contract, and `extension SearchPhraseCapture: LiveTranslateUtteranceCapturing {}` is the whole
  conformance. There is no second recognition stack, no continuous recogniser, no timer and no restart
  loop in this file: the type only decides *when* the shipped capture may listen.
- `Outcome` is the honest enumeration of what one window produced — `.command`, `.reprompt`, `.turnEnded`
  (T-023's turn rule, reached through `LiveTranslateCommandTurn.accept(_:in:)` against the
  catalog-resolved phrase table), `.noSpeech`, `.unavailable`, `.cancelled`, `.refused(_:)`.
- **The feature never hears itself, three guards deep**: `listen` refuses with `.featureIsSpeaking` while
  the feature speaks; `speechBegan()` cancels an open window and `speechEnded()` resumes it with a
  **fresh** window (so nothing said before or during the speech can answer it); and a transcript that
  arrives while the feature is speaking is discarded rather than parsed, so even a race the first two
  guards miss cannot turn the feature's own voice into a command.
- **Logical window vs physical microphone.** `isListening` is the elder's unanswered request;
  `isMicrophoneOpen` is recognition actually running. A pause closes the microphone and leaves the request
  open. A resume that arrives while the device is still closing waits (`resumeWhenMicrophoneCloses`)
  instead of asking the shipped capture for a window it would silently refuse.
- **Interruptions** are observed on the audio session's own notification (`object: nil`) and mapped onto
  the same pause/resume: an interruption cannot answer the window, and the resume is a fresh window, so no
  pre-interruption audio can become a command. A notification that is not an interruption changes nothing.
- `close(then:)` makes the design's teardown order structural rather than conventional: recognition stops,
  the command window is dropped without an outcome, this feature's own `audioSession.deactivate()` runs,
  and only then the caller's `releaseCaptureSession()` closure (the camera, T-006) executes. A recognition
  callback that lands afterwards finds `isClosed` and does nothing at all.
- The file holds **no observability bus** and no audio buffer, file handle or URL session — a transcript
  has nowhere to travel and nothing to be written to. The parser's vocabulary, near-miss rule and single
  re-prompt stay T-023's; this file spells no phrase of its own. It also never calls `setCategory`: the
  category, mode and options live in `AudioSessionManager` and nowhere else.

### `ios/ElderlyAssistant/Services/Voice/SpeakQueue.swift` (one additive edit, +36 lines)

Two source-scoped operations on the shipped queue, added beside the shipped lane policy and changing
none of it (see *Shipped-file edits* below).

### Tests (all new, under `ios/ElderlyAssistantTests/Services/LiveTranslate/`)

- `LiveTranslateSpeechTests.swift` (906 lines, **33 tests**) — behavioural checks over a recording speech
  path and placements built by the real `LiveOverlayPlacement` (so "the spoken string is the on-screen
  string" is asserted against the lines the overlay actually draws), plus two integration tests against
  the **real** `SpeakQueue` with a hand-gated `ParkingSpeaker`.
- `LiveTranslateCommandCaptureTests.swift` (731 lines, **26 tests**) — a hand-driven device double and a
  `SessionDrivingDevice` that opens and closes its window *through* the shipped `AudioSessionManager`
  (itself driven by a stub `AudioSessionControlling`), so the audio calls the tests read are the ones the
  real manager makes, and the interruption path is exercised by posting the real notification.

## Shipped-file edits (NFR-LCT-012)

One file, additive only, no behaviour of any existing caller changed:

`ios/ElderlyAssistant/Services/Voice/SpeakQueue.swift`
- `drain(sourceID:)` — drops every pending announcement belonging to `sourceID` and cancels the utterance
  now playing **when it is that source's**. Source-scoped on purpose: "stop reading" must never silence a
  medication reminder queued behind the reading. The cancel runs after the lock is released, for the same
  reason preemption does (a resumed continuation runs inline on the resuming thread and must not re-enter
  the lock).
- `isSpeaking(sourceID:)` — the source-scoped counterpart of the shipped `isSpeaking`. Another lane
  speaking is not this feature speaking, which is exactly the question T-025's gate asks.

No existing method, lane rule, admission decision or delivery path was touched; the regression suite
`SpeakQueueTests` (9 tests) still passes unchanged, and the seam is exercised where it matters — in the
two `LiveTranslateSpeechTests` integration tests that drive the real queue and assert that another
source's medication announcement keeps playing through a `stop`.

## Gherkin coverage — scenario to test

### T-024 `LiveTranslateSpeech` — 8 scenarios

| Scenario | Test |
|---|---|
| Tapping a bubble speaks that region and nothing else | `testTappingARegionSpeaksThatRegionAndNothingElse` (asserts exactly one enqueue, that region's text, and no other region's) |
| Read-all speaks the visible regions top-to-bottom | `testReadAllSpeaksEveryReadableRegionOnceInReadingOrder` (order, once each, sequential), `testTheReadingOrderIsThePlacementGeometryNotAStoredOrArrivalOrder` (arrival order ≠ reading order), `testTheSpokenOrderIsThePlacementsOwnOrdering` (the order is T-020's, not a second copy) |
| ↳ …in the active-language voice (scenario 2's second Then) | `testTheVoiceIsTheQueuesChoiceAndNotThisFeatures` (the announcement names no voice and no locale: the queue's own `AppLanguage.persisted()` decides, and the feature cannot override it) |
| Nothing is spoken automatically | `testAResolutionEnqueuesNoSpeech` (an enqueue-site scan: the only enclosing functions of an `.enqueue(` in the feature are the three handlers), `testOnlyTheTapHandlerAndTheCommandHandlerConstructAnnouncements` (the construction-site count), `testNoObservingHookExistsInTheFeatureThatCouldEnqueueSpeech` (no `didSet`/`willSet`/`onReceive`/`onChange`/`addObserver`/`NotificationCenter`/`Task`/`await`/`Timer`/`DispatchQueue` in the file) |
| Nothing quarantined is ever spoken | `testAQuarantinedRegionIsSkippedWithoutBlockingTheOthers`, `testAQuarantinedRegionIsTheOnlyRegionNothingIsSpokenFor` |
| Degraded regions are spoken honestly | `testADegradedRegionIsReadAsItsOriginalTextAndNotAsATranslation`, `testADegradedRegionIsNotATapToHearTarget`, `testTapOnARegionWithNothingToSaySpeaksNothingAndRecordsTheFailure` |
| Speech stops immediately on request | `testStopDrainsTheFeaturesOwnAnnouncements`, `testCloseDrainsTheSameWayAndMakesTheInstanceInert`, `testCloseIsIdempotentAndDrainsOnlyOnce`, `testStopKeepsWhatWasSpokenRepeatable`, `testStopCancelsTheFeatureUtteranceInFlightAndDropsTheRest` (real queue, in-flight utterance cancelled), `testTheDrainSeamLeavesAnotherSourcesUtterancePlaying` (real queue, another source untouched) |
| A speech failure leaves the visual path untouched | `testASpeechFailureStartsNoRetryAndTouchesNothingElse`, `testSpeakingIsReportedPerSourceAndFalseWhenClosed` |
| Reading does not re-translate or re-send | `testTheSpokenStringIsExactlyTheOnScreenString`, `testTheSpeechPathReachesNoTranslationCacheConsentOrCostCode` (source scan: no `translateStrings`, `GeminiClient`, `LabelTranslationCache`, `URLSession`/`URLRequest`, consent gate or cost governor in scope) |

Supporting and adjacent properties asserted by the same suite: `testTheAnnouncementIsTheShippedShape`
(the announcement is the shipped value type: `.interactive`, the feature's `sourceID`, no card),
`testTheConstructionSiteScanDetectsAThirdSite` (the scanner's falsifiability control — it is run against
a synthetic source that *does* have a third site and must find it), `testAPendingRegionIsNotRead`,
`testTheDisplayPreferenceChangesNothingAboutWhatIsSpoken`, `testReadingUsesThePlacementsItWasGivenAndNothingElse`,
`testRepeatReplaysTheExactAnnouncementsWithoutBuildingNewOnes` (the replayed announcements are the very
values, proven by identity and by there being no second construction), `testRepeatBeforeAnythingWasSpokenSpeaksNothingAndRecordsTheFailure`,
`testRepeatDoesNotGoThroughATapOrAReading`, `testNoSpokenOrRecognizedTextReachesAnyEvent`,
`testTheSpeechEventsAreTheTwoDeclaredOnesWithOnlyTheModeToken`.

### T-025 `LiveTranslateCommandCapture` — 6 scenarios

| Scenario | Test |
|---|---|
| A spoken command is captured as a single utterance | `testASpokenCommandIsCapturedAsASingleUtterance` (one window in, one outcome out, and the utterance reaches the parser), `testEveryCommandInTheVocabularyIsReachableFromASpokenPhrase`, `testASecondWindowIsRefusedWhileOneIsOpen` (single-utterance, not always-on), `testAMissRepromptsOnceAndThenEndsTheTurn`, `testSilenceIsNotAFailure`, `testAnUnusableMicrophoneIsReportedAsUnavailable` |
| The feature does not hear itself | `testTheWindowIsRefusedWhileTheFeatureIsSpeaking`, `testSpeechPausesTheMicrophoneAndTheResumeIsAFreshWindow`, `testATranscriptThatArrivesWhileTheFeatureIsSpeakingIsNeverACommand`, `testAudioFromBeforeTheSpeechCannotAnswerTheResumedWindow` |
| Recording coexists with background audio | `testACommandWindowActivatesTheShippedPresetThatMixesWithOtherAudio` (the shipped `.playAndRecord` + `.measurement` + `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]`, activated through the real manager), `testTheFeatureNeverConfiguresTheAudioCategoryItself` (source scan: no `setCategory` in the file) |
| Closing releases the microphone as completely as the camera | `testCloseReleasesTheMicrophoneInTheDesignsOrder` (one ordered log: recognition stops → window dropped → `audio.deactivate` → camera release), `testClosingWhilePausedStillReleasesTheAudio`, `testNoRecognitionCallbackFiresAfterTeardown`, `testAClosedCaptureOpensNoFurtherWindowAndRefusesToListen`, `testAResumeThatArrivesMidTeardownWaitsForTheDevice`, `testCancelAnswersTheCallerAndStopsTheMicrophone`, `testCancelWhilePausedAnswersImmediately` |
| An interruption pauses capture and resumes safely | `testAnInterruptionPausesCaptureAndResumesItWithoutDuplicatingACommand` (the real `AVAudioSession.interruptionNotification`), `testAudioFromBeforeTheInterruptionCannotFireACommand`, `testANotificationThatIsNotAnInterruptionLeavesCaptureAlone`, `testACancellationNobodyAskedForEndsTheWindowWithoutACommand` |
| Command audio is never retained or uploaded | `testTheCaptureHoldsNoTranscriptAndNoAudio` (Mirror over the instance: no `String`, `[String]`, `[String: String]`, `Data`, `URL` or file handle is stored), `testTheCaptureCannotLogStoreOrSendAnything` (source scan: no `print`/`NSLog`/`os_log`, no file or network API, no bus), `testNoTranscriptTextReachesAnyEventOrLogRecord` (the only event types that reach the bus are the shipped audio activate/deactivate ones) |

## Definition of done

T-024:

| DoD bullet | Evidence |
|---|---|
| All Gherkin scenarios covered | table above; 33/33 tests pass |
| A test asserts tap-to-hear speaks only its own region | `testTappingARegionSpeaksThatRegionAndNothingElse` |
| A test asserts reading order matches vertical-then-horizontal ordering | `testReadAllSpeaksEveryReadableRegionOnceInReadingOrder` (midpoints tie-broken horizontally), plus `testTheReadingOrderIsThePlacementGeometryNotAStoredOrArrivalOrder` |
| A test counts announcement construction sites and fails if a third appears | `testOnlyTheTapHandlerAndTheCommandHandlerConstructAnnouncements` (count == 2, and the enclosing functions are exactly `speakTappedRegion` / `readAll`), with `testTheConstructionSiteScanDetectsAThirdSite` as the control |
| A test asserts stop and close both drain the queue with no late playback | `testStopDrainsTheFeaturesOwnAnnouncements`, `testCloseDrainsTheSameWayAndMakesTheInstanceInert`, `testStopCancelsTheFeatureUtteranceInFlightAndDropsTheRest` |
| A test asserts a quarantined region is skipped without blocking the others | `testAQuarantinedRegionIsSkippedWithoutBlockingTheOthers` |
| No spoken or recognized text in any log or event | `testNoSpokenOrRecognizedTextReachesAnyEvent`, `testTheSpeechEventsAreTheTwoDeclaredOnesWithOnlyTheModeToken` |
| `ios/build.sh` passes | `./build.sh build` → `** BUILD SUCCEEDED **`, exit 0 |

T-025:

| DoD bullet | Evidence |
|---|---|
| All Gherkin scenarios covered | table above; 26/26 tests pass |
| A test asserts capture is single-utterance and no command fires from the feature's own speech | `testASecondWindowIsRefusedWhileOneIsOpen`, `testTheWindowIsRefusedWhileTheFeatureIsSpeaking`, `testSpeechPausesTheMicrophoneAndTheResumeIsAFreshWindow`, `testATranscriptThatArrivesWhileTheFeatureIsSpeakingIsNeverACommand` |
| A test asserts teardown releases the microphone with no callback after teardown | `testCloseReleasesTheMicrophoneInTheDesignsOrder`, `testNoRecognitionCallbackFiresAfterTeardown`, `testAClosedCaptureOpensNoFurtherWindowAndRefusesToListen` |
| A test asserts no audio is retained beyond the command window and none is uploaded | `testTheCaptureHoldsNoTranscriptAndNoAudio`, `testTheCaptureCannotLogStoreOrSendAnything` |
| Integration test against a stubbed audio session, including the interruption path | `SessionDrivingDevice` + `StubAudioSession` drive the real `AudioSessionManager`; `testACommandWindowActivatesTheShippedPresetThatMixesWithOtherAudio`, `testAnInterruptionPausesCaptureAndResumesItWithoutDuplicatingACommand`, `testAudioFromBeforeTheInterruptionCannotFireACommand` |
| `ios/build.sh` passes | as above |

## Decisions made during implementation

1. **"No auto-speak" is structural, not conventional.** The only two construction sites of an
   `Announcement` in the feature's sources are the tap handler and the command handler, and a test counts
   them by walking each construction site upward to its enclosing `func` and asserting the set is exactly
   `{speakTappedRegion, readAll}`. The scanner strips comments first (so prose about announcements cannot
   create a false site) and is itself falsified against a synthetic third site in the same run, so a
   broken scanner cannot pass for a clean feature. A complementary scan asserts the same about `.enqueue(`.
2. **The reading order is T-020's, not a second copy.** `orderedForReading` calls
   `LiveOverlayPlacement.readingOrder`. The alternative — re-deriving the midpoints here — would let the
   spoken order diverge from the drawn order in exactly the case nobody would notice (a tie).
3. **The spoken string is the placement's primary line** — the same expression `RegionPresentation` uses
   for its accessibility label — rather than a formatted or re-derived sentence. This is what makes
   "what the elder hears is what the elder sees" a property of the data flow.
4. **A degraded region is read as its original text; a quarantined one is not read at all.** FR-LCT-023
   asks for the honest fallback and NFR-LCT-009 forbids the quarantined string entirely; both are per
   region, so neither can silence the rest.
5. **Tap-to-hear refuses a region with no translation instead of falling back to its original.** The
   command's honest fallback and the tap's affordance are different promises; a button that silently does
   something else is worse than a recorded failure.
6. **`stop` is source-scoped, so the shipped `SpeakQueue` gained two additive operations** rather than a
   `cancelAll`. Silencing a medication reminder because the elder said "stop reading" would be a safety
   regression, and the added operations change no shipped admission, arbitration or delivery decision.
7. **`repeatLast` replays the announcement values, it does not rebuild them.** Re-deriving the text would
   be a second construction site and a second chance to say something different from what was said; the
   stored values are drained-then-re-enqueued so "say that again" restarts instead of doubling.
8. **The microphone is a *logical* window over a *physical* one.** `isListening` is the elder's request;
   `isMicrophoneOpen` is recognition running. A pause (the feature's own speech, an interruption) closes
   the physical window and leaves the request open, and the resume opens a fresh window — which is what
   makes "no command fires from pre-`speech`/pre-interruption audio" structural rather than hopeful.
9. **Three guards against self-hearing, not one**: refusal at `listen`, pause at `speechBegan`, and
   discarding a transcript that arrives while the feature speaks. The third is the one that holds when the
   other two race — and it is the failing shape a single gate would leave open.
10. **`close(then:)` takes the camera teardown as a closure** so the design's order (recognition → drain →
    audio → camera) is unexpressible any other way, and a post-teardown callback finds `isClosed`.
11. **No second audio policy.** The file never calls `setCategory`; the shipped `AudioSessionManager`
    owns the category string, and reusing it is what makes "recording coexists with background audio" and
    "the shipped permission surfaces are unchanged" the same fact.
12. **No observability bus in the capture.** The strongest form of "no transcript in any event" is for
    the transcript to have no bus to reach; the consequence is recorded as an open item (no matched-command
    evidence is emitted), and it matches T-023's decision 7.
13. **No new `LiveTranslateConfig` value.** The window timings are `SearchPhraseCapture`'s, so the
    banned-literal inventory (T-001/T-003) is untouched.
14. **A closed capture refuses rather than crashes.** `listen` after `close` answers `.refused(.sessionClosed)`
    immediately; every entry point is main-queue by `assert`, like the shipped capture it drives.

## Verification performed

Command — `ios/build.sh test:unit`'s flags, scoped to the two tasks' suites:

```
cd ios
./build.sh generate                            # XcodeGen — mandatory before testing
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/TG08bDerivedData -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSpeechTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCommandCaptureTests \
  -resultBundlePath build/TG08b-gate-final.xcresult
```

Result: **`** TEST SUCCEEDED **`**, and
`xcrun xcresulttool get test-results summary --path build/TG08b-gate-final.xcresult` →
`result: Passed · totalTestCount: 59 · passedTests: 59 · failedTests: 0 · skippedTests: 0`
(`LiveTranslateSpeechTests` **33/33**, `LiveTranslateCommandCaptureTests` **26/26**) on
iPhone 17 (iOS 26.5), x86_64.

Wider regression, on the same final tree — the two new suites plus every suite the work touches
(audio session, camera session, the parser, the config/copy/settings/events/hygiene pins, the queue):

```
xcrun xcresulttool get test-results summary --path build/TG08b-gate-regress3.xcresult
→ result: Passed · totalTestCount: 205 · passedTests: 205 · failedTests: 0 · skippedTests: 0
```

Per suite (from the same bundle): `LiveTranslateSpeechTests` **33**, `LiveTranslateCommandCaptureTests`
**26**, `LiveTranslateCommandParserTests` 24, `LiveCameraSessionTests` 26, `AudioSessionPresetTests` 15,
`LiveTranslateEventsTests` 17, `AlwaysShowOriginalToggleTests` 11, `LiveTranslateAppLayerHygieneTests`
11, `LiveTranslateCopyTests` 10, `LiveTranslateSettingsTests` 9, `SpeakQueueTests` 9,
`LiveTranslateConfigTests` 8, `LiveTranslateSourceHygieneTests` 6 — all passed, zero failures.

`ios/build.sh build` (both tasks' DoD line, run after the last source change): **`** BUILD SUCCEEDED **`**,
exit 0, zero compiler errors.

Coverage (`-enableCodeCoverage YES`, bundle `build/TG08b-cov2.xcresult`, read with
`xcrun xccov view --report --json` and `xcrun xccov view --file …`), line coverage of the two new source
files on the final tree:

| File | Line coverage | Covered / executable |
|---|---|---|
| `LiveTranslateSpeech.swift` | **99.1 %** | 112 / 113 |
| `LiveTranslateCommandCapture.swift` | **96.6 %** | 200 / 207 |

Both are well above the 80 % bar. The first coverage run (`build/TG08b-cov.xcresult`, taken before the
last test existed) reported 94.7 % for the capture file and named one behavioural gap: the device
reporting a cancellation nobody asked for. `testACancellationNobodyAskedForEndsTheWindowWithoutACommand`
was written for exactly that path, and the re-run above confirms it (196 → 200 covered lines). What is
left uncovered is only: the five-line defensive re-entry guard in `openMicrophone` (unreachable by
construction — `resumeIfPossible` tests the same condition before calling it, so no input can reach it)
and one `break` in an `@unknown default` of the interruption-type switch (unreachable by Swift's own
rule). `LiveTranslateSpeech.swift`'s single uncovered line is not itemised by the per-line report (no
zero-count line appears in it), which is reported here rather than rounded away.

`bash ios/tools/check-release-log-safety.sh`: exit 0,
`✓ no transcript content or raw error object can be printed in a non-Debug configuration`.

The gate was run repeatedly while the two tasks were built; the failures found and fixed along the way are
in *Environment findings* below where they were environmental. Two were real defects in the tests
themselves, found by the gate and fixed before this report: a helper that built an empty surface, making
an index-based assertion crash the whole test process (which silently shortened an earlier run — see
finding 4), and an assertion that assumed a teardown callback would not fire when in fact it does (the
code is right — the callback fires and must be ignored; the test now asserts exactly that).

## Environment findings

1. **The unit baseline in this checkout is genuinely red** (≈21 pre-existing failures across unrelated
   suites, e.g. the voice-turn timing suites), which is why verification is scoped rather than a full
   `./build.sh test:unit`. Nothing in this work's scope failed.
2. **XcodeGen must be re-run before testing — and a missing file fails silently.** A raw
   `xcodebuild test -only-testing:…/<NewSuite>` whose class is not in the generated project runs nothing
   and reports success; every count in this report was read from the result bundle, not the exit code.
3. **`ElderlyAssistantTests` compiles as one unit.** A build error naming a file this task does not own
   (another agent's in-flight edit) is not a defect here; the correct response is to wait and re-run, never
   to edit their file.
4. **A crash inside one test silently shortens the report.** An `Index out of range` in a fixture helper
   aborted the process mid-suite; the run still reported "Executed N tests" for the tests that had run by
   then. Per-suite counts from the bundle (not the console tail) are what caught it — the same discipline
   finding 2 asks for.
5. **Simulator contention across agents is real.** Concurrent `xcodebuild test` runs on the same device id
   produce XPC interruptions and `Simulator device failed to launch … RequestDenied` with no assertion
   failure; the device is shut down underneath the runner. Re-running is the fix; it is not a code defect.
6. **A Release build for a device destination running concurrently is enough to slow the gate down**, but
   not to break it — the runs in this report shared the machine with another agent's T-032 Release build.
7. `CGRect` equality is not a float-safe assertion, and `CGRect.contains` is half-open on `maxX`/`maxY` —
   both bit the TG-07 render suite rather than this one, but the placement-based fixtures here use the
   same geometry helpers, so the same care applies.
8. The simulator must be pinned (`id=990E1710-4805-46E2-8FED-BD1DE12D1BE8`); `xcodebuild` boots it, and
   `-derivedDataPath` must be private to this task (`build/TG08bDerivedData`) — a shared derived data
   directory across concurrent agents is its own source of confusion.
9. **`xccov`'s per-line report does not always itemise the uncovered line it counts.** The speech file's
   summary says 112/113 while no zero-count line appears in the per-line view; the discrepancy is reported
   above rather than smoothed over.

## Open items (reported, not silently closed)

1. **The re-prompt sentence still has no catalog key** (T-023 notes, item 1). T-025 delivers
   `Outcome.reprompt` to its caller — that is the *fact* of the re-prompt, exactly once, per T-023's turn
   rule — but it speaks nothing, so C12's "the elder is re-prompted once" is not yet audible until T-026
   wires the outcome to copy. Adding the key means updating `LiveTranslateCopyTests`' pin and going through
   the OD3 copy review; that is a deliberate copy decision, not something this task could take silently.
2. **Per-command evidence events are still not emitted** (T-023 notes, item 3). The capture deliberately
   holds no bus so a transcript has no event to travel in; the cost is that a matched or unmatched command
   leaves no trace. If `security-test` (T-029) wants that evidence it needs a declared
   `LiveTranslateEventCatalogue` entry, its `LogSanitiser.allowedKeys` entry and a design-table row — and
   the utterance can never be the payload.
3. **`SpokenOutput` remains undefined in `specs/design-component.md`** (CL-8's finding; T-023's decision
   2). This task did **not** invent it: C12 speaks through the shipped `Announcement` → `SpeakQueue` path,
   and `LiveTranslateSpeechPath` is that queue narrowed to the three operations C12 uses. Resolving the
   design text is a design-owner action; this task's constraints forbid editing the design.
4. **A spoken "stop" during a reading is unreachable under the design's own pause-during-speech rule.**
   The microphone pauses while the feature is speaking (this task's guard, correctly), so a `stopSpeaking`
   utterance is only heard after the reading has finished or at a gap in it — exactly when it is least
   useful. The touch affordance (T-021's control) is the reliable stop today. If the owner wants a spoken
   stop to interrupt a reading, that is a design decision about acoustic echo or barge-in, not something to
   decide here; `LiveTranslateSpeech.stop()` is the seam either way.
5. **`repeatLast`'s scope is the last *speaking request*.** After a tap-to-hear, "say that again" repeats
   that region, not the last read-all. That is what CL-8's wording ("the last spoken item") supports and
   it is asserted; if the owner means something else by "again", the seam is `remember(_:)`.
6. **The capture's window timings are the shipped capture's** (`SearchPhraseCapture`), so the elder's
   command window behaves exactly like the plugin's existing phrase capture. If C12 or T-030's device pass
   wants a different window for in-session commands, that is a config decision in the shipped type rather
   than a new value here.
7. **Nothing in the app constructs either type yet.** `LiveTranslateSpeech` and
   `LiveTranslateCommandCapture` are built and tested, but the session that owns them, presents the
   overlay and routes the parser's commands to them is T-026's; until it lands, the microphone gate
   (`isFeatureSpeaking:`) is the seam T-026 must connect to `LiveTranslateSpeech.isSpeaking`.
8. **No UI-test coverage.** `ElderlyAssistantUITests` is skipped in every gate above and was not extended:
   the tap-to-hear gesture and the VoiceOver-level checks live there, and this task's level is the unit and
   integration boundary.

## Out of scope (adjacent capabilities, for the reader's map)

- **Session assembly and the plugin wiring** (T-026): building the speech and capture instances with the
  session, connecting `isFeatureSpeaking`, presenting the overlay, and speaking the re-prompt copy.
- **The parser itself** (T-023): vocabulary, near-miss rule, the one re-prompt, the settings writer.
- **Placement and rendering** (T-020/T-021): the geometry, the `Form`, `speaksTranslation`, the states.
- **`security-test` / `final-sign-off`** (T-029/T-030): the manual device validation, including the
  acoustic behaviour of a real room for the self-speech guards this task makes structural.
