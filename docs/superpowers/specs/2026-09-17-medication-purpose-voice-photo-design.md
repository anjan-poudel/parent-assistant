# Design: Medication Purpose Field + Voice Photo Query (PR 1)

**Date:** 2026-09-17
**Status:** Approved (brainstorming session; user decisions recorded below)
**Scope:** PR 1 of 2 — purpose field + voice "what does it look like" photo query. PR 2 (camera/OCR add-flow + web "what it's for" lookup) follows its own brainstorm cycle.

## 1. User decisions

1. **Scope:** two PRs — A+B (this one) first; C+D (OCR + web lookup) second.
2. **Purpose picker:** 10 common chips + free text (blood pressure, diabetes, pain, heart, sleep, stomach, breathing, vitamins, antibiotics, other).
3. **Voice approach:** A1 — deterministic keyword rule (immune to encoder/band/calibration, same pattern as the festival-date rule).
4. Voice matches by medication NAME **or** purpose keyword ("pressure medication" is a purpose word, not a name).

## 2. Model

- `MedicationEntry.purpose: String?` — optional-field migration pattern (custom decoder default nil; pre-field payloads load fine). Stored as the localized chip id for chips, raw text for free text — a single `String?`, no enum (an enum would make "other" text a second field and break the unversioned-store migration rule).

## 3. Editor (`MedicationScheduleSettingsView`)

- New purpose step: 10 chips (रक्तचाप / चिनी / दुखाइ / मुटु / निद्रा / पेट / सास फेर्न / भिटामिन / एन्टिबायोटिक / अन्य, with English labels), plus a free-text field always editable (chips prefill it; free text overrides). en+ne L10n keys.
- Med list rows: name + purpose caption (+ existing thumbnail when the visual-aid store has one).

## 4. Voice rule (`.medicationPhoto`)

- `KeywordIntentRule`: new domain + rule — query lexemes ("कस्तो देखिन्छ", "कस्तो छ", "looks like", "what does … look like", "kun ho", "कुन हो" — the family that asks for identification) AND (medication name token/phrase from the scheduler's entries OR purpose keyword from the chip vocabulary).
- CommandRouter routes the match to a new coordinator seam `showMedicationPhoto(entryId:)`:
  - exactly one match → present the existing full-screen medication photo overlay (name + purpose in the caption);
  - multiple matches → speak the names, show the first that has a photo;
  - no photo → honest line: "I don't have a photo of that yet — you can add one in the medication settings."
- The rule reads the CURRENT medication entries + purposes at match time (dynamic groups like the festival/app rules), never a fixed table — a med the elder has is a med that can be asked about.

## 5. Fire-time overlay

- `MedicationVisualAidFireHandler` / overlay caption gains the purpose when present ("रक्तचापको औषधि — अम्लोडिपिन").

## 6. Tests

- `MedicationEntry` purpose decode/migration round-trip.
- Editor: chip selection ↔ free-text prefill/override (model-level helper where feasible).
- Rule matrix: name match, purpose match, multi-match, no-match, query-without-name (no fire).
- Coordinator seam: single/multi/no-photo outcomes (recorder-based).
- Overlay caption with/without purpose.

## 7. Execution

- Worktree `worktree-med-purpose`, direct implementation; `./build.sh generate` + targeted `-only-testing` suites (KeywordIntentRule, MedicationScheduler/Models, editor-related, fire-handler) before PR; merge via PR; Anzaan smoke test: set a purpose on a med → ask "रक्तचापको औषधि कस्तो छ?" → photo shows with caption; med without photo → honest line.
