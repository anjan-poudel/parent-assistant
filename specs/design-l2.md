# L2 Component Design — Profile Interview + Address-as (v1)

**Feature:** `profile-interview` · **Branch:** `feat/profile-interview`
**Task:** `design-l2` (agent `pe`) · **Contract:** `component_design_l2` → `specs/design-l2.md`
**Date:** 2026-10-05 · **Status:** for `review-l2`; feeds `security-design-review`, `plan-tasks`, `implement`

**Inputs folded in.** `specs/design-l1.md` (BINDING — component inventory C01–C12, ADR-01…ADR-11,
hand-off notes in its §16, and the §17 verification hooks); `specs/define-requirements.md` +
`specs/define-requirements.lock.yaml` (16 FR-PI / 11 NFR-PI, all MUST — re-baselined with the
2026-10-05 owner amendment that added FR-PI-016);
`specs/profile-interview/constitution.md` (Field Contract, Address-as Behaviour Contract,
Feature Constraints 1–8 — including the Constraint 8 app-start routing amendment — plus the
resolved OD-F1/OD-F2/OD-F3 in the L1 ADRs, OD-PI-4 / OD-PI-5 owner-resolved);
`specs/profile-interview/workflow.yaml`; and the shipped code, re-read for this task (the
filenames quoted throughout appear in the L1 input list, §1).

**What this document is.** The component-level design for the components L1 defined: exact
Swift interfaces with explicit error types, data shapes, error/observability behaviour,
concurrency and isolation statements per shared resource, configurable parameters with named
defaults, measured budget proof, technical risks, and test seams. It settles exactly the items
L1 §16 assigned to `design-l2`. It adds **no** component, pattern, permission, egress, or API
beyond L1 **except C13**, the app-start interview routing mandated by the 2026-10-05 owner
amendment (FR-PI-016, Feature Constraint 8 — component C13 in the Components section);
everything else is the L1 scope unchanged. Implementation code and migrations are out of scope for this
task. Where this document corrects a stale number or an interface sketch in L1, the correction is
recorded in **Section 13 (Findings and corrections vs L1)** with its evidence.

**Path convention.** Paths are source-root-relative. `App/…`, `Services/…`, `Resources/…` resolve
under the app source root `` `ios/ElderlyAssistant` ``; `tools/…` resolves at the repository root;
`ios/tools/…` at the iOS project root.

---

## Overview

**Goal.** From a first-run interview (and a Settings editor afterwards), record who the user is
and how the assistant should address them, then use the term ("address-as") in exactly two
places: the spoken wake acknowledgment and the brain reply-style rules — cloud and on-device
alike. Until a term is recorded, the app behaves exactly as today (FR-PI-011, NFR-PI-010).

**Design shape (all from L1, restated as the L2 baseline).** One encrypted single-record store
(C01) is the single source of truth; the wizard steps (C02/C11/C12) and the Settings editor (C04)
write through one coordinator writer; the wake path (C05) speaks a localized template with the
term as data, ack-first with a bounded hold; the prompt path (C06/C07) composes one guarded term
through the shared builders; the seed mirror (C08) and the log-safety gate (C10) are updated in
the same change; localisation (C09) covers every new string. The 2026-10-05 owner amendment
adds app-start interview routing (C13, FR-PI-016): on cold start an incomplete interview opens
the wizard at the first pending step, complete interviews start normally.

**What L2 settles (L1 §16 hand-off).**

| L1 hand-off item | L2 settlement |
|---|---|
| Exact clause wording + measured budget proof | Clause wording adopted as final; base fixture measured at 2,506 Characters (the L1/test comment figure 2,936 is stale — §13, item 2); worst-case composition 2,586 ≤ 3,000 (Section 9.1) |
| Final guard name and bound | `ProfilePromptTextGuard`, `guarded(_:)`, `maxPromptTermGraphemes` default 24 (= the entry bound), plus quote-slot neutralisation (§5.3) |
| Ack service internal state machine | `WakeAcknowledgmentService`, two-state machine with a single `settle` exit; table in §7.1 |
| C03 chip data structure | `AddressAsPresets.terms(for:)` over a `[String: [String]]` table (§5.2) |
| `hasPayload` probe exact signature | `hasPayload(key: String) -> Bool?` on the new `ProfilePayloadStorage` seam (§5.1) |
| Test seams for the §9 contracts | Section 12 |
| Seed byte-identity hook | New build-blocking gate `ios/tools/check-prompt-mirror.sh` + `.py` wired into `ios/build.sh` beside the log-safety gate (§9.2); the gate found and the change fixes a one-byte trailing-newline drift (§13, item 3) |
| App-start routing settlement (FR-PI-016, owner amendment) | `AppCoordinator.coldStartInterviewRoute()` — the earlier of the first pending step and About-you when the mandatory fields are missing — consumed once per cold start by the existing shell (§5.8, C13); the background→foreground re-check is decided **out** for v1, with revisit conditions recorded |

**Measured facts (evidence for the review).**

| Measurement | Value | How measured |
|---|---|---|
| Rendered `build` fixture, no term, no plugins (`ne`, no meds, transcript "भोलिको मौसम कस्तो छ?") | 2,506 Swift `Character`s / 2,718 UTF-8 bytes | Compiled the exact source substring; `String.count` (graphemes) and `utf8.count` |
| `addressAsClause` with a 24-grapheme term | 80 Characters (56 static + 24 term) | Character count of the settled clause |
| Worst-case composed fixture (2,506 + 80) | 2,586 ≤ 3,000 (headroom 414) | Arithmetic on the two measurements |
| Fixture with an 8-grapheme Devanagari term | 2,570 | Same |
| `build` template with placeholder tokens | 2,698 bytes | Swift-dedent extraction of the literal, interpolations replaced by placeholder tokens |
| Seed `tools/train-intent/seeds/prompt_template.txt` | 2,699 bytes | `wc -c`; differs from the template by exactly one trailing `\n` (§13, item 3) |

**Operator/user-visible summary.** Success: after the interview, the next wake answers with
`हजुर <term>` and replies may address the user by the term; every new field is editable in
Settings and takes effect on the next wake/reply with no relaunch. On app start, an incomplete
interview opens the wizard at the first pending step (FR-PI-016) — the user is never trapped
(every step skippable, the presentation dismissible) — and a complete interview starts normally.
Failure: nothing about this feature ever blocks listening or replies — a store read failure, a
guard rejection, a synthesis failure, or the hold bound all degrade to today's un-personalized
behaviour, with a content-free event for the operator (§7.5).

---

## Components

Each component below states: responsibility, files touched, key types, dependencies, concurrency,
errors, and the requirements it carries. Component IDs C01–C12 are L1's; C13 is the single
addition, under the 2026-10-05 owner amendment (FR-PI-016, Feature Constraint 8).

### C01 — `UserProfile`, `UserProfileStore`, `ProfileLoadResult`, `ProfileStoreError`

- **Files.** New `Services/Storage/UserProfileStore.swift`; additive conformance extensions inside
  `Services/Storage/EncryptedFileStorage.swift` and `Services/Storage/MigratingEncryptedStorage.swift`
  (§5.1). No existing method changes.
- **Responsibility.** One encrypted record (name, address-as, DOB, GP, hospital) behind
  `UserProfileStoring`; absent-vs-unreadable discrimination; atomic durable writes; a
  lock-protected in-memory cache; no PII in any log path.
- **Key types.** `UserProfile`, `ProfileLoadResult`, `ProfileStoreError`, `UserProfileStoring`,
  `ProfilePayloadStorage`, `UserProfileStore` (Section 4 and §5.1).
- **Dependencies.** `ProfilePayloadStorage` (production: the shared `MigratingEncryptedStorage`
  instance the coordinator hands every store; test: an in-memory fake), `ObservabilityBus?`.
- **Concurrency.** Reads from any queue behind the store's `NSLock` + cache; writes
  main-thread-only by contract (`UserProfileStore` asserts this in `save`); file I/O happens
  inside the lock; atomic temp-file+rename means a crash mid-write leaves the previous record.
  See Section 6.
- **Errors.** `ProfileStoreError.readFailed / decodeFailed / writeFailed`; every failure is an
  explicit case returned, never thrown; no retry loop anywhere.
- **Requirements.** FR-PI-003, FR-PI-015, FR-PI-011; NFR-PI-001, NFR-PI-002, NFR-PI-010.
  ADR-01.

### C02 — Wizard step extension (`OnboardingState.Step` + step views)

- **Files.** `App/OnboardingState.swift` (three cases, doc-comment addendum), 
  `App/OnboardingWizardView.swift` (three step views + switch cases), new `App/OnboardingDrafts.swift`
  (pure draft/merge values), new `App/Components/AddressAsField.swift` (C03).
- **Responsibility.** Insert `aboutYou`, `emergencyContacts`, `voiceFingerprint` in the required
  order (FR-PI-001); About-you gates Next on trimmed non-empty name + address-as (FR-PI-002) while
  the header Skip stays (ADR-04); the family step additionally lists existing contacts
  (FR-PI-005); every new step participates in the existing skip/pending/reopen machinery
  (FR-PI-004, FR-PI-013).
- **Key types.** `OnboardingState.Step` (extended), `AboutYouDraft`, `AddressAsField`,
  `ProfileEntryBounds` (§5.2).
- **Dependencies.** `AppCoordinator.saveProfile` / `currentProfileSnapshot` (C01 single writer),
  `AddressAsField`, existing `primaryButton` and wizard chrome.
- **Concurrency.** SwiftUI main actor only; all writes go through the coordinator's main-thread
  writer.
- **Errors.** Save `writeFailed` → inline localized message, step stays; `addFamilyContact` /
  `updateFamilyContact` returning `false` → inline message, selection reloads from the store.
- **Requirements.** FR-PI-001…FR-PI-005, FR-PI-013; NFR-PI-007, NFR-PI-010. ADR-03, ADR-04.

### C03 — `AddressAsField` (chips + custom entry)

- **File.** New `App/Components/AddressAsField.swift` (new directory `App/Components/`).
- **Responsibility.** The one address-as input used by the wizard and Settings: preset chips for
  the active language (OD-PI-4) plus a free-text field; grapheme-safe entry bound; the chip's
  resolved term is written to the field as data (ADR-05).
- **Key types.** `struct AddressAsField: View`, `enum AddressAsPresets`, `struct ProfileEntryBounds`.
- **Dependencies.** `Locale` from the environment (`AppLanguage`-driven).
- **Concurrency.** Main actor (SwiftUI).
- **Errors.** None thrown; over-long input is clamped on `Character` boundaries.
- **Requirements.** FR-PI-002, FR-PI-010; NFR-PI-006, NFR-PI-007. ADR-05.

### C04 — `ProfileSettingsView` + `SettingsDestination.profile`

- **Files.** `App/SettingsTabs.swift` (destination case, family-tab row, view switch), new
  `App/ProfileSettingsView.swift`, new `App/ProfileSettingsModel.swift`.
- **Responsibility.** Plain (!) editor for name, address-as (C03), DOB, GP, hospital, plus a
  read-only next-of-kin note linking to the family-contacts editor. Saves through the coordinator;
  the change is effective on the next wake/reply via the cache swap (FR-PI-012). No new auth
  (OD-PI-5 / ADR-08).
- **Key types.** `SettingsDestination.profile`, `ProfileSettingsView`, `ProfileSettingsModel`.
- **Dependencies.** Coordinator writer/snapshot, `AddressAsField`, `SettingsTabMappingTests`
  (extended).
- **Concurrency.** Main actor (`@MainActor` model).
- **Errors.** `writeFailed` → inline localized message; the previously stored value remains in
  effect.
- **Requirements.** FR-PI-012, FR-PI-010; NFR-PI-006, NFR-PI-007. ADR-08.

### C05 — `WakeAcknowledging` + `WakeAcknowledgmentService` + `VoicePipeline.beginCapture`

- **Files.** New `Services/Voice/WakeAcknowledgment.swift`; edits to
  `Services/Voice/VoicePipeline.swift` (seam property, handler split, `stop()` cancel).
- **Responsibility.** On wake detection with a recorded term, speak the localized template with
  the term verbatim, then start capture — bounded by `wakeAckMaxHoldSeconds`; nil term or any
  failure falls back to today's immediate silent start; nil seam is today's code path (FR-PI-008,
  FR-PI-011, NFR-PI-008; ADR-06, ADR-09).
- **Key types.** `WakeAcknowledging`, `WakeAcknowledgmentService`, `VoicePipeline.wakeAcknowledger`.
- **Dependencies.** A `Speaker` (the coordinator's base `PiperVoiceSpeaker`, **not** the
  `SpeechNoteForwarder`-wrapped instance — one bookkeeping owner, §6), the coordinator's
  `noteSpeakingStarted/Ended` hooks, `L10n`, `ObservabilityBus?`.
- **Concurrency.** Main-thread-only by contract with `dispatchPrecondition` checks; at most one
  in-flight ack; completion exactly once per `begin` except when `cancel()` drops it (documented,
  §7.1). See Section 6.
- **Errors.** No thrown errors; failures are the synchronous fallback completion plus a
  content-free event (`wake_ack_failed` / `wake_ack_timeout`).
- **Requirements.** FR-PI-008, FR-PI-010, FR-PI-011, FR-PI-015; NFR-PI-001, NFR-PI-002,
  NFR-PI-008, NFR-PI-010. ADR-06, ADR-09.

### C06 — `InterpreterContext.addressAs` + `IntentPrompt` clause

- **Files.** `Services/Voice/LlamaCommandInterpreter.swift` (context type + init),
  `Services/Voice/IntentPrompt.swift` (helper + three call sites), `Services/Voice/CommandRouter.swift`
  (context construction ~line 1412), `App/AppCoordinator.swift` (collapse-provider context ~line 3601).
- **Responsibility.** One guarded term flows from one accessor through the two existing
  context-construction sites into the shared builders; the clause is appended to the reply-style
  guidance in `build`, `buildChat`, and `buildUnderstanding`; no term → clause `""` → byte-identical
  prompts (FR-PI-009, FR-PI-011; ADR-07, ADR-10).
- **Key types.** `InterpreterContext` (extended), `IntentPrompt.addressAsClause(_:)`.
- **Dependencies.** `ProfilePersonalizationReading` (C07), `IntentPromptTests`.
- **Concurrency.** The clause rides the immutable `InterpreterContext` value; prompt composition is
  pure and safe on any interpreter queue. See Section 6.
- **Errors.** None; a rejected term is simply absent (nil) for that composition.
- **Requirements.** FR-PI-009, FR-PI-010, FR-PI-011; NFR-PI-004, NFR-PI-005, NFR-PI-010.
  ADR-07, ADR-10.

### C07 — `ProfilePromptTextGuard` + `ProfilePersonalization`

- **Files.** New `Services/Voice/ProfilePromptTextGuard.swift` (guard + `ProfileText` clamp
  helper), new `Services/Voice/ProfilePersonalization.swift` (read seam + implementation).
- **Responsibility.** The injection discipline for the one profile string that enters prompts:
  quarantine → strip-then-detect → grapheme bound → quote-slot neutralisation → `nil` on residual
  (un-personalized). `ProfilePersonalization` is the read seam the two context sites and the ack
  service consume; it never writes.
- **Key types.** `ProfilePromptTextGuard`, `ProfilePersonalizationReading`, `ProfilePersonalization`.
- **Dependencies.** `InputSanitiser` (unchanged, single-sourced marker table), `UserProfileStoring`,
  `ObservabilityBus?`.
- **Concurrency.** Pure guard function; the read seam delegates to the store's locked cache; safe
  from any queue. See Section 6.
- **Errors.** No thrown errors; a dropped term emits `profile_prompt_text_quarantined` (content-free)
  and the un-personalized path is used for that turn.
- **Requirements.** FR-PI-011, NFR-PI-004, NFR-PI-002. ADR-09.

### C08 — Seed mirror + Python renderer + mirror gate

- **Files.** `tools/train-intent/seeds/prompt_template.txt`,
  `tools/train-intent/src/intent_prompt.py`, new `ios/tools/check-prompt-mirror.sh` + `.py`,
  `ios/build.sh` (gate call).
- **Responsibility.** The seed gains `{address_as_clause}` at the exact position the Swift
  template interpolates the helper; the renderer gains the placeholder defaulting to `""`
  (training bytes unchanged for the no-term corpus); a new build-blocking gate asserts byte
  equality between the extracted Swift template and the seed, and fixes the one-byte trailing
  newline drift it found (§13, item 3).
- **Key types.** `PLACEHOLDERS`, `render_prompt(..., address_as_clause: String = "")`.
- **Dependencies.** None at runtime; gate runs in `ios/build.sh` before every test scope.
- **Concurrency.** n/a (build tooling).
- **Errors.** Gate exits non-zero with a diff excerpt on any mismatch, missing placeholder, or
  extraction failure (never a silent pass).
- **Requirements.** NFR-PI-005. ADR-10.

### C09 — L10n catalog additions

- **File.** `Resources/Localizable.xcstrings` (en + ne).
- **Responsibility.** Every new user-visible string keyed; the term and name are **data** and never
  catalogued (FR-PI-010). New keys: the three step titles/bodies, about-you labels
  (`onboarding.aboutYou.*`), emergency labels (`onboarding.emergency.*`), fingerprint step copy
  (`onboarding.stepVoiceFingerprint.*`, `onboarding.voiceFingerprint.*`), the ack templates
  (`wakeAck.personalized`: ne `हजुर %@`, en `Yes, %@`), and the Settings editor keys
  (`settings.profile.title`, `profile.field.*`, `profile.kin.note`, `profile.save`,
  `profile.saved`, `profile.error.saveFailed`). Button keys reuse `onboarding.next` /
  `onboarding.skip` / `common.back`; the emergency inline add form reuses `onboarding.stepFamily.*`.
- **Key types.** n/a (catalog).
- **Dependencies.** `SettingsTabMappingTests`' L10n check (it fails if a new row's key is missing),
  `L10n.str/fmt`.
- **Concurrency.** n/a.
- **Errors.** Unresolved template key → the ack speaks nothing (`wake_ack_failed`
  `template_missing`); the UI degrades to the key string as today.
- **Requirements.** NFR-PI-006, FR-PI-010; OD-A2 (owner eyeball on the en copy).

### C10 — Observability + log-safety coverage

- **Files.** `Services/Observability/LogSanitiser.swift` (redacted-keys additions),
  `ios/tools/check-release-log-safety.py` (`FEATURE_ROOTS` additions).
- **Responsibility.** Content-free events only (`outcome`, `error_code`, `duration_ms` — all
  already allow-listed); profile field-name keys added to `redactedKeys` as the fail-closed
  defence; the scan roots extended to the feature's own sources so a console write or an
  unlisted metadata key in them fails the gate (NFR-PI-002).
- **Key types.** `ObservabilityEvent` (unchanged), `LogSanitiser` (sets only).
- **Dependencies.** `ios/build.sh` invokes `check-release-log-safety.sh` before every test scope
  (existing wiring).
- **Concurrency.** The bus is existing infrastructure; emitters below hold no shared state beyond
  the store lock.
- **Errors.** n/a.
- **Requirements.** NFR-PI-002, NFR-PI-011.

### C11 — Emergency contacts step wiring

- **Files.** `App/OnboardingWizardView.swift` (new `EmergencyContactsStep`),
  `App/AppCoordinator.swift` (no API change — the existing `addFamilyContact` /
  `updateFamilyContact` signatures already carry `isEmergencyContact`).
- **Responsibility.** GP + hospital into C01 (optional, partial fill accepted); next of kin is the
  existing `isEmergencyContact` designation on a family contact (ADR-02, resolving OD-F1); no
  emergency-call logic change (FR-PI-014).
- **Key types.** `EmergencyContactsDraft` (pure merge), `EmergencyContactsStep`.
- **Dependencies.** `coordinator.familyContacts`, `addFamilyContact`, `updateFamilyContact`,
  `saveProfile`, `currentProfileSnapshot`.
- **Concurrency.** Main actor; contact writes go through the existing coordinator methods.
- **Errors.** Contact write `false` → inline message + selection reload; profile `writeFailed` →
  inline message, step stays.
- **Requirements.** FR-PI-004, FR-PI-006, FR-PI-014; NFR-PI-001. ADR-02.

### C12 — Voice fingerprint step

- **Files.** `App/OnboardingWizardView.swift` (new `VoiceFingerprintStep`).
- **Responsibility.** Hosts the existing `VoiceEnrollmentSession` exactly as `VoiceSettingsView`
  constructs it (same service/recorder/coordinator-as-suspender), as an optional skippable step;
  a call site only — mechanism, storage, and permissions unchanged (FR-PI-007, NFR-PI-009).
  `suspendForSampleCapture()` returns `true` when no live pipeline exists, so the pre-`start()`
  wizard context is safe (verified in the coordinator conformance, §13 item 5).
- **Key types.** `VoiceFingerprintStep` (holds the `@StateObject` session).
- **Dependencies.** `VoiceEnrollmentSession`, `coordinator.makeEnrollmentSampleRecorder()`,
  coordinator as `VoicePipelineSuspending`.
- **Concurrency.** Existing `@MainActor` session + `VoicePipelineSuspending` cycle, unchanged.
- **Errors.** The session's existing `Phase.failed` states render as honest copy; failure or skip
  still advances; enrollment stays available in Settings.
- **Requirements.** FR-PI-007; NFR-PI-009, NFR-PI-010.

### C13 — App-start interview routing (`coldStartInterviewRoute`; FR-PI-016)

- **Scope.** Added under the 2026-10-05 owner amendment (Feature Constraint 8); this is the only
  addition to L1's C01–C12 inventory. It supersedes FR-PI-013's "No force-migration" scenario
  **for the app-start path** (pending steps are now surfaced on start) while keeping FR-PI-013's
  mechanism (`pendingSteps` / `firstPendingStep` / the wizard's `startingAt:` reopen), the
  wizard's no-hard-gate contract and the FR-PI-004 / OD-F3 soft-skip. No new persisted state.
- **Files.** `App/AppCoordinator.swift` (the route method), `App/ContentView.swift` (the
  fresh-install path presents the wizard at the route), `App/HomeView.swift` (one-shot startup
  presentation through the existing `showWizard` fullScreenCover), `App/OnboardingDrafts.swift`
  (the shared trimmed-non-empty predicate). No new files.
- **Responsibility.** Decide once per cold start where (if anywhere) to send the user into the
  interview: the earlier of the first pending step and About-you when the mandatory fields are
  not recorded; nil = no routing. Resume only — the outcome feeds the existing wizard
  presentation; the check itself persists nothing.
- **Key types.** `AppCoordinator.coldStartInterviewRoute()`,
  `AboutYouDraft.mandatoryFieldsRecorded(in:)`.
- **Dependencies.** `OnboardingState.stepStatuses` / `pendingSteps` / `firstPendingStep` (the
  existing persisted map), `coordinator.currentProfileSnapshot()` (C01 cache; the check may
  prime it).
- **Concurrency.** Main-thread by contract; pure read, no mutation; one evaluation per process
  (one-shot state in the shell). No async call, so no timeout parameter applies (Section 8).
- **Errors.** The method never throws and has no error return: every failure mode has a defined
  route (edge table below); its only outcomes are a `Step` or nil. Nothing in the check can
  crash, stall or loop — the step-map read ignores unknown values (existing `status(of:)` rule)
  and the decision is a single synchronous evaluation.
- **Decision (L2, settling FR-PI-016's foreground question).** Cold start only; **no**
  background→foreground re-check in v1. A foreground re-check would fire inside a living session
  and can pop the interview over an active interaction (listening, playback, a safety flow) — an
  interruption the requirement does not justify; cold start is its stated minimum.
  Discoverability is preserved by the Home reminder card and the Settings editor. Revisit only
  with an interruption-safety design (never over an active capture, call or alarm; never
  mid-task).
- **Requirements.** FR-PI-016 (plus FR-PI-001/002/004/013/015, NFR-PI-010).

**Route rule (normative).** `first = onboardingState.firstPendingStep`.
`mandatoryFieldsRecorded` = the snapshot is `.loaded` with a trimmed non-empty name AND
address-as. If the mandatory fields are not recorded, the route is the earlier of `first` and
`.aboutYou` in `Step.allCases` order (`.aboutYou` when `first` is nil or later than About-you);
otherwise the route is `first`; nil when nothing is pending and the mandatory fields are
recorded. The mandatory-missing route is a **hard route on start**; the About-you step's OD-F3
soft-skip (ADR-04) and the dismissible presentation still apply, so the user is never trapped.

**Edge behaviour (normative).**

| Situation | Status map | Profile snapshot | Route |
|---|---|---|---|
| Fresh install (never finished) | all pending | `.absent` | `.language` (the wizard's existing start — unchanged) |
| Pre-finish relaunch (quit mid-wizard) | some completed | any | first pending step — resumes where the user left off; today such a relaunch restarted at `.language`, so this is the requirement's conscious resume change |
| Interview complete | none pending | `.loaded`, name + address-as non-empty | none — the app starts normally |
| Optional steps pending | first pending is optional | `.loaded`, mandatory recorded | first pending step — routed with the soft-skip preserved, never trapped |
| Mandatory missing while About-you is marked completed (e.g. a corrupt payload discarded per §5.1) | aboutYou completed | `.absent` / empty / `.unreadable` | `.aboutYou` — the hard route repairs the record through the wizard's ordinary Next-and-save gate |
| Status map corrupt (unknown raw values, wrong types) | reads as nothing recorded (existing rules) | any | as computed above — wizard from the first pending step; skippable; no crash, stall or loop |
| Unit tests (hosted) | — | — | no routing — the one-shot honours the same boot guard ContentView uses for `start()` |

**Shell wiring (normative).**

- `ContentView` (the not-finished path): `OnboardingWizardView(startingAt: coordinator.coldStartInterviewRoute())`.
  For an untouched fresh install this is `.language` — identical to today; for a pre-finish
  relaunch it resumes at the first pending step (edge table).
- `HomeView` (the finished path): a new `@State wizardStart: OnboardingState.Step?` is captured
  by both entry points — the existing reminder card sets
  `wizardStart = coordinator.onboardingState.firstPendingStep` (same value, captured at tap),
  and the new one-shot sets `wizardStart = coordinator.coldStartInterviewRoute()` with
  `showWizard = true`; the existing `.fullScreenCover` renders
  `OnboardingWizardView(startingAt: wizardStart)` with its current environment injections.
  One-shot: a `didCheckStartupRoute` `@State`, first `onAppear` only; `scenePhase` is not
  observed for routing (the cold-start decision above). The one-shot honours the
  `XCTestConfigurationFilePath` boot guard so hosted unit tests see today's behaviour; UI tests
  run the real shell and see production routing.

---

## Interfaces

All signatures are the L2 contracts `plan-tasks` and `implement` must hold to. Error return types
are explicit everywhere; nothing returns `any Error` or uses `unknown`-style placeholders.

### 5.1 Store interfaces (C01)

```swift
// Services/Storage/UserProfileStore.swift

/// The single profile record. Unversioned; every future addition is an
/// optional key read as nil when absent (the FamilyContact convention).
/// `name` / `addressAs` are non-optional Strings: a payload MISSING those
/// keys is unreadable — never defaulted. An empty string is legal and
/// means "not recorded yet" (skip path, partial fill, Settings clear).
struct UserProfile: Codable, Equatable {
    var name: String
    var addressAs: String
    var dateOfBirth: DateComponents?   // year/month/day only; never spoken, never prompted
    var emergencyDoctor: String?
    var localHospital: String?
}

enum ProfileLoadResult {
    case absent                        // fresh install / never written / discarded
    case loaded(UserProfile)
    case unreadable(ProfileStoreError) // present but not usable
}

enum ProfileStoreError: Error, Equatable {
    case readFailed     // the store could not answer "is there a payload?"
    case decodeFailed   // payload present, but not a valid UserProfile
    case writeFailed    // the atomic write failed
}

/// The raw seam the store needs from the encrypted storage chain.
/// Deliberately NOT `RawEncryptedStorage`: it adds the presence probe
/// that distinguishes absent from unreadable, and inherits the typed
/// write/delete surface from the existing protocol.
protocol ProfilePayloadStorage: EncryptedLocalStorage {
    /// The stored payload verbatim, or nil when the key is absent AND
    /// when a file exists but does not yield a payload.
    func readRawData(key: String) -> Data?
    /// true  = a payload exists for `key` (even if unreadable),
    /// false = no payload,
    /// nil   = unknowable (store location unresolvable, or the file
    ///         channel does not expose the probe). Never read as absent.
    func hasPayload(key: String) -> Bool?
}

protocol UserProfileStoring: AnyObject {
    /// Never throws; a failure is an explicit case. Callable from any
    /// queue; the result is cached after the first disk read.
    func load() -> ProfileLoadResult
    /// Main-thread writer (UI-initiated through the coordinator). Atomic;
    /// on failure the previously stored record stays in effect and the
    /// cache is not touched.
    func save(_ profile: UserProfile) -> Result<Void, ProfileStoreError>
}

final class UserProfileStore: UserProfileStoring {
    static let storageKey = "user.profile"   // constant, not tunable
    init(storage: ProfilePayloadStorage, observabilityBus: ObservabilityBus?)
}
```

**File naming and placement (no change to the existing pattern).** The key is placed by the
existing `StoragePlacementPolicy` on the encrypted-file channel (it is not in
`keychainResidentKeys`): Application Support / `EncryptedStore/`, file named
`<sha256("user.profile")>.json`, envelope `{key, payload}`, written `.atomic` +
`.completeFileProtection`, excluded from backup. The migration seam
(`MigratingEncryptedStorage`) is where the routing lives; `user.profile` is a new key, so no
legacy copy can exist.

**Probe conformance (additive; no call site changes).**

```swift
// Extension inside Services/Storage/EncryptedFileStorage.swift
// (file-scoped access to the private URL builder).
extension EncryptedFileStorage: ProfilePayloadStorage {
    /// nil only when the store has no root (Application Support
    /// unavailable) — the load path must not read that as "absent".
    func hasPayload(key: String) -> Bool? {
        guard let url = url(for: key) else { return nil }
        return fileManager.fileExists(atPath: url.path)
    }
}

// Extension inside Services/Storage/MigratingEncryptedStorage.swift
// (file-scoped access to `files`, `keychain`, `migrateToFileIfPossible`).
extension MigratingEncryptedStorage: ProfilePayloadStorage {
    /// Mirrors `read()`'s precedence: snapshot → files → legacy Keychain
    /// (+ the existing transactional migration), so a record that landed
    /// on the Keychain fallback channel is still read honestly.
    func readRawData(key: String) -> Data?
    /// files probe; on `false`, a legacy Keychain copy still counts as
    /// present; `nil` when the file channel cannot probe.
    func hasPayload(key: String) -> Bool?
}
```

**Load state mapping (exhaustive).**

| Probe | Raw read | Decode | Result | Side effects |
|---|---|---|---|---|
| `nil` | — | — | `.unreadable(.readFailed)` | cached; `profile_store_unreadable` `read_failed` |
| `false` | — | — | `.absent` | cached; `profile_store_absent` |
| `true` | `nil` | — | `.unreadable(.decodeFailed)` | best-effort `delete`; cached as `.absent` when the delete succeeded, else cached `.unreadable`; `profile_store_unreadable` `decode_failed` |
| `true` | data | throws | same as the row above | same |
| `true` | data | ok | `.loaded` | cached; `profile_store_loaded` |

The **first** load of a corrupt payload returns `.unreadable(.decodeFailed)`; the payload is then
discarded (L1 §3.2) and the cache holds what the store now contains. Events are emitted once per
disk observation, never per cache hit, never in a loop.

### 5.2 Wizard + editor model interfaces (C02, C03, C04, C11)

```swift
// OnboardingState.swift — the only change to the enum:
enum Step: String, CaseIterable, Identifiable {
    case language, permissions
    case aboutYou            // NEW
    case familyContact
    case emergencyContacts   // NEW
    case voiceFingerprint    // NEW
    case models
}
// The type's doc comment gains one clarifying line: every step is
// skippable; the About-you step additionally gates its NEXT button on the
// required fields (ADR-04) — this keeps the documented no-hard-gate
// contract true and the two pinned tests in agreement.
```

```swift
// App/OnboardingDrafts.swift — pure, unit-testable wizard helpers.

struct ProfileEntryBounds: Equatable {
    var addressAsMaxGraphemes: Int = 24   // L1 §11 addressAsMaxGraphemes
    var nameMaxGraphemes: Int = 60        // L1 §11 nameMaxGraphemes
    static let `default` = ProfileEntryBounds()
}

struct AboutYouDraft: Equatable {
    var name: String = ""
    var addressAs: String = ""
    var dateOfBirth: Date? = nil
    var hasDateOfBirth: Bool = false
    /// Trimmed non-empty name AND address-as (the Next gate, FR-PI-002).
    var isComplete: Bool
    /// The single permitted normalisation (trim) applied to name and
    /// address-as; GP/hospital preserved from `base` (FR-PI-010).
    func merged(into base: UserProfile) -> UserProfile
}

struct EmergencyContactsDraft: Equatable {
    var emergencyDoctor: String = ""
    var localHospital: String = ""
    var nextOfKinID: UUID? = nil
    /// Trims the two text fields; empty → nil; name/address-as/DOB
    /// preserved from `base`.
    func merged(into base: UserProfile) -> UserProfile
}
```

```swift
// App/Components/AddressAsField.swift
enum AddressAsPresets {
    /// Chip options per language code. Data, not catalog strings: a chip's
    /// term IS the stored term (ADR-05 / FR-PI-010), never a localised
    /// display string. Suggested sets: ne — आमा, ममी, बुबा, दाइ, दिदी,
    /// बजै, हजुरबुबा, हजुरआमा; en — Mum, Mom, Dad, Grandma, Grandpa.
    /// Unknown language falls back to the en set.
    static func terms(for languageCode: String) -> [String]
}

struct AddressAsField: View {
    @Binding var text: String
    let locale: Locale
    var bounds: ProfileEntryBounds = .default
    // Chips (Buttons, accessibilityLabel = the term as data) write the
    // term into `text`; the TextField clamps writes to
    // bounds.addressAsMaxGraphemes on Character boundaries via
    // ProfileText.clamped(_:maxGraphemes:).
}
```

```swift
// App/ProfileSettingsModel.swift
@MainActor
final class ProfileSettingsModel: ObservableObject {
    enum SaveState: Equatable { case idle, saved, failed }
    @Published var name: String
    @Published var addressAs: String
    @Published var hasDateOfBirth: Bool
    @Published var dateOfBirth: Date?
    @Published var emergencyDoctor: String
    @Published var localHospital: String
    @Published private(set) var saveState: SaveState

    init(coordinator: AppCoordinator, bounds: ProfileEntryBounds = .default)
    /// Prefill from `coordinator.currentProfileSnapshot()`; empty strings
    /// for absent/cleared fields.
    func load()
    /// Merges via AboutYouDraft/EmergencyContactsDraft semantics and
    /// writes through `coordinator.saveProfile`. Empty name/address-as is
    /// allowed here (clearing = back to the un-personalized path,
    /// FR-PI-011); the wizard gate is the wizard's contract only.
    func save()
}
```

**Wizard step views (all `private struct` in `App/OnboardingWizardView.swift`, on the existing
chrome).**

- `AboutYouStep(onNext:)` — name field (clamp 60), `AddressAsField`, optional DOB (`Toggle` +
  `DatePicker`; components built with only year/month/day set, no calendar/timezone);
  primary button `onboarding.next` disabled while `!draft.isComplete`; on tap: merge into
  `coordinator.currentProfileSnapshot()` then
  `coordinator.saveProfile(...)`; `writeFailed` → inline `profile.error.saveFailed` text and stay.
- `FamilyContactStep` (existing) — additionally renders the store's contacts as a read-only
  confirmation list (`settings.family.empty` when none); writes unchanged.
- `EmergencyContactsStep(onNext:)` — kin list from `coordinator.familyContacts`: tapping a contact
  writes `isEmergencyContact: true` through `updateFamilyContact` (passing its current values) and
  clears the flag on any **other** flagged contact, so the wizard produces the singular
  designation the requirement describes; plural flags remain legal in the store and resolve
  through the existing `preferredEmergencyContact(_:)` rule unchanged (first flagged in list
  order — verified in the shipped code). Empty list → the minimal inline form (reusing
  `onboarding.stepFamily.*` field keys) calling
  `addFamilyContact(name:phone:relationship:isEmergencyContact: true)`. GP/hospital TextFields
  save with Next via `EmergencyContactsDraft`.
- `VoiceFingerprintStep(onNext:)` — `@StateObject` session constructed exactly as
  `VoiceSettingsView` constructs it; minimal UI driven by `session.phase` /
  `session.collectedCount` (idle → "Record sample n of 3"; recording → stop; ready → done; failed →
  the session's copy + `dismissFailure()`); Next always available.
- `stepContent` gains the three cases; the exhaustive switch makes every future reorder visible.

### 5.3 Prompt guard + personalization interfaces (C07)

```swift
// Services/Voice/ProfilePromptTextGuard.swift

enum ProfileText {
    /// Character-boundary prefix (grapheme clusters are never split).
    static func clamped(_ value: String, maxGraphemes: Int) -> String
}

struct ProfilePromptTextGuard {
    /// Composition bound (L1 §11 maxPromptTermGraphemes). Default = the
    /// entry bound, so a stored term is never truncated at composition.
    let maxPromptTermGraphemes: Int
    init(maxPromptTermGraphemes: Int = 24)

    /// nil in → nil out. nil out when:
    ///  - the value is empty/whitespace after quarantine,
    ///  - the quarantine action left a residual injection-marker shape
    ///    (strip-then-detect via InputSanitiser's single-sourced table),
    ///  - the bounded value is empty.
    /// Slot neutralisation: `"` (U+0022) is replaced with `'` (U+0027)
    /// so the term can never terminate the clause's quoted slot. This is
    /// prompt-side only — the stored and spoken term is untouched
    /// (FR-PI-010, ADR-09).
    func guarded(_ value: String?) -> String?
}
```

```swift
// Services/Voice/ProfilePersonalization.swift

protocol ProfilePersonalizationReading: AnyObject {
    /// Guarded term for prompt composition; nil = un-personalized.
    var addressAsForPrompt: String? { get }
    /// The stored term, verbatim, for the wake acknowledgment; nil when
    /// absent/unreadable/empty. Never guard-processed (ADR-09 asymmetry).
    var addressAsVerbatim: String? { get }
}

final class ProfilePersonalization: ProfilePersonalizationReading {
    init(storage: UserProfileStoring,
         promptGuard: ProfilePromptTextGuard,
         observabilityBus: ObservabilityBus?)
}
```

Behaviour: `addressAsVerbatim` returns the stored (already-trimmed) value when the load result is
`.loaded`; `.absent` / `.unreadable` / empty → `nil` (no placeholder, ever). `addressAsForPrompt`
applies `guarded(_:)` and, on a `nil` result for a non-nil input, emits
`profile_prompt_text_quarantined` (outcome `quarantined`, no metadata). Guard evaluation runs per
read; readings without a residual emit nothing.

### 5.4 Ack service interfaces (C05)

```swift
// Services/Voice/WakeAcknowledgment.swift

protocol WakeAcknowledging: AnyObject {
    /// Starts the acknowledgment if a term is recorded; calls `completion`
    /// exactly once, on the main queue, within `wakeAckMaxHoldSeconds`.
    /// No term / unresolvable template → completion synchronously.
    /// `cancel()` may drop a pending completion (pipeline stop or a
    /// superseding capture — in both cases the completion is stale by
    /// definition; see the state machine, §7.1).
    func begin(completion: @escaping () -> Void)
    /// Cancels any in-flight ack: playback stopped, bookkeeping balanced,
    /// pending completion dropped, no event.
    func cancel()
}

final class WakeAcknowledgmentService: WakeAcknowledging {
    init(speaker: Speaker,
         termProvider: @escaping () -> String?,
         localeProvider: @escaping () -> Locale,
         onSpeakingStarted: @escaping () -> Void,
         onSpeakingEnded: @escaping () -> Void,
         wakeAckMaxHoldSeconds: TimeInterval = 2.5,
         templateKey: String = "wakeAck.personalized",
         observabilityBus: ObservabilityBus? = nil)
}
```

**Phrase composition contract.** `phrase(term:templateKey:locale:) -> String?` resolves the
template through `L10n.str`; if the resolved string equals the key (unresolved), or contains no
`%@`, or the formatted result does not contain the term verbatim, the phrase is `nil` and the
service emits `wake_ack_failed` (`error_code: "template_missing"`) and completes synchronously —
a key or placeholder is never spoken.

**Pipeline seam.**

```swift
// VoicePipeline.swift
var wakeAcknowledger: WakeAcknowledging?   // nil default; wired by AppCoordinator

private func handleWakeDetected() {
    // unchanged: state/wakeWordGate guard; captureGeneration += 1; the
    // per-capture buffer resets; emit("wake_word_detected"); turnTracer.beginTurn()
    if let ack = wakeAcknowledger {
        ack.begin { [weak self] in self?.beginCapture(generation: generation) }
    } else {
        beginCapture(generation: generation)   // today's exact path
    }
}

private func beginCapture(generation: Int) {
    guard captureGeneration == generation, state == .idle else { return }
    // today's capture-start body VERBATIM, in order: the noise-filter
    // capture bookend, the legacy/push recognizer branch (VAD reset +
    // callbacks), state = .capturingCommand, the wedge-guard
    // asyncAfter, speechRecognizer.startListening(timeout:)
}

func stop() {
    startGeneration += 1
    captureGeneration += 1
    wakeAcknowledger?.cancel()   // NEW — before engine teardown
    // ...unchanged
}
```

**Extraction rationale for the ack-first order.** Moving the noise-filter bookend into
`beginCapture` keeps the ack's own audio out of the ambient noise profile the capture computes for
the user's utterance. `simulateWakeWordDetection()` routes through the same handler, so the Talk
button gets the same acknowledgment (ADR-06, recorded). The pipeline state stays `.idle` during
the ack; the wake gate closes through the coordinator's `noteSpeakingStarted` hook, which the
shipped wiring delivers on a main-queue async hop (AM-3 — this text previously claimed a
synchronous close at `begin`), so a detection racing the ack start is normally rejected by the
existing `allowsWakeDetection` guard, and in the narrow window before the hop lands the ack
service's supersede teardown owns the old ack: the worst observable outcome is a restarted
greeting, never a doubled capture start (the racing pair is pinned by
`WakeAcknowledgmentSeamTests` + `WakeAcknowledgmentServiceTests`).

### 5.5 Prompt builder interfaces (C06, C08)

```swift
// LlamaCommandInterpreter.swift — final L2 form (see §13, item 1).
struct InterpreterContext {
    let pendingMedications: [String]
    let userLanguageHint: String
    let addressAs: String?          // guarded term; nil = un-personalized

    init(pendingMedications: [String],
         userLanguageHint: String,
         addressAs: String? = nil)
}

// IntentPrompt.swift — settled wording (L1 candidate adopted as final).
private static func addressAsClause(_ term: String?) -> String {
    guard let term, !term.isEmpty else { return "" }
    return " Address them as \"\(term)\" where it fits, never every sentence."
}
```

**Interpolation positions (exact anchors).**

- `build` — appended directly after the text `one short idea per sentence.` on the
  `"response" is SPOKEN ALOUD` line.
- `buildChat` — appended directly after `one short idea per sentence.` in its Nepali line (before
  ` Never invent a fact…`).
- `buildUnderstanding` — appended directly after `…keep one short idea per sentence.` in the
  `Reply style` bullet.

**Construction sites (the only two; verified by grep).** `CommandRouter.swift` (~1412) and
`AppCoordinator.swift` (~3601, the Gemini collapse provider) both pass
`addressAs: profilePersonalization?.addressAsForPrompt`. Downstream call sites of
`IntentPrompt.build` / `buildChat` / `buildUnderstanding` (Gemini interpreter, Llama interpreter,
local interpreter, Gemini client) need no edits — the clause arrives through the context value.

### 5.6 Coordinator seams (C01 writer + read snapshots)

```swift
// AppCoordinator — additions only; main-thread writer, any-queue reads.

/// The only writer for the profile record (wizard + Settings call it).
/// The five values are written as the complete new record; callers merge
/// by reading `currentProfileSnapshot()` first.
@discardableResult
func saveProfile(name: String,
                 addressAs: String,
                 dateOfBirth: DateComponents?,
                 emergencyDoctor: String?,
                 localHospital: String?) -> Result<Void, ProfileStoreError>

/// The store's cached load result; no disk I/O after the first read.
/// Any queue.
func currentProfileSnapshot() -> ProfileLoadResult

/// The read seam the interpreters and the ack service consume. Created in
/// `init()`; nil means "not wired" (tests) and is consumed as nil-safe.
private(set) var profilePersonalization: ProfilePersonalizationReading?
```

**Construction order (why `init()`).** The wizard runs **before** `coordinator.start()`, so the
store, guard, and personalization seam are built in `AppCoordinator.init()` next to the existing
storage composition; only the ack service (needs the speaker) is built in `start()`, where the
seam is also handed to the pipeline (`voicePipeline.wakeAcknowledger = …`) and the base speaker
instance is passed (never a forwarding wrapper — §6).

### 5.7 Settings destination interfaces (C04)

```swift
// SettingsTabs.swift
enum SettingsDestination { /* ... */ case profile }        // new case
// titleKey: "settings.profile.title" · icon: "person.text.rectangle"
// tab: .family  — rows become [.family, .profile, .caregiverNotifications, .calling]

struct SettingsDestinationView: View { /* … case .profile: ProfileSettingsView() */ }
```

The kin note links to the existing family editor via the Settings navigation stack (the same
mechanism the hub uses to push leaves); the row's L10n key and the family-tab test expectations
are updated in the same change (`SettingsTabMappingTests`: family rows list + the visible-row
count 20 → 21).

### 5.8 App-start routing interfaces (C13)

```swift
// AppCoordinator.swift
/// Cold-start interview routing (FR-PI-016). Evaluated by the shell once
/// per process. Synchronous, main-thread; reads the persisted step map
/// and the profile store's cached load result only — no async work, so
/// no timeout parameter applies.
/// Returns the step to present the wizard at, or nil when the interview
/// is complete. No error return: every failure mode has a defined route
/// (C13's edge table) — the method never throws.
func coldStartInterviewRoute() -> OnboardingState.Step?
```

```swift
// OnboardingDrafts.swift — the trimmed-non-empty predicate, single-sourced
// with the About-you Next gate (FR-PI-002).
extension AboutYouDraft {
    static func mandatoryFieldsRecorded(in profile: UserProfile) -> Bool
}
```

### 5.9 Interface-to-requirement matrix

| Interface element | Requirements |
|---|---|
| `UserProfileStoring.load/save`, `ProfileLoadResult`, `ProfileStoreError` | FR-PI-003, FR-PI-015; NFR-PI-001 |
| `ProfilePayloadStorage.readRawData/hasPayload` | FR-PI-015 (absent vs unreadable); NFR-PI-010 |
| `saveProfile`, `currentProfileSnapshot` | FR-PI-002/003/006/012, FR-PI-015 |
| `OnboardingState.Step` + drafts + steps | FR-PI-001/002/004/005/013; NFR-PI-007 |
| `AddressAsField`, `AddressAsPresets` | FR-PI-002, FR-PI-010; OD-PI-4 |
| `ProfileSettingsModel` | FR-PI-012; OD-PI-5 |
| `ProfilePromptTextGuard.guarded` | NFR-PI-004; Feature Constraint 4 |
| `ProfilePersonalizationReading` | FR-PI-009/010/011, FR-PI-015 |
| `WakeAcknowledging.begin/cancel` | FR-PI-008/010/011; NFR-PI-008 |
| `VoicePipeline.beginCapture`, `stop` cancel | FR-PI-008/011; NFR-PI-010 |
| `InterpreterContext.addressAs`, `addressAsClause` | FR-PI-009/010/011; NFR-PI-005 |
| Seed + renderer + mirror gate | NFR-PI-005; Feature Constraint 2 |
| L10n additions | NFR-PI-006; Feature Constraint 3 |
| LogSanitiser + FEATURE_ROOTS | NFR-PI-002; Feature Constraint 5 |
| `coldStartInterviewRoute`, `mandatoryFieldsRecorded(in:)` | FR-PI-016, FR-PI-002/013; NFR-PI-010 |

---

## 6. Concurrency and isolation

Per shared resource: who reads, who writes, and the isolation mechanism.

| Resource | Readers | Writers | Isolation | Guarantees |
|---|---|---|---|---|
| Encrypted profile file (`user.profile`) | Any queue, through `UserProfileStore.load` / `ProfilePersonalization` | `UserProfileStore.save`, main-thread-only by contract (asserted) | One `NSLock` inside the store guards the cache and the disk access; the underlying `EncryptedFileStorage` writes are atomic (temp + rename) | A reader never sees a partial record; a failed write leaves both the file and the cache on the previous record; the first read primes the cache, later reads are cache hits |
| Prompt assembly (`InterpreterContext` + `IntentPrompt`) | Any interpreter queue | None (values are immutable per turn) | Value semantics; `addressAsClause` is a pure static; the guarded term is computed at the read seam before the context is built | No shared mutable state; the same context value can be read from cloud/on-device paths without coordination |
| Wake-ack path (`WakeAcknowledgmentService`) | `VoicePipeline.handleWakeDetected` (main-confined), `stop()` (main-confined) | same | Main-thread-only by contract, enforced with `dispatchPrecondition(.onQueue(.main))`; single in-flight ack; one `settle` exit | `completion` runs at most once per `begin` (except a `cancel()` that drops it); speaking bookkeeping is balanced exactly once; `begin` closes the wake gate through the coordinator's speaking hook, which the shipped wiring delivers on a main-queue async hop (AM-3) — the supersede path covers the racing window |
| `VoicePipeline` capture epoch | — | `handleWakeDetected` / `stop` (main) | Existing `captureGeneration` counter + the added `state == .idle` check in `beginCapture` | A stale ack completion (superseded capture, stop race) is inert; `stop()` cancels the ack and bumps the epoch, double-protecting the invariant |
| Family contacts (`family.contacts`) | Existing published list (main) | Existing coordinator methods, main | Unchanged existing store behaviour | The emergency step's flag writes are ordinary existing edits; the safety path's rule is untouched |
| Wizard / Settings state | Main actor (SwiftUI) | Main actor | Existing pattern | `ProfileSettingsModel` and the step views are `@MainActor` |
| Voice enrollment session | Main actor | Main actor | Existing `@MainActor` + `VoicePipelineSuspending` cycle | Unchanged; the pre-`start()` wizard context is handled by the existing no-live-pipeline path |
| Cold-start interview routing (`coldStartInterviewRoute`) | Shell views, main thread, once per process | None — pure read (no mutation) | One-shot `@State` in the shell; the profile read uses the store's existing lock/cache; `scenePhase` deliberately not observed | The decision is stable for the process lifetime; no background re-evaluation; returning to Home never re-presents the wizard |

**Why the ack service takes the base speaker.** The coordinator's reply lane wraps the shared
speaker in `SpeechNoteForwarder` (it calls `noteSpeakingStarted/Ended` per utterance). The ack
service receives the **base** `PiperVoiceSpeaker` instance plus the coordinator's note closures,
so each ack balances the speaking count exactly once — wrapping a second forwarder would
double-count.

---

## 7. Error handling and observability

### 7.1 Ack state machine (C05)

States: `idle`, `active`. Fields: `completion`, `maxHoldWorkItem`, `speakTask`,
`speakingOutstanding`, `startedAt`.

| Event | Condition | Actions (in order) | Completion |
|---|---|---|---|
| `begin` | state active (unreachable through the pipeline — defensive) | teardown of the old ack as `superseded` (playback cancel, balance speaking, drop old completion, no event) | dropped (old); new one proceeds |
| `begin` | term nil/empty | none | called synchronously |
| `begin` | phrase nil (template/unresolved/term not present) | `wake_ack_failed` `template_missing` | called synchronously |
| `begin` | phrase ok | `speakingOutstanding = true`; `onSpeakingStarted()`; state `active`; `speakTask = Task { await speaker.speak }; schedule maxHold timer | pending |
| speak returns (played or cancelled) | state active | `settle(.spoken)` | called |
| timer fires | state active | `speaker.cancel()`; `wake_ack_timeout` `hold_exceeded`, `duration_ms` = hold | called |
| `cancel()` | state active | `speaker.cancel()`; no event | dropped |
| any settle | — | cancel timer; balance `onSpeakingEnded()` once; clear task/completion; state `idle`; then call the completion | — |

Notes. `Speaker.speak` is non-throwing, so "failed" is exactly the phrase-resolution failure
above; a synthesis that dies silently inside the speaker presents as the timeout path (the
existing fallback chain inside the speaker is unchanged). The "exactly once, within
`wakeAckMaxHoldSeconds`" contract holds for every path except `cancel()`, which is only called
when the pending completion is by definition stale (`stop()`, supersede).

### 7.2 Error taxonomy

| # | Error | Trigger | Retry | User sees | Operator sees |
|---|---|---|---|---|---|
| E1 | `ProfileStoreError.readFailed` | store cannot answer presence | no | nothing (un-personalized) | `profile_store_unreadable` `read_failed` |
| E2 | `ProfileStoreError.decodeFailed` | present but undecodable | no | nothing (un-personalized) | `profile_store_unreadable` `decode_failed`; payload discarded |
| E3 | `ProfileStoreError.writeFailed` | atomic write failed | user re-taps | inline `profile.error.saveFailed`; nothing claimed; previous value intact | none (no event in v1 — the L1 catalogue is followed exactly; the failure is user-visible) |
| E4 | guard rejection | residual marker / empty after quarantine | no | nothing (un-personalized turn) | `profile_prompt_text_quarantined` |
| E5 | ack phrase unavailable | unresolved template / term not present after formatting | no | silent start (today's behaviour) | `wake_ack_failed` `template_missing` |
| E6 | ack hold exceeded | playback not finished within the bound | no | capture starts; greeting cut off at worst | `wake_ack_timeout` `hold_exceeded` |
| E7 | contact write `false` | store add/update failed | user retries | inline message; list reloads | existing contact-path behaviour |
| E8 | interview status unreadable/corrupt | step map or profile snapshot unusable at cold start | no | wizard opens at the first pending step; every step skippable; never trapped | none (no new event in v1 — the routing outcome is user-visible and the requirement carries no log surface; C13 records the decision) |

### 7.3 Event catalogue (no new metadata keys; all values content-free)

| Event (`component` / `eventType`) | outcome | errorCode | durationMs | metadata | Emission point |
|---|---|---|---|---|---|
| `profile` / `profile_store_loaded` | `success` | — | — | `[:]` | first disk load that decodes |
| `profile` / `profile_store_absent` | `success` | — | — | `[:]` | first load, nothing stored |
| `profile` / `profile_store_unreadable` | `failure` | `read_failed` \| `decode_failed` | — | `[:]` | first load of an unusable payload |
| `profile` / `profile_store_saved` | `success` | — | — | `[:]` | successful save |
| `profile_guard` / `profile_prompt_text_quarantined` | `quarantined` | — | — | `[:]` | guard dropped a term |
| `wake_ack` / `wake_ack_spoken` | `success` | — | hold ms | `[:]` | playback finished within the bound |
| `wake_ack` / `wake_ack_timeout` | `failure` | `hold_exceeded` | hold ms | `[:]` | bound reached; playback cancelled |
| `wake_ack` / `wake_ack_failed` | `failure` | `template_missing` | — | `[:]` | phrase unavailable; silent start |

`outcome` values follow the shipped free-form vocabulary (`success` / `failure`, plus the
explicit `quarantined` marker); `error_code`, `duration_ms`, and `outcome` are all already in
`LogSanitiser.allowedKeys`, so the scan-gate rules pass on the new roots without widening the
allow-list. L1's `term_present` boolean on `wake_ack_spoken` is dropped as redundant (the event
only fires when a term was spoken) — recorded in §13, item 4.

### 7.4 Log safety (C10)

- `LogSanitiser.redactedKeys` gains `profile_name`, `address_as`, `date_of_birth`,
  `emergency_doctor`, `local_hospital`. Redaction runs before the allow-list filter, so the
  fail-closed direction holds: if a future diagnostic ever emits one of these keys, the value is
  replaced by `[redacted]` first and the key is then dropped by the allow-list (it is
  deliberately **not** added to `allowedKeys` — no shipped event carries it).
- `ios/tools/check-release-log-safety.py` `FEATURE_ROOTS` gains the feature's own sources:
  `Services/Storage/UserProfileStore.swift`, `Services/Voice/WakeAcknowledgment.swift`,
  `Services/Voice/ProfilePromptTextGuard.swift`, `Services/Voice/ProfilePersonalization.swift`,
  `App/Components/AddressAsField.swift`, `App/ProfileSettingsView.swift`,
  `App/ProfileSettingsModel.swift`, `App/OnboardingDrafts.swift`. Rules 3–6 then apply to them:
  no Release-compiled console write, no content in any configuration, metadata keys must be in
  the shipped allow-list (they are), no text interpolated into an event field (none is).

### 7.5 What the user / operator sees

| Flow | Success | Failure |
|---|---|---|
| About-you Next | advances; values persisted; next wake greets by term | inline `profile.error.saveFailed`, step stays, nothing claimed |
| Emergency step Next / kin pick | values persisted; flag reflected in Settings too | inline message; selection reloads from the store |
| Voice fingerprint | session's existing ready state | existing failure states; Next still advances |
| Settings save | confirmation text; effective next wake/reply | inline message; previous value remains in effect |
| Wake with term | `हजुर <term>` (ne) / `Yes, <term>` (en, OD-A2), then listening | silent start (E5) or a cut-off greeting then listening (E6); never a retry loop |
| Store unreadable | n/a | nothing visible; exactly today's assistant behaviour |
| Cold start, interview incomplete | wizard opens at the first pending step (FR-PI-016) | corrupt/unreadable state → wizard from the first pending step; still skippable; no crash or stall |

---

## 8. Configuration

Named, injectable, with defaults; no call-site magic numbers.

| Parameter | Type | Default | Declared at | Wired at |
|---|---|---|---|---|
| `wakeAckMaxHoldSeconds` | `TimeInterval` | 2.5 | `WakeAcknowledgmentService.init` | `AppCoordinator.start()` |
| `templateKey` | `String` | `"wakeAck.personalized"` | `WakeAcknowledgmentService.init` | `AppCoordinator.start()` |
| `maxPromptTermGraphemes` | `Int` | 24 (= entry bound) | `ProfilePromptTextGuard.init` | `AppCoordinator.init()` |
| `addressAsMaxGraphemes` | `Int` | 24 | `ProfileEntryBounds` | wizard + Settings editor |
| `nameMaxGraphemes` | `Int` | 60 | `ProfileEntryBounds` | wizard + Settings editor |
| `storageKey` | `String` | `"user.profile"` | `UserProfileStore` (constant, not tunable per L1 §11) | — |

Async/external call timeouts: the only added async call is `Speaker.speak` from the ack service —
bounded by `wakeAckMaxHoldSeconds` (default 2.5 s). The store adds no async call and no timeout:
its I/O is synchronous local-disk work behind its lock (the existing atomic-write pattern), and
it performs no network of any kind. The enrollment session's async methods keep the existing
mechanism's behaviour with no new timeout.

FR-PI-016 routing adds no parameter and no async call: `coldStartInterviewRoute()` is a single
synchronous cached read (the ack bound and the entry bounds above are unaffected). The
background→foreground re-check is deliberately not implemented in v1 — recorded in C13.

---

## 9. Performance and security implementation patterns

### 9.1 Prompt budget proof (NFR-PI-005)

- **Ceiling unchanged:** `IntentPromptTests` pins `prompt.count <= 3_000` for the fixture. The
  ceiling is not raised.
- **Measured base:** the fixture renders to **2,506** Swift `Character`s (2,718 UTF-8 bytes)
  today. The in-file test comment's "2,936" is stale — it predates the `[GEMINI-SOLIDIFY]`
  trim (2026-09-18); the comment is corrected to the measured value in the same change so a
  future trim starts from truth (§13, item 2).
- **Worst-case composition:** 2,506 + 56 (clause static) + 24 (term at the entry bound) =
  **2,586 ≤ 3,000**, headroom **414**. An 8-grapheme Devanagari term measures 64 → 2,570. The
  composition bound equals the entry bound, so no stored term is ever truncated.
- **Token view:** the ceiling was calibrated against the real tokenizers (696 qwen3 / 677 gemma
  tokens at the base); the worst-case addition is ≤ 80 characters (roughly ≤ 20 tokens), leaving
  ≈280 tokens for the utterance and JSON inside the 1,024-token on-device context.
- **Runtime cost:** the guard is O(term length ≤ 200) on an already-sanitised string; the
  personalization read is a lock + cached-value read (no disk after the first read).

### 9.2 Seed mirror gate (NFR-PI-005, Feature Constraint 2)

- `ios/tools/check-prompt-mirror.sh` (wrapper, mirroring the log-safety gate's shape) calls
  `ios/tools/check-prompt-mirror.py`; `ios/build.sh` runs it beside
  `tools/check-release-log-safety.sh` before every test scope and fails the build on a non-zero
  exit.
- The checker: extracts the `build` literal from `Services/Voice/IntentPrompt.swift` with Swift
  multiline-literal semantics (dedent by the closing delimiter's indentation; drop exactly one
  trailing newline), replaces the four interpolation sources — `\(context.userLanguageHint)`,
  `\(meds)`, `\(transcript)`, `\(addressAsClause(context.addressAs))` — with
  `{language_hint}`, `{medications}`, `{transcript}`, `{address_as_clause}`, then asserts byte
  equality with `tools/train-intent` `/seeds/prompt_template.txt`.
- Failure modes are loud: extraction failure, missing/duplicated interpolation, missing
  placeholder, or any byte mismatch exits non-zero with a diff excerpt. There is no pass-by-default.
- The checker's first run established the current drift: the seed ends `request.\n\n`, the
  template `request.\n` — 2,699 vs 2,698 bytes. The C08 change removes the seed's extra newline
  and adds the 18-byte placeholder (net 2,716 bytes), making `render_prompt(..., address_as_clause: "")`
  byte-identical to the pre-feature rendered prompt (§13, item 3).

### 9.3 Injection discipline (NFR-PI-004, Feature Constraint 4)

Applied at the read seam, before any context construction, in this order:
quarantine via `InputSanitiser.sanitise(value, level: .quarantine)` (control-strip, whitespace
collapse, marker removal, clamp 200) → `containsInjectionMarker` (strip-then-detect, single-sourced
table) → `Character`-boundary clamp to `maxPromptTermGraphemes` → quote-slot neutralisation
(`"` → `'`) → nil on any residual. The term then appears only inside the quoted slot of the
clause and is explicitly framed as data ("Address them as …"). The ack speaks the stored term
verbatim and never guard-processes it (TTS, not a prompt — ADR-09 asymmetry). Model output
remains untrusted exactly as today; nothing in a reply can cause a profile write or an action.

### 9.4 Storage and privacy patterns (NFR-PI-001, NFR-PI-003)

- All five fields live on the encrypted-file channel (Data Protection Complete, not backed up,
  atomic writes); no plaintext copy exists at any point, including the atomic temp file.
- DOB is stored as year/month/day components, never spoken, never composed into any prompt or
  payload; GP/hospital likewise never leave the device. The only profile value that can reach an
  engine is the guarded term, under the existing consent-gated cloud path (ADR-11).
- The ack's synthesis uses the existing `PiperVoiceSpeaker` path whose temp WAV is deleted after
  playback; no personalized audio is cached (ADR-06).
- No new permissions, no HealthKit, no new egress. `Info.plist` untouched.
- Cold-start routing (C13) reads the store's cached load result — priming it once on the main
  thread (one small synchronous local read, the same first read personalization would perform)
  — and performs no polling, no background work, no network.

---

## 10. Technical risks and mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Ack synthesis latency misses NFR-PI-008's ≤ 1 s activation on a slow device (OD-A1, evidence owed) | medium | low | Ack-first design; warmed Piper engine (existing WarmStart); the fallback ladder stays L1's: warm the engine, then a memory-only pre-synthesis keyed by term+voice (never a disk artifact), then shorten copy. The implement/security-test tasks measure detection→first audio on a device |
| R2 | Piper synthesises while the mic is live; a race lets the tail of the greeting reach the recognizer | low | low | Ack-first with a bounded hold; speaker cancelled before capture starts on timeout/cancel; the gate closes through the coordinator's speaking hook on a main-queue async hop (AM-3), so the racing window is real and handled by the supersede path; worst case is a short clipped greeting in the transcript, bounded by the existing capture timeout |
| R3 | Prompt budget regression from a future edit | medium | medium | Pinned 3,000-char ceiling test unchanged + comment corrected to 2,506; seed gate blocks template/seed drift; the measured table in §9.1 is the baseline for future changes |
| R4 | The seed-mirror checker mis-emulates Swift's literal semantics | low | medium | The checker implements the two rules verified by compilation in this task (dedent + exactly one dropped trailing newline) and fails loudly on extraction anomalies instead of passing |
| R5 | `wake_ack_spoken` timeout at 2.5 s cuts a slow synthesis before any audio, so a personalized user hears nothing on a slow boot | low | low | Same fallback as today (silent start); the timeout path emits `wake_ack_timeout` so the frequency is observable; OD-A1 measurement drives any default change (the parameter is injectable) |
| R6 | Multiple flagged contacts confuse "next of kin" | low | low | The wizard step produces a single flag (clears others); plural flags from the Settings editor remain legal and resolve through the existing first-flagged rule, unchanged |
| R7 | Corrupt-store discard loop on a locked device | low | low | The first load deletes best-effort and caches the outcome; no path re-reads in a loop; a save overwrites cleanly |
| R8 | Settings "link to family editor" assumed a navigation stack | low | low | If the Settings stack cannot push a leaf from a leaf in implementation, the note degrades to text with the same information; tracked as an implementation detail, not a contract |
| R9 | Guard false-positives reject a legitimate term (e.g. a term containing a marker-like phrase) | low | low | The rejection is per-turn and un-personalized — no crash, no user error; `profile_prompt_text_quarantined` makes it visible; the ACK still speaks the term verbatim (the user still hears their greeting) |
| R10 | Devanagari grapheme handling in clamps/truncation | low | medium | All clamps use `Character` prefixes (`ProfileText.clamped`); tests pin a Devanagari fixture (conjuncts are single Characters) |
| R11 | The one-byte seed drift repeats (edits to one file only) | medium (historically) | medium | The new build-blocking gate; the Swift file's doc comment and `intent_prompt.py`'s loud placeholder failure remain |
| R12 | L10n key for the ack template missing in a language | low | low | Phrase builder refuses unresolved templates (silent start + `wake_ack_failed`); `SettingsTabMappingTests`' L10n sweep plus the catalog additions cover the rest |
| R13 | Startup routing repeats on every cold start until the interview is completed — a user who deliberately declines to give a term is routed each launch | medium (required by the amendment) | low | The OD-F3 soft-skip and the dismissible presentation guarantee they are never trapped, and completing the steps (or the Settings editor) ends the routing; the behaviour itself is the owner's amendment (Feature Constraint 8), not an implementation choice |

---

## 11. Traceability (delta vs L1 §13)

L1's traceability table stands (it predates the 2026-10-05 amendment). The L2 additions that
complete it — coverage now **16/16 FR-PI and 11/11 NFR-PI**:

| Requirement | L2 design points |
|---|---|
| FR-PI-001 / FR-PI-013 | Step enum extension (§5.2); pending-by-construction from legacy status maps; `OnboardingStateTests` additions |
| FR-PI-002 / FR-PI-004 | `AboutYouDraft.isComplete`; Skip path unchanged; both pinned by tests |
| FR-PI-003 / FR-PI-015 | `UserProfileStoring`, load state mapping table (§5.1), cache/discard semantics, E1/E2 |
| FR-PI-005 / FR-PI-006 / FR-PI-014 | `EmergencyContactsStep` writes through the existing contact APIs; flag semantics documented (§5.2); `preferredEmergencyContact` untouched |
| FR-PI-007 | `VoiceFingerprintStep` canonical construction; pre-`start()` suspension safety verified (§13, item 5) |
| FR-PI-008 / FR-PI-010 / NFR-PI-008 | Ack state machine (§7.1), phrase composition contract (§5.4), pipeline seam (§5.4) |
| FR-PI-009 / FR-PI-011 | Clause + interpolation anchors (§5.5); no-term byte-identity via the clause `""` and the pinned digest test (Section 12) |
| FR-PI-012 | `ProfileSettingsModel`, destination row, cache-swap effectiveness (§5.2, §5.7) |
| NFR-PI-001 | §9.4; store on the encrypted-file channel |
| NFR-PI-002 | Event catalogue (§7.3), redacted keys + scan roots (§7.4) |
| NFR-PI-003 | §9.4; only the guarded term ever composes into a prompt |
| NFR-PI-004 | §9.3 guard pipeline incl. quote-slot neutralisation |
| NFR-PI-005 | §9.1 budget proof; §9.2 mirror gate |
| NFR-PI-006 | C09 key list |
| NFR-PI-007 | Existing wizard/Settings chrome + `DesignTokens`; chips as ≥44 pt buttons |
| NFR-PI-009 | C12: call site only; no mechanism/permission change |
| NFR-PI-010 | §5.4 extraction keeps today's capture-start body verbatim; nil-seam path; `InterpreterContext` init keeps every call site compiling |
| NFR-PI-011 | §7.4 gate wiring; disclosure item unchanged (owner/compliance, 2026-10-13 window) |
| FR-PI-016 (owner amendment 2026-10-05) | C13 route rule + shell wiring (§5.8); the "pending-by-construction" behaviour of legacy status maps is what the cold-start route surfaces. **Supersedes FR-PI-013's "No force-migration" scenario for the app-start path** (recorded in FR-PI-016) — L1's "the wizard is never auto-presented" sentence is superseded; FR-PI-013's `pendingSteps` / `firstPendingStep` / `startingAt:` mechanics are unchanged and are the resume mechanism used here |

---

## 12. Test seams

| Seam | Test (existing file unless noted) | Pins |
|---|---|---|
| `UserProfileStore` over an in-memory `ProfilePayloadStorage` fake (no file system) | `UserProfileStoreTests.swift` (new) | round-trip; absent vs unreadable vs readFailed; corrupt payload removed then read as absent; a failed write leaves the existing record in effect; empty-string partial records; merge helpers (`AboutYouDraft`, `EmergencyContactsDraft`); trim rules |
| `EncryptedFileStorage` probe on a temp directory root | `EncryptedFileStorageProbeTests.swift` (new, small) | `hasPayload` true for a corrupt envelope, false for absent, nil for an unresolvable root |
| Guard with adversarial fixtures | `ProfilePromptTextGuardTests.swift` (new) | marker payloads → nil; quotes → `'`; 24-grapheme clamp (Latin + Devanagari conjuncts); empty/whitespace → nil; nil in → nil out |
| `ProfilePersonalization` over the store fake | `ProfilePersonalizationTests.swift` (new) | verbatim accessor; guarded accessor; quarantine event once per read; absent/unreadable → nil |
| Budget + byte identity | `IntentPromptTests.swift` (extend) | ceiling 3,000 with a 24-grapheme term (2,586); no-term digest pin of the composed `build`; clause position in all three builders; clause `""` for nil/empty |
| Ack state machine with a fake `Speaker` (controllable completion) and `wakeAckMaxHoldSeconds: 0.01` | `WakeAcknowledgmentServiceTests.swift` (new) | sync completion for nil term; spoken path; timeout cancel + event; cancel drops completion; supersede; template-missing path; speaking hooks balanced exactly once |
| Pipeline seam with a stub `WakeAcknowledging` | `WakeAcknowledgmentSeamTests.swift` (new, alongside the existing `VoicePipelineNoiseFilterSeamTests` / `VoiceTurnTimingSeamTests` harnesses using `debugEnterIdleForTesting` + `simulateWakeWordDetection`) | capture starts only after completion; nil seam = synchronous start (today's path); `stop()` cancels the ack; stale completion inert |
| Step order / pending semantics | `OnboardingStateTests.swift` (extend) | 7-case order; legacy status maps leave the three new IDs pending; `firstPendingStep` |
| Settings table + L10n | `SettingsTabMappingTests.swift` (extend) | family rows `[.family, .profile, …]`; visible count 21; `settings.profile.title` resolves in en + ne |
| Editor model | `ProfileSettingsModelTests.swift` (new) | prefill; save success/failure mapping; clearing allowed |
| Seed mirror | `ios/tools/check-prompt-mirror.sh` via `ios/build.sh` | byte equality template↔seed; loud failure otherwise |
| Log surface | `ios/tools/check-release-log-safety.sh` via `ios/build.sh` | new roots clean; metadata keys allow-listed |
| Cold-start routing composition | `ColdStartRoutingTests.swift` (new) | fresh → `.language`; complete → nil; optional pending → first pending; mandatory missing with About-you completed → `.aboutYou`; corrupt/unknown step values read as pending; unreadable profile counts as mandatory missing; the predicate trims like the About-you Next gate |
| Startup presentation | UI test (extend the onboarding UI-test group) | cold start with a pending interview → the wizard appears at the first pending step with the skip affordance; existing Home-assuming UI tests account for the one-time presentation (no new launch argument is introduced — tests manage persisted state as they already do for onboarding) |

---

## 13. Findings and corrections vs L1

All corrections preserve L1's binding intent; each is recorded here for `review-l2`.

1. **`InterpreterContext` defaulted field does not compile as written.** L1 §6.2 sketches
   `let addressAs: String? = nil` with "every existing call site compiles unchanged". Verified by
   compiler experiment: with `let` and a default, the synthesized memberwise initializer omits the
   parameter entirely, so no call site can ever pass a term (the personalization would be dead
   code); with `var` and a default it compiles but makes the field mutable. L2 settles the
   explicit initializer in §5.5 — immutability kept, the parameter defaulted, every existing call
   site source-compatible. Semantics are unchanged; only the mechanism differs.
2. **The budget baseline number is stale.** L1 §6.3 (and the test's comment) cite the fixture at
   2,936 characters; the shipped fixture measures **2,506** (the prompt was trimmed by
   `[GEMINI-SOLIDIFY]`, 2026-09-18). The ceiling stays 3,000; the comment is corrected to 2,506 in
   the same change so the next trim starts from truth. The clause still fits with room to spare
   (2,586 worst case).
3. **The seed mirror was off by one byte.** Byte comparison shows the seed ends `request.\n\n`
   while the Swift template (with placeholders) ends `request.\n` — 2,699 vs 2,698 bytes. The C08
   change removes the extra trailing newline and adds the 18-byte `{address_as_clause}`
   placeholder; the new gate makes the contract enforceable from then on.
4. **`wake_ack_spoken.term_present` dropped.** L1 §7.3 lists a `term_present` boolean; it cannot
   ever be false (the event only fires on the personalized path), and it is not in the shipped
   allow-list. Dropping it keeps the event content-free without widening `allowedKeys`.
5. **Pre-`start()` enrollment safety verified.** `suspendForSampleCapture()` in the shipped
   coordinator returns `true` when `voicePipeline == nil` (the wizard's state), so hosting the
   session in the wizard needs no mechanism change (C12).
6. **Owner amendment, not a correction: FR-PI-016 supersedes one L1 sentence.** L1 §4.1 says the
   wizard "is never auto-presented (no force-migration)"; the 2026-10-05 owner amendment
   (Feature Constraint 8, FR-PI-016) supersedes that for the app-start path — pending steps are
   now surfaced on start. The mechanism sentence around it (`pendingSteps` / `firstPendingStep` /
   `startingAt:`) stands as written and is exactly the mechanism C13 uses.

Not a correction, for completeness: L1's guard sketch names the method `guard(_:)`; `guard` is a
keyword, so L2 settles the name `guarded(_:)` — this is within the L1 §16 hand-off ("final guard
name"), not a deviation.

---

## 14. Hand-off notes

- **`review-l2`** should check: the §13 corrections, the error taxonomy completeness (every
  interface declares its failure return), the concurrency table against the four shared resources
  the dispatch names, the budget arithmetic, and C13's route rule + edge table against FR-PI-016
  (including the cold-start-only decision).
- **`security-design-review` (STRIDE)** focus, per L1 §16, sharpened at L2: the guard pipeline
  incl. the quote-slot neutralisation (§9.3); the read seam's fail-closed nil behaviour
  (§5.1); the ack path as TTS-only with verbatim data (ADR-09); the log surface (§7.4); storage
  at rest (§9.4); no new egress (§9.4).
- **`plan-tasks`**: land the seed + template + mirror gate as one indivisible unit; the store
  (C01) before its consumers; the pipeline extraction before the ack service wiring; the wizard
  step views after the store and drafts; land C13 with the step-enum extension (its route
  references the new step IDs, and it needs no dependency on C01 — a nil/absent snapshot is a
  handled route).
- **`security-test`** hooks: adversarial terms through the guard; no-PII log runs over a
  personalized session; container inspection for plaintext; ack failure injection incl. the
  timeout path; seed-gate negative test (flip one byte → build fails).
- **UI tests:** startup routing presents the wizard once per launch for upgraded states (the new
  step IDs are pending by construction), so existing Home-assuming UI tests must account for the
  one-time presentation; the routing check itself is suppressed under hosted unit tests by the
  existing boot guard.

## 15. Open items

- **OD-A1 (from L1, unchanged):** device-measured wake-ack synthesis latency vs the ≤ 1 s
  activation budget; evidence owed by `implement`/`security-test`. The fallback ladder and the
  injectable `wakeAckMaxHoldSeconds` are already in place.
- **OD-A2 (from L1, unchanged):** the English ack copy `Yes, %@` is an owner eyeball item at this
  gate; the term is never translated or reformatted.
- **Implementation note (not a design decision):** Nepali copy for the new catalog keys and the
  chip presets is drafted as part of the implementation's localisation pass; the chip terms are
  data constants, the surrounding copy is catalogued (C09).
- **Recorded, not open:** App Store privacy-disclosure update for the new fields (NFR-PI-011 #2,
  owner/compliance, 2026-10-13 window); the project-wide biometric/PIN gate remains a recorded
  follow-up outside this feature (OD-PI-5); FR-PI-016's background→foreground question is settled
  in C13 (cold start only in v1, with the revisit conditions stated there).
