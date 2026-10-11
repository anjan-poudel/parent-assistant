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
