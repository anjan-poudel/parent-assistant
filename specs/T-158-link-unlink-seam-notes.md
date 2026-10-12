# T-158 — Link/unlink seam, post-save system-photo step and link-aware missed-call names (notes)

**Feature:** family-contacts-unify (TG-31 write seam and coordinator integration)
**Branch:** `feat/family-contacts-unify` (worktree `elderly-ai-assistant-family-contacts-unify`)
**Commit:** `b23f190b` (implementation; record commit follows this file)
**Date:** 2026-10-12
**Mode:** speed — implement + whole-module typecheck + commit only (scoped suite run, per-unit review and push deferred by the orchestrator)
**Design refs:** design-l2 §1.8, §1.9, §2.6, §3.5, §4.4, §4.5, §5.2, §8.2; design-l1 §6.4; security-design-review T-4 (F3 advisory) + review-iter-2 R4
**Requirements:** FR-FCU-001/004/005/006; NFR-FCU-002
**Depends on:** T-154 (`SystemContactPhotoWriting` seam), T-156 (`6751cc50` identity state), T-157 (`a8bc3986` face surface)

## What was built

### 1. `ios/ElderlyAssistant/App/AppCoordinator.swift` — the link/unlink seam (design-l2 §1.9)

**`enum SystemContactUnlinkMode: Equatable`** (nested) — `unlinkKeepingLocalAsIs`,
`unlinkKeepingDisplayedPhotoLocally`, `unlinkAndClearAppLocalPhoto`, and the pure rule

```swift
static func unlinkMode(appLocalFileExists: Bool, displayedPhotoIsSystem: Bool) -> SystemContactUnlinkMode
```

(app-local file exists → keep-local-as-is, `displayedPhotoIsSystem` decides only when no
app-local file exists — table-pinned in tests).

**`setFamilyContactLink(id:mode:) async -> Bool`** (impl `:6927`) — *the* only unlink path
(§1.9; a link is set/replaced only through T-156's add/update `link:` seam):

| Stage | Behaviour |
|---|---|
| `.unlinkKeepingLocalAsIs` | app-local file untouched; record write clears the claim |
| `.unlinkKeepingDisplayedPhotoLocally` | **copy runs FIRST, before any record write** (`copyDisplayedSystemPhotoLocally` :7006 — the readable-gated `photoImageData` read → decode → `contactPhotoStore.save` = one encode via `processedJPEG`, design-l1 §6.4); a copy that produces no file REFUSES the unlink (`false`, link intact, `unlink_refused`/`copy_failed`) — the never-lose rule wins (F3/T-4) |
| `.unlinkAndClearAppLocalPhoto` | `photoFilename = nil` |
| record write | ONE write from a fresh store read: `photoFilename` (the mode consequence) + `systemContact = nil` land together, so no window exists where a cleared link sits next to a stale filename (F3 order: copy < assignment < clear < save); on store rejection the just-copied file is deleted (never orphan) + `unlink_refused`/`save_failed` |
| commit | old app-local file deleted only AFTER the save (the `updateFamilyContact` sequencing); roster republished (didSet → index rebuild + `refreshVerifiedLinks` — the stale claim leaves the snapshot on the next pass, FR-FCU-006); `faceEpoch += 1` (§4.4) |
| events | `contacts_link`/`unlink`, outcome = the §5.2 mode token `keeping_local_as_is` / `keeping_displayed_photo_locally` / `clear_app_local_photo`, errorCode nil (:7017); refusals use the `claim_refused` shape — `unlink_refused`, outcome `refused`, fixed codes `copy_failed` / `save_failed` (:7047). No name/number/identifier/filename/byte in any field (NFR-FCU-002) |

The unlink body has **no reference to the write seam at all** (`writePhoto`/`clearPhoto`/
`CNSaveRequest`/`systemContactPhotoWriter` all absent — source-pinned): an unlink can never
write the system record (FR-FCU-005). A missing stored link is "already absent" → plain clear
→ `true` (design's explicit reading).

### 2. `syncSystemPhoto(forContactID:clearing:) async -> SystemContactPhotoWriteOutcome?` (:7095)

A thin post-save delegation to the T-154 seam (design-l2 §1.9/§2.6), injected through
`init(…, systemContactPhotoWriter:)` and resolved lazily (`:7066` — same first-use rule as
`linkService`: a contact with no verified link never constructs a `CNContactStore`):

- `nil` — no contact carries the id; `nil`/empty identifier in the verified link → `.skippedNoLink`
  (short-circuited BEFORE the lazy writer is resolved);
- pre-flight `SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink:access:)` →
  `.skippedNoAuthorization(access)` (no store call — the honest fallback label);
- the payload is the app-local processed JPEG (`contactPhotoStore.loadData(named:)` — the
  bytes the system record receives are byte-identical to what the record holds; test-pinned);
  no payload and not clearing → `.failed(.fetchFailed)` — no attempt, no false success;
- `.written` → `linkService.invalidate(identifier:)` + `faceEpoch += 1`; `.recordGone`/
  `.identityMismatch` → `refreshVerifiedLinks()`; nothing else triggers anything (§4.4/§4.5).

### 3. Link-aware missed-call names (design-l2 §1.8/§3.5/§8.2)

- **`familyContact(matchingPhone:)` (:9379)** = `familyMatch` ?? `linkedFamilyMatch(… snapshot:
  verifiedLinks)` — the contact's OWN phone first; the published snapshot is the ONLY link
  source, so a stale/unverified claim is absent and the number falls through to today's
  behaviour exactly (FR-FCU-006 — never the wrong person).
- **`refreshMissedCallCorrelations`** family pass now delegates to that lookup — one identity
  source for the list and the dial-back (FR-FCU-004); the verified snapshot is captured by
  value on main and travels with the detached pass.
- **`refreshNativeMissedCallNames` (:9322) — the review-iter-2 R4 fix (§3.5):** after the
  permission prompt the status is **re-read** (`access = AddressBookDirectory.access()`), the
  guard reads `access.allowsReading` (`.limited`'s granted set enumerates — only a genuinely
  unreadable state skips the pass), and the resolver receives the REAL `access:` plus
  `snapshot: snapshot`. The granted-ternary and any hardcoded `.allowed` are gone (source-pinned).

### 4. Tests — `ios/ElderlyAssistantTests/App/CoordinatorLinkUnlinkTests.swift` (new, 937 lines, 16 tests)

Real `AppCoordinator` over an in-memory profile channel + the real `FamilyContactStore`
(the T-156/T-157 harness); scripted `FakeLinkReading` (refresh/photo/invalidations/gate) and
the T-154 `FakeSystemContactPhotoWriter` through the init seams — no `CNContactStore` in any
test. Every test starts from `clearRoster`; link-staging tests clear again at the end so the
shared container can never hand a stored link to a later suite's coordinator.

1. `testLinkVerifiesIntoTheSnapshotAndUnlinkClearsItNeverTouchingTheSystemRecord` — scenario 1:
   link → verified reference in the snapshot (generation bump) → unlink clears stored + published
   claim, the other contact's link survives, the snapshot drops the cleared claim, epoch bumps,
   writer untouched (0 access requests). (Two linked contacts so the post-unlink refresh runs —
   see decision 6.)
2. `testUnlinkModeRuleIsPureAndTotal` — the 4-way `unlinkMode` matrix.
3. `testCopyModeUnlinkCopiesTheDisplayedSystemPhotoThenAssignsAndClears` — F3: copied file
   assigned to `photoFilename` in the same write that cleared the link; the contact still shows
   the same (red) photo from the app-local copy after the snapshot drops the link; no system write.
4. `testCopyModeUnlinkCannotClearBeforeTheCopyCompletes` — behavioural order pin: with the copy
   parked, the link is still stored and no filename assigned; after release both land.
5. `testCopyFailureRefusesToClearAndLeavesNoPhantomFile` — never-lose: `false`, link intact,
   no dangling `photoFilename`, no system write.
6. `testAsIsUnlinkWithAGoneSystemPhotoCompletesWithoutAPhantomFile` — stale link, no crash,
   no invented file.
7. `testClearModeUnlinkRemovesTheAppLocalFileAndTheLink` — file deleted after the record write.
8. `testUnlinkOfAnUnknownContactReturnsFalseAndTouchesNothing` — `false`, no bytes read.
9–13. `syncSystemPhoto` mapping: nil for unknown; `.skippedNoLink` with the writer slot unbuilt;
   `.skippedNoAuthorization(.denied)` (no attempt/intent) and `.limited` attempts; `.written`
   payload byte-identity + `invalidate(identifier:)` + exactly one epoch bump, plus the clear leg;
   `.recordGone`/`.identityMismatch` → refresh fired, no epoch bump, and `.failed` → no refresh;
   missing payload → `.failed(.fetchFailed)` with no write.
14. `testFamilyContactMatchingPhoneIsLinkAwareAndNeverWrongPerson` — own phone wins; a linked
   record's number (different from the contact's own phone) resolves to the family person;
   unrelated number → nil; degraded snapshot → the linked number stops resolving while the
   stored claim is untouched (FR-FCU-006).
15. `testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource` — brace-balanced body extraction
   over comment-stripped source: F3 order indices, the four forbidden write-seam symbols absent
   from the unlink body, the mode/event/refusal vocabulary literals, the lazy seam + init
   assignment, and `syncSystemPhoto`'s consequence lines.
16. `testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource` — the family pass delegation
   (no bare `familyMatch` loop), `familyMatch` < `linkedFamilyMatch` order, `snapshot:
   verifiedLinks`; the R4 gate shape (`requestAccess()` < the status re-read, no `granted`,
   `guard access.allowsReading,`, `access: access`, `snapshot: snapshot`, no `access: .allowed`).

Suite registered in `ios/seniOS.xcodeproj/project.pbxproj` (manual groups — no
filesystem-synchronized groups): PBXBuildFile `B8E4D32EAF5C59B2C7D1E268`, PBXFileReference
`F3C5E7091B2D5F4EAC8B6B32`, four occurrences each; `plutil -lint` OK.

## Decisions made during implementation

1. **`FamilyContactStore` untouched** — the unlink mutates through the coordinator's own
   `load()`/mutate/`save()` (the `updateFamilyContact` pattern), which is what makes the
   photoFilename+clear atomic in ONE write; adding a store mutator would be a second write
   path to the same record.
2. **Copy-mode strictness**: `.unlinkKeepingDisplayedPhotoLocally` with a stored link whose
   bytes cannot be copied (gone/undecodable/rejected) is a REFUSAL (`copy_failed`), not a
   silent downgrade to as-is — the design's "without a successful copy does NOT clear" read
   literally (never-lose > completion). "Already absent" (no stored link) is `true`.
3. **Refusal vocabulary** mirrors §5.2's `claim_refused` precedent rather than inventing a
   new shape: `contacts_link`/`unlink_refused`/`refused` + fixed codes. The frozen `unlink`
   success row is byte-as-specified (nil errorCode, mode outcome token).
4. **Missing payload → `.failed(.fetchFailed)`** rather than a store attempt: no `CNContactStore`
   call without bytes, and the outcome mapping renders the honest kept-on-phone label — a
   fabricated `.written` was never an option (no silent stubs).
5. **Snapshot pass-through into the native pass** — additive to the assignment per §8.2: the
   resolver's `snapshot:` parameter existed (T-150) but the parent call passed only the default;
   the R4 shape feeds it for real.
6. **Last-unlink stale snapshot unchanged** — after the LAST linked contact is unlinked, T-156's
   unlinked-roster early return means no fresh pass runs and the snapshot may retain the entry
   until the next linked mutation. Recorded there as accepted (decision 1) and not re-litigated
   here; the tests observe the drop with a second linked contact held in place.
7. **Test hygiene**: the roster store is a shared simulator-container file — every test clears at
   start, link-staging tests clear at the end (a leftover link would make a later suite's
   coordinator build the REAL link service).

## Verification (speed mode)

- **Final whole-module typecheck: GREEN on the final tree.** `xcodebuild build-for-testing
  -project seniOS.xcodeproj -scheme ElderlyAssistant -destination "platform=iOS Simulator,id=
  14AE2228-4EC9-4CBE-A935-A50DF75A35E2" -derivedDataPath build/DerivedDataTests
  -skip-testing:ElderlyAssistantUITests` → exit 0, zero `error:` lines, `** TEST BUILD
  SUCCEEDED **` (`ios/build/t158-typecheck3.log` / `.exit`); the new test object (17:19:17) is
  newer than the last source edit (17:18:51) — the green build is the final tree.
  Iterations: run 1 failed on ONE parse error (a stray `)` in a source-pin line, `:817`) —
  fixed; runs 2 and 3 green, zero warnings from the files this unit touched.
- **Contention**: T-161's concurrent typecheck owned the shared `build/DerivedDataTests` first;
  its run was allowed to finish (exit 0) before this unit's builds started — no racing.
- **pbxproj**: `plutil -lint` OK; exactly 4 entries for the new file.
- **No PII in logs (NFR-FCU-002):** the two new events are outcome/reason-coded with empty
  metadata; nothing logs an identifier or filename.
- **Scoped suite run: deferred** (speed mode by assignment). The 16 tests exist and compile;
  execution is the remaining evidence for the unit gate.

## Deviations

None from the unit spec or design. The notes file lives at
`specs/T-158-link-unlink-seam-notes.md` as the assignment required (the call-dialer feature's
merged T-158 record occupies `specs/T-158-notes.md` on this branch's base).

## Definition of done (unit spec)

- [ ] Code reviewed and merged — review deferred (speed mode); merge is the orchestrator's call
- [x] All Gherkin scenarios covered by automated tests — link-verifies + unlink-clears (1),
      unlink keeps the photo by copying first (3/4), link-aware missed-call name match (14),
      copy failure refuses to clear with no phantom file (5), gone system photo degrades
      cleanly (6), stale link never resolves the wrong person (14); execution deferred
- [x] F3 pin — copy → assign → clear order, one record write (3, 4, 15)
- [x] Coherent failure state — never-lose refusal leaves the link intact, no dangling
      photoFilename, no orphaned copy (5, 7, 15)
- [x] Zero wrong person — unverified/stale claims are absent from the snapshot and fall
      through (14, 16)
- [x] No PII in logs — outcome/reason-coded events, empty metadata (15 + source read)
- [x] Whole-module typecheck green (log 3, exit 0)

## Files

- `ios/ElderlyAssistant/App/AppCoordinator.swift`
- `ios/ElderlyAssistantTests/App/CoordinatorLinkUnlinkTests.swift` (new)
- `ios/seniOS.xcodeproj/project.pbxproj`
- `specs/T-158-link-unlink-seam-notes.md` (this file)
