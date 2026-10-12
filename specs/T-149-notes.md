# T-149 — `SystemContactLinkService` — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`). Unit: TG-30 "contacts access, link
verification and matching", the verification half. Agent: dev. Design
references: design-l2 §1.3 (types + failure paths), §4.1 (actor isolation),
§4.2 (single-flight drain with latest-roster capture), §4.3 (photo cache
constants + cache-aside), §4.4–§4.5 (invalidation hooks), §5.2 (closed event
vocabulary), §0 deviation 1 (`invalidate` is `async`); design-l1 §6.1/§6.2/§6.3
(link semantics, duplicate-claim refusal, reachable numbers). Requirements:
FR-FCU-002/004/006, FR-FCU-009, NFR-FCU-001/002/003.

## Status

**Done** — service + seam conformance + test suite written, whole-module
typecheck GREEN, release log-safety gate passes, committed (no push).
Per the 2026-10-12 speed-mode directive: the scoped test-suite RUN is
**deferred to phase end (T-163)** — the tests must exist and compile, and they
do (see "Gate results"). The service is **not** wired into `AppCoordinator`
(T-156's unit).

## Files changed

- `ios/ElderlyAssistant/Services/Contacts/SystemContactLinkService.swift`
  (**NEW**, 419 lines) — `VerifiedLinksSnapshot`; `SystemContactReading` /
  `SystemContactLinkReading` seams; `actor SystemContactLinkService`
  (verification pass, single-flight drain, photo cache, closed-vocabulary
  events). No console writes, no network (both pinned by tests + the repo
  gate).
- `ios/ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift`
  (+26) — `extension AddressBookDirectory: SystemContactReading`
  (`currentAccess()` delegating to the single T-148a mapping;
  `contacts(identifiers:keysToFetch:)` as one identifier-predicate batched
  read over the private store).
- `ios/ElderlyAssistantTests/Services/Contacts/SystemContactLinkServiceTests.swift`
  (**NEW**, 880 lines, 27 tests) — fake `SystemContactReading`; verification
  matrix, degrade paths, duplicate claims, snapshot lookups, drain cases,
  photo-cache contract, event vocabulary, source hygiene.
- `ios/seniOS.xcodeproj/project.pbxproj` — the 8 lines for my two files are
  **already in HEAD**: T-154's commit `0686369a` swept them in with their own
  (same worktree, shared index). Verified:
  `git show HEAD:ios/seniOS.xcodeproj/project.pbxproj | grep -c SystemContactLinkService`
  = 8, and the working tree has no pbxproj delta left for this unit. Nothing
  was re-staged.
- `specs/T-149-notes.md` (this file).

## What was built

### 1. `VerifiedLinksSnapshot` + the two seams (§1.3)

- `VerifiedLinksSnapshot` is the only thing consumers read: `links`
  (`UUID → SystemContactLink`, verified only), `linkedRecordNumbers`
  (`record identifier → that record's CURRENT normalized numbers`, verified
  links only), `generation`. `.empty` (generation 0) is the unlinked anchor —
  the "today's behavior exactly" value of design-l1 §6.2.
- `familyID(forIdentifier:)` — the record→family lookup; deterministic `min`
  tiebreak so even a hand-built (duplicate) snapshot answers reproducibly.
- `familyID(matchingRecordNumber:)` — the number→family lookup, built on
  `MissedCallContactResolver.matches` reused **unchanged** (trailing-digit
  rule, floor 8). Only verified links are consulted: a changed number can
  never resolve to the wrong person. Sorted identifiers keep the answer
  deterministic when two relatives share a landline.
- `SystemContactReading`: `currentAccess()` + one batched
  `contacts(identifiers:keysToFetch:)`. `CNContactStore` is neither
  constructible nor fakeable in unit tests, so this seam is where every test
  scripts the book.
- `SystemContactLinkReading`: `refresh(contacts:)`, `photoImageData(forIdentifier:)`,
  `invalidate(identifier:)`. The caller owns the "record is still verified"
  precondition for photos (§10.1): `photoImageData` answers "what bytes does
  record X hold", not "is X still linked".

### 2. Verification pass (§1.3)

One pass, per the design's failure-path table:

1. Build `stored` in roster order, skipping empty `identifier`/`numberKey`
   (the model's "no linkable record" contract, re-checked).
2. Nothing to verify ⇒ publish the empty snapshot **without a store call** —
   which also means a roster that dropped a link drops the previous
   snapshot's verified link (no link outlives the roster that claimed it).
3. `currentAccess().allowsReading` guard ⇒ **no store call**, snapshot
   unchanged, `degraded` event with `errorCode: nil` (nothing failed; access
   is off) — no retries, no backoff (L1 §13.4), the next trigger re-runs it.
4. ONE batched fetch (`verificationKeys = [identifier, phoneNumbers]`).
   `throw` ⇒ snapshot unchanged, generation **not** bumped, `degraded` +
   `fetch_failed` (stale serves; no empty-snapshot flap).
5. Per stored link, in roster order: first claim of an identifier owns it
   (`claimed` set — later duplicates stay unverified even if their own
   fingerprint would have matched); record absent (deleted, or withheld under
   limited access) ⇒ link excluded, never presented, never a crash; verified
   iff one of the record's current normalized numbers satisfies
   `MissedCallContactResolver.matches(storedKey, currentNumber)` (number
   added or kept ⇒ verified; number changed ⇒ stale).
6. Publish: generation +1, snapshot, `ok` event.

### 3. Single-flight drain (§4.2)

- `refresh` fast path: sets `refreshInFlight`, loops passes, returns the
  snapshot as of its last pass.
- Coalesced path (drain in flight): the roster **overwrites**
  `pendingContacts` (latest wins; never merged, never queued) and the call
  returns the snapshot published so far — an early return the consumer drops
  with its generation guard.
- Capture window: exactly one `await Task.yield()` per loop iteration,
  between the pass and the `pendingContacts` read. Rationale (in-code
  comment): `SystemContactReading.contacts` is synchronous, so without a
  suspension point the whole drain would be atomic with respect to other
  `refresh` calls, `pendingContacts` could never be written, and the
  coalesced path — the Gherkin's "trigger during a drain" — would be dead
  code. The yield is the documented capture window; the in-flight flag stays
  set for the entire drain, so a trigger arriving during any pass takes the
  coalesced path and its roster becomes the follow-up batch. A future edit
  that removes the yield is caught by the coalescing test (it degrades to
  one pass per trigger, which that test fails on).

### 4. Photo cache (§4.3) and invalidation (§4.4/§4.5)

- Named constants: `photoCacheCountLimit = 24` (≈ 12 contacts × 2 sweep
  generations), `photoCacheTotalCostLimit = 16 * 1024 * 1024` (raw bytes,
  `cost: data.count`), `photoKeyHashPrefixLength = 16`.
- Cache key = first 16 hex chars of `sha256(identifier)` — a hash by
  construction; no identifier, or slice of one, is ever a cache-internal
  value that could reach a log or a crash dump (§5.2).
- Cache-aside read: hit ⇒ served without touching the store; miss ⇒ ONE
  fetch for ONE identifier with `photoKeys = [identifier, imageData]` only
  (data minimisation: no names, no numbers). `nil` for absent / store
  failure / unreadable access (no store call in the last case). `nil` is NOT
  cached — an absent photo is re-checked next ask, never remembered as
  absent.
- `invalidate(identifier: nil)` = wholesale (the foreground hook); one
  identifier after our own write. Both are the entire mutation surface.

### 5. Observability (§5.2)

One event per completed pass: `component = contacts_link`,
`eventType = refresh_completed`, outcome `ok`/`degraded`, error code
`nil`/`fetch_failed`, `durationMs` set, metadata `{"entry_count": "<count>"}`
— allow-listed keys only, count-shaped values only. **This file writes
nothing to the console in any build** (§5.2 rule 3): the release log-safety
gate passes, and a source-scan test pins the five console-write tokens.

### 6. `AddressBookDirectory` conformance

Thin glue, nothing decided here: `currentAccess()` delegates to the same
`ContactsAccess.from` mapping every read path uses (re-mapping the status
here would be exactly the version-gate drift `ContactsAccessTests` exists to
catch), and `contacts(...)` is one `CNContact.predicateForContacts(withIdentifiers:)`
fetch over the private store. A withheld record is simply absent from the
result — never an error, never invented.

## Gate results

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project
  seniOS.xcodeproj -scheme ElderlyAssistant -destination 'platform=iOS
  Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18' -derivedDataPath
  build/DerivedDataTests -skip-testing:ElderlyAssistantUITests` (log:
  `ios/build/t149-typecheck4.log`) → `** TEST BUILD SUCCEEDED **`, exit 0,
  **0 errors**. All three touched/created files recompiled in that run
  (forced with `touch`): 0 warnings from `SystemContactLinkService.swift` and
  `SystemContactLinkServiceTests.swift`. The single warning in the log is
  `AddressBookDirectory.swift:282:9: warning: switch must be exhaustive` —
  the pre-existing-in-kind T-148a mapping-switch warning, documented in
  `T-148a-notes.md`, not introduced here.
- **Release log-safety gate: PASS.** `python3 ios/tools/check-release-log-safety.py`
  (repo gate) — the no-console-write and no-content-bearing-event rules cover
  this file.
- **Project regeneration:** `xcodegen generate` ran after the test file
  landed; the resulting pbxproj delta for this unit is 8 lines (2 file refs +
  2 file refs + 4 group/Sources memberships), already committed by T-154's
  `0686369a` (see "Files changed").
- **Scoped `SystemContactLinkServiceTests` run: deferred** to phase end
  (T-163) per the speed-mode directive. Everything below is
  compile-verified and reasoning-checked, **not yet executed** — the first
  T-163 run is the first execution.

## Test coverage (27 tests, written; run deferred)

Fake-first: `FakeSystemContactReader` (lock-protected `access` / `records` /
`failure` / per-fetch `identifiers`+`keys` / `fetchCount` /
`peakConcurrentFetches` / an `onFetch` arrival hook) + a lock-protected `Box`
for spawned-task capture. Records are `CNMutableContact`s — real framework
records whose `identifier` is framework-assigned per instance and get-only
(tests read it back and build the stored link from it, as the wizard does; a
`XCTAssertFalse(identifier.isEmpty)` guard fails loudly rather than silently
linking against nothing).

- **Verification (§1.3)** — verifies with record numbers + one generation
  bump per drain; ONE batched fetch with exactly `[identifier, phoneNumbers]`
  (names/photos asserted absent — data minimisation); number added ⇒ still
  verified; duplicate claim: first in roster order wins, later duplicates
  unverified (and: a stale first claim still owns the identifier, so a
  corrupt payload cannot flip the record→family mapping).
- **Degradation (FR-FCU-006)** — stale (record gone): excluded, generation
  still bumps, stored claim untouched, family contact still resolves by
  number; stale (number changed): excluded, no reachable numbers; fetch
  throw: previous snapshot equal, generation NOT bumped, `fetch_failed`;
  denied/notDetermined: no store call, snapshot equal, `degraded` with nil
  error code; `.limited`: granted record verifies, withheld record absent,
  outcome `ok` (not degraded), no re-prompt; link-less roster: empty
  snapshot, generation bumps, zero store calls, replaces an older snapshot.
- **Snapshot lookups** — by identifier and by number (country-code/format
  tolerance, 8-digit floor, 7-digit no-match); unverified links are
  unreachable by number.
- **Drain (§4.2)** — four tests (see "Determinism of the drain tests").
- **Photo cache (§4.3)** — fetched once then cached; key set exactly
  `[identifier, imageData]`; key = 16-hex-char sha256 prefix, deterministic,
  not a slice of the identifier; the three budget constants pinned; wholesale
  invalidation re-reads, per-identifier invalidation leaves the other record
  cached; nil for absent/unreadable/not-readable and nil is not negative
  cached.
- **Observability + hygiene (§5.2, NFR-FCU-002/003)** — one event per pass
  with the closed vocabulary, `durationMs` set, metadata exactly
  `["entry_count": "1"]` and a subset of `LogSanitiser.allowedKeys`; source
  scan: no `print(`/`debugPrint(`/`NSLog(`/`os_log(`/`fputs(`, no
  `URLSession`/`URLRequest`/`NWConnection`/`NWPathMonitor`/`CFNetwork`.

### Determinism of the drain tests (reasoned at authoring time)

The design's "trigger during a pass" is a race; the assertions were chosen to
hold under EVERY interleaving, or the interleaving is forced:

- *Trigger arriving mid-pass* (test-side call while pass 1 is in flight,
  synchronised on `fetchCount`): fetch order `[A], [B]`, count 2, `max`
  generation 2, `min` generation 1, and the returned snapshot always matches
  the pass it stands for (switch on `generation`). Both outcomes of the race
  — coalesced follow-up, or the late call running its own pass — satisfy all
  of these.
- *Two overlapping drains* (`async let`): exactly 2 fetches, peak
  concurrency 1, exactly one call carries generation 2.
- *Trigger after quiescence*: trivially sequential, generations 1 then 2.
- *Coalescing bound (forced, not raced)*: pass 1's fetch blocks on a
  `DispatchSemaphore` gate, so the actor is held while two roster triggers
  arrive; their calls are parked on the actor before the drain's capture
  read, so **both** take the coalesced path: exactly 2 fetches, the
  follow-up pass verifies the LATEST roster only, the superseded roster is
  never fetched, and both coalesced callers get the generation-1 snapshot
  back. The two 100 ms margins only give each task BODY time to issue its
  call (microseconds of work) while the actor is provably held; no assertion
  depends on them. (Spawning triggers from inside `onFetch` without the gate
  was written first and discarded: a late-spawning body legitimately costs
  its own pass, so `fetchCount ≤ 2` was not an invariant.)

## Decisions

1. **`invalidate(identifier:)` is `async`** — design-l2 §0 deviation 1,
   implemented as flagged. An actor method cannot satisfy a synchronous
   protocol requirement while touching actor state (`#ConformanceIsolation`
   hard error on this toolchain); `@preconcurrency` would silence it but adds
   a runtime isolation trap for protocol-typed callers. Every call site
   already awaits the actor (§4.5). Documented in-code.
2. **The `Task.yield()` capture window** — the one place this file adds a
   suspension the design text implies but does not spell out (see §3 above
   for the rationale and the test that guards it).
3. **Duplicate claims are dropped silently** — the closed §5.2 vocabulary for
   `contacts_link refresh_completed` has no duplicate-specific reason code,
   and §5.2's `claim_refused` row is the coordinator's WRITE-side refusal
   (L1 §6.1), not a verification outcome. Verification's job is to not
   present the duplicate; the write-side unit already prevents persisting
   one.
4. **`entry_count` = the verified-link count that STANDS after the pass** —
   the newly published count on `ok`, the unchanged published count on
   `degraded` (not 0). It is "how many links are live", the number a monitor
   can act on; a degraded pass must not read as "all links gone".
5. **No negative caching of photos** — absent is re-checked each ask rather
   than remembered as absent (a photo can be added in Contacts.app at any
   time; the foreground invalidation hook only covers cache entries).
6. **Key-set constants are typed constants, not literals at call sites** —
   `verificationKeys`/`photoKeys` are the single source for both production
   and the tests' pins (`CNContact*Key` constants are `String` in this SDK;
   the arrays are bridged once at the declaration).
7. **First record wins for duplicate identifiers in a fetch result**
   (defensive only; a store cannot return two records with one identifier).
8. **`SystemContactLinkReading` photos do not re-verify the link** — the
   caller owns that precondition (§10.1), so the cache stays ignorable: the
   service never invents a link, it only serves bytes for a record handle it
   was handed.

## Deviations

None beyond the design's own flagged ones (§0 deviation 1, decisions 1 above).

## Risks / open items

- **T-156 (AppCoordinator) must pass the FULL roster to `refresh`** — a pass
  publishes exactly its batch's verified set (that is the §1.3 "dropped
  contact ⇒ dropped link" rule), so a partial batch would publish a
  partial snapshot. The drain's coalescing assumes callers hand it the
  current whole roster.
- The coalescing guarantee is bounded by the capture window: a trigger that
  arrives after the drain's last capture read runs its OWN pass (correct, and
  covered by the "quiescence" test). The suite pins the follow-up-pass
  behaviour, not the timing.
- The pbxproj entries for this unit live in T-154's commit `0686369a`
  (shared index). If that commit is ever amended or rebased, re-run
  `xcodegen generate` and stage the two entries with whichever unit's commit
  lands next.
- `.limited`-withheld records degrade links to unverified with no
  user-visible signal yet — the honest-caption UX is TG-30's access half
  (T-148b) / the coordinator's surface, not this unit.
