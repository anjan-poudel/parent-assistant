# T-162 — Family list link chip, face migration and legacy photo API deletion (implement notes)

Feature: family-contacts-unify · Branch: feat/family-contacts-unify
Unit: TG-32 / T-162 · Mode: speed mode (implement + whole-module typecheck + commit only;
scoped suite run and per-unit review deferred)
Design refs: design-l2 §2.7, §4.4, §8.1-§8.2; design-l1 §11.2, §10.1.

Note on filenames: the default `specs/T-162-notes.md` is the merged call-dialer feature's
record (present on this branch's base); per the assignment this unit's notes live here.

## What was built

### 1. The link chip (design-l2 §2.7) — `ios/ElderlyAssistant/App/SettingsView.swift`

- New pure seam `enum FamilyListPresentation` (new, directly above
  `FamilyContactsSettingsView`), one decision:

  ```swift
  static func showsLinkChip(_ contact: FamilyContact,
                            verifiedLinks: VerifiedLinksSnapshot) -> Bool {
      verifiedLinks.links[contact.id] != nil
  }
  ```

  VERIFIED links only — the snapshot's `links` map holds exactly the verified claims
  (T-157), so a stale stored link is absent and shows NOTHING here; the editor's link
  area owns the honest stale line (`family.link.stale`). The view renders the chip as

  ```swift
  if FamilyListPresentation.showsLinkChip(
      contact, verifiedLinks: coordinator.verifiedLinks) {
      linkChip(contact)
  }
  ```

  appended to the role-chip row (after the relationship caption), per §2.7's
  "appended to the role-chip row".
- `linkChip(_:)` (new, between `roleChip` and `isDoctorRelationship`): the frozen
  `family.link.chip` key through `L10n.str` in the active locale (no inline strings),
  the accent-tint capsule the call rows' `familyChip` uses, a `>= 44 pt` tap floor
  (`.frame(minHeight: DesignTokens.minTapTargetSize)` + `.contentShape(Rectangle())` so
  the WHOLE frame is tappable, not only the small visual capsule), and — unlike the
  decorative role chips — NOT `accessibilityHidden` (it is interactive), with the chip
  copy as its a11y label.
- The chip affordance opens the contact's editor (`editorTarget = .edit(contact)`):
  the wizard's link area is the home of the link/unlink flow, and its unlink commits
  through the ONE copy-preserving path (T-158's `setFamilyContactLink` +
  `AppCoordinator.unlinkMode`). Decision logged under "Decisions" below.

### 2. Face migration — verified complete, one stale comment fixed

The T-157 migration on the list rows (:1596-1612 pre-edit) was already correct and is
now pinned:
- one BATCH pass `.task(id: faceIdentities)` over the whole roster (not a task per
  row), keyed on the identity ARRAY (`coordinator.familyContacts.map {
  coordinator.faceIdentity(for: $0) }` — which carries id, system-photo token,
  filename and `faceEpoch`);
- each face via `await coordinator.faceThumbnail(for:diameter:
  DesignTokens.iconBadgeDiameter, displayScale:)`;
- the post-await identity re-check (`guard coordinator.faceIdentity(for: contact) ==
  identity else { continue }` — the stale-pass drop) on EVERY row;
- ONE publication per pass (`contactPhotos = resolved`), so all rows render their
  face after the same (single) identity change;
- the view never touches `faceEpoch` — no per-row bump is even possible here; the
  bump-exactly-once-per-change ordering is the coordinator's (T-157 pins:
  `CoordinatorIdentityRefreshTests`, `CoordinatorFaceIdentityTests`).
- Fixed the one straggler: the `contactPhotoThumb` doc comment still referenced the
  pre-T-157 `contactPhotoKey` task name; it now names the `faceIdentities` batch pass.

### 3. `loadDraft` stored-photo preview — already aligned (T-160), pinned

`loadDraft` deliberately assigns nothing; the preview resolves in the sheet's
`.task(id: storedFaceIdentity)` through `await coordinator.faceImageWithSource(for:
contact)` (ONE precedence pass: image + source attribution), keyed on the LIVE roster
row (`liveEditingContact`) and re-checked after the await. Nothing left to change;
pinned by source.

### 4. Legacy `contactPhoto(for:)` — deletion CONFIRMED (§8.1)

Source scan (both patterns, production module `ElderlyAssistant/`, 391 Swift files):

- `contactPhoto(for` → 0 code references;
- `func contactPhoto(` → 0 declarations.

The only remaining mentions anywhere are in the anti-regression tests themselves
(`CoordinatorFaceIdentityTests`' broader pin, and the new named pin). The deletion was
done in T-157; this unit CONFIRMS it and lands the named pin.

### 5. Tests — `ios/ElderlyAssistantTests/App/FamilyListLinkChipTests.swift` (new, in pbxproj)

- `testLinkChipVisibilityIsVerifiedOnly` — the pure seam over verified / stale /
  unlinked / empty-snapshot fixtures (the §2.7 rule; the empty snapshot IS the
  post-unlink render — no chip).
- `testChipWiringIsPinnedAtTheSource` — region pins on `linkChip` + the row render:
  the seam drives the capsule, the frozen key is the only copy, the chip opens the
  editor, the 44 pt floor + `contentShape` hold, and the chip is NOT decorative.
- `testListFaceMigrationIsPinnedAtTheSource` — the batch pass: exactly ONE `.task(id:)`
  in the list region (a per-row task regression fails the count), the identity-array
  key, the async `faceThumbnail` call, the post-await guard, the single publication,
  state-read rendering, and no `faceEpoch` in the view.
- `testDraftPreviewUsesTheAsyncFacePath` — the wizard region's preview wiring
  (`storedFaceIdentity` key on the live row, `faceImageWithSource`, the post-await
  guard, both assignments).
- `testSyncContactPhotoResolverIsRemoved` — the §8.1 pin, by name (the unit gate runs
  it): comment-stripped scan of all 391 production sources for both patterns, plus the
  surviving async accessors present in AppCoordinator. Test module exempt by design —
  the pin tests carry the literal.
- All source pins use the house `FeatureSourceScan` + `region`/`collapsed` helpers; the
  pins were additionally dry-run against the real tree with an external script
  (all PASS; the one raw-text mismatch was the `.task(id:)` mention inside a doc
  comment, which `codeText` strips).

## Verification

- Whole-module typecheck from `ios/`:

  ```
  xcodebuild build-for-testing -project seniOS.xcodeproj \
    -scheme ElderlyAssistant \
    -destination 'platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2' \
    -derivedDataPath build/DerivedDataTests
  ```

  **TEST BUILD SUCCEEDED, 0 errors** (`ios/build/t162-typecheck.log` / `.exit` = 0).
  `FamilyListLinkChipTests.swift` compiled in the test batch (`.o` produced). 195
  warnings — one FEWER than the T-161 baseline of 196; none lands in the new lines or
  the new file.
- Scoped suite run DEFERRED (speed mode) — per the assignment: tests exist and compile.

## Decisions

1. **Chip affordance = open the editor.** The unit's Gherkin asks the chip to "open the
   link/unlink flow (copy-preserving unlink per T-158)" and design-l2 §2.7 specifies no
   other affordance; the editor's link area is the only link/unlink surface (the list
   itself stores nothing — FR-FCU-001's write seam), and the frozen key set cannot
   express a list-local unlink confirmation. The chip therefore opens the contact's
   editor (same target the pencil uses), where the unlink commits through the one
   copy-preserving path. No new copies, no new surface.
2. **Chip appended after the relationship caption** — §2.7's "appended to the role-chip
   row" read literally (it is the row's last element).
3. **Seam placement**: a new `FamilyListPresentation` enum rather than a static on the
   view, matching the find/photo presentation-seam pattern in the same file.
4. **No faceEpoch handling added to the view** — the batch pass re-resolves when the
   identity (which embeds the epoch) changes; the view cannot and must not bump.

## Deviations

None from the assignment. Two adjacent findings handled in-scope: the stale
`contactPhotoKey` doc comment (fixed) and the pbxproj registration of the new test
file (required — the project uses explicit file references).

## Files changed

- `ios/ElderlyAssistant/App/SettingsView.swift` — `FamilyListPresentation` seam, chip
  in the row, `linkChip(_:)`, stale comment fix.
- `ios/ElderlyAssistantTests/App/FamilyListLinkChipTests.swift` — new suite.
- `ios/seniOS.xcodeproj/project.pbxproj` — new test file registered.
- `specs/T-162-family-list-notes.md` — this file.
