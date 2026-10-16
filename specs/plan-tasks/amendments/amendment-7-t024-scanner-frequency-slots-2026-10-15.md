# Amendment 7 — T-024: scanner frequency→slot grouping (owner-directed defect fix) (2026-10-15)

Status: **applied**. Source: owner-reported defect relayed by the coordinator
mid-run on 2026-10-15 (during the W6.5 close), owner-directed unit inserted
into the implement run.

## The defect (as reported)

Scanning a label reading "one tablet twice a day" captures no schedule.

## The directive (as received)

- New unit **T-024**: a frequency phrase on a scanned label must produce slot
  rows. Scanning "one tablet twice a day" must produce **TWO slot rows —
  Afternoon after food + Evening after food**.
- Files owned: `MedicationLabelOCR.swift`, `ScannedSchedule.swift`,
  `MedicationEditorDraft.swift` (+ their test suites; new OCR test cases).
  **NOT `SettingsView`** — the view layer is untouched, and the capture seam
  (`MedicationLabelScanner.swift`) is not owned.
- Slot it **after T-023 (W6.5), before the W7 full suite**; its scoped
  (`-only-testing`) pass runs at its wave close (the owner's code-only strip
  does not extend to it).
- Delivery: a parallel subagent implements + tests in an **isolated temp
  worktree** (scratch branch, based on master — never touching this feature
  worktree) and hands off `/tmp/msr-scanner-frequency.patch` with green scoped
  tests. The wave coordinator applies the patch to the feature worktree at
  wave-close time and runs the scoped pass.
- **Quiescence rule:** no other unit in flight may touch the three owned files
  until T-024 lands.

## Placement and cadence

- **Wave W6.6** — after W6.5 (T-023) closes and closed BEFORE the W7 full
  suite. File-chain reason: `ScannedSchedule.swift` follows T-005 (W1) and
  `MedicationEditorDraft.swift` follows T-009 (W2); `MedicationLabelOCR.swift`
  is new to the chains. None of the three is shared with T-023, so the W6.5 →
  W6.6 order is by directive, not by conflict.
- The owner's strip directive (code-only W5/W6) does NOT extend to T-024: its
  scoped pass runs at wave close, per amendment-4's wave-close cadence. The W7
  full suite then covers T-024 alongside everything else.

## Patch-base note

Verified 2026-10-15 (at W6.5 close): the three owned production files are
identical between master and the feature branch (the W0–W4 prefix is already
on master via the #228 merge commit 181a6866, and the feature branch has not
modified these three files since), so the handoff patch applies cleanly to
both bases.

## Integration

- T-024 rides the same remaining-delta PR as W5–W7 + T-023 (PR #2) against
  master. The feature branch is not rebased and master is not pulled into the
  worktree mid-run.
- No retroactive change: W5/W6 recorded cadence stands as executed (code +
  typecheck only); no wave reopens.

## Artifacts added

- `specs/plan-tasks/tasks/T-024.md` (the unit: acceptance criteria, owned
  files, the delivered-patch reconciliation note, DoD).
- `plan.md`: Contents entry, the W6.6 wave-table row (with its closing scoped
  pass filter), and the hotspot-ordering updates (`ScannedSchedule.swift`,
  `MedicationEditorDraft.swift`, `MedicationLabelOCR.swift` chains).
