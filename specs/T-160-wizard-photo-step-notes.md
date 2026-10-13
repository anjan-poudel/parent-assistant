# T-160 notes — wizard photo step and save (family-contacts-unify)

Developer record for unit **T-160: wizard photo step and save** (TG-32,
design-l2 §2.4, §2.5, §2.6, §10.2–§10.4; design-l1 §10.1–§10.4, §11.1;
F4 decision, FR-FCU-007/008/009/010/015, NFR-FCU-005).

Speed mode: implement + whole-module typecheck + commit. Scoped suite run
deferred (tests exist, compile, and are pinned; the run happens at the unit
gate). All work in the feature worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`).

File name: call-dialer's merged records occupy `specs/T-160-notes.md`, so
this unit's notes live here (per assignment).

## What was built

### 1. Photo step → design-l2 §2.4

`FamilyContactWizardSheet.photoStep` is the design's subview breakdown in
order: `stepTitle("family.step.photo")`, `photoPreview`, `sourceCaption`,
`photoControls`, `writeAccessCards`, `photoStateLine`.

- **Source caption** (`sourceCaption`): renders `family.photo.sourceSystem`
  exactly when the preview shows the STORED face AND that face is the
  resolved SYSTEM one — the decision comes from the new pure seam
  `FamilyWizardPhotoPresentation.showsSourceSystemCaption(displayingStoredPhoto:
  storedPhotoIsSystem:)`. A fresh pick (`pickedPhoto != nil`) or an explicit
  remove replaces the preview and the caption falls away; an app-local
  fallback never claims to come from the phone book (FR-FCU-007 honest
  display, both failure directions).
- **Write-access cards** (`writeAccessCards`, design-l2 §2.4): rendered only
  while editing a contact whose link the snapshot VERIFIES
  (`liveEditingContact` + `coordinator.verifiedLinks.links[contact.id] != nil`)
  — the only state in which Save can actually write (`syncSystemPhoto`
  answers `.skippedNoLink` otherwise, so an ask would be a dead end).
  - `.notDetermined` → the point-of-use ask card (`family.photo.accessTitle`
    + `family.photo.accessBody`) whose Allow runs the wizard's EXISTING
    `grantAccess()` via the new shared `askCard(titleKey:bodyKey:)` (the find
    step's `askAccessCard` now delegates to it too — the frozen
    `call.search.allowButton` label, ≥44 pt, one ask path, no divergence).
  - `.denied` → `photoAccessDeniedLine`: the frozen
    `family.photo.accessDeniedBody` sentence plus the shared
    `openSettingsButton` (`UIApplication.openSettingsURLString`,
    `call.search.openSettings`) — no nag, only the system door.
  - `.limited`/`.allowed` → no card (readable — the write proceeds
    attempt-and-detect at Save); nil (still reading) → nothing, so no card
    can flash before the status resolves.
- **State line** (`photoStateLine`): after a save, renders
  `Text(LocalizedStringKey(FamilyWizardPhotoPresentation.stateLabelKey(state)))`
  with the denied body alongside exactly `.keptOnPhoneAccessDenied`
  (`showsAccessDeniedBody`). Nothing renders before a save.

### 2. Save flow → design-l2 §2.6, §10.2 (F4)

`save()`:

1. `let savedID = editingContact?.id ?? newDraftID` — the saved contact's id
   is known BEFORE the store write.
2. The store write runs FIRST (unchanged add/update seam), now passing the
   FULL nickname list (`nicknames: nicknames`) and the T-159 draft link
   (`link: draftLink`) on both calls. A failed write keeps the draft on
   screen (`guard succeeded else { return }`) — no system write is ever
   attempted for a failed store write.
3. No photo changed (`guard photoIntent else { dismiss(); return }`) →
   today's UX, nothing attempted.
4. Photo intent → `Task { @MainActor in let outcome = await
   coordinator.syncSystemPhoto(forContactID: savedID, clearing: removingPhoto) }`.
   - Remove path (§10.4): when `rechecksRemoval` (a VERIFIED clear —
     `.written` with `removing`) the display-precedence recheck runs through
     the SAME resolver the preview uses
     (`coordinator.faceImageWithSource(for: contact).isSystemPhoto`); a
     system photo still standing maps to `.systemPhotoRemains` (the
     actionable Contacts-app sentence).
   - Everything else maps through the total `FamilyPhotoEditorState` table
     (`FamilyWizardPhotoPresentation.saveState` wrapping `FamilyPhotoEditorState.from`).
   - **F4**: any non-nil state — including `.written` →
     `.updatedInSystem` — sets `photoSaveState`, switches to the `.photo`
     step, keeps the sheet open, and the footer's primary button becomes
     `common.close` (dismiss). Only nil (unlinked, or the contact left the
     roster) dismisses. The label is `family.photo.state.updatedInSystem`,
     one frozen string; the design-doc wording alignment (design-l1 §10.2
     step 3's auto-dismiss phrasing) is deferred to T-165, recorded in a
     comment at the mapping.

### 3. Nickname step → design-l2 §2.5

Replaces the interim single-field editor (`@State nickname` gone):

- `nicknameList`: one row per OCCURRENCE
  (`ForEach(Array(nicknames.enumerated()), id: \.offset)`) — duplicates are
  real data and render as separate rows; the stored spelling is verbatim.
- `nicknameRow`: the entry text + a ≥44 pt xmark remove control whose a11y
  label is `L10n.fmt("family.nickname.removeLabel", locale:, entry)`
  (fresh; formatted with the entry, active locale).
- `nicknameAddRow`: offered while
  `FamilyWizardNicknamePresentation.canAdd(entries:)` (`entryLimit = 8` —
  the add row simply stops offering at the cap; nothing already stored is
  ever dropped). TextField prompt = `family.nickname.entryPlaceholder`;
  the ≥44 pt Add button (`family.nickname.add`, with an a11y label)
  commits through the F5 seam
  `FamilyWizardNicknamePresentation.newEntry(from:)` →
  `FamilyContact.cappedNickname` (trimmed; whitespace-only rejected AT
  ENTRY; over-long capped at 64 CHARACTERS as a whole-grapheme prefix, so a
  Devanagari cluster is never split; stored as entered within the bound —
  no transliteration, no case folding).
- `nicknameHint`: `family.nickname.hint` caption.
- `loadDraft()` reads `contact.nicknames` (the full stored list) and `save()`
  passes the full draft list through the coordinator's widened `nicknames:`
  seam on both add and update — the interim first-entry-only loss window
  closes here. The coordinator re-applies `FamilyContact.normalizedNicknames`
  at its own boundary (defense in depth).

### 4. Coordinator seam: `faceImageWithSource(for:)` (recorded deviation)

The source caption could not be derived honestly from view state alone:
`verifiedLinks + storedPhoto != nil` false-positives when the linked record
has no readable photo but an app-local file exists, and `photoFilename == nil`
alone misses the both-sources case. Added the exact one-pass resolver:

```swift
@MainActor
func faceImageWithSource(for contact: FamilyContact) async
    -> (image: UIImage?, isSystemPhoto: Bool) {
    if let system = await resolvedSystemPhoto(for: contact) { return (system, true) }
    return (contactPhotoStore.load(named: contact.photoFilename), false)
}

@MainActor
func faceImage(for contact: FamilyContact) async -> UIImage? {
    await faceImageWithSource(for: contact).image
}
```

`faceImage` delegates (its signature line is pinned by
`CoordinatorFaceIdentityTests` and stays byte-identical); the pair comes out
of ONE precedence pass, so the displayed bytes and the caption can never
disagree (design-l2 §8.1's two-paths hazard). The wizard's face task reads
`storedPhoto = face.image` / `storedPhotoIsSystem = face.isSystemPhoto`
after the SAME post-await identity re-check as before
(`.task(id: storedFaceIdentity)` kept).

## Tests

New scoped suite `ios/ElderlyAssistantTests/App/FamilyWizardPhotoSaveTests.swift`
(registered in `seniOS.xcodeproj/project.pbxproj`, the T-159 4-line recipe):

- Pure seams: the source-caption rule (both false directions); the post-save
  state mapping — `.written` → `.updatedInSystem` (F4), the unlinked nil,
  the denied/limited/notDetermined/full arms, `.recordGone`/`.identityMismatch`,
  all four `SystemContactWriteFailure` cases; the failure-path Gherkin (no
  non-success attempt outcome can ever render `.updatedInSystem` or
  `.systemPhotoRemains`; nil outcome dismisses); the §10.4 remove matrix
  (verified clear + standing photo → `.systemPhotoRemains`; verified clear
  with nothing left → `.updatedInSystem`; failed clear maps through the
  table; the write path never produces the remove label); `rechecksRemoval`
  trigger; the state→label keys (four states, three distinct frozen keys,
  the deliberate `.keptOnPhone` share); `showsAccessDeniedBody` only beside
  the denied state.
- Nickname rules: the 8-entry envelope (add row offered below, closed at and
  above the cap); trim/whitespace-only rejection; the 64-char whole-grapheme
  cap probed with repeated Devanagari clusters and ASCII; store-as-entered;
  `FamilyContact.normalizedNicknames` order/duplicate preservation and trim.
- End to end: `faceImageWithSource` over the REAL coordinator with a
  scripted `SystemContactLinkReading` fake on an in-memory profile channel —
  resolved system bytes → `(image, true)`; the identical resolution through
  `faceImage`; no bytes and no app-local file → `(nil, false)`; no bytes but
  an app-local file → `(image, false)` (the honest fallback attribution).
- Source pins (comment-stripped `FeatureSourceScan` scans; the
  `FamilyWizardFindStepTests` house convention): the photo-step subview
  order; the caption's ONE rule + pair assignment; the write-access card
  arms, frozen copy, shared ask card (`grantAccess()`,
  `call.search.allowButton`, ≥44 pt) and Settings door; the state line's
  mapping + denied body; the save-flow sequencing (id first, store write
  before the photo Task, failure keeps the draft, recheck via the same
  resolver, `photoSaveState = state`, `step = .photo`, two `nicknames:
  nicknames,` / two `link: draftLink` passes, `id: savedID`); the footer's
  `common.close` while a state is shown; the nickname list wiring (no
  single-field state, enumerated rows, ≥44 pt labeled remove, the canAdd
  gate, the F5 commit, the hint) and `loadDraft` reading the full list. The
  F4/T-165 comment pin reads the RAW file text — `codeText` strips exactly
  the comments that are the subject.

## Verification

- Whole-module typecheck from `ios/`:

  ```
  xcodebuild build-for-testing -project seniOS.xcodeproj \
    -scheme ElderlyAssistant \
    -destination 'platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2' \
    -derivedDataPath build/DerivedDataTests
  ```

  **TEST BUILD SUCCEEDED, 0 errors** — the app module and the
  `ElderlyAssistantTests` target both compiled, including
  `FamilyWizardPhotoSaveTests.swift` (in the compile batch). The 196
  warnings are the pre-existing baseline; none lands in the new lines or
  the new file. Destination note: `name=iPhone 16 Pro` alone resolves
  against the latest runtime (26.5, where the device does not exist) — the
  explicit simulator id (18.3.1) is the working specifier.
- Scoped suite run: deferred (speed mode) — tests exist and compile; the
  unit gate runs them.

## Decisions and deviations (recorded for review)

1. **`faceImageWithSource(for:)` added to `AppCoordinator`** (the one
   production deviation). Recorded above: exact source attribution cannot
   be derived from view state without a stale/false-positive case, and the
   one-pass pair keeps image and caption from ever disagreeing. `faceImage`
   delegates to it, preserving the pinned signature and all T-157
   identity/token pins.
2. **Write-access cards gate on the VERIFIED link**, not merely an editing
   contact: `syncSystemPhoto` answers `.skippedNoLink` for unverified
   links, so an ask card there would promise a write that cannot happen
   (the unit's failure-path honesty rule). This matches §2.4's intent.
3. **The shared ask card and Settings door.** `askCard(titleKey:bodyKey:)`
   and `openSettingsButton` were extracted in the wizard so the photo
   step's ask/denied affordances reuse the find step's exact behavior
   (`grantAccess`, `call.search.allowButton`, `call.search.openSettings`)
   — §2.4's "reusing the wizard's existing ask-card pattern", implemented
   literally as one code path. `askAccessCard` is now a two-line delegate;
   `blockedSearchCard` reuses `openSettingsButton`.
4. **`.keptOnPhone` label shared** by `.keptOnPhone` and
   `.keptOnPhoneAccessDenied` — the denied state adds the explanation
   body, never a second sentence (the §1.5 table's own shape).
5. **F4 comment at the mapping**: the deliberate label and the T-165
   design-doc alignment deferral are recorded next to
   `stateLabelKey`; the pinned test reads the raw source for exactly this
   reason.
6. **Remove-path recheck reads the same resolver as the preview.** §10.4
   is implemented as: verified clear → re-resolve through
   `faceImageWithSource` → still system → `.systemPhotoRemains`. Sharing
   the resolver means the state line and the post-save preview can never
   disagree about what remains.
7. **Task-file drift (same as T-159 decision 5).** The task file names
   onboarding files; the shipped wizard is `FamilyContactWizardSheet` in
   `SettingsView.swift`. Implemented against the shipped structure; no
   onboarding changes.

## Files

- `ios/ElderlyAssistant/App/SettingsView.swift` — photo step, save flow,
  nickname list editor, `FamilyWizardPhotoPresentation`,
  `FamilyWizardNicknamePresentation`, shared `askCard`/`openSettingsButton`.
- `ios/ElderlyAssistant/App/AppCoordinator.swift` — `faceImageWithSource`,
  `faceImage` delegation.
- `ios/ElderlyAssistantTests/App/FamilyWizardPhotoSaveTests.swift` — new.
- `ios/seniOS.xcodeproj/project.pbxproj` — 4-line test registration.
- `specs/T-160-wizard-photo-step-notes.md` — this file.

## Commit

- `3294a397` — "T-160: wizard photo step + save flow — honest post-save
  states, managed nickname list" (SettingsView.swift, AppCoordinator.swift,
  FamilyWizardPhotoSaveTests.swift, project.pbxproj; typecheck green).
  Branch `feat/family-contacts-unify`; not pushed (per assignment). This
  notes file is the follow-up record commit.
