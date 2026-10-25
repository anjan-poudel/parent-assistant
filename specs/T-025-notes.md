# T-025 — Coordinator fired-screen composition, tap routing and launch sweep

Status: implemented in the feature worktree
(`/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements`,
branch `feat/reminders-instructions-enhancements`). Scoped test filter and
project regeneration are run by the coordinator; this unit did not run
`xcodebuild` or `./build.sh` (explicit instruction).

## Files changed (only the three owned files)

1. `ios/ElderlyAssistant/App/AppCoordinator.swift` (additive/localized)
2. `ios/ElderlyAssistantTests/App/AppCoordinatorInstructionTests.swift` (extended)
3. `ios/ElderlyAssistantTests/Services/Readiness/NoIOInInitTests.swift` (extended)

No other file was edited. `VisualAidViews.swift`, `ContentView.swift`,
`EventsView.swift`, the services and the project file are untouched.

## Production changes

### 1. Sweep input value and store seam (file scope, before the class)

- `struct LiveInstructionOwners: Equatable` with `routines: Set<InstructionOwner>?`
  and `events: Set<InstructionOwner>?` (design §4.9). `static func compose`
  maps a source through `Set(...)` when it is readable and preserves `nil`
  when it is not — `nil` means unknown, never an empty stand-in. Liveness is
  `instruction?.knownKind == .video` only; filenames and file existence are
  never consulted. `compose` performs no IO.
- `protocol InstructionOrphanSweeping` with the two purge methods
  (`purgePendingDrafts()` and `purgeOrphanedOwners(in:live:graceSeconds:)`).
- `extension InstructionVideoStore: InstructionOrphanSweeping {}` — the
  existing store methods already match the protocol, so no store change was
  needed.

### 2. One shared event side index

- New stored `let eventExtrasStore: EventExtrasStore`, assigned in `init`
  beside `storage` (`EventExtrasStore(storage: storage)` — construction only,
  no read/write/file IO).
- The lazy `freeFormEventService` now receives `extras: eventExtrasStore`
  instead of constructing its own instance, so the sweep's `snapshot()` reads
  exactly the index the event service writes.

### 3. Fired-screen composition and tap routing

- `presentRoutineVisualAids(for:context:)` publishes
  `FiredRoutineVisualAids(entryId:content:)` with
  `.reminder(title: entry.displayTitle(locale: activeLocale), aids:,
  instruction:, expectsInstruction: context.hadInstruction, firedAt:
  context.firedAt)`. The title is resolved at fire time; the delivery date is
  the notification's, never a clock read.
- `presentRoutineInstructionTap(entryId:entry:firedAt:)`:
  - a presentation already showing the same `entryId` is not replaced
    (dedupe check runs first);
  - `entry == nil` publishes `.unavailable` (the deleted-owner notice, no
    title/time claimed);
  - a live entry publishes `.reminder(... expectsInstruction: true,
    firedAt:)` — this sink only runs when `had_instruction` was true, so a
    removed instruction renders the `.removed` fallback.
- `dismissFiredRoutineVisualAids()` is unchanged and remains idempotent.
- The temporary `FiredRoutineVisualAids.init(entryId:title:aids:)` is no
  longer used anywhere in the coordinator; its deletion is left to the
  coordinator as instructed.

### 4. Handler registration

`RoutineVisualAidFireHandler` is now registered with the designated
initializer: `entryLookup` unchanged, `onFire` forwards the typed
`RoutineInstructionFireContext`, and `onInstructionTap` routes the
`(entryId, entry?, firedAt)` triple to the tap seam. Registration order and
every other handler (`NotificationReader`, `CaregiverEventFireHandler`,
medication/event handlers) are unchanged; `FreeFormEventFireHandler` keeps
its existing sink.

### 5. One launch orphan sweep

- Enqueued exactly once from `composePostFirstFrame()` (main-confined via
  `MainActor.assumeIsolated`), never from `init` and never from a timer or a
  foreground event.
- Before the hop, on the main actor: `composeLiveInstructionOwners()` (the two
  strict reads — `routineScheduler.entriesIfReadable()` and
  `eventExtrasStore.snapshot()`), the 60 s
  `InstructionVideoConfiguration.standard.orphanGraceSeconds`, the
  `instructionSweeper` seam and the `instructionEvents` observability value
  are resolved. This also forces both lazy initializers on main.
- Off-main (`modelHousekeepingQueue`), the synchronous helper
  `AppCoordinator.performInstructionOrphanSweep` calls
  `purgePendingDrafts()` once, then `purgeOrphanedOwners` once per root with
  that root's own live set. Each call emits exactly one
  `instruction_orphan_purge` event (component `instruction_media`):
  `.completed` + count on success, `.failed` + count 0 + the mapped error
  token on failure. A failure is an event and a skipped root, never a thrown
  error or a launch failure.
- A one-shot guard (`instructionSweepEnqueued`) makes repeated enqueue calls
  a no-op, so the sweep runs once per process.
- A `nil` live set is passed through to the store, whose `nil` handling is a
  no-op — bytes for an unreadable source are kept.

## Tests added

`ios/ElderlyAssistantTests/App/AppCoordinatorInstructionTests.swift`
(all 11 pre-existing T-022 tests are untouched and still present,
including `testFactoriesBuildNoNetworkOrTranscodeAdapter`):

- `testPresentForegroundBuildsReminderContent`
- `testExpectsInstructionMirrorsHadInstruction`
- `testTapWithInstructionPresentsReminder` (also proves dedupe by entry id and
  replacement by a different entry)
- `testTapWithRemovedInstructionPresentsRemoved`
- `testTapWithNilEntryPresentsUnavailable`
- `testDismissClearsAndIsIdempotent`
- `testSweepKeepsBytesForUnreadableRoutineSource` (nil routine source keeps
  bytes; readable events still follow live rules)
- `testSweepKeepsBytesForUnreadableEventSource` (nil event source keeps bytes)
- `testSweepUsesStrictReadsOnly` (source pin: `entriesIfReadable()` and
  `snapshot()` present; `loadEntries()`, `entries()`, `.all` absent)
- `testSweepHonoursTenantGrace` (60 s passed to both roots; grace captured
  from its one named home)
- `testLiveSetUsesInstructionKindNotFileExistence` (video kind with no
  filename is live; text/image/unknown kinds are not)
- `testComposePerformsNoIO` (source pin over `compose` plus behavioural
  absent-file case)
- `testSweepRunsOnceAtLaunch` (one `purgePendingDrafts` call, one call per
  root, second enqueue is a no-op)
- `testSweepPartialCountReported` (three events, ordered outcomes, counts
  2/1/0, `purge_failed` token on failure)
- `testInstructionPlaybackAvailabilityDelegatesToSharedStore` (the seam
  answers exactly the shared store's answer for an absent filename, and the
  source shows one delegation)

Supporting test doubles/helpers added in the same file: the
`RecordingInstructionSweeper` spy (NSLock-protected call log, scriptable
results, `onCall` hook), `sourceSlice(from:to:)`, `makeEntry`,
`videoInstruction(filename:)` and `fixedFiredAt`.

`ios/ElderlyAssistantTests/Services/Readiness/NoIOInInitTests.swift`:

- `testSweepNotRunFromInit` — source pin over the `init(profileStorage:` …
  `StartupSignposts.end(.bootstrapInit)` region (no enqueue, no purge call)
  and over `composePostFirstFrame()` (exactly one
  `enqueueInstructionOrphanSweep()` and a `MainActor.assumeIsolated`), plus an
  `occurrences(of:in:)` helper.

## Decisions made during implementation

1. **Dedupe before the nil check in the tap sink.** L1's rule ("a
   presentation already showing the same entry is not replaced") is applied
   to the id alone, so a re-delivered tap for the same owner — live or
   deleted — does not reset or flip the screen. The prompt's three outcomes
   are preserved; the dedupe only short-circuits an identical owner.
2. **Synchronous static sweep helper.** The purge body is a static function
   taking `(owners, graceSeconds, sweeper, events)`, so the tests exercise the
   real ordering and event emission with a spy and never touch a file root.
   The launch path is a thin enqueue around the same body.
3. **Main-actor lazy resolution.** `instructionSweeper` and
   `instructionEvents` are read (and thereby initialized) inside the
   `@MainActor` enqueue method before the queue hop; the off-main block
   captures values only, avoiding lazy-initializer races.
4. **`nil` is preserved at every layer.** `compose` uses `Optional.map`
   rather than `?? []`; the sweep forwards `nil` to the store, whose
   documented `nil` behaviour is a no-op. No test or production path can
   substitute an empty set.

## Constraints honoured

- No file IO in `init`; no purge from `init`; no timer, repeating sweep or
  foreground sweep.
- No new egress, analytics, notification registration or permission request.
- Diff is additive and localized; no reformatting; no free-text logs (the
  only observability is the existing closed-token event).
- The existing T-022 source pins still hold: one `InstructionVideoStore()`
  construction site, two `instructionVideoStore: instructionVideoStore`
  injections, and no forbidden IO/network/timer tokens inside the instruction
  composition section.

## Verification performed

- Full read-back of every edited region of the three owned files.
- Cross-checked every referenced symbol against its declaration:
  `FiredRoutineVisualAids.Content` / designated init, `InstructionPresentation`,
  `InstructionVideoStore.purgePendingDrafts` / `purgeOrphanedOwners` and
  `availability`, `InstructionStorageError.purgeFailed`,
  `InstructionObservability.orphanPurge` and the `ObservabilityEvent` fields,
  `EventExtrasStore.snapshot` / `EventExtras(instruction:)`,
  `RoutineEntry` init / `displayTitle` / `visualAids` / `instruction`,
  `RoutineScheduler.entriesIfReadable` / `entry(for:)`,
  `FreeFormEventService(extras:instructionVideoStore:observability:)`,
  `MainActor.assumeIsolated` usage, and the single `AppCoordinator`
  initializer.
- `xcrun swiftc -parse` (syntax only, no build) on all three files: clean.
- Confirmed the new code sits inside the `instructionSection()` slice used by
  the T-022 pins and contains none of their forbidden tokens.

## Risks / uncertainty

1. **No full compile/typecheck in this unit.** Per the task instruction the
   scoped `-only-testing` filter and project regeneration are run by the
   coordinator. Static review and parse-only checks were done, but a
   typecheck-level surprise (e.g. an overload or isolation diagnostic) can
   only surface in that scoped run.
2. **`testSweepRunsOnceAtLaunch` performs the real strict reads.**
   `composeLiveInstructionOwners()` runs against the coordinator's real
   `MigratingEncryptedStorage` (file-resident keys first, Keychain fallback),
   which in the unit host typically returns nil and is non-destructive. The
   purge itself is fully spied, so no directory is created, read for deletion
   or removed by the test.
3. **Temporary initializer deletion is owned elsewhere.** The coordinator
   still compiles today because the temporary
   `FiredRoutineVisualAids.init(entryId:title:aids:)` remains in
   `VisualAidViews.swift`; this unit simply stopped using it. If the
   coordinator deletes it before regenerating/building, nothing in the
   coordinator references it.
4. **Handler callbacks are delivered on main by the handler itself.** The
   presentation methods are intentionally not `@MainActor`: the handler's
   closure types are non-isolated and it already hops to
   `DispatchQueue.main`; annotating the methods would be a compile error.
