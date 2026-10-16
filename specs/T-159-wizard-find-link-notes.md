# T-159 notes — wizard find and link steps (family-contacts-unify)

Developer record for unit **T-159: wizard find step — link section, prefill,
steering and claimant guard** (TG-32, design-l2 §2.1–§2.3, §3.5, §6.4, §8.2;
FR-FCU-001/003/012, NFR-FCU-005).

Speed mode: implement + whole-module typecheck + commit. Scoped suite run
deferred (tests exist, compile, and are pinned; the run happens at the unit
gate). All work in the feature worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`).

## What was built

### 1. Find step → `UnifiedContactSearch` (design-l2 §2.2)

`FamilyContactWizardSheet.searchResults` now renders the unified engine's
outcome: `UnifiedContactSearch.search(query:family:index:in:verifiedLinks:
recency:)` fed with the coordinator's published seams —
`coordinator.familyContacts`, `coordinator.familyIndex`,
`coordinator.verifiedLinks`, `coordinator.contactCallRecency`. The legacy
`SystemContactSearch.search` call is gone from the wizard. `noResults`
renders on an empty row list; `moreAvailable` keeps the "keep typing" hint.
The wizard defines no tier table of its own — its row list IS the engine's
list through the new pure seam below.

### 2. `FamilyWizardFindPresentation` — the pure seam (file-level enum after the sheet)

Split out so the harness can pin the logic without a view instance:

- `rows(for:roster:editing:) -> [Row]` — one rendered row per engine entry,
  in the engine's order. `.addressBook` rows whose record is claimed by
  another roster contact become `.steering(claimant)`; `.family` rows become
  `.steering(contact)` — except the contact being edited, whose own row is
  skipped entirely. First-occurrence dedupe by `Row.id`
  (`"pick-<normalized>"` / `"steer-<uuid>"`) keeps `ForEach` ids unique when
  a STALE claimant's book row rides beside the claimant's own family row.
- `storedClaimant(_:in:editing:)` — roster order; matches the STORED claim
  (verified AND stale, the superset); never the editing contact; an empty
  identifier never claims.
- `draftLink(for:)` — `SystemContactLink(identifier: entry.identifier,
  numberKey: entry.normalized)`; nil for an empty identifier ("no linkable
  record", §3.5).
- `linkState(draftLink:editing:verifiedLinks:)` — draft → stored+verified →
  stored+stale → no pick.
- `bookName(for:in:)` — the current sweep's name for the linked identifier;
  nil fails closed (no fabricated identity), empty identifier → nil.

### 3. Draft state and the link area (design-l2 §2.1/§2.2)

- New `@State draftLink: SystemContactLink?`, `draftLinkBookName: String?`,
  `steerTarget: FamilyContact?`.
- `prefill(_ entry:)` records the draft through the seam's non-empty-
  identifier guard (records `draftLinkBookName` at pick time) and clears any
  steering intent.
- `linkSection` (inside the find step, add AND edit) renders
  `family.link.sectionTitle` in all four states:
  1. `.draftLinked` — `family.link.linkedTo` (the pick-time book name) +
     unlink that clears ONLY the draft (`clearDraftLink`);
  2. `.storedLinked` — linkedTo with the name resolved from the CURRENT
     sweep (nil → the design's "-" placeholder) + unlink that commits;
  3. `.storedStale` — `family.link.stale` + the same committing unlink;
  4. `.noPick` — the `family.link.pickHint` caption only.
- The unlink control: ≥44 pt, a11y label `family.link.unlink`, a11y hint
  `family.link.unlinkHint`, and the hint ALSO visible as a caption under the
  button. A committed unlink goes through the ONE path —
  `coordinator.setFamilyContactLink(id:mode:)` (T-158) — with the mode from
  the coordinator's pure `unlinkMode` rule.
- `draftLink` passes through Save (`link: draftLink` on both
  `updateFamilyContact` and `addFamilyContact`, §2.6). No link is stored
  from the link area itself; the only write there is the stored link's
  unlink. The single-field nickname step stays interim (T-160 replaces it).

### 4. Steering micro-flow (design-l2 §2.3)

- New init parameter `onSteerTo: @escaping (FamilyContact) -> Void`; the
  parent call site (`FamilyContactsSettingsView`) sets
  `editorTarget = .edit(other)` in place — the `.sheet(item:)` id changes,
  so SwiftUI swaps the content with no dismiss/re-present race. The first
  contact's uncommitted draft is discarded by design.
- The steering row renders the `family.link.alreadyLinked` sentence (the
  other contact's name, `L10n.fmt`) plus a ≥44 pt accent button whose
  a11y label is `settings.family.edit` and whose action fires
  `onSteerTo(other)`. A tap anywhere else on the card records `steerTarget`
  WITHOUT selecting anything — no field changes, no store write.
- `steerTarget` clears on any new search keystroke (`.onChange(of:
  searchText)`) and on a successful pick.

### 5. T-148b wizard obligations (design-l2 §3.5)

- `refreshSearchAccess` and `grantAccess` gate on `allowsReading` (never
  `== .allowed`, never the binary request result): a limited grant loads the
  granted set, on relaunch and post-grant alike.
- The honest `call.search.accessLimited` caption renders once, inside the
  shared `.allowed, .limited` arm, directly under the field.

### 6. Tests

New scoped suite `ios/ElderlyAssistantTests/App/FamilyWizardFindStepTests.swift`
(registered in `seniOS.xcodeproj/project.pbxproj`):

- Pure-seam tests: `storedClaimant` rules (first claimant, editing-contact
  exclusion, stale superset, empty identifier); `rows` mapping (family →
  steering, editing row skipped, claimed book row → steering, the editor's
  own record stays selectable, dedupe + order); `draftLink` identifier guard
  and number-key record; `linkState` precedence (including the cleared-row
  `.noPick`); `bookName` resolution and fail-closed cases.
- Engine-integrated Gherkin paths through the REAL
  `UnifiedContactSearch.search`: the verified linked number steers via the
  synthesized family row (FR-FCU-004 shape); the stale claim still steers to
  its claimant (unlinked parity — the link is unverified); the nickname
  query surfaces the contact through the published index (FR-FCU-012);
  family-first engine order maps 1:1 to the wizard's row order.
- Drift pin (design-l2 §6.4): the wizard region calls
  `UnifiedContactSearch.search(` exactly once with the published roster /
  index / verified links, `SystemContactSearch.search` count is 0, no
  `FamilyMatchTier` in the region, and the rows come through the ONE
  presentation seam.
- Source pins (comment-stripped `FeatureSourceScan` scans; the
  CallViewFacesAndCaptionTests house convention): the steering callback +
  parent in-place swap + `steerTarget` lifecycle + ≥44 pt card/button +
  a11y label; the four link states + section title + draft-vs-stored unlink
  split + unlink a11y/hint/≥44 pt + `setFamilyContactLink` commit +
  `unlinkMode` derivation + `link: draftLink` pass-through at Save +
  `liveEditingContact` face keying; the `allowsReading` gates and the
  limited caption's placement under the field.

## Verification

- Whole-module typecheck (xcodebuild `build-for-testing`, scheme
  ElderlyAssistant, destination iPhone simulator, `-derivedDataPath
  build/DerivedDataTests`): **TEST BUILD SUCCEEDED, 0 errors** — the app
  module and the `ElderlyAssistantTests` target both compiled, including
  `FamilyWizardFindStepTests.swift` (verified in the build log's compile
  batch). Warnings are the pre-existing baseline (e.g. WhisperKit
  Sendable) — none introduced by this unit.
- Scoped suite run: deferred (speed mode) — tests exist and compile; the
  unit gate runs them.

## Decisions and deviations (recorded for review)

1. **Steering card placement interpretation.** design-l2 §2.2 maps result
   kinds to row kinds (human sentence + edit button as the row, not
   selectable) while §2.3 describes the micro-flow. Implemented as: the
   steering card IS the row presentation (per §2.2); the card-body tap sets
   `steerTarget` (§2.3.1 — pure selection, no write); the inner button fires
   `onSteerTo` (§2.3.3); a keystroke or a successful pick clears the intent
   (§2.3.5).
2. **`liveEditingContact`** (new wizard-side computed property). `target` is
   an open-time snapshot; after a successful in-sheet unlink the captured
   value would still hold the cleared claim and render a phantom
   `family.link.stale` line, and its `photoFilename` would miss the
   copy-first unlink's saved file. The link area (`linkState`, `commitUnlink`,
   `unlinkModeForEditingContact`), `resolvedBookName` and the face task
   (`.task(id: storedFaceIdentity)`) all read the LIVE roster row by id
   instead. nil for a fresh add or a contact deleted while the sheet is up.
3. **`unlinkMode` sharpening.** §2.6 names "verified snapshot +
   photoFilename"; implemented as verified link AND `storedPhoto != nil`
   (the editor actually displays system bytes). A verified link whose record
   has no readable photo would otherwise take a copy-first mode whose copy
   can never be made — a stuck unlink dead-end. The derivation matches the
   photo step's source caption (§2.4).
4. **`showsLinkSection` failure-path rule.** The link area renders in the
   readable access states always, and in the unreadable ones ONLY when a
   link exists to show — a denied/undetermined search shows the honest
   access card and never an empty-but-enabled section (the unit's failure
   path), while a stored link's unlink remedy stays reachable after access
   was revoked (FR-FCU-006). The stale test drives the full
   engine → presentation path for the revoked/unverified case.
5. **Task-file drift — `OnboardingWizardView.swift` is stale.** The T-159
   task file names `OnboardingWizardView.swift` /
   `ProfileInterviewSteps.swift` as the wizard home; the shipped wizard is
   `FamilyContactWizardSheet` in `SettingsView.swift` (the family-wizard
   restructure, 2026-09-07), and the parent call site lives in
   `FamilyContactsSettingsView` in the same file. Implemented against the
   shipped structure per the design-l2 §8.2 site list; no onboarding
   changes were made.
6. **Test suite shape.** design-l2 §8.2 sketches all-files
   `ContactsAccessGateTests`; followed the T-161 precedent instead — a
   scoped `FamilyWizardFindStepTests` suite next to the wizard it pins
   (pure seams + engine-integrated Gherkin paths + source pins in one
   place), registered in the app test target.
7. **Drift-pin reading.** design-l2 §6.4 is implemented as a source scan
   (the wizard region calls `UnifiedContactSearch.search`; the legacy call
   is gone; the published seams are carried) plus a behavioral parity test
   (every `Result` kind maps through the ONE presentation seam in the
   engine's order). The tier ORDER itself is raw-value order, already
   pinned by T-152's `UnifiedContactSearchTests`; this suite pins that the
   wizard introduces no second table.

## Files

- `ios/ElderlyAssistant/App/SettingsView.swift` — wizard find step, draft
  link, link section, steering, gates, `FamilyWizardFindPresentation`, the
  parent call site. `CallingSettingsView` untouched.
- `ios/ElderlyAssistantTests/App/FamilyWizardFindStepTests.swift` — new.
- `ios/seniOS.xcodeproj/project.pbxproj` — 4-line test registration.
- `specs/T-159-wizard-find-link-notes.md` — this file.

## Commit

- `2bc3817a` — "T-159: wizard find/link steps — unified engine rows, draft
  link, steering, link section" (SettingsView.swift, FamilyWizardFindStepTests.swift,
  project.pbxproj; typecheck green). Branch `feat/family-contacts-unify`;
  not pushed (per assignment). This notes file is the follow-up record
  commit.
