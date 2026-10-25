# T-001 — Instruction model, configuration, filename guard and inspection seam

## What was built

Five files, exactly the unit's owned paths:

- `ios/ElderlyAssistant/Services/Instructions/Instruction.swift`
  - `InstructionKind` (`text` / `image` / `video`; raw values are the locked stored vocabulary; `reportable(_:)` maps unknown raw values to `unknown`).
  - `Instruction` — the stored wire model with a raw `String` kind (must-carry B-2: a stored text instruction keeps exactly `text`). Tolerant decode: every field uses `try? decodeIfPresent`, so a wrong-typed or missing field becomes `nil` (missing/wrong kind becomes `""`); unknown fields are ignored; encode omits nil fields.
  - `knownKind`, `isPresent` (IF-1 rules of design §3.4.1), `trimmedText`, `trimmedCaption`.
  - `InstructionPayload` (validated enum kind; `instruction` trims text/caption and nulls fields the kind cannot carry), `InstructionWrite`, `InstructionRoot`, `InstructionOwner` (routine UUID / event SHA-256 digest), `InstructionVideoDuration` (rounds to nearest away from zero; inclusive 180 s boundary).
- `ios/ElderlyAssistant/Services/Instructions/InstructionConfiguration.swift` — `InstructionVideoLimits`, `InstructionVideoConfiguration`, `InstructionRecordingQuality`, `InstructionCaptureConfiguration`, all `.standard` defaults exactly per design §9.1.
- `ios/ElderlyAssistant/Services/Instructions/InstructionFilename.swift` — `isPlain` (non-empty, not `.` / `..`, no `/` or `\`) and `sanitizedExtension` (1–8 lowercase alphanumerics else `mov`).
- `ios/ElderlyAssistant/Services/Instructions/InstructionVideoInspecting.swift` — `InstructionVideoMetadata`, `InstructionVideoProbing` (IF-13), `InstructionVideoInspecting` (IF-14), `InstructionImportError`, `AVInstructionVideoProber`, `AVInstructionVideoInspector`, plus the temporary `InstructionStorageError` placeholder (below).
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionModelTests.swift` — the 12 named cases.

No draft/commit types, stores, views, copy keys, notifications or logging. No IO beyond the two inspection methods (read-only file checks plus AVFoundation metadata); neither method copies bytes or creates a file.

## InstructionImportError shape

```swift
enum InstructionImportError: Error, Equatable {
    case unreadableSource
    case unsupportedFormat
    case tooLong
    case tooLarge
    case validationTimedOut
    case writeFailed(InstructionStorageError)
    case cancelled
}
```

Exactly the seven design §3.3 cases.

## InstructionStorageError

It did **not** pre-exist in the worktree (a grep over `ios/` for the symbol returned nothing). Because `InstructionImportError.writeFailed` carries it, a placeholder is declared in `InstructionVideoInspecting.swift` with the six design §3.3 cases: `invalidOwner`, `stagingFailed`, `protectionFailed`, `commitFailed`, `deleteFailed`, `purgeFailed`.

Deviation from the dispatch note: the note listed five cases and omitted `purgeFailed`; all six are included because design §3.3 is authoritative and T-002 must not lose `.purgeFailed` when it moves the declaration. The block is marked TEMPORARY in-source.

**Coordinator action:** when T-002 lands `InstructionStorageError` in `InstructionVideoStore.swift`, delete the placeholder block from `InstructionVideoInspecting.swift`.

## Tests (12 named cases, exact names)

`InstructionModelTests`:

1. `testRawKindTextImageVideoRoundTrip` — raw kind verbatim, value equality, payload normalization, no invented media fields.
2. `testIsPresentRequiresNonBlankText` — text/image/video/blank/unknown presence rules and `reportable`.
3. `testTolerantDecodeIgnoresUnknownFields` — unknown fields ignored and dropped on encode, wrong-typed field becomes nil, unknown kinds verbatim.
4. `testMissingKindDecodesAsAbsent` — missing and wrong-typed kind decode to blank with `isPresent == false`.
5. `testCaptionIsOptional` — nil caption omits the key; a stored caption is preserved verbatim; trimmed accessor.
6. `testOwnerRootsAreDisjoint` — `InstructionVideos` / `EventInstructionVideos`, UUID directory, cross-kind disjointness.
7. `testEventOwnerUsesLowercaseSHA256Hex` — known answer `ev-ce36863f51b6baf9d16397ffb3e9af50` for `event-1`, `^ev-[0-9a-f]{32}$`, 35 characters, distinct ids differ.
8. `testDurationRoundsUpAtTheInclusiveBoundary` — exactly 180 accepted, 180.2 rounds to 180 and is accepted, 180.5 rounds to 181 and is refused, non-finite exceeds.
9. `testFilenameGuardRejectsTraversalAndEmptyNames` — empty / `.` / `..` / separators / absolute names refused; plain names accepted; extension sanitizer cases.
10. `testConfigurationDefaultsMatchDesign` — 180 / 209_715_200 / 20 / 60 / 1_048_576 / `.high`.
11. `testProbeRejectsMissingSource` — missing, directory and remote URLs give `unreadableSource`; a readable empty file gives `unsupportedFormat`.
12. `testInspectRejectsNonVideo` — a generated audio-only WAV (real media, no video track) gives `unsupportedFormat` on both the async and synchronous paths; a missing source gives `unreadableSource` without throwing.

Gherkin coverage: scenario 1 by tests 1/2/5; scenario 2 by tests 3/4; scenario 3's inspection half by test 12, with test 8 pinning the over-long boundary. The `.tooLong` emission itself belongs to T-002's store.

## Verification performed (no project build)

- `xcrun swiftc -parse` over all five files: clean.
- `xcrun swiftc -typecheck` over the four source files (iOS 17 simulator target): clean, with only the three AVFoundation deprecation warnings the design explicitly accepts (design §2.3 rule 1, OI-2: `isPlayable`, `duration`, `tracks(withMediaType:)`).
- Emitted a temporary `-enable-testing` module from the four files under `/tmp` and typechecked `InstructionModelTests.swift` against it: clean. The scratch module was removed afterwards.
- The scoped XCTest run itself was **not** executed (per dispatch: no `./build.sh` or `xcodebuild`; the coordinator regenerates the project and runs `-only-testing:ElderlyAssistantTests/InstructionModelTests`).

## Implementation decisions

- `InstructionWrite` is included: it is part of the §3.4 value layer, depends only on `InstructionPayload`, and is not in the T-003 forbidden list (`InstructionDraft`, `InstructionPendingMedia`, `InstructionCommit` are absent).
- `InstructionVideoDuration` lives in `Instruction.swift` because the §3.4 declaration block places it there.
- A missing/blank kind decodes to `""` and `isPresent` is `false` even when text is present (the dispatch's rule); unknown non-blank kinds keep the forward-tolerance rule.
- `sanitizedExtension` lowercases before validating, so a recorder's `MOV` keeps `mov` instead of falling back.
- `roundedSeconds` returns `Int.max` for non-finite or unrepresentably large input to avoid an `Int(Double)` trap; `exceedsLimit` treats non-finite input as exceeding. The probe maps a non-finite duration to `.unreadableSource` before any limit check.
- AV failure mapping: not a file URL / absent / directory / unreadable gives `.unreadableSource`; not playable or no video track gives `.unsupportedFormat`; non-finite duration gives `.unreadableSource`; a thrown async load gives `.unreadableSource`. No `NSError` escapes.
- The prober and inspector deliberately do **not** enforce the 180 s cap; the store does (design §5.2 step 3).
- Tests generate their audio-only media as a deterministic PCM WAV in the per-test temporary directory; there are no fixture files.

## Coordinator notes / possible issues

- Remove the temporary `InstructionStorageError` block when T-002 lands (duplicate-symbol risk).
- Project regeneration is required so xcodegen picks up the two new directories; the test target's `ElderlyAssistantTests` glob already includes them.
- Deprecation warnings are expected and accepted; the target has no warnings-as-errors.
- `InstructionVideoMetadata`, `InstructionImportError` and `InstructionStorageError` are not `Sendable`; fine under Swift 5.9 (no strict concurrency). If a later unit enables Swift 6 strict concurrency, add `Sendable` to the metadata and error types.
- `testInspectRejectsNonVideo` depends on AVFoundation parsing a linear-PCM WAV on the simulator (standard); if that ever misbehaves, the result is `.unreadableSource` and the assertion localises it.
