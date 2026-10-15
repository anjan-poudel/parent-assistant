# Amendment 6 — T-023: medication manage-list screen (owner-directed defect fix) (2026-10-15)

Status: **applied**. Source: owner-reported defect on the W0–W4 device build,
relayed by the coordinator mid-run on 2026-10-15 (owner-directed unit, inserted
into the implement run).

## The defect (as reported)

"The Settings medication UI always shows the add-new-medication form and never
shows existing schedules."

## The directive (as received)

- New unit **T-023** (M-sized, owner-directed): a medication manage-list screen —
  Settings → Medications first shows the **list** of existing schedules (each row:
  name, composed dose line, slot + meal context, purpose caption), with an
  explicit add control.
- Tapping a row opens the existing editor **pre-filled** (the T-018
  edit-existing conversion flow already exists — reuse it, do not rebuild); the
  add form must **NOT auto-open**.
- Empty state uses the **existing** empty string.
- Elderly-fit binding (44pt+ targets, 18pt+ body); voice-first unaffected.
- ne/en strings through the existing `Localizable.xcstrings` discipline; the L10n
  catalog-coverage pin is updated **by re-measurement**, never guessed.
- Implement as a NEW view file (`MedicationManageListView`) with minimal
  `SettingsView` wiring so the unit is file-disjoint-safe.

## Placement and cadence

- **Wave W6.5** — dispatched after W6 (T-021) lands and closed BEFORE the W7
  full suite. File-chain reason: `SettingsView.swift` is shared with T-021 (W6)
  and same-file units never share a wave (plan.md hotspot rule); `SettingsTabs.swift`
  is new to this chain and T-023-only.
- **The owner's strip directive (code-only W5/W6) does NOT extend to T-023:**
  its scoped (`-only-testing`) pass runs at its wave close, per amendment-4's
  wave-close cadence. The W7 full suite then covers T-023 alongside everything
  else.
- Placement rule unchanged: earliest wave its dependencies allow; dependencies
  are T-018 (W4, landed — the edit-existing conversion flow) and T-020 (W5,
  landed — the Medicine-times card sharing the same leaf body).

## Integration

- T-023 rides the same PR #2 (W5–W7 + T-023) against master. The W0–W4 prefix PR
  (#228, branch `msr-pr1-w0-w4` at 3a66d7cb) is unchanged and does not move.
- No retroactive change: W5/W6 recorded cadence stands as executed (code +
  typecheck only); no wave reopens.

## Artifacts added

- `specs/plan-tasks/tasks/T-023.md` (the unit: acceptance criteria, named tests,
  owned files, DoD).
- `plan.md`: Contents entry, the W6.5 wave-table row (with its closing scoped
  pass filter), and the hotspot-ordering update (`SettingsView.swift` chain
  gains T-023; `SettingsTabs.swift`, `MedicationManageListView.swift` and the
  conditional `Localizable.xcstrings` follow-up entry).

## Addendum — second owner report and expanded scope (2026-10-15, same day)

The owner's device reports are read together: (1) "settings UI always shows the
add form and doesn't show existing schedules"; (2) "I entered a medication
schedule and it just disappeared". Coordinator code audit confirmed two
mechanisms; T-023's scope expands accordingly:

- **Display:** the manage leaf renders the entries list above an always-inline
  `addForm` (one VStack), and there is no dedicated observable revision for the
  computed `AppCoordinator.medicationEntries` — a fresh save can go unseen
  without a relaunch. T-023 must guarantee immediate post-save visibility
  (explicit redraw signal; if the redraw does not pick the entry up, that is a
  bug to fix, not to accept).
- **Real loss:** `MedicationScheduler.loadSchedule` discards its
  `storage.write(key: "medication.entries")` result (`_ =`, :367 in the post-W6
  tree; all four coordinator save paths funnel through it), so a failed write is
  silent and the entry is gone after relaunch. T-023 must make the persist tail
  surface write failures loudly per the no-silent-stubs rule: the write result
  is checked, the shipped `entry_persistence_failed` event is emitted, the
  failure is caller-visible, and no schedule is armed behind an unpersisted
  write (FR-MSR-022 / D2 persistence-before-arm).
- **Acceptance added:** save → row visible in list (no relaunch) → process kill
  → relaunch → row still visible AND reminder re-armed (persistence round trip
  through `medication.entries`); plus a failed-persist test proving the loud,
  unarmed failure path.
- **Ownership extension (wave-coordinator, disclosed):** `MedicationScheduler.swift`
  (the `loadSchedule` persist tail only) and/or the scheduler/save-plumbing test
  suites only where a shipped pin must be updated. W6.5 is a single-unit wave;
  file-disjoint. The wave-close scoped pass now also includes
  `MedicationSchedulerTests` + `MedicationSavePlumbingTests`.
- **Deliverable:** the root-cause verdict (display-only vs real loss) with
  evidence is recorded in the unit notes at W6.5 close; on-device confirmation
  rides DV-1..DV-7 at final-sign-off.
