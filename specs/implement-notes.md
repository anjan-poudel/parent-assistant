# implement-notes — Medication Schedules & Reminders

description: Implementation notes for the medication-schedules-reminders implement task (unit_based, 22 units in 8 waves): per-wave unit outcomes, consolidated scoped test passes, deviations, and the final full-suite comparison.

## Summary

- Task: `implement` (contract `implementation`), feature `medication-schedules-reminders`.
- Plan: `specs/plan-tasks/plan.md` — 22 units, 8 waves (W0:4, W1:4, W2:5, W3:3, W4:2, W5:2, W6:1, W7:1), file-disjoint within each wave.
- Cadence: per-unit code + typecheck; ONE consolidated scoped test pass per wave (`ios/build.sh test:unit <Classes...>`); a single full-suite run at W7 (compared against the documented pre-existing baseline).
- Resolution pins carried: R-1(a) at T-019/T-021, R-2 at T-006, R-3 at T-019, R-4 at T-014.

## Wave ledger

| Wave | Units | Consolidated scoped pass | Result |
|------|-------|--------------------------|--------|
| W0 | T-001, T-006, T-007, T-012 | 6 classes — 92 tests (2026-10-15) | PASS — 92/92, 0 failures |
| W1 | T-002, T-003, T-004, T-005 | pending | pending |
| W2 | T-008, T-009, T-011, T-013, T-015 | pending | pending |
| W3 | T-010, T-014, T-017 | pending | pending |
| W4 | T-016, T-018 | pending | pending |
| W5 | T-019, T-020 | pending | pending |
| W6 | T-021 | pending | pending |
| W7 | T-022 | pending | pending |

## Deviations

- None at unit level. One coordinator correction before W0 closure: the T-007
  `MedicationEvidenceStore.maxPhotoBytes` cap was written initially as the
  decimal `200_000`; it is corrected to the pinned PhotoVerifier precedent
  constant `200 * 1024` (= 204,800), with the doc comments and the
  source-scan test anchor realigned. The W0 pass below is green on the
  corrected value.

## Verification

- **W0 consolidated scoped pass (2026-10-15):** `ios/build.sh test:unit
  MedicationSlotClockTests ConfirmationChallengeTests MedicationSchedulerTests
  MedicationEvidenceStoreTests L10nCatalogCoverageTests
  CalendarShareConsentCopyTests` — 92 tests, 0 failures, `TEST SUCCEEDED`
  (xcresult 92/92, result Passed). Guard scripts (release-log-safety,
  prompt-mirror) green ahead of the run. Suite coverage: slot clock 10,
  challenge 11, scheduler 15, evidence store 12, catalog coverage 40,
  calendar-share consent copy 4. A scoped run does not advance the impact
  baseline.
- **Unit outcomes (W0):**
  - T-001 — `MedicationSlotClock.swift` (new) + its suite (10 tests, parse-clean):
    per-slot default/family mapping resolution, validate-before-persist, refusal
    maps to a typed storage error, unreadable bytes load as the household
    default (L1 4.2).
  - T-006 — one named home for the challenge window
    (`ConfirmationChallenge.defaultChallengeTimeoutSeconds` = 30 s, the shipped
    FR-D02 value); `AckClarificationConfig` (new) derives its window from the
    same home; both scheduler construction sites pass the value explicitly; no
    literal timeout at any call site (grep evidence recorded by the unit).
  - T-007 — `MedicationEvidenceStore.swift` (new) + its suite (12 tests):
    entry/log-named file layout under `.completeFileProtection`, atomic writes,
    never-oversize compression ladder, typed failures, fail-soft entry cascade.
    Cap pinned to the PhotoVerifier precedent `200 * 1024` (see Deviations).
  - T-012 — 42 new keys, ne + en (catalog 1,439 -> 1,481 on the branch);
    M-1 consent amendment applied to `calendarShare.consent.whoCanSee` with
    the shipped Nepali duplication repaired; `calendarShare.consent.body`
    verified byte-unchanged in both locales; the four coverage count pins
    rebased to the new total (1,481).
- **Carry-forward baseline note (for the W7 full-suite comparison):** the
  Spotify localization suite's absolute key-count pin is red at the branch
  base (pin 1,381 vs catalog 1,439 pre-W0) and is untouched by this feature —
  it belongs to the documented pre-existing baseline, not to this feature's
  regressions.
- **Hygiene note:** two pre-existing camelCase test method names in touched
  suites (challenge + scheduler) are exactly 40 alphanumeric characters and
  trip the release scanner's hash-like-token pattern. They predate this feature
  and stay untouched (renaming shipped tests is out of scope); they are kept
  out of artifact content for the same reason.
