# FCU security evidence index — family-contacts-unify (T-165)

**Feature:** `family-contacts-unify` (LINK / PHOTO / NICKNAMES unify) · **Gate this index is written for:** `security-test` (workflow `specs/family-contacts-unify/workflow.yaml:193-208`).
**Worktree / branch:** `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` @ `feat/family-contacts-unify`; authoring base HEAD `4d4d1e28` ("implement: record T-163 acceptance unit"). **Date:** 2026-10-12.
**Basis:** `specs/security-design-review.md` — STRIDE table §2.1 (S-1..S-4, T-1..T-5, R-1, I-1..I-5, D-1..D-4, E-1..E-4), write-authority layers §2.3, degradation §2.4, checklist §3, advisories **F1..F8** (§4), accepted residuals §5.
**Requirements:** NFR-FCU-002 (log safety), NFR-FCU-003 (no new egress), NFR-FCU-009 (gates and baseline honesty); FR-FCU-016 (feasibility honesty — the per-ask statement is `specs/FCU-feasibility-honesty-report.md`, referenced here).

This is the one document the `security-test` gate reads for the feature's security evidence. Every row names a **test**, a **gate run**, or an explicitly recorded **gap/residual** — nothing is listed as covered because it was designed to be covered.

**Honesty rule (binding).** A row without a reproducible pointer is incomplete, not assumed. A row with no artifact is marked **OPEN** with the owning task named — never silently omitted. The F7 row is a recorded **no-action with rationale**; the F8 row is an accepted **residual**, recorded so `security-test` does not rediscover it as a finding.

**How this index is validated (stated limit).** Unlike the LCT / SP / MTC bundles, this feature ships **no in-target parser suite** for this file (there is no `FamilyContactsSecurityEvidenceIndexTests`; only the Spotify and LiveTranslate bundles have those). The validator is the `security-test` gate itself, running the per-row verifier commands below. Three mechanical checks are available and were applied while authoring: (1) every named `<Suite>.<test>` is greppable in `ios/ElderlyAssistantTests/`; (2) every named suite appears in the recorded T-163 sweep (§ Freshness run); (3) every verifier command is re-runnable in this worktree. One in-target pin touches this evidence set directly: `FamilyWizardPhotoSaveTests.testF4CommentRecordsTheDeliberateLabelAndTheT165Deferral` (the F4 code-comment record). A wrong test name in a row is caught by the running gate, not by a parser — recorded as residual R-7, not dressed up.

## Environment and build identity

| What | Value | Recorded by |
|---|---|---|
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` | `pwd` |
| Branch | `feat/family-contacts-unify` | `git rev-parse --abbrev-ref HEAD` |
| Base HEAD | `4d4d1e2852717b40e53b294338173cd619439323` (T-163 record) | `git rev-parse HEAD` |
| Merge base | `81de796a` (master tip = merge-base; the diff base for every attribution) | `git merge-base HEAD master` |
| Simulator | iPhone 16 Pro `14AE2228-4EC9-4CBE-A935-A50DF75A35E2` (iOS 18.3.1, 22D8075) | T-163 record |
| Xcode | 26.6 (Build 17F113) | T-163 record |
| Derived data | `build/DerivedDataTests` (warm) | T-163 record |

## Freshness run (the passing status of every named test comes from here)

T-163's scoped sweep ran **32 suites**, one at a time, via the build gate, on the tree at `4d4d1e28`. Every suite this index cites is in that sweep; per-suite logs `/tmp/fcu-sweep-*.log`, `/tmp/fcu-rerun-*.log`, `/tmp/fcu-fix2-*.log`, `/tmp/fcu-call-*.log`; results `/tmp/fcu-sweep-results.txt`, `/tmp/fcu-rerun-results.txt` (reproduction is via the recorded commands; `/tmp` logs are transient). Full record: `specs/T-163-acceptance-notes.md` §1-§2.

| Suite | Result | Suite | Result |
|---|---|---|---|
| SystemContactPhotoWriterTests | 37/0 PASS | CoordinatorIdentityRefreshTests | 9/0 PASS |
| ContactResolverTests | 37/0 PASS | CoordinatorFaceIdentityTests | 8/0 PASS |
| CoordinatorLinkUnlinkTests | 16/0 PASS | FamilyListLinkChipTests | 5/0 PASS |
| FamilyContactStoreTests | 31/0 PASS | UnifiedContactSearchTests | 36/0 PASS |
| FamilyContactIndexTests | 17/0 PASS | L10nCatalogCoverageTests | 26/0 PASS |
| FamilyWizardPhotoSaveTests | 18/0 PASS | MissedCallContactResolverTests | 32/0 PASS |
| FamilyWizardFindStepTests | 17/0 PASS | MissedCallDialBackTests | 22/0 PASS |
| CallViewFacesAndCaptionTests | 10/0 PASS | VoiceContactSearchRouteTests | 30/0 PASS |
| ContactsAccessTests | 11/0 PASS | ContactPhotoStoreTests | 16/0 PASS |
| SystemContactLinkServiceTests | 27/0 PASS | FamilyContactValidationTests | 5/0 PASS |
| SystemContactSearchTests | 10/0 PASS | MethodResolverTests | 17/0 PASS |

Full unit bundle (T-163): 7 062 tests, 7 030 passed, 22 failed — **all 22 attributed to the `81de796a` baseline** (per-suite baseline evidence in `specs/T-163-acceptance-notes.md` §4); **FCU-touched suites failing: 0**. Release gates green: log-safety gate exit 0 (fresh re-run for this index, 2026-10-12, `/tmp/t165-gate.log`: 24 fixtures over 12 rules, all four FCU roots scanned), prompt-mirror gate green at every scope.

Standard verifier command shape used below (runs the privacy guards — log gate + fixtures + prompt mirror — ahead of every scope):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify/ios
./build.sh test:unit <Suite> [<Suite> ...]
```

---

## Part A — F1..F8 advisory closure

| ID | Advisory (security review §4) | Producer task | Status |
|---|---|---|---|
| F1 | `PhotoWriteIntent` assertion documentation-grade | T-154 (+ T-155 gate) | **CLOSED** |
| F2 | Two at-margin band pairs decisive but unpinned | T-153 | **CLOSED** |
| F3 | `unlinkKeepingDisplayedPhotoLocally` must set `photoFilename` | T-158 (+ T-163 test fixes) | **CLOSED** |
| F4 | §2.6 comment contradicts §1.5's `.written` mapping | T-160 (implemented label) + **T-165** (doc alignment) | **CLOSED** |
| F5 | No length bounds on externally-sourced strings | T-145 (cap) + T-151 (perf pin) | **CLOSED** |
| F6 | `makeDialectBiasProfileProvider` outside the §3.5 enumeration | **T-165** (footnote) | **CLOSED** |
| F7 | Accepted honest false-negative (`readBackMismatch`) | T-154 | **NO ACTION — recorded with rationale** |
| F8 | Shared-number fingerprint residual | T-158 (+ T-164 DV pointer) | **ACCEPTED RESIDUAL — recorded** |

### F1 — the intent assertion is now an enforcement layer (source-level)

- Producer: T-154 (`specs/T-154-notes.md` §"F1" rows), consumed by T-155's release-gate registration (`specs/T-155-notes.md` §Gate results).
- Artifact: `SystemContactPhotoWriterTests.testOnlyImageDataIsAssignedOnTheMutableContact` (binding derived from the `mutableCopy() as? CNMutableContact` guard; every assignment on it must be `imageData`; exactly one assignment site — write and clear share the parameterised path; no `as!`/`try!`), `testTheSaveRequestIsUpdateOnly` (one `CNSaveRequest()`, the only call on it is `update(_:)`, no `add`/`delete`/`addMember`/`removeMember`), plus the module-wide confinement scan `testCNSaveRequestAndCNMutableContactLiveOnlyInTheWriterFile` (§6.2 layer 1; both tokens found in the writer itself — a scan that matches nothing proves nothing) and `testCNContactStoreConstructionsStayInTheAllowedFiles` (writer + `AddressBookDirectory.swift` read glue only). Gate layer: T-155 registered the three new seam files in `FEATURE_ROOTS` with per-root positive/negative fixtures (injected-PII plant named file + line; falsification run proves the three plants load-bearing on `feature-console-write` alone).
- Verifier: `./build.sh test:unit SystemContactPhotoWriterTests` · `bash ios/tools/check-release-log-safety.sh` (exit 0 incl. fixtures).
- Output (T-163): 37/0 PASS; gate exit 0, 24 fixtures over 12 rules, the three FCU roots scanned.
- Status: **CLOSED** — the advisory asked for the source-level assertion; it exists and can fail.

### F2 — the two at-margin band pairs are pinned by consequence rows

- Producer: T-153 (`specs/T-153-notes.md`).
- Artifact: `ContactResolverTests.testConsequenceTablePinsTheBandingConstants` — pins accept 0.6 / margin 0.15 and the IEEE-754 gaps: `1.00 − 0.85`, `0.90 − 0.75`, `0.75 − 0.60` are all exactly `0.15000000000000002`, **not** `< margin`, therefore decisive (top wins); a gap under margin (`0.90 − 0.85`, `0.85 − 0.75`) stays ambiguous. The two new pairs are run over REAL contacts: `testConsequenceRowRelationshipBeatsNicknameContainmentAtMargin` (0.90 vs 0.75 → the relationship contact wins, both roster orders) and `testConsequenceRowNicknameContainmentBeatsTokenOverlapAtMargin` (0.75 vs 0.60 → nickname containment wins). The 1.00/0.85 row was kept: `testConsequenceRowNameExactBeatsNicknameExactAtMargin`.
- Verifier: `./build.sh test:unit ContactResolverTests`.
- Output (T-163): 37/0 PASS.
- Status: **CLOSED**.

### F3 — the copied photo is assigned to `photoFilename` in the same record write that clears the link

- Producer: T-158; test-side corrections at T-163 (`specs/T-163-acceptance-notes.md` §2.6-§2.9 — the product was correct in each; the tests were fixed).
- Artifact: `CoordinatorLinkUnlinkTests.testCopyModeUnlinkCopiesTheDisplayedSystemPhotoThenAssignsAndClears` (the copy lands in the app-local store and is ASSIGNED to `photoFilename` in the same record write that cleared the link; post-unlink the face still resolves to the red displayed photo; writer untouched, zero access requests, nothing invalidated), `testCopyModeUnlinkCannotClearBeforeTheCopyCompletes` (behavioural order pin: while the copy is parked, neither assignment nor clear may have happened), plus the source-order pin inside `testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource` (`copyIndex < assignIndex`; "assignment + clear reach the store in ONE write").
- Verifier: `./build.sh test:unit CoordinatorLinkUnlinkTests`.
- Output (T-163): 16/0 PASS.
- Status: **CLOSED**.

### F4 — the implemented label is `.updatedInSystem`, and the design record now says so

- Producer: T-160 (`specs/T-160-wizard-photo-step-notes.md`) implemented the review-recommended arm ("show the label"); **T-165** applied the document alignment.
- Artifact (implemented behaviour): `FamilyWizardPhotoSaveTests.testWrittenMapsToUpdatedInSystemAndTheTableIsTotal` (`.written` → `.updatedInSystem`; `from(_:)` total over every outcome row of §1.5), `testFailurePathsNeverRenderUpdatedInSystem` (no non-written outcome ever renders the success label — no false success), `testStateLabelKeysAreTheFourFrozenKeys` (one string only), `testSaveFlowSequencingIsPinnedAtTheSource` (`.written` keeps the sheet open like every other non-nil state; the nil states are `.skippedNoLink`/no-photo-change), `testFooterOffersCloseWhileAPostSaveStateIsShown`. Implemented in the pure seam `FamilyWizardPhotoPresentation.stateLabelKey` / `saveState` (`SettingsView.swift:3696-3749`).
- Artifact (document alignment, T-165): `specs/design-l2.md` §2.6's dismiss comment corrected to read "`.skippedNoLink` or nil outcome → today's UX (F4, T-165: `.written` → `.updatedInSystem`, shown)" — matching §1.5's mapping and the implemented `FamilyPhotoEditorState.from` (only `.skippedNoLink` yields nil among outcomes; a nil outcome is the contact-left-the-roster case); and `specs/design-l1.md` §10.2 step 3's stale "dismiss (today's UX)" phrasing aligned to the same implemented behaviour (the alignment the shipped F4 code comment at `SettingsView.swift:3737-3739` explicitly deferred to T-165 — discharged here so the recorded deferral is not left open).
- Verifier: `./build.sh test:unit FamilyWizardPhotoSaveTests` · doc check: `grep -n "F4" specs/design-l2.md specs/design-l1.md` (`design-l2.md` §2.6; `design-l1.md` §10.2 step 3).
- Output (T-163): 18/0 PASS. The in-code pin `testF4CommentRecordsTheDeliberateLabelAndTheT165Deferral` (raw-file read, one `"family.photo.state.updatedInSystem"` occurrence) remains green — no production file was touched by T-165 (unit rule: documentation/evidence only).
- Status: **CLOSED**.

### F5 — the length bound and the worst-case perf pin both landed

- Producer: T-145 (the 64-grapheme editor cap — `specs/T-145-notes.md`, "T-145 acceptance scenario 3 (security advisory F5)") + T-151 (worst-case index perf) + T-147/T-160 (editor seam copy).
- Artifact (bound): `FamilyContactStoreTests.testNicknameCappedAtSixtyFourCharactersAtTheEditorSeam` — `FamilyContact.cappedNickname` caps at 64 **Characters** (a Devanagari cluster straddling the boundary is kept whole — no grapheme split), trims, rejects blanks; `normalizedNicknames` stays faithful (no silent truncation inside the projection — the bound lives at the editor/submission seam, documented in design-l2 §3.2). Editor-side twin: `FamilyWizardPhotoSaveTests.testNicknameEntryIsTrimmedRejectsBlankAndCapsAtSixtyFourGraphemes`. Model/decoder still accept more without failing (budgets degrade gracefully) — the review's stated envelope.
- Artifact (perf): `FamilyContactIndexTests.testLongStringWorstCaseEntryStaysWithinTheCeilings` — 256-char worst case, build worst-of-5 **1.590–1.602 ms**, query worst-of-20 **0.007–0.011 ms** (ceiling 20 ms; T-163 §7). T-163's first run had the fixture guard wrong ("सीता" is two clusters — the test, not the product); fixed test-side with a fixture-guard assertion pinning the arithmetic (`specs/T-163-acceptance-notes.md` §2.1).
- Verifier: `./build.sh test:unit FamilyContactStoreTests FamilyWizardPhotoSaveTests FamilyContactIndexTests`.
- Output (T-163): 31/0, 18/0, 17/0 PASS.
- Status: **CLOSED**.

### F6 — the adjacent `allEntries()` consumer is now in the design record with a verified anchor

- Producer: **T-165**.
- Artifact: `specs/design-l2.md` §3.5's new footnote records `AppCoordinator.makeDialectBiasProfileProvider` — definition at `AppCoordinator.swift:2660` (the `allEntries()` call at `:2664`; recognizer call sites `:1337`, `:1377`), line position verified against the merged tree at `4d4d1e28` (review-time anchor was `:2529` at `f6ba251b`). It is not an `AddressBookDirectory.access()` consumer; behaviour unchanged (never gates/prompts/nags; denied or absent book → honest empty list).
- Verifier: `grep -n "makeDialectBiasProfileProvider" ios/ElderlyAssistant/App/AppCoordinator.swift` (expect `:2660` definition + `:1337`/`:1377` call sites at this tree) · `grep -n "makeDialectBiasProfileProvider" specs/design-l2.md` (the §3.5 footnote).
- Related per-site access-gate pins (E-3 evidence, carried under names other than the design's proposed suite — see residual R-8): `CallViewFacesAndCaptionTests.testEveryCallViewReadableGateReadsAllowsReading`, `FamilyWizardFindStepTests.testWizardAccessGatesReadAllowsReadingWithTheLimitedCaptionUnderTheField`, `CoordinatorLinkUnlinkTests.testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource`.
- Output: anchors confirmed at `4d4d1e28`; the three pin suites 10/0, 17/0, 16/0 PASS (T-163).
- Status: **CLOSED**.

### F7 — no action: the read-back false-negative is the safe direction (rationale recorded)

- Producer: T-154 (read-back gate), reviewed at T-163.
- Rationale (security review §2.3 layer 3 and F7): `.failed(.readBackMismatch)` can show "Kept in this app only" while the system record actually received the photo — an **honest false negative**. The unsafe direction (claiming `.written` without byte equality — a false success) cannot occur: `.written` requires read-back equality. The review's disposition is **keep as-is**; this index records it so `security-test` reads it as a **known and accepted property of the mechanism**, not a finding.
- Artifact: `SystemContactPhotoWriterTests.testReadBackVerificationMatrix` (the full outcome matrix incl. the unverifiable-read-back case), `testUnverifiableReadBackIsNeverSuccess`, `testEveryFailureRawValueMapsToAKeptState` (every failure raw value maps to a kept-on-phone state — total by construction), `testFromMapsEveryOutcomeRowOfTheTable`; UI side `FamilyWizardPhotoSaveTests.testFailurePathsNeverRenderUpdatedInSystem`.
- Verifier: `./build.sh test:unit SystemContactPhotoWriterTests FamilyWizardPhotoSaveTests`.
- Output (T-163): 37/0, 18/0 PASS.
- Status: **NO ACTION — recorded with rationale** (no code or test change; the property is pinned by the tests above).

### F8 — accepted residual: the shared-number fingerprint cannot disambiguate two people sharing one number

- **The residual, stated exactly:** the attempt-time fingerprint accepts ANY current number on the fetched record satisfying the shared floor-8 trailing-digit rule (`SystemContactPhotoWriter.fingerprintHolds`, `SystemContactPhotoWriter.swift:313-314`, `MissedCallContactResolver.matches`). Two distinct system cards that share the dialled number would BOTH satisfy the fingerprint. If an identifier is reused/moved to such a sibling card (the compound coincidence), the write could land on a card whose number matches but which is a different person than the owner believed linked.
- **Why accepted:** extremely low likelihood (requires identifier reuse AND a shared number); bounded impact (one `imageData` field of one card the owner believed was the linked person; nothing else on the card is touched — F1's confinement holds regardless); the read-back gate still prevents a false success claim; and the accepted-risk wording is the security review's own (§2.1 S-1 "Acceptable (F8)", §4 F8).
- **Not testable at unit level:** the compound coincidence needs a real `CNContactStore` with a moved identifier — `CNContactStore` is not fakeable, so no unit test can reproduce it. It is recorded here **for the DV session** (T-164): DV-3/DV-4 (photo write / fallback) are the device steps that would expose it; if the DV session probes a shared-number pair it must record what it saw, PASS/FAIL/BLOCKED, never a fabricated pass.
- Artifact: `specs/security-design-review.md` §2.1 S-1 + §4 F8 + §5; this section; `SystemContactPhotoWriterTests.testFingerprintPreconditionUsesTheSharedTrailingDigitRule` and `testFingerprintNeverHoldsForAnEmptyNumberKey` (the mechanism's pins); `CoordinatorLinkUnlinkTests.testSyncSystemPhotoRecordGoneAndIdentityMismatchRefreshTheLinks` (mismatch → refresh, no write).
- Verifier: `./build.sh test:unit SystemContactPhotoWriterTests CoordinatorLinkUnlinkTests` (mechanism pins) · the device half is T-164's record.
- Status: **ACCEPTED RESIDUAL — recorded, not retired.**

### Gaps in this section

None. All eight advisories have a closing artifact, a recorded no-action, or a recorded residual — no F row is OPEN.

---

## Part B — STRIDE evidence index (for the `security-test` gate)

One row per threat of `specs/security-design-review.md` §2.1, with the verifier command and the T-163 result. Rows marked "inspection" name the exact artifact checked; rows marked "residual" point at Part A's residuals.

| Threat | Evidence | Verifier | Status |
|---|---|---|---|
| **S-1** wrong-contact photo write | Fetch → fingerprint → build → execute: `SystemContactPhotoWriter.swift:401-405` (`guard fingerprintHolds … else .identityMismatch` BEFORE any request exists); pins `SystemContactPhotoWriterTests.testFingerprintPreconditionUsesTheSharedTrailingDigitRule`, `testFingerprintNeverHoldsForAnEmptyNumberKey`, `testFakeRecordsNoIntentBeforeTheRequestIsBuilt`, `testTheAttemptSequenceIsFetchFingerprintIntentSaveReadBackWrite`; coordinator: `CoordinatorLinkUnlinkTests.testSyncSystemPhotoRecordGoneAndIdentityMismatchRefreshTheLinks` | `./build.sh test:unit SystemContactPhotoWriterTests CoordinatorLinkUnlinkTests` | 37/0, 16/0 PASS — **residual F8** |
| **S-2** wrong-person merge / stale identifier | `SystemContactLinkServiceTests.testStaleLinkNumberChangedIsExcluded`, `testStaleLinkRecordGoneIsExcludedAndTheFamilyContactSurvives`, `testSnapshotNumberLookupIgnoresUnverifiedLinks`; `CoordinatorIdentityRefreshTests.testDegradedSnapshotPublishesAndNeverRewritesTheStoredClaim` | `./build.sh test:unit SystemContactLinkServiceTests CoordinatorIdentityRefreshTests` | 27/0, 9/0 PASS |
| **S-3** linked row over-claims reachability | `CallViewFacesAndCaptionTests.testBookSideOnlyMatchComposesTheFrozenCaptionWithTheBookName`, `testOnlyTheFamilyRowKeyedInTheMapCarriesTheCaption`, `testEmptyStoredBookNameIsSuppressedNotRendered`, `testCaptionResolvesTheFrozenKeyInBothLanguages` | `./build.sh test:unit CallViewFacesAndCaptionTests` | 10/0 PASS |
| **S-4** voice resolves the wrong person | F2's consequence rows (Part A) incl. every ambiguity row (`testConsequenceRowSharedNicknameIsAmbiguous`, `testConsequenceRowNicknameExactAgainstRelationshipIsAmbiguous`, `testConsequenceRowNicknameExactAgainstNameContainmentIsAmbiguous`, `testConsequenceRowNicknameExactAgainstNicknameContainmentIsAmbiguous`), `testAmbiguityReturnsAllRivals`, `testDecisionsDoNotDependOnRosterOrder`; route level `VoiceContactSearchRouteTests` | `./build.sh test:unit ContactResolverTests VoiceContactSearchRouteTests` | 37/0, 30/0 PASS |
| **T-1** partial / other-field mutation | F1's evidence set in full (single-assignment source assertion + update-only pin + file confinement + gate roots) | `./build.sh test:unit SystemContactPhotoWriterTests` | 37/0 PASS |
| **T-2** corrupt persisted payload | `FamilyContactStoreTests.testEveryHistoricalShapeLoadsWithoutLoss`, `testCorruptLinkPayloadDecodesToNoLinkAndKeepsTheContact`, `testLegacyPayloadWithoutOptionalFieldsDecodesAsNil`, `testLegacySingleNicknameMigratesLosslessly`; index rebuild `FamilyContactIndexTests.testRebuildAfterStoreChangeDropsStaleIDsWithNoTornReads` | `./build.sh test:unit FamilyContactStoreTests FamilyContactIndexTests` | 31/0, 17/0 PASS |
| **T-3** second contact claims the same record | `CoordinatorLinkUnlinkTests.testLinkVerifiesIntoTheSnapshotAndUnlinkClearsItNeverTouchingTheSystemRecord`, `testFamilyContactMatchingPhoneIsLinkAwareAndNeverWrongPerson`; wizard steering `FamilyWizardFindStepTests` (17/0) | `./build.sh test:unit CoordinatorLinkUnlinkTests FamilyWizardFindStepTests` | 16/0, 17/0 PASS |
| **T-4** unlink loses the photo / touches the record | F3's evidence set + `testAsIsUnlinkWithAGoneSystemPhotoCompletesWithoutAPhantomFile`, `testClearModeUnlinkRemovesTheAppLocalFileAndTheLink`, `testUnlinkOfAnUnknownContactReturnsFalseAndTouchesNothing`, `testCopyFailureRefusesToClearAndLeavesNoPhantomFile`, `testUnlinkModeRuleIsPureAndTotal` | `./build.sh test:unit CoordinatorLinkUnlinkTests` | 16/0 PASS |
| **T-5** dedupe hides a person or strands a call | `UnifiedContactSearchTests.testNicknameMatchedLinkedPairStillYieldsOneRow` (linked pair yields ONE row); `MissedCallDialBackTests` 22/0; `MissedCallContactResolverTests` 32/0 (unlinked parity) | `./build.sh test:unit UnifiedContactSearchTests MissedCallDialBackTests MissedCallContactResolverTests` | 36/0, 22/0, 32/0 PASS |
| **R-1** no trace of write/unlink/refresh/refusal | Closed-vocabulary events: `SystemContactPhotoWriterTests.testTheWriterEmitsTheClosedContactsPhotoWriteEvent`, `testOutcomeLogTokensAreTheClosedVocabulary`, `testFailureReasonCodesAreTheRawValuesAndOnlyOnFailed`, `testMetadataIsStateOnlyForSkippedNoAuthorization`; `SystemContactLinkServiceTests` vocabulary pins; allow-listed keys + runtime choke point (NFR row 1 below) | `./build.sh test:unit SystemContactPhotoWriterTests SystemContactLinkServiceTests` | 37/0, 27/0 PASS |
| **I-1** PII reaching logs | Release gate exit 0 (fresh run 2026-10-12, `/tmp/t165-gate.log`) + T-155 per-root fixtures; per-file source pins: `SystemContactLinkServiceTests.testServiceFileHasNoConsoleWrites`, `SystemContactPhotoWriterTests.testTheWriterSourceCarriesNoConsoleWriteOrForceUnwrap`, `ContactPhotoStoreTests.testStoreSourceHasNoConsoleWrites`; runtime sanitiser choke point (P8) exercised by the L10n/observability suites | `bash ios/tools/check-release-log-safety.sh` · `./build.sh test:unit SystemContactLinkServiceTests SystemContactPhotoWriterTests ContactPhotoStoreTests` | gate exit 0; 27/0, 37/0, 16/0 PASS |
| **I-2** photo bytes / source metadata | `ContactPhotoStoreTests` (≤512 px JPEG q0.8, orientation baked, metadata stripped, `.completeFileProtection`); `SystemContactPhotoWriterTests.testImageBytesHashIsAStableSha256Prefix`, `testPhotoWriteIntentCarriesNoBytes` (Mirror: no `Data` member), `testIntentIsPhotoFieldOnly` | `./build.sh test:unit SystemContactPhotoWriterTests ContactPhotoStoreTests` | 37/0, 16/0 PASS |
| **I-3** identifiers in events | `SystemContactPhotoWriterTests.testTheWriterEmitsTheClosedContactsPhotoWriteEvent` (source assertion: no `identifier:` and no `integerValue` may enter the event), `testMetadataIsStateOnlyForSkippedNoAuthorization`; `contact_id_hash` declared-but-unused (P7, security review §2.1 I-3) | `./build.sh test:unit SystemContactPhotoWriterTests SystemContactLinkServiceTests` | 37/0, 27/0 PASS |
| **I-4** dishonest permission copy | `L10nCatalogCoverageTests.testTheContactsDisclosureStatesReadingAndThePhotoWrite` (verbatim against the design-l2 §7 frozen copy: read/search use, the photo write onto the card, the permission gate, "works fully even if you say no"; old string gone; English-only accepted residual) + `testThePlistAddsNoNewUsageDescriptionKeys` (12-key usage-description set unchanged; no write-only contacts descriptor) | `./build.sh test:unit L10nCatalogCoverageTests` | 26/0 PASS |
| **I-5** alt caption reveals a book name | S-3's caption tests incl. `testEmptyStoredBookNameIsSuppressedNotRendered` | `./build.sh test:unit CallViewFacesAndCaptionTests` | 10/0 PASS |
| **D-1** unbounded fetches / caches / loops | `FamilyContactStoreTests.testMaxContactsEnforcedAtTwelve`; index bounded by the 12 × (1+8) envelope (`FamilyContactIndexTests` build/lookup ceiling pins); writer: one fetch per attempt, no retries (`SystemContactPhotoWriterTests.testTheAttemptSequenceIsFetchFingerprintIntentSaveReadBackWrite`) | `./build.sh test:unit FamilyContactStoreTests FamilyContactIndexTests SystemContactPhotoWriterTests` | 31/0, 17/0, 37/0 PASS |
| **D-2** crash loop from corrupt state | T-2's evidence + `SystemContactPhotoWriterTests.testTheWriterSourceCarriesNoConsoleWriteOrForceUnwrap` (no `try!`/`as!`/`fatalError`/`preconditionFailure` in the seam) + `testTheSaveBlockCatchesExecuteFailuresAndTheSuccessIsGatedOnReadBack` | `./build.sh test:unit FamilyContactStoreTests SystemContactPhotoWriterTests` | 31/0, 37/0 PASS |
| **D-3** refresh storms | `SystemContactLinkServiceTests.testTriggersArrivingDuringAnInFlightPassCoalesceIntoOneFollowUpPass` (T-163 fixed the TEST's lost-update collector race — §2.3; product coalescing was correct), `testInvalidateOneIdentifierLeavesOtherRecordsCached` (per-identifier invalidation re-read semantics, §2.4); `CoordinatorIdentityRefreshTests` (9/0) | `./build.sh test:unit SystemContactLinkServiceTests CoordinatorIdentityRefreshTests` | 27/0, 9/0 PASS |
| **D-4** oversized strings | F5's evidence set (64-char editor cap + 256-char worst-case perf pin) | `./build.sh test:unit FamilyContactStoreTests FamilyWizardPhotoSaveTests FamilyContactIndexTests` | 31/0, 18/0, 17/0 PASS |
| **E-1** writing another field / another contact | F1's evidence set (confinement + single-assignment + update-only) | `./build.sh test:unit SystemContactPhotoWriterTests` | 37/0 PASS |
| **E-2** prompting / nagging outside user-initiated flows | `SystemContactPhotoWriterTests.testDeniedAndNotDeterminedSkipWithTheirOwnAccessPayload` (attempt-time skips never prompt), `testThePreAttemptGateAgreesWithAllowsWriting`, `testNoVerifiedLinkSkipsForEveryAccess`; wizard/callview prompts only at user taps (`FamilyWizardFindStepTests`, `CallViewFacesAndCaptionTests`) | `./build.sh test:unit SystemContactPhotoWriterTests FamilyWizardFindStepTests CallViewFacesAndCaptionTests` | 37/0, 17/0, 10/0 PASS |
| **E-3** `.limited` silently collapsed / equality gates taking the else path | `ContactsAccessTests` (mapping + `allowsReading` + the one iOS-18 availability gate) and the per-site source pins `CallViewFacesAndCaptionTests.testEveryCallViewReadableGateReadsAllowsReading`, `FamilyWizardFindStepTests.testWizardAccessGatesReadAllowsReadingWithTheLimitedCaptionUnderTheField`, `CoordinatorLinkUnlinkTests.testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource` (coordinator fifth site: granted-ternary gone, `guard access.allowsReading`, `access: access` in order). **Naming divergence recorded — residual R-8** | `./build.sh test:unit ContactsAccessTests CallViewFacesAndCaptionTests FamilyWizardFindStepTests CoordinatorLinkUnlinkTests` | 11/0, 10/0, 17/0, 16/0 PASS |
| **E-4** read-scope expansion under `.limited` | `ContactsAccessTests.testAllowsReadingIsTrueForAllowedAndLimitedOnly`, `testMappingAndAllowsReadingAgree`; limited-without-grant write attempt: `SystemContactPhotoWriterTests.testFetchFailureClassification` (fetch failure under `.limited` → `.failed(.notInGrantedSelection)`, under `.full` → `.failed(.fetchFailed)`), `testEmptyFetchClassification` (empty fetch under `.limited` → `.notInGrantedSelection`, never a claim that the book is off), `testFullAndLimitedAccessProceedToTheAttempt` | `./build.sh test:unit ContactsAccessTests SystemContactPhotoWriterTests` | 11/0, 37/0 PASS |

Integration-level anchors (the flows the threats live in), all green in T-163's sweep: `CoordinatorLinkUnlinkTests` (link/unlink/post-save photo), `SystemContactLinkServiceTests` (verify/refresh/degrade), `FamilyWizardPhotoSaveTests` + `FamilyWizardFindStepTests` (wizard surfaces), `CallViewFacesAndCaptionTests` (call surface), `UnifiedContactSearchTests` (search unification).

---

## Part C — guards outside the STRIDE list (NFR-FCU-002 / 003 / 009)

| Requirement | Evidence | Verifier | Status |
|---|---|---|---|
| **NFR-FCU-002** — log safety; the gate covers the new paths | `bash ios/tools/check-release-log-safety.sh` **exit 0** (fresh run 2026-10-12: engine verdict + 24 fixtures over 12 rules; the three FCU roots registered and scanned — `check-release-log-safety.py:192-194` verified 2026-10-12; T-163 §6's "4 FCU roots" phrasing is imprecise and recorded here so the count stays exact; the injected-PII fixture names file+line); T-155's registration + fixture transcript (`specs/T-155-notes.md` §Gate results, incl. the registration-drift experiment); runtime allow-list choke point (P8; current tree `AppCoordinator.swift:12792` — the review-time anchor was `:11666`) + the §5.2 closed-vocabulary pins (R-1/I-1 rows above); device console check outstanding — gap G-2 | `bash ios/tools/check-release-log-safety.sh` | gate exit 0; suites green; **device half OPEN (T-164)** |
| **NFR-FCU-003** — no new network egress | Source pin: `SystemContactLinkServiceTests.testServiceFileHasNoNetworkEgress` (forbidden transport/network symbol set over the link-service file) + `testServiceFileHasNoConsoleWrites`. Inspection run for this index (2026-10-12): every feature-changed product Swift file (`git diff --name-only 81de796a..HEAD -- 'ios/ElderlyAssistant/**'`) scanned for `URLSession|URLRequest|NWConnection|NWPathMonitor|dataTask|URLComponents|URL scheme` — zero feature-introduced hits; two files carry pre-existing tokens only (`AddressBookDirectory.swift:247` parses a facebook-profile URL *found in the address book* — no egress; `AppCoordinator.swift`'s hits are all pre-existing, none on added lines). Stated limit (gap G-4): `SystemContactPhotoWriter.swift` and `FamilyContactIndex.swift` have no dedicated network-symbol source pin — their no-egress property rests on this inspection + the file-confinement pins + review | `./build.sh test:unit SystemContactLinkServiceTests` · the inspection loop recorded in this row | 27/0 PASS; inspection clean; **limit recorded** |
| **NFR-FCU-009** — gates and baseline honesty | T-163: 32-suite sweep green (§Freshness); full bundle 7 062 / 7 030 / 22-failed, **all 22 attributed to the `81de796a` baseline with per-suite evidence** (`specs/T-163-acceptance-notes.md` §4), zero FCU suites failing; log gate + prompt-mirror gate green at every scope; L10n pins held (1 415 = 1 389 base + 5 + 21); five test-side first-run corrections documented in-code (`[T-163 first-run correction]`) and in §2; the 120 s per-test guard disclosed (§3) | `specs/T-163-acceptance-notes.md` §1-§7 (commands and logs recorded there) | **PASS — honest baseline recorded** |

---

## Residual risks (recorded, not retired)

- **R-F8 — shared-number fingerprint residual.** Stated in full in Part A/F8 with its accepted-risk rationale and the DV-session pointer (T-164). Not retired by this feature; `security-test` must treat it as recorded, not rediscover it as a finding.
- **R-1 — write-seam real glue is unit-untestable** (`CNContactStore` not fakeable): covered by the source-scan pins (F1) + `security-test` + **DV-3/DV-4** device evidence (T-164). `request.update` writes the fetched snapshot back; minimal fetch keys limit materialised fields; any throw degrades to a labelled fallback.
- **R-2 — new coordinator/UI lines remain outside the release gate's rules 3-6** (documented in design-l2 §5.3): bounded by rules 1-2 (which DO scan those roots), the runtime allow-list choke point, review, and `security-test`.
- **R-3 — audit events are console-only** (pre-existing house infrastructure).
- **R-4 — `.limited` readable semantics** are a deliberate, bounded scope correction (the user's granted subset), pinned per site (E-3 row).
- **R-5 — English-only usage strings** (pre-existing project pattern; pinned by I-4's test).
- **R-6 — F7's honest false-negative** in `.failed(.readBackMismatch)` — no action, rationale in Part A/F7.
- **R-7 — no in-target parser suite validates this index** (unlike LCT/SP/MTC): a wrong test name in a row is caught by the running gate, not a parser. Recorded as a limitation of the evidence itself.
- **R-8 — suite-name divergence.** Design-l2 §6.4 proposed a dedicated `ContactsAccessGateTests` source-scan suite; the shipped per-site pins instead live in `CallViewFacesAndCaptionTests`, `FamilyWizardFindStepTests` and `CoordinatorLinkUnlinkTests` (E-3 row). Equivalent per-site enforcement is asserted — under different homes than proposed. The proposal's name is not created; recorded so the divergence is not read as missing coverage.

## Gaps — not exercised, not dressed up as coverage

1. **G-1 — the DV-1..6 device session has not run** (T-164; completion gate, T-164's record is the authority). No device evidence is claimed anywhere in this index: every gate above is simulator/unit evidence.
2. **G-2 — the device Release-build console check (NFR-FCU-002's device half) is outstanding** (T-164).
3. **G-3 — F8's compound coincidence is not reproducible at unit level** (real `CNContactStore` required); recorded as residual, observable only in the DV session if probed.
4. **G-4 — no dedicated network-symbol source pin for `SystemContactPhotoWriter.swift` / `FamilyContactIndex.swift`** (NFR-FCU-003 row); the property rests on inspection + confinement pins.
5. **G-5 — the release gate cannot follow indirection** (wrapper functions, `metadata:` variables, unknown sink spellings — the engine's own documented limits, LCT precedent). The runtime allow-list remains the primary safeguard; the gate is the backstop.
6. **G-6 — the full bundle carries 22 pre-existing failures** at the `81de796a` baseline (attributed in T-163 §4, not fixed — master-owned).

## Integrity of this index

| Check | How |
|---|---|
| All eight advisories present, none OPEN | Part A table: F1-F6 CLOSED, F7 no-action-with-rationale, F8 accepted residual |
| All 21 STRIDE threats present | Part B table: S-1..S-4, T-1..T-5, R-1, I-1..I-5, D-1..D-4, E-1..E-4 |
| Every named suite is in the recorded freshness run | §Freshness run table (T-163 §1) |
| Every named `<Suite>.<test>` exists | greppable in `ios/ElderlyAssistantTests/` at `4d4d1e28` (authoring check) |
| Every verifier command re-runnable in this worktree | standard shape above; the gate re-run recorded (2026-10-12, exit 0) |
| The feature's device truth is not pre-empted | G-1/G-2: DV-1..6 marked outstanding; T-164 owns them |
