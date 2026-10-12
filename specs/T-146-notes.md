# T-146 — ContactPhotoStore byte access and unlink copy helper — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`, base dfebaf0e). Unit: TG-29; Agent: dev;
Effort S; Risk LOW. Requirements: FR-FCU-007, FR-FCU-010, NFR-FCU-006.
Design references: design-l2 §8.2 placement table (`:1283`), §1.9 `loadData`
contract (`:498-503`), §5.1 byte-level guarantee (`:1055-1058`), §5.2
logging rules (`:1068-1071`).

## Status

**Done — unit gate green (scoped suite + whole-module build).** No new files;
two files changed (the store and its suite). No `.ai-sdd/` touch, no push.

## Files changed

- `ios/ElderlyAssistant/Services/Storage/ContactPhotoStore.swift` — added
  `processedJPEG(_:)` (static), `loadData(named:)`, `copy(named:)`; `save(_:)`
  refactored to consume `processedJPEG`.
- `ios/ElderlyAssistantTests/Services/Storage/ContactPhotoStoreTests.swift` —
  9 new test methods (7 pre-existing kept unchanged).
- NEW `specs/T-146-notes.md` (this file).

## What was built

### 1. `static func processedJPEG(_ image: UIImage) -> Data?` — the single preprocessing seam

`scaledForStorage` (≤512px longest edge, orientation baked, metadata stripped)
→ `jpegData(compressionQuality: jpegQuality)`. `save(_:)` no longer encodes on
its own: it guards on `Self.processedJPEG(image)` and writes those exact bytes,
so no second encoding path can drift (§8.2 "static extraction: `scaledForStorage`
→ `jpegData`; `save` refactored to call it — byte-identical output").

Non-throwing, `nil` on unreadable input. The usable-bitmap guard is the house
form from `VisualAidStore.jpegData` (`size` positive and `cgImage != nil ||
ciImage != nil`); it is what makes an empty/corrupt image fail clean instead of
reaching a zero-size renderer — the FR-FCU-010 fallback signal. For every input
the old save path could encode, the code path is unchanged.

### 2. `func loadData(named filename: String?) -> Data?` — exact stored bytes

`Data(contentsOf:)` on the stored file, behind the existing plain-filename
guard; `nil` when the name is missing/unsafe or the file is absent/unreadable
(including a protected file while locked). No decode and no re-encode, so the
bytes handed to the T-154 read-back comparison and the T-158 unlink copy are
byte-identical to the bytes the app holds (§1.9). Never throws. The store has no
console writes at all (existing state, now pinned), so no file name can reach a
log line — greppable, test-enforced PII discipline rather than a promise.

### 3. `@discardableResult func copy(named filename: String?) -> String?` — unlink copy helper

Copies an existing stored file to a NEW `<uuid>.jpg` name and returns that name;
`nil` when the source is missing/unsafe or the write fails — non-throwing, so
the unlink path can treat `nil` as "do not clear the link" (never lose). Bytes
are copied verbatim (read → `.atomic, .completeFileProtection` write), so the
copy is byte-identical and protected like any other stored file; the original is
untouched.

**Decision (design gap, logged):** the design doc names only
`processedJPEG(_:)` and `loadData(named:)`; the unit spec mandates "the copy
helper" by behaviour, not by signature. `copy(named:) -> String?` was chosen
because it mirrors `save(_:) -> String?` — the caller receives the file name to
assign to `photoFilename` (the F3 pin), and internal UUID naming keeps the
"contact stores only a bare file name" invariant. If T-158's flow needs to
persist raw system bytes that are not yet a store file, that is a separate write
seam concern (T-154), not a second copy path here.

## Gherkin coverage (all scenarios automated)

| Scenario | Test |
|---|---|
| processedJPEG → JPEG that loadData returns byte-identical | `testProcessedJPEGIsByteIdenticalToTheStoredFile` |
| Same input twice → byte-identical (deterministic) | `testProcessedJPEGIsDeterministicAcrossCallsAndSaves` (two calls + two separate saves, JPEG SOI/EOI markers pinned) |
| Seam carries the full preprocessing (downscale) | `testProcessedJPEGAppliesTheStorageDownscale` |
| loadData returns the exact bytes written at store time | `testLoadDataReturnsTheExactBytesOnDisk` (compared against the raw file on disk) |
| Copy → new file byte-identical, original untouched | `testCopyProducesAByteIdenticalNewFileAndLeavesTheOriginalUntouched` |
| Missing file → nil, no throw/crash | `testLoadDataMissingUnsafeNamesReturnNilWithoutCrash`; failed copies create nothing: `testCopyFailsSoftOnMissingUnsafeNamesAndCreatesNothing` |
| No log line contains the filename (PII) | `testStoreSourceHasNoConsoleWrites` (FeatureSourceScan source pin: zero console/log writes in the store) |
| Unreadable input → clean nil (FR-FCU-010) | `testCorruptInputFailsCleanlyForTheFallbackPath` (garbage bytes cannot decode; bitmap-less `UIImage` → nil through `processedJPEG` and `save`) |

## Gate results (focused gate, as specified)

1. Scoped suite — `./build.sh test:unit ContactPhotoStoreTests`, which runs the
   house privacy guards (release log-safety, prompt mirror) then
   `xcodebuild test … -only-testing:ElderlyAssistantTests/ContactPhotoStoreTests`
   against an iPhone 16 Pro simulator: **16 tests executed, 0 failures**
   (7 pre-existing pins unchanged + 9 new), `** TEST SUCCEEDED **`, exit 0.
2. Whole-module typecheck/build — `xcodebuild build -scheme ElderlyAssistant
   -destination 'platform=iOS Simulator…' -configuration Debug` over the current
   sources: `** BUILD SUCCEEDED **`; re-verified with a forced recompile of the
   touched file (`SwiftCompile … ContactPhotoStore.swift (in target
   'ElderlyAssistant')`, exit 0).

The full unit bundle was deliberately NOT run (known pre-existing baseline
failures; house rule is focused gates).

## Determinism evidence

Two `processedJPEG` calls on the same input are byte-equal, and two separate
`save(_:)` writes of the same input land byte-identical files (asserted in
`testProcessedJPEGIsDeterministicAcrossCallsAndSaves`, including the JPEG
SOI/EOI markers). This is the pin the write-seam read-back equality (T-154)
depends on.

## Deviations / findings

- **Deviation from the unit spec: none.**
- PII: the store logs nothing — no filename (or any other value) can appear in
  a log line; pinned by a source scan over the production file.
- No new network egress; local file store only (NFR-FCU-003 unaffected).
- No new L10n keys, no guard-config changes, no project.yml change (no new
  files, so no XcodeGen regeneration needed).
- Design-gap decision recorded above (copy helper signature).
