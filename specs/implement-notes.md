# implement — running unit log (family-contacts-unify)

Short per-unit summaries for the engine record (full notes per unit live in
`specs/T-NNN-notes.md`).

## T-145 — FamilyContact identity model and nicknames — DONE

Commit 5914777e. Model: `nicknames: [String]` replaces the single nickname
(no shim); new `SystemContactLink` struct; decoder per design §3.4 (presence
wins, separate legacy-key container, corrupt link → nil, synthesized encoder
kept); `normalizedNicknames` trim/drop/order; 64-char cap (F5).
Compile-forced shared-file minimums (marked in code as T-156 debt):
AppCoordinator add/update still take the single nickname for now;
SettingsView loadDraft/save; ProfileInterviewSteps pass-through.
Gate (run before the speed-mode directive): FamilyContactStoreTests 31/31,
KinDesignationTests 4/4, whole-module build green, zero errors.
Handoff: T-156 must widen the coordinator seam to `nicknames: [String]` +
normalization, otherwise multi-nickname contacts lose entries through the
interim single-field paths.

## T-147 — Frozen L10n keys + disclosure — DONE

Commit 4ffc9389. 21 keys en+ne at the design §7 placements (22-line span
pin; the 3 pre-existing photo keys at 16-18); NSContactsUsageDescription
replaced with the frozen write disclosure; L10nCatalogCoverageTests extended
(coverage + span functions, 14 fixtures, verbatim copy table, the #16
ASCII-exemption pin). Baseline re-measured: 1389 → 1410 (+21).
Whole-module typecheck green (build-for-testing, exit 0). Scoped suite
deferred to T-163 per speed mode. Open: T-144 merge must re-measure the
absolute baseline; SpotifyLocalizationTests count pin pre-existing red at
HEAD (untouched, flagged).

## T-148a — ContactsAccess .limited + identifier plumbing — DONE

Commit d162aa16. ContactsAccess gains .limited + allowsReading + from(_:) as
the single iOS-18 gate; access() delegates; AddressBookEntry.identifier
plumbing (make default, CNContactIdentifierKey, allEntries pass-through).
Compile-forced fallout: MissedCallContactResolver resolve gains the .limited
readable arm (own file); ONE mechanical shared-file fix — wizard searchSection
:2117 case .allowed, .limited (T-148b debt marked in code). New suite
ContactsAccessTests (9 tests incl. the module-wide single-gate scan).
Whole-module typecheck green (build-for-testing, exit 0, 0 errors). Scoped run
deferred to T-163 per speed mode.

## T-151 — FamilyContactIndex — DONE

Commit 7b041b2d. Pure value type per design §1.2/§5.4: Entry set, multi-valued
idsByNickname map, empty anchor, lookups; normalization via the existing
NepaliTextNormalizer only (grapheme pin honored). New suite FamilyContactIndexTests
(17 tests: O(1) map contract, 12x8 perf ceilings incl. 256-char F5 worst case,
Devanagari positive pin, deliberate negative pin, canonical-variant unification,
duplicate holders roster order, rebuild, empty parity, legacy payload decode).
Whole-module build-for-testing green, 0 errors. Scoped run deferred to T-163.
Not wired: coordinator publish (T-156), search tiers (T-152), resolver provider
(T-153).

## T-153 — ContactResolver nickname bands — DONE

Commit 65f6fee9. indexProvider init param (nil = per-call build, test-parity);
band ladder 1.00/0.90/0.85/0.80/0.75/0.60 with the strict < rival rule and
tie-ambiguity unchanged; nearMiss extended over nickname spellings (exactly-one
rule counts contacts). Tests 13 -> 37: the F2 consequence table (three
at-margin decisive rows pinned at 0.15000000000000002, four sub-margin
ambiguous), index-path parity, Devanagari grapheme pin, 12x8 <=20 ms ceiling
(measured ~1.7-2.4 ms in the pre-commit harness). Whole-module build green,
0 errors. Scoped run deferred; handoff: T-156 passes the published index at
the coordinator construction site.

## T-154 — SystemContactPhotoWriter — DONE

Commit 307928d0. The app's first CNSaveRequest surface, confined to one file:
exact §1.4 attempt sequence (attempt-time fingerprint, checked mutableCopy as?,
update-only request, do/catch, read-back byte equality with unverifiable never
success); closed §5.2 event vocabulary; FamilyPhotoEditorState.from exhaustive
no-default; six internal decisions recorded in the unit notes. Suite: 37 tests
incl. the F1 source-level pins (only imageData assigned, update-only request,
ten-marker order pin) and module-wide FeatureSourceScan confinement scans; a
pre-commit dry-run caught and fixed two defects in the scan tests themselves.
Whole-module build green, 0 errors. Scoped run deferred. Handoffs: T-155
FEATURE_ROOTS registration; T-158 injection + preAttemptOutcome use; T-160 label
rendering.

## T-149 — SystemContactLinkService — DONE

Commit 64727330. VerifiedLinksSnapshot + the two reading seams + actor service:
one batched verification fetch (identifier+phoneNumbers keys only), fingerprint
rule reused unchanged, duplicate claims first-in-roster-order, single-flight
drain with latest-roster capture (one documented Task.yield window), photo cache
(24/16 MiB/16-hex sha256 keys, no negative caching), closed-vocabulary events,
no console writes. AddressBookDirectory gains the SystemContactReading
conformance. Suite: 27 tests incl. deterministic gate-forced drain cases.
Whole-module build green + release log-safety gate passes. Scoped run deferred.
Handoff: T-156 must pass the FULL roster to refresh.

## T-152 — UnifiedContactSearch tiers and dedupe — DONE

Commit b0e8dc7f. FamilyMatchTier.nickname at raw 2 (containment renumbered 3);
Outcome.linkedBookNames defaulted; search requires index:, five passes per
design (nickname exact via O(1) map + Character-safe substring; Pass 3
drop/synthesize with name-equal suppression; Pass 4 unchanged; Pass 5 recount;
.empty short-circuit = structural parity). Guards: no phantom drop, one-row-per
person, stale stored claims never merge. Shared-file fixes: 3 call sites in
LeafViews (inline index hoists, T-156 interim). Wizard does not call the unified
search yet (T-159 scope, verified). Tests: 22 existing + 17 new (tier order,
Devanagari pins positive+negative, Pass 3-5, parity anchors, ambiguity, failure
paths, <=20 ms ceiling); the one uncertain Foundation behavior probed standalone.
Whole-module build green, 0 errors. Scoped run deferred.

## T-155 — FEATURE_ROOTS + release-gate coverage — DONE

Commit 432584b8. The three Contacts seam files registered as feature-role
roots in check-release-log-safety.py (design §5.3 block); 3 positive + 3
negative fixtures + 3 expect pins. Evidence: full shell gate exit 0 (24
fixtures/12 rules); injected-PII fixture names each planted file+line;
falsify green; registration-drift caught in an isolated copy. Whole-module
typecheck green (attempt 1 red only on T-150's concurrent mid-wave state, per
protocol waited and retried). Scoped run deferred. One documented limitation
(rule-3 Debug framing) recorded in the notes.

## T-150 — MissedCallContactResolver link-aware — DONE

Commit 56605e1d. linkedFamilyMatch (roster order, snapshot-only, matches
reused unchanged) + resolve(snapshot:) with the §1.8 precedence: family own
phones -> verified links -> native half gated on allowsReading with verified
link identifier remap; notDetermined -> needsPermission; denial -> unresolved.
Default .empty keeps all 4-arg callers unchanged; AppCoordinator untouched
(T-158 wires the real snapshot). Tests: 18 new (32 total) — linked resolution,
precedence, remap, .limited, denial, unlinked parity matrix, roster-order
determinism (5x), single-snapshot semantics, dial-back mirror. Whole-module
build green on a forced recompile of both files (0 errors); release log-safety
gate passes. Scoped run deferred.

## T-144 — Sequencing gate (master merge) — DONE

Call-dialer PR #171 merged to master (81de796a, marker CallChannelChain.swift
present); master merged into feat/family-contacts-unify (commit 78d9a34d).
Conflict resolutions: spec files ours (per-feature records); evidence JSONL
unioned; L10n baseline pins re-measured to the combined catalog (1,415 keys:
dialogue 1_396, calling 1_410, family 1_394); FEATURE_ROOTS unioned (our 3
files + call-dialer's Services/Calls). Merged-tree build-for-testing GREEN
(exit 0). Frozen call-dialer suites deferred to T-163 per speed mode.
Line-anchor drift: L10nCatalogCoverageTests + check-release-log-safety.py are
the union points; downstream units read current file state, not old anchors.

## T-156 — Coordinator identity and link refresh — DONE

Commit 6751cc50. familyContacts.didSet = single roster choke point (index
rebuild + refreshVerifiedLinks); published familyIndex/verifiedLinks/faceEpoch;
lazy link-service seam (first use, never init); generation-guarded publish;
duplicate-claim guard refuses before any write (reason-coded PII-free event);
add/update widened to nicknames: [String] + link: (interim shims removed);
ContactResolver reads the published index. Foreground hook appended after
syncCalendarShare; call-dialer chain untouched (no secondaryCallApp symbols in
the diff). New suite: 9 tests. Log-safety gate exit 0 (24/24 fixtures);
whole-module build green, 0 errors. Scoped run deferred.
