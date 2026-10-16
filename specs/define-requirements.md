# Requirements — Medication Schedules and Reminders (feature)

**Project:** Elderly AI Assistant · **Feature:** `medication-schedules-reminders` (v1) ·
**Branch:** `feat/medication-schedules-reminders` (worktree
`elderly-ai-assistant-medication-schedules-reminders`; scaffold base master `261aa862`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-15 · **Status:** HIL gate `bedf72fc` approved by the owner from Slack
(2026-10-14T22:22:30Z); this artifact is submitted for the coordinator's completion. The T2 human
gate sits at `final-sign-off`. The locked snapshot (`define-requirements.lock.yaml`) is the
drift-detection baseline for downstream tasks.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both cover the same set; the per-requirement files
are the unit of change, this document and the lock are the snapshot downstream tasks
(`design-l1`, `design-l2`, `review-l2`, `plan-tasks`, `implement`, `review-implementation`,
`final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-MSR-NNN` / `NFR-MSR-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention the
earlier features used (`FR-LCT-NNN`, `FR-PI-NNN`, `FR-SP-NNN`, `FR-MTC-NNN`, `FR-FCU-NNN`,
`FR-CDP-NNN`, `FR-CNR-NNN`). The brief's `FR-026` … `FR-030` and the dementia supplement's
`FR-D01` … `FR-D04e` are referenced for traceability, never renumbered. One file per requirement;
every requirement carries Gherkin acceptance criteria, and every safety-relevant requirement
carries both a happy-path and a failure or misuse scenario.

**Source mandate.** The stakeholder input is the owner's brief delivered with the scaffold
invocation (2026-10-15) — the seven scope points below — restated as binding in the feature
constitution [`specs/medication-schedules-reminders/constitution.md`](medication-schedules-reminders/constitution.md)
(the source mandate: Feature Purpose & Scope, the five binding contracts — Entry Model &
Slot-to-Clock Mapping; Intake Acknowledgement & Recording; Scan-to-Fill; Photo-as-Evidence;
Caregiver Notification — the Safety & Compliance Delta (a) … (d), Feature Constraints 1 … 10, the
Integration Surfaces table, and the Open Decisions section). Read-only inputs, not modified by
this pass: the project-root [`requirements.md`](../requirements.md) (`FR-026` … `FR-030`,
`NFR-027`) and [`requirements-dementia-supplement.md`](../requirements-dementia-supplement.md)
(`FR-D01` … `FR-D04e`). Context for the shipped machinery:
[`docs/medication-scheduler-implementation-plan.md`](../docs/medication-scheduler-implementation-plan.md).
File and line anchors in the constitution are verified orientation, not contracts (verified
against master `261aa862`, 2026-10-15).

**The owner's seven scope points** (owner brief, 2026-10-15):

1. Entry model becomes quantity + time-of-day (morning/afternoon/evening) + before/after meal — not raw clock times.
2. Each medication carries a brief purpose description.
3. Camera scan of packaging/label fills the name and schedules, with manual entry as before.
4. The elder acknowledges intake in natural voice ("I have taken X for morning before meal") and intake activities are recorded against daily schedules.
5. A photo of the medication serves as intake evidence — easier than dictating names when several medications share one schedule slot.
6. Caregivers are always notified of significant medication events via the caregiver app, calendar events, and other channels.
7. Core requirement: fit for forgetful elderly users.

## Summary

- Functional requirements: **22** (`FR-MSR-001` … `FR-MSR-022`), all MUST.
- Non-functional requirements: **10** (`NFR-MSR-001` … `NFR-MSR-010`), all MUST.
- Areas covered: Entry Model; Slot-to-Clock Mapping; Quantity & Dose Line; Purpose; Scan-to-Fill;
  Voice Acknowledgement (resolution, conservative disambiguation, copy discipline); Medication
  Safety Sequence; Recording & Adherence; Ack Vocabulary Guard; Voice Pipeline / Ack Fast Lane;
  Photo Evidence; Caregiver Notification (significant-event set, channels, honest delivery); Wire
  Discipline; Honesty / Delivery Integrity; Preserved Machinery; Elderly-Fit UX; Persistence &
  Recovery; Privacy (observability, on-device egress); Localisation (strings, spoken times,
  Devanagari pin); Accessibility; Reliability / Compatibility (migration); Quality / Compliance;
  Performance (firing latency).
- Settled decisions carried as requirements: slot-to-clock defaults 08:00 / 13:00 / 19:00,
  family-configurable (OD-1 → FR-MSR-002); structured quantity, amount + unit composed into the
  rendered dose line, double-dose detector semantics unchanged (OD-2 → FR-MSR-003); significant
  set = missed medication + possible double dose + intake recorded + escalation started, PII-free
  wire, transport scope honest (OD-3 → FR-MSR-015 / FR-MSR-016 / FR-MSR-017).
- Open decisions carried forward: **OD-4 … OD-8** remain for the design chain (`design-l1` /
  `design-l2`) with their boundaries — see the Open decisions section below. No owner-level
  decision is open.
- Completion: the recorded **DV-1 … DV-7** device-validation checklist on the reference device
  (Anzaan) at `final-sign-off`, plus the release log-safety gate (NFR-MSR-009) — see Gate
  traceability.

## Contents

- [define-requirements/index.md](define-requirements/index.md) — folder index (summary, areas, open
  decisions, out of scope)
- [define-requirements/FR/index.md](define-requirements/FR/index.md) — functional requirements (22
  files, `FR-MSR-001` … `FR-MSR-022`), with the traceability table to the source mandate
- [define-requirements/NFR/index.md](define-requirements/NFR/index.md) — non-functional
  requirements (10 files, `NFR-MSR-001` … `NFR-MSR-010`), with the safety-delta coverage table
- [define-requirements.lock.yaml](define-requirements.lock.yaml) — locked snapshot (per-requirement
  sha256 plus this document's snapshot hash; the drift-detection baseline)

Every requirement's full statement, rationale, traceability and Gherkin acceptance criteria live
in its own file under the folder; the sections below carry the per-requirement summary lines.

## Functional requirements

### FR-MSR-001: Slot-based entry model — quantity + time-of-day slot + before/after meal

**Area:** Entry Model · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-001-slot-based-entry-model.md](define-requirements/FR/FR-MSR-001-slot-based-entry-model.md)

The family-facing entry surface becomes quantity + time-of-day slot (morning / afternoon /
evening) + before/after-meal relation — not raw clock times (owner point 1); the family is never
required to compute or type a clock time, and the reminder clock time is derived by FR-MSR-002.
The revamp extends the shipped editor draft and does not relax its rules (blank-only text
pre-fill, the label's schedule wins, empty read changes nothing, save requires a name). Scenarios
cover a saved slot-model entry (no clock time requested), a nameless save being rejected, and the
draft rules holding.

### FR-MSR-002: Deterministic slot-to-clock mapping — 08:00 / 13:00 / 19:00 defaults, family-configurable

**Area:** Slot-to-Clock Mapping · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-002-deterministic-slot-to-clock-mapping.md](define-requirements/FR/FR-MSR-002-deterministic-slot-to-clock-mapping.md)

Every entry resolves to exact reminder clock times through a mapping that is deterministic and
total over the creatable entry space (safety delta (b)); no reminder may be armed without a
determinate hour/minute, and the acknowledgement deadline, re-fire schedule, escalation deadline
and missed-dose verdict all derive from the one resolved scheduled time. Defaults 08:00 / 13:00 /
19:00 (OD-1, resolved), family-configurable per household; the meal relation is context, not a
second clock. Scenarios cover default and reconfigured mappings (same inputs, same times) and the
failure rule: no determinate time means no armed reminder and a surfaced error.

### FR-MSR-003: Structured quantity — amount + unit composed into the rendered dose line

**Area:** Quantity & Dose Line · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-003-structured-quantity-dose-line.md](define-requirements/FR/FR-MSR-003-structured-quantity-dose-line.md)

Quantity is captured as a positive-integer amount plus a unit from a fixed set (tablet, capsule,
ml, teaspoon, drop, puff, sachet) with a custom free-text fallback; the rendered dose line that
the fired-dose screen, briefing and scanned-strength display already consume is composed from it,
so no downstream surface churns (OD-2, resolved). Free-text dose ("half tablet") remains
representable. Guard scenario: the double-dose detector keeps its entry-and-window-scoped
contract with no dose or quantity input; partial-vs-full-dose detection is out of scope.

### FR-MSR-004: Purpose at entry — a brief purpose description on every medication

**Area:** Purpose · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-004-purpose-at-entry.md](define-requirements/FR/FR-MSR-004-purpose-at-entry.md)

Each medication can carry a brief purpose description set at entry (owner point 2), built on the
shipped purpose field, chips, voice vocabulary and lookup — not a new mechanism. Whether purpose
is required-at-entry is design-level; either way no behaviour may depend on the purpose text being
present and pre-purpose payloads keep loading. Scenarios cover purpose selected from chips and
rendered, an entry without purpose behaving fully, and a legacy purpose-less payload loading.

### FR-MSR-005: Scan-to-fill — additive beside manual entry, bounded extraction

**Area:** Scan-to-Fill · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-005-scan-to-fill-additive.md](define-requirements/FR/FR-MSR-005-scan-to-fill-additive.md)

A camera scan of packaging/label fills the medication name (and strength) and the label's stated
schedule as candidate values, additive beside manual entry — a household that never scans keeps
today's exact manual path (owner point 3). Extraction is bounded by the conservative parser (name,
strength, schedule times, frequency guess), which refuses to guess; purpose is not scannable;
partial and failed reads are honest and non-destructive (blank-only fills, empty read changes
nothing and is spoken, the photo is never discarded). OD-4 (confirm-step and partial-fill details)
is carried to the design chain. Scenarios cover readable and partial reads, the untouched manual
path, and the honest empty read.

### FR-MSR-006: OCR values require human confirmation before binding — never silent auto-apply

**Area:** Scan-to-Fill / Safety · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-006-ocr-human-confirmation-before-binding.md](define-requirements/FR/FR-MSR-006-ocr-human-confirmation-before-binding.md)

OCR'd name/schedule values are candidates: nothing writes a schedule store on scan, and the entry
is created only by the family's explicit review-and-save; every new scan entry point must route
through the same gate (safety delta (a) — an OCR misread must cost a correction, never a dose).
Scenarios cover a corrected misread binding only after correction, no binding on an abandoned
scan, and the rejection of any silent auto-apply entry point.

### FR-MSR-007: Voice acknowledgement names the medication and slot — resolution by what was said

**Area:** Voice Acknowledgement · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-007-voice-ack-names-medication-and-slot.md](define-requirements/FR/FR-MSR-007-voice-ack-names-medication-and-slot.md)

The elder acknowledges in natural voice naming the medication and slot ("I have taken X for
morning before meal"), and the utterance resolves deterministically to the correct reminder and
entry by what the elder said — not by firing order or oldest-pending (owner point 4; the stated
motivation for the shared-slot case). Plain "taken"/"done" keeps working when the target is
unambiguous; ambiguity never resolves by guessing (FR-MSR-008). OD-6 (resolution mechanics and
interaction order) is carried to the design chain. Scenarios cover named resolution, the shared
slot resolving the named medication, the unambiguous simple acknowledgement, and the shared-slot
simple acknowledgement demanding clarification instead of a guess.

### FR-MSR-008: Conservative disambiguation — "did you mean X / X or Y" copy rule, never the wrong medication

**Area:** Voice Acknowledgement / Safety · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-008-conservative-disambiguation-copy-rule.md](define-requirements/FR/FR-MSR-008-conservative-disambiguation-copy-rule.md)

When several medications share a slot or the utterance is ambiguous, the system disambiguates
conservatively and deterministically and never records the wrong medication. Clarification uses
the owner's copy forms — "did you mean X / X or Y" — ONLY; no leading questions, no numbered
lists, ever. The unrecognised-path correction rescue and the acknowledgement vocabulary must
neither shadow nor be shadowed by each other. Scenarios cover the sanctioned clarification and
its affirmative resolution, determinism, a never-recorded unresolved utterance, and the
coexistence edge.

### FR-MSR-009: Acknowledgement safety sequence preserved — challenge, then double-dose check, then record

**Area:** Medication Safety Sequence · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-009-acknowledgement-safety-sequence.md](define-requirements/FR/FR-MSR-009-acknowledgement-safety-sequence.md)

Every acknowledgement — voice with slot or via the photo-evidence companion flow — flows through
the existing sequence in order and no new path may bypass it: acknowledgement → FR-D01
confirmation challenge → FR-D03 double-dose check → record. A "No" answer or a timeout does not
record and re-enters escalation (FR-D02 semantics); locale-aware prompts are preserved. Scenarios
cover the full sequence, denial, timeout, and the rejection of any design that would record
without the challenge.

### FR-MSR-010: Intake recorded against the day's schedule — scheduled time and acknowledged time

**Area:** Recording & Adherence · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-010-intake-recorded-against-schedule.md](define-requirements/FR/FR-MSR-010-intake-recorded-against-schedule.md)

Every acknowledged intake is recorded against the day's schedule as an adherence-log entry
carrying the entry reference, the reminder's scheduled time (the slot-mapped exact time of
FR-MSR-002) and the acknowledgement timestamp — the record the caregiver timeline (FR-D04 shape,
root FR-030) reads (owner point 4; the feature's observable success: the elder can answer what
has been taken and what has not, per slot). Only a fully confirmed dose records as taken; a
denial, timeout or fully escalated miss does not. Scenarios cover the record shape, per-slot
taken/not-taken answerability, and the never-recorded-as-taken failure case.

### FR-MSR-011: Refusal-first denial guard preserved — a denial never falls through to an acknowledgement

**Area:** Ack Vocabulary Guard · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-011-refusal-first-denial-guard.md](define-requirements/FR/FR-MSR-011-refusal-first-denial-guard.md)

Wherever the acknowledgement vocabulary is used, the denial-phrase guard runs first, and a denial
never falls through to an acknowledgement — including the new utterance shapes, clarification
answers and challenge answers. Scenarios cover a plain denial routed as a denial, a mixed
denial-with-ack-tokens utterance staying a denial, and "No" to the challenge never advancing the
sequence toward recording.

### FR-MSR-012: Mic continuity around acknowledgements — no gap between acknowledgement and listening

**Area:** Voice Pipeline / Ack Fast Lane · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-012-mic-continuity-around-acks.md](define-requirements/FR/FR-MSR-012-mic-continuity-around-acks.md)

Acknowledgements (including the new ack-with-slot and clarification utterances) play through the
ack fast lane so the microphone never closes, and listening resumes with no gap after the
acknowledgement; the fast-lane suite extends to the new shapes. Scenarios cover the mic staying
open, a challenge answer spoken immediately after the acknowledgement being captured, and a
mic-closing regression failing the suite.

### FR-MSR-013: Photo of the medication as intake evidence — augments, never replaces, never creates a record

**Area:** Photo Evidence / Safety · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-013-photo-evidence-augments-never-replaces.md](define-requirements/FR/FR-MSR-013-photo-evidence-augments-never-replaces.md)

A photo of the medication serves as intake evidence (owner point 5), augmenting and never
replacing the acknowledgement + confirmation chain (safety delta (c)): recording still happens
through the acknowledgement path; evidence attaches to a record, never creates one. Processing
stays on-device; the shipped photo-verification machinery exists but is NOT wired end-to-end —
the feature must not assume it works, and if evidence leaves the device it follows the existing
size-cap, end-to-end-encryption, retention-and-deletion discipline with no silent delivery
failure. OD-8 (mechanism and recipient) is carried to the design chain; removal of the dementia
mechanism is forbidden. Scenarios cover evidence attaching to a confirmed intake, a photo alone
record-creation attempt rejected, and the on-device guard.

### FR-MSR-014: Photo evidence resolves the shared slot deterministically — never the wrong medication

**Area:** Photo Evidence · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-014-photo-evidence-shared-slot-resolution.md](define-requirements/FR/FR-MSR-014-photo-evidence-shared-slot-resolution.md)

The driving case for photo evidence is the shared slot (owner point 5): evidence must resolve and
record against the correct slot and medication deterministically, with the same conservative
discipline as the voice path — on ambiguity the system asks (sanctioned copy) or declines to
bind, never guesses and never attributes evidence to the wrong medication; the record still flows
through the acknowledgement chain. OD-8 is carried to the design chain, bounded by these
properties. Scenarios cover determinate binding, ambiguity never attributed by guess, and
deterministic repeat resolution.

### FR-MSR-015: Significant-event notification set — missed dose, double-dose, intake recorded, escalation started

**Area:** Caregiver Notification · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-015-significant-event-notification-set.md](define-requirements/FR/FR-MSR-015-significant-event-notification-set.md)

Caregivers are always notified of significant medication events (owner point 6) — the resolved
significant set (OD-3): missed medication + possible double dose (already unconditional) + intake
recorded (new, unconditional) + escalation started (new, unconditional); the first-fire reminder
notification keeps its existing opt-in. Triggers live on the medication notification path, not
the general event-fire handler; send decisions resolve at fire time, never stored per event.
Scenarios cover each significant trigger and the fire-time-resolution failure guard.

### FR-MSR-016: Caregiver notification channels and honest per-contact delivery

**Area:** Caregiver Notification / Delivery Honesty · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-016-caregiver-channels-honest-delivery.md](define-requirements/FR/FR-MSR-016-caregiver-channels-honest-delivery.md)

Significant events reach caregivers across the channels as paths — caregiver app push, the
consent-gated family calendar, and the text channels derived from calling preference — with
honest per-contact results: partial delivery is reported as partial, never as success, and a
notification that could not be delivered is never reported as delivered. The trigger paths and
the calendar channel are this feature's scope; the end-to-end push transport remains inherited
tracked work and delivery claims are made only for what actually fires. OD-7 (calendar-channel
mechanism) is carried to the design chain within the consent gate and the honest-result rule.
Scenarios cover partial delivery honesty, not-delivered reporting, and the calendar consent gate.

### FR-MSR-017: PII-free wire — significant events extend the existing taxonomy with no new PII

**Area:** Wire Discipline / Safety · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-017-pii-free-wire.md](define-requirements/FR/FR-MSR-017-pii-free-wire.md)

Significant-event notifications extend the existing PII-free alert taxonomy (safety delta (d)):
the versioned envelope carries the alert type and timestamp, with the hashed entry identifier
where medication-level correlation is needed — no medication name, dose or household content.
Putting names or titles on the wire stays an explicit owner-level decision (the in-memory-title
rule), never smuggled in. Scenarios cover the type-only envelope, rejection of name/title
payloads, and the hash staying non-reversible for wire purposes.

### FR-MSR-018: Honest degradation — deferred capabilities surfaced as themselves, never a false success

**Area:** Honesty / Delivery Integrity · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-018-honest-degradation-deferred-capabilities.md](define-requirements/FR/FR-MSR-018-honest-degradation-deferred-capabilities.md)

No silent stubs: the unwired photo-verification machinery is surfaced as itself, an undelivered
notification is never presented as success, a failed persistence write surfaces and blocks its
dependent step, and delivery claims are limited to paths that actually fire (transport-dependent
statements are labelled inherited tracked work). Scenarios cover truthful photo-state reporting,
failed-delivery honesty, the persistence-failure block, and the claim-audit review guard.

### FR-MSR-019: Existing reminder and escalation semantics preserved — no weakening of medication safety invariants

**Area:** Preserved Machinery · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-019-existing-reminder-escalation-preserved.md](define-requirements/FR/FR-MSR-019-existing-reminder-escalation-preserved.md)

The revamp must not weaken the shipped reminder/escalation semantics (root FR-026 – FR-028): the
reminder names the medication; re-fires follow the shipped interval/count within the escalation
window; a fully escalated miss is marked, logged and alerted; a future dose stays future on
restore. The only change to the chain is that all derived instants come from the one resolved
scheduled time (FR-MSR-002) — any other derivation basis is rejected. Scenarios cover preserved
escalation on a slot-model entry, the future-stays-future restore edge, and the derivation-change
rejection.

### FR-MSR-020: Dementia machinery preserved and integrated — never rebuilt, never removed

**Area:** Preserved Machinery · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-020-dementia-machinery-preserved.md](define-requirements/FR/FR-MSR-020-dementia-machinery-preserved.md)

The dementia machinery is preserved and integrated — extension is the mode, removal is forbidden:
the FR-D01/D02 challenge stays the gate before recording, the FR-D03 detector keeps its contract,
the FR-D04a–e photo-verification components remain in place with their unwired state surfaced
honestly, and the emergency-call and health-monitoring modules plus Android stay untouched.
Decisions touching the challenge, detector or photo machinery run under the elevated confidence
threshold. Scenarios cover the components remaining on the paths, removal/bypass rejection, and
the elevated bar.

### FR-MSR-021: Elderly-fit UX of the new flows — voice-first completion, plain language, vocabulary limit

**Area:** Elderly-Fit UX · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-021-elderly-fit-ux-new-flows.md](define-requirements/FR/FR-MSR-021-elderly-fit-ux-new-flows.md)

Every new or revamped flow is fit for the forgetful elderly primary user (owner point 7): the
intake loop completes entirely by voice (or the provided photo capture) with no touch required;
copy is plain language with the sanctioned clarification as the only multi-part form; no new
command vocabulary beyond the established set; one idea per utterance; the unambiguous case adds
no extra step. Quantitative standards live in NFR-MSR-005; the Devanagari behaviour is pinned by
NFR-MSR-007. Scenarios cover the touch-free loop, the no-extra-step unambiguous case, the
vocabulary-limit rejection, and one-idea utterances.

### FR-MSR-022: Persistence before alarm and process-kill re-arm — the FR-029 invariant holds on the revamped paths

**Area:** Persistence & Recovery · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-MSR-022-persistence-before-alarm-and-rearm.md](define-requirements/FR/FR-MSR-022-persistence-before-alarm-and-rearm.md)

A reminder (with its resolved exact scheduled time) is persisted before the platform alarm is
armed; a failed write blocks arming and surfaces. An acknowledgement is durably stored
immediately on confirmation, before runtime cleanup. If the process is killed while a reminder is
outstanding and its escalation window is unexpired, the reminder re-fires on next launch and
escalation resumes from the remaining window time (root FR-029 / NFR-027). Scenarios cover the
persistence-before-alarm order, the kill-and-relaunch re-fire, the storage-failure block, and
immediate durability of the acknowledgement.

## Non-functional requirements

### NFR-MSR-001: LLM independence — the medication scheduler unit stays free of LLM dependencies

**Category:** Reliability · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-001-llm-independence.md](define-requirements/NFR/NFR-MSR-001-llm-independence.md)

The medication scheduler compilation unit has no dependency on the on-device language model;
reminder firing, escalation, the acknowledgement sequence and recording all operate with the LLM
busy, unavailable or not loaded, and a build/link symbol inspection finds zero LLM-inference
symbols in the unit. Root FR-009 and the shipped scheduler's safety invariant 1 preserved.

### NFR-MSR-002: PII-free observability — hash-only medication identifiers, sanitised logs

**Category:** Privacy / Security · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-002-pii-free-observability.md](define-requirements/NFR/NFR-MSR-002-pii-free-observability.md)

Every observability event and log line on the feature's paths carries the one-way hashed entry
identifier and categorical metadata only — no medication names, dose text, label text, photo
content or conversation content — with the log sanitiser applied and the release-build
log-surface gate covering the new paths. Measurable: zero PII tokens by audit; gate exits zero.

### NFR-MSR-003: On-device label and photo processing — no new cloud egress for medication content

**Category:** Privacy · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-003-on-device-no-new-egress.md](define-requirements/NFR/NFR-MSR-003-on-device-no-new-egress.md)

Medication label scanning and medication-photo evidence processing stay on-device; no label text,
label imagery or medication photos are transmitted to any cloud service, and the recorded cloud
exceptions (voice transcription; OCR'd-text translation) do not apply. The shipped purpose-lookup
medicine-name egress through the existing search stack is the stack's, under its existing
disclosure — not widened by this feature.

### NFR-MSR-004: Localisation and spoken times — every new string in Nepali and English, all spoken times through the formatter

**Category:** Localisation · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-004-localisation-and-spoken-time.md](define-requirements/NFR/NFR-MSR-004-localisation-and-spoken-time.md)

Every new or changed user-visible string exists in Nepali and English in the string catalogue (no
hard-coded strings), and every spoken time — mapped reminder times, acknowledgement times,
schedule rendering, notification copy — is produced through the mandated spoken-time formatter;
raw hour/minute interpolation into speech is forbidden. Measurable: 100 per cent of new keys in
both locales; zero formatter bypasses.

### NFR-MSR-005: Accessibility — 44pt targets, 18pt body text, contrast, voice-first acknowledgement

**Category:** Accessibility · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-005-accessibility-elderly-fit.md](define-requirements/NFR/NFR-MSR-005-accessibility-elderly-fit.md)

Every new or revamped touch surface meets the elder-fit standards: interactive controls at least
44 x 44 pt, body text at least 18 pt (system scaling not reduced below it), WCAG AA contrast
(4.5:1 body, 3:1 large/UI), and the intake loop completable by voice with zero touch. Measurable
by surface audit plus a voice-only walkthrough.

### NFR-MSR-006: Migration compatibility — legacy payloads keep loading, schedules are never lost to a missing key

**Category:** Reliability / Compatibility · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-006-migration-compatibility.md](define-requirements/NFR/NFR-MSR-006-migration-compatibility.md)

New model fields are optional with custom-decoder defaults; pre-revamp payloads (raw schedule
times, no quantity/slot/meal/purpose/visual-aids fields) load successfully, legacy schedule times
remain readable and representable, and entries keep working exactly as today until the family
edits them. A migration that drops or silently reinterprets a schedule element is a defect. OD-5
(legacy rendering; backfill) is carried to the design chain — the recorded safe default is no
automatic slot inference.

### NFR-MSR-007: Devanagari grapheme-cluster behaviour regression-pinned — do not "fix" it

**Category:** Localisation / Regression · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-007-devanagari-grapheme-regression-pin.md](define-requirements/NFR/NFR-MSR-007-devanagari-grapheme-regression-pin.md)

The shipped Devanagari substring and grapheme-cluster matching behaviour stays exactly as shipped:
the pinned regression tests pass unchanged, the matching implementation is untouched by the
feature, and a proposed "fix" is rejected (any such change needs an explicit owner decision
outside this feature).

### NFR-MSR-008: Safety-path test rigor — 100 per cent unit coverage, required integration tests, elevated confidence

**Category:** Quality / Compliance · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-008-safety-test-coverage-and-confidence.md](define-requirements/NFR/NFR-MSR-008-safety-test-coverage-and-confidence.md)

Every touched safety-critical medication path carries 100 per cent unit coverage plus the
required integration tests: persistence-before-alarm ordering, process-kill re-arm, LLM
independence, and the legacy-payload migration round trip. The scoped medication and notifier
suites are the honest gate (pre-existing baseline failures recorded separately); the release
log-surface check passes before any test scope. Confidence 0.85, elevated to 0.90 on decisions
touching the FR-D01 / FR-D03 / FR-D04a–b machinery; paired review on; max rework 5.

### NFR-MSR-009: Compliance and release gates — log-safety gate green, health-policy posture unchanged, honest baseline

**Category:** Compliance · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-009-compliance-and-release-gates.md](define-requirements/NFR/NFR-MSR-009-compliance-and-release-gates.md)

The release-build log-surface gate passes over the feature's new paths; the existing App Store
health-data posture (data collection and storage; health and health research) is unchanged with
no new health-data category, no new data collection, and any new permission requested at the
point of use with plain-language justification; PII-free telemetry keeps the standing
log-volume monitoring posture applicable; the verification report records the pre-existing
baseline failures separately from the feature's results.

### NFR-MSR-010: Reminder firing latency — the mapped clock time is the schedule of record

**Category:** Reliability / Performance · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-MSR-010-reminder-firing-latency.md](define-requirements/NFR/NFR-MSR-010-reminder-firing-latency.md)

The slot-mapped resolved time functions as the schedule of record: a medication reminder fires
within 30 seconds of its resolved scheduled time (root NFR-005 preserved), including for entries
created or edited shortly before the slot and for reminders re-armed after a relaunch; the
mapping introduces no fire-time resolution step that can delay or shift a reminder. A
mapping-related delay is a defect of this requirement.

## Open decisions carried forward

**OD-1 … OD-3 are RESOLVED** in the feature constitution (2026-10-15) and are carried by this set
as settled requirements — slot-to-clock defaults and family configurability (FR-MSR-002);
structured quantity with the composed dose line and unchanged detector semantics (FR-MSR-003);
the significant-event set, PII-free wire and transport scope honesty (FR-MSR-015 / FR-MSR-016 /
FR-MSR-017). They are not reopened here.

**OD-4 … OD-8 remain OPEN and belong to the design chain (`design-l1` / `design-l2`).** They are
choices inside the contracts this set fixes — not product questions — and are carried with their
boundaries:

| # | Decision (design-chain) | Bounded by |
|---|---|---|
| OD-4 | Scan-to-fill: confirm-step details, extraction-surface nuances, partial-fill behaviour | FR-MSR-005 (additive, bounded, non-destructive, refuses to guess), FR-MSR-006 (human confirmation before binding is fixed) |
| OD-5 | Legacy entries in the new model — rendering in the slot UI; whether any backfill (time-to-slot inference) happens at migration | NFR-MSR-006 (no loss; legacy times readable/representable; any re-interpretation deterministic, visible, family-directed; recorded safe default: no automatic inference) |
| OD-6 | Voice ack with slot — exact resolution mechanics and interaction order for the new utterance shapes | FR-MSR-007 (by what was said; simple acks keep working), FR-MSR-008 (conservative, deterministic, sanctioned copy), FR-MSR-009 (sequence order never bypassed) |
| OD-7 | Caregiver "calendar events" channel mechanism — existing schedule mirror vs. significant events as calendar entries vs. another shape; which events surface there | FR-MSR-016 (consent gate; honest results), FR-MSR-017 (no new PII on any channel) |
| OD-8 | Photo-as-evidence mechanism and recipient — reuse the existing photo-verification path once wired, an on-device-only variant, or an extension of the per-medication dementia mechanism; what the photo proves and who judges it | FR-MSR-013 (augments never replaces; never assumes the unwired machinery works; on-device; delivery discipline if it leaves the device), FR-MSR-014 (deterministic, conservative resolution), FR-MSR-020 (removal of the dementia mechanism forbidden) |

No owner-level decision is open after this pass.

## Traceability summary

| Source | Requirements |
|--------|--------------|
| Owner scope point 1 — slot-based entry model | FR-MSR-001, FR-MSR-002, FR-MSR-003 |
| Owner scope point 2 — purpose | FR-MSR-004 |
| Owner scope point 3 — scan-to-fill; manual as before | FR-MSR-005, FR-MSR-006 |
| Owner scope point 4 — voice ack with slot; recorded against the day's schedule | FR-MSR-007, FR-MSR-008, FR-MSR-009, FR-MSR-010, FR-MSR-011, FR-MSR-012 |
| Owner scope point 5 — photo as evidence; shared slot | FR-MSR-013, FR-MSR-014 |
| Owner scope point 6 — caregivers always notified | FR-MSR-015, FR-MSR-016, FR-MSR-017 |
| Owner scope point 7 — fit for forgetful elderly users | FR-MSR-021 (+ NFR-MSR-005) |
| Safety delta (a) — OCR never auto-binds | FR-MSR-006 |
| Safety delta (b) — deterministic slot-to-clock mapping | FR-MSR-002 |
| Safety delta (c) — photo evidence never creates a record | FR-MSR-013 |
| Safety delta (d) — PII-free wire | FR-MSR-017 |
| Root FR-026 – FR-028 (delivery, escalation, missed dose) | FR-MSR-019, FR-MSR-015 |
| Root FR-029 / NFR-027 (persistence, re-fire) | FR-MSR-022 |
| Root FR-030 / supplement FR-D04 (adherence view) | FR-MSR-010 |
| Supplement FR-D01 – FR-D03 (challenge, denial, double dose) | FR-MSR-009, FR-MSR-011, FR-MSR-020 |
| Supplement FR-D04a – FR-D04e (photo-verification machinery) | FR-MSR-013, FR-MSR-020 |
| LLM independence; PII-free observability; on-device processing | NFR-MSR-001, NFR-MSR-002, NFR-MSR-003 |
| Localisation, spoken times, Devanagari pin, accessibility | NFR-MSR-004, NFR-MSR-007, NFR-MSR-005 |
| Migration without loss | NFR-MSR-006 |
| Test rigor; compliance and release gates; firing latency | NFR-MSR-008, NFR-MSR-009, NFR-MSR-010 |

## Out of scope

- **Emergency-call and health-monitoring modules** — untouched by this feature.
- **Android** — deferred to v2; not reopened.
- **No weakening of any existing medication safety invariant** — reminder/escalation semantics,
  persistence-before-alarm, process-kill re-arm and the LLM-independence of the medication
  scheduler unit all remain binding (FR-MSR-019, FR-MSR-022, NFR-MSR-001).
- **No removal of the existing dementia machinery** — confirmation challenge, double-dose
  detection and photo-verification components are integrated and extended, never rebuilt or
  removed (FR-MSR-020).
- **No new cloud egress for medication content** — label/photo processing stays on-device; the
  recorded cloud exceptions (voice transcription; OCR'd-text translation) do not apply to this
  feature (NFR-MSR-003).
- **No new PII on the caregiver wire** — the title/name-on-wire question stays an explicit
  owner-level decision (FR-MSR-017).
- **Devanagari substring/grapheme-cluster behaviour** — regression-pinned; not "fixed"
  (NFR-MSR-007).
- **Partial-vs-full dose detection** — out of scope; the double-dose detector's semantics are
  unchanged (FR-MSR-003).

## Gate traceability

| Gate (feature workflow) | What it consumes from this set |
|---|---|
| `design-l1` / `design-l2` | Resolve OD-4 … OD-8 inside the contracts: the entry model + slot-to-clock mapping with the determinism/totality property and the family-configurable control (FR-MSR-001/002); the quantity representation and dose-line composition (FR-MSR-003); scan-to-fill confirm step and partial-fill rules (FR-MSR-005/006); the ack-with-slot vocabulary and resolution mechanics with the by-what-was-said discipline (FR-MSR-007/008/011/012); the photo-evidence mechanism and its delivery decision (FR-MSR-013/014, OD-8); the calendar-channel mechanism (FR-MSR-016, OD-7); the notification seams and honesty boundaries (FR-MSR-015/016/017/018); migration and legacy rendering (NFR-MSR-006, OD-5). |
| `review-l2` | `review.decision == GO` against the component design and this set, including the safety-sequence no-bypass property (FR-MSR-009) and the preserved escalation semantics (FR-MSR-019). |
| `plan-tasks` / `implement` | Units trace back to `FR-MSR-*` / `NFR-MSR-*` ids; paired review and the 0.85 confidence threshold on implementation output (0.90 on FR-D01/D03/D04a–b-touching decisions); the coverage and integration-test obligations (NFR-MSR-008); migration tests ride with the model change (NFR-MSR-006). |
| `review-implementation` | `review.decision == GO` over the implementation against this set — including the honesty properties (FR-MSR-018) and the PII-free paths (FR-MSR-017, NFR-MSR-002). |
| `final-sign-off` | T2 + HIL; the recorded DV-1 … DV-7 device-validation checklist on the reference device (Anzaan): DV-1 slot entry + mapped fire (FR-MSR-001/002); DV-2 scan confirm, honest partial read (FR-MSR-005/006); DV-3 voice ack with slot resolving the shared slot, sequence order preserved (FR-MSR-007/008/009); DV-4 photo evidence attaching on-device, never creating a record (FR-MSR-013/014); DV-5 significant events firing with the consent-gated calendar channel and no PII on the wire (FR-MSR-015/016/017); DV-6 process-kill re-arm within the unexpired window (FR-MSR-022); DV-7 elderly-fit 44pt+/18pt+/voice-first and spoken times via the formatter only (FR-MSR-021, NFR-MSR-004/005). Release gate: `ios/tools/check-release-log-safety.sh` exits 0 (NFR-MSR-009). |

## Assumptions recorded during this requirements pass

- The constitution's Integration Surfaces are taken as verified ground truth for this pass
  (verified against master `261aa862`, 2026-10-15); file/line anchors are orientation, not
  contracts, and no capability claim in this set goes beyond those verified statements or the
  read-only source documents.
- Numeric thresholds are inherited, not invented: the 30-second firing envelope is root NFR-005;
  the 44 pt / 18 pt / contrast figures are root NFR-020–NFR-022 and the feature house rule; the
  size-cap and retention figures for photo evidence belong to the FR-D04b discipline referenced by
  FR-MSR-013. No new numeric target was fabricated.
- The contract shapes deliberately left unspecified are design-level and are carried as OD-4 …
  OD-8: the confirm-step and partial-fill details; legacy rendering and any backfill; the ack
  resolution mechanics and interaction order; the calendar-channel mechanism; the photo-evidence
  mechanism and recipient. Each is bounded by the requirement(s) named in the Open decisions
  table.
- The `PhotoVerifier` unwired state and the stub push transport are treated as facts (per the
  constitution's verified notes): the set encodes honesty obligations around them (FR-MSR-013,
  FR-MSR-016, FR-MSR-018) rather than assuming delivery.
- The project's known pre-existing full-bundle test failures remain the recorded baseline; the
  feature's own and touched suites are the honest gate (NFR-MSR-008, NFR-MSR-009).
- The HIL gate record (gate `bedf72fc`, approved from Slack by owner `U0C6DTHDMV0` on
  2026-10-14T22:22:30Z) is the approval basis for the feature story; the T2 human gate sits at
  `final-sign-off`.

## Related

- Structured set: [`define-requirements/index.md`](define-requirements/index.md) ·
  [`define-requirements/FR/index.md`](define-requirements/FR/index.md) ·
  [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md)
- Locked snapshot: [`define-requirements.lock.yaml`](define-requirements.lock.yaml)
- Feature constitution (source mandate):
  [`specs/medication-schedules-reminders/constitution.md`](medication-schedules-reminders/constitution.md)
- Feature workflow: [`specs/medication-schedules-reminders/workflow.yaml`](medication-schedules-reminders/workflow.yaml)
- Project constitution: [`constitution.md`](../constitution.md)
- Read-only inputs: [`requirements.md`](../requirements.md) (`FR-026`–`FR-030`),
  [`requirements-dementia-supplement.md`](../requirements-dementia-supplement.md) (`FR-D01`–`FR-D04e`)
- Shipped scheduler architecture:
  [`docs/medication-scheduler-implementation-plan.md`](../docs/medication-scheduler-implementation-plan.md)
