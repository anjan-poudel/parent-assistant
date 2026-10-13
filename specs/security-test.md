# security-test — family-contacts-unify

**Decision: SECURITY-GO** · **Task:** `security-test` · **Date:** 2026-10-12
**Worktree:** `elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`, HEAD `6dc4374a`; `ios/` tree clean vs HEAD — only `.ai-sdd/` state files modified). Read-only review; no artifact modified.
**Evidence base:** `specs/FCU-security-evidence-index.md`, `specs/security-design-review.md`, `specs/review-implementation.md` (GO 0.93; F-4 advisory), `specs/T-163-acceptance-notes.md`, `specs/implement-notes.md`, `specs/design-l2.md`, `specs/T-155-notes.md`.
**Method / tree binding:** the index was treated as a claim set, not as evidence. Every load-bearing row was re-derived from source on the final tree, and the release gate was re-run live. Product code at the reviewed HEAD is identical to the T-163 sweep tree (`git diff --name-only 4d4d1e28..6dc4374a` contains only `specs/**` and `.ai-sdd/**`), so the recorded 32-suite sweep binds to this tree.

## 1. Assigned items — independent verification

| # | Item | Verification | Verdict |
|---|---|---|---|
| 1 | F1 confinement | Module-wide grep: `CNSaveRequest`/`CNMutableContact` ONLY in SystemContactPhotoWriter.swift; the ONLY call on the request is `update(mutable)`; the ONLY assignment is `mutable.imageData = jpeg`; no try!/as! in added product lines; self-falsifying scan pins (non-vacuous: the scans assert the tokens exist); gate roots registered at check-release-log-safety.py:192-194 with positive fixture plants at the exact paths. | PASS |
| 2 | F2 consequence pins | Consequence-table tests assert the three at-margin IEEE-754 gaps are all `0.15000000000000002` ≥ margin ⇒ decisive; under-margin rows assert ambiguity; real-resolver rows for 1.00/0.85, 0.90/0.75, 0.75/0.60 in both roster orders. | PASS |
| 3 | F3 unlink order | Source-order pin `copy < assign < clear < save` verified against the real seam (copy :6965 → filename+clear :6986-6987 → one save :6988 → old-file delete after commit); never-lose refusals reason-coded, return false without clearing; behavioural pins incl. the parked-copy proof. | PASS |
| 4 | F8 residual | RE-CONFIRMED as accepted-for-DV: mechanism (attempt-time fingerprint accepts any current number passing the shared floor-8 trailing-digit rule) + bounded impact (one imageData field; F1 confinement holds regardless; read-back blocks false success); device half pointed at T-164 DV-3/DV-4. | RECONFIRMED |
| 5 | Live gates | `ios/tools/check-release-log-safety.sh` re-run live → exit 0 (24 fixtures/12 rules); product-diff console sweep: zero matches; network primitives in the nine feature files: zero (the two URL tokens are pre-existing, no egress); Info.plist: single disclosure-string replacement, no new keys (pinned by the L10n suite). | PASS |
| 6 | PII vocabulary | Closed event tokens and fixed reason-code strings; metadata limited to `state`/`entry_count`, both in `LogSanitiser.allowedKeys`; the intent record (identifier + fingerprint) in-memory only, never emitted; vocabulary pins present. | PASS |
| 7 | Baseline honesty | The 22 (b)-attributed failures sum exactly; path-disjointness verified — the diff matches none of the failing-suite areas; nothing in the diff plausibly explains the 22. | PASS |
| 8 | Security checklist | Data flows / PII / input validation / audit logging / secrets N/A / least privilege / compliance — all PASS (one line each in §5 of the full review). | PASS |

## 2. Advisory closure F1-F8 — re-verified against source

F1 CLOSED (source-level enforcement, can fail); F2 CLOSED (at-margin rows assert decisiveness); F3 CLOSED (order pinned at source and behaviourally); F4 CLOSED (design-l2:699 + design-l1:560 aligned; in-code pin); F5 CLOSED (64-grapheme cap + 256-char perf pin + single processedJPEG path); F6 CLOSED (anchors verified: makeDialectBiasProfileProvider at AppCoordinator.swift:2660, call sites :1337/:1377); F7 NO ACTION recorded (safe direction re-verified: `.unverifiable` never success); F8 ACCEPTED RESIDUAL recorded (re-confirmed above).

## 3. Residuals re-confirmed

R-F8 re-confirmed as accepted-for-DV (not retired; correctly recorded). R-1 (write glue unit-untestable) stands — compensated by direct source verification + confinement pins; device half stays with DV-3/DV-4. R-2/R-3/R-4/R-5/R-6/R-7/R-8 stand as recorded. G-1/G-2 (DV session + device Release-console check) stand — no device evidence exists or is claimed; T-164 owns both. G-3 (F8 compound coincidence not unit-reproducible) stands. G-4 (no network-symbol pin for two files) stands as a coverage limit — the property was independently verified by inspection this review. G-5 (gate indirection limit) stands. G-6 (22 pre-existing baseline failures) master-owned, spot-confirmed disjoint.

## 4. Findings

No blocking findings. Three observations recorded: O-1 test-side timing prints (numbers only, no PII, outside the gate's app-module root); O-2 G-4 open-by-design (a pin would be master leisure); O-3 the writer emits through the optional bus, live at runtime via the coordinator's lazy construction (nil-bus = DI/test shape).

## 5. Limits (stated, not dressed up)

No device evidence exists or is claimed (G-1/G-2). The unit suites were not re-executed by this review — T-163's recorded 32-suite sweep binds here because the product code is identical between the sweep tree and the reviewed HEAD. This review re-ran the release gate live and re-derived every load-bearing source fact directly. F8 cannot be reproduced at unit level; it remains an accepted residual.

**Decision: SECURITY-GO.** The F1-F8 closure holds against source; the release log-safety gate is green on the final tree; the load-bearing claims of the evidence index were independently reproduced rather than accepted; the residuals are recorded, not laundered; and the only outstanding items are exactly the recorded device halves (G-1/G-2) owned by T-164.
