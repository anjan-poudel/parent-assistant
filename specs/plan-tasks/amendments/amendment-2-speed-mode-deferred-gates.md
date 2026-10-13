# Plan amendment 2 — speed mode: per-unit reviews and tests deferred to the end (2026-10-12)

Owner directive (verbatim intent): "move all reviews and tests to the end instead
of per unit to speed things up for now."

**Suspended per unit:** the paired-review overlay (reviewer challenger per unit),
the confidence ≥0.85 assessment per unit, and the per-unit scoped test gate.

**Kept per unit:** whole-module typecheck (the tree stays compile-green — this is
the cheap tripwire that keeps broken units from cascading) and the commit-per-unit
discipline.

**Deferred, not dropped — the end-of-phase gates still enforce everything:**
- `review-implementation` (paired review of the whole diff, GO exit),
- `security-test` (SECURITY-GO exit; includes the F1-F8 expectations),
- T-163 acceptance: scoped suite sweep (all named suites) + the one full-suite run
  (house rule) + release log-safety gate,
- T-164 DV-1..6 on Anzaan, T-165 security evidence + honesty report.

The end-of-phase reviews cover the full diff at once — any unit-level defect found
there reworks its unit. This amendment reverses the per-unit overlay application
recorded in the workflow yaml for the duration of this feature's implement phase
(owner-authorised speed mode).
