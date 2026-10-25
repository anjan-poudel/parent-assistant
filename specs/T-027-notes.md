# T-027 — Instruction feature integration suite

Status: test file implemented in the feature worktree
(`/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements`,
branch `worktree-reminders-instructions-enhancements`, base master `821f19c5`).

This unit created exactly one product-tree file and this notes file. The
scoped XCTest filter, the single full-suite run, the release-log gate, the
canonical build and the 14-step device smoke are the coordinator's steps and
were NOT run by this agent. No test is claimed to pass; the only command
evidence below is `xcrun swiftc -parse` (exit 0) plus read-only source scans.

## What was built

`ios/ElderlyAssistantTests/Services/Instructions/InstructionFeatureIntegrationTests.swift`
(new, 1,982 lines) containing exactly the twelve named cases, in the order the
task lists them:

1. `testRoutineInstructionEndToEndText`
2. `testRoutineInstructionEndToEndImage`
3. `testRoutineInstructionEndToEndVideo`
4. `testReminderFiresWithoutInstruction`
5. `testNotificationPayloadCarriesNoInstructionContent`
6. `testTapPresentRemovedDeletedMatrix`
7. `testMigrationFixturesF1ThroughF12`
8. `testMedicationFixturesUnchanged`
9. `testVisualAidFixturesUnchanged`
10. `testSingleVideoPerOwnerInvariant`
11. `testNoNewEgressSourceScan`
12. `testCrashIndependenceSourceScan`

No method with a `test` prefix exists beyond those twelve; helpers do not use
the prefix.

The suite drives real production seams (routine store + scheduler + alarm
seam + `RoutineNotificationContent` + `RoutineVisualAidFireHandler` +
`AppCoordinator`; `InstructionVideoStore` and `VisualAidStore` rooted under a
per-test temp directory; `EventExtrasStore` + `FreeFormEventService` over a
real extras index; `InstructionPresentation`, `VisualAidInstructionImageLoader`,
`InstructionMessageKey`, `InstructionFilename`). Only platform edges are
doubled: alarm scheduler, observability bus, family notifier, EventKit
gateway, encrypted storage and profile storage.

Rules honoured:

- Every test uses `setUpWithError`'s unique
  `FileManager.default.temporaryDirectory/InstructionFeatureIntegrationTests-<UUID>`
  root and removes it in `tearDownWithError`. Nothing is written to
  Application Support, the Keychain, the photo library or the network.
- No sleeps. The handler's `DispatchQueue.main.async` sinks are drained with
  the checked-continuation `drainMainQueue()` pattern from
  `RoutineVisualAidFireHandlerTests`, so "no call" is proved without timing.
- No prints and no instruction text, captions or filenames in failure
  messages; every fixture is synthetic.
- Fixture media in test 7 is planted before any decode, and the final
  assertions prove no load path deleted it and no storage `delete` ran.

## Case coverage

### 1. `testRoutineInstructionEndToEndText`

Real `RoutineScheduler.addEntry` + `setInstruction(.text)` + real store,
notification builder and fire handler, then the real coordinator.

Proves: the stored wire value is trimmed while the raw kind is kept; the
armed occurrence carries `hadInstruction == true` (read from the current
index by `regenerateWindow`); exactly one `entry_instruction_updated` event
with outcome `saved` and exactly the `{entry_id_hash, kind, count}` metadata
keys, with no instruction text in any value; the notification payload carries
`had_instruction == true` as a Bool; the foreground fire publishes
`.reminder(title:…, aids: [], instruction: expected, expectsInstruction: true,
firedAt:)`; the card resolves `.text(text:)`; `timeText` is non-nil; a tap
with the instruction present publishes the same instruction and the
notification's delivery date.

### 2. `testRoutineInstructionEndToEndImage`

Real scheduler + real `VisualAidStore` pending `UIImage` + real
`VisualAidInstructionImageLoader` + real handler/coordinator.

Proves: the store mints the filename; the instruction image is NOT appended
to the entry's `visualAids`; the loader reads the committed bytes; the event
kind is `image`; the fired screen and tap card resolve `.image(filename:,
caption:)`; `timeText` is non-nil.

### 3. `testRoutineInstructionEndToEndVideo`

Real `InstructionVideoStore.stageSynchronously` + scheduler commit + real
handler/coordinator.

Proves: the committed name is exactly
`InstructionVideoStore.storedFilename(draftId:sourceExtension:)`;
`availability` is `.available(url)` and the bytes on disk match; the card is
`.video(filename:, caption:)` before and after the tap; the coordinator's
playback seam answers the same thing as its own shared store for an absent
filename (`.missingFile`); source pins show exactly one seam declaration and
one delegation line.

Documented limitation: `AppCoordinator.instructionVideoStore` is a
non-injectable `let` rooted at Application Support. This test does not write
there; it asserts the temp store's own bytes/availability and pins the
one-line delegation instead. If the coordinator changes that seam's shape,
the source pin fails loudly.

### 4. `testReminderFiresWithoutInstruction`

Real scheduler arming with no instruction, real notification payload, real
handler.

Proves: every armed occurrence has `hadInstruction == false`;
`willPresent` returns false and publishes nothing when the entry has no
photo, no instruction AND the payload expected none; a pre-upgrade tap (no
`had_instruction` key) is a no-op.

### 5. `testNotificationPayloadCarriesNoInstructionContent`

Real `RoutineNotificationContent.make`.

Proves: exactly the four producer keys (`occurrence_id`, `entry_id`, `type`,
`had_instruction`); the values are the expected strings and a real `Bool`; no
category identifier, no actions, no attachments; a sentinel instruction word
appears in none of title/subtitle/body/userInfo; the reader treats an absent
key and a non-Bool value as false; a real `true` reads true.

### 6. `testTapPresentRemovedDeletedMatrix`

Real handler + coordinator with a mutable `EntryBox` lookup.

Covers the Gherkin tap outcomes: (a) present → card; dedupe by entry id does
not replace an already-presented owner; a different entry id does replace;
(b) entry live, instruction removed after arming → `.reminder` with nil
instruction, `expectsInstruction == true`, non-nil fire time, `.removed` card;
(c) owner deleted → `.unavailable`, `.none` card, nil time, empty footer;
(d) pre-upgrade payload → no-op, nothing published.

### 7. `testMigrationFixturesF1ThroughF12`

Raw JSON in the exact shipping key spellings (`routine.entries`,
`eventExtras.byEventId`) through the real `RoutineStore` and
`EventExtrasStore`, with real instruction videos and a real image planted on
disk first.

F-1 legacy routine entry; F-2 legacy extras; F-3 text (raw text preserved,
display trimmed); F-4 image; F-4b image with a wrong-typed `text` field (the
field costs only itself, filename survives); F-5 video; F-6a unknown `link`
kind (verbatim round trip, `.unsupported(text: nil)`); F-6b unknown `audio`
kind with text (`.unsupported(text:)`); F-7 wrong-typed instruction in both
owners (owner survives, instruction nil); F-8 unknown nested field (loads,
re-encode drops it); F-9 empty extras index; F-10 explicit null in both
owners; F-11 traversal filenames decode but the video store / image loader
refuse them (`.rejectedFilename`, nil `fileURL`, `.deleteFailed`, one plain
fallback key); F-12 absent video file (`.video` display state, `.missingFile`,
nil fileURL/playbackURL). Final assertions: planted routine/event videos and
the image still exist with identical bytes/availability, and
`deleteCallCount == 0`.

### 8. `testMedicationFixturesUnchanged`

Strict legacy medication decode with all optional fields nil/defaulted; the
encoded top-level key set is exactly the pre-feature set (including the
pre-existing `visualAids` field); no `instruction` key anywhere; notification
categories/actions/options pinned for `en` and `ne`; the medication and
notification-categories sources contain no instruction mention; the
instruction sources borrow none of the four medication/event identifiers;
the four medication timer fields still exist; a behavioural pin shows
`setEnabled(false)` on one entry cancels exactly that entry's occurrence ids
and leaves the other entry armed; the alarm protocol has the scoped
`cancelRoutineReminders(occurrenceIds:)` and no `cancelAll`.

### 9. `testVisualAidFixturesUnchanged`

A legacy entry with a visual aid encodes/decodes equal and gains no
`instruction` key; a real stored image survives real text, video and removal
instruction writes; event extras photo and instruction are independent in
both directions; N-1 is pinned in source: `VisualAidStore.delete` /
`deleteAll` and `ContactPhotoStore.delete(named:)` stay `Void`, while
`InstructionVideoStore.delete` keeps its typed `Result<Void,
InstructionStorageError>`.

### 10. `testSingleVideoPerOwnerInvariant`

Real scheduler/store for a routine owner and real `EventExtrasStore` /
`FreeFormEventService` (stub gateway) for an event owner.

Proves, per owner: replace leaves exactly one instruction file and deletes
the replaced bytes; a text instruction deletes the previous video; an
instruction added after a text commit yields one file; removal leaves zero
files and nil instruction. Event-owner assertions cover the same sequence
through the service.

### 11. `testNoNewEgressSourceScan`

22 precise patterns (URLSession, URLRequest, NWConnection, WebSocket,
CFSocket family, CKContainer, share/document pickers, the Photos family and
`requestAuthorization`, `import Photos`, upload, data/download tasks,
putData, Firebase family, CloudKit) over all instruction sources, the shared
seam files and the coordinator's instruction composition slice. A planted
`.swift` file containing every token must match every pattern; a negative
control (`import PhotosUI`, `PHPickerViewController`, `AVAudioSession`, a
local `URL(fileURLWithPath:)`, `UIActivityItemProvider`) must match none.
The test states that a textual scan cannot prove the absence of indirect
egress outside these roots.

### 12. `testCrashIndependenceSourceScan`

24 precise AI/voice/LLM patterns over the same roots and coordinator slice
with the same planted-token and negative-control design. The test states
that this proves no code dependency, not runtime isolation.

## Acceptance-scenario coverage (automated portion)

- "A routine instruction survives the full path" — tests 1–3 and 6 cover
  arming/firing/presentation, payload content, present/removed/deleted tap
  outcomes and the fire-time line; test 4 covers firing without an
  instruction. FR-RIE-015, FR-RIE-017, FR-RIE-019.
- "Legacy payloads from every prior shape still load" — test 7 (F-1…F-12 plus
  the no-delete survival checks), with test 9 for visual aids. NFR-RIE-006.
- "The medication path and notification taxonomy are unchanged" — test 8
  (payload, categories/actions/options, timer fields, scoped cancels), test 9
  (visual-aid and delete-signature boundary). FR-RIE-021, FR-RIE-023,
  NFR-RIE-010.
- "The full suite has zero new failures" — only the coordinator's single
  full-suite run can prove this; this unit contributes the named suite.
- "The gate and the canonical build pass" — coordinator's release-log gate
  and `./build.sh`; this unit changes no product file.
- "The device smoke is recorded honestly" — coordinator's 14-step Release
  recording; not simulated here.
- "The AI and voice pipeline cannot break reminder delivery" — test 12's
  source pin plus tests 1–4's delivery path; runtime isolation is explicitly
  not claimed.

The plan's matrix rows that name this suite are NFR-RIE-006
(`testMigrationFixturesF1ThroughF12`), FR-RIE-023 and NFR-RIE-010
(`testMedicationFixturesUnchanged`); the remaining rows point at earlier
units' named tests.

## Production APIs assumed (coordinator must compile-verify)

Every symbol below was checked against its declaration before use:

- `RoutineScheduler.init(store:alarmScheduler:observabilityBus:familyNotifier:caregiverNotifySettings:visualAidStore:instructionVideoStore:now:)`,
  `addEntry`, `setInstruction(_:entryId:)`, `entry(for:)`, `scheduleAll`,
  `setEnabled(_:enabled:)`; `setInstruction` emits
  `entry_instruction_updated` with the three closed metadata keys via
  `notifyInstructionChanged` → `completeMutation` → `scheduleAll`.
- `RoutineAlarmScheduling.scheduleRoutineReminder(occurrenceId:entryId:title:visualAidURL:hadInstruction:at:)`
  and `cancelRoutineReminders(occurrenceIds:)` (no `cancelAll`).
- `Instruction(kind:text:caption:filename:url:)`, tolerant `init(from:)`,
  `InstructionPayload(kind:text:caption:filename:)`,
  `InstructionWrite.set/.remove`, `InstructionCommit(write:pendingMedia:)`,
  `InstructionPendingMedia.image/.video`,
  `AcceptedInstructionVideo(staged:validatedAt:)`,
  `InstructionVideoMetadata(durationSeconds:hasVideoTrack:isPlayable:)`,
  `InstructionOwner.routine/.event`, `.root`, `.directoryName`,
  `InstructionRoot.routines/.events`.
- `InstructionVideoStore.init(fileManager:baseDirectory:now:fileOps:)`,
  `stageSynchronously(from:into:limits:chunkBytes:draftId:probe:)`,
  `commit(_:for:)`, `delete(_:for:)`, `fileURL(filename:owner:)`,
  `availability(filename:owner:)`,
  `ownerDirectoryURL(named:in:)`,
  `storedFilename(draftId:sourceExtension:)`; `InstructionStorageError`
  Equatable; `InstructionPlaybackAvailability` Equatable.
- `VisualAidStore.init(rootDirectory:)`, `save(_:for:caption:)`,
  `existingFileURL(_:for:)`, `delete(_:for:)`, `deleteAll(for:)` (Void);
  `ContactPhotoStore.init(rootDirectory:directoryName:)`, `delete(named:)`
  (Void).
- `EventExtras(photoFilename:instruction:)`, tolerant `init(from:)`;
  `EventExtrasStore.init(storage:)`, `snapshot()`, `all`, `track(eventId:)`,
  `setPhotoFilename(_:forEventId:)`, `setInstruction(_:forEventId:)`,
  `extras(forEventId:)`.
- `FreeFormEventService.init(gateway:extras:photoStore:instructionVideoStore:observability:)`,
  `setInstruction(_:forEventId:)`; `EventKitCalendarGateway` requirements
  (including `eventExists(identifier:)`, which has a default).
- `RoutineNotificationContent` keys/builder/`hadInstruction(from:)`;
  `RoutineVisualAidFireHandler.init(entryLookup:onFire:onInstructionTap:)`,
  `willPresent(_:categoryIdentifier:)`, `didReceive(_:)`,
  `routineReminderType`.
- `FiredRoutineVisualAids(entryId:content:)`, `.reminder(title:aids:instruction:expectsInstruction:firedAt:)`,
  `.unavailable`; `RoutineVisualAidOverlay.cardState(for:)`,
  `timeText(for:locale:)`, `footerIsEmpty(for:)`.
- `AppCoordinator.init(profileStorage:)`, `presentRoutineVisualAids(for:context:)`,
  `presentRoutineInstructionTap(entryId:entry:firedAt:)`,
  `dismissFiredRoutineVisualAids()`, `firedRoutineVisualAids`,
  `instructionPlaybackAvailability(filename:owner:)`,
  internal `instructionVideoStore`.
- `ProfilePayloadStorage` (`readRawData`, `hasPayload`),
  `EncryptedLocalStorage` (`write`/`read`/`delete`), `ObservabilityEvent`
  fields, `NotificationCategories` identifiers/actions/options,
  `InstructionDisplayState` cases, `InstructionPresentation.state(for:isExpected:)`,
  `InstructionMessageKey.forImage(_:)`, `InstructionFilename.isPlain(_:)`,
  `VisualAid(filename:caption:)`, `MedicationEntry` and its optional decode.

## Reused helpers and doubles

- Reused unchanged from the existing target: `MockEncryptedLocalStorage`,
  `MockObservabilityBus`, `MockFamilyNotifier`,
  `MockRoutineAlarmScheduler` (its `scheduled`/`cancelled` shape is what
  makes the scoped-cancel pin behavioural), and `CaregiverNotifySettings.isolated`.
- Re-declared minimally because the originals are file-private:
  `InMemoryProfileStorage` (`ProfilePayloadStorage`), `StubEventGateway`
  (`EventKitCalendarGateway`), the runtime `UNNotification` /
  `UNNotificationResponse` stubs (`class_createInstance` + KVC), and
  `drainMainQueue`.
- New local double: `RawJSONStorage`, an `EncryptedLocalStorage` that can
  hold RAW JSON bytes. The shipping `MockEncryptedLocalStorage` only encodes
  Swift values, so it cannot express wrong-typed fields, explicit nulls,
  unknown nested fields or the pre-instruction key shapes that F-1…F-12 are
  about. It is used only for those raw fixtures; every other round trip uses
  `MockEncryptedLocalStorage`.
- New local helpers: `RoutineHarness`, `EntryBox`, `SinkRecorder`, fixture
  constants, commit/stage helpers, JSON helpers, `FeatureSourceScan` roots
  and the coordinator section slicer.

## Decisions

1. **Real seams wherever the behaviour lives in product code.** The suite
   doubles only the alarm scheduler, the observability bus, the family
   notifier, the EventKit gateway and storage. The scheduler, stores,
   notification builder, handler and coordinator are the shipping ones, so
   the transaction, arming and presentation order are exercised rather than
   mocked.
2. **Raw JSON for migration fixtures.** F-1…F-12 are about decode tolerance
   from bytes an older build could have written. Encoding Swift values
   cannot produce a wrong-typed `text`, an explicit `null` or an unknown
   nested field, so those twelve fixtures go through a private raw-JSON
   storage. The key spellings are pinned once (`ShippingKey`), so a store
   key rename fails loudly.
3. **No Application Support writes for the video seam.** The coordinator's
   video store is a non-injectable `let`, so the video case asserts the temp
   store's bytes and the seam's own answer for an absent name, and pins the
   one-line delegation in source. Writing outside the temp root would break
   the task's isolation rule and the notes say so.
4. **Source scans are comment-free, string-preserving, line-oriented.** This
   matches `FeatureSourceScan.codeText`/`firstMatch`: documentation examples
   do not fail the suite, a code literal inside a string is still visible,
   and each pattern is evaluated per line. Both scan tests state their
   limits: they prove the feature's own sources name no forbidden surface,
   not that no indirect edge exists outside those roots.
5. **Falsifiability controls.** Each scan has a planted `.swift` file that
   must match every pattern and a negative control that must match none. If
   a detector silently stopped matching, the planted leg fails instead of
   passing forever.
6. **Medication key set includes `visualAids`.** A systematic read-back
   against `MedicationEntry`'s synthesized `Encodable` found that the
   non-optional `visualAids` field is always encoded (empty array included),
   while optional fields use `encodeIfPresent`. The exact-set assertion was
   corrected to the real 13-key pre-feature set.
7. **Exact twelve methods.** Per the task, no extra cases; supporting
   behaviour is expressed as assertions inside the named cases.

## Validation performed

### Syntax

```
xcrun swiftc -parse ios/ElderlyAssistantTests/Services/Instructions/InstructionFeatureIntegrationTests.swift
```

Result: exit 0, run before and after the final edits. This is syntax only,
not a type-check against the test target, and is not an `xcodebuild` run.

### Read-only scan simulation

Because the two source-scan cases cannot be executed here, every pattern was
replayed in Python over the exact file set the suite builds (13 files under
`Services/Instructions` plus `InstructionViews.swift`,
`InstructionCapture.swift`, `RoutineNotificationContent.swift`,
`RoutineVisualAidFireHandler.swift`, `RoutineScheduler.swift`,
`EventExtrasStore.swift`, `FreeFormEventService.swift` = 20 files) and over
the coordinator's composition slice, using a faithful mirror of
`codeText` (comments stripped, string literals preserved, line-oriented
matching):

- 0 matches for all 22 egress patterns and all 24 AI/voice patterns across
  all 20 files and the coordinator section;
- the planted egress control matched every pattern;
- the planted AI control matched every pattern;
- the egress negative control matched none;
- the AI negative control matched none;
- the coordinator start/end markers resolve and the section is non-empty.

The simulation caught two real defects before submission, both fixed:

1. `\bCFSocket\b` cannot fire on `CFSocketCreate(...)`, and `\bFirebase\b`
   cannot fire on `FirebaseApp.configure()`. Both patterns became
   `\bCFSocket\w*` / `\bFirebase\w*`, which still match the real sources'
   nothing and the planted controls' every token.
2. The medication encoded top-level set omitted the always-encoded
   `visualAids` field (see Decision 6).

### Not run (and not claimed)

No XCTest case, scoped filter, full suite, release-log gate, canonical
build, project regeneration or device smoke was run. Per the task
instruction the coordinator runs them and records the command results in
`specs/implement-notes.md`. Nothing in this file should be read as a green
test claim; the suite has not been compiled against the test target.

## Risks the coordinator must verify

1. **Type-check surprises.** `swiftc -parse` proves syntax only. Method
   references, optional pattern matching, actor-isolation annotations and
   the re-declared protocol conformances must be compiled by the scoped
   `-only-testing:ElderlyAssistantTests/InstructionFeatureIntegrationTests`
   run. Any resulting edits belong to the coordinator's repair pass.
2. **Coordinator's non-injectable video store.** Test 3 pins the seam by
   source text and asserts only absent-name behaviour against the real
   shared store. If `AppCoordinator.instructionVideoStore` or
   `instructionPlaybackAvailability` is reshaped for another task, this
   test fails loudly rather than silently skipping.
3. **Full-suite baseline.** T-027's zero-new-failures criterion needs the
   documented baseline from the starting commit. If the baseline record is
   missing, the run must be recorded as inconclusive, not green.
4. **Release gate and canonical build.** The gate's feature roots/event
   registry and `./build.sh` are T-026/T-027 coordinator steps on the final
   tree; this unit changed no product source and no allow-list entry.
5. **Device smoke and timings.** NFR-RIE-008's player/first-frame/fallback
   timings and the 14-step checklist need the owner's device on a Release
   build. This unit cannot and does not claim them.
6. **Textual scan scope.** Tests 11–12 cannot see indirect egress or a
   process-wide crash; they prove the feature's own code names no such
   surface, and their comments say so.
7. **Fixture-format drift.** F-1…F-12 are synthetic and pinned to today's
   tolerant decoders. A future decoder change that starts throwing on one
   of these shapes is exactly what the suite should catch, but the failure
   message must be read as a fixture/decoder mismatch, not as a test bug.

## Files changed by this unit

- `ios/ElderlyAssistantTests/Services/Instructions/InstructionFeatureIntegrationTests.swift`
  — new, the twelve named cases.
- `specs/T-027-notes.md` — this file.

No production code, project file, existing test/helper, or other task/spec
file was created or edited.

## Coordinator verification record (2026-10-26)

This section is the coordinator's evidence, appended after the unit agent
finished. It supersedes nothing above; the agent correctly claimed no test
result of its own.

### Scoped suite

- Project regenerated: `cd ios && ./build.sh generate` — `seniOS.xcodeproj
  regenerated`.
- The first scoped run compiled and executed all twelve cases with one
  assertion failure at line 932: `cardState()` returns
  `InstructionDisplayState?`, and the bare `.none` argument resolved to
  `Optional.none` (nil), so the deleted-owner case compared
  `Optional(.none)` with `nil`. The coordinator changed the expectation to
  `InstructionDisplayState.none` (test-only edit).
- Rerun: `Executed 12 tests, with 0 failures (0 unexpected) in 2.353 s`,
  `** TEST SUCCEEDED **`. Exactly the twelve named cases exist; no helper
  uses the `test` prefix.

### Release gate

`bash ios/tools/check-release-log-safety.sh` exited 0 on the final tree:
the feature roots and the seven `instruction_*` event types resolve, all
seeded violations are caught by name, the off-root control stays quiet, and
the three temporary-copy legs left the shipping tree byte-identical. No
allow-list entry was removed or weakened.

### Canonical build

`cd ios && ./build.sh` — `✓ Build complete`, exit 0. The first attempt was
stopped by a 20-minute wall-clock guard while compiling a cold canonical
cache; a retry immediately after hit a transient locked build database from
the shutting-down process; the clean rerun on the warm cache completed.

### Full-suite comparison — INCONCLUSIVE

The documented pre-wave baseline was itself inconclusive (starting commit
does not compile without the five recorded repairs; the run was terminated
inside a 309-second dialect test). Two post-change attempts were made:

1. A 9-minute-guarded run completed 2,864 cases before the guard: 41
   failures — the same 33 baseline failures plus 8; 2 of the 8 passed when
   rerun scoped, the other 6 are order-sensitive CloudChat consent cases.
2. A 30-minute-guarded run completed 5,261 cases (5,180 passed, 79 failed,
   2 skipped) and then the test host crashed with
   `EXC_BAD_ACCESS/SIGSEGV` in `MedicationSchedulerTests.testIntakeRecordedAfterWrite`
   (`MockEncryptedLocalStorage.read` → `Dictionary._Variant.lookup` inside
   `MockFamilyNotifier.notifyAll` — the pre-existing non-thread-safe test
   double raced by the scheduler's async notification). That suite passes
   41/41 alone; no instruction source is in the stack.

Over every executed case, all 33 documented baseline failures reproduced
and no instruction suite failed (207 instruction cases passed before the
crash point, including this suite's 12/12). The 46 failures beyond the
baseline's executed scope are all in pre-existing, feature-untouched suites
(prompt-mirror drift, CloudChat consent-store state, availability and
LiveTranslate suites). Full details and the classification are in
`specs/implement-notes.md`; the comparison is recorded as **inconclusive,
not green**, as the task requires when the baseline record is incomplete.

### Device smoke — OUTSTANDING

Anzaan (iPhone 14 Pro Max, `iPhone15,3`, iOS 27.0.1) is paired and available
(`xcrun devicectl list devices` → `available (paired)`), but the 14-step
Release-build checklist in design §11.5 is owner-driven: fired reminders a
minute ahead, a 10 s and a 4-minute recording, >200 MiB and corrupt files, a
container-file deletion through devicectl, language switching, VoiceOver and
one-handed checks, and a 60 fps screen recording for NFR-RIE-008. None can
be executed or attested unattended, and no step may be claimed passed from a
simulator. **All 14 steps are an outstanding gate with this exact reason;
the NFR-RIE-008 tap→player (≤500 ms), player→first-frame (≤2 s) and
failure→fallback (≤1 s) timings are outstanding.** No step is claimed
passed.
