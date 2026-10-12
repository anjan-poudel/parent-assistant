# FCU feasibility honesty report — FR-FCU-016 (T-165)

**Requirement:** FR-FCU-016 (feasibility honesty — the three asks reported explicitly, no silent drop).
**Feature:** `family-contacts-unify` · **Worktree / branch:** `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` @ `feat/family-contacts-unify`; authoring base HEAD `4d4d1e28`. **Date:** 2026-10-12.
**Consumers:** the T2 `final-sign-off` gate (per FR-FCU-016 the statement rides the design record and the sign-off record); the `security-test` gate reads its residual pointers via `specs/FCU-security-evidence-index.md`.
**Verdict source of record:** `specs/design-l1.md` §2 ("Feasibility statement (FR-FCU-016)", the design-stage statement). This report is the evidence-backed confirmation of that statement after execution, per FR-FCU-016's first scenario.

**Status legend (honesty rule — a status may never be upgraded without an evidence link):**
- **DEMONSTRATED** — executed evidence (green test run / gate run) closes the claim at the layer stated.
- **PARTIALLY DEMONSTRATED** — some layers demonstrated, a named layer outstanding.
- **NOT YET DEMONSTRATED** — no executed evidence yet; named owner and dependency.
- **OUTSTANDING (DEVICE)** — device-only fact; T-164 owns it; never claimed from the simulator.

| Ask | Verdict (design-l1 §2) | Status after execution |
|---|---|---|
| LINK | FEASIBLE as specified | **PARTIALLY DEMONSTRATED** — implementation layers DEMONSTRATED; device verdicts OUTSTANDING (T-164) |
| PHOTO unification | FEASIBLE with a stated bound | **PARTIALLY DEMONSTRATED** — implementation layers DEMONSTRATED; the system-write device path OUTSTANDING (T-164) |
| NICKNAMES | FEASIBLE as specified | **PARTIALLY DEMONSTRATED** — implementation layers DEMONSTRATED; device verdicts OUTSTANDING (T-164) |

No ask is infeasible; no ask is silently dropped; no device-level claim is made anywhere in this report.

---

## 1. LINK — delivered as specified

**What is delivered (per design-l1 §2 / design-l2 §1.1, §1.3, §2.2, §2.3, §7, §1.9):** a `SystemContactLink` stored on `FamilyContact`; a verified-link snapshot (record exists AND a current number satisfies the floor-8 trailing-digit fingerprint); link-aware dedupe — a linked pair surfaces ONCE for matched AND unmatched queries; every duplicate-render surface audited; unlink without touching the system record (copy-before-clear, `.unlinkKeepingDisplayedPhotoLocally` assigns the copied file to `photoFilename` in the same record write that clears the link — security F3); wizard find/link step with steering.

**Evidence pointers (all green at `4d4d1e28`, T-163 sweep):**
- `SystemContactLinkServiceTests` 27/0 — verification, staleness degradation (`testStaleLinkNumberChangedIsExcluded`, `testStaleLinkRecordGoneIsExcludedAndTheFamilyContactSurvives`), snapshot lookup (`testSnapshotNumberLookupIgnoresUnverifiedLinks`), single-flight/coalescing, no console/no egress source pins.
- `CoordinatorLinkUnlinkTests` 16/0 — link/unlink end-to-end (F3 rows), link-aware missed-call names (`testFamilyContactMatchingPhoneIsLinkAwareAndNeverWrongPerson`).
- `UnifiedContactSearchTests` 36/0 — `testNicknameMatchedLinkedPairStillYieldsOneRow` (the one-row claim).
- `FamilyWizardFindStepTests` 17/0, `FamilyListLinkChipTests` 5/0.
- `specs/FCU-security-evidence-index.md` STRIDE rows S-2, T-3, T-4, T-5.

**Bounded behaviours (stated, not dropped):**
- Bounded by `CNContact.identifier` stability + the fingerprint: a stale identifier degrades to unlinked — never a wrong merge (design-l1 §6.2).
- **Accepted residual (F8):** two distinct cards sharing the dialled number both satisfy the fingerprint; if an identifier is reused onto such a card, the write could land on a card whose number matches but which is a different person than the owner believed linked. Low likelihood (compound coincidence), bounded impact (one photo field of the believed-linked card), accepted by the security review, recorded for the DV session — `specs/FCU-security-evidence-index.md` F8/R-F8.

**Device verdicts: OUTSTANDING (T-164)** — DV-1 (link → the person appears once, matched and unmatched queries, and in the call list), DV-2 (voice by nickname incl. Devanagari; ambiguous never silently dials), DV-5 (search by name and each recorded nickname finds the single linked row).

## 2. PHOTO unification — delivered as specified, with the stated bound

**What is delivered (per design-l1 §2 / design-l2 §1.4, §1.5, §2.4, §2.6):** system photo displayed when present and readable (`.faceImageWithSource`, source caption); the app writes ONLY the edited, verified-linked contact's photo, via a confined `CNSaveRequest` (update-only, single `imageData` assignment, file-confined construction, attempt-time fingerprint re-check BEFORE any request is built, read-back byte verification gating every success claim); honest full/limited/denied states; app-local `ContactPhotoStore` fallback (owner-pre-authorized) with no loss, no false success, no crash; the post-save outcome labels map totally from every write outcome.

**Evidence pointers (all green at `4d4d1e28`):**
- `SystemContactPhotoWriterTests` 37/0 — access mapping, fetch/fingerprint/no-request ordering, intent field-set, update-only request, read-back matrix, closed event vocabulary, confinement scans (F1).
- `FamilyWizardPhotoSaveTests` 18/0 — `.written` → `.updatedInSystem` shown (F4; one frozen string), never a false success, `systemPhotoRemains` only for a verified clear leaving a photo, footer Close-while-shown.
- `CoordinatorLinkUnlinkTests` 16/0 — post-save system-photo family: written→invalidate+epoch, recordGone/identityMismatch→refresh, nil-payload→no attempt, denied→skip, limited→attempt.
- `ContactPhotoStoreTests` 16/0 — the fallback store's byte discipline (≤512 px JPEG, metadata stripped, file protection).
- `specs/FCU-security-evidence-index.md` F1, F4, F7 rows; STRIDE I-2, I-4, E-2, E-4.

**Bounded behaviours (stated, not dropped) — the design-l1 §2 "stated bound":**
1. **Access denied / not determined:** no attempt, skip-and-label (`keptOnPhone`, + the denied explanation for `.denied`); never a prompt, never a nag (E-2). The photo stays app-local.
2. **Limited access:** attempt-and-detect per record; a record outside the granted subset yields `.failed(.notInGrantedSelection)` → `keptOnPhone` (the honest granted-subset fact — never a claim the book is off). This is the pre-authorized fallback, not a gap (design-l1 §2 PHOTO row; design-l2 §3.5).
3. **Read-only record / save rejected:** `.failed(.saveRejected)` → `keptOnPhone`; nothing false is claimed.
4. **Imperfect read-back:** `.failed(.readBackMismatch)` can show "Kept in this app only" even though the system record received the photo — an honest FALSE NEGATIVE accepted by the security review (F7). The unsafe direction (false success) is impossible: `.written` requires byte equality.
5. **Unit-untestable real glue:** `CNContactStore` is not fakeable, so the actual `CNSaveRequest.execute` + read-back against the system store is covered by the source-scan pins (F1) plus `security-test` and the DV-3/DV-4 device gates — stated, never substituted by mock-only evidence.
6. **Write-authority scope:** the app currently has zero other `CNSaveRequest`/`CNMutableContact` usage; if a future unit adds one outside the writer file, the confinement scan fails loudly (F1 layer 1).

**Device verdicts: OUTSTANDING (T-164)** — DV-3 (setting a photo in the app updates the system contact when permission allows; the displayed photo reflects the system contact) is the device proof that the write path works end-to-end; DV-4 (fallback under denied/limited or a read-only contact — no loss, no crash, honestly surfaced) is the device proof of the bounded behaviours above.

## 3. NICKNAMES — delivered as specified

**What is delivered (per design-l1 §2 / design-l2 §1.2, §2.5, §3.2, §6.1):** `nicknames: [String]` on `FamilyContact` with lossless legacy migration from the pre-change single nickname; indexed exact matching + character-safe substring matching; name OR any recorded variant matches in BOTH in-app search and voice resolution; ambiguity never silently dials the wrong person (deterministic consequence table — see F2); a managed list editor (8 entries max at the editor, duplicates preserved, ≥44 pt a11y remove control); the 64-grapheme entry cap at the editor/submission seam (security F5).

**Evidence pointers (all green at `4d4d1e28`):**
- `FamilyContactStoreTests` 31/0 — round-trip, legacy migration (`testLegacySingleNicknameMigratesLosslessly`, `testLegacyPayloadWithoutOptionalFieldsDecodesAsNil`), the F5 cap (`testNicknameCappedAtSixtyFourCharactersAtTheEditorSeam` — cluster-safe, no silent truncation inside the projection).
- `FamilyContactIndexTests` 17/0 — exact-key lookups, Devanagari positive AND negative pins (`testDevanagariExactMatchIsThePositivePin`, `testDevanagariPartialWordSubstringDoesNotMatchTheNegativePin`), 256-char worst-case perf (F5), rebuild semantics.
- `UnifiedContactSearchTests` 36/0 — the nickname tier (`testNicknameExactMatchLandsInTheNicknameTier`, `testDevanagariNicknamePinsPositiveAndNegative`, `testNicknameSubstringMatchUsesTheSameCharacterSafeSemantics`, `testNicknameQueriesDoNotCrossScripts`, `testNicknameTierRanksBelowRelationshipAndAboveContainment`).
- `ContactResolverTests` 37/0 — voice bands + the consequence table (F2): ambiguity rows return the rivals, never a silent pick; decisions independent of roster order.
- `VoiceContactSearchRouteTests` 30/0; `FamilyWizardPhotoSaveTests.testNicknameEntryIsTrimmedRejectsBlankAndCapsAtSixtyFourGraphemes` (editor-side cap).
- `specs/FCU-security-evidence-index.md` F2, F5 rows; STRIDE S-4, D-4.

**Bounded behaviours (stated, not dropped):**
- **Store-as-entered, no transliteration (OD-2):** a variant matches only when recorded — the normalization canonicalizes spelling (e.g. canonically equivalent forms) but never transliterates Devanagari↔Latin. This is the pre-authorized fallback, not a gap (design-l1 §2 NICKNAMES row).
- **Devanagari substring baseline is deliberate:** a partial word does not match the full name (the pinned regression, per the memory precedent "SWIFT-DEVANAGARI-SUBSTRING… pin as regression"); no "grapheme fix" is applied.
- **Bounds:** the 64-grapheme cap applies to NEW editor entries; the model/decoder accept more without failing (budgets degrade gracefully; the perf ceiling is pinned at the 256-char worst case).

**Device verdicts: OUTSTANDING (T-164)** — DV-2 (voice "call `<nickname>`", Devanagari variation included, reaches the right person; ambiguity disambiguates) and DV-5 (search by each recorded nickname/variation finds the single linked row).

---

## 4. The honesty statement (for the final-sign-off record)

> All three asks — LINK, PHOTO unification, NICKNAMES — are feasible on the target iOS and were
> delivered as specified; the FR-FCU-016 "ask infeasible → name it for the owner" branch does not
> fire for any of them. The three pre-authorized fallbacks (LINK dedupe; the PHOTO app-local photo;
> NICKNAMES store-as-entered) are delivered as the bounded behaviours below where their context
> applies — each is the design's settled input, not a replacement for a deliverable. Bounds are
> stated rather than buried: the PHOTO system-write cannot act under denied/limited-without-grant
> access (the app-local photo stands, honestly labelled), the PHOTO read-back can under-claim in the
> safe direction only (F7, accepted), and NICKNAMES match store-as-entered without transliteration
> (OD-2, by design). One accepted security residual is recorded: the shared-number fingerprint
> cannot disambiguate two people sharing one number (F8). **Device validation (DV-1..6, T-164) is
> OUTSTANDING — this report makes no device-level claim, and the feature is not complete until that
> record lands.**

## 5. How this report is checked

- Every status above is tied to a named evidence artifact executed at `4d4d1e28` (T-163's recorded sweep, `specs/T-163-acceptance-notes.md` §1-§8) or to a recorded outstanding item with its owning task named (T-164). No status was upgraded without an evidence link.
- The per-ask residual/bound pointers are the same rows the `security-test` gate reads in `specs/FCU-security-evidence-index.md` (F7, F8, R-1, R-4, R-5).
- FR-FCU-016's failure scenarios (an infeasible ask named with its fallback; a partially infeasible sub-capability bounded) are discharged by section 2's bounded behaviours — no scenario in FR-FCU-016 required the "ask infeasible" branch, and that fact is stated here rather than implied.
