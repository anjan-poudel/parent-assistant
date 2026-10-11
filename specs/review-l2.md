# review-l2 — Reviewer report (final): design-l2.md rev 3

**Decision: GO — all criteria met.** The design is complete, internally consistent, and verified against the worktree code through three review rounds: iteration-1 NO_GO items R1, R2, R3 and all minors (resolved in rev 2), iteration-2 residual R4 (resolved in rev 3). No open items.

**Artifact:** `specs/design-l2.md`, rev 3 at worktree commit `e687f075` (design-only change, +21/-3; rev arc `9571e8a7` → `a549d3a7` → `e687f075`), branch `feat/family-contacts-unify`, base master `8089c735`.
**Against:** frozen `specs/design-l1.md`; `specs/define-requirements.md` + lock; `specs/family-contacts-unify/constitution.md` (12 constraints); root `constitution.md` Standards.
**Mode:** read-only; every file:line claim in the reviewed sections re-checked against worktree source at the review commit.

## 1. Rework-resolution table (full arc)

| Round | Item | Status | Verified resolution evidence |
|---|---|---|---|
| Iter 1 | R1 — `.limited` gates on both search surfaces; false 'compile-forced' claim | RESOLVED (rev 2) | §3.5 rewritten with the honest 'NOT uniformly compile-forced' statement; the two-switch claim verified TRUE repo-wide (`MissedCallContactResolver:107` and `SettingsView:2117` are the only switches over `ContactsAccess`); CallView sites enumerated EXACT (`:1343`, `:1347-1362`, `:1370`, `:1379-1388` with `if granted` at `:1383` after the `:1382` status read, `:1413`, `:1519`); optional form correct (`access: ContactsAccess?` at `LeafViews:929`); wizard gates (`refreshSearchAccess :2322-2329`, `grantAccess :2331-2339`; callers `:1977`/`:1983`); caption decided for BOTH surfaces (§3.5 :867-871; §2.2 :539-544); §8.2 rows updated; pins made able-to-fail (`ContactsAccessTests` mapping + per-site `ContactsAccessGateTests`, §6.4) |
| Iter 1 | R2 — §4.2 follow-up input unspecified; 'latest wins' overclaim | RESOLVED (rev 2) | `pendingContacts` overwrite capture on the coalesced path; fast-path drain loop consumes it, so the follow-up never uses the in-flight call's older roster; dirty-during-follow-up lifecycle stated; guarantee re-worded to three precise claims plus the explicit 'generation orders PUBLICATION only; input freshness via the capture'; §3.6 (:895-897), §8.3 drain cases (:1288-1291), §9 R7 (:1309) aligned; loop stress-tested sound under all interleavings (no trigger dropped, one extra pass per burst extension) |
| Iter 1 | R3 — §7 contiguity pin 22-vs-19 mismatch | RESOLVED (rev 2) | Exact 22-line span named between `family.emergencyToggleHint` (:5874) and `family.relationship.brother` (:5942), both excluded, with the 3 pre-existing keys at positions 16-18 (`family.photo.add :5891`, `change :5908`, `remove :5925`); verified against the real `Localizable.xcstrings` scan; the pin can pass as written |
| Iter 1 | Minors — §8.2 typos, one-ulp consequence pin, L10n.fmt locale | RESOLVED (rev 2) | Zero 'ContractsAccess'/'Contentions' matches; the IEEE-754 1.0/0.85 pair explicit at :350-351 and :1281-1282; locale argument present in the sketches |
| Iter 2 | R4 — fifth access consumer (`AppCoordinator.refreshNativeMissedCallNames`) unenumerated and undecided under `.limited` | RESOLVED (rev 3) | §3.5 now enumerates it as the FIFTH `AddressBookDirectory.access()` consumer with the exact fix spec: function range `:8327-8358` verified EXACT against source (decl :8327, closing brace :8358); the `granted`-ternary at :8336 replaced by a post-prompt status re-read (rationale: a limited-selection sheet must not be collapsed to `.allowed`); :8338 guard → `allowsReading` (the granted set enumerates under `.limited`); :8346 real `access:` passthrough, making the resolver's `.limited`-readable arm production-reachable — the test-honesty sub-point is closed; the local-snapshot observation is accurate (`:8331` Task.detached, `:8333` local `access`); §8.2 row (:1284), §6.4 pin scope (now LeafViews.swift, SettingsView.swift AND AppCoordinator.swift, with concrete asserts: :8336 re-read present, :8338 `allowsReading`, :8346 `access: access`, no hardcoded `.allowed`), and §8.3 placement note all updated |

## 2. Enumeration completeness (the R4 basis — confirmed)

`AddressBookDirectory.access()` has exactly five call sites in the app (repo grep, tests excluded): `SettingsView:2323`, `SettingsView:2334`, `LeafViews:1368`, `LeafViews:1382`, `AppCoordinator:8333`. All five are now enumerated and decided in §3.5. The inventory is complete because the only reader of the raw contacts authorization status is `AddressBookDirectory.access()` itself (`AddressBookDirectory:349`); there are no direct `ContactsAccess.from(` callers outside it; and the three contacts-domain `requestAccess()` callers (`LeafViews:1381`, `SettingsView:2333`, `AppCoordinator:8335`) are each covered by an enumerated fix. The remaining `authorizationStatus`/`requestAccess` hits in the codebase are non-contacts domains (speech, calendar, camera, wake settings) — out of scope by construction.

## 3. Checklist verdicts (final)

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Explicit error/outcome return types | PASS | `SystemContactWriteOutcome` total enum; `FamilyPhotoEditorState.from` exhaustive; typed `Outcome`s and raw-coded `error_code`; corrupt decode degrades to nil/defaults |
| 2 | Async/external failure modes + recovery | PASS | Link fetch degrade (snapshot survives); `.written` requires read-back byte equality; never-lose ordering before link clear; face tasks identity-guarded with documented fallbacks |
| 3 | Timeouts/retries — 'no timeouts, no retries, structural bounding' | PASS — satisfies the spirit | No timed waits, no retries at any boundary; single-shot structurally bounded calls (≤12); named constants only (§4.3); §6.3 documents no-retry as the DoS decision; future waits must be named constants (stated) |
| 4 | Traceability §10 honesty | PASS | Spot-checked FR-FCU-003/005/006/007/009/011/012/014 and NFR-FCU-001/002/007/008/009; every element traces to an FR/NFR; no unspecified features |
| 5 | FR-FCU-003 unlinked-pair parity + `.empty` anchor | PASS | Pass 3 gated on verified links; Pass 4 = today's dedupe; `.empty` snapshot ⇒ today's behavior exactly (structurally verified) |
| 6 | FR-FCU-014 ambiguity consequence math | PASS | Strict `<` at `ContactResolver:83-84` with margin 0.15; 1.0 − 0.85 = 0.15000000000000002 (IEEE-754) resolves to name-exact; 0.0/0.05/0.10 deltas ambiguous; the pair is explicitly pinned (:350-351, :1281-1282) |
| 7 | Operator-visible run/failure behavior | PASS | Wizard states, outcome copy, silent/neutral parent surfaces; `.limited` is readable on both search surfaces with the honest caption; missed-call enrichment now reads the granted set under `.limited` (family half + native half) with honest fallback; `.denied` stays quiet and never re-prompts |
| 8 | NFR-FCU-002 log safety | PASS | Six allow-listed keys verified live in `LogSanitiser.allowedKeys:56`; reason codes enumerated; FEATURE_ROOTS format; build-wired checker |
| 9 | NFR-FCU-008 sequencing | PASS | MethodResolver untouched (no row in §8.2; §9 R4 states the split) |
| 10 | NFR-FCU-001 ≤20ms at 12×8 | PASS | Precomputed normalized strings, O(1) map, bounded substring checks; measured ceilings planned |
| 11 | NFR-FCU-007 grapheme pin | PASS | Same `range(of:options:)` semantics as today; Character-cluster case pinned positive AND negative |
| 12 | Four flagged L1 deviations | ALL ACCEPTABLE | Async `invalidate` (actor conformance); `SystemContactWriteAccess.from(ContactsAccess)` (pure mapping, one availability gate); checked `as?` mutableCopy (crash-safety); `common.close` reuse (key verified in the catalog) |
| 13 | Localization — frozen copy | PASS | 21 keys collision-free; 1,389-key baseline exact; neighbor placements verified; exactly 4 keys × one %@; #16 romanized-example exemption documented and bounded; loanword conventions consistent |
| 14 | Concurrency spec | PASS | Drain-loop coalescing sound (stress-tested); isolation matrix matches real ownership; face identity/epoch convergence bounded |
| 15 | Out-of-scope elements | PASS | None found; touched-file list minimal for the feature's contracts |
| 16 | `.limited` enumeration completeness (§3.5 claim) | PASS | Five-consumer inventory complete and all five enumerated (see §2 above) |

## 4. Minor notes

None outstanding. All iteration-1 minors were verified fixed in rev 2; rev 3 introduced no new minors — the :8335-8336 replacement bundle ('discard the Bool, re-read the status') is unambiguous alongside the :8338 guard, the :8346 passthrough, and the new ContactsAccessGateTests asserts.

## 5. Verdict

**GO — all criteria met.** Three review rounds, every finding resolved and re-verified against the worktree code: R1/R2/R3 plus minors in rev 2, R4 in rev 3. The five-consumer access enumeration is complete, the new pins can actually fail, the concurrency mechanism is sound, the FR-FCU-014 math is consistent and pinned, and the frozen L10n copy is verified. Proceed to security-design-review.
