# T-019 notes — Instruction copy catalogue (36 keys, en + ne)

## What was built

### 1. Catalogue (`ios/ElderlyAssistant/Resources/Localizable.xcstrings`)

The 36 `instruction.*` keys from design-l2 §10.5 were inserted as ONE
alphabetically sorted contiguous block between `homeTimer.stop` and
`intentLog.clear`. The copy was extracted programmatically from the design
table (rows 1972–2007), so English and Nepali values are byte-verbatim
(straight apostrophes U+0027, ellipsis U+2026, Devanagari digits ३, Nepali
danda ।). Each entry follows the neighbouring manual-entry shape exactly:
`"extractionState": "manual"`, `en` + `ne` stringUnits, both
`"state": "translated"`. Only `instruction.atTimeFormat` carries a
placeholder ("At %@" / "%@ बजे", one `%@` each).

Block order (the catalogue's convention is case-insensitive within blocks;
for this family byte-order and case-insensitive order agree because no two
keys differ only in letter case):

add, atTimeFormat, camera.denied, camera.unavailable, change, done,
foregroundNote, image.accessibility, image.change, image.unavailable,
kind.image, kind.text, kind.video, microphone.denied, reminderUnavailable,
remove, removed, saveFailed, savePartial, textPlaceholder, title,
unsupported, useVideo, video.accessibility, video.add, video.change,
video.play, video.preparing, video.record, video.recordingLimit,
video.saveFailed, video.tooLarge, video.tooLong, video.unavailable,
video.unreadable, video.validating.

Note: `instruction.video.record` sorts before
`instruction.video.recordingLimit` because "." (U+002E) sorts before
letters — the same convention the file already uses for dot-continuations
(e.g. `settings.gemini.model.flash` then `flash.desc` then `flashLatest`).

Verified deltas vs HEAD: 612 lines added, 0 removed; JSON diff shows 36
keys added, 0 removed, 0 changed. Total 1,498 → 1,534 keys.

### 2. Coverage tests (`ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift`)

New pinned data: `instructionKeys` (36), `instructionCopy` (36 verbatim
pairs), `instructionForbiddenTokens` (technical-token ban),
`instructionBaselineKeyCount = 1_498`, and the pure
`instructionCoverageFailures(in:)` source check (unpinned/missing keys,
`manual` extraction state, both units `translated`, non-empty values,
Devanagari Nepali with no ASCII letters, en != ne, and the placeholder
rule: exactly `instruction.atTimeFormat` carries one `%@`, no other key
carries any `%`).

The 8 test cases, exact names:

- testEveryInstructionKeyResolvesInBothLanguages
- testInstructionFamilyPassesCoverageCheck (asserts 1_534 = 1_498 + 36,
  plus the homeTimer.stop / intentLog.clear neighbour value pins)
- testInstructionCopyIsPinnedVerbatim
- testInstructionPlaceholdersMatchBetweenLanguages
- testInstructionKeysAreAlphabeticallyContiguous (raw-file key-line scan;
  predecessor `homeTimer.stop`, successor `intentLog.clear`)
- testInstructionFamilyHasNoCodesOrFilenames (pinned token list asserted
  non-empty + code-shape `\b[A-Z]{2,}\d{2,}\b` and extension-shape
  `[a-zA-Z]+\.[a-zA-Z]{1,4}\b` probes; findings collected and asserted
  empty with per-key messages)
- testReminderUnavailableAndForegroundNoteArePresentInBothLanguages
  (L10n resolution both languages + verbatim pin of both behaviour-bearing
  keys)
- testAtTimeFormatPlaceholderCounts ("At %@" / "%@ बजे", exactly one `%@`
  each, en hasPrefix "At ", ne hasSuffix "बजे")

Shared-count repair (as instructed, +36 each, one-line comment):

- dialogueBaselineKeyCount 1_465 → 1_501
- callingBaselineKeyCount 1_479 → 1_515
- familyContactsBaselineKeyCount 1_461 → 1_497
- cloudChatBaselineKeyCount 1_466 → 1_502

## Test results

No xcodebuild (coordinator owns the simulator; another run is executing).
All eight tests were instead simulated against the edited files with a
Python mirror of their logic:

- raw key-line scan: 1,532 key lines; the 36 instruction keys occupy
  indices 515–550 contiguously, exactly matching the pinned list, with
  `homeTimer.stop` before and `intentLog.clear` after → contiguity test
  would pass.
- coverage rules: manual/translated/non-empty/Devanagari/no-ASCII/
  en != ne/placeholder contract → no failures → family-pass test would
  pass.
- forbidden tokens + both shape probes over all 72 values → no findings.
- resolve simulation: every key non-empty in both languages, en != ne,
  Nepali Devanagari or placeholder-only.
- delimiter balance of the edited Swift file with literals stripped:
  braces/parens/brackets balanced.

## Verification commands and results

- `python3 -c 'import json; ...'` over the catalogue: total keys 1534,
  `instruction.*` keys 36, every instruction key has non-empty en/ne
  values and equal `%@` counts. PASS.
- `git -C <worktree> diff --numstat` on the two owned files:
  612/0 for the catalogue, 481/4 for the tests (the 4 removals are the
  replaced baseline-constant lines). No other file touched by this unit.
- JSON comparison of HEAD vs edited catalogue: 36 added, 0 removed,
  0 changed → no pre-existing key altered.

## Decisions and observations

1. Sort order: the 36 keys sort identically under byte-order and
   case-insensitive comparison (no case-only-differing pair), and the
   dot-before-letter rule matches the file's existing convention, so the
   pinned alphabetical order is unambiguous.
2. Pre-existing drift, NOT a T-019 regression: the four whole-catalogue
   baseline pins were already 14–16 below the actual 1,498-key tree before
   this unit (they asserted 1,484 / 1,484 / 1,482 / 1,484 against 1,498).
   The instructed +36 keeps that pre-existing gap unchanged (now 1,520 /
   1,520 / 1,518 / 1,520 against the new 1,534). The instruction family
   pass test pins the exact 1,534 = 1,498 + 36. Whoever owns the master
   rebase of those four pins should re-measure them against the actual
   tree; this unit followed the explicit +36 instruction and did not touch
   any other family's keys, copy pins or assertions.
3. The usage descriptions (Info.plist / InfoPlist.strings) were not
   touched — T-020 owns them.
4. No source file references the new keys yet; that is expected and stated
   in the task (catalogue entries are inert until later units).

## Deviations from spec

None.
