# T-150 — `MissedCallContactResolver` link-aware resolution — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`). Unit: TG-30 "contacts access, link
verification and matching", the missed-call/dial-back half. Agent: dev. Design
references: design-l2 §1.8 (the resolver change, the precedence order), §8.2
(placement table), §3.5 (`refreshNativeMissedCallNames` gate enumeration —
T-158's, untouched here); design-l1 §6.3 (reachable numbers), §7.3. Requirements:
FR-FCU-004 (one person on every surface), FR-FCU-006 (stale links degrade, never
a wrong person). Depends on T-148 (`allowsReading`/`.limited`, landed) and T-149
(`VerifiedLinksSnapshot`, landed at `64727330`).

## Status

**Done** — resolver + tests written, whole-module typecheck GREEN (forced
recompile of both my files, `TEST BUILD SUCCEEDED`, 0 errors, 0 warnings from
them), release log-safety gate passes, committed (no push). Per the 2026-10-12
speed-mode directive: the scoped test-suite RUN is **deferred to phase end
(T-163)** — the tests must exist and compile, and they do (see "Gate results").
`AppCoordinator` call sites are **not** touched (T-158's unit).

## Files changed

- `ios/ElderlyAssistant/Services/Contacts/MissedCallContactResolver.swift`
  (+~114 lines) — NEW `linkedFamilyMatch(phone:in:snapshot:)`; `resolve` gains
  `snapshot: VerifiedLinksSnapshot = .empty` with the §1.8 precedence (family
  own phones → verified links → native book, the last gated on
  `access.allowsReading` with the identifier remap); doc comments updated to
  document the precedence and the access/state contract. Signature-compatible:
  the 4-argument call shape compiles unchanged (proven by the whole-module
  build: `AppCoordinator.swift:8358` was not edited).
- `ios/ElderlyAssistantTests/Services/Contacts/MissedCallContactResolverTests.swift`
  (+~408 lines; 18 new tests, 14 pre-existing untouched → 32 total) — linked
  correlation, precedence, remap, `.limited`, denial, unlinked parity,
  roster-order determinism, single-snapshot semantics, the dial-back mirror.
- `ios/ElderlyAssistantTests/Services/Contacts/MissedCallDialBackTests.swift` —
  **untouched, verified to still compile** (part of the test target build).

## What was built

### 1. `linkedFamilyMatch(phone:in:snapshot:)` — the link-aware half

The family contact whose VERIFIED linked record carries the number, or nil:

```swift
for contact in contacts {                       // ROSTER order decides
    guard let link = snapshot.links[contact.id],
          !link.identifier.isEmpty,             // "no linkable record", §3.5/§3.4
          let numbers = snapshot.linkedRecordNumbers[link.identifier]
    else { continue }
    if numbers.contains(where: { matches(phone, $0) }) { return contact }
}
```

- **Roster order**, deliberately: the answer is deterministic when two linked
  relatives share one landline, and "first in the family editor's order" is the
  order the user curates. The snapshot's own
  `familyID(matchingRecordNumber:)` orders by record identifier (an iOS handle
  artifact), so delegating to it would pick a different claimant in that tie —
  documented in the function, pinned by a test whose identifier sort order is
  the reverse of the roster order.
- **Snapshot-only**: `contact.systemContact` is never read. A stored link the
  verification pass dropped (record deleted, number changed, unreadable access)
  is absent from the snapshot → nil → fall-through to the unlinked path
  (FR-FCU-006). A snapshot link whose contact has left the roster is never
  returned either — the roster is what is iterated.
- Reuses `matches` (the trailing-digit rule) UNCHANGED, as required.

### 2. `resolve(phone:family:native:access:snapshot:)` — the §1.8 order

```
1. familyMatch on the family's own phones        → .name (unchanged, ungated)
2. linkedFamilyMatch                             → .name (the linked FAMILY person)
3. access.allowsReading gate:
   .allowed/.limited → nativeMatch:
        matched entry with a VERIFIED-link identifier → that family contact's name
        otherwise                                      → the book name
   .notDetermined    → .needsPermission
   non-readable      → .unresolved (honest denial)
```

- **Default argument `.empty` = today's behavior exactly**: every pre-existing
  call site (all 4-argument) compiles and behaves identically.
- **`.limited` read arm** (R2): the gate is `allowsReading`, so a granted subset
  is consulted exactly like `.allowed`; a person outside the selection is an
  honest "no match", never a denial claim.
- **Identifier remap** (step 3): the entry's `identifier` is looked up among the
  current roster's VERIFIED links (roster order for the tie); a hit returns the
  family contact's name. This covers the record that gained a number after the
  last verification pass (the snapshot's recorded numbers lag) — the person is
  proven (identifier is in the snapshot) even though the *number* is not yet in
  `linkedRecordNumbers`. Empty identifier never remaps (both sides guarded).
- No new dependency: still a Foundation-only `enum`, no CNContact, no
  coordinator, no observability, no console write, no network, no LLM/brain
  path — dial-back naming stays deterministic and local even if the brain
  process is gone (DoD item).
- `NameResolution` is unchanged; no new cases, so every existing consumer
  switch stays exhaustive.

## Gate results

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project
  seniOS.xcodeproj -scheme ElderlyAssistant -destination 'platform=iOS
  Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18' -derivedDataPath
  build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`:
  - `ios/build/t150-typecheck.log` — first run: 64 errors, **all** in
    `UnifiedContactSearchTests.swift` (T-152's file, mid-edit by a concurrent
    agent at the time). Zero errors named any file of mine, and the production
    module (my resolver included) compiled clean in that run.
  - `ios/build/t150-typecheck2.log` — retry after the concurrent build cleared:
    `** TEST BUILD SUCCEEDED **`, 0 errors.
  - `ios/build/t150-typecheck3.log` — **forced evidence run**: both my files
    `touch`ed first, so the log shows `Compiling MissedCallContactResolver.swift`
    and `Compiling … MissedCallContactResolverTests.swift` and ends
    `** TEST BUILD SUCCEEDED **`, exit 0, **0 errors**, **0 warnings** from my
    two files (the 16 warnings in the log are other agents'/pre-existing
    files). The linked test bundle contains the new test symbols
    (`nm … ElderlyAssistantTests | grep testLinkedFamilyMatch` → 41 symbols).
- **Release log-safety gate: PASS.** `python3 ios/tools/check-release-log-safety.py`
  → exit 0.
- **Scoped `MissedCallContactResolverTests` + `MissedCallDialBackTests` run:
  deferred** to phase end (T-163) per the speed-mode directive. Everything
  below is compile-verified and reasoning-checked, **not yet executed** — the
  first T-163 run is the first execution.
- No project regeneration needed (no new files; `xcodegen` untouched).

## Test coverage (32 tests in the suite; 18 new, run deferred)

Test-side fakery is the house pattern: `linkedContact(id:name:phone:identifier:)`
builds a contact with a STORED link (the claim), `verifiedSnapshot([...])` builds
the PUBLISHED snapshot (the proof) with explicit record numbers, so every test
states which side of the claim/proof line it exercises.

Acceptance scenario "Linked number resolves to the family contact" →
`testLinkedFamilyMatchResolvesRecordNumberToFamilyContact`,
`testLinkedFamilyMatchUsesTrailingDigitRule`,
`testResolutionResolvesLinkedRecordNumberToFamilyName`, and the dial-back mirror
`testMissedCallAndDialBackSurfacesAgreeOnTheLinkedPerson` (the `familyMatch` then
`linkedFamilyMatch` composition T-158 wires into
`AppCoordinator.familyContact(matchingPhone:)` returns the same id/name the
missed-call resolution does).

Store precedence → `testResolutionFamilyOwnPhoneWinsOverAnotherContactsLinkedRecord`
(source 1 beats source 2 regardless of roster position),
`testResolutionPrefersLinkedFamilyOverNativeBookName` (source 2 beats source 3).

Acceptance scenario "Unlinked numbers are unchanged" →
`testUnlinkedParityEmptySnapshotMatchesPreFeatureResults`: a six-row matrix
(family hit / native hit / no match / `.notDetermined` / `.denied` / `.limited`)
asserted BOTH via the defaulted 4-arg call and the explicit `snapshot: .empty`,
plus the stored-but-unverified-link row; the 14 pre-existing tests are the
second parity pin (they compile and are unchanged).

Acceptance scenario "Stale link degrades to the unlinked path" →
`testLinkedFamilyMatchIgnoresStoredLinksAbsentFromTheSnapshot` (empty snapshot;
re-published snapshot whose record no longer carries the old number).

Failure paths → `testResolutionDeniedWithNoVerifiedLinksIsTheHonestEmptyResult`
(no crash, no invented name, source 1 still answers);
`testResolutionAnswersFromOneSnapshotDuringADrain` (two claimants in one
snapshot → roster-first, five repeats; the later publish answers only calls made
with it — a torn read across two snapshots is impossible for a pure enum taking
one value).

Identifier remap → `testResolutionRemapsVerifiedLinkedRecordToFamilyName`,
`testResolutionKeepsBookNameForUnlinkedIdentifier`,
`testResolutionNeverRemapsOnAnEmptyIdentifier`.

`.limited` → `testResolutionConsultsNativeUnderLimitedAccess`,
`testResolutionRemapsUnderLimitedAccess`.

Churn/robustness → `testLinkedFamilyMatchSkipsSnapshotLinksWithoutARosterContact`,
`testLinkedFamilyMatchFollowsRosterOrderNotIdentifierOrder`,
`testLinkedResolutionDoesNotDependOnLiveAddressBookAccess`.

## Decisions

1. **Roster order, not `VerifiedLinksSnapshot.familyID(matchingRecordNumber:)`,
   for the two-linked-claims tie.** Both are deterministic; the roster is the
   user-visible order and matches the unit spec's wording ("roster order"). The
   snapshot helper would have picked the lexicographically smaller record
   identifier. Test 4 makes the two orders disagree on purpose.
2. **The linked half is not access-gated.** §1.8 gates only the native half;
   `linkedFamilyMatch` reads local, already-proven state and performs NO
   address-book read. T-149 keeps the last snapshot when access turns unreadable
   ("stale serves"), so after a revocation the linked number still names the
   person the user themselves linked — reverting to the raw number would be the
   regression, not the privacy fix. The fresh-denial case (no verified links)
   is still the honest empty answer, pinned by test.
3. **Empty-identifier guard inside `linkedFamilyMatch`.** Mirrors the model-level
   rule the T-149 pass re-checks ("an empty identifier is no linkable record,
   never a link target") so even a corrupt, hand-built snapshot cannot invent a
   link. Pinned by `testResolutionNeverRemapsOnAnEmptyIdentifier`.
4. **Remap resolution uses roster order** (`family.first { … }`): unique by
   construction (duplicate identifier claims lose at verification), but
   deterministic if a hand-built snapshot violates that.
5. **`NameResolution` untouched; `snapshot` defaulted** so the change is purely
   additive at the API level — no call-site churn, no new exhaustive-switch
   burden, and T-158 can wire the real snapshot in without a compile cascade.
6. **No observability/logging added.** This is a synchronous pure function on a
   safety-adjacent path; there is nothing to log that would not name a person or
   number (NFR-FCU-002), and the log-safety gate stays green by construction.

## Deviations

None.

## Risks / open items

- **The linked half is inert until T-158 passes the real snapshot** at the
  coordinator call sites (`refreshNativeMissedCallNames` :8358 and
  `familyContact(matchingPhone:)` :8367). Units T-150 and T-158 merge together
  for the end-to-end behavior; the defaulted argument is what keeps the
  intermediate state honest (unlinked semantics) rather than broken.
- The scoped suite run is deferred to T-163. Highest-value first executions:
  the two roster-order/determinism loops and the parity matrix.
- For the T-163 acceptance authoring: "resolution runs while access is denied"
  is honest-empty **with no verified links**; with a snapshot that still carries
  a verified link, decision 2 above is the intended behavior (the link is local
  proven state). Flagged here so the acceptance test states which state it sets.
