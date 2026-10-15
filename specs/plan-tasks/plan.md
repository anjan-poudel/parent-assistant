# Task Breakdown — Medication Schedules & Reminders

Feature `medication-schedules-reminders` · worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-medication-schedules-reminders` · branch `feat/medication-schedules-reminders` · HEAD `f31ffa79`.
Inputs: `specs/design-l2.md` (frozen components C1–C13, interfaces IF-1–IF-24, decisions D1–D11), `specs/review-l2.md` (GO; required resolutions R-1…R-4), `specs/review-l1.md` (resolutions M-1, m-1…m-5), `specs/define-requirements.md` (locked 22 FR-MSR, 10 NFR-MSR), `specs/medication-schedules-reminders/constitution.md`.

## Summary

- **Units:** 24 leaf units, `T-001` … `T-024` (T-023 and T-024 inserted mid-run by the owner-directed amendments 6 and 7), one unit per file, flat under `tasks/` (this workflow's plan-tasks contract; no task-group folders). Each unit carries: an explicit **Owned files** list (every source/test/config file it creates or modifies), components touched (C1–C13) and interfaces (IF-1–IF-24), a FR/NFR trace, explicit unit-id dependencies, a wave assignment, checkable acceptance criteria (Gherkin reusing the locked FR phrasing where behavioral), named tests with exact `-only-testing:` filters (or an explicit no-test note), and an S/M/L effort estimate with a risk note.
- **Waves:** 10 (W0…W7, plus W6.5 = T-023 and W6.6 = T-024 from the amendments), organized for maximum width around the parallel-safe seams (models / editor UI / voice-ack path / photo-evidence / notifier+calendar / tests). Widths: 4 / 4 / 5 / 3 / 2 / 2 / 1 / 1 / 1 / 1. No two units in a wave own the same file (proof in the wave table below).
- **Estimated effort:** ~41–45 developer-days nominal (2 S, 11 M, 9 L units). Longest dependency chain: 8 waves. With the wave-parallel dispatch (all units of a wave at once) the wall-clock estimate is ~2.5–3.5 weeks; strictly sequential ~9 weeks.
- **Critical path:** T-001 → T-003 → T-009 → T-017 → T-018 → T-020 → T-021 → T-022. Running parallel: the scheduler spine T-001 → T-003 → T-008 → T-010 → T-016 → T-020, and the voice-ack lane T-001 → T-006 → T-013 → T-014 (done by W3). T-021 (evidence surfaces) waits on both the hold seam (T-019) and the settings surface (T-020); T-022 closes the feature.
- **Required resolutions (review-l2) pinned:**
  - **R-1 pin (a) — chosen:** the coordinator mints the log id at capture time (`EvidenceContext.pendingDose(entryId)`), the store names the file by it, and `finalizeAcknowledgement` uses that held id for the log it writes (stated at T-019; the `<logId>.jpg` scheme stays true everywhere, including pending captures).
  - **R-2:** one named home, `ConfirmationChallenge.defaultChallengeTimeoutSeconds`; the scheduler passes it explicitly at both construction sites (`MedicationScheduler.swift` :255, :434) and `AckClarificationConfig` derives its window from the same home; no literal timeout at any call site (T-006).
  - **R-3:** a hold registered when no un-finalized reminder exists for the entry is cleared at registration (file deleted); the record stays honestly evidence-free (T-019, with a named test).
  - **R-4:** the walk consult is a sibling immediately ahead of the `if coordinator?.isAwaitingConfirmation == true` block at `CommandRouter.swift` :1049, so the flag flip skips the block and the refusal ladder (:2491) handles the denial; the two risk-5 router tests are kept (T-014).
- **Scope discipline:** all 22 FR-MSR and 10 NFR-MSR are covered by at least one unit (matrix below); nothing beyond design-l2 and the review findings is added; no timing-target claim is asserted anywhere.

## Contents

- [T-001](tasks/T-001.md) — Slot-clock foundation: types, defaults, fail-closed resolution, mapping store (C1) — Wave 0 — depends on: —
- [T-002](tasks/T-002.md) — Dose line composition from structured quantity (C2) — Wave 1 — depends on: T-001
- [T-003](tasks/T-003.md) — Model additions, legacy migration decode, and the `withScheduleTimes` trap (C6) — Wave 1 — depends on: T-001
- [T-004](tasks/T-004.md) — Ack resolver and closed vocabulary, pure and deterministic (C3) — Wave 1 — depends on: T-001
- [T-005](tasks/T-005.md) — Scanned schedule to slots conversion, pinned hour table (C9) — Wave 1 — depends on: T-001
- [T-006](tasks/T-006.md) — Challenge-timeout single source: named home, explicit at both construction sites, into `AckClarificationConfig` (R-2) — Wave 0 — depends on: —
- [T-007](tasks/T-007.md) — On-device evidence store: compression cap, replace-in-place, fail-soft deletes (C5) — Wave 0 — depends on: —
- [T-008](tasks/T-008.md) — Resolution feed at arming: resolved times, persist-before-arm preserved (C7.1) — Wave 2 — depends on: T-001, T-003
- [T-009](tasks/T-009.md) — Editor draft extension: slot rows, scan application, preselection rules (C8 draft) — Wave 2 — depends on: T-001, T-005
- [T-010](tasks/T-010.md) — Guarded re-arm on mapping change with `SlotClockRearmReport` (C7.2, m-1) — Wave 3 — depends on: T-008
- [T-011](tasks/T-011.md) — Honest push transport, per-contact outcomes, PII-free envelope `v: 1` (C10, D9) — Wave 2 — depends on: T-003
- [T-012](tasks/T-012.md) — Localisation key sets and the M-1 consent copy amendment, ne + en (C13) — Wave 0 — depends on: —
- [T-013](tasks/T-013.md) — Coordinator seams: ack candidates and the clarification walk state (C4 state half, IF-7/IF-8) — Wave 2 — depends on: T-003, T-006
- [T-014](tasks/T-014.md) — Router: resolution call and walk interception placement (C4 router half, R-4) — Wave 3 — depends on: T-004, T-013
- [T-015](tasks/T-015.md) — Calendar significant-event writes and one-off bookkeeping (C11, D7) — Wave 2 — depends on: T-003, T-012
- [T-016](tasks/T-016.md) — Scheduler significant-event triggers, event hooks, and the slot retime refusal (C7.3–C7.5, D10, m-5) — Wave 4 — depends on: T-003, T-008
- [T-017](tasks/T-017.md) — Save plumbing: `MedicationSaveRequest`, N rows to N entries, duplicate rule (C12, D1, m-2) — Wave 3 — depends on: T-002, T-003, T-007, T-009
- [T-018](tasks/T-018.md) — Editor surface: slot/quantity/meal controls, dose rows, edit-existing conversion flow (C8 view) — Wave 4 — depends on: T-009, T-017
- [T-019](tasks/T-019.md) — Evidence hold, finalize attach, discard paths, R-1(a) and R-3 pins (C7.6, IF-15) — Wave 5 — depends on: T-007, T-008
- [T-020](tasks/T-020.md) — Medicine-times settings section, mapping save action, re-arm lines, one-shot retime note, hook wiring (C8/C12) — Wave 5 — depends on: T-001, T-010, T-012, T-016, T-017, T-018
- [T-021](tasks/T-021.md) — Evidence capture plumbing and surfaces: pending-dose hold, record-surface attach, "Taken today" (C5 UX, C12, D11) — Wave 6 — depends on: T-012, T-018, T-019, T-020
- [T-022](tasks/T-022.md) — Integration tests, release gates, and the honesty claim audit (NFR-MSR-008/009, FR-MSR-022/018) — Wave 7 — depends on: T-003, T-013, T-014, T-015, T-016, T-017, T-019, T-020, T-021
- [T-023](tasks/T-023.md) — Medication manage-list screen: list-first Settings surface, explicit add, tap-to-edit (owner-directed defect fix, amendment 6) — Wave 6.5 — depends on: T-018, T-020
- [T-024](tasks/T-024.md) — Scanner frequency→slot grouping: "twice a day" yields two slot rows, Afternoon + Evening after food (owner-directed defect fix, amendment 7) — Wave 6.6 — depends on: T-005, T-009

## Waves: parallel dispatch, file ownership, closing test pass

Dispatch model: the coordinator dispatches ALL units of a wave in parallel (subagents on the shared worktree). Per unit: code + typecheck only — no unit owner runs tests, and no unit's acceptance requires a build beyond typecheck. xcodebuild is serialized across the worktree: exactly ONE consolidated build + scoped test pass per wave, run by the coordinator after the wave's units land, using the filter line in the table. A single full-suite run happens only at the end (W7).

| Wave | Units (dispatched in parallel) | Files owned in this wave (disjointness proof) | Closing consolidated scoped pass |
|------|-------------------------------|-----------------------------------------------|----------------------------------|
| W0 | T-001, T-006, T-007, T-012 | T-001: `Services/MedicationScheduler/MedicationSlotClock.swift` (new), `Tests/.../MedicationSlotClockTests.swift` (new) · T-006: `Services/MedicationScheduler/AckClarificationConfig.swift` (new), `ConfirmationChallenge.swift`, `MedicationScheduler.swift`, `Tests/.../ConfirmationChallengeTests.swift`, `Tests/.../MedicationSchedulerTests.swift` · T-007: `Services/MedicationScheduler/MedicationEvidenceStore.swift` (new), `Tests/.../MedicationEvidenceStoreTests.swift` (new) · T-012: `Resources/Localizable.xcstrings`, `Tests/App/L10nCatalogCoverageTests.swift`, `Tests/App/CalendarShareConsentCopyTests.swift` (new) | `-only-testing:ElderlyAssistantTests/MedicationSlotClockTests -only-testing:ElderlyAssistantTests/ConfirmationChallengeTests -only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/MedicationEvidenceStoreTests -only-testing:ElderlyAssistantTests/L10nCatalogCoverageTests -only-testing:ElderlyAssistantTests/CalendarShareConsentCopyTests` |
| W1 | T-002, T-003, T-004, T-005 | T-002: `DoseLine.swift` (new), `Tests/.../DoseLineTests.swift` (new) · T-003: `Models.swift`, `Tests/.../MedicationEntryMigrationTests.swift` (new), `Tests/Services/FamilyNotifier/FamilyNotifierTests.swift` (raw-value list extension only) · T-004: `MedicationAckResolver.swift` (new), `Tests/.../MedicationAckResolverTests.swift` (new) · T-005: `ScannedSchedule.swift` (new), `Tests/.../ScannedScheduleTests.swift` (new) | `-only-testing:ElderlyAssistantTests/DoseLineTests -only-testing:ElderlyAssistantTests/MedicationEntryMigrationTests -only-testing:ElderlyAssistantTests/FamilyNotifierTests -only-testing:ElderlyAssistantTests/MedicationAckResolverTests -only-testing:ElderlyAssistantTests/ScannedScheduleTests` |
| W2 | T-008, T-009, T-011, T-013, T-015 | T-008: `MedicationScheduler.swift`, `Tests/.../MedicationSchedulerTests.swift` · T-009: `MedicationEditorDraft.swift`, `Tests/.../MedicationEditorDraftTests.swift` · T-011: `Services/FamilyNotifier/FamilyNotifier.swift`, `Tests/Services/FamilyNotifier/FamilyNotifierTests.swift`, `Tests/Services/FamilyNotifier/NotifyChannelTests.swift` · T-013: `App/AppCoordinator.swift`, `Tests/App/MedicationAckClarificationTests.swift` (new) · T-015: `Services/CalendarSync/CalendarShareService.swift`, `Services/CalendarSync/CalendarShareMapper.swift`, `Tests/Services/CalendarSync/CalendarShareServiceTests.swift`, `Tests/Services/CalendarSync/CalendarShareMapperTests.swift` | `-only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/MedicationEditorDraftTests -only-testing:ElderlyAssistantTests/FamilyNotifierTests -only-testing:ElderlyAssistantTests/NotifyChannelTests -only-testing:ElderlyAssistantTests/MedicationAckClarificationTests -only-testing:ElderlyAssistantTests/CalendarShareServiceTests -only-testing:ElderlyAssistantTests/CalendarShareMapperTests` |
| W3 | T-010, T-014, T-017 | T-010: `MedicationScheduler.swift`, `Tests/.../MedicationSchedulerTests.swift` · T-014: `Services/Voice/CommandRouter.swift`, `Tests/Services/Voice/CommandRouterMedicationWalkTests.swift` (new), `Tests/Services/Voice/AckFastLaneTests.swift` · T-017: `App/AppCoordinator.swift`, `Tests/App/MedicationSavePlumbingTests.swift` (new) | `-only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/CommandRouterMedicationWalkTests -only-testing:ElderlyAssistantTests/AckFastLaneTests -only-testing:ElderlyAssistantTests/MedicationSavePlumbingTests` |
| W4 | T-016, T-018 | T-016: `MedicationScheduler.swift`, `Tests/.../MedicationSchedulerTests.swift`, `Tests/.../EscalationEngineTests.swift` · T-018: `App/SettingsView.swift`, `Tests/App/MedicationEditorSurfaceTests.swift` (new) | `-only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/EscalationEngineTests -only-testing:ElderlyAssistantTests/MedicationEditorSurfaceTests -only-testing:ElderlyAssistantTests/MedicationEditorDraftTests` |
| W5 | T-019, T-020 | T-019: `MedicationScheduler.swift`, `Tests/.../MedicationSchedulerTests.swift` · T-020: `App/SettingsView.swift`, `App/AppCoordinator.swift`, `Services/Storage/SettingsPersistence.swift`, `Tests/App/MedicationSlotClockSettingsTests.swift` (new) | `-only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/MedicationSlotClockSettingsTests -only-testing:ElderlyAssistantTests/MedicationSavePlumbingTests` |
| W6 | T-021 | T-021: `App/AppCoordinator.swift`, `App/SettingsView.swift`, `App/MedicationVisualAidViews.swift`, `Services/Notifications/MedicationVisualAidFireHandler.swift`, `Tests/App/MedicationEvidenceCaptureTests.swift` (new), `Tests/App/MedicationVisualAidPresentationTests.swift`, `Tests/Services/Notifications/MedicationVisualAidFireHandlerTests.swift` | `-only-testing:ElderlyAssistantTests/MedicationEvidenceCaptureTests -only-testing:ElderlyAssistantTests/MedicationVisualAidPresentationTests -only-testing:ElderlyAssistantTests/MedicationVisualAidFireHandlerTests` |
| W6.5 | T-023 | T-023 (amendment 6 + addendum, owner-directed): `App/MedicationManageListView.swift` (new), `App/SettingsView.swift`, `App/SettingsTabs.swift`, `App/AppCoordinator.swift` (redraw signal + save-failure propagation), `Services/MedicationScheduler/MedicationScheduler.swift` (the `loadSchedule` persist tail only), `Resources/Localizable.xcstrings` (only if a key is added), `Tests/App/MedicationManageListTests.swift` (new), `Tests/App/L10nCatalogCoverageTests.swift` / `Tests/.../MedicationSchedulerTests.swift` / `Tests/App/MedicationSavePlumbingTests.swift` (only where a shipped pin must be updated) | `-only-testing:ElderlyAssistantTests/MedicationManageListTests -only-testing:ElderlyAssistantTests/MedicationEditorSurfaceTests -only-testing:ElderlyAssistantTests/MedicationSlotClockSettingsTests -only-testing:ElderlyAssistantTests/MedicationSchedulerTests -only-testing:ElderlyAssistantTests/MedicationSavePlumbingTests -only-testing:ElderlyAssistantTests/SettingsTabMappingTests -only-testing:ElderlyAssistantTests/L10nCatalogCoverageTests` (L10n and SettingsTabMappingTests included as executed: the catalog gained `settings.meds.saveFailed` and `SettingsTabs.swift` changed). NOT under the W5/W6 strip directive: this scoped pass runs at the wave close, before W7. |
| W6.6 | T-024 | T-024 (amendment 7, owner-directed): `Services/MedicationScheduler/MedicationLabelOCR.swift`, `Services/MedicationScheduler/ScannedSchedule.swift`, `Services/MedicationScheduler/MedicationEditorDraft.swift` (scan application only), `Tests/.../MedicationLabelOCRTests.swift`, `Tests/.../ScannedScheduleTests.swift`, `Tests/.../MedicationEditorDraftTests.swift`. NOT `SettingsView` and NOT the capture seam (`MedicationLabelScanner.swift`). Delivered as an isolated-worktree patch (`/tmp/msr-scanner-frequency.patch`) applied by the coordinator at wave close. | `-only-testing:ElderlyAssistantTests/MedicationLabelOCRTests -only-testing:ElderlyAssistantTests/ScannedScheduleTests -only-testing:ElderlyAssistantTests/MedicationEditorDraftTests`. NOT under the W5/W6 strip directive: this scoped pass runs at the wave close, before W7. |
| W7 | T-022 | T-022: `Tests/App/MedicationSchedulesIntegrationTests.swift` (new), `Tests/Services/MedicationScheduler/MedicationLLMIndependenceTests.swift` (new), `tools/check-release-log-safety.py`, `Services/Observability/LogSanitiser.swift`, `Tests/Services/Observability/LogSanitiserTests.swift` | `-only-testing:ElderlyAssistantTests/MedicationSchedulesIntegrationTests -only-testing:ElderlyAssistantTests/MedicationLLMIndependenceTests -only-testing:ElderlyAssistantTests/LogSanitiserTests` then ONE full-suite run compared against the documented pre-existing baseline |

Placement rule applied: every unit sits in the earliest wave its declared dependencies allow, and same-file units are never in one wave (one of the two constraints pushed a unit later where they met).

## Cross-wave hotspot ordering (explicit)

Shared files appear in multiple units and MUST land in different waves in this order (each later unit inherits the earlier unit's code):

- `MedicationScheduler.swift` (+ its test suite): **T-006 (W0) → T-008 (W2) → T-010 (W3) → T-016 (W4) → T-019 (W5) → T-021 (W6, IF-24 read seam; ownership extension disclosed in implement-notes) → T-023 (W6.5, the `loadSchedule` persist tail)**.
- `AppCoordinator.swift`: **T-013 (W2) → T-017 (W3) → T-020 (W5) → T-021 (W6) → T-023 (W6.5, redraw signal + save-failure propagation)**.
- `SettingsView.swift`: **T-018 (W4) → T-020 (W5) → T-021 (W6) → T-023 (W6.5)**.
- `FamilyNotifierTests.swift`: **T-003 (W1, adds the two new taxonomy cases to the wire-value stability list) → T-011 (W2, flips the stub-success assertions)**; T-011 depends on T-003.
- `Tests/.../MedicationSchedulerTests.swift`: follows its production file (T-006 → T-008 → T-010 → T-016 → T-019 → T-021 → T-023).
- `CommandRouter.swift`: **T-014 (W3)** only. `Models.swift`: **T-003 (W1)** only. `FamilyNotifier.swift`: **T-011 (W2)** only. `Localizable.xcstrings`: **T-012 (W0)** then **T-023 (W6.5, only if a genuinely missing key is needed)** (later units reference its keys; a key missed at W0 is a follow-up edit in a later wave, pin re-measured by that unit). `SettingsTabs.swift`: **T-023 (W6.5)** only. `MedicationManageListView.swift`: **T-023 (W6.5)** only. `MedicationEditorDraft.swift`: **T-009 (W2) → T-024 (W6.6, scan application)**. `ScannedSchedule.swift`: **T-005 (W1) → T-024 (W6.6)**. `MedicationLabelOCR.swift`: **T-024 (W6.6)** only. Calendar files: **T-015 (W2)** only. `MedicationVisualAidViews.swift` / `MedicationVisualAidFireHandler.swift`: **T-021 (W6)** only. `LogSanitiser.swift` + `tools/check-release-log-safety.py` + `LogSanitiserTests.swift`: **T-022 (W7)** only. `SettingsPersistence.swift`: **T-020 (W5)** only.

## Must-carry obligations index

| Obligation (source) | Unit | Where pinned |
|---------------------|------|--------------|
| R-1 (major) — pending-capture evidence identity: pin **(a)** | T-019 | Acceptance text + `testHoldIdEqualsFinalizedLogId`; finalize change stated at :461 |
| R-2 (minor) — hoist timeout constant; explicit at :255/:434; into `AckClarificationConfig`; no literal; keep shorter-window test | T-006 | Acceptance text + `ConfirmationChallengeTests` / `MedicationSchedulerTests` extensions |
| R-3 (minor) — late hold cleared at registration; record stays honestly evidence-free | T-019 | Acceptance text + `testLateHoldClearedAtRegistration` |
| R-4 (minor) — walk consult sibling immediately ahead of the :1049 block; keep the two risk-5 router tests | T-014 | Acceptance text + `CommandRouterMedicationWalkTests` |
| `withScheduleTimes` migration trap — named test, highest-risk silent defect | T-003 | Acceptance text + `testSlotEntrySurvivesScheduleTimesCopy` |
| Honest push stub flip — `notDelivered("transport_unimplemented")`; flip every stub-success assertion | T-011 | Acceptance text + explicit FamilyNotifierTests flip list |
| D10 — `escalationStarted` at first re-fire decision (`.fireReminder` refireCount 0→1 at :394 / EscalationEngine :117) | T-016 | Acceptance text + `testEscalationStartedAtFirstRefireOnly` |
| D7 — calendar one-off keys out of `outboundKeys` and out of the reconcile snapshot (:703; sweep :553-583) | T-015 | Acceptance text + `testOneOffKeyNotInReconcileSnapshot` |
| M-1 — consent copy amendment ne + en incl. `परिवारलाई परिवारलाई` repair, with the hold condition | T-012 | Acceptance text + `CalendarShareConsentCopyTests` |
| m-5 — `medication_retime_refused` event + one-shot settings note (appointmentSmsNoteDismissed precedent) | T-016 (event), T-020 (note) | Acceptance text in both |
| m-3 — OCR hour table {8→morning; 12/13→afternoon; 19/20/21→evening; others nothing} | T-005 | Acceptance text + `ScannedScheduleTests` |
| m-4 — 3+ candidates: `no` advances; after the last candidate's `no` the walk ends | T-013 | Acceptance text + walk state tests |
| m-1 — `SlotClockRearmReport` per-entry effects surfaced honestly | T-010 (report), T-020 (lines) | Acceptance text in both |
| m-2 — duplicate rule retains the shipped expression incl. mixed legacy/slot pairs | T-017 | Acceptance text + duplicate tests |
| D1 — row = entry; N rows to N entries | T-017 | Acceptance text + `testNRowsCreateNEntries` |
| D9 — `v: 1` on the wire; no PII keys | T-011 | Acceptance text + wire tests |

## Coverage matrix (locked requirement → units)

| FR | Units | | NFR | Units |
|----|-------|-|-----|-------|
| FR-MSR-001 | T-001, T-003, T-009, T-017, T-018 | | NFR-MSR-001 | T-004, T-013, T-022 |
| FR-MSR-002 | T-001, T-008, T-010, T-016, T-020 | | NFR-MSR-002 | T-008, T-011, T-016, T-022 |
| FR-MSR-003 | T-002, T-017 | | NFR-MSR-003 | T-007, T-021 |
| FR-MSR-004 | T-003, T-018 | | NFR-MSR-004 | T-012, T-020, T-021 |
| FR-MSR-005 | T-005, T-009, T-018 | | NFR-MSR-005 | T-018, T-020, T-021 |
| FR-MSR-006 | T-005, T-009, T-018 | | NFR-MSR-006 | T-001, T-003, T-017, T-022 |
| FR-MSR-007 | T-004, T-014 | | NFR-MSR-007 | T-004, T-014, T-022 |
| FR-MSR-008 | T-004, T-012, T-013, T-014 | | NFR-MSR-008 | T-006, T-022 |
| FR-MSR-009 | T-006, T-013, T-014, T-019 | | NFR-MSR-009 | T-012, T-022 |
| FR-MSR-010 | T-019, T-021 | | NFR-MSR-010 | T-008, T-022 |
| FR-MSR-011 | T-014 | | | |
| FR-MSR-012 | T-014 | | | |
| FR-MSR-013 | T-007, T-019, T-021 | | | |
| FR-MSR-014 | T-021 | | | |
| FR-MSR-015 | T-003, T-016 | | | |
| FR-MSR-016 | T-011, T-012, T-015, T-016 | | | |
| FR-MSR-017 | T-003, T-011, T-015 | | | |
| FR-MSR-018 | T-007, T-010, T-011, T-015, T-020, T-021, T-022 | | | |
| FR-MSR-019 | T-008, T-010, T-016, T-022 | | | |
| FR-MSR-020 | T-007, T-017, T-021 | | | |
| FR-MSR-021 | T-018, T-020, T-021 | | | |
| FR-MSR-022 | T-008, T-010, T-019, T-022 | | | |

## Critical path

T-001 → T-003 → T-009 → T-017 → T-018 → T-020 → T-021 → T-022 is the longest chain (models before drafts, drafts before save plumbing, save plumbing before the editor surface, the editor surface before the settings surface, both before the evidence surfaces, all before the integration wave). The scheduler spine T-001 → T-003 → T-008 → T-010 → T-016 → T-020 merges at T-020, and the voice-ack lane T-001 → T-006 → T-013 → T-014 finishes at W3. The two single-unit tail waves (W6, W7) are structurally forced: T-021 needs every surface in place, and T-022 gates the whole feature.

## Key risks

1. **`withScheduleTimes` memberwise rebuild (T-003)** — a slot entry silently loses its slot on any copy path; the named migration test is the guard and must not be dropped.
2. **Router walk interception and denial order (T-014)** — होइन inside a walk must not reach the challenge handler; an acknowledgement inside a walk must restart resolution; the denial ladder (:2491) is the refusal path. Kept as the two risk-5 tests.
3. **Honest push flip breaks shipped assertions (T-011)** — every stub-success assertion in `FamilyNotifierTests` flips with the transport; partial delivery must never read as success.
4. **Re-arm guard (T-010)** — re-arming a finalize-in-flight entry would corrupt the sequence; the guard and the second-pass-replaces-nothing property are tested.
5. **Pending-capture evidence identity (T-019, R-1(a))** — the log id minted at capture is the id finalize writes; the test asserts name equality end-to-end.
6. **M-1 hold condition (T-012)** — until the copy amendment lands, no surface, log line or test may claim the pre-amendment consent text covers the significant-event audience (restated in every unit that could make such a claim: T-015, T-016, T-011; the amendment itself lands at W0, before any of them).
7. **Cross-wave file chains (hotspots)** — the ordering table above is binding for the implement planner; two same-file units in one wave would conflict in the shared worktree.
8. **Full-suite baseline (T-022)** — the single end-of-feature full run is compared against the documented pre-existing full-bundle baseline; scoped wave passes are the working gate.

## Security blockers

None: `review-l2` returned GO with no blockers. The four required resolutions (R-1…R-4) are carried in the named unit obligations (T-019, T-006, T-019, T-014 respectively; see the obligations index). Safety invariants preserved and pinned by unit acceptance: acknowledgement → challenge → double-dose → record remains intact (T-013/T-014/T-019), persistence precedes alarm arming (T-008/T-010/T-019), no new egress and no medication photo leaves the device (T-007/T-021), PII-free observability (T-008, T-011, T-016, T-022), dementia machinery untouched (T-007, T-017, T-021).

## Residual opens consciously deferred

1. **`MedicationSchedulerProtocol` extension** — extended only if a suite needs it (residual open 8 of design-l2); decision rides T-019/T-020 implementation notes, no unit owns a standalone seam change.
2. **DV-1…DV-7 device validation** (Anzaan, final-sign-off gate) — not implement units; the recorded checklist and latency evidence live in final-sign-off. Noted in T-022.
3. **Copy wording polish within the pinned facts** — rides T-012; facts and the M-1 amendment strings are pinned, fine-tuning is allowed only inside them.
4. **Legacy task folders under `specs/plan-tasks/tasks/`** — prior-feature TG folders remain untouched; the flat `T-NNN.md` files and the Contents section above are this feature's authoritative index.
5. **Full-suite baseline** — the single end-of-feature full run (T-022) is reported against the documented known-red baseline; the wave-level scoped passes are the working gate.
