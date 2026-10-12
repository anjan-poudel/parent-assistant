# T-147 — Frozen L10n keys (21, en+ne), coverage pins and NSContactsUsageDescription — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`, base 804e7645). Unit: TG-29; Agent: dev;
Effort M; Risk MEDIUM. Requirements: FR-FCU-009, NFR-FCU-002, NFR-FCU-004.
Design references: design-l2 §7 (`:1176-1257` — frozen copy, placement, pins),
§8.2 (`:1288-1289` placement table); plan amendment 1 (the T-144 gate narrowed
to the shared surfaces — this unit's files are file-disjoint and unblocked).

## Status

**Done.** 21 frozen keys landed en+ne, the `NSContactsUsageDescription`
disclosure replaced, `L10nCatalogCoverageTests` extended with the pins. Gate per
the 2026-10-12 owner speed-mode directive: the scoped suite run is **deferred to
phase end (T-163)**; the whole-module typecheck ran instead and is green. No
push.

## Files changed

- `ios/ElderlyAssistant/Resources/Localizable.xcstrings` — +357 lines, 0
  deletions (insertion-only; verified via `git diff --numstat`): 19 new
  `family.*` keys + the 2 `call.search.*` keys, in the catalog's canonical
  format (`extractionState: manual`, both localizations `translated`).
- `ios/ElderlyAssistant/Info.plist` — `NSContactsUsageDescription` replaced
  (1/1) with the design-l2 §7 frozen disclosure: read/search + the photo write
  + its limit + the honest no-permission state. No new usage keys.
- `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift` — +706/-2:
  the T-147 sections (2 MARK blocks, 7 tests, 2 pure check functions, 5
  helpers) plus the deliberate dialogue-baseline bump.
- `specs/T-147-notes.md` (this file).

## Key-count delta (recorded deliberately — acceptance criteria: no stale pin, no guessing)

- Measured on this tree immediately **before** the insertions: **1,389** keys
  (JSON parse of the catalog; the existing dialogue pin measured the same
  tree).
- **After** the 21 insertions: **1,410**. Delta **+21** — the constant; the
  absolute is re-measured, never guessed.
- New pin: `familyContactsBaselineKeyCount = 1_389`, asserted as
  `count == 1_389 + 21`.
- Dialogue pin updated deliberately: `dialogueBaselineKeyCount` 1_370 → **1_391**
  (1_391 + 19 = 1_410), with the delta recorded in the comment chain.
- The T-144 call-dialer merge was still open at implement time and its design
  adds its own settings keys (`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md:142`).
  The rebase re-measures this absolute deliberately; the obligation is recorded
  in the test comment next to the pin.
- Pre-existing drift found and **not** touched: `SpotifyLocalizationTests` pins
  `catalog.count == 1361 + 20 = 1381`, but the tree already held 1,389 keys
  before this unit (1,410 after) — that suite's count test is red at HEAD
  independent of this unit (8 keys landed in post-Spotify merges without the
  deliberate bump). It is outside this unit's file set; flagged here for
  T-163 / a later rebase.

## What was built

### 1. The 21 frozen keys (design-l2 §7), exact placement

Structure: 8 `family.link.*`, 4 `family.nickname.*`, 7 new `family.photo.*`
merged with the 3 pre-existing, 2 `call.search.*` insertions.

Placement, verified in-file before the commit (and pinned by the tests):

- before the pre-existing `family.photo.add`: the 12 `family.link.`/
  `family.nickname.` keys in alphabetical order, then
  `family.photo.accessBody`, `family.photo.accessDeniedBody`,
  `family.photo.accessTitle`;
- after `family.photo.remove`: `family.photo.sourceSystem`,
  `family.photo.state.keptOnPhone`, `family.photo.state.systemPhotoRemains`,
  `family.photo.state.updatedInSystem`;
- `call.search.accessLimited` directly BEFORE `call.search.allowBody` (after
  `call.openWhatsAppContacts`); `call.search.linkedBookName` between
  `call.search.familyChip` and `call.search.loadFailed`.

The 22-line span between `family.emergencyToggleHint` and
`family.relationship.brother` (both excluded) is exactly design §7's corrected
list 1–22, with the pre-existing `family.photo.add/change/remove` at positions
16–18.

Copy: extracted **programmatically** from the design file's frozen table (no
hand transcription), which also let the placeholder rule be audited before the
edit: exactly four keys carry one `%@`
(`family.link.linkedTo`, `family.link.alreadyLinked`,
`family.nickname.removeLabel`, `call.search.linkedBookName`); no other key
carries any `%`. Every `ne` value is pure Devanagari except key #16's
deliberate romanized example ("sanu", the store-as-entered showcase), which is
the single documented exception in the coverage function.

### 2. `App/L10n.swift` — no change needed (pattern checked first)

The house accessor pattern is plain key-string resolution — `L10n.str(key,
locale:)` for non-View code, `Text("key")` in views — with **no per-key
registration table** in `L10n.swift`. The new keys therefore require no code
change; consumers arrive with T-159…T-162.

### 3. Test pins (`L10nCatalogCoverageTests`)

- `testEveryFamilyContactsKeyResolvesInBothLanguages` — the behavioural half:
  all 21 resolve through the shipped lproj bundles in en and ne, non-empty,
  values differ, ne Devanagari.
- `testTheFamilyContactsFamilyPassesTheCoverageCheck` — the source half: the
  count pin (1,389 + 21), the coverage check over the parsed catalog, and the
  value pins on the `call.search.*` insertion neighbours.
- `testTheCoverageCheckFailsNamingTheMissingFamilyContactValue` — 11 fixtures,
  each a one-rule mutant of the parsed catalog: ne removed, en removed, entry
  removed, blank ne, en copied into ne, placeholder dropped, stray `%` in a
  non-format key, ASCII in an unexempted ne, stray `family.link.*` key, stray
  `family.photo.*` key, and the count-pin delta semantics.
- `testTheSpanCheckFailsOnAMovedOrSmuggledFamilyContactsKey` — 3 fixtures over
  the raw key-line array: a moved key, a swapped `call.search.*` neighbour, and
  an unpinned key smuggled into the span. The check itself rejects each mutant,
  so the contiguity rule is gate-enforced, not merely asserted.
- `testTheFamilyContactsBlockSitsContiguouslyBetweenItsNeighbours` — the real
  file: the exact 22-line span plus the two named `call.search.*` neighbour
  pairs.
- `testTheFamilyContactsCopyMatchesTheDesignFrozenTableVerbatim` — the
  `familyContactsCopy` table equals the design §7 rows verbatim, both
  languages, and the table order equals the pinned inventory.
- `testOnlyTheNicknamesPlaceholderCarriesASCIIInNepali` — the #16 exemption is
  pinned as *exactly* the romanized example: the value must contain "sanu",
  stripping it must leave no ASCII, and every other key's ne must be ASCII-free
  (the ONLY permitted carrier).
- `testTheFamilyContactsPlaceholderRuleHoldsInBothLanguages` — the four
  placeholder keys carry exactly one `%@`, other keys carry none, both
  languages agree.
- `testTheContactsDisclosureStatesReadingAndThePhotoWrite` — the plist string
  equals the frozen copy verbatim, the old read/search-only string is gone, the
  read and write uses + the limit + the no-permission state are present, and
  the string is English-only (accepted security residual; no Info.plist
  localisation).
- `testThePlistAddsNoNewUsageDescriptionKeys` — the 12-key usage-description
  set is pinned, and no write-only contacts descriptor may appear (the designed
  write seam needs read-and-write access).
- Pure functions `familyContactsCoverageFailures(in:)` and
  `familyContactsSpanFailures(in:)` carry the rules so every failure path runs
  against fixtures (the dialogue suite's discipline).

### 4. Decisions

- `familyContactsKeys` is in **design table order 1..21** (not catalog order),
  so the copy table maps 1:1 to the design rows; the 22-line span array is kept
  separately in file order.
- The disclosure is pinned **verbatim** against the design's frozen text; the
  string written to the plist was verified equal to the extracted design text
  at edit time.
- The `family.photo.*` stray rule pins the family as the 10 = 3 pre-existing +
  7 new; `family.link.`/`family.nickname.` are wholly new namespaces, so any
  unpinned key there fails.
- No refactor of the dialogue half beyond the baseline bump (kept the diff
  scoped); the raw key-line scan is shared into one helper for the new tests.

## Gate results

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project
  seniOS.xcodeproj -scheme ElderlyAssistant -destination 'platform=iOS
  Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18' -derivedDataPath
  build/DerivedDataTests -skip-testing:ElderlyAssistantUITests` →
  `** TEST BUILD SUCCEEDED **`, `COMPILECHECK_EXIT=0`, with the log showing the
  `SwiftCompile … L10nCatalogCoverageTests.swift` task for the final content
  (app + unit + UI test bundles compiled; log kept at
  `ios/build/t147-typecheck2.log`, gitignored). Zero warnings attributable to
  the changed file (the 11 warnings in the log are pre-existing, in other
  files).
- **Scoped `L10nCatalogCoverageTests` run: deferred** to phase end (T-163) per
  the coordinator's speed-mode directive.
- Additional static verification before the commit: every coverage rule and the
  span/neighbour arithmetic replicated over the real catalog in Python — zero
  failures; catalog count 1,410; plist string == design frozen copy; usage-key
  set == the pinned 12; catalog diff insertion-only.

## Risks / open items

- The absolute baseline pins depend on the T-144 merge happening before
  phase-end acceptance; the deliberate re-measure obligation is recorded in the
  test comment (the +21 delta is the constant).
- `SpotifyLocalizationTests` count pin is pre-existing red at HEAD (see above).
- The `L10n.str` resolution half runs only at the phase-end gate; the lproj is
  generated from this same catalog at build time (no independent risk
  identified).
