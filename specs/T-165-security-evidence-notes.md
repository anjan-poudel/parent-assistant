# T-165 — Security evidence index, F8 residual, F4/F6 doc accuracy, feasibility report (notes)

**Unit:** T-165 (TG-33, `security evidence and feasibility honesty`) · **Branch:** `feat/family-contacts-unify` · **Base:** `4d4d1e28` (T-163 record; master tip `81de796a` = merge-base).
**Date:** 2026-10-12 · **Mode:** speed mode — documentation/evidence assembly; no suite run required (the evidence cited already passed at T-163). No production code was touched.
**Note-path deviation:** call-dialer owns `specs/T-165-notes.md`; per dispatch, this unit's notes live here (`specs/T-165-security-evidence-notes.md`).

---

## 1. What was built

| File | Change | Consumer |
|---|---|---|
| `specs/FCU-security-evidence-index.md` | **NEW** — the one document the `security-test` gate reads: F1..F8 closure index with per-row verifier commands, a 21-row STRIDE evidence index (S-1..S-4, T-1..T-5, R-1, I-1..I-5, D-1..D-4, E-1..E-4), NFR-FCU-002/003/009 evidence rows, residuals R-1..R-8, gaps G-1..G-6, the freshness-run record (T-163's 32-suite sweep), and the honesty/validation statements | `security-test` |
| `specs/FCU-feasibility-honesty-report.md` | **NEW** — FR-FCU-016 per-ask verdicts (LINK / PHOTO / NICKNAMES) with evidence pointers and stated bounds; implementation layers PARTIALLY DEMONSTRATED, device verdicts OUTSTANDING (T-164), no device claim anywhere | `final-sign-off` (T2), the owner |
| `specs/design-l2.md` §2.6 (line 699) | Comment aligned: `// .skippedNoLink or nil outcome → today's UX (F4, T-165: .written → .updatedInSystem, shown)` — matches §1.5's mapping and the implemented `FamilyPhotoEditorState.from` | security F4 |
| `specs/design-l1.md` §10.2 step 3 | The same F4 alignment ("dismiss (today's UX)" → "show the honest label (§10.3: `.updatedInSystem`; the sheet stays open)"), discharging the alignment the shipped T-160 code comment (`SettingsView.swift:3737-3739`) explicitly deferred to T-165 | security F4 |
| `specs/design-l2.md` §3.5 | **Footnote added** for the one adjacent `allEntries()` consumer: `AppCoordinator.makeDialectBiasProfileProvider` — definition `AppCoordinator.swift:2660`, call `:2664`, call sites `:1337`/`:1377`, verified at `4d4d1e28` (review-time anchor was `:2529` at `f6ba251b`); not an `access()` consumer, behaviour unchanged | security F6 |

Commit: **`6e86ebd9`** (this notes file is its own follow-up commit, house pattern). No push.

## 2. F1..F8 closure summary (detail and verifier commands in the index)

| ID | Advisory | Closing artifact | Status |
|---|---|---|---|
| F1 | `PhotoWriteIntent` assertion documentation-grade | T-154 source-level assertions (`testOnlyImageDataIsAssignedOnTheMutableContact`, `testTheSaveRequestIsUpdateOnly`) + confinement scans (`testCNSaveRequestAndCNMutableContactLiveOnlyInTheWriterFile`, `testCNContactStoreConstructionsStayInTheAllowedFiles`) + T-155 gate roots/fixtures; SystemContactPhotoWriterTests 37/0 | **CLOSED** |
| F2 | Two at-margin band pairs decisive but unpinned | T-153 consequence table: `testConsequenceTablePinsTheBandingConstants` (0.90−0.75 and 0.75−0.60 = `0.15000000000000002` ≥ margin ⇒ decisive) + the two pair rows + the kept 1.00/0.85 row; ContactResolverTests 37/0 | **CLOSED** |
| F3 | Unlink must assign the copied `photoFilename` | T-158 pins: `testCopyModeUnlinkCopiesTheDisplayedSystemPhotoThenAssignsAndClears`, `testCopyModeUnlinkCannotClearBeforeTheCopyCompletes`, source-order pin in `testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource` ("assignment + clear reach the store in ONE write"); CoordinatorLinkUnlinkTests 16/0 | **CLOSED** |
| F4 | §2.6 comment vs §1.5 | T-160 implemented `.written` → `.updatedInSystem` shown (`testWrittenMapsToUpdatedInSystemAndTheTableIsTotal`, `testFailurePathsNeverRenderUpdatedInSystem`); T-165 aligned design-l2 §2.6 **and** design-l1 §10.2 step 3; FamilyWizardPhotoSaveTests 18/0 | **CLOSED** |
| F5 | No length bounds | T-145 64-grapheme editor cap (`FamilyContact.cappedNickname`, cluster-safe; `FamilyContactStoreTests.testNicknameCappedAtSixtyFourCharactersAtTheEditorSeam` + editor twin) + T-151 256-char worst-case perf pin (`FamilyContactIndexTests.testLongStringWorstCaseEntryStaysWithinTheCeilings`, 1.59–1.60 ms build / 0.007–0.011 ms query vs 20 ms) | **CLOSED** |
| F6 | `makeDialectBiasProfileProvider` outside §3.5 | T-165 §3.5 footnote with the post-T-144-verified anchor (`:2660` at `4d4d1e28`); behaviour unchanged; per-site access-gate pins noted (naming divergence → R-8) | **CLOSED** |
| F7 | Accepted honest false-negative | No action — rationale recorded: `.written` requires read-back byte equality so a false success is impossible; `.failed(.readBackMismatch)` may under-claim (kept-on-phone while the card got the photo) — the safe direction, kept as-is by the review. Pinned by `testReadBackVerificationMatrix`, `testUnverifiableReadBackIsNeverSuccess`, `testEveryFailureRawValueMapsToAKeptState` | **NO ACTION — recorded with rationale** |
| F8 | Shared-number fingerprint residual | Accepted residual recorded in full (mechanism: `fingerprintHolds` accepts any current number satisfying the shared floor-8 rule; compound coincidence required; impact bounded to one `imageData` field; not unit-testable — real `CNContactStore` needed) with the DV-session pointer (T-164, DV-3/DV-4) so `security-test` reads it as recorded, not as a finding | **ACCEPTED RESIDUAL — recorded** |

No F row is OPEN; no gap was silently omitted.

## 3. Decisions made during implementation

1. **Two F4 edits, not one (design-l2 §2.6 + design-l1 §10.2 step 3).** The task file assigns the §2.6 comment alignment. The shipped T-160 code comment at `SettingsView.swift:3737-3739` explicitly records that design-l1 §10.2 step 3's wording alignment "is deferred to T-165". Shipping T-165 without doing it would leave a recorded deferral unfulfilled and the design record still self-contradictory (§10.2 step 3 vs §10.3's own table). Both edits are one-line-scale, doc-only, and recorded here; production code was left untouched per the unit rule (`no production code changes`), so the T-160 code comment (pinned by `testF4CommentRecordsTheDeliberateLabelAndTheT165Deferral`) still contains "F4" and "T-165" and stays green.
2. **F6 anchor verified against the merged tree, divergence recorded.** Review-time anchor `:2529` (`f6ba251b`) now `:2660`/`:2664` (definition/call) at `4d4d1e28`; the footnote states both, so no stale reference ships.
3. **Index validated mechanically where possible, limitation stated (R-7).** Unlike LCT/SP/MTC there is no in-target parser suite for this index. Authoring checks actually run: (a) every cited `<Suite>.<test>` token (35 unique) resolves to a `func` in the matching suite file — 35/35, 0 misses; (b) every cited suite exists and is in T-163's recorded 32-suite sweep; (c) verifier commands re-runnable — the log gate was re-run for this index (`bash ios/tools/check-release-log-safety.sh` → exit 0, `/tmp/t165-gate.log`).
4. **F8 recorded for the DV session, not "covered".** No unit test can reproduce the compound coincidence (`CNContactStore` not fakeable); it is recorded as an accepted residual with the T-164 pointer so `security-test` does not rediscover it.
5. **Two count/anchor corrections found while assembling evidence (recorded in the index, not silently harmonised):** T-163 §6's "4 FCU roots" is imprecise — the engine registers exactly three FCU roots (`check-release-log-safety.py:192-194`, verified); and the runtime sanitiser choke point (security review P8) has moved to `AppCoordinator.swift:12792` (review-time `:11666`).
6. **Suite-name divergence recorded (R-8):** design-l2 §6.4 proposed a dedicated `ContactsAccessGateTests`; the shipped per-site `allowsReading` pins live in `CallViewFacesAndCaptionTests.testEveryCallViewReadableGateReadsAllowsReading`, `FamilyWizardFindStepTests.testWizardAccessGatesReadAllowsReadingWithTheLimitedCaptionUnderTheField` and `CoordinatorLinkUnlinkTests.testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource`. Equivalent enforcement, different homes — recorded so it is not read as missing coverage.
7. **Feasibility report is its own file.** FR-FCU-016's consumer is the T2 sign-off (it must "ride the sign-off record"); the security-test gate reads the index. Splitting them keeps each document's honesty sections clean while the index cross-references the report and the report cross-references the index's residual rows.
8. **NFR-FCU-003 inspection performed for this unit** (not just quoted): every feature-changed product Swift file scanned for transport/network primitives — zero feature-introduced hits; the two files with tokens carry only pre-existing non-egress uses (recorded in the index NFR row). Stated limit G-4: the writer/index files have no dedicated network-symbol source pin.

## 4. Test results / verification performed

- **No suite run** — per the unit's speed-mode instruction (documentation/evidence assembly; the sweep evidence already passed at T-163 and is referenced, not re-run).
- **Release log-safety gate:** re-run for the index — `bash ios/tools/check-release-log-safety.sh` **exit 0** (24 fixtures over 12 rules; three FCU roots scanned), `/tmp/t165-gate.log`.
- **Index integrity checks:** 35/35 cited test tokens exist and pair to their suite files; 22/22 cited suites are in T-163's sweep (SystemContactPhotoWriterTests 37/0, ContactResolverTests 37/0, CoordinatorLinkUnlinkTests 16/0, FamilyContactStoreTests 31/0, FamilyContactIndexTests 17/0, FamilyWizardPhotoSaveTests 18/0, FamilyWizardFindStepTests 17/0, CallViewFacesAndCaptionTests 10/0, ContactsAccessTests 11/0, SystemContactLinkServiceTests 27/0, CoordinatorIdentityRefreshTests 9/0, CoordinatorFaceIdentityTests 8/0, FamilyListLinkChipTests 5/0, UnifiedContactSearchTests 36/0, L10nCatalogCoverageTests 26/0, MissedCallContactResolverTests 32/0, MissedCallDialBackTests 22/0, VoiceContactSearchRouteTests 30/0, ContactPhotoStoreTests 16/0, FamilyContactValidationTests 5/0, SystemContactSearchTests 10/0, MethodResolverTests 17/0).
- **Doc-edit greps:** `F4` present in `design-l2.md` §2.6 and `design-l1.md` §10.2 step 3; `makeDialectBiasProfileProvider` present in `design-l2.md` §3.5 and at `AppCoordinator.swift:2660`/`:2664`/`:1337`/`:1377`.
- **Typecheck/lint:** not applicable — no source code changed (spec/design Markdown only).

## 5. Open items (carried, not closed here)

- **DV-1..6 device validation (T-164) is outstanding** — the completion gate; the feasibility report makes no device claim and the index's device rows are marked OPEN/OUTSTANDING.
- Device Release-build console check (NFR-FCU-002's device half) — T-164.
- Index gap G-4 (no network-symbol pin for the writer/index files), G-5 (gate indirection limits), G-6 (22 pre-existing baseline failures, master-owned) — recorded in `specs/FCU-security-evidence-index.md`.
- The index is not parser-validated in-target (R-7); if a later unit wants a parser, `SpotifySecurityEvidenceIndexTests` is the pattern to copy.

## 6. Delivery

- Commit `6e86ebd9` (artifacts + design edits), followed by the record commit for this notes file. No push.
