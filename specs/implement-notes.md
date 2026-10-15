# implement-notes — Medication Schedules & Reminders

description: Implementation notes for the medication-schedules-reminders implement task (unit_based, 24 units in 10 waves): per-wave unit outcomes, consolidated scoped test passes, deviations, and the final full-suite comparison.

## Summary

- Task: `implement` (contract `implementation`), feature `medication-schedules-reminders`.
- Plan: `specs/plan-tasks/plan.md` — 24 units, 10 waves (W0:4, W1:4, W2:5, W3:3, W4:2, W5:2, W6:1, W6.5:1, W6.6:1, W7:1), file-disjoint within each wave (W6.5/T-023 and W6.6/T-024 inserted by amendments 6 and 7, owner-directed).
- Cadence: per-unit code + typecheck; ONE consolidated scoped test pass per wave (`ios/build.sh test:unit <Classes...>`); a single full-suite run at W7 (compared against the documented pre-existing baseline).
- Resolution pins carried: R-1(a) at T-019/T-021, R-2 at T-006, R-3 at T-019, R-4 at T-014.

## Wave ledger

| Wave | Units | Consolidated scoped pass | Result |
|------|-------|--------------------------|--------|
| W0 | T-001, T-006, T-007, T-012 | 6 classes — 92 tests (2026-10-15) | PASS — 92/92, 0 failures |
| W1 | T-002, T-003, T-004, T-005 | 5 classes — 42 tests (2026-10-15) | PASS — 42/42, 0 failures |
| W2 | T-008, T-009, T-011, T-013, T-015 | 7 classes — 176 tests (2026-10-15) | PASS — 176/176, 0 failures |
| W3 | T-010, T-014, T-017 | 4 classes — 65 tests (2026-10-15) | PASS — 65/65, 0 failures |
| W4 | T-016, T-018 | 4 classes — 77 tests (2026-10-15) | PASS — 77/77, 0 failures |
| W5 | T-019, T-020 | code + typecheck only (speed directive) | GREEN — combined-tree module emit 0 errors; probes green |
| W6 | T-021 | code + typecheck only (speed directive) | GREEN — combined-tree module emit 0 errors; 3 suites typechecked; probes exit 1 at injected lines |
| W6.5 | T-023 | 7 classes — 139 tests (2026-10-15) | PASS — 139/139, 0 failures; xcresult result Passed |
| W6.6 | T-024 | 3 classes — 72 tests (2026-10-15) | PASS — 72/72, 0 failures; xcresult result Passed |
| W7 | T-022 | full suite vs documented baseline (the tail's single test gate) | pending |

> **Speed directive (owner, mid-run 2026-10-15):** W5 and W6 are code + typecheck
> only — their consolidated scoped passes are skipped, and per-unit
> report-vs-file spot-checks are dropped (typecheck is the per-unit bar). The
> single test gate for the remaining tail is the W7 full-suite run against the
> documented pre-existing baseline. Kept unchanged: the confidence overlay on
> implement units, the W7 full-suite run + release-log-safety gate, and
> final-sign-off (T2 + HIL + DV-1..7 + advisory safety pass). The trade-off is
> owner-accepted: a defect introduced in W5/W6 surfaces only at the W7 suite.
> Do not re-add the scoped passes.

> **Amendment 6 (owner-directed, 2026-10-15):** the owner-reported Settings
> defect (the medication UI always showed the add-new form, never existing
> schedules) inserts **T-023** (medication manage-list screen, W6.5) between W6
> and W7. Its scoped (`-only-testing`) pass runs at the wave close — the strip
> directive above does NOT extend to it — and the W7 full suite then covers it.
> T-023 rides the W5–W7 PR. See
> `specs/plan-tasks/amendments/amendment-6-t023-medication-manage-list-2026-10-15.md`.

> **Amendment 7 (owner-directed, 2026-10-15):** a second owner defect — scanning
> "one tablet twice a day" captures no schedule — inserts **T-024** (scanner
> frequency→slot grouping, W6.6) between W6.5 and W7. Owned files:
> `MedicationLabelOCR.swift`, `ScannedSchedule.swift`, `MedicationEditorDraft.swift`
> (+ their suites); NOT `SettingsView` and NOT the capture seam. Delivered as a
> patch from an isolated temp worktree (`/tmp/msr-scanner-frequency.patch`),
> applied by the coordinator at wave close; its scoped pass runs at the wave
> close (the strip directive does NOT extend to it). Quiescence: no unit in
> flight may touch the three owned files until T-024 lands (W6.5/T-023 does
> not). See
> `specs/plan-tasks/amendments/amendment-7-t024-scanner-frequency-slots-2026-10-15.md`.

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
- T-010 recorded judgment calls: the finalize-in-flight guard is
  deadline-inclusive (`Date() <= deadline`) — an unanswered challenge never
  clears from the map, so a bare presence check would permanently lock an entry
  out of every future re-arm (a lapsed window is not a live finalize; covered by
  a lapsed-window control test); `keptLiveCount` counts reminders (guarded
  entries' live reminders plus re-armed entries' fired reminders);
  `createPendingReminders` gained `@discardableResult -> Int?` as the minimal
  reuse seam (no second arming implementation); IF-12 deliberately lives on the
  concrete scheduler, not `MedicationSchedulerProtocol` (T-020 calls the
  concrete runtime-scoped instance).
- T-014 recorded judgment calls (5): होइन inside a walk is consumed by the walk
  as the resolver's `isNo: true` (the shipped denial vocabulary carries
  छैन/भएन/नखाए but not होइन, per design-l2 step 3) — genuine refusals fall
  through to the refusal ladder; pinned by both risk-5 tests. `.unmatched`
  speaks the shipped `meds.ack.clarifyEnded` key and opens no walk (one
  vocabulary, asserts nothing false); `oldestPendingReminderEntryId()` survives
  only as the legacy-double fallback (production IF-7 and oldest agree); the
  walk consult reads the raw transcript; observation metadata carries entry-id
  hashes only (resolved: the resolved entry's; ambiguous: the first candidate's;
  unmatched/nothing-pending: none).
- T-017 recorded judgment calls (8): an unknown-id update degrades to add
  (documented; no invented error key); gates — empty rows ->
  `settings.meds.timeRequired`, mixed row shapes -> `settings.meds.slotRequired`
  (fail-closed; the view emits single-shape rows from the draft);
  `photoVerificationEnabled` false at every new-entry construction and carried
  verbatim on edit; `editedEntry` names every field memberwise (copy-self
  trap); copied visual aids re-save bytes under the new entry id (fail-soft);
  a slot-resolution failure leaves an empty mirror and never fails the save
  (arming surfaces the unresolved line later); the verification harness
  typechecked a frozen module snapshot (deterministic under concurrent sibling
  edits); no notes file per the binding rules.
- T-016 recorded judgment calls (4): `escalationStarted` fires at the
  `.fireReminder(let refireCount)` arm only when `refireCount == 1` — the
  exactly-once decision is read from the engine's `currentRefireCount`, no
  stored flag, and the arm is unreachable from `triggerReminder`/`recover`;
  `.possibleDoubleDose` anchors `occurredAt`/`fireAt` at `acknowledgedAt`;
  `intakeRecorded` deliberately makes no `onSignificantEvent` call (it writes
  no calendar entry — the T-011 push path covers intake separately; comment at
  the site); the retime-refusal order is emit observation -> fire hook ->
  `return false`, no mutation, `outcome: "info"` on `medication_retime_refused`
  with metadata exactly `entry_id_hash` + `slot`; legacy path unchanged.
  Coordinator flags: T-020 must wire BOTH hooks at composition (an unset hook
  is a safe no-op, but nothing reaches the calendar until wired) and must NOT
  gate the four significant alert types on the caregiver medication toggle.
- T-018 recorded judgment calls (6): the dose-line round trip reconstructs the
  structured quantity only when the stored dose description is exactly
  `DoseLine.compose(quantity, "")` or its rendered-plus-separator prefix; any
  other text (including copy saved in the other language) keeps the stored line
  verbatim in `strength` with the quantity step empty — verbatim, never
  duplicated, but a cross-language edit degrades that entry to the legacy shape
  on re-save (flagged for T-020/T-021 review); no from-entry initializer was
  added (T-009 forbids it) — prefill is field assignment inside the pure static
  factory; the coordinator's slot-clock store is private with no accessor, so
  the view composes a stateless `MedicationSlotClockStore` over
  `MigratingEncryptedStorage` at tap time (precedent: `MedicationScheduler`
  init; never cached; follow-up: add a coordinator accessor); a legacy time
  matching no slot default is left unassigned on family switch and blocks Save
  with `settings.meds.slotRequired` (no fuzzy match, no silent conversion); a
  tap on the selected meal chip clears the relation to nil (the model admits
  nil); every new interactive element carries the 44pt/18pt floors pinned
  line-by-line in the suite.
- T-019 recorded judgment calls (4): the new `evidenceStore` init parameter is
  defaulted nil — holds register but file deletions are skipped, and the
  composition obligation (W6/T-021 passes the shared store) is stated at the
  init site; `attachEvidence`'s unknown-log arm deletes nothing (a bare file
  name cannot resolve its entry directory — guessing is not the seam's
  business); observability ownership split — T-019 emits
  `medication_evidence_discarded` (outcomes late_hold / replaced / denied /
  persistence_failed / attach_failed) and `medication_evidence_attached` with
  entry-id hashes only, while `medication_evidence_captured` remains T-021's;
  the runtime harness used a Foundation-only store double (UIKit unavailable
  off-Simulator) against the real frozen scheduler sources.
- T-020 recorded judgment calls (8): hook wiring sits beside `onScheduleChanged`
  (after all stored properties initialize) and the discarded calendar-write
  result is deliberate (share-consent-gated, inert when unavailable; the
  caregiver-notify toggle is consulted nowhere in the region — T-016's flag
  held); the coordinator's injected `slotClockStore` is now passed through into
  the `MedicationScheduler` construction so save gate, re-arm, arming feed and
  `currentMedicationSlotClock` are one instance (nil keeps prior behavior
  byte-identical); **boundary exception, disclosed:** a paired two-line edit to
  `SettingsPersistenceTests.swift` (one comment + the new allow-list key) —
  that suite pins the backfill list exactly, so without the edit the W5 gate
  would be structurally red; no 40-char token introduced there (two
  pre-existing names in that file remain untouched); the saved line reuses the
  closest existing key (`profile.saved`) and the rearmed/kept counts ride
  `SlotClockSaveResult` fields rather than interpolated copy (T-012 follow-up
  flagged: a dedicated re-arm summary key if W6 wants counts spoken);
  `settings.meds.times.unresolved` carries no placeholder, so unresolved slots
  render as a plain sentence with the slot list riding the struct; reset = seed
  the documented defaults (08:00/13:00/19:00) then save through the same IF-9
  path (validated, persisted, re-armed, honest lines); `MedicineTimesDraft` is
  internal for the reset round-trip test; a literal `.frame(minHeight: 56)` the
  suite's own token pin caught was fixed in the source, not by weakening the
  test.
- T-021 recorded judgment calls (7): the frozen IF-14 case name
  `recordedDose(logId:)` wins over the task prose's `.record(logId:entryId:)` —
  the entryId is resolved from the log itself, which yields the
  decline-before-store property for free; R-3 late hold → `.declinedNoContext`
  (never a claimed hold; the caption and spoken line say the honest "could not
  be saved" — the file really is gone); attach failure → idempotent
  coordinator-side delete + `.failed(.storageUnavailable)` (no path can claim a
  file that is not there); single-flight for the synchronous frozen signature =
  a flow-level active-session flag (a second call answers nil = exactly "no
  capture made") plus the serial store queue; "Taken today" day key =
  `Calendar.current isDate(inSameDayAs:)` over `scheduledAt` (mirrors
  `MedicalView.todaysReminders`), confirmed-only, rows only for surviving
  entries, section hidden when empty; held-state line = the
  `meds.evidence.notYetDelivered` one-shot caption; the capture affordance is a
  property of the dose SCREEN, so `MedicationVisualAidFireHandler.swift` is
  deliberately untouched (its suite hosts the IF-24 named test for the read
  seam under the handler's presentation), and `MedicationVisualAidOverlay`
  reads the coordinator from the environment (root injection verified present).
  **Ownership extension (wave-coordinator, disclosed):**
  `MedicationScheduler.swift` + `LeafViews.swift` — ONLY the IF-24 read seam
  (`takenLogs(on:)`, internal, same visibility discipline as
  `pendingReminders`) and the `MedicalView` "Taken today" section, both
  mandated by the frozen design (design-l2 :82 / :133 / :845) while the plan's
  owned-list omitted them; W6 is a single-unit wave, so the extension is
  conflict-free. pbxproj wiring for the new test file was added by the unit;
  the coordinator canonicalized the project via xcodegen at wave close (the
  agent's hand-written UUIDs were the only diff — identical 4-point wiring).
- W6.5/T-023 recorded judgment calls + deviations (all disclosed): (1)
  `MedicationSchedulerProtocol.swift` edited — not in the enumerated owned
  list; compilation-forced (the frozen-snapshot emit caught the `loadSchedule`
  Void→Bool conformance break); a one-line signature mirror + doc; no other
  conformer or existential exists; residual open 8 (the protocol extension
  decision) closes here. (2) Editor presentation: `fullScreenCover` +
  `EditorTarget` with fresh UUID identity per presentation (two taps on one
  row present twice); a failed save leaves the cover up with the editor's own
  error line. (3) The two shipped scheduler-suite pins the new semantics
  require were read first and updated, never weakened:
  `testPersistenceBeforeAlarmOnScheduleAll` now asserts the Bool and
  nothing-adopted/nothing-armed; `testStorageFailureBlocksArming` was split to
  also drive the reminders-key failure (entries land, one adoption,
  `reminder_persistence_failed`, still nothing armed). (4) A coordinator-level
  storage-failure drive is infeasible (the concrete `MigratingEncryptedStorage`
  + Keychain fallback exposes no seam) — the failure path is driven at the
  scheduler seam, and the coordinator propagation is pinned by source scan
  (4 guard sites, 3 error renders, guard-before-`scheduleAll()` ordering).
  (5) pbxproj canonicalized via xcodegen at wave close (diff vs the agent's
  8 hand-added lines = ordering/UUIDs only; identical wiring); canonical sha
  `f7514841…`; the wave-close build's own xcodegen regeneration re-produced
  the same bytes. (6) The `medication.entries` write sites confirmed: :266
  (`setVisualAids` precedent), :394 (the new write-first `loadSchedule` tail),
  :587 (removal payload, guarded).
- W6.6/T-024 recorded deviations (all disclosed): (1) delivery was an
  isolated-worktree patch applied by the coordinator with `git am` (am
  commit `58071bd4`), not an sdd-dev subagent run — provenance verified
  cryptographically (all ten pre/post-image blob prefixes in the patch's
  index lines matched the worktree before and after the apply; patch
  `/tmp/msr-scanner-frequency.patch`, 34,978 B, source commit `79c915d0…`,
  base master `85349303`); the commit's `Co-Authored-By` trailer is
  preserved. (2) `ScannedSchedule.swift` production was NOT touched by the
  delivered patch — narrower than the amendment's owned-file list; the
  pinned hour-table conversion was already the correct seam, and no change
  was needed there. (3) SEC-002: the patch
  introduced five NEW test method names that are exactly 40 `[A-Za-z0-9]`
  characters (new content must avoid the hash-like-token pattern: 42+ or
  ≤39 are safe). Identifier-only renames of all five landed in the W6.6
  close commit; the exactly-40 maximal-run scan over the five final files
  is 0. The am commit stays byte-authentic in history. (4) Owner rule delta
  folded in before the recorded pass (see the W6.6 verification block): the
  after-food default for label-derived rows; the recorded pass covers its
  new pins. (5) NO `SettingsView` changes and NO new strings: the L10n pins
  were not re-measured (unchanged from the W6.5 close).

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
- **W3 consolidated scoped pass (2026-10-15):** `ios/build.sh test:unit
  MedicationSchedulerTests CommandRouterMedicationWalkTests AckFastLaneTests
  MedicationSavePlumbingTests` — 65 tests, 0 failures, `TEST SUCCEEDED`
  (xcresult 65/65, result Passed). Suite coverage: scheduler 25, router walk 9,
  ack fast lane 21, save plumbing 10. Green on the first attempt; guards green;
  a scoped run does not advance the impact baseline.
- **Unit outcomes (W3):**
  - T-010 — `MedicationScheduler.swift`: IF-12 `rearmForSlotClockChange()` —
    slot entries walked deterministically; finalize-in-flight entries kept whole
    (challenge-active guard, deadline-inclusive); resolution fail-closed with
    the honest `medication_slot_unresolved`; staleness judged by resolution
    equality so a second unchanged pass is a true no-op; mirrors persist before
    in-memory apply and alarm movement; reminders re-placed through the standard
    creation path (no parallel arming code); `SlotClockRearmReport`
    (`rearmedCount`, `keptLiveCount`, `unresolvedSlots`, `persistenceFailed`)
    for T-020's leaf lines. Suite 25 tests (20 shipped + 5 named); an 82-check
    runtime harness ran green.
  - T-014 — `CommandRouter.swift`: `handleMedicationAcknowledgement` resolves
    through the T-004 resolver over the IF-7 candidates (resolved -> the shipped
    challenge/baseline sequence; ambiguous -> the walk; unmatched -> the honest
    line; nothingPending -> the shipped line; the oldest-pending selection
    survives only as the fallback). The R-4 walk consult is a sibling at :1135
    immediately ahead of the confirmation block (:1160): the denial guard runs
    first (one `isMedicationDenial` helper over the shipped phrase list), a
    refusal ends the walk and falls through to the refusal ladder, yes/no inside
    a walk route to the walk. Five new `VoiceCommandCoordinating` requirements
    with inert extension defaults; verified that AppCoordinator's concrete
    members carry all five exact spellings (the app never hits the defaults).
    PII-free `medication_ack_resolved`/`_ambiguous`/`_unmatched`. Suites: walk
    9 (all named, incl. both risk-5 guards) and ack fast lane 21 (19 + 2).
  - T-017 — `AppCoordinator.swift`: IF-21 slot-model save plumbing —
    `MedicationSaveRequest` (file scope); `addMedication(_:)` /
    `updateMedication(id:_:)` / `removeMedication(id:)`; one entry per slot row
    (D1) with the D2 mirror composed through C1 at save time (resolution
    failure leaves an empty mirror, never fails the save); `doseDescription`
    through the T-002 composer; the SHIPPED duplicate expression verbatim
    (exact name equality + effective-time intersection) — mixed legacy/slot
    pairs flag, same-save entries participate, update excludes self, corrupt
    mapping/empty mirror never flags; the evidence cascade on removal
    (fail-soft); `photoVerificationEnabled` false at construction; the shipped
    legacy path untouched. New suite 10 tests. Anchors for T-020: rows built
    from `MedicationEditorDraft.storedRows`, errors are catalog keys
    (`settings.meds.*`).
- **W4 consolidated scoped pass (2026-10-15):** `ios/build.sh test:unit
  MedicationSchedulerTests EscalationEngineTests MedicationEditorSurfaceTests
  MedicationEditorDraftTests` — 77 tests, 0 failures, `TEST SUCCEEDED`
  (xcresult 77/77, result Passed). Suite coverage: scheduler 34 (25 + 9),
  escalation engine 14 (13 + 1), editor surface 6 (new suite), editor draft 23.
  Green on the first attempt; guards green; a scoped run does not advance the
  impact baseline.
- **Unit outcomes (W4):**
  - T-016 — `MedicationScheduler.swift`: the four significant-event triggers —
    `intakeRecorded` after the successful adherence-log write in
    `finalizeAcknowledgement` (deliberately no hook call); `escalationStarted`
    exactly once per reminder at the first re-fire (`.fireReminder` arm,
    `refireCount == 1`); `missedMedication`/`possibleDoubleDose` now carry real
    context through the private `notifySignificantEvent`. Hooks
    `onSignificantEvent` (:136) and `onSlotEntryRetimeRefused` (:145);
    `raiseSignificantEvent` (:1299) invoked at exactly the three at-risk sites
    (:757 / :898 / :953). Retime refusal: the `setScheduleTimes` slot guard
    emits `medication_retime_refused`, fires the hook, returns false, no
    mutation; legacy unchanged. The first-fire opt-in gate is untouched.
    Tests: 9 named in the scheduler suite + 1 in escalation engine; additive
    `MockFamilyNotifier` seam. Anchors for T-020: both hooks wired at
    composition; the four significant alert types are never gated on the
    caregiver toggle.
  - T-018 — `SettingsView.swift` (+ new `MedicationEditorSurfaceTests.swift`):
    slot-model rebuild of the medication editor form (schedule/quantity/meal/
    purpose steps; family chips keep-times / use-slot-model; slot mode never
    shows a clock time to the family) and the edit-existing flow (legacy entry
    reopens `.times` exactly as stored — no fuzzy match, no silent conversion;
    slot entry reopens `.slots` with its row, mirror never shown; family switch
    is an explicit chip tap and nothing persists before Save). IF-21 save: the
    pending-row gate (`settings.meds.slotRequired` for unassigned rows) is
    ordered before the coordinator call; `updateMedication(id:request:)` on
    edit, `addMedication(request)` on add; returned catalog key becomes the
    error line; form resets on success. Pure static seams for T-020
    (`newDraft`, `draft(from:)`, `saveRequest(from:photo:)`,
    `pendingRowFailureKey`, `switchToSlots`, `switchToTimes`). Every string is
    a T-012 catalog key (en+ne verified present); 44pt/18pt floors pinned.
    Suite 6 named tests.
- **W5 (code + typecheck only — speed directive; no scoped pass):**
  - T-019: `swiftc -parse` 0 on both files; frozen-snapshot module emit exit 0
    (164 warnings = the T-018 baseline, 0 errors); test-file typecheck exit 0;
    both error-sensitivity probes exit 1 at the injected lines; optional
    runtime harness over the real frozen scheduler sources ran 121 checks /
    0 failures (the 7 T-019 scenarios plus T-016's 8 as a no-regression
    signal); sha256 re-check matched the frozen bytes after all runs.
  - T-020: `swiftc -parse` 0 on all five files; frozen-snapshot module emit
    exit 0 / 0 errors over a snapshot that INCLUDED T-019's landed scheduler
    (the combined W5 tree typechecks), 164 warnings unchanged; new suite and
    the paired SettingsPersistenceTests edit both typecheck exit 0; both
    probes exit 1 at the injected lines; all 11 consumed catalog keys
    verified non-empty in en+ne; 23 in-suite source pins dry-run pass against
    the final sources; sha256 re-check matched.
  - Not run by directive: the W5 `-only-testing` pass (scheduler / slot-clock
    settings / save plumbing) — the W7 full suite is the tail's single gate.
- **W5 unit outcomes:**

  - T-019 — `MedicationScheduler.swift`: IF-15 evidence hold —
    `holdPendingEvidence(logId:fileName:for:)` (`@discardableResult -> Bool`;
    R-3 late hold deletes the stored file, emits, registers nothing, returns
    false; re-capture deletes the superseded file first);
    `attachEvidence(fileName:toLog:) -> Result<Void, SafetyError>` attaches to
    an existing log only (unknown log = `.reminderPersistenceFailed`, nothing
    created); `finalizeAcknowledgement` mints `held?.logId ?? UUID()`, sets
    `evidencePhotoFileName` before the single persist, and on the failure arm
    deletes the held file, clears the hold, strips the retained record's name
    (intakeRecorded already does not fire); deny arm discards; success emits
    `_attached` once and clears the hold WITHOUT deleting the claimed file.
    Holds are in-memory only (process death loses the claim — honest loss).
    `MedicationSchedulerProtocol` unchanged (residual open 8 default held).
    Suite 34 → 41 tests (7 named).
  - T-020 — `SettingsView.swift` + `AppCoordinator.swift` +
    `SettingsPersistence.swift` (+ new suite): the "Medicine times" card in
    the medication settings — three slot rows with spoken times ONLY through
    the SpokenTime formatter (zero interpolation on the card, pinned),
    DatePickers at the 44pt/18pt floors, reset + save, honest result lines
    (saveFailed / unresolved / saved), and the one-shot retime banner. IF-9
    `saveMedicationSlotClock(_:) -> SlotClockSaveResult` ordered
    validate → persist → `rearmForSlotClockChange()` (invalid or failed
    persist = nothing stored, no re-arm; unresolved slots surface honestly;
    re-arm persistence failure reuses the saveFailed line) with a pure
    `lineKeys(for:)` mapper; `currentMedicationSlotClock()` accessor (closes
    T-018's deviation-3 follow-up; the view constructs no store). One-shot
    note mirrors the appointment-SMS precedent exactly (didSet persist,
    `medicationRetimeNoteDismissed.v1` allow-listed, construction read,
    presented-until-dismissed then never again). Composition wiring:
    `onSignificantEvent` → main hop → `calendarShareService.writeSignificantEvent`
    and `onSlotEntryRetimeRefused` → main hop → surface the note; no caregiver
    toggle anywhere in the region. Suite 7 named tests.
- **W6 (code + typecheck only — speed directive; no scoped pass):**
  - T-021: `swiftc -parse` 0 on all 7 touched/created files; frozen-snapshot
    module emit exit 0 / 0 errors over the combined tree (T-019/T-020 landed),
    164 warnings = the unchanged baseline; all three test suites typecheck
    exit 0 against the emitted module; three error-sensitivity probes (app +
    evidence suite + tail probe on the extended fire-handler suite) exit 1 at
    the injected lines; sha256 re-verified after every run with 0 drift, and
    all 8 reported on-disk hashes matched the report at wave close; the
    forbidden-symbol greps on the capture path are 0 (PhotoVerifier and the
    whole network family — the doc comment was reworded so even the identifier
    substring is absent; FR-MSR-020 clean with no caveat); all 8 consumed
    catalog keys verified non-empty in en+ne; secret-scanner 40-char scan: 2
    pre-existing hits only (pbxproj VariantTables path, presentation-suite
    :179 pre-existing name), 0 introduced.
  - Not run by directive: the W6 `-only-testing` pass — the W7 full suite is
    the tail's single gate (T-021's 9 named tests are typechecked only; the
    report lists the behaviors W7 should target, incl. serial-execution
    storage-key discipline in the three new/extended suites).
- **W6 unit outcomes:**
  - T-021 — `AppCoordinator.swift` (IF-14 `captureEvidence` with the serial
    `medication.evidence.store` queue and main-thread outcome;
    `captureMedicationEvidence` single-flight flow with availability guard and
    the D11 announce; `takenDosesToday()`; `medication_evidence_captured`
    classification-only emission), `MedicationScheduler.swift` (IF-24
    `takenLogs(on:)`), `LeafViews.swift` ("Taken today" section in
    `MedicalView`), `MedicationVisualAidViews.swift` (dose-screen capture
    affordance + one-shot outcome caption). Composition: the shared
    `medicationEvidenceStore` now flows into the `MedicationScheduler`
    construction (object-identity asserted in the first named test). Named
    tests: 6 (evidence capture) + 2 (presentation) + 1 (fire handler) across
    three suites — authored and typechecked; execution rides W7.
- **W6.5 (scoped pass at wave close — amendment 6; NOT under the strip directive):**
  - T-023 agent verification (frozen snapshot `/tmp/msr-t023`, 418 app sources ==
    appfiles.txt exactly; 5 test files byte-equal to the worktree): module emit
    exit 0 / 0 errors, 164 warnings with the normalized warning multiset
    identical to the W6 baseline (60 unique templates, diff empty); the first
    emit attempt caught a REAL compile defect (the `loadSchedule` Void→Bool
    change broke `MedicationScheduler`'s protocol conformance) — fixed in-unit
    by the one-line protocol mirror; test typecheck exit 0/0/0 after one
    harness-set correction (a duplicate `MockObservabilityBus` shim the agent
    had copied in, removed); three error-sensitivity probes exit 1 at the
    injected lines (app :279, test suites :36/:272); zero hash drift across all
    runs; 40-char scan adds none (the 2 pre-existing hits only — the
    scheduler-suite pre-existing name and the pbxproj VariantTables path).
  - Wave-close scoped pass (coordinator-run, feature worktree; release-log-safety
    + prompt-mirror guard preflight green, 0 failures): 7 classes —
    MedicationManageListTests 10, MedicationEditorSurfaceTests 6,
    MedicationSlotClockSettingsTests 7, MedicationSchedulerTests 41,
    MedicationSavePlumbingTests 10, L10nCatalogCoverageTests 40,
    SettingsTabMappingTests 25 — **139/139 passed, 0 failures** (2026-10-15,
    simulator), xcresult result "Passed". SettingsTabMappingTests joined the
    pass because `SettingsTabs.swift` changed and L10nCatalogCoverageTests
    because the catalog gained the new key (the plan row's conditional
    resolved to included).
  - All 11 reported on-disk hashes matched the T-023 report at wave close
    (zero drift); the pbxproj re-hash after the build's own xcodegen
    regeneration equals the canonical sha `f7514841…`.
- **W6.5 unit outcomes:**
  - T-023 — NEW `MedicationManageListView.swift` (list-first screen: one card
    row per entry — name, composed dose line via the T-018 `doseTextHalf` +
    `DoseLine.compose` call, slot/meal "when" line via the shipped
    `slotKey`/`mealKey` statics or `timesText` for legacy, purpose caption;
    explicit add control at the raised tap floor; row tap presents the editor
    PRE-FILLED through `draft(from:)` + `editingEntryId` — a call, never a
    copy; the add form never auto-opens — `editorTarget` nil until a control
    sets it, no `onAppear`/`task` pathway; empty state reuses
    `settings.meds.empty`; the T-020 Medicine-times card stays reachable on
    the manage screen; delete keeps its shipped refusal render;
    44pt/18pt floors pinned). `SettingsTabs.swift` `.meds` route now hosts the
    manage list. `MedicationScheduler.loadSchedule` became write-first-or-fail
    (`Bool`; on failure `entry_persistence_failed` emitted, nothing adopted,
    the previous schedule intact and armed — FR-MSR-022/D2); `setScheduleTimes`
    returns the load result; all four coordinator writer paths guard on it and
    render `settings.meds.saveFailed` on failure, arming nothing. Redraw:
    `AppCoordinator.medicationScheduleRevision` (`@Published private(set)`)
    bumped at the `onScheduleChanged` seam, read explicitly in the list body.
    New catalog key `settings.meds.saveFailed` (en+ne); re-measured pins:
    catalog 1,481 → 1,482, medication family 42 → 43, baselines 1_463 / 1_477 /
    1_459 / 1_464. Suite: exactly the 10 named tests; the persist-failure test
    drives the real scheduler over the mock store (fail write → false + event
    + nothing adopted + previous still armed + disk unchanged) and pins the
    coordinator propagation by source scan.
- **W6.5 root-cause verdict (required deliverable — owner report 2, "it just disappeared"):**
  TWO independent mechanisms confirmed; both made impossible:
  - **Display-only half:** `medicationEntries` is a computed read with no
    observable storage of its own, and the shipped leaf had no dedicated
    redraw signal — a saved entry could fail to draw until unrelated
    `@Published` churn while it was on disk. Now: the revision counter (bumped
    only by committed medication writes) is read in the list body path.
  - **Real-loss half:** the old `loadSchedule` tail discarded the
    `medication.entries` write (`_ = storage.write(...)`) while adopting the
    entries in memory regardless; all four coordinator save paths funnelled
    through it, so a failed write read as "saved" and was gone after
    relaunch/process death. Now: write-first-or-fail with the shipped
    `entry_persistence_failed` event, caller-visible failure, and nothing
    armed behind an unpersisted schedule.
  - On-device confirmation of the round trip (save → row → kill → relaunch →
    row + re-armed) rides DV-1..DV-7 at final-sign-off.
- **W6.6 (scoped pass at wave close — amendment 7; NOT under the strip directive; T-024, scanner frequency→slot grouping):**
  Delivered as an isolated-worktree patch
  (`/tmp/msr-scanner-frequency.patch`, 34,978 B; source commit `79c915d0…`
  on a scratch branch, base master `85349303`) and applied with `git am` in
  the feature worktree → commit `58071bd4` (5 files, +432/−25). Provenance
  verified before and after the apply: all ten pre/post-image blob prefixes
  in the patch's index lines matched the worktree; the commit message
  carries the as-delivered evidence (65 tests, 0 failures — xcresult bundle
  `…22-56-23`) and the `Co-Authored-By: Claude Code` trailer. An
  as-delivered in-worktree pass also ran green (65/65, bundle `…23-00-41`).
  SEC-002 (see deviations): five new 40-character test method names from
  the patch were renamed identifier-only in the W6.6 close commit; the
  exactly-40 maximal-run scan over all five final files is 0.
- **W6.6 owner rule delta (coordinator relay, 2026-10-15 — folded in before the recorded pass):**
  when the scanned label states NO before/after-meal context, the
  label-derived schedule rows default to AFTER FOOD for EVERY row-producing
  shape (frequency rows already carried it; time-word, day-pattern and
  digit-count rows now do too). A relation the label states explicitly
  ("before breakfast", "खानु अघि") always wins; a label mentioning BOTH
  ("before breakfast, after dinner") states none — nothing is defaulted
  over an explicit mention. Fill-blank-only semantics stay: manual entry
  keeps the family's explicit choice (the editor shows the chosen value);
  the default is for label-derived rows only. Implementation:
  `MedicationLabelParser.rowMealRelation(in:)` + ne+en phrase lists, matched
  on the whitespace-collapsed text; the draft's fill logic is unchanged.
- **W6.6 design notes (as handed over; behavior pinned by the recorded pass):**
  (1) the old count table's count-1 row (which guessed 08:00 morning for
  "1 time a day") is REMOVED — refuse-to-guess; "1 time a day" falls
  through to the once-daily phrases (frequency, no times). (2) "2 times a
  day" (digit form) keeps the shipped count-table result [8:00, 20:00] —
  pinned; under the owner delta its rows also carry the after-food default
  like every shape. (3) Meal relation fills BLANK rows only. (4) The
  abbreviation matchers are token-safe ("od" inside "food" cannot fire).
  (5) Nepali phrase variants included. (6) Whitespace-collapsed matching
  handles OCR line splits.
- **W6.6 unit outcomes:** parser: 5 new pins (time-word / day-pattern /
  digit-count rows default after food; explicit before-food kept; mixed
  mentions state nothing) and 3 earlier nil pins flipped to the default
  (the "mixed signals" test); draft: 2 new pins through the real parser
  (time-word default; explicit before-food lands in the blank relation) and
  1 earlier no-relation test rewritten to the default. No-rows shapes
  (once-daily, weekly, refused phrases, no-schedule reads) keep nil — the
  default reaches rows only.
- **W6.6 recorded scoped pass (on the final close-commit bytes):** 3 classes
  — `MedicationLabelOCRTests` 37, `ScannedScheduleTests` 5,
  `MedicationEditorDraftTests` 30 — **72/72, 0 failures, TEST SUCCEEDED**
  (xcresult `…23-09-06`, result Passed, iPhone 17 Pro simulator iOS 26.5;
  "Scoped unit run passed (baseline not advanced)"). Guard preflights green
  (release-log-safety self-tests + prompt-mirror drift classes). Final file
  hashes (shortened): `MedicationEditorDraft.swift` `e47ef130…`,
  `MedicationLabelOCR.swift` `6a3b097e…`, `MedicationEditorDraftTests.swift`
  `14836550…`, `MedicationLabelOCRTests.swift` `5ed20863…`,
  `ScannedScheduleTests.swift` `5a789f99…` (ScannedSchedule tests file
  content unchanged from the am commit; still hashed at close).
- **Carry-forward baseline note (for the W7 full-suite comparison):** the
  Spotify localization suite's absolute key-count pin is red at the branch
  base (pin 1,381 vs catalog 1,439 pre-W0) and is untouched by this feature —
  it belongs to the documented pre-existing baseline, not to this feature's
  regressions.
- **Hygiene note:** two pre-existing camelCase test method names in touched
  suites (challenge + scheduler) are exactly 40 alphanumeric characters and
  trip the release scanner's hash-like-token pattern. They predate this feature
  and stay untouched (renaming shipped tests is out of scope); they are kept
  out of artifact content for the same reason. The W4 pre-flight scan over the
  four touched files is clean; the single boundary-anchored hit in the
  scheduler suite is that pre-existing name (present at HEAD before W4; its
  line simply shifted as T-016's 9 tests were appended). T-018's
  spec-mandated surface test name is 42 characters — boundary-broken, it does
  not match the exactly-40 pattern; the name stays as spec-mandated.
