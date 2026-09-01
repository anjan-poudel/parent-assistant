# UI/UX Revision + Intents Pass — Design Spec

**Date:** 2026-09-02
**Status:** Approved (design review: user, 2026-09-02)
**Scope:** iOS only (native SwiftUI). Parallel to the in-progress STT model fine-tune.

## 1. Context

The STT model (distilled Whisper small Nepali) is being fine-tuned and will take a day
or more. Meanwhile the iOS MVP's UI (`ios/ElderlyAssistant/App/ContentView.swift`) is a
debug scaffold: a scroll view with a status row, a developer-style model-download list,
a small "Talk to Assistant" button, and caption-sized fonts — several violations of the
constitution's accessibility standards (NFR-021: 44pt targets, 18pt body text,
high-contrast). The 2026-08-30 deep review (`docs/review-2026-08-30.md`) confirmed the
UI was never designed, only wired.

This spec covers two parallel tracks that need no voice pipeline:

- **Track A — UI/UX revision:** Home screen redesign, first-run onboarding, Settings
  screens, and the design-language foundations (state machine, localization, tokens).
- **Track B — Intents:** expanding the LLM intent layer (catalog, grammar, entities,
  golden Nepali corpus) plus the interpreter safety fixes from the review.

Voice-dependent work (enrolment, wake word, TTS linking) is explicitly out of scope.

## 2. Decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| D1 | App structure | Hub & Spoke: Home with 4 giant single-purpose cards, single-purpose detail screens, huge back buttons. No tabs, no gestures. |
| D2 | Onboarding | 4-step skippable wizard; skipped steps surface as a Home reminder card. |
| D3 | Language | Single active language at a time (no dual-line bilingual UI). **Nepali is the pilot language.** English ships as a fallback/development language. Architecture must support adding further Asian regional languages via a String Catalog only. |
| D4 | Visual style | "Warm & Soft": cream background, deep green accent, serif display type for greetings, rounded corners, soft shadows, Light appearance. |
| D5 | Home layout | Hero Talk button centre-stage with status line; greeting top; latest conversation card; setup-reminder card; 2×2 hub cards bottom. |
| D6 | Talk button | Driven by a `VoiceSessionState` state machine; every state binds localized Nepali strings (button label + status line) and appearance (color/ring). |
| D7 | Settings | 4 sections: Language & region, Family & emergency contacts, Medication schedule editor, Privacy policy & about. |
| D8 | Intent scope | Safety core + daily helpers: `ack_med`, `emergency`, `call` (auth-gated), `set_reminder`, `health_query`, `music` (bhajan/song), plus fallbacks `query`/`none`. |

## 3. Design foundations

### 3.1 Design tokens

All views consume shared tokens (a `DesignTokens`/theme helper), not per-view literals:

- Colors: background `#FAF3E9`, card `#FFFFFF`, accent (deep green) `#2A7F62`,
  text primary `#3D2F24`, text secondary `#8A7562`, listening amber `#C77F2A`,
  transcribing tan `#8A6D3B`, understanding plum `#5C5A8A`, error red.
- Type: body ≥18pt, captions ≥15pt (replaces current 10–12pt caption fonts), serif
  (New York/Georgia-style) for greeting display, system sans for the rest.
- Shape: card corner radius 12–14pt; Talk button a full circle ≥120pt diameter.
- Spacing: minimum 44×44pt tap targets everywhere; at least 8pt between interactive
  elements.
- Contrast: all text/background pairs meet WCAG AA (≥4.5:1 for body text).
- Dynamic Type: all text scales with Dynamic Type; layouts must not truncate at
  accessibility sizes.

### 3.2 Localization architecture (multi-lingual invariant)

- All user-facing strings live in `Localizable.xcstrings` with language-agnostic keys.
  No hardcoded user-facing text in Swift files — this includes the spoken assistant
  strings currently inline in `CommandRouter.swift` and the English notification
  titles/bodies (NFR-023/24).
- Active language is a single value (`AppLanguage` enum, persisted in UserDefaults).
  Switching re-binds every visible string immediately via a custom environment key
  (e.g. `\.appLanguage`) read by all views; the system `.locale` environment is not
  overridden.
- Nepali (`ne`) is the pilot and default. English (`en`) ships as secondary. Adding a
  language later = adding entries to the catalog; no code changes.
- Number/date formatting uses the active locale (`ne-NP` today).

### 3.3 `VoiceSessionState` state machine

A dedicated enum drives the Talk button and status line. It wraps — not duplicates —
`VoicePipeline.State`:

```
idle → listening → transcribing → understanding → speaking → idle
idle → awaitingConfirmation → (yes/no/timeout) → idle
any → error → idle            (after ack/re-prompt)
idle → stopped → idle         (voice disabled)
```

- Explicit `canTransition(to:)`; illegal transitions assert in debug, no-op in release.
- Per state, bound from the catalog: button label, status line, color, ring animation.
  Nepali defaults:

  | State | Button | Status line |
  |-------|--------|-------------|
  | idle | बोल्नुहोस् | तयार छु |
  | listening | सुन्दै छु… | बोल्नुहोस्, म सुन्दै छु |
  | transcribing | लिख्दै छु… | भर्खरै सुनें, लेख्दै छु |
  | understanding | बुझ्दै छु… | के भन्नुभयो, बुझ्दै छु |
  | speaking | बोल्दै छु | सहायकले जवाफ दिँदैछ |
  | awaitingConfirmation | हो / होइन | औषधि खानुभयो? (challenge prompt) |
  | error | फेरि प्रयास गर्नुहोस् | माफ गर्नुहोस्, फेरि भन्नुहोस् |
  | stopped | आवाज बन्द | आवाज बन्द छ |

- `awaitingConfirmation` shows **yes/no chips** (हो / होइन, ≥60pt tall) instead of
  relying on voice alone; it carries the C12 fix: a timeout (default 45s, configurable)
  clears `pendingConfirmationEntryId` in `AppCoordinator`, speaks a notice
  ("समय सकियो, फेरि सम्झाउँछु"), and returns to `idle`.
- The state machine owns a single `@Published` value; all mutations happen on the main
  actor, addressing H1 (background-publish races) for the UI surface.

## 4. Screens

### 4.1 Home

Top to bottom (priority layout; only the conversation card scrolls if needed on small
devices):

1. Greeting: time-based, e.g. "नमस्ते, ७:३० बजे" (शुभ प्रभात / नमस्ते / शुभ रात्री by
   time of day), serif display.
2. Pending-setup reminder card (only when onboarding steps were skipped):
   "अझै २ काम बाँकी" + one tap opens the wizard at the first incomplete step.
3. Hero Talk button (D5/D6) with status line beneath.
4. Latest conversation card: last user utterance + assistant reply as bubbles
   (user: light green `#E6F1EC` left; assistant: accent green right). Shows the last
   exchange only on Home; full history lives on the Meds/Reminder-independent
   "conversation" detail if ever needed — out of scope this pass.
5. 2×2 hub cards: औषधि (Meds), सम्झना (Reminders), फोन (Call), सेटिङ (Settings).
   Each card ≥100pt tall, icon + label only, whole card is the tap target.

### 4.2 Onboarding wizard (D2)

Four steps, each: title, plain-language body, one primary action, "छाड्नुहोस्" (Skip)
in the top-right, back arrow top-left. Progress dots at the bottom.

1. **भाषा** — single-select language cards (नेपाली preselected, English secondary).
2. **अनुमति** — microphone and notifications, each with plain-language explanation
   ("आवाज फोनबाट बाहिर जाँदैन") and a big "दिनुहोस्" button that triggers the system
   prompt. Denied permission → inline guidance "सेटिङबाट खोल्नुहोस्" with the steps.
3. **परिवारको सम्पर्क** — name, phone number, relationship fields (≥60pt tall), one
   contact required to proceed, "राख्नुहोस्" saves encrypted.
4. **तयारी** — model download progress (reuses `ModelDownloadService`, restyled),
   "घर जानुहोस्" proceeds regardless of download state.

- Completion stored in an `OnboardingState` (UserDefaults-backed): per-step
  completed/skipped flags + a `hasSeenOnboarding` flag.
- The wizard runs before `AppCoordinator.start()` engages voice; skipped steps do not
  block Home.

### 4.3 Detail screens (Hub & Spoke leaves)

- **Meds (औषधि):** today's dose list with taken/pending state per reminder; a big
  "लिएँ" (I took it) button per pending dose → `acknowledgeWithConfirmation` path.
- **Reminders (सम्झना):** today's upcoming reminders, plain list.
- **Call (फोन):** fail-closed placeholder: explanation that calls need secure
  authentication, which is coming ("सुरक्षित प्रमाणीकरण तयार भएपछि फोन गर्न मिल्नेछ").
- **Settings (सेटिङ):** see §4.4.

Each leaf has a huge back button (top-left, ≥44pt) and a single-purpose layout.

### 4.4 Settings (D7)

1. **भाषा र क्षेत्र** — single-select language list (नेपाली, English). Region shown,
   not yet editable (ne-NP fixed for now).
2. **परिवारको सम्पर्क** — 1–3 contacts (name, relationship, phone). Stored via
   `KeychainEncryptedStorage` (Data Protection Complete, constitution §Security).
   Today `APNsFamilyNotifier` is constructed with `contacts: []`; this section makes
   the list real and feeds the notifier.
3. **औषधि तालिका** — view/edit medication names and times through the existing
   scheduler storage (`MedicationScheduler`'s `EncryptedLocalStorage` entries).
   Validation: non-empty name, valid times, no duplicate (name, time) pairs. Changes
   call `medicationScheduler.scheduleAll()` to re-arm.
4. **गोपनीयता** — privacy policy text (plain-language Nepali; states what stays
   on-device) + app version/about (NFR-032).

### 4.5 Model downloads

The existing `ModelDownloadSection` moves off Home. It appears only in onboarding
step 4 (तयारी) and as a Settings sub-entry; restyled to the Warm & Soft tokens with
large progress rows.

## 5. Intents track

### 5.1 Catalog

| Intent | Trigger examples (Nepali) | Action |
|--------|---------------------------|--------|
| `ack_med` | "औषधि खाएँ", "मैले औषधि लिइसकें" | Existing challenge → ack flow |
| `emergency` | "साहयता चाहियो", "इमर्जेन्सी" | Route to the safety path with **no auth gate** (constitution: emergency must never be blocked by auth or a busy LLM). Today that means spoken acknowledgement + observability emit + local alert, because the broker relay and emergency-call module don't exist yet (§9). |
| `call` | "छोरालाई फोन गर" | Blocked with spoken reason until voice auth lands (current behaviour, retained) |
| `set_reminder` | "बिहान ८ बजे औषधि खान सम्झाउनु" | Create a reminder entry via scheduler storage |
| `health_query` | "मेरो प्रेसर कति छ" | Answer from HealthKit when available; spoken "not available yet" fallback this pass |
| `music` | "भजन बजाउनुस्", "गीत चलाउ" | Spoken-ack stub (playback integration out of scope) |
| `query` | "भोलि मौसम कस्तो" | LLM-generated reply (existing behaviour) |
| `none` | chit-chat | LLM reply |

### 5.2 Grammar + entities

- Extend `LlamaGrammar.commandJSON` (and the paired `RawCommand` Codable) to cover the
  catalog above; enforce it at inference time (currently defined but never passed to
  the sampler — review H2).
- Entity extraction: `time` (Nepali expressions "बिहान ८ बजे", "दिउँसो", "अब"),
  `contact` (name), `medication` (name matched against the scheduler's med list when
  available). Entities are fields on `InterpretedCommand`; the `set_reminder` handler
  resolves a fuzzy time string via a small `NepaliTimeParser` (pure, unit-testable).
- Input sanitiser runs on the transcript before every LLM call (H3/NFR-013,
  `sanitise(.quarantine)`).
- LLM inference gets a timeout (configurable, default 10s) — on timeout, router falls
  back to keyword matching (H2).
- Remove PII leaks while in these files (C9): drop `postDebugNotification` with raw
  transcripts and the 160-char LLM output preview from the observability metadata.

### 5.3 Golden corpus

A `Tests`-embedded fixture set: 15–25 Nepali utterances per intent, including
code-switched and dialectal variants, each labelled `intent` + `entities`. Used by:

- unit tests for the parser (with the LLM mocked),
- later, eval of the fine-tuned STT + interpreter together (slow/nightly).

The corpus is a test fixture, not a shipped asset.

### 5.4 Routing order (unchanged)

LLM interpreter first (when available and confident ≥0.7), then the keyword fallback
(the safety net for safety-critical vocabulary — retained as-is per the existing
design), then "माफ गर्नुहोस्, मैले बुझिनँ" re-prompt.

## 6. Data flow

- `AppCoordinator` remains the composition root and owns all services. It gains:
  `AppLanguage` (published), `OnboardingState`, and exposes `VoiceSessionState` to the
  UI. `ContentView` becomes a thin host: it picks Home vs Onboarding wizard from
  `OnboardingState.hasSeenOnboarding`.
- Voice pipeline publishes `VoicePipeline.State`; a small adapter maps it onto
  `VoiceSessionState` (the single place that knows both enums).
- Settings writes go through existing stores: contacts → `KeychainEncryptedStorage`;
  med schedule → scheduler storage; language/onboarding → UserDefaults.
- No new networking, no cloud calls (constitution constraint 1).

## 7. Error handling

- Permission denied (mic/notifications) → wizard shows plain-language fix instructions;
  app remains usable (voice off state).
- Download failure → retry button on the तयारी step and on the Home reminder card.
- Voice error → `error` state (red), spoken re-prompt; `onSTTError` messages are
  localized instead of raw strings.
- `awaitingConfirmation` timeout → spoken notice + return to idle (C12).
- Language switch mid-flight → all bound strings re-render; in-progress spoken replies
  are not re-recorded.
- Illegal state-machine transitions → debug assert, release no-op.

## 8. Testing

- **Unit:** state-machine transition legality + per-state string bindings (ne + en);
  `NepaliTimeParser` (time expressions incl. Devanagari digits); intent parser +
  entity extraction against the golden corpus (mocked LLM output); settings
  persistence (contacts encrypted round-trip, med schedule validation rejects
  duplicates); onboarding state flags.
- **Integration:** wizard persistence + skip → Home reminder card; med schedule edit →
  `scheduleAll()` re-arm observed; language switch re-binds Home + Settings.
- **Safety regression:** C12 timeout test (pending confirmation clears after N s);
  C9 checks (no raw transcript in notification payloads or observability metadata);
  keyword fallback still acks medication when interpreter unavailable.
- **Accessibility:** token values asserted in a unit test (min font sizes, tap-target
  constants); Dynamic Type smoke test via previews.

## 9. Out of scope (explicit)

Voice biometric enrolment, wake word (v2), Piper TTS linking, health monitoring,
emergency calling module, remote config channel, Messenger deep links, news/calendar
integrations, background-execution fixes (C1) — all per the existing productionisation
roadmap; none of this pass depends on or blocks them.

## 10. References

- `constitution.md` §Accessibility, §Privacy, §Security, Open Decisions #8/#10
- `docs/review-2026-08-30.md` — C9, C12, H1, H2, H3, NFR-021/023/24 findings
- `.ai-sdd/outputs/plan-tasks/tasks/TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md`
- `ios/ElderlyAssistant/App/ContentView.swift`, `App/AppCoordinator.swift`
- `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`,
  `Services/Voice/LlamaCommandInterpreter.swift`
