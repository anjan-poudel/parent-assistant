# T-005 — Instruction image loaders and filename guard reuse

## What was built

Exactly the unit's three owned paths:

- `ios/ElderlyAssistant/Services/Instructions/InstructionImageLoading.swift`
  - `InstructionImageFailure: Error, Equatable` — the three design §3.3 cases exactly: `.rejectedFilename` (bare-name guard refused), `.missingFile` (absent), `.unreadableFile` (present but undecodable). No `NSError` can escape; the surface maps every case to the one plain `instruction.image.unavailable` line.
  - `@MainActor protocol InstructionImageLoading` — IF-21: `func loadImage(filename: String) -> Result<UIImage, InstructionImageFailure>`.
  - `@MainActor struct VisualAidInstructionImageLoader: InstructionImageLoading` — `init(store: VisualAidStore, entryId: UUID)`. Routine instruction images live in the entry's `VisualAidStore` directory (design D3, §5.8). Load order: `InstructionFilename.isPlain` guard (before any store call) → `store.existingFileURL(_:for:)` for the existence probe (absent → `.missingFile`) → `store.load(_:for:)` for the decode (nil → `.unreadableFile`).
  - `@MainActor struct EventPhotoInstructionImageLoader: InstructionImageLoading` — `init(store: ContactPhotoStore)`. Event instruction images live in the same flat event-photo store as the event's own photo. Load order: guard → `store.loadData(named:)` (nil → `.missingFile`) → `UIImage(data:)` (nil → `.unreadableFile`).
  - No photo-library, picker, permission, network or logging symbol in the file (pinned by the source-scan test). No path or content is ever logged.

- `ios/ElderlyAssistantTests/Services/Instructions/InstructionImageLoadingTests.swift` — the 8 planned cases with their exact names (listed below). Both loaders are exercised on every behavioural row, per design §11.3 D ("the two loader rows").

- `ios/ElderlyAssistantTests/Services/Storage/VisualAidStoreTests.swift` — one appended regression, `testInstructionAndVisualAidImagesCoexist`. The diff is a single hunk: 43 insertions, 0 deletions; no existing test was rewritten or weakened.

## Planned tests (exact names, each defined exactly once)

`InstructionImageLoadingTests`:
1. `testLoadsStoredJPEG` — Gherkin scenario 1: a JPEG saved by each shipping store loads back through its loader with deterministic pixel sizes (40×30 routine, 50×20 event). The "no permission, no picker" half of the scenario is pinned structurally by test 8.
2. `testEmptyFilenameIsInvalid` — `""` → `.rejectedFilename` on both loaders. The routine loader runs over a `RecordingFileManager` spy and asserts **zero** `fileExists` probes — literal "the store is never consulted". The event loader's proof is the typed outcome: its store's own guard would collapse the name into a nil read, which the loader reports as `.missingFile`; only the loader's own guard can produce `.rejectedFilename`.
3. `testAbsoluteFilenameIsInvalid` — `"/tmp/instruction.jpg"`, `"/absolute.jpg"`, `"file:///tmp/x.jpg"` → `.rejectedFilename` on both loaders.
4. `testSeparatorFilenameIsInvalid` — `"a/b.jpg"`, `"a\\b.jpg"`, `"sub/dir/photo.jpg"` → `.rejectedFilename` on both loaders (a backslash is no escape hatch).
5. `testTraversalFilenameIsInvalid` — `"../planted-….jpg"`, `"..\\planted-….jpg"`, `"."`, `".."` → `.rejectedFilename` on both loaders. A real decodable JPEG is planted at the exact location each traversal name would resolve to: any read of it would have returned that image, so the `.rejectedFilename` outcome proves no read happened. The routine loader additionally asserts zero `fileExists` probes on a spy.
6. `testMissingFileReportsMissing` — a plain name that never existed → `.missingFile` on both loaders; the spy sees ≥1 existence probe, proving the guard really let the plain name through (the two paths are distinct).
7. `testUndecodableBytesReportDecodeFailed` — garbage bytes written at the stored path → `.unreadableFile` on both loaders: present on disk, refused by the decoder, never an invented image.
8. `testLoaderUsesNoPhotoLibraryAPI` — source pin over `InstructionImageLoading.swift` via the `FeatureSourceScan.codeText` idiom (comments stripped, strings preserved): the file contains none of `import Photos`, `import PhotosUI`, `PHPhotoLibrary`, `PHPicker`, `UIImagePickerController`, `PHAsset`, `PHImageManager`, `UIImageWriteToSavedPhotosAlbum`, `requestAuthorization`, `authorizationStatus`, `URLSession`, `Network`, `print(`, `NSLog`, `os_log`, `Logger(`. The scan fails loudly if the file is missing.

`VisualAidStoreTests` (extended):
9. `testInstructionAndVisualAidImagesCoexist` — Gherkin scenario 4: one entry saves a visual aid and an instruction image through the same `save(_:for:)` seam; the filenames differ and both files coexist in the entry directory; deleting the instruction image leaves the visual aid loadable (and the reverse direction on a second entry: deleting the visual aid leaves the instruction image loadable).

## Design decisions

- **Failure-type placement.** `InstructionImageFailure` lives in `InstructionImageLoading.swift` (C01's file for this seam): §3.3 tags it "C01/C08 — image decoding's failures", IF-21 is declared here, and T-018's dependencies reference it. No other unit owns it.
- **Distinguishing `.missingFile` from `.unreadableFile` without widening a shipping store (N-1).** The image stores collapse absent and undecodable into a nil read, and their API may not change (§5.8). The routine loader uses `VisualAidStore.existingFileURL` (a public existence probe that already exists for the notification seam) before `load`, so absent vs present-but-undecodable is distinguishable through public API only. The event loader reads bytes via `ContactPhotoStore.loadData` (its public read-back API) and decodes with `UIImage(data:)` — absent yields nil data → `.missingFile`; corrupt bytes decode-fail → `.unreadableFile`. Documented asymmetry: a file the OS cannot read at all (permissions) classifies as `.missingFile` on the event side and `.unreadableFile` on the routine side; both render the same plain fallback line, and the design's observable rows (absent, corrupt bytes) are pinned by tests 6–7.
- **Proof of "no file is read" for refused names.** For the routine loader, a recording `FileManager` subclass (the `EncryptedFileStorageProbeTests.FailingFileManager` idiom) counts `fileExists` probes — zero probes for refused names. For the event loader (no injectable FileManager in `Data(contentsOf:)`), the proof is behavioural: `.rejectedFilename` can only be produced by the loader's own guard, since the store's internal guard would collapse the same name into a nil read (→ `.missingFile`); a planted decodable JPEG at the traversal target would have returned `.success` had anything read it.
- **Guard reuse.** Both loaders call `InstructionFilename.isPlain` (the T-001 guard, byte-identical to the stores' private `isPlainFilename`) before any store call; the stores' own guards remain as belt-and-braces, unchanged.
- **@MainActor.** Protocol and both structs are `@MainActor` per design §7.1 ("decode + `UIImage`, the shipping pattern"). Tests annotate the individual methods that call the loaders (the `MedicationSavePlumbingTests` house idiom).

## Gherkin coverage

- Scenario 1 (stored JPEG loads; no permission, no picker): tests 1 and 8.
- Scenario 2 (empty/absolute/separator/traversal refused before a URL exists; no read): tests 2–5.
- Scenario 3 (missing → `missingFile`, non-image bytes → `decodeFailed`/`unreadableFile`; plain fallback): tests 6–7 (the plain line itself is T-018/T-019 copy).
- Scenario 4 (instruction image and visual aid coexist; removing one spares the other): test 9.

## Verification performed (no build, per dispatch)

- Read-back review of all three files; brace/paren/bracket balance check on the comment-and-string-stripped sources: all balanced.
- `git status --short --untracked-files=all` in the worktree: only the three owned paths changed (`?? InstructionImageLoading.swift`, `?? InstructionImageLoadingTests.swift`, `M VisualAidStoreTests.swift`); the `VisualAidStoreTests.swift` diff is one hunk, +43/−0.
- Grep over the whole `ios/` tree: each of the nine planned test names is defined exactly once; no other unit's file defines them.
- Forbidden-token grep over the production file: none of the photo-library/picker/permission/network/logging symbols present.
- No xcodebuild/swiftc run (coordinator owns verification; the scoped filter is `-only-testing:ElderlyAssistantTests/InstructionImageLoadingTests -only-testing:ElderlyAssistantTests/VisualAidStoreTests`).

## Risks / notes for the coordinator

- The event loader's `loadData`-based read is a deliberate reading of §3.5's prose over §5.8's table row (`load(named:)`): the table row lists the store's read API surface, while the prose requires absent vs decode-failure to stay distinguishable, which `load(named:)` alone cannot do. If the coordinator prefers strict table adherence, the alternative is collapsing event images to `.missingFile` — which would violate the three-case contract.
- The scan test asserts the loader file's location via the source tree; a missing file fails loudly rather than passing vacuously.
- The `RecordingFileManager` spy only observes `fileExists(atPath:)` (the store's read-path probe); other store methods do not touch it in this unit's paths.
