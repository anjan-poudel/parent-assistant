# Design L1 — Medication Schedules and Reminders

| | |
|---|---|
| Task | `design-l1` (agent: `system-architect`), contract `architecture_l1` |
| Feature | `medication-schedules-reminders`, branch `feat/medication-schedules-reminders` |
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-medication-schedules-reminders` |
| Base | `61e6bc32` (scaffold base master `261aa862`; every seam below re-verified in this worktree) |
| Date | 2026-10-15 |
| Inputs | project `constitution.md`; `specs/medication-schedules-reminders/constitution.md` (feature supplement: five binding contracts, safety delta (a)–(d), Feature Constraints 1–10, Integration Surfaces, Open Decisions); `specs/define-requirements.md` + `specs/define-requirements/` (22 FR-MSR, 10 NFR-MSR, locked; `define-requirements.lock.yaml`); read-only: `requirements.md` (FR-026–FR-030, NFR-027), `requirements-dementia-supplement.md` (FR-D01–FR-D04e), `docs/medication-scheduler-implementation-plan.md`, `docs/family-notifier-e2e-implementation-plan.md`, `docs/2026-09-16-calendar-family-sharing-implementation-plan.md`; workflow `specs/medication-schedules-reminders/workflow.yaml` |
| OD status | OD-1…OD-3 settled as requirements (not reopened). **OD-4…OD-8 resolved in this document at L1** (§3, §6, §7, §8, §9, §11); the component-level internals each resolution leaves open are carried to `design-l2` with explicit boundaries (§24) |

Line numbers cited below are orientation anchors into base `61e6bc32`, not contracts; symbol
names are the contracts. Every seam claim was re-checked against the worktree code before being
relied on. This document designs; it does not implement (no production code, no migrations, no
seed content). Every interface below specifies its error paths (agent principle: explicit error
return types), its isolation (agent principle: concurrency explicit), and treats windows and
timeouts as configuration (§15) — no timeout literal is introduced. Scope is enforced by the
requirements: every component named here traces to an FR-MSR/NFR-MSR id in §22, and nothing
else is added.

---

## Overview

### 1. Scope and method

This document fixes the architecture for the owner's seven-point brief — the medication entry
model becomes quantity + time-of-day slot + before/after meal; each medication carries a purpose;
scan-to-fill works beside manual entry; the elder acknowledges intake in natural voice naming
medication and slot; a photo of the medication serves as intake evidence; caregivers are always
notified of significant events; and the whole is fit for forgetful elderly users — as bound by
the feature constitution's five contracts and the 22+10 locked requirements. It translates the
generic architect template to this codebase's idioms:

- **"REST API surface" → the in-process seam surface.** This is a single-process native iOS app.
  The interfaces that matter are the Swift seams another module may call — the scheduler's
  resolution/arming feed, the pure slot-clock resolver, the pure ack resolver, the evidence
  store, the notifier payload builder, the calendar-share write path — each with an explicit
  outcome/error type (§21). There is no server of ours and no REST API.
- **"OpenAPI" → the fixed schemas of those seams**: the `MedicationEntry` persisted schema
  (§20), the family-alert wire envelope (§9.4), the household slot-clock record (§4.2), and the
  significant-event calendar entry shape (§9.3) — each a named, versioned shape.
- **"Data model" → persisted schemas**: the extended `MedicationEntry`, the extended
  `MedicationAdherenceLog`, the new household slot-clock record, the new evidence file store
  (§20). No database; `EncryptedLocalStorage` keys are the store (§20).
- **"Infrastructure topology" → the process/component topology**: one iOS app process; the
  platform alarm scheduler (UNUserNotificationCenter) as the firing surface; on-device Vision OCR
  and camera capture; the caregiver app push path (transport stubbed — surfaced honestly); the
  shared family Google Calendar (existing OAuth session, consent-gated). No container, no
  Docker, no server of ours (§21.4).
- **"Auth strategy" → the trust & consent model**: no accounts and no auth tokens are
  introduced. The relevant authorization surfaces are (a) the existing family-calendar share
  consent (reused, not re-invented), (b) the existing per-contact caregiver-notify settings
  (opt-in kept for the daily first-fire only), and (c) the existing cloud voice-stack consent,
  which this feature neither widens nor touches — label and photo processing stay on-device
  (§12, §21.5).

### 2. Design summary and invariant ledger

The revamp relocates two things — where an entry's clock time comes from, and how an
acknowledgement finds its medication — and extends three surfaces — scan-to-fill, photo
evidence, caregiver notification — while every safety-shaped component between them keeps its
contract. The load-bearing invariants that must not move:

| Invariant | Contract | Enforcement in this design |
|---|---|---|
| Acknowledgement safety sequence | acknowledgement → FR-D01 challenge → FR-D03 double-dose → record, order never bypassed | §7.4: resolution only replaces *which* entry the shipped sequence runs for; `acknowledgeWithConfirmation` (:241) and its first-call-issues-challenge behaviour are untouched; no new recording path exists |
| Persistence before alarm; re-arm on relaunch | FR-029 / NFR-027, root constitution | §10: a reminder persists its resolved exact `scheduledAt` before arming (`createPendingReminders` :707 persists then arms :733–744); restore/re-arm paths unchanged |
| Deterministic, total slot→clock mapping | safety delta (b), FR-MSR-002 | §4.3: pure exhaustive function over a three-value slot enum; failure is typed and fail-closed — no determinate time ⇒ no armed reminder, error surfaced |
| OCR never auto-binds | safety delta (a), FR-MSR-006 | §6: candidates only; the sole bind remains the family's save through `MedicationEditorDraft` → `AppCoordinator.addMedication` (:11634); every new scan entry point routes through the same gate |
| Photo never creates a record | safety delta (c), FR-MSR-013 | §8: evidence attaches only inside `finalizeAcknowledgement` (:453) or to an already-recorded log; no path from capture to record |
| PII-free wire | safety delta (d), FR-MSR-017 | §9.4: envelope `{v, alert_type, timestamp, entry_id_hash}` — no names, doses, or titles; `FamilyAlertContext` titles stay in memory only |
| Existing escalation semantics | FR-MSR-019, root FR-026–FR-028 | §10: `EscalationEngine` (:29) untouched — it still derives ack deadline, re-fire schedule, escalation deadline and missed verdict from the one resolved `scheduledTime`; a future dose stays future on restore (:191–198) |
| Dementia machinery | FR-MSR-020 | §8.5, §7.4: `ConfirmationChallenge`, `DoubleDoseDetector`, `PhotoVerifier` preserved; extension only, removal forbidden |
| LLM independence | NFR-MSR-001 | §7, §13: the resolver is pure Swift string/enum logic in the medication module; the ack path runs on the keyword safety net ahead of the LLM; the scheduler compilation unit gains no LLM symbol |
| Migration without loss | NFR-MSR-006 | §11: optional fields with custom-decoder defaults (the `init(from:)` :114 precedent); legacy `scheduleTimes` readable and representable; no automatic backfill |
| Devanagari grapheme behaviour | NFR-MSR-007 | §16.3: pinned behaviour untouched; new vocabulary reuses the shipped substring conventions without "fixing" them |
| Mic continuity around acks | FR-MSR-012, [ACK-MIC-CONTINUITY] | §7.5: new ack shapes ride the existing speech/fast-lane seams; no new session teardown between acknowledgement and listening |

### 3. Decision register — OD-4 … OD-8 resolved at L1

| OD | Question | L1 decision (this document) | Carried to design-l2 (boundaries in §24) | Section |
|---|---|---|---|---|
| OD-1 | Slot defaults / configurability | Settled upstream (FR-MSR-002): 08:00 / 13:00 / 19:00, family-configurable. The control shape is designed here (§4.2, §16.1) | — | 4.2 |
| OD-2 | Quantity representation | Settled upstream (FR-MSR-003): amount + unit composed into `doseDescription`; detector unchanged. Composition rule designed here (§4.6) | — | 4.6 |
| OD-3 | Significant set / "always" | Settled upstream (FR-MSR-015/016/017): missed + double-dose + intake-recorded + escalation-started, unconditional; first-fire stays opt-in; transport scope honest | — | 9 |
| OD-4 | Scan-to-fill confirm step / partial fill | **Resolved**: the human-confirm step IS the family's review-and-save through the draft (nothing writes a store on scan); extraction surface stays the conservative parser's; partial-fill rules = blank-only text, label schedule wins, empty read changes nothing; scanned schedule items map to slot selections through a fixed documented table (§6) | Exact scan UI affordance placement; spoken partial-read copy; parser table extensions if any (must keep "refuses to guess") | 6 |
| OD-5 | Legacy entries / backfill | **Resolved**: no automatic slot inference, ever; legacy entries render and behave exactly as today; the only time→slot conversion is family-directed inside an explicit edit, with exact-equality preselection only; new-entry surface is slot-only; `.weekly`/`.custom` remain decodable and out of the slot model (§11) | Editor presentation details of the switch; list-row rendering layout | 11 |
| OD-6 | Ack-with-slot resolution mechanics | **Resolved**: pure deterministic resolver over the pending set by what was said (name keys via `MedicationVoiceVocabulary`, then slot; meal is context only); ambiguity walks the sanctioned "did you mean X / X or Y" forms in a fixed order; simple acks resolve only when unambiguous; sequence order preserved (§7) | Probe-state representation, exact slot/meal word lists, exact copy strings, per-event observability field names | 7 |
| OD-7 | Calendar channel mechanism | **Resolved**: the existing consent-gated schedule mirror stays as is, and the three at-risk significant events (missed, possible double dose, escalation started) additionally surface as one-off entries on the same shared family calendar through the same service and consent gate; intake-recorded does not write calendar entries; push wire stays PII-free (§9.3) | One-off entry bookkeeping/lifecycle, entry title copy, invitee-derivation helper shape | 9.3 |
| OD-8 | Photo-evidence mechanism / recipient | **Resolved**: on-device-only evidence variant; capture context (the reminder/record surface the capture starts from) determines the entry deterministically — no image classification anywhere; the record always flows through the acknowledgement chain; the caregiver is the judge, the app only captures/attaches/retains and reports state honestly; the dementia mechanism is untouched (§8) | Evidence store internals, capture-surface placement, copy strings, compression implementation (reuse the FR-D04b cap) | 8 |

The five resolutions are design-level choices inside the contracts the requirements fix — no
owner-level decision is taken here. Each L2 hand-off in §24 names what design-l2 must decide and
what it may not violate.

---

## Architecture

### 4. Entry model and the slot-to-clock mapping (FR-MSR-001, FR-MSR-002, FR-MSR-003)

#### 4.1 The entry model

`MedicationEntry` (:26) grows three optional fields; `scheduleTimes` stays exactly as shipped:

```swift
enum MedicationSlot: String, Codable, CaseIterable { case morning, afternoon, evening }
enum MealRelation: String, Codable { case beforeMeal, afterMeal }
struct MedicationQuantity: Codable, Equatable {
    let amount: Int    // positive integer, validated at the editor
    let unit: String   // MedicationDoseUnit raw value, or the family's free text
}
enum MedicationDoseUnit: String, Codable, CaseIterable {
    case tablet, capsule, milliliter, teaspoon, drop, puff, sachet
}
```

`MedicationEntry` additions (all optional, all `decodeIfPresent` with defaults, CodingKeys
extended — the shipped migration shape at :114–131):
`quantity: MedicationQuantity?`, `slot: MedicationSlot?`, `mealRelation: MealRelation?`.

The family-facing editor (`MedicationEditorDraft` :19, `SettingsView` `addForm` :4640) gains
three controls and keeps every shipped draft rule:

- **Quantity**: a positive-integer amount control plus a unit picker (the seven units above,
  plus a custom free-text option modelled on the purpose chips — a unit string that matches no
  enum case is stored verbatim, exactly the shipped `purpose` chip-or-free-text precedent).
- **Slot**: three large slot options (morning / afternoon / evening), each rendered with the
  household-mapped clock time as read-only context (e.g. "Morning · 8:00 am"). The family never
  types or computes a clock time.
- **Meal relation**: before meal / after meal, attached to the slot as context.

The draft rules bound by constitution Entry-Model property 7 are unchanged: text pre-fill into
blank fields only, the label's stated schedule wins, an empty read changes nothing,
`storedTimes` stays `[.hour, .minute]` (:143), and `canSave` still requires a name (:149). The
save gate produces a slot-model entry; a legacy entry keeps loading and behaving (§11).

The voice `set_reminder` path (`addVoiceReminder` :12939) keeps constructing the legacy shape
(raw `scheduleTimes`, no slot): the elder's one-off voice reminder is not the family-facing
entry surface, and the model keeps that shape first-class. Recorded, not silently changed.

#### 4.2 The household mapping and its store

NEW persisted record `MedicationSlotClock` — the household's slot→clock mapping, one per
installation/profile, stored through the existing `EncryptedLocalStorage` seam under a new key
(the scheduler's own store keys :60–62 are the precedent):

```swift
struct TimeOfDay: Codable, Equatable { let hour: Int; let minute: Int }

struct MedicationSlotClock: Codable, Equatable {
    let morning: TimeOfDay     // default 08:00
    let afternoon: TimeOfDay   // default 13:00
    let evening: TimeOfDay     // default 19:00

    static let `default` = ... // 08:00 / 13:00 / 19:00 (OD-1)
}
enum SlotClockError: Error, Equatable { case indeterminate(slot: MedicationSlot) }
```

- **Custom decode, defaults not failures** (the house migration rule): a record with a missing
  key decodes that slot as the default; the record's absence decodes as `.default`. Never lose a
  household's schedule to a missing key.
- **Present-but-invalid values are indeterminate, not repaired**: a stored hour/minute outside
  0–23 / 0–59 is a corrupt value and must NOT be silently clamped into a guessed time — that
  slot resolves as `.indeterminate` and the failure path below applies. Determinism means "the
  same inputs always produce the same times", never "anything produces some time".
- **One writer**: the medication settings surface (settings leaf, §16.1). Writes validate
  ranges before persisting; a failed write surfaces and does not take effect (§14).
- **Control shape (design-l1 owns this per OD-1)**: a "Medicine times" section in the medication
  settings leaf — three rows (Morning / Afternoon / Evening), each with a large tappable
  time control at 44pt+/18pt+, plus a "reset to default times" action. Changes persist through
  the store and immediately trigger the guarded re-arm (§4.5).

The meal relation is context, not a clock (OD-1): it renders in spoken copy and on the dose
screen and never produces a second firing.

#### 4.3 Determinism and totality

The mapping is a pure function of `(entry.slot, householdMapping)`:

- **Total over the creatable entry space.** The creatable space is {morning, afternoon,
  evening} — an exhaustive three-case enum resolved by a function with no default case — so
  every creatable entry resolves under every valid household mapping. There is no input for
  which the function "has no answer" by omission.
- **The one failure is typed and fail-closed.** `.indeterminate(slot:)` arises only from a
  corrupt stored mapping value (§4.2). On failure: **no reminder is armed for the affected
  entries**, an observability event (`medication_slot_unresolved`, entry_id_hash only) is
  emitted, and the condition surfaces on the settings surface as an error. No implicit or
  guessed clock time is ever used — this is FR-MSR-002's failure scenario by construction.
- **No hidden state.** The resolver reads only the entry's slot and the persisted mapping;
  identical inputs always produce identical `TimeOfDay` outputs. Nothing is cached that could
  drift (the mapping is read at arming time through the injected store).
- **Exact-time scheduling preserved.** Resolution produces hour/minute `DateComponents`, the
  same shape `createPendingReminders` (:707) and `nextOccurrence` (:747) already consume;
  `UNCalendarNotificationTrigger`-based exact-time arming (`UNNotificationScheduler` :37) is
  untouched, so the resolved time is the schedule of record and NFR-MSR-010's 30-second firing
  envelope is unaffected (no fire-time resolution step is introduced).

#### 4.4 The resolved-time feed into arming

`MedicationScheduler` gains one seam:

```swift
func resolvedScheduleTimes(for entry: MedicationEntry) -> Result<[DateComponents], SlotClockError>
```

- `entry.slot == nil` (legacy shape) → `.success(entry.scheduleTimes)` verbatim — bit-for-bit
  today's behaviour.
- `entry.slot != nil` → the mapping's `TimeOfDay` for that slot, as `[DateComponents]` with
  `.hour`/`.minute` only (the model's local-time convention).

`createPendingReminders` (:707) consumes this seam in place of reading `entry.scheduleTimes`
directly. On `.failure`, the entry is skipped with the surfaced error (§4.3); on `.success` the
existing pipeline runs byte-identically: reminder constructed with the resolved `scheduledAt`,
escalation deadline derived from it, engines made per reminder, `persistReminders()` before the
first `alarmScheduler.scheduleReminder` call. Everything downstream — `EscalationEngine`
(:29), `PlatformAlarmScheduler` (:5), `DoubleDoseDetector` (:21), the adherence log — keeps
reading one concrete `Date` and is untouched.

Because slots map to exactly one time and there is no second firing for the meal relation, a
slot entry produces one pending reminder per day per slot — the same cardinality the shipped
editor produced for one `DatePicker` row, so `activeReminderId(for:)` (:773) and the per-reminder
engine keying are unchanged.

#### 4.5 Mapping changes and the guarded re-arm

When the family saves a changed mapping, reminders must re-resolve deterministically (FR-MSR-002
scenario: re-armed ⇒ 07:30). The shipped `loadSchedule` (:180) cannot be reused for this:
it clears `pendingRemindersList` and `engines` wholesale, which would reset a live escalation
(refire counts, deadlines) and could re-create an already-fired dose as "next occurrence"
(tomorrow). The design therefore requires a dedicated pass:

**`rearmForSlotClockChange()` (new scheduler API), semantics:**
1. For each entry, re-resolve times under the new mapping (§4.4).
2. Pending reminders with `lastFiredAt != nil` (the dose rang; escalation has begun) keep their
   persisted `scheduledAt`, engine and state — a mapping change never moves a live escalation.
3. Un-fired pending reminders whose resolution changed are replaced, using the standard creation
   rules (`nextOccurrence` from now), engines re-made, persistence before arming.
4. Entries whose resolution fails arm nothing and surface the error (§4.3).
5. The pass runs through `persistReminders()` before any `alarmScheduler` call — persistence
   before alarm holds on this path too (FR-MSR-022).

Callers: the mapping-save action (§4.2) and nothing else. App launch keeps the shipped
`scheduleAll()` → `restoreState`/`rearmAllPendingReminders` path, which restores persisted
resolved times verbatim.

#### 4.6 Quantity and the composed dose line (FR-MSR-003, OD-2)

`doseDescription` remains the one rendered dose line — the field the fired-dose screen, the
briefing and the editor's scanned strength already consume (:30; `MedicationEditorDraft`
`storedStrength` :132). Composition happens at save through one pure function:

```swift
enum DoseLine {
    static func compose(quantity: MedicationQuantity?, doseText: String, locale: Locale) -> String
}
```

Rules (single, documented, deterministic):
1. `quantity` set, dose text blank → `"<amount> <localized unit>"` (e.g. "1 tablet";
   unit label resolved through the catalog when `unit` matches a `MedicationDoseUnit`, the
   family's words verbatim otherwise).
2. `quantity` set, dose text non-blank (e.g. a scanned strength "500 mg") → the composed line
   gains the text after a fixed separator (`"1 tablet, 500 mg"`); exact separator and copy at
   implementation. Nothing the family saw in the form is dropped.
3. `quantity` nil → the dose text verbatim (today's path; "half tablet" and every legacy entry).
4. Both empty → empty string (today's behaviour for a dose-less entry).

Downstream consumers change not at all — they keep reading `doseDescription`. The editor keeps
its strength/free-text input (the scan target per FR-MSR-005) and adds the structured controls;
the two together follow the purpose-draft shape (structured selection pre-fills, typed text
overrides the structured rendering only through rule 2/3 in this subsection — the exact interaction is a
component detail for design-l2, §24).

`DoubleDoseDetector.check(medicationEntryId:windowHours:adherenceLog:now:)` (:21) is untouched:
entry-scoped and window-scoped, no dose or quantity input. Partial-vs-full dose detection stays
out of scope (FR-MSR-003) — a recorded dose blocks a second attempt for the window regardless of
quantity, exactly as shipped.

### 5. Purpose at entry (FR-MSR-004)

Purpose builds on the shipped machinery — `MedicationEntry.purpose` (:50), the ten chips and
`MedicationPurposeDraft`, `MedicationVoiceVocabulary.voiceKeys(for:)` (:114),
`MedicationPurposeLookupService` — and adds nothing new. The one design-level question the
requirement leaves open is decided here:

**Purpose remains OPTIONAL at entry.** Rationale: no behaviour may depend on purpose text being
present (FR-MSR-004); pre-purpose payloads keep loading (they do, via the shipped
`decodeIfPresent` :129); requiring it would add friction to a hurried caregiver editing flow and
risks junk values that then enter the voice vocabulary. The chip step, the lookup and the
pre-fill-into-free-text rule (`applyPurposeLookup` :103) are unchanged. Purpose is not scannable
from a label (FR-MSR-005) — the lookup stays the separate, gated suggestion path.

### 6. Scan-to-fill (FR-MSR-005, FR-MSR-006, OD-4)

**Resolution of OD-4 — the confirm step is fixed as the family's review-and-save, and nothing
else.**

- **Additive path.** The scan button, `MedicationLabelScanner` (`start`/`finish`, spoken
  outcomes, metadata-free `medication_label_scan` events) and `MedicationEditorDraft.applyScan`
  (:69) remain the scanner surface. A household that never scans keeps today's exact manual
  path.
- **Bounded extraction surface (unchanged).** Name, strength, schedule (time words; the
  `1-0-1` day pattern; count-based defaults), frequency guess — all from the conservative
  `MedicationLabelParser` (:86), which refuses to guess. Purpose is not scannable.
- **Human confirmation before binding (safety delta (a)).** Nothing writes a store on scan: the
  parser's output is a `MedicationLabelCandidate` (:41), `applyScan` mutates only the in-memory
  draft, and the entry is created solely by the family's save
  (`SettingsView` :4673 → `AppCoordinator.addMedication` :11634 → `loadSchedule`). **Any new scan
  entry point must route through the same draft-and-save gate; a scan path that writes an entry
  or arms a reminder directly is a defect of this design, not a feature.**
- **Partial-fill rules (unchanged).** Text fills blank fields only; the label's stated schedule
  replaces the form's (including family-set values — the rule and its rationale stand); an empty
  read changes nothing and is spoken ("could not read it"); the photo is never discarded
  (`.scanned` carries the image even when text did not come).
- **Scanned schedule → slot selections (new, bounded).** With the entry surface now slot-based,
  the parser's schedule output must land in slot selections. The parser's schedule values are
  already slot-shaped conventions — time words (बिहान / सकाळ / morning → 8:00; दिउँसो /
  afternoon → 13:00; बेलुका / evening → 19:00; other table entries) and the `1-0-1` day-pattern
  slots (morning / midday / night), see `timeWordHours` :203 and `slotHours` :213. A new pure
  conversion (`ScannedSchedule.slots(from:)`) maps each parsed item to a slot through a fixed,
  documented table (morning → morning; midday/noon/afternoon → afternoon; evening/night →
  evening), applied as **candidate selections the family sees and can change before Save**,
  under the existing "the label's stated schedule wins" rule. The conversion uses the parser's
  own convention hours, never the household mapping (the label says "morning", not "07:30");
  an item with no slot counterpart (possible only if the parser's tables change) fills nothing —
  if no item converts, the schedule is left unchanged, mirroring "a candidate that stated no
  schedule changes nothing". Meal relation is not scannable and stays family-set. The conversion
  is deterministic and testable; it does not extend the parser's extraction surface.
- **Outcomes stay observable and metadata-free** (no image, no recognized text).

### 7. Voice acknowledgement with slot (FR-MSR-007 … FR-MSR-012, OD-6)

#### 7.1 Gate order and vocabulary

The shipped gate order is preserved exactly, and the new utterance shapes slot into it:

1. Emergency phrases (`routeSafetyNet` :2478 first check) — untouched.
2. **Refusal-first denial guard** (`medicationDenialPhrases` :2425, checked everywhere the ack
   list is used, :2464, :2491) — untouched and still first: a denial never falls through to an
   acknowledgement (FR-MSR-011), including mixed denial-with-ack-token utterances, clarification
   answers and challenge answers.
3. **Acknowledgement gate** — `isExplicitMedicationAcknowledgement` (:2460) unchanged as the
   entry condition into the ack flow. The owner's utterance shape ("I have taken X for morning
   before meal" / "औषधि खाएँ … बिहान") already matches via the shipped phrase/token lists
   ("taken", "औषधि खाएँ"…); the lists may only be extended **additively** (a phrase list
   addition), never reordered around the denial guard.
4. Resolution and the safety sequence (§7.2–7.4) — replacing only the `oldestPendingReminderEntryId()`
   (:12929) selection step inside `handleMedicationAcknowledgement` (:5381).
5. Correction rescue (`attemptCorrectionRescue` :2519) — untouchable order: it runs on the
   unrecognised path only, after the ack vocabulary; a medication acknowledgement is never
   captured by it, and a general correction utterance is never captured as an ack (FR-MSR-008
   coexistence scenario). Within an open confirmation/clarification window the existing
   "follow-up block asks `isExplicitMedicationAcknowledgement` first" rule (:1191) continues to
   hold.

#### 7.2 The candidate seam and the resolver

`AppCoordinator` exposes one read seam (the `oldestPendingReminderEntryId` precedent, :12929):

```swift
struct MedicationAckCandidate {
    let entryId: UUID
    let scheduledAt: Date          // the reminder's resolved time — the ordering key
    let fired: Bool                // lastFiredAt != nil (the reminder has rung)
    let slot: MedicationSlot?      // nil for legacy-shape entries
    let voiceKeys: [String]        // MedicationVoiceVocabulary.voiceKeys(for: entry), canonical
    let medicationName: String     // for the sanctioned copy only
}
func medicationAckCandidates() -> [MedicationAckCandidate]  // one per pending reminder
```

NEW pure type `MedicationAckResolver` in the medication module (no LLM dependency — NFR-MSR-001;
deterministic; no clock reads beyond the inputs):

```swift
enum AckResolution: Equatable {
    case resolved(entryId: UUID)
    case ambiguous(ordered: [UUID])       // ≥2 candidates; walk order fixed here
    case noMatch(orderedPending: [UUID])  // something was said that matches no pending entry
    case nothingPending
}
enum MedicationAckResolver {
    static func resolve(transcript: String, candidates: [MedicationAckCandidate]) -> AckResolution
}
```

**Resolution algorithm (deterministic, conservative, by what was said):**

1. **Parse the utterance**: name-key matches = candidate entries whose canonical `voiceKeys`
   appear in the canonical transcript (substring containment — the shipped vocabulary convention
   `MedicationVoiceVocabulary.canonical` :104 and the parser's Devanagari-fusion convention);
   optional slot word from a closed two-language list (morning/afternoon/evening in the elder's
   languages); optional meal word (before/after meal). The meal relation is **context only — it
   never filters and never discriminates** (OD-1: meal is not a clock; the named medication and
   slot are the strong signals).
2. **Name first.** If ≥1 name-key match:
   - if a slot was named and any name-match has that slot → keep the name-matches carrying that
     slot; if a slot was named and none of the name-matches carries it → this is a conflict
     (one of the two statements is wrong) → **ambiguous** walk over the name-matches;
   - exactly one → `resolved`; several → `ambiguous`.
   Resolution is by what the elder said — never by firing order or `scheduledAt` preference — so
   naming a medication resolves to that medication's entry even when another medication's
   reminder rang first (FR-MSR-007's stated motivation).
3. **Then slot.** No name match, slot named: candidates = pending entries whose slot equals the
   named slot. 0 → `noMatch` (honest: nothing pending at that slot — never a fall-through to
   other slots); 1 → `resolved`; ≥2 → `ambiguous`. Legacy entries (slot nil) never match a slot
   word — no inference over their raw times.
4. **Then a simple acknowledgement.** No name, no slot: candidates = the **fired** pending
   reminders if any (`fired == true` — "taken" with no further information refers to what rang),
   else all pending (early acknowledgement of a not-yet-rung reminder — the shipped
   single-pending behaviour). 1 → `resolved`; ≥2 → `ambiguous`; 0 → `nothingPending`.
5. `noMatch` carries the full ordered pending set so the router can run the sanctioned fallback
   question below.

**Behaviour change recorded (conservative, per FR-MSR-007):** today a simple run of "taken" with
several pending reminders silently picks the oldest. Under this design, several pending
reminders make a simple acknowledgement **ambiguous** (clarification) unless exactly one has
rung. The requirement's own failure scenario demands this ("no medication is chosen by firing
order"); the single-pending case (the scenario where today's behaviour was correct) is
byte-identical.

#### 7.3 The clarification walk — sanctioned copy only

`AckResolution.ambiguous` and `noMatch` enter the clarification walk: coordinator state
`pendingAckClarification` (the `pendingNavigationWalk` precedent — a small ordered candidate
list plus a cursor), reflected in `isAwaitingConfirmation` (:12916) so the router's yes/no
parsing stays in force while it is open. The walk:

- **Order**: fixed at entry — by `scheduledAt`, then canonical name, then id. Same input ⇒ same
  order ⇒ same question (FR-MSR-008 determinism scenario).
- **Two candidates**: first question uses the pair form — "did you mean X or Y?" (the sanctioned
  copy). A response naming one of the pair (name containment) resolves to it; a plain "yes"
  stays ambiguous and the walk falls to the single-candidate form below at cursor 0; a plain
  "no" ends the walk with nothing recorded.
- **One candidate (and `noMatch` with a single pending)**: "did you mean X?" — the sanctioned
  single form. "Yes" resolves to X and proceeds to the safety sequence; "no" ends with nothing
  recorded.
- **Three or more candidates**: single-candidate form from cursor 0 onward, one candidate per
  question — **never a numbered list, never a leading question** (owner copy rule; the forms
  permitted are exactly "did you mean X" and "X or Y").
- **Barge-in**: a response that is itself an explicit acknowledgement re-enters resolution from
  scratch (the existing precedence: an ack is never consumed as a yes/no answer, :1191).
- **Expiry**: the walk is open for a configurable response window (§15), default equal to the
  existing challenge timeout (30 s, `ConfirmationChallenge.challengeTimeoutSeconds` :21);
  on expiry the walk ends, nothing is recorded, and the reminders stay pending untouched —
  escalation continues on its own clock.
- **Outcome**: every ending other than a resolved "yes" records nothing and says so honestly.
  The copy strings are L10n keys in both languages; the sanctioned forms are the only shapes.

The same conservative discipline governs the photo path (§8.3) — one clarification mechanism,
not two.

#### 7.4 The preserved safety sequence and recording (FR-MSR-009, FR-MSR-010)

On `.resolved(entryId)`, the router calls the shipped flow for that entry:
`coordinator.startVoiceAckConfirmation(for: entryId)` (:12657) → challenge prompt spoken →
next-transcript handling (`handleMedicationConfirmation` :12647) → `acknowledgeWithConfirmation`
(:241) → `ConfirmationChallenge.userResponds` → `.recordTaken` → `checkDoubleDoseAndRecord`
(:499, `DoubleDoseDetector`) → `finalizeAcknowledgement` (:453). Nothing in this chain is
modified — resolution only decides **which** entry the chain runs for. The first-call-issues-
challenge behaviour (:254) is untouched, so no path — resolved directly, clarified, or
photo-initiated — can record without the challenge; a "No" or a timeout re-enters escalation
with FR-D02 semantics (:272, `reEnterEscalation` :589), locale-aware prompts preserved.

**Recording (FR-MSR-010):** unchanged shape — `MedicationAdherenceLog` carrying the reminder's
`scheduledAt` (the slot-mapped exact time) and `acknowledgedAt` (:460–471), persisted before
runtime cleanup (:476–489). Only a fully confirmed dose records as taken.

#### 7.5 Mic continuity, refusal-first, correction coexistence (FR-MSR-011, FR-MSR-012)

- **Mic continuity**: the new ack-with-slot and clarification utterances enter the same turn
  pipeline and the same speech seams as today's acks; the [ACK-MIC-CONTINUITY] property
  (`AckFastLane.swift` header; pre-acks play outside the listening seam, `speakPreAck` :5529)
  is preserved — no new synthesis-and-teardown step is introduced between the acknowledgement
  and listening, and the fast-lane suite (`AckFastLaneTests`) extends to the new shapes. The
  challenge and clarification prompts are spoken through the same `speak` seam that already
  speaks the shipped challenge prompt (confirmation challenges deliberately never use the
  pre-ack, :5512).
- **Refusal-first**: §7.1 step 2.
- **Correction coexistence**: §7.1 step 5.

#### 7.6 Honest outcomes summary

| Situation | Outcome | Recorded? |
|---|---|---|
| Name (+ slot) matches one entry | resolved → challenge → detector → record | yes, on confirmation |
| Name matches several / pair form | sanctioned clarification walk; nothing until a resolution | no |
| Simple ack, exactly one fired (or only one pending) | resolved (shipped single-pending behaviour) | yes, on confirmation |
| Simple ack, several pending | clarification walk over the sanctioned forms | no |
| Slot named, nothing pending there | honest "nothing to acknowledge" line | no |
| Name matches nothing, ≥1 pending | clarification walk over the pending set | no |
| Nothing pending at all | shipped `router.noPendingReminder` line (:5384) | no |
| Challenge answer "No" / timeout | FR-D02: not recorded, escalation re-entered | no |

**LLM independence (NFR-MSR-001):** the resolver and the vocabulary lists are pure Swift in the
medication module; the ack path runs on the keyword safety net ahead of the model (`routeSafetyNet`
precedes the interpreter), and no medication compilation unit gains an `LlamaInferenceEngine`
symbol.

### 8. Photo-as-evidence (FR-MSR-013, FR-MSR-014, OD-8)

**Resolution of OD-8 — the on-device-only evidence variant, judged by the caregiver, bound by
capture context.**

#### 8.1 Mechanism

- **Capture context determines the entry — never image content.** The capture affordances live
  on surfaces that already carry a determinate entry: the fired-dose screen
  (`MedicationVisualAidFireHandler`/`MedicationVisualAidsPresentation`) for the entry whose
  reminder rang, and the intake-record surface for an already-recorded dose. The photo itself is
  never classified — no CV, no matching against visual aids, no claim about what the image
  shows. When no determinate context exists, the design **declines to bind** (honest line) —
  there is no generic evidence camera, so FR-MSR-014's ambiguity case is handled by not creating
  the ambiguous capture surface at all, and any future surface must route ambiguity through the
  §7.3 clarification discipline ("asks … or declines to bind; never guesses").
- **Evidence attaches, never creates (safety delta (c)).** Two attach moments, both inside the
  acknowledgement machinery: (i) a capture taken while a reminder is pending is held as pending
  evidence for that entry and attached only when `finalizeAcknowledgement` records the dose —
  on a denied or timed-out challenge the held photo is discarded and nothing is recorded
  (the intake still required the chain); (ii) a capture on a record surface attaches to that
  existing `MedicationAdherenceLog`. No code path leads from capture to record creation.
- **The record still flows through the chain.** Ruling from §7.4 applies verbatim: the
  acknowledgement → challenge → double-dose → record sequence runs for the context's entry, and
  the challenge's medication-naming prompt is also the elder's chance to catch a wrong context
  ("Is that the small white tablet…?" → "No" → nothing recorded). The photo path is a second
  way to *start* the chain, never a way around it (FR-MSR-009's photo-flow clause).
- **On-device only (NFR-MSR-003).** Photos are captured, compressed (reusing the FR-D04b 200 KB
  cap precedent — `PhotoVerifier` :27) and stored in a new on-device file store keyed by the
  adherence-log id. The model carries a bare file name only (the `visualAids` precedent, :55–61:
  never a path, never bytes in the model). Nothing is transmitted; the recorded cloud
  exceptions do not apply.
- **Camera availability**: capture reuses the shipped camera-presenting component and its
  availability handling (`MedicationLabelScanner`/`CameraCapturePresenting` — no device, no
  permission, cannot present all have honest spoken guidance). A camera that cannot present
  never blocks the intake loop — the voice path is the floor (the FR-D04d graceful-degradation
  philosophy).
- **Recipient and judge**: the caregiver. The app's claim is exactly "a photo was captured at
  acknowledgment time and attached to this record" — never "intake verified". Delivery: there
  is no medication-photo transport in this feature. The photo stays on the primary device
  (compressed, retained until delivered — which, with no channel, is honestly "not yet
  delivered", surfaced as such, FR-MSR-018). When the inherited E2E channel
  (`docs/family-notifier-e2e-implementation-plan.md`) lands, the FR-D04b discipline applies to
  this store unchanged: deliver to the companion app, then delete from the primary device
  within 1 hour; never stored on the relay; delivery failure never silent. This is the OD-3
  transport-scope logic applied to evidence (§9.5), and it is the honest boundary under which
  the requirement's "where evidence leaves the device" clause stays satisfiable without
  falsifying anything today.

#### 8.2 Data shape

- `MedicationAdherenceLog` gains `evidencePhotoFileName: String?` (optional, custom-decoder
  default nil, migration-safe). The dementia-side `photoVerification: PhotoVerificationStatus`
  (:196) is **not** reused — keeping the two mechanisms separable keeps the unwired dementia
  state honestly reported (§8.5).
- NEW `MedicationEvidenceStore`: file-per-record storage under Application Support (the
  `VisualAidStore` pattern), one photo per record (re-capture replaces), deleted with its
  entry (the `removeMedication` cascade :11683 precedent) and deleted when a record's evidence
  is discarded pre-record.

#### 8.3 Determinism (FR-MSR-014)

Resolution is a function of the capture context, not the image: the same capture context and
pending set resolve identically every time. Ambiguity cannot be attributed to a neighbouring
medication by construction (no cross-entry binding exists); declined binding is the honest
failure branch.

#### 8.4 UX

The capture affordance is a large touch target on the fired-dose screen (and the record
surface), announced by voice when the surface appears (the FR-D04e audio-cue philosophy). The
elder may complete the whole intake by voice alone — the photo is the provided alternative, not
a requirement (FR-MSR-021: "or the provided photo capture").

#### 8.5 Dementia machinery — preserved, not repurposed (FR-MSR-020)

`PhotoVerifier` (FR-D04a–e) stays exactly as shipped — components present, not wired
(`photoVerificationEnabled` still `false` at every entry-construction site), no tests invented
for it, its state surfaced honestly. The new evidence path is a sibling, not a wiring of that
machinery; nothing in this feature removes, bypasses or silently enables the per-medication
dementia mechanism.

### 9. Caregiver notification (FR-MSR-015, FR-MSR-016, FR-MSR-017, FR-MSR-018, OD-7)

#### 9.1 The significant set and its trigger sites

The resolved set (OD-3) fires **unconditionally** — not gated by `CaregiverNotifySettings`
(whose opt-in remains for the daily first-fire `eventReminder` only, resolved at fire time
:353):

| Event | Wire type | Trigger site (medication path) |
|---|---|---|
| Missed dose | `missedMedication` (shipped) | `recordMissedDose` :551 — unchanged |
| Possible double dose | `possibleDoubleDose` (shipped) | `checkDoubleDoseAndRecord` blocked branch :530–536 — unchanged |
| **Intake recorded** | `intakeRecorded` (**new taxonomy case**) | `finalizeAcknowledgement` :453 — after the adherence log is durably persisted, before/independent of runtime cleanup; every recorded intake, whichever path recorded it |
| **Escalation started** | `escalationStarted` (**new taxonomy case**) | `handleAckDeadlineExpired` :378, the reminder's **first re-fire decision** (the ack window elapsed and the re-fire escalation begins — FR-MSR-015's scenario), once per reminder, state-derived (the engine's re-fire count), never a per-event stored flag |

Both new triggers live on the medication notification path, never on
`CaregiverEventFireHandler` (medication alarms carry no `userInfo["type"]` — its own guard
:70–76). Send decisions resolve at fire time, nothing is stored per event.

#### 9.2 Channels and honest per-contact results

- **Push/text path**: the shipped `notifyAll` per-contact loop (`FamilyNotifier` :112–151), with
  `NotificationResult` carrying success/errorCode/channel (:230). Significant-event calls now
  pass a `FamilyAlertContext` (kind `.medicationReminder`, hashed event id, title in memory
  only) so the channel the push rode and the `family_event_alerted` observability event are
  recorded for significant events too — the mechanism exists and is reused, not rebuilt.
- **Transport honesty (FR-MSR-016, FR-MSR-018)**: the shipped provider is a stub that returns
  success (`APNsProvider.sendPush` :222–227) — that is precisely the false success the
  requirements forbid. The design makes it honest: `sendPush` returns an explicit outcome
  (delivered / not-delivered with a reason code, e.g. `transport_unimplemented`), the notifier
  maps it to `success: false` + errorCode, partial delivery is reported as partial, and no
  surface describes a caregiver as notified when the transport did not deliver. When the E2E
  transport lands (inherited tracked work), the provider is swapped and the honesty contract
  stays.
- **Text channels**: `NotifyChannel.resolve(preferred:defaultApp:…)` (:58) keeps deriving the
  channel per contact; they remain available paths with the same honest-result rule.
- **Delivery claims**: made only for what actually fires. Transport-dependent statements are
  labelled inherited tracked work (`docs/family-notifier-e2e-implementation-plan.md`).

#### 9.3 The calendar channel — OD-7 resolved

**Decision: the consent-gated schedule mirror stays exactly as shipped, and the three at-risk
significant events additionally surface as one-off entries on the same shared family calendar.**

- **Mechanism.** `CalendarShareService` (consent gate at :124–162, status :224) already mirrors
  the schedule into shared twins on every schedule write (`MedicationScheduler.onScheduleChanged`,
  wired at `AppCoordinator` :3523 → `reconcileMedication` :437 → `CalendarShareMapper.medicationDrafts`
  :214). Significant events (missed medication, possible double dose, escalation started) are
  written through the same service and gate as **one-off** entries — the key grammar already has
  `CalendarShareKey.oneOff` (:32) — at the event time, non-recurring, keyed by a stable
  non-PII event identifier. The schedule mirror is untouched by this addition.
- **Which events.** Exactly the three at-risk events; **intake-recorded does not write calendar
  entries** — a calendar entry per taken dose would flood the family calendar and defeat the
  channel's attention purpose; the push notification still fires for it, and the caregiver's
  adherence view is its record surface. (OD-7 explicitly leaves "which events surface there" to
  the design; recorded here for review.)
- **Consent gate respected.** No calendar-share consent (or not signed in) ⇒ no writes, exactly
  as shipped (`canShare(isSignedIn:hasConsented:)` :196). The household's consent text covers
  sharing medication schedule content on that calendar; the event entries stay in that content
  class (medication name + time, to the same invitees) — **no new PII category on that channel,
  and none on the push wire.**
- **Invitee rule (deviation recorded).** The shipped `inviteeEmails` (:155) suppresses
  non-emergency contacts for medication-kind twins unless the first-fire opt-in is on. Because
  the significant set is unconditional, significant-event entries use the family-notification
  contact set (contacts with an email, de-duplicated, emergency-first — the same
  de-dup/ordering helpers) without consulting the first-fire opt-in. The opt-in keeps governing
  the daily reminder twins (noise control).
- **Honest results.** Each write's outcome is tracked per item through the service's existing
  pending-queue/status surface; a failed or pending write is reported as itself (the Settings
  status card already shows the pending count honestly), never as delivered.

#### 9.4 The wire (FR-MSR-017)

- Envelope stays versioned and PII-free: `{v:1, alert_type, timestamp}` **plus an optional
  `entry_id_hash`** (`IdHashing.shortHash`, a truncated SHA-256 — one-way) where
  medication-level correlation is needed (`FamilyNotifier.buildPayload` :153 extended). No
  medication name, dose, label text, household content, or title on the wire, on any of the
  four significant types. The additive key keeps v:1 (no deployed consumer exists — the
  transport is unimplemented); this is recorded as the honest state, to be revisited at
  transport landing.
- The `FamilyAlertContext` in-memory-title rule stands: titles (the medication name) are never
  serialized; putting names/titles on the wire remains an explicit owner-level decision, not
  smuggled in here.

#### 9.5 Honest degradation (FR-MSR-018)

No silent stubs, stated affirmatively: the unwired photo-verification machinery is surfaced as
itself (§8.5); the push transport reports not-delivered (§9.2); a calendar write failure
surfaces as pending/failed (§9.3); a failed persistence write blocks its dependent step — a
reminder is not armed (:733 persist-then-arm) and a dose is not reported as recorded (:476); and
every delivery-dependent claim in this document is labelled inherited tracked work.

### 10. Preservation and persistence (FR-MSR-019, FR-MSR-022)

- **Reminder/escalation semantics preserved.** The only change to the chain is that all derived
  instants come from the one resolved `scheduledAt` (§4.4): the reminder names the medication;
  re-fires follow the shipped interval/count within the escalation window (defaults 5 min ack /
  5 refires / 60 min window / 12 min interval — `EscalationEngine` :31–34, untouched); a fully
  escalated miss is marked, logged and alerted; a future dose stays future on restore (:191–198).
  One `Date` remains the sole derivation basis (FR-MSR-019's rejection of any other basis holds
  by construction).
- **Persistence before alarm.** `createPendingReminders` persists the reminder (with its
  resolved exact `scheduledAt`) before the first `alarmScheduler.scheduleReminder` call
  (:733–744); a failed write skips arming and surfaces (`reminder_persistence_failed` :789).
  The mapping-change pass obeys the same order (§4.5).
- **Acknowledgement durability.** `finalizeAcknowledgement` writes the adherence log before
  runtime cleanup and before returning success (:473–496) — a crash after confirmation loses
  nothing.
- **Process-kill re-arm.** `scheduleAll()` on launch (`restoreState` :611 → `rearmAllPendingReminders`
  :646) restores the persisted reminders — now carrying slot-model resolved times — and re-arms
  within the unexpired escalation window; escalation resumes from the remaining window time.
  This path is unchanged.
- **Future-stays-future.** Restore never converts a not-yet-due dose into "fire now"
  (the shipped recovery rule).

### 11. Migration and legacy compatibility (NFR-MSR-006, OD-5)

**Resolution of OD-5 — no automatic backfill inference; legacy entries keep working exactly as
today; every re-interpretation is deterministic, visible and family-directed.**

- **Decode.** `quantity`, `slot`, `mealRelation` (entry) and `evidencePhotoFileName` (log) are
  optional with custom-decoder defaults — the `init(from:)` :114 and `decodeIfPresent` :129–130
  precedent. A pre-revamp payload (raw `scheduleTimes`, no new fields) loads successfully; no
  key is required that the payload does not contain. **Implementation trap, called out for
  design-l2/implement: `withScheduleTimes` (:144) rebuilds the entry memberwise — it must carry
  the new fields (or be replaced) or a slot-model entry loses its slot on a copy.**
- **Legacy representation.** `scheduleTimes` remains required-decodable and representable; a
  legacy entry (`slot == nil`) resolves and schedules byte-identically (`.success(entry.scheduleTimes)`,
  §4.4), and the slot model never consults `scheduleTimes` for slot entries.
- **Migration time.** Nothing is rewritten at migration. No slot is inferred, ever. A migration
  that drops, alters or silently reinterprets a legacy schedule element is a defect (the
  requirement's failure scenario).
- **Rendering.** Legacy entries render in the family list with their raw clock times (display
  formatting as today; any spoken line through the `SpokenTime` formatter per NFR-MSR-004) and
  behave exactly as today until the family edits them.
- **Family-directed conversion (the only time→slot path).** Inside an explicit edit of a legacy
  entry, the editor offers the slot model; the family assigns each legacy time to a slot. The
  only assistance permitted is **exact-equality preselection**: a legacy time whose hour:minute
  equals the household mapping's time for a slot may preselect that slot — visible in the chips,
  deterministic, family-confirmed on save. Any legacy time with no exact match requires the
  family to pick a slot or remove the row; the slot-model save is gated on every row being
  assigned. The family may also leave the entry in times mode — legacy stays a first-class shape.
- **Native-calendar retime interaction (decision).** `setScheduleTimes` / the
  `onMedicationNativeChanges` relay (`applyMedicationCalendarMutations` :12067) can retime an
  entry from the iPhone Calendar app. For a slot-model entry the times are derived, so a raw
  retime would create two sources of truth; the design **refuses the retime for slot entries**
  (returns `false`; an honest observability event is emitted; the family edits the slot in the
  app instead). Refusal is the non-interpretation: deterministic, visible, never a silent
  re-interpretation. Legacy entries are unaffected. (Recorded for review — the alternative,
  clearing the slot silently, was rejected as family-intent loss.)
- **Frequency.** The slot model is daily; the shipping editor already constructs `.daily`
  everywhere. `.weekly`/`.custom` stay decodable; legacy entries of any frequency keep working
  exactly as today (the shipped scheduler treats `scheduleTimes` as daily wall-clock times —
  `CalendarShareMapper.medicationDrafts` :205 records the same fact). Representing non-daily
  frequencies in the slot model is out of scope for this feature (recorded, not silently
  dropped).

### 12. Privacy, observability, on-device (NFR-MSR-002, NFR-MSR-003)

- **No new egress.** Label scanning (Vision, on-device), medication-photo evidence (on-device
  store), the ack resolver, and the slot mapping are all device-local. The recorded cloud
  exceptions (voice transcription; OCR'd-text translation) do not apply. The shipped
  purpose-lookup medicine-name search-stack egress is unchanged and is the stack's, under its
  existing disclosure. **Honest note for review:** the family-calendar channel is an existing
  consent-gated egress of medication schedule content (Google Calendar); §9.3 extends its
  content with significant-event entries inside the same content class and consent — this is
  not a new channel or a new data category, and it is stated rather than implied.
- **Observability.** Every new event is PII-free (`entry_id_hash` = `IdHashing.shortHash` only,
  categorical fields, `LogSanitiser` discipline). New event vocabulary (classification only):
  `medication_slot_clock_changed`, `medication_slot_unresolved`, `medication_ack_resolved` /
  `medication_ack_ambiguous` / `medication_ack_unmatched` / `medication_ack_clarify_ended`
  (outcome enum only), `medication_evidence_captured` / `_discarded` / `_attached` (no image,
  no text), plus the extended family-alert events (`family_alerted` with the new alert_type
  values). No medication name, dose text, label text, photo content or utterance content ever
  reaches an event or log.
- **Release log gate.** `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`)
  must exit 0 with the new source paths inside its coverage (NFR-MSR-009).

### 13. Concurrency and isolation (explicit)

| Component | Isolation | Concurrent access |
|---|---|---|
| `MedicationAckResolver` (NEW) | pure static function — no state, no IO, no clock | trivially thread-safe; callable from the router path |
| `MedicationSlotClock` / slot resolver (NEW) | pure value + store read; mapping read once per arming pass | reads are per-arming; the record is written by ONE writer (the settings surface), validated before persist; no partial states observable |
| `MedicationScheduler` (CHANGED) | shipped confinement unchanged — mutations (`loadSchedule`, `scheduleAll`, ack/record paths, the new `rearmForSlotClockChange`) run on the main thread; alarm callbacks arrive on the main queue | the new resolution feed adds no shared mutable state; mapping reads are point-in-time |
| Clarification walk state | coordinator `@Published`/main-thread state (the `pendingNavigationWalk` pattern) | one active walk; a new ack re-enters resolution (single logical flow) |
| `MedicationEvidenceStore` (NEW) | file IO off the main thread (the scanner's `offload` discipline :82); one photo per record (replace-on-recapture) | per-record writes are serialized by record identity; no cross-record state |
| `FamilyNotifier` / `APNsProvider` (CHANGED) | async per-contact loop, per-call payloads | unchanged shape; the honest outcome type adds no shared state |
| `CalendarShareService` (CHANGED) | shipped reconcile/queue discipline; consent read at act time | one-off event writes ride the same single reconcile path |
| Camera capture (evidence) | the shipped `CameraCapturePresenting` main-queue discipline, one session at a time | the scanner's `isRunning` guard pattern prevents overlapping sessions |

### 14. Error-path catalogue

| Interface / flow | Failure | Returned outcome | Consumer behaviour |
|---|---|---|---|
| Slot→clock resolution (§4.4) | corrupt mapping value | `SlotClockError.indeterminate(slot:)` | no reminder armed for that entry; `medication_slot_unresolved` event; settings error surfaced; never a guessed time |
| Mapping save (§4.2) | store write fails / out-of-range input | write result surfaced; no take-effect | mapping unchanged; re-arm not triggered; honest error line |
| Mapping-change re-arm (§4.5) | persist fails | `persistReminders` false | arming skipped for the affected reminders; surfaced (shipped `reminder_persistence_failed` shape) |
| Scan (`MedicationLabelScanner`) | camera unavailable / recognition or read failure / empty candidate | existing honest outcomes: unavailable-with-reason, spoken "could not read it", `.scanned(nil/empty)` | form unchanged; photo retained; nothing bound |
| Ack resolution (§7.2) | ambiguous / unmatched / nothing pending | `AckResolution` enum cases | sanctioned clarification, or honest "nothing to acknowledge" line; nothing recorded; reminders untouched |
| Clarification walk (§7.3) | no response within the window | walk ends (configurable timeout) | nothing recorded; reminders and escalation continue; classification event |
| Challenge | "No" / timeout | `reEnterEscalation` (shipped) | not recorded; FR-D02 re-enter; locale-aware copy |
| Recording (§7.4) | adherence-log persist fails | `SafetyError.reminderPersistenceFailed` (shipped) | failure surfaced; not reported as recorded; intake-recorded notification NOT fired (it follows successful persistence) |
| Evidence capture (§8) | camera unavailable / store write fails / pre-record challenge denied | `CameraAvailability` reasons / store error (explicit) / discard | voice path continues; photo not presented as evidence; honest lines |
| Notification delivery (§9.2) | transport not implemented / partial failure | `NotificationResult` per contact (`success:false`, errorCode, channel) | partial reported as partial; never described as notified |
| Calendar significant-event write (§9.3) | no consent / not signed in / write failure | consent gate blocks; per-item result / pending queue | no writes without consent; failures surfaced as themselves |
| Notify at fire time (§9.1) | settings resolve at fire time only | — | no per-event stored decision can silently suppress a significant event |

### 15. Configuration and timeouts (timeouts are configuration)

| Parameter | Value | Status |
|---|---|---|
| `MedicationSlotClock` defaults | morning 08:00 / afternoon 13:00 / evening 19:00 | NEW named defaults (OD-1; household-configurable) |
| `ConfirmationChallenge.challengeTimeoutSeconds` | existing (default 30 per FR-D02) | untouched, still injected config (:28) |
| Clarification response window | NEW configurable parameter; default equal to the challenge timeout | configuration, single named constant — no literal at the call site |
| Ack window / refire count / escalation window / refire interval | existing entry-level fields (5 / 5 / 60 / 12 defaults) | untouched (FR-MSR-019 binding) |
| Evidence photo size cap | FR-D04b-existing 200 KB precedent (`PhotoVerifier` :27) | reused as the compression cap; not a timeout |
| Notification / calendar calls | existing async paths; no new timeouts | unchanged |
| Mapping resolution | pure function — no timeout possible | none |

### 16. Elderly-fit UX, localisation, accessibility (FR-MSR-021, NFR-MSR-004, NFR-MSR-005, NFR-MSR-007)

#### 16.1 Fit for the forgetful elder

- The intake loop completes entirely by voice (acknowledge → challenge answer → recorded) with
  zero touch; the photo capture is the provided alternative (§8.4); the clarification answers
  (yes/no, or naming a medication) are voice-reachable.
- The unambiguous case adds no step: a simple "taken" with one pending reminder resolves
  exactly as today.
- No new command vocabulary beyond the established set: the slot and meal words are part of the
  acknowledgement sentence grammar the owner specified, not new commands; the only new
  interactions are variants of the sanctioned clarification forms and yes/no.
- One idea per utterance: the challenge, each clarification question and every outcome line is
  a single, short spoken sentence.
- Family-facing editor surfaces use plain language (no "slot", no "mapping" jargon in copy),
  ≥44 pt controls, ≥18 pt body text, contrast per the shipped appearance tokens; the
  mapping section shows the mapped times as read-only context so nobody computes clock times.

#### 16.2 Localisation and spoken time

- Every new user-visible string exists in Nepali and English in
  `Resources/Localizable.xcstrings` (no hard-coded strings): slot labels, meal labels, unit
  labels, the quantity control, the mapping section (+ reset + error lines), the sanctioned
  clarification forms ("did you mean X" / "X or Y"), clarification/outcome lines, the
  significant-event alert bodies (`family.alertIntakeRecorded`, `family.alertEscalationStarted`),
  evidence capture/state lines, calendar event entry titles. `L10nCatalogCoverageTests` extends.
- **All spoken times go through the `SpokenTime` formatter** (`Services/Voice/SpokenTime.swift`
  :28; the `formattedTime` :5375 and `todayMedicationSummaryLines` :12625 precedents). Any new
  spoken line that names a time — mapped reminder times, schedule renderings, notification
  copy, error lines — uses the formatter; raw hour/minute interpolation into speech is a defect
  (NFR-MSR-004).

#### 16.3 Devanagari regression pin (NFR-MSR-007)

The resolver's matching reuses the shipped substring/vocabulary conventions
(`MedicationVoiceVocabulary.canonical`, the parser's Devanagari-fusion substring matching) and
does not change, "fix" or route around the pinned grapheme-cluster behaviour. The pinned
regression tests pass unchanged; the matching implementation is untouched; a proposed "fix" is
rejected (owner decision required, outside this feature).

### 17. Quality, compliance and latency (NFR-MSR-008, NFR-MSR-009, NFR-MSR-010)

- **Test rigor.** Scoped suites are the honest gate (the constitution's Feature Constraint 4
  names them): the ten medication suites and four notifier suites extend with the new
  contracts, plus NEW suites for `MedicationSlotClock` (determinism, totality, corrupt-value
  fail-closed, decode defaults), `MedicationAckResolver` (the §7.2 truth table, the §7.3 walk,
  determinism, denial interactions), `MedicationEvidence` (attach-never-create, on-device,
  context determinism, discard-on-denial), quantity/dose-line composition, migration decoding,
  and notifier honesty (stub reports not-delivered). The four required integration tests ride
  along and are release-blocking: persistence-before-alarm ordering, process-kill re-arm,
  LLM independence (symbol inspection), and the legacy-payload migration round trip.
  Zero-touch (100 %) unit coverage on every touched medication safety path; pre-existing
  baseline failures recorded separately, never mixed in.
- **Compliance/release.** The release log-surface gate passes over the new paths; the App Store
  health-data posture is unchanged (no new data collection, no new permission — camera is
  already used at point of use with plain-language copy); PII-free telemetry keeps the standing
  log-volume posture (NFR-MSR-009).
- **Elevated bar.** Decisions touching FR-D01/D03/D04a–b machinery (the challenge, the
  detector, the photo machinery) run at the dementia supplement's 0.90 threshold; this design
  touches them only by routing around them (§7.4, §8.5) — the challenge/detector contracts are
  byte-preserved.
- **Firing latency (NFR-MSR-010).** The mapping resolves at arming time (pure O(1)); no
  fire-time resolution step exists, so a reminder fires within 30 s of its resolved scheduled
  time, including for entries created or edited shortly before the slot and reminders re-armed
  after a relaunch (the persisted `scheduledAt` is the schedule of record). DV-1/DV-6 exercise
  this on the reference device.

### 18. Safety delta (a)–(d) as enforced invariants

| Delta | Enforced invariant | Mechanism | Verification |
|---|---|---|---|
| (a) OCR never auto-binds | no scan path writes a store or arms a reminder; only the family's save through the draft binds | §6: candidate → draft → `addMedication`; any new scan entry point must route through the same gate | `MedicationEditorDraftTests`/`MedicationLabelOCRTests` extended; a silent-auto-apply path is a test-level rejection |
| (b) deterministic, total slot→clock mapping | every creatable entry resolves to one determinate hour/minute; failure is typed and fail-closed; all derived instants come from the one resolved time | §4.3–4.5: exhaustive enum function; `.indeterminate` → no arm + surfaced; `EscalationEngine` untouched and fed the resolved `Date` | `MedicationSlotClockTests`; escalation/persistence integration tests; DV-1 |
| (c) photo never creates a record | capture leads only to evidence attachment inside the acknowledgement machinery; denied/expired challenge ⇒ no record, evidence discarded | §8.1: context-bound captures; attach inside `finalizeAcknowledgement` or on an existing record; no capture→record edge exists | `MedicationEvidenceTests` (photo-alone ⇒ no record); DV-4 |
| (d) PII-free wire | envelope carries type + timestamp (+ one-way `entry_id_hash`); no names/doses/titles on any wire; titles stay in memory | §9.4: `buildPayload` extension; `FamilyAlertContext` rule preserved | `FamilyNotifierTests` (payload shape; no name); DV-5 |

---

## Components

### 19. Module boundaries and responsibilities

| File / artifact | Status | Responsibility | Requirements |
|---|---|---|---|
| `Services/MedicationScheduler/Models.swift` | CHANGED | `MedicationEntry` grows `quantity`/`slot`/`mealRelation` (optional, custom-decode defaults); `MedicationAdherenceLog` grows `evidencePhotoFileName`; `FamilyAlertType` grows `intakeRecorded` + `escalationStarted`; `withScheduleTimes` carries the new fields | FR-MSR-001/003/004/015/017; NFR-MSR-006 |
| `Services/MedicationScheduler/MedicationSlotClock.swift` | NEW | `MedicationSlot`, `MealRelation`, `TimeOfDay`, `MedicationSlotClock` (defaults, custom decode, validation, one writer), `SlotClockError`; the pure deterministic mapping (§4) | FR-MSR-001/002; NFR-MSR-006 |
| `Services/MedicationScheduler/DoseLine.swift` | NEW (small) | Quantity composition into `doseDescription` (single rule, localized units) | FR-MSR-003 |
| `Services/MedicationScheduler/MedicationAckResolver.swift` | NEW (pure) | Ack resolution over candidates by what was said: name keys → slot → fired preference; `AckResolution`; the clarification walk order — never a guess (§7) | FR-MSR-007/008; NFR-MSR-001 |
| `Services/MedicationScheduler/MedicationEvidenceStore.swift` | NEW | On-device evidence file store (bare file names in the model; JPEGs under Application Support; one per record; delete-with-entry) | FR-MSR-013/014; NFR-MSR-003 |
| `Services/MedicationScheduler/MedicationScheduler.swift` | CHANGED | `resolvedScheduleTimes(for:)` feed at arming; `rearmForSlotClockChange()`; significant-event triggers (`intakeRecorded` in `finalizeAcknowledgement`, `escalationStarted` on the first re-fire decision); slot-entry retime refusal in `setScheduleTimes` | FR-MSR-002/015/019/022 |
| `Services/MedicationScheduler/MedicationEditorDraft.swift` | CHANGED | Quantity + slot + meal controls in the draft; scanned-schedule→slot candidates; all shipped draft rules bound unchanged | FR-MSR-001/005/006; NFR-MSR-006 |
| `Services/MedicationScheduler/MedicationLabelOCR.swift` + `ScannedSchedule` (pure helper) | CHANGED (bounded) | No parser-surface change; a fixed documented conversion of parser outputs to slot candidates (§6) | FR-MSR-005/006 |
| `Services/Voice/CommandRouter.swift` | CHANGED | Ack gate additions (additive phrases only; denial guard first); resolution call replacing `oldestPendingReminderEntryId()`; clarification-walk interception + copy; correction-rescue ordering preserved | FR-MSR-007–012; NFR-MSR-001 |
| `App/AppCoordinator.swift` | CHANGED | `medicationAckCandidates()` seam; clarification-walk state (navigation-walk precedent); editor save plumbing (`addMedication` gains quantity/slot/meal); mapping-save action + re-arm call; evidence capture plumbing | FR-MSR-001/007/008/013/014 |
| `App/SettingsView.swift` | CHANGED | Editor: quantity + slot + before/after-meal controls; "Medicine times" mapping section (3 rows + reset); legacy edit-switch flow; evidence capture affordance on the dose/record surfaces | FR-MSR-001/002/011; NFR-MSR-005 |
| `Services/FamilyNotifier/FamilyNotifier.swift` | CHANGED | `FamilyAlertType` cases wired; payload gains optional `entry_id_hash`; honest provider outcome (`transport_unimplemented`) replacing the silent-success stub; context passed for significant events (channel reporting) | FR-MSR-015/016/017/018 |
| `Services/CalendarSync/CalendarShareService.swift` + `CalendarShareMapper.swift` | CHANGED | One-off significant-event calendar entries (3 at-risk events), consent gate reused, invitee rule for significant events, honest per-item results | FR-MSR-016/017; OD-7 |
| `Resources/Localizable.xcstrings` (+ `L10n.swift`, `L10nCatalogCoverageTests`) | CHANGED | All new strings ne/en; spoken times only via `SpokenTime` | NFR-MSR-004/005 |
| `ios/tools/check-release-log-safety.sh` fixtures | CHANGED (coverage) | New paths inside the gate's coverage; gate exits 0 | NFR-MSR-002/009 |
| `Services/MedicationScheduler/EscalationEngine.swift`, `ConfirmationChallenge.swift`, `DoubleDoseDetector.swift`, `PlatformAlarmScheduler.swift`, `PhotoVerifier.swift` | UNCHANGED (bound) | The escalation machinery, challenge, detector, alarm arming and the dementia photo machinery are preserved contracts — fed the same one `Date` | FR-MSR-003/009/019/020; NFR-MSR-001 |
| `Services/Voice/AckFastLane.swift` | UNCHANGED (property extended by tests) | The ack fast lane and its mic-continuity property hold for the new shapes | FR-MSR-012 |
| Tests: `ios/ElderlyAssistantTests/Services/MedicationScheduler/` (10 suites), `…/Services/FamilyNotifier/` (4 suites), `…/Services/Voice/` | CHANGED + NEW suites | Coverage of every new contract + the four required integration tests | NFR-MSR-008/009 |

### 20. Data model outline

| Datum | Shape | Store / notes |
|---|---|---|
| `MedicationEntry` | + `quantity: MedicationQuantity?`, `slot: MedicationSlot?`, `mealRelation: MealRelation?`; `scheduleTimes` retained | `EncryptedLocalStorage` key `medication.entries` (shipped); optional fields, custom decode |
| `MedicationSlotClock` | `morning/afternoon/evening: TimeOfDay` | NEW key (e.g. `medication.slot_clock`); per-slot decode defaults; present-but-invalid ⇒ indeterminate; one writer |
| `MedicationAdherenceLog` | + `evidencePhotoFileName: String?` | shipped key `medication.adherence_log`; bare file name only |
| `ScheduledReminder` | unchanged (`scheduledAt` = the resolved exact time) | shipped key `medication.pending_reminders` |
| Evidence files | JPEG ≤ 200 KB cap, one per record | `Application Support` on-device store (VisualAidStore pattern); deleted with the entry or on pre-record discard |
| Family-alert wire | `{v:1, alert_type, timestamp, entry_id_hash?}` | `FamilyNotifier.buildPayload`; no names/doses/titles |
| Calendar significant-event entry | one-off, non-recurring, at the event time, keyed by a stable non-PII identifier; title plain-language + medication name (same content class as the existing mirror) | `CalendarShareService` one-off key space; consent-gated |

### 21. Interface surface (seams, payload schemas, topology, auth)

#### 21.1 New/changed seamed signatures (explicit error types)

```swift
// Slot→clock resolution (pure value; MedicationSlotClock.swift)
func resolve(slot: MedicationSlot) -> Result<TimeOfDay, SlotClockError>

// Scheduler arming feed (MedicationScheduler)
func resolvedScheduleTimes(for entry: MedicationEntry) -> Result<[DateComponents], SlotClockError>
func rearmForSlotClockChange()

// Ack candidate seam (AppCoordinator, read-only; the oldestPendingReminderEntryId precedent)
func medicationAckCandidates() -> [MedicationAckCandidate]

// Ack resolution (pure; MedicationAckResolver.swift)
static func resolve(transcript: String, candidates: [MedicationAckCandidate]) -> AckResolution

// Evidence store (MedicationEvidenceStore.swift)
func store(image: UIImage, for logId: UUID) -> Result<String, EvidenceStoreError>   // returns the bare file name
func delete(fileName: String) -> Result<Void, EvidenceStoreError>

// Notifier honesty (FamilyNotifier / APNsProvider)
enum PushOutcome: Equatable { case delivered; case notDelivered(reason: String) }
func sendPush(payload: [String: Any], deviceToken: String) async -> PushOutcome

// Calendar significant-event write (CalendarShareService)
func writeSignificantEvent(_ event: SignificantMedicationEvent, entry: MedicationEntry?) -> CalendarShareWriteResult
```

#### 21.2 Outcome/error types

`SlotClockError.indeterminate(slot:)`; `AckResolution.{resolved, ambiguous, noMatch, nothingPending}`;
`EvidenceStoreError` (explicit cases: writeRequested, storageUnavailable, removeFailed);
`PushOutcome`; per-contact `NotificationResult` (existing: success/errorCode/channel);
per-item calendar results.

#### 21.3 Persisted schema versioning

`MedicationEntry` and the wire envelope keep their current version fields; the new keys are
optional/additive (custom decode; `decodeIfPresent`). No migration step runs at upgrade — the
absence of a key IS the default (§11).

#### 21.4 Infrastructure topology

One iOS app process: main-thread-confined coordinator/scheduler state; `UNUserNotificationCenter`
as the firing surface; on-device camera + Vision; `EncryptedLocalStorage` + Application Support
stores; the family Google Calendar via the existing OAuth session (consent-gated); the APNs
push path (transport stubbed, honestly reported). No server, no container, no Docker.

#### 21.5 Auth strategy

No accounts or tokens introduced. Authorization surfaces as they ship: the family-calendar
share consent (reused for §9.3 writes), the per-contact caregiver-notify settings (opt-in kept
for the daily first-fire only), the cloud voice-stack consent (untouched — no new egress), and
camera permission requested at point of use with plain-language copy (shipped behavior for the
scanner, reused for evidence capture).

---

## Traceability

### 22. Requirement-to-architecture mapping

| Requirement | Design sections |
|---|---|
| FR-MSR-001 slot-based entry model (quantity + slot + meal) | 4.1, 4.2, 4.4, 19 (draft/settings rows) |
| FR-MSR-002 deterministic total slot→clock mapping, defaults, family-configurable | 4.2, 4.3, 4.5, 15, 18 (b), 21.1–21.2 |
| FR-MSR-003 structured quantity, composed dose line, detector unchanged | 4.6, 19 (DoseLine), 2 (invariant ledger) |
| FR-MSR-004 purpose at entry (optional; no dependency) | 5 |
| FR-MSR-005 scan-to-fill additive, bounded, partial-fill honest | 6, 19 (draft + ScannedSchedule) |
| FR-MSR-006 OCR confirmation before binding, no silent auto-apply | 6, 18 (a), 14 |
| FR-MSR-007 voice ack names medication and slot; resolution by what was said | 7.1, 7.2, 7.6 |
| FR-MSR-008 conservative disambiguation, sanctioned copy only | 7.2, 7.3, 14 |
| FR-MSR-009 safety sequence preserved, no bypass | 7.4, 8.1, 2, 17 |
| FR-MSR-010 intake recorded against the schedule | 7.4, 10 |
| FR-MSR-011 refusal-first denial guard preserved | 7.1, 7.5 |
| FR-MSR-012 mic continuity around acks | 7.5, 13, 19 (AckFastLane row) |
| FR-MSR-013 photo evidence augments never replaces, never creates | 8.1, 8.2, 8.5, 18 (c) |
| FR-MSR-014 photo evidence shared-slot resolution deterministic | 8.1, 8.3 |
| FR-MSR-015 significant-event set + triggers on the medication path | 9.1, 9.5, 14 |
| FR-MSR-016 channels + honest per-contact delivery; consent gate | 9.2, 9.3, 14 |
| FR-MSR-017 PII-free wire | 9.4, 18 (d), 20 |
| FR-MSR-018 honest degradation, no silent stubs | 9.2, 9.3, 8.1, 9.5, 14 |
| FR-MSR-019 reminder/escalation semantics preserved | 10, 2, 4.4 |
| FR-MSR-020 dementia machinery preserved and integrated | 7.4, 8.5, 17 |
| FR-MSR-021 elderly-fit UX of the new flows | 16.1, 7.3, 8.4 |
| FR-MSR-022 persistence before alarm + process-kill re-arm | 10, 4.5, 14 |
| NFR-MSR-001 LLM independence | 7.6, 13, 17 |
| NFR-MSR-002 PII-free observability + release log gate | 12, 17, 19 |
| NFR-MSR-003 on-device label/photo processing, no new egress | 6, 8.1, 12 |
| NFR-MSR-004 localisation + spoken time via the formatter | 16.2, 11 (legacy rendering) |
| NFR-MSR-005 accessibility (44pt/18pt/contrast, voice-first) | 16.1, §4.2 control shape |
| NFR-MSR-006 migration compatibility, no loss, no inference | 11, 4.2, 20, 21.3 |
| NFR-MSR-007 Devanagari grapheme regression pin | 16.3 |
| NFR-MSR-008 test coverage, integration tests, confidence bars | 17, 19 (tests row) |
| NFR-MSR-009 compliance and release gates | 12, 17, 19 |
| NFR-MSR-010 reminder firing latency | 4.3, 10, 17 |

Every locked requirement is bound by the design above. No requirement is left unbound.

---

## Risks and open questions

### 23. Risks and review focus for `review-l1`

1. **Calendar-channel content extension (§9.3, OD-7).** Significant-event entries put
   medication-name + event-time content on the shared Google Calendar. This is the same content
   class the shipped schedule mirror already shares under the same consent, and FR-MSR-016 names
   the calendar channel in scope — but the disclosure copy (`calendarShare.consent.*`) should be
   reviewed to confirm it covers event entries, not just schedule items. Recorded as the top
   review focus.
2. **Simple-ack behaviour change (§7.2).** Several pending reminders now yield clarification
   instead of the silent oldest-pending pick. Required by FR-MSR-007's failure scenario; the
   single-pending case is byte-identical. Review should confirm the due-set preference
   ("fired == true") is the right reading of "unambiguous".
3. **Retime refusal for slot entries (§11).** The Calendar-app retime path is refused for
   slot-model entries (honest event, no silent conversion). The alternative (clearing the slot)
   was rejected; review should confirm the refusal is acceptable to the family's edit paths.
4. **Honest-stub change (§9.2).** Making `APNsProvider` report not-delivered changes shipped
   behaviour (and its tests) — required by FR-MSR-016/018, but it makes delivery gaps visible on
   every existing alert. Review should confirm this is the intended honesty posture.
5. **Evidence delivery boundary (§8.1, OD-8).** On-device-only evidence is honest but means the
   caregiver cannot see the photo remotely until the inherited E2E transport lands. Review
   should confirm the retention/forward-contract statement satisfies FR-MSR-013's
   "where evidence leaves the device" clause.
6. **Dose-line composition rule 2 (§4.6).** Composing quantity + scanned strength into one line
   ("1 tablet, 500 mg") preserves data but adds content; the alternative (quantity wins,
   strength dropped) loses the scanned value. Review should confirm the composed form.
7. **`withScheduleTimes` copy trap (§11).** A memberwise rebuild that drops the new fields is a
   silent slot-loss defect; called out for implement-time attention and a migration test.
8. **Legacy entries in the ack slot filter (§7.2 rule 3).** Legacy (slot-nil) entries never
   match a slot word; a household mid-upgrade gets the honest clarification instead of an
   inferred match. Deterministic and conservative; review should confirm no inference is wanted
   there either.

## Deferred work (design-l2 / implementation — nothing below weakens a binding above)

| Item | Disposition |
|---|---|
| Clarification-walk state representation; response-window plumbing | DEFERRED to design-l2 — mechanics fixed in §7.3; the state object and its timeout wiring are component details |
| Slot/meal word lists (exact strings, both languages); additive ack-phrase additions | DEFERRED to design-l2/implement — closed lists, no LLM, tested; boundary: denial guard first, no reordering, Devanagari pin untouched |
| Exact L10n copy strings (units, slots, meals, mapping section, clarification forms, outcome lines, alert bodies, evidence lines, calendar entry titles) | DEFERRED to implementation — key sets and semantics fixed (§16.2); both languages; catalog coverage test |
| Evidence store internals (file naming, compression implementation, replace/delete ordering) | DEFERRED to design-l2 — shape fixed in §8.2/§20 (bare file names, one per record, 200 KB cap) |
| Capture-surface placement/details (dose screen affordance, record-surface affordance) | DEFERRED to design-l2 — context-bound determinism and no-generic-camera rule fixed in §8.1 |
| Calendar one-off bookkeeping (key lifecycle, reconcile interplay, entry title format) | DEFERRED to design-l2 — mechanism, consent gate, invitee rule and event subset fixed in §9.3 |
| Editor interaction details (quantity/strength coexistence rendering; mapping control layout) | DEFERRED to design-l2 — rules fixed in §4.1/§4.6 |
| Wave decomposition and unit boundaries | DEFERRED to plan-tasks (the plan owns unit decomposition) |
