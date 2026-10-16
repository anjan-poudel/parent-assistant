# T-161 — CallView faces and caption (implement notes)

Feature: family-contacts-unify · Branch: feat/family-contacts-unify
Unit: TG-32 / T-161 · Mode: speed mode (implement + whole-module typecheck + commit only; scoped suite run and per-unit review deferred)
Production commit: `44846df3` — "T-161: CallView faces and caption — synthesized-row phone-book caption, .limited gate shape, published index+links" (3 files, +447/−24)

Note on filenames: the default `specs/T-161-notes.md` is the merged call-dialer
feature's record (PR #171); per the assignment this unit's notes live here.

## What was built

### 1. The synthesized-row caption (design-l1 §7.2 alt caption, §11.3 seam)

- `UnifiedContactResultRow` (private, `ios/ElderlyAssistant/App/LeafViews.swift`)
  gains `var caption: String? = nil` — deliberately `var` **with** a default,
  not `let`: Swift excludes `let`-with-default from the memberwise
  initializer, while `var` keeps the parameter defaulted, so every existing
  row construction (call-dialer's included) compiles untouched. This mirrors
  the house pattern (`RowChannelState.fellBackFrom`).
- The caption renders in `dialZone`'s VStack directly after the existing
  number-caption HStack, behind `if let caption {`: nil adds no line —
  today's layout exactly; non-nil renders one line (caption token, secondary
  color, up to 2 lines, leading).
- The composition lives in ONE pure seam, `enum CallResultRowText` (new,
  directly after the row struct):

  ```swift
  static func linkedBookCaption(for result: UnifiedContactSearch.Result,
                                in outcome: UnifiedContactSearch.Outcome,
                                locale: Locale) -> String? {
      guard let bookName = outcome.linkedBookNames[result.id], !bookName.isEmpty else {
          return nil
      }
      return L10n.fmt("call.search.linkedBookName", locale: locale, bookName)
  }
  ```

  Frozen key `call.search.linkedBookName` ("Also in your phone book as %@" /
  "फोनबुकमा %@ को रूपमा पनि छ", from T-147). The map is keyed by family result
  id, so only synthesized family rows can ever earn the caption — book rows
  cannot match a key by construction. An empty stored book name is
  suppressed rather than rendered as a dangling "…as ".
- `resultsArea` passes `caption: CallResultRowText.linkedBookCaption(for: result,
  in: outcome, locale: coordinator.activeLocale)` — the caption is composed
  from the SAME outcome the row renders, so it can never drift.

### 2. The T-148b gate shape (design-l2 §3.5 — six LeafViews sites)

Post-PR-#171 line drift re-mapped; all six obligations migrated:

| site | before | after |
| --- | --- | --- |
| `searchArea` field-row gate | `access == .allowed` | `access?.allowsReading == true` |
| `searchArea` display branches | binary allowed/other | readable block for `.allowed` **and** `.limited`; `} else if access == .denied {` stays the only blocked arm; `.notDetermined` ask arm untouched |
| `refreshDirectory()` | blocked unless `.allowed` | `guard status.allowsReading else { return }` |
| `grantAccess()` load condition | trusted binary `requestAccess()` result | re-reads `AddressBookDirectory.access()` then `if access?.allowsReading == true { … }`; `_ = await directory.requestAccess()` (the re-read, not the request result, decides — a sheet can yield `.limited`) |
| `micButtonVisible` | `access == .allowed` | `guard !micHidden, access?.allowsReading == true else { return false }` |
| `announceVoiceResultIfReady()` | `access == .allowed` | `access?.allowsReading == true` |

Whole file: zero `== .allowed` comparisons survive.

### 3. The honest `.limited` caption (design-l2 §3.5 placement)

In `searchArea`'s readable block, FIRST — directly under the field row and
above `micCaption` — when `access == .limited`:

```swift
Text(L10n.str("call.search.accessLimited", locale: coordinator.activeLocale))
    .font(.system(size: appearance.typography.captionPointSize))
    .foregroundStyle(appearance.colors.textSecondary)
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 6)
```

Frozen key `call.search.accessLimited` ("Searching shows only the contacts
you allowed." / "खोज्दा तपाईंले अनुमति दिनुभएका सम्पर्कहरू मात्र देखिन्छन्।").
It renders only inside the readable gate, so `.limited` can never fall into
the blocked/ask arms.

### 4. The T-156 published-state handoff

All three CallView search sites (`resolveResultPhotos()` face pass,
`announceVoiceResultIfReady()`, `resultsArea`) now read
`index: coordinator.familyIndex` and `verifiedLinks: coordinator.verifiedLinks`;
the three interim inline `FamilyContactIndex(family: coordinator.familyContacts)`
hoists (T-152 compile fixes) are gone (0 occurrences in the file). Rows,
announced names and resolved faces can no longer disagree about who is linked.

### 5. call-dialer union (PR #171) — verified, not touched

Full-worktree `git diff` inspection: no `+`/`−` line touches `dialChannel`,
`whatsApp`, `dial`, `rowChannelState`, `channelStates`, `RowChannelState` or
`ContactTile`. The only textual mention of `RowChannelState` in my diff is an
added doc comment referencing the house defaulted-field pattern. The
`CallChannelResolutionTests` region markers (`private var searchField:`,
`private func dialChannel(`, `private struct RowChannelState {`,
`private struct UnifiedContactResultRow`) all survive.

## Tests

New `ios/ElderlyAssistantTests/App/CallViewFacesAndCaptionTests.swift`
(349 lines, 10 tests), registered in `seniOS.xcodeproj/project.pbxproj`.
Motivation matches the unit spec's split: caption composition is pure and
unit-testable; the gate shape and wiring are runtime-unreachable, so they are
pinned as `FeatureSourceScan` (comment-stripped, string-literal-preserving)
source scans, using the house `region`/`collapsed`/`occurrences` helpers.

1. `testBookSideOnlyMatchComposesTheFrozenCaptionWithTheBookName` — real
   `UnifiedContactSearch` run: book-side-only query ("शर्मा") synthesizes the
   family row; caption is exactly "Also in your phone book as सीता शर्मा".
2. `testUnlinkedPairKeepsTodaysRowsAndGetsNoCaption` — unlinked anchor (the
   twin's number spells differently, so Pass-4 dedupe cannot collapse the
   rows): today's two-row outcome, empty map, no captions.
3. `testOnlyTheFamilyRowKeyedInTheMapCarriesTheCaption` — hand-built outcome:
   the keyed family row gets the caption, the book row (id = normalized
   number) never can.
4. `testEmptyStoredBookNameIsSuppressedNotRendered`.
5. `testCaptionResolvesTheFrozenKeyInBothLanguages` — literal en + ne
   wording, the book name placed by the key's `%@`.
6. `testEveryCallViewReadableGateReadsAllowsReading` — file-wide
   `== .allowed` count 0; per-region pins for all six sites; `.denied` the
   only blocked arm; `_ = await directory.requestAccess()`; no `if granted`
   shape; the limited caption sits inside the readable gate.
7. `testAccessLimitedCaptionLeadsTheReadableBlock` — ordering
   searchField < key < micCaption; exact collapsed caption-block snippet.
8. `testResultRowCaptionSeamAndDialInputsArePinnedAtTheSource` — `var
   caption: String? = nil`, `if let caption {`, `Text(caption)`, initials
   fallback, and the five call-dialer dial-input seams (`channelState`,
   `dial`, `whatsApp`, `chooseChannel`, `addHandle`) pinned as SURVIVING.
9. `testTheCaptionIsComposedFromTheRenderedOutcomeInOnePlace` — one composer
   call site with the collapsed snippet; composer region carries exactly one
   key literal, one map lookup, the empty-name suppression, and the exact
   `return L10n.fmt(...)` line.
10. `testEveryCallViewSearchReadsThePublishedIndexAndLinks` — 0 inline
    `FamilyContactIndex(family:` rebuilds; 3 ×
    `UnifiedContactSearch.search(`, 3 × `index: coordinator.familyIndex`,
    3 × `verifiedLinks: coordinator.verifiedLinks`.

### Pin pre-verification (suite run deferred)

Because speed mode defers the scoped suite run, every source pin was
pre-verified against the real post-edit `LeafViews.swift` with a Python
mirror of the repo's own `FeatureSourceScan.codeText` + the
`region`/`collapsed`/`occurrences` helpers (`/tmp/t161_scan_sim.py`):
**all 33 pins verified**. Two self-caught defects were fixed during this
pass: a contradictory gate assertion (`access == .limited` is now a
legitimate arm — replaced with an ordering assertion) and an unlinked-pair
fixture whose twin shared the family number's normalized form (would have
been collapsed by Pass-4 dedupe at run time).

## Verification

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing
  -project seniOS.xcodeproj -scheme ElderlyAssistant -destination
  "platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2"
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`
  from `ios/` → `** TEST BUILD SUCCEEDED **`, exit 0, 0 errors
  (`ios/build/t161-typecheck.log`). The log shows
  `CallViewFacesAndCaptionTests.swift` compiled into the test target and
  `LeafViews.swift` into the app target on the final tree.
- The same build compiled the concurrent T-158 dev's in-flight
  `AppCoordinator.swift` cleanly — no cross-unit breakage was introduced.
- Scoped suite run (`CallViewFacesAndCaptionTests` + the
  `CallChannelResolutionTests` regression) deferred per the speed-mode
  assignment; every pin is pre-verified (above).

## Decisions and deviations

1. **Test suite naming/location.** Design-l2 mentions an all-files
   `ContactsAccessGateTests`; I created a CallView-scoped suite instead
   (`CallViewFacesAndCaptionTests`). Rationale: an all-files gate scan would
   collide with the concurrent T-158/T-159 devs' uncommitted files; all six
   §3.5 LeafViews obligations are pinned in scope, which is what the unit
   owns. Deviation recorded.
2. **`MissedCallDialBackTests` not extended.** Its pinned regions scan
   `AppCoordinator`, not `LeafViews`; it rides the unit gate as a regression
   run. Deviation recorded.
3. **Notes filename** `specs/T-161-callview-faces-notes.md` (default path is
   call-dialer's merged record) — explicitly instructed.
4. **Selective pbxproj staging in the shared worktree.** The working-tree
   pbxproj carried the concurrent T-158 dev's 4 `CoordinatorLinkUnlinkTests`
   registrations alongside mine. I staged a blob = HEAD's pbxproj + exactly
   my 4 `CallViewFacesAndCaptionTests` lines (built and asserted
   programmatically, `git hash-object -w` +
   `git update-index --cacheinfo`), then verified the staged diff contains no
   `CoordinatorLinkUnlink` lines. Their entries remain unstaged in the
   worktree for their own commit; nothing of theirs was committed.
5. **Disk housekeeping.** The typecheck ran under the known ENOSPC hazard;
   I pruned the dormant call-dialer worktree build cache (~5.2 GB, merged
   feature) before building, keeping this worktree's warm
   `build/DerivedDataTests` for the concurrent dev.

## Files

- `ios/ElderlyAssistant/App/LeafViews.swift` (modified — CallView only)
- `ios/ElderlyAssistantTests/App/CallViewFacesAndCaptionTests.swift` (new)
- `ios/seniOS.xcodeproj/project.pbxproj` (4 registration lines only)

## Outstanding

- Scoped unit gate run (deferred by speed mode; pins pre-verified).
- Device validation (DV) is out of scope for this unit.
