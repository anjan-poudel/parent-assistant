# Design L2 — Medication Schedules and Reminders

Feature: `medication-schedules-reminders` (worktree `elderly-ai-assistant-medication-schedules-reminders`,
branch `feat/medication-schedules-reminders`; worktree HEAD 5704b50f).
Task: `design-l2`, agent `principal-engineer`, contract `component_design_l2`.
Date: 2026-10-15.
Status: elaboration of the approved `specs/design-l1.md` (review-l1 GO, 6 required resolutions).
Nothing here redesigns L1; each section resolves an L1 §24 deferral, fixes a component-level
detail L1 left to L2, or resolves one of the six review-l1 findings inside its stated bound.

Inputs read: `specs/design-l1.md` (approved architecture), `specs/review-l1.md` (GO with
resolutions M-1, m-1…m-5 and notes n-1…n-5), `specs/medication-schedules-reminders/constitution.md`,
`specs/define-requirements.md` + all 22 FR-MSR / 10 NFR-MSR files, and symbol-level verification
of the code at the worktree HEAD (file:line references below are orientation; symbols are the
contracts): `MedicationScheduler.swift`, `Models.swift`, `MedicationEditorDraft.swift`,
`MedicationLabelOCR.swift`, `MedicationPurpose.swift`, `EscalationEngine.swift`,
`ConfirmationChallenge.swift`, `DoubleDoseDetector.swift`, `PhotoVerifier.swift`,
`PlatformAlarmScheduler.swift`, `IdHashing.swift`, `VisualAidStore.swift`,
`CommandRouter.swift`, `AckFastLane.swift`, `DialogueManager.swift`, `AppCoordinator.swift`,
`SettingsView.swift`, `LeafViews.swift`, `MedicationVisualAidFireHandler.swift`,
`MedicationVisualAidViews.swift`, `FamilyNotifier.swift`, `CaregiverNotifySettings.swift`,
`CalendarShareService.swift`, `CalendarShareMapper.swift`, `LocalGoogleEventMappingStore.swift`,
`Localizable.xcstrings`.

*Reference convention:* section refs use section names or numbered subsections in document order (Data Models §4.1–4.3, Error Handling §5.1–5.3, Performance and Security §6.1–6.4); components are C1–C13; interface contracts IF-1–IF-24.

## Overview

### What this document decides

The L1 architecture is frozen. L1 §24 left eight items to `design-l2`; all eight are resolved
below, together with the six review-l1 resolutions:

| L1 §24 deferral | Resolved in |
|---|---|
| Clarification-walk state representation; response-window plumbing | Components (C4); Interfaces (IF-8); Configuration and Timeouts |
| Slot/meal word lists (exact strings, both languages); additive ack-phrase additions | Components (C3); Interfaces (IF-6) |
| Exact L10n copy strings | key sets pinned in C13; final wording at implementation (both locales) |
| Evidence store internals (file naming, compression, replace/delete ordering) | Components (C5); Data Models §4.1 |
| Capture-surface placement/details | Components (C5) |
| Calendar one-off bookkeeping (key lifecycle, reconcile interplay, title format) | Components (C11); Data Models §4.3 |
| Editor interaction details (quantity/strength coexistence; mapping control layout) | Components (C8) |
| Wave decomposition | out of scope — `plan-tasks` follows approval |

### The six review-l1 resolutions, resolved (full dispositions in Review-l1 Resolutions)

| # | Finding | Resolution decision | Bound by |
|---|---|---|---|
| M-1 | Calendar invitee/disclosure mismatch | **Option (ii): amend `calendarShare.consent.whoCanSee` in BOTH locales** (exact text in Review-l1 Resolutions, M-1); significant-event one-offs keep the family-notification audience (all contacts with an email, de-dup, emergency-first, toggle-independent). No surface claims the old text covers the deviation; `calendarShare.consent.body` already discloses the content class and is unchanged. | FR-MSR-016/017, NFR-MSR-004 |
| m-1 | `rearmForSlotClockChange()` outcome | Returns `SlotClockRearmReport` (Interfaces IF-12): rearmed/kept counts, unresolved slots, persistenceFailed; the mapping-save action surfaces failure on the settings leaf. | FR-MSR-002, FR-MSR-018, FR-MSR-022 |
| m-2 | Duplicate rule for slot-model saves | The shipped guard is kept and its input pinned: slot entries store the **resolved-time mirror** in `scheduleTimes` (decision D2), so name + effective-time intersection stays the rule across every shape pair; mixed pairs compare the slot's resolved time against the legacy times; a corrupt mapping (mirror empty) does not flag. | FR-MSR-001, NFR-MSR-006 |
| m-3 | Hour→slot table for scanned schedules | Pinned at the parser's emission level (Components C9): 8:00→morning; 12:00 and 13:00→afternoon; 19:00, 20:00 and 21:00→evening; every other hour fills nothing; per-slot dedup, first-occurrence order. | FR-MSR-005/006 |
| m-4 | Multi-candidate clarification "no" | Pinned (Components C4): with three or more candidates **"no" advances the cursor** and asks the next single-candidate question; after the last candidate's "no" the walk ends honestly (nothing recorded). Pair form holds L1's rule ("no" ends; "yes" falls to the single form at cursor 0). Test obligation named in Components C4. | FR-MSR-008, FR-MSR-021 |
| m-5 | Retime refusal visibility + event name | Event named **`medication_retime_refused`** (§5.2); family visibility decided: a one-shot honest note on the medication settings leaf ("Medicine times" section) explains the slot-model rule, dismissible, persisted (the `appointmentSmsNoteDismissed` precedent); the specific entry identity stays in observability (`entry_id_hash`) only. | FR-MSR-002, FR-MSR-018 |

Notes carried from the review are dispositioned under Review-l1 Resolutions (n-1 accepted; n-2 confirmed there;
n-3 orientation-level, symbols used here; n-4 accepted; n-5 realized in C5/C13).

### L2-level design decisions introduced here (flagged for review-l2)

Everything below honors a frozen L1 contract; these are the places where L2 had to choose a
concrete shape. Each is cross-referenced to its section.

- **D1 — A dose row is an entry.** The slot-model save with N dose rows produces N single-slot
  entries (one per row), never a multi-slot entry: `MedicationEntry.slot` is singular in the
  frozen L1 model, and L1 §11's conversion ("assigns each legacy time to a slot … every row
  assigned") plus L1 §4.4's "one pending reminder per day per slot" both read row-by-row. Components (C8).
- **D2 — `scheduleTimes` on a slot entry is a resolved-time mirror, never an arming input.**
  Written only by the save gate and the mapping-change pass; arming always resolves fresh
  (L1 §4.4). This keeps the display row, the native mirror (`planMedicationMutations`) and the
  shared-calendar mirror (`medicationDrafts`) working for slot entries without touching them.
  Components (C6, C7, C8).
- **D3 — The clarification walk rides the confirmation block.** Coordinator state
  (`pendingAckClarification`) reflected in `isAwaitingConfirmation`; the router intercepts walk
  answers inside its confirmation follow-up region, ahead of the generic yes/no arms; the walk
  and a challenge are mutually exclusive by construction. Components (C4); Interfaces (IF-8).
- **D4 — Walk window is the challenge timeout, one source.** `AckClarificationConfig
  .responseWindowSeconds` is composed from the same injected challenge-timeout value the
  scheduler's `ConfirmationChallenge` receives — no literal at any call site. Configuration and Timeouts.
- **D5 — Evidence hold lives in the scheduler; record surface is the Meds leaf.** Pending
  evidence is held per entry on `MedicationScheduler` (so only `finalizeAcknowledgement` can
  attach it); the post-record capture surface is a new "Taken today" section on the Meds leaf
  (Components C5). FR-MSR-013's acceptance scenario ("completed the chain, then photographs") requires a
  record surface to exist.
- **D6 — Retime refusal is family-visible.** One-shot settings-leaf note + the named event
  (m-5). Components (C7, C12); §5.2.
- **D7 — Calendar one-off bookkeeping.** Significant-event one-offs reuse `EventNotifyKind
  .medicationReminder` with the 2-component `CalendarShareKey.oneOff` form; their keys are kept
  OUT of `outboundKeys` (the stale-twin sweep must never tombstone them) and out of the
  medication schedule reconcile's known-key snapshot (so a schedule edit can never tombstone
  them). Event identity is deterministic per (kind, entry, dose occurrence). Components (C11); Data Models §4.3.
- **D8 — `EvidenceStoreError` case names.** L1 §21.2's outline "(writeRequested,
  storageUnavailable, removeFailed)" is realized as `compressionFailed` (the capped JPEG could
  not be produced — the write is then not attempted), `storageUnavailable`, `removeFailed`. Interfaces (IF-13).
- **D9 — `v: 1` on the wire.** `buildPayload` gains the documented envelope version key `v: 1`
  (the E2E plan's `FamilyAlertPayload { v, alert_type, timestamp }`) alongside both the shipped
  keys and the optional `entry_id_hash`. No deployed consumer exists; recorded. Components (C10).
- **D10 — `escalationStarted` trigger.** The reminder's first re-fire decision = the
  `.fireReminder(let refireCount)` arm of `handleAckDeadlineExpired` with `refireCount == 1`
  (state-derived, once per reminder). Components (C7).
- **D11 — The capture affordance announces its bound medication** (n-5): the fired-dose screen
  already titles the bound entry; the record row shows the entry name; the spoken line on
  capture names it. Components (C5).

### Invariants carried unchanged (checked at L2 level)

- Safety delta (a): scan stays candidate → draft → family save; nothing here writes a store on
  scan.
- Safety delta (b): pure total slot→clock resolution; the typed `.indeterminate(slot:)` failure
  arms nothing and is never guessed; all derived instants come from one resolved `Date`.
- Safety delta (c): a photo never creates a record; attach happens only inside
  `finalizeAcknowledgement` or onto an existing `MedicationAdherenceLog` (Components C5; Interfaces IF-14/15).
- Safety delta (d): PII-free wire and events; names/titles in memory only; `entry_id_hash` is
  `IdHashing.shortHash` (a truncated one-way digest).
- OCR confirm-before-binding, deterministic total slot→clock mapping, Devanagari grapheme pin
  (Character-cluster substring containment is the matching convention — no per-grapheme
  fuzzy matching is introduced anywhere), SpokenTime for every spoken time, 44pt/18pt targets.

## Components

Component inventory with L1 status. "NEW" and "CHANGED" files are the only ones this feature
touches; everything else is bound by the L1 preservation rows.

| # | Component / file | Status | Responsibility |
|---|---|---|---|
| C1 | `Services/MedicationScheduler/MedicationSlotClock.swift` | NEW | Slot/meal/quantity types, `TimeOfDay`, the record, pure resolve, validation, the store |
| C2 | `Services/MedicationScheduler/DoseLine.swift` | NEW | Quantity → dose-line composition |
| C3 | `Services/MedicationScheduler/MedicationAckResolver.swift` | NEW | Pure ack resolution + the closed vocabulary |
| C4 | Walk state + router wiring (`AppCoordinator.swift`, `CommandRouter.swift`) | CHANGED | Clarification walk, interception, speaking |
| C5 | `Services/MedicationScheduler/MedicationEvidenceStore.swift` | NEW | On-device evidence file store + capture plumbing |
| C6 | `Services/MedicationScheduler/Models.swift` | CHANGED | Entry/log/taxonomy additions; the `withScheduleTimes` trap |
| C7 | `Services/MedicationScheduler/MedicationScheduler.swift` | CHANGED | Resolution feed, guarded re-arm, trigger sites, retime refusal, evidence hold |
| C8 | `MedicationEditorDraft.swift` + `App/SettingsView.swift` + `App/LeafViews.swift` | CHANGED | Slot/quantity/meal editor, conversion, duplicate rule, mapping section, record surface |
| C9 | `MedicationLabelOCR.swift` + `ScannedSchedule` | CHANGED (bounded) | Pinned hour→slot conversion |
| C10 | `Services/FamilyNotifier/FamilyNotifier.swift` | CHANGED | Honest transport outcome, envelope extension, significant-event contexts |
| C11 | `Services/CalendarSync/CalendarShareService.swift` + `CalendarShareMapper.swift` | CHANGED | Significant-event one-off writes, invitee rule, bookkeeping |
| C12 | `App/AppCoordinator.swift` | CHANGED | Candidate seam, save plumbing, mapping save, capture plumbing, settings note |
| C13 | `Resources/Localizable.xcstrings` (+ `L10n.swift`, coverage test) | CHANGED | New key sets, M-1 copy amendment, both locales |

### C1 — MedicationSlotClock (NEW)

Types exactly as frozen in L1 §4.1/§4.2 (`MedicationSlot`, `MealRelation`, `TimeOfDay`,
`MedicationSlotClock`, `SlotClockError`, `MedicationQuantity`, `MedicationDoseUnit`), plus:

- `MedicationSlotClock.default` = morning 08:00 / afternoon 13:00 / evening 19:00 (OD-1).
- Custom decode: a record with a missing per-slot key decodes that slot as the default; an
  absent record decodes as `.default`. Present-but-invalid values (hour/minute outside range)
  decode as the stored value **as-is** and resolve as `.indeterminate(slot:)` — never clamped,
  never repaired (L1 §4.2).
- Store key `medication.slot_clock` on the shipped `EncryptedLocalStorage` seam; the record is
  small and JSON-encodable like the scheduler's other keys.
- One writer: the settings save action (C12). The scheduler only reads, at arming time
  (C7), through the same store instance.
- `MedicationSlotClockStore` is a thin, stateless façade over `EncryptedLocalStorage`
  (`load()` non-throwing with the decode-with-defaults rules; `save(_:)` validates first and
  returns `Result<Void, StorageError>`); one instance is composed and shared by the scheduler
  (read) and coordinator (write).
- Control shape and copy keys per L1 §4.2 (three rows + reset), localised both languages (C13).
  The rows display each time through `SpokenTime` — the established Updates-leaf display
  exception ("a senior reads what they hear"), since this screen is where the family sets what
  the assistant will speak.

### C2 — DoseLine (NEW)

`DoseLine.compose(quantity:doseText:locale:)` with L1 §4.6's four rules verbatim. Localized
unit labels are catalog keys (`meds.unit.tablet` … `meds.unit.sachet`); a unit string matching
no `MedicationDoseUnit` case is stored and rendered verbatim (the purpose chip-or-free-text
precedent — `MedicationPurposeDraft` is the model for the unit control). The fixed separator
between quantity and non-blank dose text is `", "` (implementation-fixed per L1; the composed
string is the stored `doseDescription`).

### C3 — MedicationAckResolver (NEW, pure)

L1 §7.2's algorithm verbatim, with the L2-pinned vocabulary:

```
MedicationAckVocabulary (closed sets, canonical form via MedicationVoiceVocabulary.canonical):
  slotWords: morning -> ["morning", "बिहान", "सकाळ"]
             afternoon -> ["afternoon", "midday", "noon", "दिउँसो"]
             evening -> ["evening", "night", "बेलुका", "राति"]
  mealWords (recognised only; NEVER filters, discriminates or selects — OD-1):
             beforeMeal -> ["before meal", "before food", "before eating", "खानु अघि", "खाना अघि"]
             afterMeal  -> ["after meal", "after food", "after eating", "खानु पछि", "खाना खाएपछि"]
```

The slot word families mirror the scanner's word families (`MedicationLabelOCR.timeWordHours`
:203) so the house has ONE vocabulary, not two inventions. Word sets are matched as
substrings of the canonical transcript with the Devanagari grapheme pin respected
(NFR-MSR-007): Swift Character-cluster containment, exactly the shipped convention.

Resolver inputs: `transcript` (canonicalised internally), `candidates` (one per pending
reminder, ordered by `scheduledAt`). Output `AckResolution` with L1 §7.2's four cases. Name
keys come from `MedicationVoiceVocabulary.voiceKeys(for:)` (name first, then purpose keys,
dedup, stable order — the first matching key decides nothing by itself; matching is per
candidate). The walk order for `ambiguous`/`noMatch` is fixed here at entry: `scheduledAt`,
then canonical medication name, then id.

Additive ack-phrase additions (L1 §7.1 leaves the lists extendable additively): the resolver
itself needs none — the owner's utterance shape already matches the shipped lists; if
implementation extends `medicationAckPhrases`/`medicationAckTokens`, the denial guard stays
first and the lists are extended only (never reordered).

### C4 — Clarification walk (state + router wiring)

**State (coordinator, main thread).**

```swift
struct AckClarificationState {
    let candidates: [MedicationAckCandidate]   // ordered: scheduledAt, canonical name, id
    var cursor: Int                            // 0-based single-form position
    var pairAsked: Bool                        // exactly-2 opening question spoken
    let deadline: Date
}
@Published private(set) var pendingAckClarification: AckClarificationState?
var isAwaitingAckClarification: Bool { pendingAckClarification != nil }
// isAwaitingConfirmation becomes: challenge-open || pendingAckClarification != nil
```

**Router wiring**: inside the confirmation follow-up region of `CommandRouter.route` (the
`if coordinator?.isAwaitingConfirmation == true` block :1049), the walk is consulted FIRST with
this exact order (refusal-first preserved):

1. Explicit acknowledgement → end the walk (`.bargedIn`), call
   `handleMedicationAcknowledgement(transcript: raw)`, return `.acknowledgedMedication`
   (the L1 §7.3 barge-in rule; an ack is never consumed as a yes/no answer).
2. Denial (the shipped `medicationDenialPhrases` :2425 checked via one extracted helper —
   one list, no second vocabulary) → end the walk (`.denied`); the utterance falls through
   to the ladder unchanged (the walk's end flips `isAwaitingConfirmation` false, so the shipped
   confirmation block below cannot swallow the denial; refusal semantics preserved, FR-MSR-011).
3. Otherwise → `coordinator.ackClarificationResponse(raw:isYes:isNo:)`; return
   `.unrecognised(transcript: raw)`. The coordinator speaks its own lines (the navigation-walk
   precedent — the router's generic `router.confirmationYes/No` text must not be reached while
   the walk is open).

**Walk behaviour (coordinator), pinned:**

- Entry: `beginAckClarification(orderedCandidates:)` is called only when no challenge is open
  (invariant: walk and challenge are mutually exclusive — an acknowledgement arriving while a
  medication challenge is open is intercepted by the shipped block and re-prompted; a
  resolution that resolves opens the challenge, never a walk).
- Exactly two candidates: the pair question first ("did you mean X or Y?"); "yes" falls to the
  single form at cursor 0; "no" ends the walk (nothing recorded). One candidate (and `noMatch`
  with one pending): single form; "yes" resolves; "no" ends.
- Three or more: single-candidate form from cursor 0; **"no" advances the cursor and asks the
  next candidate**; after the last candidate's "no" the walk ends (nothing recorded, honest
  ended line). Never a numbered list, never a leading question.
- A response naming any walk candidate (name-key containment over the same vocabulary as C3)
  resolves to it at any cursor.
- Resolution → the shipped sequence: `startVoiceAckConfirmation(for:)` → prompt spoken →
  `handleMedicationConfirmation` → challenge → detector → record. Nothing in that chain is
  touched.
- Expiry: the walk timer ends it (`.expired`), nothing recorded, reminders untouched,
  escalation continues on its own clock. Every ending other than a resolved yes records
  nothing and says so honestly (catalog key, both locales).
- Test obligation (m-4): a walk over three candidates where two "no"s advance and a third
  "yes" resolves to the third candidate; three "no"s end with nothing recorded; the walk order
  is the fixed `scheduledAt`/name/id order.

### C5 — MedicationEvidenceStore (NEW)

File-per-record storage, one directory per entry (the `VisualAidStore` pattern — a directory
per entry so the entry-delete cascade is one call):

```
Application Support/MedicationEvidence/<entryId>/<logId>.jpg     // .completeFileProtection
```

- Cap: `MedicationEvidenceStore.maxPhotoBytes = 200_000` (the FR-D04b `PhotoVerifier` :27
  precedent; named once, not a literal at call sites). Compression: downscale-to-fit plus a
  JPEG-quality loop until the cap holds — implemented INSIDE this store; `PhotoVerifier` is not
  called, wired or repurposed (FR-MSR-020 / L1 §8.5: the dementia machinery stays unwired).
- One photo per record: re-capture writes the same `<logId>.jpg` (replace in place; atomic
  write, so the old file is never half-gone). The model stores the bare file name only —
  never a path, never bytes (L1 §8.2).
- All methods fail soft toward the truth, never toward a claim: a missing/corrupt read returns
  nil (never a fabricated image), a failed write returns a typed failure, a delete of an
  absent file is success (idempotent — the goal state is achieved).
- Caller-side threading: the coordinator runs store calls off the main thread (the scanner's
  `offload` discipline :81) and hops back to the main queue for model writes. The store itself
  is stateless over the filesystem; the camera discipline (one capture at a time, the shipped
  `isRunning` guard pattern) serialises per-record writes at the caller.

### C6 — Models (CHANGED)

- `MedicationEntry`: `quantity: MedicationQuantity?`, `slot: MedicationSlot?`,
  `mealRelation: MealRelation?` — all `decodeIfPresent` in the custom `init(from:)` (:114,
  CodingKeys extended), memberwise init gains them with `nil` defaults.
- **The `withScheduleTimes` copy trap (:144)**: the memberwise rebuild MUST carry every field,
  including the three new ones; implementation replaces the memberwise rebuild with a
  `withScheduleTimes` that copies `self` and replaces only `scheduleTimes` (or passes every
  field explicitly). A migration test pins "a slot entry copies with its slot intact"
  (NFR-MSR-006 obligation carried from review-l1 risk 7).
- `MedicationAdherenceLog`: `var evidencePhotoFileName: String? = nil` (synthesized Codable
  treats an optional as `decodeIfPresent`, so pre-existing payloads decode with nil; the
  default keeps the three construction sites compiling).
- `FamilyAlertType`: `case intakeRecorded`, `case escalationStarted`. `alertBody` (:186-ish
  switch) gains the two cases with catalog keys `family.alertIntakeRecorded` /
  `family.alertEscalationStarted` (both locales).
- `MedicationSlot`/`MealRelation`/`MedicationQuantity`/`MedicationDoseUnit` live in C1's file
  (L1 §19 row) and are referenced by the model.
- `SignificantMedicationEvent` (C11's input) lives in the calendar service's file, not here.

### C7 — MedicationScheduler (CHANGED)

1. **Resolution feed** (L1 §4.4 verbatim): `resolvedScheduleTimes(for:)`; legacy → verbatim
   `.success(entry.scheduleTimes)`; slot → the mapping's `TimeOfDay` as `[.hour,.minute]`;
   `.indeterminate(slot:)` → the entry is skipped, `medication_slot_unresolved` event,
   settings error surfaces. `createPendingReminders` (:707) consumes this seam in place of
   reading `entry.scheduleTimes`. Nothing else in the creation pipeline changes
   (persist :733 → arm :735–744 stays byte-identical in order).
2. **Guarded re-arm** (L1 §4.5 verbatim) as `rearmForSlotClockChange() -> SlotClockRearmReport`
   (IF-12): fired reminders keep their persisted `scheduledAt`/engine (live escalation never
   moves); un-fired reminders whose resolution changed are replaced via the standard creation
   rules; **the slot entries' `scheduleTimes` mirrors are rewritten to the new mapping and
   persisted (entries write) before any reminder is armed; `onScheduleChanged` is invoked
   after the local work is committed** (the `loadSchedule` ordering comment :180–199 is the
   precedent — the calendar mirrors must see the new times); failure of either write sets
   `persistenceFailed` and arms nothing on the replaced set.
3. **Trigger sites** (L1 §9.1): `intakeRecorded` inside `finalizeAcknowledgement` after the
   adherence-log write succeeds (:476) and before runtime cleanup; `escalationStarted` in
   `handleAckDeadlineExpired`'s `.fireReminder(let refireCount)` arm when `refireCount == 1`
   (the first re-fire decision; state-derived — never a stored per-event flag). Both call
   `notifyAll(alertType:at:context:)` with a `FamilyAlertContext(kind: .medicationReminder,
   eventIdHash: IdHashing.shortHash(of: entry.id), eventTitle: entry.medicationName,
   fireAt: scheduledAt)` — the in-memory-only title rule stands. `recordMissedDose` and the
   double-dose blocked branch gain the same context (they currently pass none).
4. **Significant-event calendar hook**: `var onSignificantEvent:
   ((SignificantMedicationEvent, MedicationEntry?) -> Void)?` (the `onScheduleChanged`
   precedent :58), invoked at the three at-risk trigger sites (recordMissedDose; the blocked
   branch of `checkDoubleDoseAndRecord`; the first re-fire decision) on the main thread.
   `events` = the notifier call and the calendar hook are independent channels; neither gates
   the other.
5. **Retime refusal** (`setScheduleTimes` :152): a slot entry (`slot != nil`) returns `false`
   without writing; emits `medication_retime_refused` (metadata: `entry_id_hash`, `slot`);
   invokes `onSlotEntryRetimeRefused?(entryId)` (the settings-note hook, C12). Legacy entries:
   byte-identical shipped behavior. The refusal is the non-interpretation (L1 §11): the
   authority stays the settings editor.
6. **Evidence hold** (safety delta (c)): `holdPendingEvidence(fileName:for:)` stores one held
   file name per entry (in-memory; a new hold replaces and deletes the prior file);
   `finalizeAcknowledgement` attaches the held file to the log it just wrote (setting
   `evidencePhotoFileName` + persisting; a failed attach persists nothing and deletes the
   file — no orphan); `reEnterEscalation` and the challenge-deny path call
   `discardPendingEvidence(for:)` (delete + clear; idempotent). `attachEvidence(fileName:
   toLog:)` is the record-surface attach (persist the mutated log; on failure delete the
   just-stored file and return the typed failure).

### C8 — Editor draft, Settings editor, Meds leaf (CHANGED)

- **Draft** (`MedicationEditorDraft`): adds `scheduleMode: ScheduleMode` (`.times` | `.slots`),
  `slotRows: [MedicationSlot?]` parallel to `times` (single form, rows = doses), the quantity
  fields (amount + unit, the `MedicationPurposeDraft` chip-or-free-text shape), and
  `mealRelation`. All shipped rules stay bound: `applyScan` pre-fills blank text only, the
  label's schedule wins, an empty read changes nothing, `storedTimes` stays `[.hour,.minute]`
  (:143), `canSave` still requires a name (:149). The scanned schedule is applied through C9's
  conversion: in `.slots` mode the scanned slots replace the slot rows; `times` never becomes
  empty (the last row cannot be removed, :126).
- **New-entry form** (`addForm` :4640, C12 save): `.slots` mode by default; the time pickers
  are replaced by big slot controls (44pt+/18pt+, the mapping time as read-only context in
  spoken form); a "add another dose" row lets the family add a second row (a twice-daily
  medicine) — on save each row becomes its own entry (D1). The quantity/strength coexistence
  follows the purpose precedent: the strength field stays the scan target and free text; the
  quantity control composes into `doseDescription` via C2 at save (rule 2 keeps both:
  "1 tablet, 500 mg").
- **Edit-existing flow (new, required by L1 §11's conversion).** The medication row becomes
  tappable (photos/delete buttons unchanged) → the same form pre-filled from the entry
  (`MedicationEditorDraft(from: entry)`, `scheduleMode = .times` for a legacy entry showing its
  times). A "Use morning / afternoon / evening" control switches to `.slots`; exact-equality
  preselection applies (a legacy time whose hour:minute equals the mapping's time for a slot
  may preselect it — visible in the chips, family-confirmed on save); any unmatched row
  requires the family to pick a slot or remove the row; the slot-model save is gated on every
  row being assigned; the family may save in `.times` mode (legacy stays first-class). Save via
  C12's `updateMedication`. Conversion of row 1 updates the entry in place (same id, visual
  aids and history linkage kept); rows 2+ create new entries with copied visual aids (D1).
- **Duplicate rule (m-2)**: the guard keeps the shipped expression (exact name equality +
  effective-time intersection, `addMedication` :11641–11645) over EFFECTIVE times: legacy rows
  contribute their stored components, slot rows contribute the slot's resolved time (the
  mirror, D2 — a corrupt mapping leaves the mirror empty and does not flag). Save-time checks
  include entries created earlier in the same save (two rows assigned the same slot → the
  second flags). `updateMedication` excludes the entry being updated from its own check.
- **Mapping section** ("Medicine times", `settings.meds.times.*` keys): three rows (slot label +
  SpokenTime string) with large controls, validation before persist, a reset action, the m-5
  one-shot retime note (dismissible), and the honest failure lines for the save/re-arm outcome.

### C9 — Scanned schedule → slots (CHANGED, bounded)

`ScannedSchedule` (pure helper, new small type beside the parser):

```
static func slots(from scheduleTimes: [DateComponents]) -> [MedicationSlot]
```

Pinned conversion table (m-3), applied to the parser's emitted hours:
8:00 → morning; 12:00 and 13:00 → afternoon; 19:00, 20:00 and 21:00 → evening. Every other hour
fills nothing. Output order = first occurrence in the parser's clock-ordered list, deduplicated
per slot (a count-4 read yielding 8:00/13:00/19:00/21:00 converts to
[morning, afternoon, evening]). The parser surface itself is untouched (no new tables, no
`timeWordHours` change), and the conversion never consults the household mapping — it maps the
parser's convention hours (L1 §6 boundary).

### C10 — FamilyNotifier (CHANGED)

- `APNsProvider.sendPush(payload:deviceToken:) async -> PushOutcome` where
  `enum PushOutcome: Equatable { case delivered; case notDelivered(reason: String) }`. The stub
  returns `.notDelivered(reason: "transport_unimplemented")` and logs nothing that claims
  delivery (the current `[APNsProvider] Push sent…` print goes away). `notifyAll` maps
  delivered → `success: true`; notDelivered → `success: false, errorCode: reason` (replacing
  the generic `apns_delivery_failed`); partial results stay partial.
- `buildPayload(alertType:timestamp:entryIdHash:)`: emits `aps`, `v: 1` (D9), `alert_type`,
  `timestamp`, and `entry_id_hash` only when supplied. The four medication significant events
  (missedMedication, possibleDoubleDose, intakeRecorded, escalationStarted) supply
  `context.eventIdHash`; `eventReminder` payloads keep their current shape (no entry_id_hash;
  the context stays in memory). No name, dose, label text or title on any wire.
- `family_event_alerted` observability outcome becomes honest (per-contact result mapped to
  `success`/`failed` with `error_code`) instead of the hardcoded `"success"`.
- The per-contact loop, `NotifyChannel.resolve`, and the default protocol extension are
  unchanged; existing notifier tests that asserted stub success flip with the honest stub
  (NFR-MSR-008 obligation carried from review-l1 risk 4).

### C11 — CalendarShareService / CalendarShareMapper (CHANGED)

```swift
struct SignificantMedicationEvent: Equatable {
    enum Kind: String { case missedMedication, possibleDoubleDose, escalationStarted }
    let kind: Kind
    let entryId: UUID
    let occurredAt: Date        // the trigger timestamp — the entry's start
    let id: String              // deterministic identity, see below
}
```

- **Identity (D7)**: `id = "\(kind.rawValue)_\(entryId.uuidString)_\(occurrenceStamp)"` where
  `occurrenceStamp` = the dose occurrence's `scheduledAt` formatted `yyyyMMddHHmm` in UTC. The
  key is `CalendarShareKey.oneOff(kind: .medicationReminder, eventIdentifier: id)` — a valid
  2-component key (no colon in the id). Deterministic ⇒ a re-trigger of the same logical event
  enqueues the same key (the store's replace-same-key behavior), no duplicates.
- **Write** (`writeSignificantEvent(_:entry:) -> CalendarShareWriteResult`): on the main queue;
  `canShare` gate first (not signed in / no consent → `.skippedNotActive`, the shipped
  honest event with the kind; nothing queued — the shipped no-queue-when-gated rule);
  attendees = the family-notification audience (all contacts with an email, de-dup
  case-insensitively, emergency-first — the M-1-resolved rule; the notify toggles are NOT
  consulted for significant events); no eligible invitee → `.skippedNoInvitees` (shipped honest
  event); otherwise `enqueue(key:draft:)` → `.enqueued`. The write does NOT `markOutbound`
  (the stale-twin sweep only considers outbound keys, and these have no local EventKit event —
  marking them would queue tombstones for live entries). Result is reported per item; the
  Settings status card's pending count remains the delivery surface.
- **Reconcile interplay (D7)**: `reconcileMedication` computes its known-key snapshot as the
  slot-shaped keys of its kind (3-component keys) so significant-event one-offs can never be
  read as "removed" and tombstoned by a schedule edit. The forward mirror path is otherwise
  untouched.
- **Title format (L2-deferred item)**: `"<Localized event phrase> — <medicationName>"`
  (e.g. "Missed medicine — Metformin 500"), keys `calendarShare.alert.missed` /
  `.doubleDose` / `.escalation`, both locales. Start = `occurredAt` (one rule for all three:
  the entry is anchored at the moment the event happened; duration = the house 30-minute
  default, `recurrence = nil`). Same content class as the shipped mirror (medication name +
  time), inside the amended consent disclosure (M-1). Honesty: the mapper is a pure
  function; the service gates.
- `CalendarShareWriteResult`:
  `enum CalendarShareWriteResult: Equatable { case enqueued, skippedNotActive,
  skippedNoInvitees, failed(reason: String) }`.

### C12 — AppCoordinator (CHANGED)

Adds the candidate seam, the walk ops, the save plumbing, the mapping save + note, and the
capture plumbing and the `removeMedication` evidence cascade (`deleteAll(for:)`, beside the visual-aid cascade); all main-thread state, verified in Interfaces. The `addForm` save now routes
through `addMedication(MedicationSaveRequest)`; `medicationEntries`, `pendingReminders`,
`medicationVoiceEntries`, `oldestPendingReminderEntryId` :12929 and the confirmation helpers
remain (`oldestPendingReminderEntryId` keeps its only remaining purpose as the router's
fallback path should the resolver be unavailable — the baseline `handleMedicationAcknowledgement
(entryId:)` path; it is no longer the resolution step).

### C13 — Localisation (CHANGED)

New key SETS (exact wording at implementation, both locales, catalog coverage test extended):

- Slot/meal/quantity labels: `meds.slot.morning|afternoon|evening`, `meds.meal.before|after`,
  `meds.quantity.amount`, `meds.quantity.unit`, `meds.unit.tablet|capsule|milliliter|teaspoon|
  drop|puff|sachet`, `meds.quantity.customUnit`.
- Mapping section: `settings.meds.times.title|morning|afternoon|evening|reset`,
  `settings.meds.times.saveFailed`, `settings.meds.times.unresolved`,
  `settings.meds.times.retimeNote` (m-5 note), `settings.meds.times.retimeNote.dismiss`.
- Editor: `settings.meds.useSlotModel`, `settings.meds.keepTimes`,
  `settings.meds.slotRequired` (a row without a slot blocks the slot save),
  `meds.addDose`.
- Walk + outcomes: `meds.ack.clarifyOne` ("did you mean %@?") and `meds.ack.clarifyPair`
  ("did you mean %@ or %@?") — the ONLY permitted forms; `meds.ack.clarifyEnded` (nothing
  recorded, honestly).
- Evidence: `meds.evidence.capture`, `meds.evidence.spoken` ("photo for %@" — names the bound
  medication), `meds.evidence.attached`, `meds.evidence.failed`,
  `meds.evidence.notYetDelivered` (the honest state per L1 §8.1), `meds.takenToday.title`.
- Family alerts: `family.alertIntakeRecorded`, `family.alertEscalationStarted`;
  `calendarShare.alert.missed|doubleDose|escalation`.
- **M-1 copy amendment** (Review-l1 Resolutions, M-1): `calendarShare.consent.whoCanSee` amended in both locales.
- `L10nCatalogCoverageTests` extended for every key; no new string ships in one language only
  (NFR-MSR-004/005).

## Interfaces

Every seam below is an in-process Swift contract (single iOS process; no network surface is
added). Each entry states: signature, outcome/error type, concurrency, and idempotence where
it matters. 24 numbered interface contracts; their error types are collected in the Error Handling catalogue (§5.1).

### IF-1 — Slot resolution (pure)

```swift
extension MedicationSlotClock {
    func resolve(slot: MedicationSlot) -> Result<TimeOfDay, SlotClockError>
}
```

Pure, total over the three-case enum; the one failure is `.indeterminate(slot:)` from a
present-but-invalid stored value. No clock, no IO (the record is a value). Thread-safe by
construction; callable from any context. Idempotent (pure).

### IF-2 — Mapping validation (pure)

```swift
extension MedicationSlotClock {
    static func validate(_ clock: MedicationSlotClock) -> Result<Void, SlotClockError>
}
```

Rejects out-of-range hour/minute as `.indeterminate(slot:)` for the offending slot (first
offending slot in morning/afternoon/evening order). Used by the store's save and by the
settings editor before persisting.

### IF-3 — Mapping store read

```swift
final class MedicationSlotClockStore {
    func load() -> MedicationSlotClock        // non-throwing; decode-with-defaults (C1)
}
```

Main-thread composition point (the shipped storage seam is synchronous); reads are stateless
and safe to repeat. Never throws, never returns a partly-defaulted mix beyond the documented
per-slot defaults.

### IF-4 — Mapping store write (one writer)

```swift
extension MedicationSlotClockStore {
    func save(_ clock: MedicationSlotClock) -> Result<Void, StorageError>
}
```

Validates via IF-2 first (invalid input is rejected before any write), then persists; failure
leaves the stored record unchanged. Caller: the settings save action only. Idempotent.

### IF-5 — Dose line composition (pure)

```swift
enum DoseLine {
    static func compose(quantity: MedicationQuantity?, doseText: String, locale: Locale) -> String
}
```

L1 §4.6 rules; pure and deterministic. The stored `doseDescription` is exactly its output.

### IF-6 — Ack resolution (pure)

```swift
enum MedicationAckResolver {
    static func resolve(transcript: String, candidates: [MedicationAckCandidate]) -> AckResolution
}
```

`AckResolution` as frozen (`.resolved(entryId:)`, `.ambiguous(ordered:)`,
`.noMatch(orderedPending:)`, `.nothingPending`). No state, no IO, no clock beyond inputs
(`candidates` carry `scheduledAt`). Thread-safe; deterministic — same inputs, same case and
order (the FR-MSR-008 determinism scenario).

### IF-7 — Ack candidate read seam (coordinator, read-only)

```swift
struct MedicationAckCandidate {
    let entryId: UUID
    let scheduledAt: Date        // the reminder's resolved time — the ordering key
    let fired: Bool              // lastFiredAt != nil
    let slot: MedicationSlot?    // nil for legacy entries
    let voiceKeys: [String]      // MedicationVoiceVocabulary.voiceKeys(for: entry)
    let medicationName: String   // for the sanctioned copy only
}
func medicationAckCandidates() -> [MedicationAckCandidate]   // one per pending reminder, scheduledAt-sorted
```

Main thread; a pure in-memory read (the `oldestPendingReminderEntryId` precedent). No error
path: the empty case is expressed by `AckResolution.nothingPending`.

### IF-8 — Clarification walk (coordinator, main thread)

```swift
func beginAckClarification(orderedCandidates: [MedicationAckCandidate])   // speaks the first question
func ackClarificationResponse(raw: String, isYes: Bool, isNo: Bool)        // speaks the next line or resolves
func endAckClarification(_ reason: AckClarifyEndReason)
enum AckClarifyEndReason: Equatable { case rejected, denied, expired, bargedIn, resolved }
```

`begin` cancels any prior walk (a barge-in re-entry is the only way to arrive with one open).
`ackClarificationResponse` does its own name-containment over the walk's candidates
(MedicationVoiceVocabulary.canonical + voiceKeys — one vocabulary). `end` is idempotent
(a nil state is a no-op). The walk timer is armed at `begin`, cancelled by every end; expiry
calls `end(.expired)` + the honest ended line. Resolution inside `ackClarificationResponse`
proceeds through `startVoiceAckConfirmation` + the shipped prompt/notification — byte-identical
to the direct-resolved path. Timeout parameter: `AckClarificationConfig.responseWindowSeconds`
(Configuration and Timeouts) — the coordinator never reads a literal.

### IF-9 — Mapping save action (coordinator)

```swift
enum SlotClockSaveResult: Equatable {
    case invalidInput(slot: MedicationSlot)
    case storageFailed
    case saved(SlotClockRearmReport)
}
func saveMedicationSlotClock(_ clock: MedicationSlotClock) -> SlotClockSaveResult
```

Validate (IF-2) → persist (IF-4) → re-arm (IF-12); the report travels back for the settings
lines. Main thread. Failure at any step leaves the stored mapping unchanged and the re-arm
not run (persist-before-effect).

### IF-10 — Retime note (coordinator, settings surface)

```swift
@Published private(set) var medicationRetimeRefusedNotice: Bool
func dismissMedicationRetimeRefusedNotice()
```

Set by the scheduler hook (IF-20) when a slot-entry retime is refused; persisted as a one-shot
flag (the `appointmentSmsNoteDismissed` precedent — a UI preference in UserDefaults).
Dismissal is idempotent.

### IF-11 — Arming resolution feed (scheduler)

```swift
func resolvedScheduleTimes(for entry: MedicationEntry) -> Result<[DateComponents], SlotClockError>
```

Main thread (scheduler confinement). Legacy → `.success(entry.scheduleTimes)` verbatim. Slot →
the mapping's time; failure `.indeterminate(slot:)`. Consumed by `createPendingReminders`
(replacing the direct `entry.scheduleTimes` read) and by the re-arm pass. No timeout is
possible or needed (pure value + one store read).

### IF-12 — Mapping-change re-arm (scheduler)

```swift
struct SlotClockRearmReport: Equatable {
    var rearmedCount: Int                  // un-fired reminders replaced and armed
    var keptLiveCount: Int                 // fired reminders whose live escalation was kept
    var unresolvedSlots: [MedicationSlot]  // skipped: resolution failed (ordered, deduplicated)
    var persistenceFailed: Bool            // a write this pass depended on failed; nothing armed on the replaced set
}
@discardableResult
func rearmForSlotClockChange() -> SlotClockRearmReport
```

Main thread; persists the rewritten mirrors and the replaced reminders BEFORE any
`alarmScheduler` call (FR-MSR-022). Idempotent: run twice under the same mapping, the second
pass replaces nothing (resolution equality) and re-arms nothing. Caller: IF-9 and nothing else.

### IF-13 — Evidence store (NEW, fail-soft)

```swift
enum EvidenceStoreError: Error, Equatable {
    case compressionFailed     // the capped JPEG could not be produced; the write is not attempted
    case storageUnavailable    // directory creation / file write failed
    case removeFailed          // the file exists and could not be deleted
}
final class MedicationEvidenceStore {
    static let maxPhotoBytes = 200_000
    func store(image: UIImage, for logId: UUID, entryId: UUID) -> Result<String, EvidenceStoreError> // bare file name
    func load(fileName: String, entryId: UUID) -> UIImage?          // nil when missing/corrupt — never fabricated
    func delete(fileName: String, entryId: UUID) -> Result<Void, EvidenceStoreError> // absent file = success
    func deleteAll(for entryId: UUID)                                // entry-delete cascade; fail-soft
}
```

Synchronous; callers offload to a background task (C5). `store` idempotent per (entryId, logId)
— same name written in place. `delete` idempotent. Concurrency: different records' files are
independent; the caller's one-capture-at-a-time discipline serialises same-record writes.

### IF-14 — Evidence capture plumbing (coordinator)

```swift
enum EvidenceCaptureContext: Equatable {
    case pendingDose(entryId: UUID)     // fired-dose screen: hold; attach at finalize
    case recordedDose(logId: UUID)      // record surface: attach now
}
enum EvidenceCaptureOutcome: Equatable {
    case held(entryId: UUID)
    case attached(logId: UUID)
    case declinedNoContext              // defensive: no capture without a bound record context
    case failed(EvidenceStoreError)
}
func captureEvidence(image: UIImage, context: EvidenceCaptureContext) -> EvidenceCaptureOutcome
```

Main-thread entry point; the store work happens on a background task and the outcome is
delivered back on main. There is no context for which this creates a record — safety delta (c)
holds by construction (no `.create` case exists).

### IF-15 — Evidence hold / attach / discard (scheduler)

```swift
func holdPendingEvidence(fileName: String, for entryId: UUID)      // replaces (deletes the prior hold)
func discardPendingEvidence(for entryId: UUID)                     // idempotent (no hold = no-op)
func attachEvidence(fileName: String, toLog logId: UUID) -> Result<Void, SafetyError>
```

Main thread. The pending hold is in-memory only (a process kill discards it honestly — the
photo was never attached to a record). `finalizeAcknowledgement` performs the same attach
internally for the held file; the failure branch persists nothing and deletes the file (no
orphan claims). `attachEvidence` on persist failure deletes the just-stored file and returns
`.reminderPersistenceFailed` (the shipped error case).

### IF-16 — `setScheduleTimes` (scheduler, changed behavior)

```swift
@discardableResult
func setScheduleTimes(_ times: [DateComponents], entryId: UUID) -> Bool
```

Legacy entry: shipped behavior (returns true; the copy trap handled per C6). Slot entry:
returns `false`, no write, emits `medication_retime_refused`, calls IF-20's hook. Unknown
entry / write failure: false (shipped). Main thread (the coordinator's
`applyMedicationCalendarMutations` path).

### IF-17 — Significant-event calendar write (service)

```swift
func writeSignificantEvent(_ event: SignificantMedicationEvent,
                           entry: MedicationEntry?) -> CalendarShareWriteResult
```

Hops to main internally (the service's `onMain` discipline). Consent/sign-in gate first, then
audience, then enqueue; never marks outbound (D7); deterministic identity makes a repeated
write for the same logical event replace rather than duplicate. `CalendarShareWriteResult`
per C11. The actual Google write remains the shipped async `flushPending` path (its network
behavior, backoff and honesty are untouched; no new timeout is introduced — the shipped
Google SDK paths own their transport timeouts).

### IF-18 — Significant-event draft (mapper, pure)

```swift
enum CalendarShareMapper {
    static func significantEventTitle(kind: SignificantMedicationEvent.Kind,
                                      medicationName: String, locale: Locale) -> String
    static func significantEventDraft(event: SignificantMedicationEvent,
                                      medicationName: String,
                                      contacts: [FamilyContact],
                                      timeZone: TimeZone,
                                      locale: Locale) -> CalendarTwinDraft?
}
```

Pure; nil when no contact has an email (the shipped no-invitee → no-draft rule). Attendees:
de-dup case-insensitively, emergency-first, toggle-independent (the M-1-resolved audience).
`recurrence = nil`; duration = the house default; `kind = .medicationReminder`.

### IF-19 — Honest push transport

```swift
enum PushOutcome: Equatable { case delivered; case notDelivered(reason: String) }
func sendPush(payload: [String: Any], deviceToken: String) async -> PushOutcome
```

Async, no timeout parameter at this layer (the transport is the stub; the E2E plan owns real
request timeouts when it lands — recorded). `notifyAll(alertType:at:context:)` keeps its
frozen signature; the mapping to `NotificationResult(success:errorCode:channel:)` is per
contact, partial results stay partial.

### IF-20 — Scheduler wiring closures (set once at composition)

```swift
var onSignificantEvent: ((SignificantMedicationEvent, MedicationEntry?) -> Void)?   // C7.4
var onSlotEntryRetimeRefused: ((UUID) -> Void)?                                     // C7.5
```

Main thread, called synchronously within the trigger/refusal path. Unset = the behavior
degrades to no-calendar-write / no-note while the local truth is untouched (the
`onScheduleChanged` precedent's nullability rule).

### IF-21 — Save plumbing (coordinator)

```swift
enum MedicationDoseRow: Equatable { case time(DateComponents); case slot(MedicationSlot) }
struct MedicationSaveRequest: Equatable {
    var name: String
    var strength: String?                 // stored via DoseLine
    var purpose: String?
    var quantity: MedicationQuantity?
    var mealRelation: MealRelation?
    var rows: [MedicationDoseRow]         // all .time OR all .slot — mixed is rejected
    var photo: UIImage?
}
func addMedication(_ request: MedicationSaveRequest) -> String?      // nil = saved; else an error KEY
func updateMedication(id: UUID, _ request: MedicationSaveRequest) -> String?
```

Main thread. Duplicate rule m-2 (C8); mixed shapes → `settings.meds.slotRequired`-class error
key; slot rows resolve via IF-11 (failure of one resolution does not fail the save — mirror
empty, arming surfaces later). `updateMedication`: row 1 updates in place (id kept, visual
aids kept), extra rows create entries with copied visual aids; `canSave` name gate as shipped.
Empty `rows` is rejected (the save path needs at least one dose row).

### IF-22 — Editor draft value API (pure)

```swift
extension MedicationEditorDraft {
    var scheduleMode: ScheduleMode { get set }              // .times | .slots
    var slotRows: [MedicationSlot?] { get set }             // parallel to times
    mutating func applyScan(_ candidate: MedicationLabelCandidate)   // + C9 slot application in .slots mode
    mutating func applySlotPreselection(mapping: MedicationSlotClock) // exact-equality preselection
    var storedRows: [MedicationDoseRow]                     // the request's rows
    var canSaveRequest: Bool                                // name + every row shaped
}
```

Pure; tested without a view. The shipped rules stay bound (C8).

### IF-23 — Scanned schedule conversion (pure)

```swift
enum ScannedSchedule {
    static func slots(from scheduleTimes: [DateComponents]) -> [MedicationSlot]
}
```

m-3 table (C9); pure; deterministic; never consults the household mapping.

### IF-24 — Record-surface read (coordinator)

```swift
struct TakenDoseRow: Identifiable, Equatable {
    let id: UUID                 // the adherence-log id
    let entryId: UUID
    let medicationName: String
    let scheduledAt: Date
    let hasEvidence: Bool
}
func takenDosesToday() -> [TakenDoseRow]
```

Main thread; pure read built from the scheduler's adherence log (the new read seam
`func takenLogs(on day: Date) -> [MedicationAdherenceLog]` on the scheduler, same visibility
discipline as `pendingReminders`). Rows only for entries that still exist (a deleted entry's
history stays stored but is not surfaced here).

## Data Models and Persistence

### 4.1 Persisted schema changes

| Datum | Change | Store / migration |
|---|---|---|
| `MedicationEntry` | + `quantity: MedicationQuantity?`, `slot: MedicationSlot?`, `mealRelation: MealRelation?` | key `medication.entries` (shipped); custom `init(from:)` gains `decodeIfPresent` per field; `withScheduleTimes` MUST carry them (C6 trap; pinned by a migration test). No backfill of any kind (NFR-MSR-006). |
| Entry `scheduleTimes` semantics | Legacy entries: exactly as shipped. Slot entries: the RESOLVED-time mirror (D2), written by the save gate and IF-12 only | Same key; arming never reads it for slot entries (IF-11). |
| `MedicationAdherenceLog` | + `evidencePhotoFileName: String?` (bare file name) | key `medication.adherence_log`; synthesized Codable decodes missing as nil; construction sites gain the defaulted parameter only. |
| `MedicationSlotClock` | NEW record | key `medication.slot_clock`; custom decode with per-slot defaults; absent → `.default`; invalid values decode as-is and resolve `.indeterminate` (never repaired). |
| Evidence files | JPEG ≤ 200,000 B, one per record | `Application Support/MedicationEvidence/<entryId>/<logId>.jpg`, `.completeFileProtection`; deleted with the entry (cascade) or on pre-record discard. A retained log whose entry was deleted keeps a dangling name — the read fails soft and no surface claims evidence for a deleted entry. |
| `ScheduledReminder` | unchanged (`scheduledAt` = the resolved exact time) | key `medication.pending_reminders` (shipped). |
| Family-alert wire | `{v:1, alert_type, timestamp, entry_id_hash?}` | `buildPayload` (D9); entry_id_hash only for the four medication significant events. |
| Calendar one-off ledger | keys + fingerprints for significant events | the shipped `LocalGoogleEventMappingStore` (encrypted map/queue/fingerprints; keys are local bookkeeping). Keys are NOT in outboundKeys and NOT in the medication reconcile snapshot (D7). |

### 4.2 Store-key and namespace map (new entries only)

| Key / namespace | Writer | Readers |
|---|---|---|
| `medication.slot_clock` | settings save action (IF-9 → IF-4) | scheduler arming (IF-11), settings editor, `rearmForSlotClockChange` |
| `calendarShare.eventMap` etc. (existing) | the service (IF-17 enqueue → shipped commit) | the service, the sweep (sweep never sees these keys — D7) |

### 4.3 Calendar key grammar addition

```text
medicationReminder:<kind>_<entryUuid>_<yyyyMMddHHmm>     // significant-event one-off (2 components)
medicationReminder:<entryUuid>:<slot>                    // shipped schedule mirror (3 components)
```

`CalendarShareKey.parts`/`oneOffIdentifier` parse both correctly (the id component contains no
colon); the grammar distinction (2 vs 3 components) is what the reconcile snapshot uses (D7).

## Error Handling and Observability

### 5.1 Error-path catalogue (L2 resolutions on top of L1 §14)

| Interface / flow | Failure | Returned outcome | Consumer behavior |
|---|---|---|---|
| IF-1/IF-11 resolution | corrupt stored mapping value | `.indeterminate(slot:)` | no reminder armed for the entry; `medication_slot_unresolved`; settings line; never guessed |
| IF-4 mapping save | out-of-range input / store write fails | `.indeterminate(slot:)` / `StorageError` | editor shows the honest line; stored mapping unchanged; re-arm not run |
| IF-12 re-arm | either write fails | report `persistenceFailed: true` | nothing armed on the replaced set; `reminder_persistence_failed` (shipped shape); settings line |
| IF-12 re-arm | resolution fails for some slot | report `unresolvedSlots` | those entries arm nothing; settings line; event |
| IF-6 ack resolution | ambiguous / unmatched / nothing | `AckResolution` cases | sanctioned walk or the shipped `router.noPendingReminder` line; nothing recorded |
| IF-8 walk | expiry / rejection / denial / barge-in | `AckClarifyEndReason` | honest ended line; nothing recorded; reminders untouched |
| Challenge | "No" / timeout | `reEnterEscalation` (shipped) | not recorded; held evidence discarded (IF-15) |
| `finalizeAcknowledgement` | adherence-log write fails | `.reminderPersistenceFailed` (shipped) | not reported as recorded; intake-recorded alert NOT fired (it follows the write); no evidence attach |
| Evidence capture | camera unavailable | the shipped `CameraAvailability` reasons (the capture affordance never presents) | voice path is the floor; honest guidance |
| Evidence capture | store write fails | `.failed(EvidenceStoreError)` | photo not presented as evidence; honest line |
| IF-15 attach | adherence-log persist fails | `.reminderPersistenceFailed` | file deleted (no orphan); honest line |
| IF-17 calendar write | no consent / not signed in | `.skippedNotActive` | shipped honest event; nothing queued |
| IF-17 calendar write | no invitee has an email | `.skippedNoInvitees` | shipped honest event; nothing queued |
| IF-17 enqueue | local store write fails | `.failed(reason)` | per-item honest result; nothing claimed delivered |
| IF-19 push | transport unimplemented | `.notDelivered(reason: "transport_unimplemented")` | `NotificationResult(success:false, errorCode:)`; partial reported partial; no surface claims notified |
| IF-16 retime | slot entry | `false` + `medication_retime_refused` + settings note | schedule of record unchanged; legacy unaffected |

### 5.2 Observability vocabulary (classification only, PII-free)

New events (metadata: `entry_id_hash` via `IdHashing.shortHash` and categorical fields ONLY;
never a medication name, dose text, label text, photo content or utterance content):

| Event | Where | Outcome values |
|---|---|---|
| `medication_slot_clock_changed` | IF-9 saved | success / failure |
| `medication_slot_unresolved` | IF-11 failure | unresolved (slot in metadata) |
| `medication_retime_refused` | IF-16 slot entry | info (slot in metadata) — **the m-5 name** |
| `medication_ack_resolved` / `_ambiguous` / `_unmatched` | router after IF-6 | classification of the resolution case |
| `medication_ack_clarify_ended` | IF-8 end | rejected / denied / expired / bargedIn (resolved ends through the resolved path) |
| `medication_evidence_captured` / `_discarded` / `_attached` | IF-14/15 | classification only (no image, no text) |
| `family_event_alerted` (shipped, extended) | notifier | honest success/failed + error_code + channel + alert_type (name and kind only) |

Reused shipped events (unchanged names): `reminder_persistence_failed`, `calendar_share_*`
(skipped/not-active/reconciled/flush), `command_ack_*`, the `medication_photo_query` family.
The retime-refusal's family visibility is IF-10's settings note; the event itself is
operator-facing and completes m-5 together with it.

### 5.3 PII-free discipline

`LogSanitiser` discipline unchanged; the release log gate
(`ios/tools/check-release-log-safety.sh`, wired in `ios/build.sh`) must cover the new source
paths and exit 0 (NFR-MSR-002/009). Titles (medication names) are never logged, never encoded,
never placed in event metadata.

## Performance and Security Implementation Patterns

### 6.1 Firing latency (NFR-MSR-010)

No fire-time resolution step exists: `createPendingReminders` and the re-arm pass resolve once
and persist concrete `scheduledAt` instants; `nextOccurrence` (:747) and the
`UNCalendarNotificationTrigger`-based arming (`UNNotificationScheduler` :37, exact trigger
:114) are untouched. The mapping is read once per arming pass (point-in-time). The design
introduces no work between the alarm callback and `triggerReminder` (:287). Reminder re-arm
after a mapping change re-uses the shipped creation path, so the 30-second envelope is
inherited, not approximated.

### 6.2 On-device and egress

Label scanning (Vision), the ack resolver, the slot mapping and evidence capture are
device-local; nothing new leaves the device. The amended consent copy discloses the calendar
content class (M-1); the wire carries no PII (D9). Evidence files carry
`.completeFileProtection` (the encrypted-store protection class); models carry bare file
names, never paths or bytes. Camera permission is requested at point of use with the shipped
plain-language copy; capture is an alternative to the voice floor, never a requirement.

### 6.3 Memory and concurrency

Images are held only for the duration of a capture/compress operation (off the main thread);
they are never stored in models, published state or observability. The walk state is a small
value (candidates + cursor). The evidence hold is one file name per entry. The re-arm pass
touches only the in-memory entries/reminders on main.

### 6.4 Concurrency and isolation (shared resources, explicit)

| Resource | Readers (concurrent) | Writers | Isolation |
|---|---|---|---|
| `MedicationSlotClock` record | scheduler arming, settings editor, re-arm (all main) | the settings save action ONLY | main-thread confinement; validate-then-persist; no partial states observable |
| `MedicationEntry` list | coordinator views, scheduler, calendar hooks (main) | `loadSchedule`/`addMedication`/`updateMedication`/`removeMedication`/IF-12 mirror rewrite | main-thread confinement (shipped); the re-arm pass rewrites mirrors before arming |
| Pending reminders | scheduler + coordinator reads (main) | scheduler paths only (shipped + IF-12) | main-thread confinement; persist-before-arm on every arming path |
| Adherence log | `takenDosesToday`/widgets (main) | `finalizeAcknowledgement`/`recordMissedDose`/blocked branch/IF-15 attach | main-thread confinement; persist-before-cleanup |
| Evidence files | any (fail-soft reads) | capture path (serialized by the one-camera discipline), attach/discard/cascade | filesystem + caller serialization; atomic replace per file; one writer at a time via the capture gate |
| Walk state | coordinator + router (main) | coordinator walk ops only | main-thread confinement; one active walk (begin replaces); every end path listed in IF-8 (deregistration: resolved/denied/rejected/expired/bargedIn + timer cancel) |
| Pending evidence hold | scheduler (main) | IF-15 only | in-memory; deregistration paths: attach at finalize, discard on deny/re-enter, replace on re-capture, process death (honest loss) |
| Calendar ledger keys | service (main) | service enqueue/commit + shipped sweep | the shipped store discipline; significant-event keys are excluded from outbound/sweep and from the medication snapshot (D7 deregistration: none needed — write-once, family may curate in Google) |
| Retime note flag | settings view (main) | scheduler hook sets, user dismisses | main + UserDefaults; one-shot |

Deregistration paths are designed alongside every registration path: walk registration ↔ its
five end paths + timer cancel; evidence hold ↔ attach/discard/replace/death; one-off calendar
keys ↔ expiry-by-family-curation (no app-side tombstone, recorded); pending queue ↔ shipped
tombstone/flush; retime note ↔ dismissal.

## Review-l1 Resolutions — dispositions

### M-1 (major) — calendar invitee/disclosure mismatch → RESOLVED (copy amendment)

Decision: option (ii). The significant-event write path (IF-17/IF-18) uses the
family-notification audience (every contact with an email; de-dup; emergency-first;
toggle-independent — the unconditional significant set's audience, unchanged from frozen
L1 §9.3), and `calendarShare.consent.whoCanSee` is amended in BOTH locales to disclose it.
Exact amended strings (the facts are pinned; wording may be polished at implementation without
changing the disclosed facts):

- en: "Emergency contacts are always invited. Other family members are invited for the kinds
  of reminders you switch on in Notify caregivers. Safety alerts — a missed dose, a possible
  double dose, or a dose that needs attention — are always shared with every family contact
  who has an email."
- ne: "आपतकालीन सम्पर्कहरूलाई सधैं निम्ता जान्छ। अरू परिवारलाई खबर गर्नेमा खोल्नुभएका
  सम्झनाका प्रकारअनुसार निम्ता जान्छ। सुरक्षा सूचनाहरू — छुटेको औषधि, दोहोरो डोजको सम्भावना,
  वा ध्यान चाहिने औषधिको समय — इमेल भएका परिवारका सबै सदस्यहरूलाई सधैं पठाइन्छ।"

`calendarShare.consent.body` already discloses the content class ("Event titles, including
medicine names…") and is unchanged; the shipped Nepali `whoCanSee` duplication is repaired as
part of the amended string. The consent mechanism itself (per-installation acceptance
boolean) is unchanged — no re-consent machinery is introduced (recorded: no released build of
this feature exists; the amended text is what the consent screen displays, and the screen's
existing revoke/re-view behavior stands). Until implementation lands this amendment, no
surface, log line or test may claim the pre-amendment text covers the significant-event
audience (the review's hold condition). Bounds: FR-MSR-016/017 (channels, PII), NFR-MSR-004
(both locales).

### m-1 — re-arm outcome → RESOLVED

IF-12 returns `SlotClockRearmReport` (per-entry effects: rearmed/kept counts, `unresolvedSlots`,
`persistenceFailed`); IF-9 carries it to the settings leaf, which surfaces the honest failure
line(s) in both locales. The shipped `reminder_persistence_failed` event remains as the
observability half. Bounds: FR-MSR-002, FR-MSR-018, FR-MSR-022.

### m-2 — duplicate rule for slot-model saves → RESOLVED

Rule (Components C8): the shipped guard (exact name equality + effective-time intersection) is kept; a
slot row's effective time is the slot's resolved time (the D2 mirror); legacy rows contribute
their components; same-save entries participate; the entry being updated is excluded from its
own check; a corrupt mapping (empty mirror) does not flag (the unresolved line is the honest
signal). Bounds: FR-MSR-001, NFR-MSR-006.

### m-3 — hour→slot conversion table → RESOLVED

Pinned at the parser's emission level (Components C9): 8:00→morning; 12:00/13:00→afternoon;
19:00/20:00/21:00→evening; every other hour fills nothing; per-slot dedup, first-occurrence
order; never consults the household mapping. Bounds: FR-MSR-005/006.

### m-4 — multi-candidate clarification "no" → RESOLVED

Pinned (Components C4): three or more candidates — "no" ADVANCES the cursor; after the last
candidate the walk ends (nothing recorded, honest ended line). Pair form and single form keep
L1's pinned rules. Test obligation stated. Bounds: FR-MSR-008, FR-MSR-021.

### m-5 — retime refusal visibility + event → RESOLVED

Event named `medication_retime_refused` (§5.2). Family visibility: IF-10's one-shot note on
the "Medicine times" section ("a medicine's time comes from its Morning/Afternoon/Evening
setting — change it here if you changed it in the Calendar app"), dismissible, persisted; the
entry identity stays in `entry_id_hash`. The twin-revert remains the mechanism; it is no longer
unexplained where the family configures medicines. Bounds: FR-MSR-002, FR-MSR-018.

### Notes

- n-1 (fired-preference): accepted as-is; implemented by C3 without change.
- n-2 (mapping change past today's time → tomorrow's occurrence): CONFIRMED intended for the
  mapping-change surface too — a mapping change is prospective; the standard `nextOccurrence`
  rule applies (no retroactive firing, no immediate fire of a passed time). Consistent with
  the shipped retime semantics.
- n-3 (citation drift): orientation-level; this document names symbols, not line numbers, as
  contracts.
- n-4 (`addVoiceReminder` legacy shape): accepted; untouched.
- n-5 (capture announces the bound medication): realized in C5/C13 — the fired-dose
  screen titles the bound entry; the record row shows the name; the spoken capture line names
  it (`meds.evidence.spoken` "photo for %@").

## Configuration and Timeouts

No timeout or window is a literal at a call site; every parameter is named, defaulted and
composed from one source.

| Parameter | Default | Where configurable | Status |
|---|---|---|---|
| `MedicationSlotClock.default` | morning 08:00 / afternoon 13:00 / evening 19:00 | household mapping (settings save, IF-9) | NEW named defaults (OD-1) |
| `ConfirmationChallenge.challengeTimeoutSeconds` | 30 (existing, injected :28) | composition | untouched |
| `AckClarificationConfig.responseWindowSeconds` | EQUAL to the challenge timeout by construction — composed from the same injected value the scheduler's challenge receives (D4); no second constant, no literal | composition (tests inject shorter) | NEW |
| Ack window / refire count / escalation window / refire interval | 5 / 5 / 60 / 12 (entry fields) | per-entry (shipped) | untouched (FR-MSR-019) |
| `MedicationEvidenceStore.maxPhotoBytes` | 200,000 (FR-D04b precedent) | one named constant | reused precedent, not a timeout |
| Push / calendar async calls | no new timeouts | shipped paths own their transports (the E2E plan owns real push timeouts) | unchanged |

## Traceability

| Requirement | L2 sections |
|---|---|
| FR-MSR-001 slot entry model | C1, C6, C8, §4.1 (m-2) |
| FR-MSR-002 deterministic mapping, configurable | C1, IF-1/2/3/4/9/11/12, Configuration and Timeouts, Review-l1 Resolutions (m-1, m-5) |
| FR-MSR-003 quantity + composed dose line, detector unchanged | C2, IF-5, C6 (no detector input added) |
| FR-MSR-004 purpose optional, no dependency | C8 (purpose untouched), C13 |
| FR-MSR-005 scan-to-fill additive | C8, C9, IF-22/23 |
| FR-MSR-006 OCR confirm-before-binding | C8 (applyScan rules), C9 (no store write on scan) |
| FR-MSR-007 ack names medication/slot; resolution by what was said | C3, IF-6/7 |
| FR-MSR-008 conservative disambiguation, sanctioned copy | C3, C4, IF-6/8, Review-l1 Resolutions (m-4) |
| FR-MSR-009 safety sequence preserved, no path around it | C4 (resolution feeds the shipped chain), C7 (hold/attach inside finalize), IF-14/15 |
| FR-MSR-010 recorded against the schedule | C7 (one resolved Date), §4.1 |
| FR-MSR-011 refusal-first denial guard | C4 (walk denial arm), C3 (denial untouched) |
| FR-MSR-012 mic continuity around acks | unchanged seams; walk lines use the shipped speak path, pre-ack behavior untouched (AckFastLane property extended by tests only) |
| FR-MSR-013 evidence augments, never creates | C5, IF-13/14/15, §6.2, §4.1 |
| FR-MSR-014 deterministic shared-slot photo resolution | C5 (context-bound), IF-14 (no context → no bind) |
| FR-MSR-015 significant set + triggers | C7.3 (D10), C10 |
| FR-MSR-016 channels + honest delivery + consent gate | C10, C11 (IF-17/18/19), Review-l1 Resolutions (M-1) |
| FR-MSR-017 PII-free wire | C10 (D9), §5.3 |
| FR-MSR-018 honest degradation, no silent stubs | §5.1/§5.2, C10 (stub honesty), C11 (skip events), C12 (note) |
| FR-MSR-019 reminder/escalation semantics preserved | C7.1/7.2 (order preserved), C4 (chain untouched) |
| FR-MSR-020 dementia machinery preserved | C5 (PhotoVerifier not wired), C6 (photoVerification untouched), C7 (challenge/detector untouched) |
| FR-MSR-021 elderly-fit new flows | C4 (voice-reachable), C5 (capture alternative + spoken line), C8 (44/18, one idea per utterance), C13 |
| FR-MSR-022 persistence before alarm + re-arm | C7.2/7.6, IF-12/15, §6.1 |
| NFR-MSR-001 LLM independence | C3/C4 pure Swift; no new engine symbol |
| NFR-MSR-002 PII-free observability + release gate | §5.2/§5.3 |
| NFR-MSR-003 on-device processing | C5, C9, §6.2 |
| NFR-MSR-004 localisation + SpokenTime | C13, C1 (spoken-form display exception), C4 (no clock literals in copy) |
| NFR-MSR-005 accessibility | C1/C8 control shapes, C13 |
| NFR-MSR-006 migration, no loss, no inference | C6 (decode + trap), §4.1, C8 (conversion is family-directed) |
| NFR-MSR-007 Devanagari pin | C3 (Character-cluster containment), Overview (Invariants) |
| NFR-MSR-008 test coverage + confidence | named test obligations (m-4 walk in C4), C6 (trap), C10 (stub flip), C9 (table) |
| NFR-MSR-009 compliance/release gates | §5.3 (gate coverage) |
| NFR-MSR-010 firing latency | §6.1 |

Every locked requirement is bound at L2 without new scope.

## Risks and Residual Opens

1. **Multi-row save = N entries (D1).** Preserves twice-daily scheduling and L1's conversion
   wording, but the family list shows one row per dose. Review-l2 should confirm a row is a
   dose is an entry; the alternative (a multi-slot entry) contradicts the frozen singular
   `slot` field.
2. **Significant-event one-offs in the shared calendar.** Keyed, gated and honest; the family
   may curate (delete) them in Google and the app will not re-assert (write-once, no
   tombstone) — recorded. A future inbound reconcile could make this richer; out of scope.
3. **`withScheduleTimes` trap.** The highest-risk silent defect; the migration test is the
   named mitigation (C6) and must ride into plan-tasks as its own unit obligation.
4. **Honest push stub flips existing tests.** Expected (review-l1 risk 4); the notifier suite
   and every test that asserted stub success must flip with the honest outcome.
5. **Walk-answer interception ordering.** The walk block must precede the generic yes/no arms
   while never swallowing a denial (the fall-through relies on `isAwaitingConfirmation`
   flipping false when the walk ends). A router test pins: "होइन" inside a walk does not reach
   the challenge handler; an acknowledgement inside a walk restarts resolution.
6. **Evidence hold across process death.** In-memory by design; a photo held but not attached
   is lost honestly (never claimed attached). Recorded, accepted.
7. **Copy finalisation.** The M-1 strings and the walk/evidence lines need the owner's voice
   pass at implementation (facts pinned here); catalog coverage test gates both locales.
8. **Residual opens for plan-tasks/implement:** wave decomposition; exact copy wording;
   test-file names; the `v: 1` payload key's inventory note for the E2E plan; whether
   `MedicationSchedulerProtocol` gains the new seams for test doubles (currently the concrete
   scheduler; the protocol stays the small shipped test seam unless a suite needs it).
   Nothing above reopens an L1 contract.
