# UI/UX Revision + Intents Pass — Design Spec (Refined)

**Date:** 2026-09-02
**Status:** Approved (refinement pass on `2026-09-02-ui-ux-and-intents-design.md`; design review: user, 2026-09-02)
**Scope:** iOS only (native SwiftUI). Parallel to the in-progress STT model fine-tune.
**Supersedes:** `2026-09-02-ui-ux-and-intents-design.md`, in full. That document remains as a
historical record; this one is the one to implement against. §0 below summarizes what
changed and why.

## 0. What changed from the original pass

A review of the original spec against the actual codebase (`ContentView.swift`,
`AppCoordinator.swift`, `CommandRouter.swift`, `LlamaCommandInterpreter.swift`,
`constitution.md`, `docs/review-2026-08-30.md`) confirmed its factual claims were accurate,
but surfaced eight refinements, folded into this rewrite:

1. **Localization architecture simplified.** The original's custom `\.appLanguage`
   environment key deliberately left the system `.locale` environment untouched, while
   also claiming number/date formatting "uses the active locale" — an unresolved
   contradiction, and unnecessary complexity given localization is greenfield (no
   `.xcstrings`/`.strings` file exists yet). This pass has `AppLanguage` drive
   `.locale` directly and drops the custom key entirely (§3.2).
2. **Onboarding step 3 is no longer a hard gate.** Requiring one family contact to
   proceed was inconsistent with step 2's skip-and-remind pattern. Now skippable,
   same as every other step (§4.2).
3. **Settings gains a 5th section: AI मोडेल (model & storage).** The debug scaffold's
   model-*selection* picker (multiple Whisper variants) had no home in the original's
   4-section Settings; it's bundled with model downloads, both fully off Home (§4.4,
   §4.5).
4. **`health_query` and `music` confirmed as first-class stub intents**, not silent
   fallbacks to `query`/`none` — deliberate, so the assistant gives an honest "not yet"
   tied to a real named feature rather than a generic chat answer (§5.1).
5. **Intent naming confirmed as snake_case raw values** (`ack_med`, `set_reminder`),
   matching the existing Swift `Action` enum convention already in code
   (`case ackMed = "ack_med"` in `LlamaCommandInterpreter.swift`). The ai-sdd task file
   `T-021-intent-classifier-entity-extractor.md` uses `SCREAMING_CASE` names for the
   same concepts — flagged for reconciliation at implementation time, not fixed here
   (§5.1, §10).
6. **Routing-order honesty fix.** The original's §5.4 called the LLM-first/keyword-
   fallback order "unchanged," but §5.2 introduces a new 10s LLM timeout that triggers
   the fallback — a new failure path, not preserved behavior. This pass calls it out
   explicitly (§5.4).
7. **Governance drift flagged, not fixed.** `constitution.md` still describes the app
   as React Native; the codebase is native Swift. This spec builds on native SwiftUI
   regardless — implementers running `/sdd-run` may hit friction validating against the
   stale constitution (§10).
8. Both tracks (UI/UX and Intents) stay combined in one document, per user preference,
   despite the scope-bundling risk noted in #6 above.

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
| D2 | Onboarding | 4-step **fully skippable** wizard (every step, including the family-contact step); skipped steps surface as a Home reminder card. |
| D3 | Language | Single active language at a time (no dual-line bilingual UI). **Nepali is the pilot language.** English ships as a fallback/development language. Architecture must support adding further Asian regional languages via a String Catalog only. |
| D4 | Visual style | "Warm & Soft": cream background, deep green accent, serif display type for greetings, rounded corners, soft shadows, Light appearance. |
| D5 | Home layout | Hero Talk button centre-stage with status line; greeting top; latest conversation card; setup-reminder card; 2×2 hub cards bottom. |
| D6 | Talk button | Driven by a `VoiceSessionState` state machine; every state binds localized Nepali strings (button label + status line) and appearance (color/ring). |
| D7 | Settings | **5 sections:** Language & region, Family & emergency contacts, Medication schedule editor, AI मोडेल (model selection & storage), Privacy policy & about. |
| D8 | Intent scope | Safety core + daily helpers: `ack_med`, `emergency`, `call` (auth-gated), `set_reminder`, `health_query`, `music` (bhajan/song), plus fallbacks `query`/`none`. All are first-class recognized intents this pass, including the two stubs. |

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

Visual reference: Home screen (idle/listening states) and onboarding steps 1/3 were
mocked up and approved during design review — see `.superpowers/brainstorm/` session
artifacts from 2026-09-02 for the reviewed layouts (structural reference only, not
pixel-final).

### 3.2 Localization architecture (multi-lingual invariant) — REVISED

- All user-facing strings live in `Localizable.xcstrings` with language-agnostic keys.
  No hardcoded user-facing text in Swift files — this includes the spoken assistant
  strings currently inline in `CommandRouter.swift` and the English notification
  titles/bodies (NFR-023/24). No `.xcstrings`/`.strings` file exists yet — this is a
  from-scratch build, not a migration.
- Active language is a single value (`AppLanguage` enum: `.ne`, `.en`, …), persisted in
  UserDefaults. `AppLanguage` **drives the environment's `.locale` directly** —
  injected once at the app root via `.environment(\.locale, appLanguage.locale)`.
  There is no separate custom `\.appLanguage` environment key: views read
  `@Environment(\.locale)` and get automatic, correct string lookup from the String
  Catalog, plus correct `DateFormatter`/`RelativeDateTimeFormatter`/number formatting
  for free, with zero manual routing per formatter call.
- Any code that needs the *chosen app language* as a non-string decision (not a
  formatter, not a `Text`) — e.g. picking `NepaliTimeParser` vs. a future English
  parser — reads `locale.language.languageCode` (or holds its own `AppLanguage` handle
  passed down from `AppCoordinator`, which is the source of truth `.locale` is derived
  from). This is the one place both concepts meet; document it there, not in a second
  environment key.
- Nepali (`ne`) is the pilot and default. English (`en`) ships as secondary. Adding a
  language later = adding entries to the catalog + one `AppLanguage` case; no other
  code changes.
- Switching `AppLanguage` in Settings re-injects `.locale` at the root, which re-renders
  every bound string, date, and number immediately — no manual re-bind step needed.

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
  |-------|--------|--------------|
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

No model-download or model-selection UI appears on Home — both moved fully to Settings
and onboarding step 4 (§4.4, §4.5).

### 4.2 Onboarding wizard (D2) — REVISED

Four steps, each: title, plain-language body, one primary action, "छाड्नुहोस्" (Skip)
in the top-right, back arrow top-left. Progress dots at the bottom. **Every step is
skippable** — there is no hard gate anywhere in the wizard.

1. **भाषा** — single-select language cards (नेपाली preselected, English secondary).
2. **अनुमति** — microphone and notifications, each with plain-language explanation
   ("आवाज फोनबाट बाहिर जाँदैन") and a big "दिनुहोस्" button that triggers the system
   prompt. Denied permission → inline guidance "सेटिङबाट खोल्नुहोस्" with the steps.
3. **परिवारको सम्पर्क** — name, phone number, relationship fields (≥60pt tall).
   "राख्नुहोस्" saves encrypted. **No longer required to proceed**: a
   "पछि सेटिङबाट थप्न सकिन्छ" note sits under the primary action; skipping surfaces
   the Home reminder card exactly like a skipped permission step.
4. **तयारी** — default-model download progress only (reuses `ModelDownloadService`,
   restyled); no variant picker here (that's Settings-only, §4.5). "घर जानुहोस्"
   proceeds regardless of download state.

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

### 4.4 Settings (D7) — REVISED: 5 sections

1. **भाषा र क्षेत्र** — single-select language list (नेपाली, English). Sets
   `AppLanguage`, which re-injects `.locale` at the app root (§3.2). Region shown, not
   yet editable (ne-NP fixed for now).
2. **परिवारको सम्पर्क** — 1–3 contacts (name, relationship, phone). Stored via
   `KeychainEncryptedStorage` (Data Protection Complete, constitution §Security).
   Today `APNsFamilyNotifier` is constructed with `contacts: []`; this section makes
   the list real and feeds the notifier. Reachable both from onboarding step 3's skip
   path and directly here.
3. **औषधि तालिका** — view/edit medication names and times through the existing
   scheduler storage (`MedicationScheduler`'s `EncryptedLocalStorage` entries).
   Validation: non-empty name, valid times, no duplicate (name, time) pairs. Changes
   call `medicationScheduler.scheduleAll()` to re-arm.
4. **AI मोडेल** — *new section.* Two parts on one screen:
   - **Model selection:** picker across the available Whisper variants
     (`whisperSmallNepali`, `whisperLargeV3Nepali`, `whisperSmallMultilingual`,
     `whisperBaseEn`), wired to the existing `preferredModelID` persisted by
     `AppCoordinator` (currently set by a UI picker with no home in the app — this
     gives it one). `nil`/automatic remains a valid selection.
   - **Downloads & storage:** the restyled `ModelDownloadSection` — per-model download
     progress, retry, and delete, showing on-disk size where available. This is the
     *only* place model downloads are manageable outside onboarding step 4's
     default-model progress view.
5. **गोपनीयता** — privacy policy text (plain-language Nepali; states what stays
   on-device) + app version/about (NFR-032).

### 4.5 Model downloads and selection — REVISED

- **Onboarding step 4 (तयारी):** shows download progress for the default model only.
  No variant picker — an elderly user at first run should not need to choose between
  Whisper variants; the default (Nepali small) downloads automatically.
- **Settings → AI मोडेल (§4.4.4):** the only place both the variant picker and full
  download/delete management live. Restyled to the Warm & Soft tokens with large
  progress rows and ≥44pt controls.
- Home carries no model-related UI at all (removes the debug-scaffold's inline list).

## 5. Intents track

### 5.1 Catalog

| Intent | Trigger examples (Nepali) | Action |
|--------|---------------------------|--------|
| `ack_med` | "औषधि खाएँ", "मैले औषधि लिइसकें" | Existing challenge → ack flow |
| `emergency` | "साहयता चाहियो", "इमर्जेन्सी" | Route to the safety path with **no auth gate** (constitution: emergency must never be blocked by auth or a busy LLM). Today that means spoken acknowledgement + observability emit + local alert, because the broker relay and emergency-call module don't exist yet (§9). |
| `call` | "छोरालाई फोन गर" | Blocked with spoken reason until voice auth lands (current behaviour, retained) |
| `set_reminder` | "बिहान ८ बजे औषधि खान सम्झाउनु" | Create a reminder entry via scheduler storage |
| `health_query` | "मेरो प्रेसर कति छ" | First-class recognized intent this pass. Answers from HealthKit when available; spoken "not available yet" stub fallback otherwise — an honest answer tied to a named feature, not a generic chat reply. |
| `music` | "भजन बजाउनुस्", "गीत चलाउ" | First-class recognized intent this pass. Spoken-ack stub (playback integration out of scope), same honesty rationale as `health_query`. |
| `query` | "भोलि मौसम कस्तो" | LLM-generated reply (existing behaviour) |
| `none` | chit-chat | LLM reply |

Raw values are snake_case (`"ack_med"`, `"set_reminder"`, `"health_query"`), matching
the existing Swift convention already in `LlamaCommandInterpreter.swift`
(`case ackMed = "ack_med"`, `case call`, `case query`, `case none`). The ai-sdd task file
`T-021-intent-classifier-entity-extractor.md` names the same concepts in
`SCREAMING_CASE` (`CALL_CONTACT`, `SET_REMINDER`, `HEALTH_QUERY`,
`GENERAL_CONVERSATION`) — **reconcile T-021 to this catalog's names at implementation
time**; this spec's naming wins because it matches shipped code, not a planning
artifact.

### 5.2 Grammar + entities

- Extend `LlamaGrammar.commandJSON` (and the paired `RawCommand` Codable) to cover the
  catalog above; enforce it at inference time (currently defined but never passed to
  the sampler — review H2). **This is new work**, not a preserved behavior: today
  `LlamaGrammar.commandJSON` is referenced only from
  `LlamaCommandInterpreterTests.swift`, never wired into the real inference path.
- Entity extraction: `time` (Nepali expressions "बिहान ८ बजे", "दिउँसो", "अब"),
  `contact` (name), `medication` (name matched against the scheduler's med list when
  available). Entities are fields on `InterpretedCommand`; the `set_reminder` handler
  resolves a fuzzy time string via a small `NepaliTimeParser` (pure, unit-testable).
- Input sanitiser runs on the transcript before every LLM call (H3/NFR-013,
  `sanitise(.quarantine)`).
- LLM inference gets a timeout (configurable, default 10s) — on timeout, router falls
  back to keyword matching (H2). **This is a new failure path introduced by this
  pass** — see §5.4.
- Remove PII leaks while in these files (C9): drop `postDebugNotification` with raw
  transcripts (`CommandRouter.swift`) and the 160-char LLM output preview
  (`LlamaCommandInterpreter.swift`) from the observability metadata.

### 5.3 Golden corpus

A `Tests`-embedded fixture set: 15–25 Nepali utterances per intent, including
code-switched and dialectal variants, each labelled `intent` + `entities`. Used by:

- unit tests for the parser (with the LLM mocked),
- later, eval of the fine-tuned STT + interpreter together (slow/nightly).

The corpus is a test fixture, not a shipped asset.

### 5.4 Routing order — REVISED (no longer "unchanged")

LLM interpreter first (when available and confident ≥0.7), then the keyword fallback
(the safety net for safety-critical vocabulary — retained as-is per the existing
design), then "माफ गर्नुहोस्, मैले बुझिनँ" re-prompt.

**This order itself is preserved from current behavior, but the failure conditions
that trigger the fallback are not**: the 10s LLM timeout (§5.2) is new, and it now sits
alongside "LLM unavailable" and "LLM confidence < 0.7" as a third trigger for
keyword fallback. Treat the timeout path as new surface requiring its own test
coverage (§8), not an extension of already-verified behavior.

## 6. Data flow

- `AppCoordinator` remains the composition root and owns all services. It gains:
  `AppLanguage` (published, and the source `.locale` is derived from), `OnboardingState`,
  and exposes `VoiceSessionState` to the UI. `ContentView` becomes a thin host: it picks
  Home vs Onboarding wizard from `OnboardingState.hasSeenOnboarding`.
- Voice pipeline publishes `VoicePipeline.State`; a small adapter maps it onto
  `VoiceSessionState` (the single place that knows both enums).
- Settings writes go through existing stores: contacts → `KeychainEncryptedStorage`;
  med schedule → scheduler storage; language/onboarding → UserDefaults; preferred
  model → `AppCoordinator`'s existing `preferredModelID` persistence.
- No new networking, no cloud calls (constitution constraint 1).

## 7. Error handling

- Permission denied (mic/notifications) → wizard shows plain-language fix instructions;
  app remains usable (voice off state).
- Download failure → retry button on the तयारी step and on the Settings AI मोडेल screen.
- Voice error → `error` state (red), spoken re-prompt; `onSTTError` messages are
  localized instead of raw strings.
- `awaitingConfirmation` timeout → spoken notice + return to idle (C12).
- LLM inference timeout (10s) → keyword fallback, observability event emitted without
  raw transcript content (C9-compliant).
- Language switch mid-flight → `.locale` re-injection re-renders all bound strings,
  dates, and numbers; in-progress spoken replies are not re-recorded.
- Illegal state-machine transitions → debug assert, release no-op.

## 8. Testing

- **Unit:** state-machine transition legality + per-state string bindings (ne + en);
  `NepaliTimeParser` (time expressions incl. Devanagari digits); intent parser +
  entity extraction against the golden corpus (mocked LLM output), including the
  `health_query`/`music` stub paths; settings persistence (contacts encrypted
  round-trip, med schedule validation rejects duplicates, preferred model ID
  round-trip); onboarding state flags (all four steps skippable, none blocking).
- **Integration:** wizard persistence + skip (all steps, including family contact) →
  Home reminder card; med schedule edit → `scheduleAll()` re-arm observed; language
  switch re-binds Home + Settings + date/number formatting via `.locale`; Settings AI
  मोडेल model switch → `preferredModelID` change observed by `WhisperSpeechRecognizer`.
- **Safety regression:** C12 timeout test (pending confirmation clears after N s);
  C9 checks (no raw transcript in notification payloads or observability metadata);
  keyword fallback still acks medication when interpreter unavailable; **new** LLM
  timeout → fallback test (H2/§5.4), since this is new surface, not a regression check
  on existing behavior.
- **Accessibility:** token values asserted in a unit test (min font sizes, tap-target
  constants); Dynamic Type smoke test via previews.

## 9. Out of scope (explicit)

Voice biometric enrolment, wake word (v2), Piper TTS linking, health monitoring,
emergency calling module, remote config channel, Messenger deep links, news/calendar
integrations, background-execution fixes (C1) — all per the existing productionisation
roadmap; none of this pass depends on or blocks them.

Also out of scope: reconciling `constitution.md`'s React Native description with the
native Swift codebase (governance drift, §10) — flagged, not addressed here.

## 10. References

- `constitution.md` §Accessibility, §Privacy, §Security, Open Decisions #8/#10 — **note:**
  this document still describes the app as React Native; the codebase is native Swift.
  Implementers running `/sdd-run` should expect friction validating against the stale
  constitution until that drift is separately resolved.
- `docs/review-2026-08-30.md` — C9, C12, H1, H2, H3, NFR-021/023/24 findings
- `.ai-sdd/outputs/plan-tasks/tasks/TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md`
  — **note:** uses `SCREAMING_CASE` intent names inconsistent with this spec's
  snake_case catalog (§5.1); reconcile at implementation time.
- `ios/ElderlyAssistant/App/ContentView.swift`, `App/AppCoordinator.swift`
- `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`,
  `Services/Voice/LlamaCommandInterpreter.swift`
- `ios/ElderlyAssistant/Services/ModelStore/ModelDownloadService.swift`,
  `Services/Voice/WhisperSpeechRecognizer.swift` (existing `preferredModelID` picker,
  now given a home in Settings §4.4.4)
- `2026-09-02-ui-ux-and-intents-design.md` — superseded original; historical record of
  the initial design pass this document refines.
