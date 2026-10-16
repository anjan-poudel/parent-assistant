# T-156 — Coordinator identity and link refresh (notes)

**Feature:** family-contacts-unify (TG-31 write seam and coordinator integration)
**Branch:** `feat/family-contacts-unify` (worktree `elderly-ai-assistant-family-contacts-unify`)
**Date:** 2026-10-12
**Mode:** speed — implement + whole-module typecheck + commit only (scoped suite run and per-unit review deferred by the orchestrator)
**Design refs:** design-l2 §1.9, §3.6, §4.4, §4.5, §8.2, §8.3
**Base:** `6c743f32` (T-144 sequencing gate; master / call-dialer PR #171 merged in `78d9a34d`)

## What was built

### 1. `ios/ElderlyAssistant/App/AppCoordinator.swift` — the identity surface

**State block (design-l2 §1.9/§4.4).** `familyContacts` gained the `didSet` choke
point — *the* one place the roster is derived from:

- `familyIndex = FamilyContactIndex(family: familyContacts)` — wholesale rebuild
  (T-151 value type), so the published index can never disagree with the roster
  it was derived from;
- then `refreshVerifiedLinks()`.

New published state: `familyIndex: FamilyContactIndex = .empty`,
`verifiedLinks: VerifiedLinksSnapshot = .empty` (the unlinked-parity anchor:
starts as today's behaviour exactly), `faceEpoch: UInt64 = 0`. Plus
`systemPhotoTokens: [UUID: String]` declared (written only by T-157's face
methods) and `private lazy var linkService: SystemContactLinkReading` — built at
**first use, not init** ([BOOT-REVIEW P0-1]: a launch whose roster carries no
link never constructs a `CNContactStore`).

**Provenance of every roster assignment** (the reason one didSet is enough):
`self.familyContacts = []` in `init` (observers not armed), boot restore assigns
`self.familyContacts = batch.contacts` inside `DispatchQueue.main.async`
(main-confined), and add/update/remove republish inside `DispatchQueue.main.async`.
Boot restore therefore rides the ordinary didSet — nothing was added to the
launch path.

**`refreshVerifiedLinks()` (design-l2 §3.6).** Early-returns unless some roster
contact carries a stored link — no fetch, no service construction, no generation
bump for an unlinked roster. Otherwise: the roster is captured **by value**, one
`Task`, and the result publishes on main only when
`snapshot.generation > verifiedLinks.generation` (the actor's drain is already
single-flight; the coordinator's job is only to drop a stale completion — the
slow-refresh-after-newer-refresh race). On publish, `faceEpoch` bumps iff
`snapshot.links != verifiedLinks.links` — once per identity change, never on a
no-op refresh. No retries/backoff (L1 §13.4); the next trigger re-runs it.

**`refreshContactsIdentity()` (design-l2 §4.5).** Foreground hook:
`invalidate(identifier: nil)` (wholesale photo-cache drop) → `faceEpoch += 1`,
ordered inside one Task (invalidate first, bump second, so a face consumer never
re-resolves under the new epoch against a still-warm cache), then the ordinary
`refreshVerifiedLinks()`. Wired into `handleScenePhase(.active)` as the **last**
statement of the branch, immediately after `syncCalendarShare()`; `.background`
is untouched.

**Duplicate-claim guard (design-l2 §1.9 clause 4; L1 §6.1).**
`static func isDuplicateLinkClaim(_:in:excluding:) -> Bool` — one pure rule both
write paths judge by. An empty identifier is "no linkable record" (§3.5), never a
claim. A refusal emits one reason-coded bus event in the `command_router`
rejection shape — `component: "family_contacts"`, eventType
`family_contact_write_refused`, `outcome: "rejected"`, `errorCode:
"duplicate_claim"`, `metadata: [:]` — PII-free by shape (NFR-FCU-002, §5.2), and
the guard runs **before** anything is written, so a refused add saves no photo
and a refused update leaves the stored claim intact.

**Write-path widening (the T-156 debt from T-145).**
`addFamilyContact(id: UUID = UUID(), …, nicknames: [String] = [], …, link:
SystemContactLink? = nil)` and `updateFamilyContact(…, nicknames: [String] = [],
…, link: SystemContactLink? = nil)` — the interim single-`nickname` shims are
gone; both paths normalize through `FamilyContact.normalizedNicknames` (the one
point every caller passes). `add` takes the caller's `id` (the wizard stages a
draft id across steps). On `update`, a non-nil `link` sets/replaces the stored
claim; **nil leaves the stored link unchanged** — clearing a link is
`setFamilyContactLink`, T-158 only.

**Resolver seam.** `contactResolver` now passes
`indexProvider: { [weak self] in self?.familyIndex ?? .empty }` alongside the
existing contacts provider, so the voice resolver and the search tiers judge one
published projection.

**Test seam.** `init(profileStorage:wireProfilePersonalization:
systemContactLinkService:)` — same pattern as the shipped `profileStorage` seam;
the injection lands before the roster's first assignment, and the empty-roster
early return means no address-book handle is built during init on any path.

### 2. Call sites

- `ios/ElderlyAssistant/App/SettingsView.swift` — wizard `save()` passes
  `nicknames: nick.map { [$0] } ?? []` to both write paths; `loadDraft` comment
  rewritten to state the (now narrower) interim loss window: only this
  single-field wizard until T-160's §2.5 list editor.
- `ios/ElderlyAssistant/App/ProfileInterviewSteps.swift` — the T-100
  kin-designation pass-through carries `entry.contact.nicknames` **verbatim**
  (no longer `.first`), so a flag write can no longer drop entries.
- `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` — doc only:
  `normalizedNicknames` now records the third application (the coordinator save
  path) as landed.

No UI for the new state (T-159+), no faces (T-157), no link/unlink seam and no
missed-call wiring (T-158) — out of scope by assignment.

## Decisions made during implementation

1. **Last-unlink stale snapshot — accepted, not deviated.** After the LAST
   linked contact is unlinked, the empty roster's early return means no fresh
   pass runs, so `verifiedLinks` can retain the last verified entry. It is
   reachable only through roster-intersecting consumers (the snapshot's
   `familyID(forIdentifier:)` still resolves); the assignment pins the
   early-return, and design §3.6 owns the trade — recorded here as a known,
   accepted shape, not a bug fix.
2. **Guard placement: before the photo save** on both paths, so a refusal can
   never orphan a photo file (the "refused write persists nothing" property is
   test-pinned).
3. **Boot path needed no new code** — verified by tracing every roster
   assignment (see §1); adding a parallel trigger would be a second code path to
   the same choke point.
4. **`faceEpoch` bump = links-dict inequality**, not generation change: a
   re-verification that confirms the same set is not an identity change (pinned
   by the no-op test).
5. **Refusal vocabulary** reuses the CommandRouter rejection shape rather than
   inventing a new one; verified against the release log-safety gate's
   allow-list rules (gate green below).
6. **Tests drive the real coordinator and the real `FamilyContactStore`**
   (the store's storage is a hard-typed `EncryptedLocalStorage`, so no in-memory
   roster is injectable without widening production). Each test starts from
   `clearRoster` (the store is shared across tests in a run) and the
   linked-contact tests clear again at the end, leaving the container unlinked
   for whatever runs next.

## Tests (exist and compile; scoped RUN deferred by speed mode)

New: `ios/ElderlyAssistantTests/App/CoordinatorIdentityRefreshTests.swift`
(9 tests; fake `SystemContactLinkReading` via the init seam — no
`CNContactStore` in any test; `Gate` actor parks the first refresh for the
generation race; `waitUntil` polling for the main-actor publishes; Mirror-based
lazy-slot probe):

1. `testRosterMutationRebuildsThePublishedIndexWholesale` — add/update/remove
   each rebuild the index; save-path normalization (`"  Sit  "` → `"Sit"`, blanks
   dropped, order kept); replaced nickname keys do not survive.
2. `testGenerationGuardDiscardsAStalePublication` — held older pass completes
   after a newer publish; generation does not regress, links stay the newer ones.
3. `testNoOpRefreshDoesNotBumpTheEpoch` — same links, newer generation: published,
   epoch unchanged (exactly one bump for the first link).
4. `testDuplicateLinkClaimIsRefusedOnAddAndUpdate` — refused add persists
   nothing; refused update leaves the stored claim; a contact may re-save its own
   claim.
5. `testAnUnlinkedRosterNeverFetchesAndNeverBuildsTheService` — explicit trigger +
   unlinked add: lazy slot still unbuilt, `verifiedLinks == .empty`,
   `faceEpoch == 0`.
6. `testForegroundIdentityRefreshInvalidatesBumpsOnceThenRefreshes` — one
   `invalidate(nil)`, exactly one epoch bump, refresh re-runs, no second bump.
7. `testDegradedSnapshotPublishesAndNeverRewritesTheStoredClaim` — stale link
   absent from the snapshot (`familyID(forIdentifier:) == nil`), stored claim
   untouched (FR-FCU-006), one epoch bump.
8. `testTheLinkServiceIsResolvedAtFirstUseToTheInjectedInstance` — lazy slot
   empty at init, resolved to the injected instance on first linked refresh.
9. `testWiringAndVocabularyArePinnedAtTheSource` — the `handleScenePhase(.active)`
   tail call, the boot-restore assignment, the didSet lines, the refusal
   vocabulary, the lazy declaration, the indexProvider wiring, and the absence of
   the interim `nickname:` shim (the Spotify-suite split for platform-unreachable
   wiring).

`ios/seniOS.xcodeproj/project.pbxproj` — the four entries the test target needs
(it uses no filesystem-synchronized groups): PBXBuildFile, PBXFileReference, App
group child, Sources phase; `plutil -lint` OK.

## Verification

- **Release log-safety gate** (`bash ios/tools/check-release-log-safety.sh`):
  **exit 0** — "no transcript content or raw error object can be printed in a
  non-Debug configuration…", plus 24/24 fixture cases over 12 rules.
- **Whole-module typecheck** (from `ios/`, warm `build/DerivedDataTests`):
  `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme
  ElderlyAssistant -destination "platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2"
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`
  → **exit 0, 0 errors, `** TEST BUILD SUCCEEDED **`**, new test file compiled
  (log: `ios/build/t156-typecheck.log`). One iteration was needed: the fake's
  bare `NSLock.lock()/unlock()` in async contexts (Swift-6-mode warnings in my
  new file) were replaced with scoped `withLock`; re-run is warning-clean for
  every file this unit touched.
- **Scoped suite run: deferred** (speed mode by assignment). The tests are
  compile-verified only; the deferred run is the remaining evidence.

## Call-dialer union (master merged)

Master's call-dialer chain (PR #171) is carried untouched: the diff mentions no
`secondaryCallApp` / `resolvedCallChannel` / `resolvedMissedCallChannel` /
missed-call symbol at all. The only shared region is `handleScenePhase(.active)`,
where T-156 appends `refreshContactsIdentity()` after the existing
`syncCalendarShare()` and leaves `.background` byte-identical. Typecheck confirms
their chain still compiles.

## Deviations

None from the unit spec or design-l2. Documented subtleties: the last-unlink
stale snapshot (decision 1) and the wizard's single-field interim nickname loss
(decision, T-160 closes it).

## Files

- `ios/ElderlyAssistant/App/AppCoordinator.swift`
- `ios/ElderlyAssistant/App/SettingsView.swift`
- `ios/ElderlyAssistant/App/ProfileInterviewSteps.swift`
- `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift`
- `ios/ElderlyAssistantTests/App/CoordinatorIdentityRefreshTests.swift` (new)
- `ios/seniOS.xcodeproj/project.pbxproj`
- `specs/T-156-notes.md` (this file)
