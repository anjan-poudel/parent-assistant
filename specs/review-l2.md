# review-l2 — Medication Schedules & Reminders: L2 component design

- Review task: `review-l2` (contract `component_design_l2`), feature `medication-schedules-reminders`, project `elderly-ai-assistant`.
- Artifact under review: `specs/design-l2.md`, reviewed at worktree HEAD 3ca1d48c (declared base 5704b50f = its parent).
- Judge set: frozen `specs/design-l1.md`; `specs/review-l1.md` (GO + six required resolutions M-1, m-1…m-5); `specs/medication-schedules-reminders/constitution.md`; locked requirements (22 FR-MSR, 10 NFR-MSR); the worktree code at HEAD for every seam claim.
- Read-only review: no artifact was modified.

## Summary

No blocker was found. Every load-bearing claim was verified against the frozen L1, the locked requirements and the actual code, not taken on trust. All six resolutions required by review-l1 are resolved inside their stated FR/NFR bounds; all eight L1 §24 deferrals are addressed; no L1 contract, invariant or safety-delta item is weakened; each of D1–D11 was judged and none contradicts the frozen L1 or a locked requirement; IF-1–IF-24 carry explicit outcome/error types, stated concurrency, idempotence where claimed, a single-sourced clarification window and a PII-free observability vocabulary; traceability binds all 22 FR-MSR and 10 NFR-MSR with no invented scope; the seam spot-checks against the worktree code hold. Four findings (one major, three minor; Findings section below) are carried as required resolutions. None blocks; the decision is GO.

### Review-l1 resolutions — verified resolved

- **M-1 RESOLVED (option ii, copy amendment).** Both locale texts are present in the review-l1 resolutions section of `design-l2.md` and disclose the significant-event audience honestly: en `…Safety alerts — a missed dose, a possible double dose, or a dose that needs attention — are always shared with every family contact who has an email.`; ne `…सुरक्षा सूचनाहरू — छुटेको औषधि, दोहोरो डोजको सम्भावना, वा ध्यान चाहिने औषधिको समय — इमेल भएका परिवारका सबै सदस्यहरूलाई सधैं पठाइन्छ।` The hold condition is explicit (`Until implementation lands this amendment, no surface, log line or test may claim the pre-amendment text covers the significant-event audience`). The shipped ne duplication `परिवारलाई परिवारलाई` is real in `the app Resources/Localizable.xcstrings catalog` and the amended string repairs it. `calendarShare.consent.body` already discloses the content class and is unchanged. Bounds: FR-MSR-016/017, NFR-MSR-004.
- **m-1 RESOLVED.** `rearmForSlotClockChange() -> SlotClockRearmReport` (IF-12) with per-entry effects (rearmed/kept counts, `unresolvedSlots`, `persistenceFailed`), surfaced through the IF-9 settings result and the settings-leaf lines.
- **m-2 RESOLVED.** The duplicate rule keeps the shipped expression (exact name equality + effective-time intersection) over effective times: slot rows contribute the slot's resolved time (the D2 mirror), so a mixed legacy/slot pair compares resolved-vs-stored and still flags; entries created earlier in the same save participate; `updateMedication` excludes self; a corrupt mapping or empty mirror does not flag.
- **m-3 RESOLVED.** The hour table covers the parser's actual emitted-hour union {8, 12, 13, 19, 20, 21} (`MedicationLabelOCR.timeWordHours` :203, `slotHours` :213, `countedDoseHours` :220): 8:00 → morning; 12:00/13:00 → afternoon; 19:00/20:00/21:00 → evening; dedup with first-occurrence order. No emitted hour is left unmapped.
- **m-4 RESOLVED.** Three or more candidates: `no` advances the cursor and asks the next candidate; after the last candidate's `no` the walk ends (nothing recorded, honest ended line). Pair form keeps L1 §7.3 (`yes` falls to the single form at cursor 0; `no` ends); single form keeps L1. Test obligation present: two `no`s advance, a third `yes` resolves to the third candidate; three `no`s end; fixed scheduledAt/name/id order.
- **m-5 RESOLVED.** Named event `medication_retime_refused` (metadata `entry_id_hash`, `slot`) plus a one-shot settings-leaf note on the `appointmentSmsNoteDismissed` precedent (key and consumption sites verified in `AppCoordinator.swift` :1145/:1151/:3030/:11736 and `LeafViews.swift` :197). Bounds: FR-MSR-002/018.

### D1–D11 — each judged against the frozen L1 and the locked requirements

- **D1 (row = entry; N rows → N entries).** Consistent with the frozen singular `slot` field (`Models.swift` :26) and L1 §11/§4.4; the multi-slot alternative would contradict frozen L1. Accepted.
- **D2 (`scheduleTimes` as resolved-time mirror).** Written only by the save gate and the mapping pass; arming resolves fresh via `resolvedScheduleTimes(for:)`; keeps the display row, the native mirror (`planMedicationMutations`) and the shared-calendar mirror (`medicationDrafts`) working without touching them. Matches L1 §4.4. Accepted.
- **D3 (walk rides `isAwaitingConfirmation`).** The OR-fold is compatible with the shipped OR pattern (`AppCoordinator.swift` :12916); walk/challenge mutual exclusion holds by construction (a resolution opens the challenge, never a walk). Accepted; placement wording is R-4.
- **D4 (walk window is the challenge timeout, one source).** Intent correct (no second constant, no literal); the "injected value" wording does not hold at the shipped seam (R-2).
- **D5 (evidence hold in the scheduler; Meds-leaf record surface).** Required by FR-MSR-013's acceptance scenario (post-record capture surface) and safety delta (c) (attach-never-create). Accepted; identity gap is R-1, late-hold is R-3.
- **D6 (retime refusal family-visible).** One-shot settings note + named event; the honest minimum within FR-MSR-002/018. Accepted.
- **D7 (calendar one-off bookkeeping).** Verified necessary against the live reconcile: the key snapshot is prefix-only today (`CalendarShareService.swift` :703), so one-off keys would be tombstoned without the exclusion; the stale-twin sweep iterates `outboundKeys` only (:553-583), so keeping one-off keys out of `outboundKeys` suffices. 2-component vs 3-component grammar confirmed (`CalendarShareMapper.swift` :24-44). Accepted.
- **D8 (EvidenceStoreError case names).** A documented substitution of L1 §21.2's outline case `writeRequested` by `compressionFailed`; every failure remains typed; no consumer exists. Accepted as a note (N-1).
- **D9 (`v: 1` on the wire).** `buildPayload` (`FamilyNotifier.swift` :153) emits `aps`, `alert_type`, `timestamp` — no `v` key today; adding `v: 1` is additive, PII-free and recorded. Accepted.
- **D10 (`escalationStarted` at the first re-fire decision).** The `.fireReminder(let refireCount)` arm (`MedicationScheduler.swift` :394) sees `refireCount` 0→1 exactly once per reminder (`EscalationEngine.swift` :117); no stored flag. Accepted.
- **D11 (capture announce, n-5).** The fired-dose screens already carry `medicationName` (`MedicationVisualAidViews.swift` :26/:141/:159); the record row and the spoken capture line name it. Accepted.

### Interfaces, concurrency, errors, observability

Every IF method carries an explicit outcome or typed error, or a documented no-error case where the empty case is a value (IF-6 `.nothingPending`; IF-7 pure in-memory read). Concurrency is stated per component and per interface (main-thread state; store work offloaded with the outcome returned on main; one-capture-at-a-time serialization; main-confinement of walk state). Idempotence claims are explicit and checkable (`store` same-name written in place; `delete` absent = success; `end` nil = no-op; hold replace; IF-12 second pass replaces nothing). No literal timeout at any call site: the walk window and re-arm behavior compose from named configuration. The observability vocabulary is PII-free (hash-only identifiers; no name, dose or photo content in events or on the wire), and the error catalogue is explicit (`EvidenceStoreError`; `SafetyError` persistence failures; `SlotClockSaveResult`; editor error keys).

### Seam spot-checks at HEAD (all hold unless noted)

- `withScheduleTimes` memberwise rebuild trap — confirmed (`Models.swift` :144, 14-field rebuild); the C6 replacement rule is required, not optional.
- Shipped duplicate guard — confirmed (`AppCoordinator.swift` :11641-11645, name equality + `scheduleTimes` intersection); with the D2 mirror the kept expression is correct for slot entries.
- Router confirmation follow-up region — confirmed (`CommandRouter.swift` :1049); the generic ambiguous re-prompt consumes unrecognised utterances at :1225, so the walk must be consulted ahead of the arms (R-4).
- `setScheduleTimes` — confirmed (`MedicationScheduler.swift` :152, via `withScheduleTimes` + `loadSchedule`); the slot refusal slots in cleanly.
- `createPendingReminders` ordering — persist (:733) before arm (:737); the C7.1 claim of byte-identical order holds.
- `PhotoVerifier` cap precedent — `maxImageSizeBytes = 200 * 1024` (:27); the evidence store reuses the value as a named constant and does not call, wire or repurpose PhotoVerifier (dementia machinery untouched).
- `CalendarShareKey` grammar — 3-component `slot` vs 2-component `oneOff` (`CalendarShareMapper.swift` :24-44); reconcile snapshot prefix-only today (:703).
- `appointmentSmsNoteDismissed` precedent — key and consumption sites confirmed (m-5).
- `medicationDenialPhrases` — one list, used only at :2464 and :2491; the C4 extracted helper adds no second vocabulary.
- `APNsProvider` stub honesty — `FamilyNotifier.swift` :225-226 prints success and returns true; `emitEventAlerted` hardcodes `outcome: "success"` (:199) — the honest-stub flip is real work with test flips (risk 4).
- `buildPayload` — no `v` key today (D9 accurate).
- `ConfirmationChallenge` — timeout is an initializer default (30, :21) used at :43; the scheduler constructs it without a value (:255/:434) — the D4 wording gap (R-2).
- D10 trigger — `.fireReminder` arm :394 + engine :117; fires once per reminder.
- D11 — presentation carries `medicationName` (:26/:141/:159).

### Risks and residual opens (the design's own list) — assessed

1. **D1 (row = entry).** Accepted; the frozen singular `slot` field makes the alternative unshippable, and the family list showing one row per dose is the honest rendering.
2. **Calendar one-offs (write-once, no re-assert).** Accepted; honest detail, gated by design; family curation in Google is documented.
3. **`withScheduleTimes` trap.** Accepted with the named migration test as a plan-tasks unit obligation — this must not be dropped; it is the highest-risk silent defect.
4. **Honest push stub flips existing tests.** Accepted; the notifier suite and every stub-success assertion must flip with the honest outcome.
5. **Walk interception ordering.** Accepted; pinned by the two router tests named in risk 5 (होइन inside a walk must not reach the challenge handler; an acknowledgement inside a walk restarts resolution). Wording pin: R-4.
6. **Evidence hold across process death.** Accepted; in-memory by design, loss stays honest (never claimed attached).
7. **Copy finalisation.** Accepted; facts are pinned, wording at implementation, catalog coverage gates both locales.
8. **Residual opens for plan-tasks.** Accepted (wave decomposition; wording; test file names; the `v: 1` inventory note; protocol seam only if a suite needs it).

## Findings

- **Blocker:** none.
- **R-1 (major) — pending-capture evidence file identity is not pinned, and the documented naming cannot hold for it.** C5 pins the on-disk scheme as `Application Support/MedicationEvidence/<entryId>/<logId>.jpg` and `re-capture writes the same <logId>.jpg`; IF-13 is `store(image:for logId:entryId:) -> Result<String, EvidenceStoreError>` returning the bare file name; IF-14's `.pendingDose(entryId:)` path holds the photo before any record exists; the log id is minted only at finalize (`MedicationScheduler.swift` :461, `MedicationAdherenceLog(id: UUID(), …)`), and C7.6 has finalize attach the held file to the log it just wrote. No text says what logId the pending capture passes to `store`, and no text threads a capture-time id into `finalizeAcknowledgement`. Under the literal reading the pending file cannot be named by a log id; under the only implementable reading (a capture-time UUID) the naming convention is false for exactly the records the hold exists for. **Action (pin one):** (a) the coordinator mints the log id at capture and `finalizeAcknowledgement` uses it for the log it writes (name equals log id everywhere; state the finalize change), or (b) the bare file name is explicitly opaque and the `<logId>.jpg` phrasing is restated as the record-surface convention only. Bounds: L1 §8.2 (bare file name), §24 deferral 4 (file naming); no safety-delta item is implicated either way.
- **R-2 (minor) — D4's "injected value" wording overstates the shipped seam.** The decision and configuration rows say the window is composed from the same injected challenge-timeout value the scheduler's `ConfirmationChallenge` receives; in the worktree the scheduler constructs `ConfirmationChallenge(locale: locale)` (:255/:434) and `challengeTimeoutSeconds` is an initializer default used only at :43 — there is no injected value today. **Action:** name the home of the single constant (hoist it; pass it explicitly at both construction sites and into `AckClarificationConfig`), keeping no-literal-at-any-call-site. No behavioral risk: the equality property stays guarded by tests that inject a shorter window.
- **R-3 (minor) — late-hold race unaddressed.** IF-14 delivers the `.pendingDose` outcome on main only after the background store completes; C7.6/IF-15 list the hold's paths as attach at finalize, clear on deny/re-enter, replace on re-capture, process death. If the ack chain finalizes before the store completes, the hold lands after the log was written without evidence: the file is never attached and never cleaned until the entry cascade or a newer capture. **Action:** pin the rule (simplest: a hold registered when no un-finalized reminder exists for the entry is cleared at registration, and the record stays honestly evidence-free).
- **R-4 (minor) — walk interception placement stated two ways.** D3/C4 say the walk is consulted inside the `if coordinator?.isAwaitingConfirmation == true` block (:1049) ahead of the yes/no arms, while step 2 relies on the denial falling through to the ladder because the walk's end flips the flag (and risk 5 says the walk block must precede the arms). A consult literally inside the block cannot fall through in Swift without restructuring; the implementable shape is the walk consult as a sibling immediately ahead of the :1049 block, where the flag flip skips the block and the ladder (routeSafetyNet denial arm, :2491) handles the refusal. Behavior is pinned and tested (risk 5), so this is wording precision. **Action:** state the placement unambiguously and keep the two risk-5 tests.
- **N-1 (note) — D8 substitution.** L1 §21.2's outline case `writeRequested` becomes `compressionFailed`; different names for different failures. Accepted (typed errors, no consumer); recommend the text say the outline case is replaced rather than realized.
- **N-2 (note) — IF-13 `deleteAll(for:)` fails soft (Void).** Matches the `VisualAidStore.deleteAll(for:)` cascade precedent (:158) and the fail-soft-toward-truth rule. Accepted.
- **N-3 (note) — IF-14 `.declinedNoContext`.** Defensive case, no `.create` case exists; safety delta (c) holds by construction. Accepted.
- **N-4 (note) — walk consumption of non-yes/no, non-name utterances.** Step 3 mirrors the shipped ambiguous re-prompt (:1225); the router's generic yes/no text is unreachable during a walk (the navigation-walk precedent at `AppCoordinator.swift` :12755). Accepted.
- **N-5 (note) — M-1 ne repair.** Shipped duplication confirmed in `Localizable.xcstrings`; the amended string is the correct repair. Any residual copy polish rides risk 7.

## Decision

GO
No blockers. Required resolutions: R-1 (major) and R-2/R-3/R-4 (minor) — each is a one-place pin, carried into plan-tasks/implement as its own unit obligation. Beyond these, the design elaborates the frozen L1 faithfully: the challenge→double-dose→record chain, the persist-before-arm order, `DoubleDoseDetector`, the unwired `PhotoVerifier`/dementia machinery and the `EscalationEngine` semantics are all preserved, and the six review-l1 resolutions are resolved inside their stated bounds.
