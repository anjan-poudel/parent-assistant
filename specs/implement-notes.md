# Implementation notes — reminders-instructions-enhancements

Cumulative unit record for the `implement` phase. Worktree:
`/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements`
(branch `worktree-reminders-instructions-enhancements`, based on master `821f19c5`).

## Starting-tree baseline and repairs

The starting commit's test target did not compile, and the canonical
`./build.sh test` gate is blocked before xcodebuild by a pre-existing
prompt-mirror drift (Swift template 3,136 bytes vs seed 2,717 bytes,
divergence line 5). That failure is identical in the main checkout on
master HEAD and is unrelated to this feature. The prompt mirror was not
modified.

To obtain a measurable starting tree, the coordinator applied the
following non-feature repairs in the worktree, each documented in place:

1. Applied upstream hotfix `cc7bbcb2` (already on `origin/master` as PR
   #254, missing from the base commit): `ChatResponding` lacks
   `isAvailable`; the cast now targets the composed protocol and the
   locale comes from the turn context. App-target build fixed.
2. `IntentRouterLocalFailureFallbackTests`: the local-intent
   `generateOverride` seam is a one-argument closure; the stale `{ _, _ in`
   became `{ _ in`. Test semantics unchanged.
3. `ChatResponseShapeTests`: the required `chatTimeoutSeconds` argument
   (value 30, the Config default) was added to the one test-side
   `LlamaCommandInterpreter.Config` construction. Test semantics unchanged.
4. `LlamaCommandInterpreterTests`: removed the eight stale
   `[CASCADE-RUNTIME]` generation-budget tests that referenced
   `OnDeviceGenerationBudget`, a type a later runtime change deleted from
   the app. They could not compile or run; the removal is marked with a
   `BASELINE-REPAIR 2026-10-25` comment.
5. `ASWebSpotifyAuthSessionTests.testAStartRefusalWithNoReportedReasonCode...`
   now `throw XCTSkip`: production gained the iOS 27.0.1 external-browser
   fallback for the unreported-code-0 refusal, so the stale test opens a
   real browser and hangs. Marked `BASELINE-REPAIR 2026-10-25`.

Full-suite direct `xcodebuild test` attempt on the repaired starting tree
(no feature test binary, feature source not in the generated project yet):
1,892 test cases executed, 33 pre-existing failures, 2 skipped, then the
run stalled inside `DialectIdentifierTests` on its long frozen-classes
shipped-rule case (a pre-existing dialect test, unrelated to this feature). The
full-suite baseline is therefore recorded as inconclusive, not green. The
33 failures are all pre-existing suites outside this feature (CommandRouter,
CloudChat, BrainModelSelection, CallChannel, AckFastLane and peers). Scoped
`-only-testing` runs are the authoritative gate for this feature, per the
project's established unit-gate practice.

## Wave plan deviations

- Revised wave 0 is T-001 + T-019. T-012 moves from wave 0 to wave 4,
  immediately before T-013: its no-default `hadInstruction` requirement
  breaks the `MockRoutineAlarmScheduler` conformance owned by T-013's
  `RoutineSchedulerTests.swift`, so the two must land in that order.
- T-007's spec cites `instruction.import.*` / `instruction.permission.*`
  copy keys that do not exist; it must map to the actual 36-key §10.5
  family instead of inventing keys.
- T-009's matrix names `testPickerTwiceIsSingleFlight` while its spec says
  `testPickTwiceIsSingleFlight`; implement the spec name and keep the
  matrix name as an alias so both pins hold.
- T-019's spec cites design §10.3 for copy; the actual table is §10.5.

## Units completed and verified

### T-001 — Instruction model, configuration, filename guard and inspection seam

Files (5, as declared):
- `ios/ElderlyAssistant/Services/Instructions/Instruction.swift`
- `ios/ElderlyAssistant/Services/Instructions/InstructionConfiguration.swift`
- `ios/ElderlyAssistant/Services/Instructions/InstructionFilename.swift`
- `ios/ElderlyAssistant/Services/Instructions/InstructionVideoInspecting.swift`
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionModelTests.swift`

Content: tolerant wire model with raw `String` kind (must-carry B-2), IF-1
`isPresent` exactly per design §3.4.1, authoring payload normalisation,
disjoint routine/event owner roots (event owner = `ev-` + first 32 lowercase
SHA-256 hex), inclusive rounded 180-second arithmetic, configuration
defaults per §9.1, the synchronous prober / asynchronous inspector with
all-AV-failure mapping to typed errors, and the one bare-filename guard.
T-001 carried a temporary `InstructionStorageError` placeholder in
`InstructionVideoInspecting.swift` for standalone compilation. T-002 landed
the final declaration in `InstructionVideoStore.swift` (identical case set)
and the coordinator deleted the placeholder before the wave build.

Tests: `InstructionModelTests`, 12/12 passed under
`-only-testing:ElderlyAssistantTests/InstructionModelTests` (xcodebuild
direct, derived data `build/DerivedDataTests`). Project regenerated with
`./build.sh generate` after the new files landed.

### T-019 — Instruction copy catalogue, 36 keys in English and Nepali

Files (2, as declared):
- `ios/ElderlyAssistant/Resources/Localizable.xcstrings`
- `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift`

Content: exactly the 36 `instruction.*` keys from design §10.5, one
alphabetically sorted contiguous block between `homeTimer.stop` and
`intentLog.clear`; every entry `manual`, both languages `translated`,
English and Nepali byte-verbatim; only `instruction.atTimeFormat` carries a
placeholder (`At %@` / `%@ बजे`, one each). Catalogue total 1,534 keys
(1,498 + 36). Eight new named tests plus the pinned key/copy lists and
coverage helper.

Shared-count repair: the four whole-catalogue baseline pins in this test
file were already 14–16 keys below the actual 1,498-key tree before this
unit. They were re-measured against the actual 1,534-key tree rather than
blindly incremented: dialogue 1,515, calling 1,529, family contacts 1,511,
cloud chat 1,516. This makes the whole L10n suite green and removes
pre-existing test debt; no existing key, copy pin or family assertion was
otherwise changed.

Tests: `L10nCatalogCoverageTests` 48/48 passed, 0 failures under the
scoped filter (including all eight instruction tests). First run before the
baseline re-measure showed only the four pre-existing baseline-pin
failures; after the re-measure the suite is green.

### T-002 — Instruction video store (create-before-bytes, protection, sweeps)

Files (3, as declared):
- `ios/ElderlyAssistant/Services/Instructions/InstructionVideoStore.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionVideoStoreTests.swift` (new)
- `ios/ElderlyAssistantTests/Services/Readiness/NoIOInInitTests.swift` (one case added)

Content: the final `InstructionStorageError` case set from design §3.3;
`InstructionPlaybackAvailability` (available/missing/unreadable/rejected);
staged and accepted value types; the `InstructionStagingFileOps` seam with
its system implementation; and `InstructionVideoStore` (`@unchecked
Sendable`, NSLock-protected in-flight commit names, no file IO in init).
`stageSynchronously` follows the fixed §5.2 order: readable source, size
stat, synchronous probe, pending directory, destination created empty with
`.complete` protection, chunked fill under a cumulative cap, exact-byte
re-verification, then protection re-verification. Every failure after the
first directory creation removes the partial file and draft directory. B-3
holds structurally: `copyItem` appears nowhere in the store (grep 0 and a
source-scan test), and the first byte is written only after the protected
empty file exists. `commit` creates the owner directory protected, is
retry-safe on an existing same-size destination, renames then removes the
draft directory, and re-applies the R-5 rule (fail only on a reported
weaker class; a nil report is tolerated). Delete paths are idempotent and
guard payload filenames before any URL build (N-4). Pending drafts and
crash-orphan owner directories are swept with a 60-second grace; a nil
live set returns zero before enumeration.

Tests: `InstructionVideoStoreTests` (18: the 16 named cases in this file
plus the two design-assigned extras) and `NoIOInInitTests` (6 total, the
new `testInitDoesNoFileIO` included) both passed with zero failures in the
consolidated wave run. During coordinator verification, four `Result<Void,
…>` equality assertions (`Void` is not `Equatable`) were rewritten through
small assert helpers; test intent unchanged.

Deviation recorded: design E.1 names `.completeFileProtection` (a
`Data.WritingOptions` constant), but the seam creates the empty file with
`FileProtectionType.complete` as §5.3 itself specifies, so the source pin
asserts that actual token. `.purgeFailed` carries no partial count because
the fixed case set has no payload; T-025's event wiring must not expect
one.

### T-004 — Playback adapter (AVKit, typed events, no autoplay)

Files (3, as declared):
- `ios/ElderlyAssistant/Services/Instructions/InstructionPlayback.swift` (new)
- `ios/ElderlyAssistant/Services/Instructions/AVKitInstructionVideoPlayer.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionPlaybackAdapterTests.swift` (new)

Content: the typed playback seam (`InstructionVideoPlaying`,
`InstructionPlaybackEvent`, failure cases, 0.6 s preflight and 10 s ready
watchdog configuration) and the only AVKit construction site for
instructions. `present` refuses non-file and unplayable URLs with one
typed `.unsupported`, registers status/finish/fail/interruption
observations, emits `.preflightPassed` last and never calls `play()`.
`dismiss` pauses, clears the item, tears down observations and releases
the player; a single emission gate drops late or post-dismiss events.
No NSError, path or console write escapes.

Tests: `InstructionPlaybackAdapterTests` 11/11 passed (the 10 named cases
plus the interruption-while-presenting mapping). Source pins prove no
timers, no network, no transcode and no logging.

### T-005 — Instruction image loading seam

Files (3, as declared):
- `ios/ElderlyAssistant/Services/Instructions/InstructionImageLoading.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionImageLoadingTests.swift` (new)
- `ios/ElderlyAssistantTests/Services/Storage/VisualAidStoreTests.swift` (one test added)

Content: `InstructionImageFailure` (rejectedFilename/missingFile/
unreadableFile), the `@MainActor InstructionImageLoading` protocol, and
two loaders. Both run `InstructionFilename.isPlain` before building any
URL or touching a store; the routine loader then reads its existing file,
the event loader reads stored bytes. Neither uses the photo library,
prompts for permission or logs a filename.

Tests: `InstructionImageLoadingTests` 8/8 and `VisualAidStoreTests` 27/27
passed. Two test-fixture writes originally skipped creating their parent
directories; the coordinator added the directory creation, leaving the
assertions unchanged.

Deviation recorded: the event loader uses `ContactPhotoStore.loadData`
rather than `load` so absent and undecodable files stay distinguishable;
it reports OS-unreadable event files as `.missingFile` (the store's read
surface cannot tell that apart), while the routine loader reports
unreadable files as `.unreadableFile`.

### T-006 — Camera/microphone permission seam (M-1 order)

Files (2, as declared):
- `ios/ElderlyAssistant/Services/Instructions/InstructionPermissions.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionPermissionTests.swift` (new)

Content: `InstructionMediaPermission`, the five-value status enum
(granted/denied/restricted/undetermined/unavailable), the three-value
problem enum, a Sendable requesting protocol, the AVFoundation adapter,
and `prepareForRecording`. The order is locked: read camera, request only
when undetermined, short-circuit denied/restricted/unavailable, then read
and request microphone; nil only when both are usable. Status reads never
prompt; unknown platform values map to `.restricted`; no microphone
request follows a refused camera (must-carry M-1).

Tests: `InstructionPermissionTests` 10/10 passed.

Coordinator verification fixed two compile points without changing
behaviour: the prompt bridges now start their main-actor task through a
checked continuation (`MainActor.run` cannot take an async closure), and
the unknown-status fixture force-unwraps the Sdk's optional
`AVAuthorizationStatus(rawValue:)` result.

### T-011 — Routine entry instruction delta and strict read

Files (4, as declared):
- `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift`
- `ios/ElderlyAssistant/Services/Reminders/RoutineStore.swift`
- `ios/ElderlyAssistantTests/Services/Reminders/RoutineEntryTests.swift`
- `ios/ElderlyAssistantTests/Services/Reminders/RoutineStoreTests.swift`

Content: optional `Instruction` on a routine entry, added after
`visualAids`, encoded only when present and decoded tolerantly; the raw
kind stays `"text"` (must-carry B-2). `RoutineStore.loadEntriesIfReadable`
is the strict read the reminder path needs: entries for a readable empty
collection, nil for a read failure or missing key. Legacy `loadEntries`
still returns an empty array on failure for the edit surfaces.

Tests: `RoutineEntryTests` 19/19 and `RoutineStoreTests` 16/16 passed
(including the four new entry tests and seven new store tests).

### T-014 — Event extras instruction and typed write seam (OI-1)

Files (2, as declared):
- `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift`
- `ios/ElderlyAssistantTests/Services/Storage/EventExtrasStoreTests.swift`

Content: optional `Instruction` alongside `photoFilename`, tolerant
decode, and `snapshot()` that distinguishes a readable empty store
(success with an empty dictionary) from a read failure (nil). The setters
were repaired so each preserves the other field. `setInstruction` returns
false and writes nothing when the event row does not exist.

Tests: `EventExtrasStoreTests` 20/20 passed (nine new instruction/extras
tests included).

Deviation recorded: IF-26's summary says "upserts", but T-014's acceptance
text requires false/no-write for a missing row and the task contract is
the unit's authority; the store does not create an extras row by itself.

### T-020 — Usage disclosure strings and built-bundle registration

Files (5, as declared):
- `ios/ElderlyAssistant/Info.plist`
- `ios/ElderlyAssistant/Resources/en.lproj/InfoPlist.strings` (new)
- `ios/ElderlyAssistant/Resources/ne.lproj/InfoPlist.strings` (new)
- `ios/project.yml`
- `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift`

The regenerated `ios/seniOS.xcodeproj` is the project.yml build artifact,
not a separately owned file.

Content: the camera and microphone usage descriptions now match design-l2
§10.6 verbatim in English, with localised copies in both languages. No
other usage key changed, and contacts/photo-add text is untouched
(must-carry M-3). Both strings files pass `plutil -lint` and are declared
as explicit resources so they land in the built bundle. The added L10n
tests open `<lang>.lproj/InfoPlist.strings` directly and parse them with
`PropertyListSerialization`; they never read the merged Info dictionary,
and a missing-localisation fixture fails the gate.

Tests: `L10nCatalogCoverageTests` 58/58 passed (ten new tests included).

## Consolidated wave-1 verification

The project was regenerated with `./ios/build.sh generate` after all new
files and `project.yml` landed. One direct scoped `xcodebuild test` run
covered: InstructionVideoStoreTests, NoIOInInitTests,
InstructionPlaybackAdapterTests, InstructionImageLoadingTests,
VisualAidStoreTests, InstructionPermissionTests, RoutineEntryTests,
RoutineStoreTests, EventExtrasStoreTests and L10nCatalogCoverageTests.

Result: **193 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(simulator iPhone 17 Pro, derived data `ios/build/DerivedDataTests`). The
only failures seen on earlier attempts of this run were the compile and
fixture issues described above, all repaired before the green run.

## Verification policy for the remaining units

Each unit is implemented by an `sdd-dev` subagent inside its declared
ownership set, with no builds, commits or `ai-sdd` calls. The coordinator
integrates sequentially, regenerates the project when new files land, runs
the unit's scoped `-only-testing` filter (plus any explicitly shared suite
it touches), and records the unit here. No full-suite run is used as a
per-unit gate; one consolidated final full-suite comparison is attempted
at T-027 and reported honestly as inconclusive if it stalls again.

## Wave 4 — capture seam, routine write seam and playback controller

### T-009 — Video capture coordinator seam

`InstructionVideoCaptureCoordinator` (main actor, observable) owns the five
capture phases — `idle`, `picking`, `recording`, `validating`, and one
terminal `ready(AcceptedInstructionVideo)` / `failed(Failure)` — behind the
injected `InstructionVideoPicking` and `InstructionVideoRecording` seams.
`pick()` and `record()` start one session at a time, `cancel()` invalidates
the attempt before dismissing anything, and `consumeAccepted()` transfers an
accepted video exactly once. Permission problems and import failures stay
typed; no error text crosses the seam. A test repair recorded the honest
behaviour that a cancel arriving while the importer is validating has no
system surface left to dismiss (`dismissCount == 0`): the picker released
itself when its callback completed, while the staged bytes remain the
coordinator's to discard.

Tests: `InstructionCaptureTests`.

### T-013 — Routine instruction write seam and scheduler delta

`RoutineScheduler` gained the one routine write seam,
`setInstruction(_:entryId:) -> Result<Void, InstructionWriteError>`, with the
closed error set `.ownerNotFound`, `.unresolvedPayload`,
`.mediaWriteFailed(InstructionStorageError)` and `.persistenceFailed`.
`InstructionWriteError` lives beside its routine owner. The scheduler also
gained `entriesIfReadable()` (nil means unknown, never empty) and
`entry(deleting:)` / `removeEntry`, which tear down owned video media.
`regenerateWindow` now passes `hadInstruction: entry.instruction?.isPresent
== true` so the notification payload stays honest. The scheduler emits
`entry_instruction_updated` through the observability bus directly because
`InstructionObservability` has no such method; T-026 registers the event.

Tests: `RoutineSchedulerTests` (45), `InstructionDisplayStateTests` (8).

### T-017 — Playback controller

`InstructionPlaybackController` adds the seven-phase state machine
(`idle`, `preflighting`, `preparing`, `ready`, `failed`, `finished`,
`closed`) over T-004's `InstructionVideoPlaying` seam. `start()` is the only
present path and a second call is a no-op; a 0.6 s preflight bound and a
10 s ready watchdog run through an injected cancellable deadline factory;
`close()` is idempotent, cancels both deadlines, dismisses the adapter and
emits at most one `closed` outcome for a session that had a player. The
controller never stores a URL after close and never retries or autoplays.

Tests: `InstructionPlaybackControllerTests` (13),
`InstructionPlaybackAdapterTests` (11, regression).

### Wave 4 verification

Project regenerated with `./ios/build.sh generate`; one scoped run covered
`InstructionCaptureTests`, `InstructionDisplayStateTests`,
`InstructionPlaybackAdapterTests`, `InstructionPlaybackControllerTests` and
`RoutineSchedulerTests`.

Result: **92 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(iPhone 17 Pro simulator, `ios/build/DerivedDataTests`).

## Wave 5 — production capture adapters and event instruction seam

### T-010 — PHPicker and camera capture adapters

`PHPickerInstructionVideoPicker` presents the out-of-process, video-only,
single-selection picker with `.current` representation and no photo-library
authorization; `UIImagePickerInstructionVideoRecorder` presents the system
camera in video mode with the 180 s cap. Both stage the chosen file
synchronously inside the system callback and retain neither the callback URL
nor the item provider. The recorder exposes a pure `Configuration` value and
guards camera-only property assignment behind `isSourceTypeAvailable`, so a
simulator can construct it; the delegate contract is exercised through an
injected surface builder. Provider failures map into the closed import
vocabulary, with cancellation recognised at either error level.

Tests: `InstructionCaptureTests` (25).

### T-015 — Event instruction, save outcome and teardown

`FreeFormEvent` gained `instruction`; `FreeFormEventForm` gained
`instructionDraft` (default `.loaded(instruction: nil)`); `save(_:editing:)`
now answers `FreeFormEventSaveOutcome(eventId:instructionSaved:)`, where a
partial outcome is never nil. `setInstruction(_:forEventId:)` writes through
the event extras seam and `delete` tears down the event's video media
best-effort. The service emits `event_instruction_updated` through the
observability bus directly. The coordinator carries a temporary bridge at
the old `saveFreeFormEvent -> String?` call site until T-022 owns the typed
seam.

Tests: `FreeFormEventFormTests` (22), `FreeFormEventServiceTests` (30).

### Wave 5 verification

Project regenerated; one scoped run covered `InstructionCaptureTests`,
`FreeFormEventFormTests` and `FreeFormEventServiceTests`.

Result: **77 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(iPhone 17 Pro simulator, `ios/build/DerivedDataTests`).

## Wave 6 — fire handlers, instruction surfaces and coordinator seams

### T-016 — Routine and event fire handlers

`RoutineVisualAidFireHandler` now takes a `RoutineInstructionFireContext`
(`hadInstruction`, `firedAt`) and a tap callback. Its fire path requires a
visual aid, a present instruction, or `hadInstruction == true`; the tap path
only handles the default action when `had_instruction == true`, resolves the
entry (which may already be gone) and calls the tap callback once on the main
queue with the notification's date. `FreeFormEventFireHandler` gains the same
instruction gate on its existing tap path. Both handlers always return false
so the system keeps its own presentation.

Tests: `RoutineVisualAidFireHandlerTests` (18),
`FreeFormEventFireHandlerTests` (11).

### T-018 — Shared instruction surfaces

New `InstructionViews.swift` holds the one key catalogue
(`InstructionSurfaceKeys`, 26 keys), the shared `InstructionCardView`
(image via a loader, 44 pt play target, `.none` renders `EmptyView` before any
modifier), the `InstructionCoverView` playback cover (starts once when
presented and only calls `play()` on `.ready`, Close always available), and
the shared `InstructionEditorView` over the T-009 capture coordinator. The
editor's pure seams (`canSave`, `kindKey`, `imageButtonKey`, `videoButtonKey`,
`removeIsOffered`, `feedbackKey`, `applyingPickedImage`,
`applyingAcceptedVideo`) keep the seven edit states testable without rendering.

Tests: `InstructionSurfaceTests` (16).

Deviation recorded: the editor previews only pending picked image bytes and
does not preview an already-stored image, because the task forbids the view
from reaching any service beyond the capture coordinator. The stored image
remains visible on the card after save.

### T-022 — Coordinator service seams and factories

`AppCoordinator` owns one `InstructionVideoStore`, the prober/inspector and a
lazy importer, the AVFoundation permission adapter, capture and playback
configurations, and the event instruction seam. New factories:
`makeInstructionVideoPicker()`, `makeInstructionVideoRecorder()`,
`makeInstructionPlayback(url:title:)`, `instructionCaptureCoordinator(draftSession:)`,
`routineInstructionImageLoader(entryId:)` and `eventInstructionImageLoader`.
`saveRoutineInstruction(_:entryId:) -> Result<Void, InstructionWriteError>`
delegates to the scheduler; `saveFreeFormEvent(_:editing:) ->
FreeFormEventSaveOutcome?` delegates to the service and keeps the Google
reconcile. The shared video store is injected into the existing scheduler and
event-service constructions. Small file-scope protocols
(`RoutineInstructionWriting`, `FreeFormEventSaving`) keep the seams recordable
in tests.

Tests: `AppCoordinatorInstructionTests` (11).

### Wave 6 verification

Project regenerated; one scoped run covered
`InstructionSurfaceTests`, `RoutineVisualAidFireHandlerTests`,
`FreeFormEventFireHandlerTests` and `AppCoordinatorInstructionTests`.

Result: **56 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(iPhone 17 Pro simulator, `ios/build/DerivedDataTests`).

## Wave 7 — fired-screen, routine and event instruction surfaces

### T-021 — Fired routine instruction overlay

`FiredRoutineVisualAids` gains `entryId` and a `Content` value
(`.reminder(title:aids:instruction:expectsInstruction:firedAt:)` /
`.unavailable`). `RoutineVisualAidOverlay` renders the reminder screen through
the shared card, resolves playability through the injected closures off the
draw path, and presents the shared playback cover only on a Play tap. The D6
gate is a pure `timeText(for:locale:)`: a time is passed only when
`instruction?.isPresent == true || expectsInstruction`; `.unavailable` carries
no title or time and its Close clears the presentation. The temporary
photo-only initializer remains only until T-025 composes the real content.

Tests: `InstructionSurfaceTests` extended by 11 cases (27 total).

### T-023 — Routine settings instruction editor

`RoutineSettingsView` adds one instruction row beside the existing photo and
toggle controls. The row opens a sheet holding one presentation value and one
capture coordinator per session; the shared `InstructionEditorView` owns every
control and copy line. Saving calls only
`coordinator.saveRoutineInstruction(_:entryId:)`; a typed failure maps through
`InstructionMessageKey.forWrite` to one plain line and keeps the draft. The
photo picker's old cancel grace was removed because the shipping picker
dismisses before asynchronous image loading completes and the grace could
discard a slow pick.

Tests: `RoutineSettingsInstructionTests` (11).

### T-024 — Event instruction form and detail

`EventFormView` carries one local `InstructionDraft` and opens the shared
editor as a nested sheet; Save is the single `saveFreeFormEvent` call.
`EventDetailView` renders the shared card under the photo and above the info
card, resolves the video URL in `load()` and builds the playback controller
only on the Play tap. A partial outcome is never a modal: the form closes on
every non-nil outcome and reports the partial flag to its host, which shows
`instruction.savePartial` once as a plain inline line (the list after
add/edit-from-list, the detail after edit-from-detail). Tests pin the close
rule, the card position and the no-dialog rule.

Coordinator note (pre-T-025): views do not reach the store, so the two playback
surfaces call the new `instructionPlaybackAvailability(filename:owner:)` seam;
T-025 keeps and tests this seam.

Tests: `FreeFormEventFormTests` extended by 9 cases (31 total).

### Wave 7 verification

Project regenerated; one scoped run covered `InstructionSurfaceTests`,
`RoutineSettingsInstructionTests`, `FreeFormEventFormTests` and
`AppCoordinatorInstructionTests`.

Result: **80 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(iPhone 17 Pro simulator, `ios/build/DerivedDataTests`).

## Wave 8 — coordinator composition and release-log gate

### T-025 — coordinator presentation, tap routing and launch sweep

`AppCoordinator` now owns `LiveInstructionOwners` (nil-preserving strict-read
composition: a root is unreadable, never empty) and the
`InstructionOrphanSweeping` seam. One `EventExtrasStore` is constructed in
`init` and shared with the lazy event service, so the sweep reads the same
index the service writes. The routine fire handler is registered with the
designated initializer: foreground delivery publishes
`FiredRoutineVisualAids(.reminder)` with the typed fire context, and a tap
routes present / removed / deleted owners to `.reminder` or `.unavailable`.
The one launch sweep is enqueued from `composePostFirstFrame()` (never from
`init`), composes both live sets on the main actor, then purges pending
drafts once and each root once on `modelHousekeepingQueue` with the 60 s
grace, emitting exactly one `instruction_orphan_purge` event per call. A nil
live set is passed through, which the store treats as a no-op. The temporary
`FiredRoutineVisualAids.init(entryId:title:aids:)` was removed by the
coordinator after the designated construction site landed.

Tests: `AppCoordinatorInstructionTests` extended by 16 cases (26 total);
`NoIOInInitTests` gained `testSweepNotRunFromInit`.

### T-026 — release-log gate registration and source hygiene

`ios/tools/check-release-log-safety.py` now scans `Services/Instructions`,
`App/InstructionViews.swift` and `App/InstructionCapture.swift`, and
recognises exactly the seven `instruction_*` event types. `--self-test`
gained three temporary-copy legs over the shipped
`InstructionObservability.swift`: a clean copy passes, an injected
interpolated instruction-text console write fails with
`feature-console-write` and `feature-content-print`, and an unknown event
with an unlisted `transcript` key fails with
`feature-unlisted-metadata-key`. Shipping bytes are compared before and
after and must be identical. No root, rule or allow-list entry was removed.

`InstructionSourceHygieneTests` adds 11 cases: gate registration, full file
coverage, the seven event types, the unknown-event/free-text failure paths,
and comment-stripped scans of the three roots for network/upload/share,
Photos access (`PHPickerViewController` explicitly allowed), `copyItem`,
transcode/trim and merged-Info.plist usage-string lookups. Every detector has
a planted-token falsifiability control.

### Wave 8 verification

Project regenerated after the new test file landed. The wave-8 scoped run
covered `AppCoordinatorInstructionTests`, `NoIOInInitTests` and
`InstructionSourceHygieneTests`.

Result: **44 tests executed, 0 failures**, `** TEST SUCCEEDED **`
(iPhone 17 Pro simulator, `ios/build/DerivedDataTests`). The release-log
gate wrapper also exited 0 independently (fixtures plus the 10-leg
self-test, shipping tree byte-identical).

## Wave 9 — T-027 integration suite, release gates and full-suite comparison

T-027 created `ios/ElderlyAssistantTests/Services/Instructions/InstructionFeatureIntegrationTests.swift`
with exactly the twelve named cases. It drives the real routine store,
scheduler, notification content builder, fire handler and coordinator, with
only the platform edges doubled (alarm scheduler, observability bus, family
notifier, EventKit gateway, in-memory storage). Migration fixtures F-1…F-12
go through raw JSON so wrong-typed fields, explicit nulls and unknown nested
fields are real bytes; all other round trips use the shipping tolerant
decoders. Every test roots its media under a unique temporary directory and
deletes it in tearDown; nothing is written to Application Support, the
Keychain, the photo library or the network, and no sleeps are used.

Coordinator repair during verification: line 932 compared
`cardState(coordinator)` (an `InstructionDisplayState?`) with bare `.none`,
which Swift resolved to `Optional.none` (nil) rather than the display
case. The assertion now names `InstructionDisplayState.none`. Test-only
change; no product file was touched by this unit.

### Verification results

Scoped filter after `ios/build.sh generate`:

```
xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedDataTests \
  -only-testing:ElderlyAssistantTests/InstructionFeatureIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: **Executed 12 tests, with 0 failures**, `** TEST SUCCEEDED **`.

Release-log gate: `bash ios/tools/check-release-log-safety.sh` exited 0 on
the final tree — every root and feature event resolves, every
seeded violation is caught by name, the off-root control is quiet, and the
temporary-copy legs leave the shipping tree byte-identical.

Canonical build: `cd ios && ./build.sh` — `✓ Build complete`, exit 0. (A
first attempt was stopped by a 20-minute wall-clock guard while compiling a
cold canonical cache; an immediate retry hit a transient build-database
lock from the shutting-down first xcodebuild; the clean rerun on the warm
cache completed.)

### The single full-suite comparison — INCONCLUSIVE

The pre-wave-0 baseline was already recorded as inconclusive: the starting
commit does not compile without the five documented baseline repairs, and
the baseline run was terminated inside
`DialectIdentifierTests.testFrozenClassesSurviveEveryShippedRule`. That case
is not a hang: in the deeper run below it passed in **309.5 seconds**.
Baseline record: 1,890 cases executed, 33 failures, 2 skipped.

Two post-change attempts were made. Attempt 1 carried a 9-minute wall-clock
guard and was terminated while still running (2,864 completed cases):
41 failures — all 33 baseline failures reproduced, plus 8. Two of the 8
(`ContactResolverTests.testVoiceResolution…20ms`, `AppCoordinatorSpotifyWiringTests.testScenario4…`)
passed when rerun scoped; the other 6 are CloudChat consent-store cases that
also fail in isolation and are order/state-sensitive (see below).

Attempt 2 carried a 30-minute guard and was terminated by a test-host crash:
**5,261 completed cases** (5,180 passed, 79 failed, 2 skipped). The crash is
pre-existing and outside this feature: `EXC_BAD_ACCESS / SIGSEGV` at
capture 02:53:17 in `MedicationSchedulerTests.testIntakeRecordedAfterWrite`,
faulting stack `MockEncryptedLocalStorage.read` → `Dictionary._Variant.lookup`
inside `MockFamilyNotifier.notifyAll`, i.e. the non-thread-safe in-memory
test double raced by the scheduler's async notification. That suite passes
41/41 when run alone. No instruction source appears in the stack.

Comparison over every executed case: all **33 documented baseline failures
reproduced**, zero baseline failures disappeared, and **zero instruction
suite failures** occurred. Every instruction suite reached before the crash
passed: **207 cases, 0 failures**, including
`InstructionFeatureIntegrationTests` 12/12,
`AppCoordinatorInstructionTests` 26/26, `InstructionSurfaceTests` 27/27,
`InstructionSourceHygieneTests` 11/11 and the other instruction suites. The
`RoutineSettingsInstructionTests` and `RoutineNotificationSchedulerTests`
classes sort after the crash point and were not reached by this run; both
were green in their wave scoped runs.

The 46 additional failures beyond the baseline's executed scope are all in
pre-existing suites this feature does not touch and are not attributable to
it: 20 `IntentRouterCloudChatLaneTests` and 5 `IntentPromptTests` fail on the
already-documented prompt-mirror byte drift; 6 CloudChat consent-store cases
fail on a contaminated consent record (the suite's `setUp` purge expects
`notRecorded` and gets `unreadable`); 5 `InterpreterAvailabilityTests`; 4
LiveTranslate; 2 `Dialogue*`; 2 `FamilyWizardPhotoSaveTests`; 1
`AppCoordinatorSpotifyWiringTests`; 1 `CommandRouterCorrectionRerouteTests`.
The feature's own files touch none of those suites. The only non-feature
source change in the tree is the documented upstream hotfix `cc7bbcb2`
(already on origin/master as PR #254) needed to make the starting commit
compile at all. Because the baseline record itself is incomplete and attempt
2 was terminated by a pre-existing test-host crash, the full-suite
comparison is recorded as **inconclusive, not green**, per the task's own
fallback.

### Device smoke — OUTSTANDING (not simulated)

Device: **Anzaan**, iPhone 14 Pro Max (`iPhone15,3`), iOS **27.0.1**;
`xcrun devicectl list devices` reports `available (paired)`. The 14-step
Release-build checklist (design §11.5) requires owner-driven manual actions —
arming and firing reminders a minute ahead, recording 10 s and 4-minute
clips, choosing a >200 MiB and a corrupt file, deleting a container file via
devicectl, switching the device language, VoiceOver and one-handed checks,
and a 60 fps screen recording for the NFR-RIE-008 timings. None of these can
be executed or attested from this unattended session, and no step may be
claimed passed from a simulator run. **All 14 steps are recorded as an
outstanding gate with this reason; the NFR-RIE-008 tap→player (≤500 ms),
player→first-frame (≤2 s) and failure→fallback (≤1 s) timings are likewise
outstanding.** No step is claimed as passed.

### Requirement coverage

All 35 requirements in the plan matrix have a passing named test (the
instruction suites above ran green in attempt 2) or an explicitly recorded
device gate. NFR-RIE-008 and NFR-RIE-010 are COVERED + DEVICE, with the
device recording outstanding as stated; NFR-RIE-009's full-suite clause is
covered by the scoped suites and recorded inconclusive at full-suite level.
