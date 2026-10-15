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
| W1 | T-002, T-003, T-004, T-005 | 5 classes — 42 tests (2026-10-15) | PASS — 42/42, 0 failures |
| W2 | T-008, T-009, T-011, T-013, T-015 | 7 classes — 176 tests (2026-10-15) | PASS — 176/176, 0 failures |
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
- W1 wave-build seam (coordinator-applied): T-003's two appended
  `FamilyAlertType` cases left `FamilyNotifier.alertBody(for:)` non-exhaustive;
  that switch lives in the T-011-owned file (W2). The two arms — exactly the
  bodies design-l2 C6 assigns, resolving `family.alertIntakeRecorded` and
  `family.alertEscalationStarted` — were landed ahead of the W1 consolidated
  build so the wave compiles; T-011 (W2) remains the file's owner for its
  transport-honesty work. No behavior change beyond the two bodies.
- T-003 recorded deviation: `MedicationEntry.scheduleTimes` moved from `let`
  to `var` — the spec-pinned copy-self remedy for the memberwise-rebuild trap;
  all other call sites are reads, so source compatibility holds.
- W1 coordinator fix before closure: the first W1 build failed on exactly one
  compile error — the T-004 test referenced the parser type by a name that does
  not exist (`MedicationLabelOCR`; the declaration is `MedicationLabelParser`).
  One test line corrected, plus two prose comment references realigned
  (`MedicationAckResolver.swift`, `ScannedSchedule.swift`); the rerun is green.
- W2 coordinator test fix before closure: the first W2 pass was 175/176, red only
  on T-015's `testReconcileDoesNotTombstoneWrittenOneOff`. The test drove two
  auto-flushing passes (twin create, then tombstone) while supplying a single
  canned family-calendar answer; the shipped fake consumes canned answers in call
  order, so the second pass failed at the calendar lookup before the twin was ever
  attempted (and the emptied-schedule pass then had nothing known to tombstone).
  Two fresh `["family-cal"]` answers added ahead of each pass, mirroring the
  shipped precedent's own comment on this exact trap; the rerun is 176/176. Test
  file only — no production change.
- T-008 recorded conflict resolution: design-l1 §4.3 says the unresolved-slot
  event carries `entry_id_hash only`; design-l2 §5.2 and the unit spec pin "the
  slot only". Implemented per design-l2/unit spec — metadata is exactly
  `["slot": <slot>]`, pinned by test. Also recorded: the new `slotClockStore`
  init parameter is defaulted (`nil` composes the store over the same storage
  seam), so the W2 app behavior is correct without touching `AppCoordinator`;
  T-020 may pass the shared instance explicitly.
- T-009 recorded judgment calls: draft-init default stays `.times` (the `.slots`
  new-entry default is the view's, per design C8); a slots-mode scan places the
  rebuilt carrier rows on the draft's reference day. Integration note for W4: no
  from-entry initializer was added (not in T-009's spec or IF-22) — T-018 prefill
  is by field assignment, or the initializer becomes a follow-up edit here.
- T-011 recorded deviations (5, all inside owned files): (1) a `PushTransport`
  protocol seam with the provider's static type widened to `any PushTransport`
  (default argument still `APNsProvider()`, pinned send signature unchanged) —
  the mixed-outcome fan-out is unreachable through a stub that cannot deliver;
  (2) `FamilyDeliveryRollup`/`deliveryRollup` so "partial" is a named state
  (`.noRecipients` blocks the vacuous empty-fan-out "all delivered"); (3)
  `buildPayload` private -> internal (the exact seam `notifyAll` sends through);
  (4) the surviving diagnostics line reworded honestly and wrapped in `#if DEBUG`;
  (5) one extra test beyond the named list (empty/failed fan-out rollup). Error
  code vocabulary changed `apns_delivery_failed` -> `transport_unimplemented`
  (no consumer reads the old literal).
- T-013 recorded judgment calls (8, spec-conformant): both spec-pinned IF-8 op
  spellings ship as thin overloads (one implementation each; T-014 compiles
  against either); `medication_ack_clarify_ended` event per design-l2 §5.2
  (`resolved` excluded); narrowed-pair "no" ends the walk (advance reserved for
  3+); begin guards (live challenge outranks; candidates filtered to live
  reminders; empty opens nothing); a candidate-set change ends as `.expired`; a
  resolution ends silently returning the entryId (the T-014 caller continues the
  shipped acknowledgement sequence; no recording path in the walk); new defaulted
  init parameter `ackClarificationConfig`; the utterance-only spelling does not
  interpret yes/no.
- T-015 recorded deviations: type-name reconciliation via typealias (spec
  `SignificantEventWriteResult` vs design `CalendarShareWriteResult` — one type,
  both names); two extra honesty tests beyond the named list; two new
  `calendar_share_*` observability events (shipped metadata keys, no PII);
  write is enqueue-only (no outbound marker, no auto-flush — the shipped flush
  path owns the Google write); test-harness store-failure knob.

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
- **W1 consolidated scoped pass (2026-10-15):** `ios/build.sh test:unit
  DoseLineTests MedicationEntryMigrationTests FamilyNotifierTests
  MedicationAckResolverTests ScannedScheduleTests` — 42 tests, 0 failures,
  `TEST SUCCEEDED` (xcresult 42/42, result Passed). Suite coverage: dose line 5,
  migration 5, family notifier 12, ack resolver 16, scanned schedule 4. The
  first attempt aborted in the compile phase on the single symbol-name error
  now fixed (see Deviations); guards green; a scoped run does not advance the
  impact baseline.
- **Unit outcomes (W1):**
  - T-002 — `DoseLine.swift` (new) + its suite (5 tests): IF-5 composer,
    localized unit labels through the `meds.unit.*` keys, verbatim unknown/custom
    tokens (never repaired), trimmed strength, nil quantity composes nothing.
    Copy-polish candidate for final sign-off: unit labels are singular-invariant
    ("2 tablet") by catalog design — spec-conformant, flagged for the owner's
    polish pass.
  - T-003 — `Models.swift`: optional `quantity` / `slot` / `mealRelation` with
    defaulted memberwise init and `decodeIfPresent` migration; the memberwise
    `withScheduleTimes` trap replaced by a copy-self (recorded deviation above);
    `MedicationAdherenceLog.evidencePhotoFileName` (nil encodes as no key); two
    taxonomy cases appended with all seven shipped positions and raw values
    unchanged; migration suite 5 tests; the notifier suite's wire-value list
    extended (stub-success flips deliberately untouched — T-011 owns them).
  - T-004 — `MedicationAckResolver.swift` (new) + suite (16 tests): name-first,
    then slot (legacy nil-slot entries never match a slot word), then simple ack
    (fired reminder preferred); `.nothingPending` is a value, not an error; walk
    outputs in the fixed order; closed vocabulary mechanically matched to
    design-l2 C3 in both languages; pure (no clock, no I/O, no router symbols).
  - T-005 — `ScannedSchedule.swift` (new) + suite (4 tests): the pinned hour
    table exactly matches the parser's emitted-hour union; unmapped or
    out-of-range reads produce nothing (fail-closed, no clamping); dedup keeps
    first-occurrence order; pre-fill only — the human save gate is untouched.
- **W2 consolidated scoped pass (2026-10-15):** `ios/build.sh test:unit
  MedicationSchedulerTests MedicationEditorDraftTests FamilyNotifierTests
  NotifyChannelTests MedicationAckClarificationTests CalendarShareServiceTests
  CalendarShareMapperTests` — 176 tests, 0 failures, `TEST SUCCEEDED` (xcresult
  176/176, result Passed). Suite coverage: scheduler 20, editor draft 23, family
  notifier 19, notify channel 10, ack clarification 10, calendar share service
  67, calendar share mapper 27. The first attempt was 175/176 — the single red is
  the T-015 test's canned-answer starvation now fixed (see Deviations). Guards
  green; a scoped run does not advance the impact baseline.
- **Unit outcomes (W2):**
  - T-008 — `MedicationScheduler.swift`: IF-11 `resolvedScheduleTimes(for:)` —
    legacy entries return the stored mirror verbatim, slot entries resolve
    through the C1 slot clock read fresh on every call (the mirror is never read
    or written by this path); `createPendingReminders` consumes the feed (an
    unresolved slot arms nothing, the pass continues, PII-free
    `medication_slot_unresolved` with metadata exactly `["slot": <slot>]`);
    persist-before-arm order preserved and pinned by a call-order witness; new
    defaulted `slotClockStore` init parameter. Suite 20 tests. Conflict
    resolution recorded (see Deviations).
  - T-009 — `MedicationEditorDraft.swift`: `ScheduleMode`, `slotRows` (parallel
    count invariant), `MedicationDoseRow` (`.time`/`.slot` — T-017 consumes it in
    W3), `MedicationQuantityDraft` (both-or-nothing stored value),
    `mealRelation` passthrough; `applyScan` routes slots mode through the W1
    scan converter; `applySlotPreselection` (nil rows only, exact equality,
    fail-closed); `storedRows`/`canSaveRequest` (IF-22); `canSave` untouched
    (name-only). Suite 23 tests (16 shipped + 7 named). W4 integration note in
    Deviations.
  - T-011 — `FamilyNotifier.swift`: `PushOutcome` (IF-19) and the `PushTransport`
    seam; `APNsProvider.sendPush` now honestly reports
    `.notDelivered("transport_unimplemented")` — no fabricated success, no
    token-printing log line; per-contact outcomes flow through `notifyAll`;
    `emitEventAlerted` carries the honest outcome; payload envelope `v: 1` with
    `entry_id_hash` only for the four pinned significant events (never
    substituted, nil context omits the key); `FamilyDeliveryRollup` makes
    "partial" a named state. Suites: family notifier 19 (12 shipped + 7),
    notify channel 10 (8 + 2).
  - T-013 — `AppCoordinator.swift` `[MED-ACK-WALK]` section: file-scope walk
    types, `@Published pendingAckClarification`, IF-7 `medicationAckCandidates()`
    in the fixed order (scheduledAt -> canonical name -> uuid), IF-8
    begin/response/end in both spec spellings (thin overloads, one
    implementation each), expiry window from `AckClarificationConfig` only;
    `isAwaitingConfirmation` folds the walk. The walk records nothing and always
    ends deterministically. New suite 10 tests
    (`MedicationAckClarificationTests.swift`; pbxproj regenerated).
  - T-015 — CalendarSync significant-event write: `SignificantMedicationEvent`
    (three kinds, deterministic UTC-stamped minute-truncated identity),
    `CalendarShareWriteResult` (+ typealias), `writeSignificantEvent` (IF-17 —
    consent gate, honest skip reasons for no-invitees/nil-entry, enqueue-only);
    D7 snapshot narrowing (`reconcileSnapshotKeys`: prefix AND slot-shaped) wired
    into the reconcile pass so a written one-off is never tombstoned; mapper
    gains the M-1 family audience (every contact with an email, emergency-first)
    and the one-off draft/title. Suites: calendar share service 67, mapper 27.
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
