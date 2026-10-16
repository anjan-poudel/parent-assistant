# Medication Schedules & Reminders — feature details, user instructions, and test guide

Owner brief: 2026-10-15. Feature: `medication-schedules-reminders` (ai-sdd). Constitution: `specs/medication-schedules-reminders/constitution.md`. Task plan: `specs/plan-tasks/plan.md` (22 units, 8 waves).

## 1. What changed and why

The old medication flow asked for raw clock times and free-text doses. Elderly users don't think in clock times — they think "1 tablet, morning, before food". This feature rebuilds the entry model and the intake-acknowledgement flow around that mental model, and makes caregiver notification of significant medication events real.

**New entry model** — every medication is now described as:

| Field | Options |
|---|---|
| Quantity (amount + unit) | tablet, capsule, ml, drop, puff, sachet, teaspoon — or your own unit |
| Time of day (slot) | Morning / Afternoon / Evening |
| Meal relation | Before food / After food (spoken with every reminder) |
| Purpose (what it's for) | Blood pressure, Diabetes, Heart, Breathing, Pain, Sleep, Stomach, Antibiotics, Vitamins, Other — or your own words |
| Name + box photo | Manual entry, or **Scan label** (on-device OCR of the packaging) |

**Slot → clock mapping (deterministic).** The safety engine needs exact times, so each slot maps to a clock time: Morning 08:00, Afternoon 13:00, Evening 19:00. "Before/after food" is context attached to the slot (spoken and shown), not a second clock. The family will be able to change the per-household mapping in Settings (see §4 — that settings section ships in PR #2).

**Voice acknowledgement by name and slot.** The elder says what they took in natural language — e.g. "I took the blood-pressure medicine for morning before food" — and the app resolves it to the exact reminder, even when several medications share a slot (with a conservative "Did you mean X?" / "Did you mean X or Y?" clarification, never a guess). The existing safety sequence is unchanged: acknowledgement → confirmation challenge → double-dose check → recorded.

**Photo as evidence.** A photo of the medication attaches to the intake record (on-device), so the elder can identify which medicine at a shared slot by photographing it instead of naming it. Evidence augments, never replaces, the acknowledgement chain. (Capture UI ships in PR #2; the on-device evidence store is already in.)

**Caregiver notification.** Significant medication events always notify the family: missed dose, possible double dose, intake recorded, escalation started — via the consent-gated family calendar (live) and the caregiver app push path (honest-status until the E2E channel lands — see constitution Caregiver Notification 6). The wire stays PII-free (`{alert_type, timestamp}` — no medication names on the wire).

## 2. Ship state

| Piece | State |
|---|---|
| Waves W0–W4 (entry model, editor surface, scan-to-fill, ack resolver, save plumbing, scheduler event triggers, guarded re-arm, honest push transport, calendar writes) | **Merged to master via PR #228 (2026-10-15); installed on Anzaan, Amrit-1, Amrit** |
| Waves W5–W7 (evidence hold + finalize, slot-clock settings section, evidence capture surfaces + "Taken today", integration tests + full suite) | On `feat/medication-schedules-reminders`; PR #2 after the W7 full suite is green |
| Legacy entries | Keep working exactly as before (migration-safe decode); they convert to the slot model when the family edits them |

**What this means for testing today:** everything in §3 works on the installed build EXCEPT the slot-clock settings section (defaults 08:00/13:00/19:00 are fixed until PR #2) and the intake photo-evidence capture surface (box photos via visual aids still work).

## 3. User instructions

### 3.1 Family/caregiver — adding a medication

1. Open **Settings → Medications** (the medications manage list).
2. Tap **add**. You can either:
   - **Scan label** — point the camera at the packaging. The app reads the name (and schedule if printed, e.g. a "1-0-1" pattern). OCR values are *advisory*: review them on the form before saving — nothing binds until you save. A partial/failed read changes nothing and says so.
   - **Type manually** — as before.
3. Fill the form: **Amount + Unit** (e.g. 1 tablet), **slot** (Morning/Afternoon/Evening), **before/after food**, **What is it for?** (chip or your own words), and the dose line renders as composed text.
4. **Save** — one slot row becomes one reminder; multiple slots = multiple rows/entries.
5. The reminder fires at the slot's mapped clock time (08:00 / 13:00 / 19:00 until the settings section ships).

### 3.2 Elder — day to day

- At the slot time the app announces the medication (name, dose, slot, before/after food, purpose) and asks "Did you take your medication?"
- Acknowledge by voice: **"I took my medicine"**, or name it — **"I took the blood-pressure medicine for morning before food"** (Nepali equivalents work the same way).
- The app then confirms ("Did you take your X just now?"), checks for a double dose, and records the intake against the day's schedule.
- If the name is ambiguous ("I have two. Which one?"), the app asks — it never guesses.
- Denials stay denials: "No, not yet" re-enters the reminder escalation; a missed dose escalates to the family.
- **"Taken today"** (in PR #2) will show the day's recorded intakes at a glance — the forgetfulness-fit answer to "what have I taken and what have I not".

### 3.3 Caregiver — what you get notified about

| Event | Channel |
|---|---|
| Missed dose (after re-fires + escalation window) | Family calendar event + caregiver push path |
| Possible double dose (same med re-acked inside its window) | Family calendar event + caregiver push path |
| Intake recorded | Family calendar event + caregiver push path |
| Escalation started (dose at risk) | Family calendar event + caregiver push path |
| First reminder of the day | Opt-in only (existing `eventReminder` setting, defaults OFF) |

Calendar delivery requires the existing consent-gated calendar share to be on. The push transport reports per-contact outcomes honestly; the end-to-end push channel is tracked work (`docs/family-notifier-e2e-implementation-plan.md`) — this feature never claims a delivery that didn't happen.

## 4. Step-by-step test guide (device)

Devices with the W0–W4 build: **Anzaan** (14 Pro Max), **Amrit-1** (17 Pro Max), **Amrit** (11 Pro Max — unlock first). Best done on Anzaan.

> **Tip for testing reminder firing without waiting hours:** add a medication a few minutes before the next slot boundary — e.g. at ~12:55 add one with slot **Afternoon**; it fires at 13:00. Morning = 08:00, Afternoon = 13:00, Evening = 19:00.

**T-1. Slot-based entry (DV-1)**
1. Settings → Medications → add. Enter "Amlodipine", amount **1**, unit **tablet**, slot **Morning**, **Before food**, purpose **Blood pressure**. Save.
2. Confirm the entry shows quantity + slot + before-food + purpose (not raw clock times), and the dose line reads "1 tablet".
3. Repeat with a second medication on the same slot (e.g. "Metformin", Afternoon, After food, Diabetes) — used in T-3.

**T-2. Scan-to-fill (DV-2)**
1. Add → **Scan label** → photograph a medication box that has a printed schedule (or plain name).
2. Confirm the form pre-fills ONLY what was read, nothing binds without Save, and a partial/failed read says so and keeps the photo.
3. Purpose is never read from the label — it's the chip/typing path.

**T-3. Voice ack with shared slot (DV-3)**
1. At a slot boundary with both medications pending, say **"I took the blood-pressure medicine for morning before food"**.
2. The app must resolve to Amlodipine (not Metformin), run the confirmation challenge ("Did you take your Amlodipine just now?"), check double-dose, then record.
3. Now say the same phrase again within the double-dose window (default 4h): the app must BLOCK it as a possible double dose and notify the family (calendar event) — never a second record.
4. Say **"No"** at a challenge: nothing is recorded and the reminder stays in escalation.

**T-4. Missed-dose escalation + caregiver notification (DV-5, partial)**
1. With a caregiver calendar share on, let a slot reminder go unacknowledged through its re-fires (ack window 5 min, re-fires at +12/+24/+36/+48/+60 min, then MISSED).
2. Confirm the family calendar gets the missed-dose event, and the app-side trigger fires `missedMedication` with no medication name on the wire.

**T-5. Process-kill re-arm (DV-6)**
1. Let a reminder fire, do NOT acknowledge, force-quit the app, relaunch.
2. The reminder must re-fire on launch (within the unexpired escalation window).

**T-6. Elderly-fit + migration (DV-7 + NFR-MSR-006)**
1. Confirm the new surfaces respect 44pt+ targets, 18pt+ body, and every spoken time goes through the `SpokenTime` formatter.
2. Confirm pre-existing medications (created before this update) still load and remind as before, and convert to the slot model when edited.

**T-7. Legacy-entry conversion (NFR-MSR-006)**
1. Pick an old medication with raw times (e.g. 08:00) → edit → save. It must convert to the slot model without losing its schedule, visual aids, or purpose.

**T-8. (PR #2) Slot-clock settings + photo evidence + "Taken today"**
1. Settings → Medications → **medicine times**: change Morning to 07:30; confirm re-arm (`SlotClockRearmReport`), and the next reminder fires at 07:30.
2. At a shared-slot pending dose, take a photo as evidence: it must attach to the intake record (on-device), never create a record by itself.
3. "Taken today" shows the day's recorded intakes.

**Expected-failure honesty:** the push transport is a stub today — a notification decision is reported per-contact with its real outcome; do not treat "trigger fired" as "delivered". Photo-evidence capture and the slot-clock settings section do not exist in the W0–W4 build; do not test them against it.

## 5. Verification status

- W0–W4: each wave closed with a green consolidated build + scoped (-only-testing) pass; merged PR #228 with the L10n union conflict resolved and re-verified (`L10nCatalogCoverageTests` green on the merged tree — 1,483 keys).
- W5–W7: code+typecheck per unit (owner-stripped cadence); the single test gate is the W7 full-suite run against the documented baseline.
- Release gate: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) must exit 0 — it runs ahead of every test scope.
