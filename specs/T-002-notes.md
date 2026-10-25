# T-002 notes — Instruction video store (create-before-bytes, protection, sweeps)

## What was built

- `ios/ElderlyAssistant/Services/Instructions/InstructionVideoStore.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionVideoStoreTests.swift` (new)
- `ios/ElderlyAssistantTests/Services/Readiness/NoIOInInitTests.swift` (extended, one case)

### Store (design §2.2, §3.3, §3.5, §5.1–§5.6)

- **`InstructionStorageError`** — the final declaration, exactly the design §3.3
  case set: `invalidOwner`, `stagingFailed`, `protectionFailed`, `commitFailed`,
  `deleteFailed`, `purgeFailed`. Equatable, no NSError escapes.
- **`InstructionPlaybackAvailability`** — the four cases, `.available(URL)` only
  hands out a URL.
- **`StagedInstructionVideo` / `AcceptedInstructionVideo`** — per §3.5.
- **`InstructionStagingFileOps`** (the single staging seam, `Sendable`) and
  **`SystemInstructionStagingFileOps`** — `createFile(contents: nil,
  attributes: [.protectionKey: .complete])`, attribute read, 1 MiB `FileHandle`
  chunked read/write loop closing both handles on every path; cumulative
  `maxBytes` cap inside the loop.
- **`InstructionVideoStore`** (`@unchecked Sendable` with the §7.1 justification
  comment):
  - `init` resolves paths only (injected base → Application Support
    `url(for:create: false)` → temporary directory); zero FileManager calls
    beyond the pure path lookups; roots stored as computed URLs.
  - `stageSynchronously` (IF-5) runs the fixed §5.2 order: readable-file check,
    step-2 size stat (`size > maxBytes` strictly ⇒ `.tooLarge`), probe + the
    store's own metadata defences (`unsupportedFormat` / non-finite ⇒
    `unreadableSource` / rounded-duration `tooLong`), `_pending` directory
    created complete-protected, destination created with **no bytes and
    `.complete` protection before the first byte** (B-3), chunked fill with
    cumulative cap, post-stream re-verify. Every failure after the first
    directory creation removes the partial file then the draft directory.
    Delivered-count ≠ step-2 size ⇒ `.unreadableSource` (truncated/changed
    source).
  - `commit` (IF-6): owner-name guard (`.invalidOwner`), root match, owner
    directory created complete-protected, retry idempotency (destination
    exists with the staged size ⇒ success, no move), `moveItem` (same volume),
    destination protection re-verified (R-5 rule), draft directory removed
    best-effort; rename always precedes the delete. The owner name sits in the
    `NSLock`-protected in-flight set from before directory creation until the
    rename completes.
  - `discard`/`delete`/`deleteAll` — existence-first idempotent teardown,
    `.deleteFailed` on real failures; `delete` guards the payload filename
    before any URL is built (N-4).
  - `availability` (never throws) and `fileURL` — filename guard first,
    then existence/isDirectory/readability.
  - `purgePendingDrafts` (IF-11) — both roots, `_pending` children (files and
    directories) aged ≥ the design-fixed 60 s grace
    (`InstructionVideoConfiguration.standard.orphanGraceSeconds`); stop-early
    `.purgeFailed` on a removal failure.
  - `purgeOrphanedOwners(in:live:graceSeconds:)` (IF-12) — `live == nil` ⇒
    `.success(0)` before any enumeration (P-6); per-child rules: skip
    `_pending`, skip non-directories, skip unparseable owner names
    (UUID-shaped or `ev-` + 32 hex), skip younger-than-grace, skip in-flight
    names (lock snapshot), skip live names — else remove and count.
    Liveness is answered by directory-name membership because the event
    owner name is a one-way digest (§5.5 step 3, documented in code).

### Tests

All 17 planned cases with the exact names, plus two design-required extras
(see Decisions). Every test plants bytes only in a per-test temporary
directory injected as the store's base; no network, no real user data. The
two doubles (`InstructionFileManagerSpy`, a `FileManager` subclass, and
`InstructionStagingFileOpsSpy`, the seam double) share one ordered
`InstructionStoreCallLog`, which makes the ordering claims assertable; both
perform real operations by default so on-disk assertions stay honest.

The 17 named cases:

`InstructionVideoStoreTests`:
`testCreateProtectedFileRunsBeforeFirstWrite`,
`testStagingDoesNotUseCopyItem`,
`testWeakerClassAtCreationDeletes`,
`testWeakerClassAfterStreamFailsAndDeletes`,
`testUnreportedClassIsTolerated`,
`testMidStreamFailureLeavesNoAcceptedFile`,
`testSourceLargerThanCapIsRejectedBeforeCopy`,
`testCumulativeCapAcrossChunks`,
`testTruncatedSourceFails`,
`testCommitOrderRenameThenDelete`,
`testCommitRenameFailureKeepsOldFile`,
`testDeleteFailureIsReported`,
`testPurgePendingDraftsOnly`,
`testOrphanSweepKeepsUnreadableOwners`,
`testOrphanSweepHonoursGrace`,
`testInvalidOwnerNameIsRefusedBeforePathBuild`

`NoIOInInitTests`: `testInitDoesNoFileIO` (source pin over the init region —
no createDirectory/contentsOfDirectory/fileExists/attributesOfItem/createFile/
removeItem/moveItem/copyItem/data(/contents(, and the `url(for: … create:
false)` lookup present — plus behavioural checks: a nonexistent injected base
stays nonexistent, and the default-base construction leaves the Application
Support routines root exactly as found).

## B-3 implementation points

- Destination created via `createProtectedFile` (no bytes, `.complete`
  attribute) before any chunk write; order pinned by the shared call log in
  `testCreateProtectedFileRunsBeforeFirstWrite` (create → verify → stream →
  verify, and every writeChunk event records `existed=true`).
- `testStagingDoesNotUseCopyItem`: source scan over
  `InstructionVideoStore.swift` (`FeatureSourceScan.codeText`) asserts zero
  `copyItem` — confirmed by grep, 0 occurrences.
- Weaker-class-at-creation and weaker-class-after-stream both delete the
  partial file and the draft directory before returning
  `.writeFailed(.protectionFailed)`.
- Mid-stream write/read failures, cumulative cap breach and truncation all
  delete the partial file and the draft directory.
- Kill-window note recorded in the suite's doc comment (§5.3).

## R-5 implementation points

- The seam returns `FileProtectionType?`; the store fails closed only on a
  *reported* class weaker than `.complete`, and proceeds when the platform
  reports none. `testUnreportedClassIsTolerated` pins success with both
  attribute reads recorded as `nil` (unknown, not invented);
  `testWeakerClassAtCreationDeletes` / `testWeakerClassAfterStreamFailsAndDeletes`
  pin the fail-closed side. `commit` applies the same rule to the moved file.

## Verification performed (no build)

- Brace/paren/bracket balance check (lexer-aware, string contents excluded):
  all three files BALANCED, no close-before-open.
- `git status --short`: only the three owned paths changed by this unit —
  `NoIOInInitTests.swift` shows only my 56-line insertion (the index version
  was untouched by others); the two Instructions directories are untracked
  and contain my two new files alongside the other in-flight units' files.
  All other modified files pre-exist from parallel units.
- `grep -c copyItem` on the store: 0.
- All 17 test names present exactly once.
- `FileManager.default` in the store appears only inside
  `SystemInstructionStagingFileOps`; no `print`/`NSLog`/`os_log` anywhere.

## Decisions made

- **Source-pin drift (E.1):** the design's pin wording is `.completeFileProtection`
  — the `Data.WritingOptions` constant. The create-then-stream seam creates
  with `createFile(attributes: [.protectionKey: .complete])` (the
  `FileProtectionType` value, as §5.3 itself specifies), never `data.write`,
  so the token `.completeFileProtection` legitimately never appears in the
  store. `testCreateProtectedFileRunsBeforeFirstWrite` pins
  `FileProtectionType.complete` (3 occurrences: staging create + both
  directory creates) and records the reason in the test comment.
- **`.purgeFailed` partial count:** §5.5 says "returns `.purgeFailed` with the
  count of what was removed", but the fixed §3.3 case set has no payload. The
  store stops at the first failed removal and returns `.failure(.purgeFailed)`;
  the enum's doc comment states the partial count is not carried. T-025's
  coordinator event (`instruction_orphan_purge`, count on failed outcomes)
  may need to align on this.
- **Owner-name guard testability (N-1):** `InstructionOwner.directoryName` is
  safe by construction (UUID string / `ev-` + hex), so the public API can
  never reach `.invalidOwner`. The guard lives in an internal
  `ownerDirectoryURL(named:in:)` that every public method routes through, and
  the test trips it directly (plus the filename-refusal rows for
  delete/availability/fileURL with zero FileManager calls).
- **Two extra tests beyond the 17** (this suite is 100% owned by T-002 and the
  design assigns these rows to it): `testPreStagingRejectionsLeaveNothingBehind`
  (§11.3 A — absent URL, directory URL, probe-refused, 180.5 s refused,
  exactly 180 s accepted, zero staging calls for all rejections) and
  `testAvailabilityReportsAllFourClasses` (§11.3 D — available/missingFile/
  unreadableFile/rejectedFilename). No name collisions with any other unit.

## Risks / open items for the coordinator

- **REQUIRED FOLLOW-UP — duplicate enum:** `InstructionVideoInspecting.swift`
  still contains the T-001 TEMPORARY placeholder `InstructionStorageError`.
  The final declaration in the store file has the identical case set, but two
  declarations of one type will NOT compile. The coordinator must delete the
  placeholder block (lines marked "TEMPORARY PLACEHOLDER — T-001 only")
  before/with this unit's build. I did not touch that file (outside my
  ownership).
- **Untested branches:** `createProtectedFile` returning false
  (`.writeFailed(.stagingFailed)`) and `discard` are implemented but not
  covered by a named test (not in the 17; the cleanup helper they share is
  exercised by the failure tests). The store's `commit` weaker-class branch
  (§5.4 step 6) is implemented but its dedicated case was not in this unit's
  list either.
- **No build/typecheck was run** (coordinator owns verification). Everything
  above is from careful reading plus delimiter-balance and grep checks.
  Swift 5.9 mode, so `@unchecked Sendable` classes and `NSLock` are fine; the
  staging spy conforms to the `Sendable` seam with all-Sendable stored state.
- The pending purge's grace comes from
  `InstructionVideoConfiguration.standard.orphanGraceSeconds` (60 s, design
  §5.5) — IF-11 has no grace parameter by design.
