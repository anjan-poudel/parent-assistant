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
