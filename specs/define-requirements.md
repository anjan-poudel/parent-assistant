# Requirements — Profile Interview + Address-as

**Project:** Elderly AI Assistant · **Feature:** `profile-interview` (v1) ·
**Branch:** `feat/profile-interview` (worktree `elderly-ai-assistant-profile-interview`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-05 · **Status:** owner-approved — the HIL gate at risk tier T1 was approved
2026-10-05, and the owner amendment of the same date (adds FR-PI-016, app-start interview-status
routing) is incorporated; the locked snapshot in `define-requirements.lock.yaml` is
re-baselined.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-PI-NNN` / `NFR-PI-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention the
dementia supplement uses (`FR-DNN`) and live-camera-translation used (`FR-LCT-NNN`). One file per
requirement; every requirement carries at least one Gherkin scenario, and every security-relevant
requirement carries a failure scenario.

## Summary

- **Functional requirements: 16** (`FR-PI-001` … `FR-PI-016`)
- **Non-functional requirements: 11** (`NFR-PI-001` … `NFR-PI-011`)
- **Areas covered:** Onboarding Wizard (including About-you and the reopen path), Profile Storage,
  Family & Friends, Emergency Contacts, Voice Fingerprint, Wake Acknowledgment, Brain
  Personalization, Address-as Data Handling, Settings, Safety Integration, No-Regression, Error
  Handling. NFR categories: Security, Privacy, Performance, Reliability, Maintainability,
  Localisation, Accessibility, Compliance.
- **v1 scope:** three new first-run interview steps — about-you (name + address-as required, DOB
  optional), emergency contacts (next of kin, GP, hospital — all optional), voice fingerprint
  (optional, reusing the existing enrollment) — plus the extension of the family & friends step, a
  new encrypted profile store, address-as injected into the wake acknowledgment
  (`हजुर <address-as>`) and the brain reply-style rules (`IntentPrompt.build` / `buildChat` /
  `buildUnderstanding` + interpreter context, cloud Gemini and on-device LLaMA), a Settings
  editor, the wizard reopen path for existing users, and the rule that the assistant behaves
  exactly as today until a term is recorded.
- **Primary sources of truth:** owner brief (2026-10-05, recorded in
  `specs/profile-interview/init-report.md`); `specs/profile-interview/constitution.md` (feature
  constitution — Field Contract, Address-as Behaviour Contract, Open Decisions OD-F1/OD-F2/OD-F3,
  out-of-scope list); `specs/profile-interview/workflow.yaml` (the `define-requirements` scope
  comment); project `constitution.md` (Architecture Constraints, Standards, release gates).
- **Read-only stakeholder briefs:** `requirements.md` (baseline; its FR-042 in-app configuration
  clause and NFR-003 wake-latency target are cited) and `requirements-dementia-supplement.md`
  (context only; its personalized-copy examples already presuppose the assistant knows the user's
  form of address).

## Contents

- [`define-requirements/index.md`](define-requirements/index.md) — top-level feature index
- [`define-requirements/FR/index.md`](define-requirements/FR/index.md) — functional requirement
  list (16 files: `define-requirements/FR/FR-PI-NNN-*.md`)
- [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md) — non-functional
  requirement list (11 files: `define-requirements/NFR/NFR-PI-NNN-*.md`)
- [`define-requirements.lock.yaml`](define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (contract `requirements_lock`)
- Sections below: [Functional requirements](#functional-requirements) ·
  [Non-functional requirements](#non-functional-requirements) ·
  [Open decisions](#open-decisions) · [Out of scope](#out-of-scope) ·
  [How this set is verified downstream](#how-this-set-is-verified-downstream)

The `define-requirements/FR/` and `define-requirements/NFR/` folders also still contain the
previously shipped live-camera-translation files (`FR-LCT-NNN-*`, `NFR-LCT-NNN-*`), left in place;
the indexes and this document cover the `profile-interview` set only.

### Requirement index

| ID | Title | Area / Category | Priority | File |
|----|-------|-----------------|----------|------|
| [FR-PI-001](define-requirements/FR/FR-PI-001-interview-step-order.md) | Interview step order in the first-run wizard | Onboarding Wizard | MUST | `FR-PI-001-interview-step-order.md` |
| [FR-PI-002](define-requirements/FR/FR-PI-002-about-you-mandatory-fields.md) | About-you mandatory fields gate Next | Onboarding Wizard / About-you | MUST | `FR-PI-002-about-you-mandatory-fields.md` |
| [FR-PI-003](define-requirements/FR/FR-PI-003-encrypted-profile-store.md) | Encrypted profile store | Profile Storage | MUST | `FR-PI-003-encrypted-profile-store.md` |
| [FR-PI-004](define-requirements/FR/FR-PI-004-optional-step-skippable-pattern.md) | Optional steps remain skippable with pending status | Onboarding Wizard | MUST | `FR-PI-004-optional-step-skippable-pattern.md` |
| [FR-PI-005](define-requirements/FR/FR-PI-005-family-and-friends-step.md) | Family & friends step extension | Family & Friends | MUST | `FR-PI-005-family-and-friends-step.md` |
| [FR-PI-006](define-requirements/FR/FR-PI-006-emergency-contacts-step.md) | Emergency contacts step | Emergency Contacts | MUST | `FR-PI-006-emergency-contacts-step.md` |
| [FR-PI-007](define-requirements/FR/FR-PI-007-voice-fingerprint-step.md) | Voice fingerprint step (reuse of existing enrollment) | Voice Fingerprint | MUST | `FR-PI-007-voice-fingerprint-step.md` |
| [FR-PI-008](define-requirements/FR/FR-PI-008-wake-acknowledgment-address-as.md) | Personalized wake acknowledgment | Wake Acknowledgment / Address-as | MUST | `FR-PI-008-wake-acknowledgment-address-as.md` |
| [FR-PI-009](define-requirements/FR/FR-PI-009-brain-reply-style-address-as.md) | Address-as in brain reply-style rules (cloud and on-device) | Brain Personalization | MUST | `FR-PI-009-brain-reply-style-address-as.md` |
| [FR-PI-010](define-requirements/FR/FR-PI-010-address-as-spoken-verbatim.md) | Address-as spoken verbatim (never translated) | Address-as Data Handling | MUST | `FR-PI-010-address-as-spoken-verbatim.md` |
| [FR-PI-011](define-requirements/FR/FR-PI-011-unpersonalized-path-unchanged.md) | Un-personalized path behaves exactly as today | No-Regression | MUST | `FR-PI-011-unpersonalized-path-unchanged.md` |
| [FR-PI-012](define-requirements/FR/FR-PI-012-settings-profile-editor.md) | Settings profile editor | Settings | MUST | `FR-PI-012-settings-profile-editor.md` |
| [FR-PI-013](define-requirements/FR/FR-PI-013-wizard-reopen-for-existing-users.md) | Wizard reopen path for existing users | Onboarding Wizard | MUST | `FR-PI-013-wizard-reopen-for-existing-users.md` |
| [FR-PI-014](define-requirements/FR/FR-PI-014-safety-path-data-availability.md) | Profile data available to existing safety paths | Safety Integration | MUST | `FR-PI-014-safety-path-data-availability.md` |
| [FR-PI-015](define-requirements/FR/FR-PI-015-profile-read-failure-fallback.md) | Profile read failures degrade to the un-personalized path | Error Handling | MUST | `FR-PI-015-profile-read-failure-fallback.md` |
| [FR-PI-016](define-requirements/FR/FR-PI-016-app-start-interview-routing.md) | App-start interview-status routing (resume where the user left off) | Onboarding Wizard / App Start | MUST | `FR-PI-016-app-start-interview-routing.md` |
| [NFR-PI-001](define-requirements/NFR/NFR-PI-001-profile-encryption-at-rest.md) | Profile encryption at rest | Security | MUST | `NFR-PI-001-profile-encryption-at-rest.md` |
| [NFR-PI-002](define-requirements/NFR/NFR-PI-002-log-safety.md) | Log safety — no new PII in logs | Privacy / Security | MUST | `NFR-PI-002-log-safety.md` |
| [NFR-PI-003](define-requirements/NFR/NFR-PI-003-no-new-egress.md) | No new network egress or cloud processing | Privacy | MUST | `NFR-PI-003-no-new-egress.md` |
| [NFR-PI-004](define-requirements/NFR/NFR-PI-004-profile-string-injection-hardening.md) | Untrusted profile-string hardening (injection) | Security | MUST | `NFR-PI-004-profile-string-injection-hardening.md` |
| [NFR-PI-005](define-requirements/NFR/NFR-PI-005-prompt-budget-and-seed-mirror.md) | Prompt token budget and seed mirror preserved | Reliability / Maintainability | MUST | `NFR-PI-005-prompt-budget-and-seed-mirror.md` |
| [NFR-PI-006](define-requirements/NFR/NFR-PI-006-localisation.md) | Localisation of new UI strings | Localisation | MUST | `NFR-PI-006-localisation.md` |
| [NFR-PI-007](define-requirements/NFR/NFR-PI-007-accessibility.md) | Accessibility of the new interview UI | Accessibility | MUST | `NFR-PI-007-accessibility.md` |
| [NFR-PI-008](define-requirements/NFR/NFR-PI-008-wake-ack-latency-and-fallback.md) | Wake-acknowledgment latency and failure fallback | Performance / Reliability | MUST | `NFR-PI-008-wake-ack-latency-and-fallback.md` |
| [NFR-PI-009](define-requirements/NFR/NFR-PI-009-voice-biometric-unchanged.md) | Voice-biometric mechanism unchanged | Security / Compliance | MUST | `NFR-PI-009-voice-biometric-unchanged.md` |
| [NFR-PI-010](define-requirements/NFR/NFR-PI-010-no-regression-existing-flows.md) | No regression to existing behaviours | Reliability | MUST | `NFR-PI-010-no-regression-existing-flows.md` |
| [NFR-PI-011](define-requirements/NFR/NFR-PI-011-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST | `NFR-PI-011-compliance-and-release-gates.md` |

## Functional requirements

### FR-PI-001: Interview step order in the first-run wizard

#### Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (ordered step list) and "Integration Surfaces" (`OnboardingState.swift`); owner brief 2026-10-05; workflow `define-requirements` scope comment

#### Description
The first-run wizard **must** be extended with three new interview steps inserted in the owner-brief order, so the full sequence is: language, permissions, **about-you**, family & friends (the existing step, extended), **emergency contacts**, **voice fingerprint**, models. About-you is placed after permissions and before family & friends; emergency contacts after family & friends; voice fingerprint before models.

The new steps are `OnboardingState.Step` cases with the same per-step status semantics as the existing steps (per-step status persisted; `pendingSteps` / `firstPendingStep` ordering unchanged in mechanism). The existing steps keep their positions relative to each other and their behaviour. The wizard presents one step at a time with the existing step chrome and navigation affordances.

#### Acceptance criteria

```gherkin
Feature: Interview step order in the first-run wizard

  Scenario: Fresh install presents the steps in the required order
    Given a fresh installation with no onboarding status
    When the wizard is opened
    Then the steps are presented in the order: language, permissions, about-you, family & friends, emergency contacts, voice fingerprint, models
    And the existing steps keep their positions relative to each other

  Scenario: New step status persists like existing steps
    Given the user moves through the new steps
    When the wizard is closed and reopened
    Then each new step's status is persisted and restored through the existing per-step status mechanism
```

#### Related
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: —


### FR-PI-002: About-you mandatory fields gate Next

#### Metadata
- **Area:** Onboarding Wizard / About-you
- **Priority:** MUST
- **Source:** Feature constitution "Field Contract" and "Rules" (mandatory gates Next; Skip affordance is OD-F3); owner brief 2026-10-05; workflow scope comment ("About-you: name + address-as REQUIRED, DOB optional")

#### Description
The About-you step **must** collect three fields: **name** (required), **address-as term** (required), **date of birth** (optional). The step's Next button **must** stay disabled until both name and address-as are filled (non-empty after trimming whitespace). DOB **must not** gate Next.

The address-as term is what the assistant will call the user; it is stored and spoken verbatim (FR-PI-010). Whether the step's header Skip affordance also changes on first run is OD-F3 (open, architect) — whichever way it resolves, the mandatory gate binds the Next path, and already-onboarded users reach the step through the wizard reopen (FR-PI-013) and the Settings editor (FR-PI-012).

#### Acceptance criteria

```gherkin
Feature: About-you mandatory fields

  Scenario: Next stays disabled until both required fields are filled
    Given the About-you step is shown with both required fields empty
    When the user enters a name only
    Then Next remains disabled
    When the user also enters an address-as term
    Then Next is enabled

  Scenario: Date of birth is optional
    Given name and address-as are filled
    When the user leaves date of birth empty
    Then Next is enabled and the step can be completed

  Scenario: Required values are persisted
    Given the user has entered name and address-as and completes the step
    Then both values are persisted to the new profile store (FR-PI-003)
    And the address-as value is stored exactly as entered
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-010 (spoken verbatim), FR-PI-012 (Settings editor), FR-PI-013 (wizard reopen)
- Depends on: FR-PI-001 (step order)


### FR-PI-003: Encrypted profile store

#### Metadata
- **Area:** Profile Storage
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (new profile store under `Services/Storage/` following the `EncryptedFileStorage` pattern), "Field Contract" (storage column), Feature Constraint 5; project constitution Standards (Security: encrypted app storage, Keychain, Data Protection Complete)

#### Description
A new profile store **must** exist under `ios/ElderlyAssistant/Services/Storage/`, following the existing `EncryptedFileStorage` pattern, holding the new profile fields: **name**, **address-as term**, **date of birth**, **emergency doctor / GP**, **local hospital**, and **next of kin** (data shape per OD-F1 — standalone field in this store, or the existing `isEmergencyContact` designation on a family contact).

Rules:

- The store is the single source of truth for these fields; the wake path (FR-PI-008), the prompt builders (FR-PI-009) and the Settings editor (FR-PI-012) read from it.
- Family members remain in the existing `FamilyContactStore` (FR-PI-005) and voice-fingerprint data remains in the existing Secure Enclave mechanism (FR-PI-007) — neither is duplicated into this store.
- Reads and writes are durable and consistent: an interruption must never leave a half-written profile that breaks the assistant.
- A missing, corrupt or undecryptable payload degrades per FR-PI-015 — never fabricated, never partially applied.

#### Acceptance criteria

```gherkin
Feature: Encrypted profile store

  Scenario: All interview fields persist and read back
    Given the user completes About-you and the emergency contacts step
    When the profile store is read after an app relaunch
    Then it returns name, address-as, date of birth (if entered), GP, hospital, and next of kin per the recorded OD-F1 shape

  Scenario: Store content is not readable as plaintext
    Given profile data has been written
    When the app container is inspected
    Then no file contains the name, address-as, date of birth, GP, hospital or next-of-kin values in readable form (NFR-PI-001)

  Scenario: A corrupt payload does not break the assistant
    Given the stored profile payload is unreadable
    When the assistant starts
    Then it runs un-personalized exactly as today (FR-PI-015)
    And it does not crash or stall
```

#### Related
- NFR: NFR-PI-001 (encryption at rest), NFR-PI-002 (log safety)
- Depends on: FR-PI-002 (About-you)


### FR-PI-004: Optional steps remain skippable with pending status

#### Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "Field Contract" rules (every other new field optional; existing skippable-step + Home reminder-card pattern; no hard gate on those steps) and "Integration Surfaces" (`OnboardingState` pendingSteps/firstPendingStep); owner brief 2026-10-05

#### Description
Every new field other than name and address-as is optional. The new steps — family & friends (extended), emergency contacts, voice fingerprint — **must** follow the existing skippable-step pattern:

- no hard gate beyond About-you's Next gate; Skip completes the step;
- per-step status is persisted in `OnboardingState` with stable step IDs;
- a skipped or incomplete step remains pending in `pendingSteps`, which drives the Home reminder card and the wizard reopen position (FR-PI-013);
- the user is never blocked from finishing the wizard, and a partially filled optional step (for example a GP but no hospital) completes without requiring all fields.

#### Acceptance criteria

```gherkin
Feature: Optional steps remain skippable

  Scenario: Skipping an optional step advances the wizard
    Given the emergency contacts step is shown
    When the user skips it
    Then the wizard advances with no hard gate
    And the step's pending status follows the existing skippable-step pattern

  Scenario: Partial fill is accepted
    Given the user fills only the GP in the emergency contacts step
    When the user continues
    Then the GP is persisted and the other optional fields remain empty without blocking

  Scenario: Pending optional steps drive the reminder card
    Given one or more new optional steps remain incomplete
    When the user returns Home
    Then the reminder card reflects the pending new steps through the existing pendingSteps ordering
```

#### Related
- FR: FR-PI-002 (the only hard gate), FR-PI-005, FR-PI-006, FR-PI-007, FR-PI-013
- Depends on: FR-PI-001


### FR-PI-005: Family & friends step extension

#### Metadata
- **Area:** Family & Friends
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (family & friends extends the existing step + `FamilyContactStore`) and "Integration Surfaces" (`FamilyContactStore.swift`; `isEmergencyContact` already exists — OD-F1); "Field Contract" (family members optional, existing store)

#### Description
The existing family & friends step **must** be extended to collect and confirm family members into the existing `FamilyContactStore`, using its existing model. It **must not** fork, duplicate or replace the store. Existing step and store behaviour (add, edit, remove family members and everything else the store serves today) is preserved; the step remains optional and skippable per FR-PI-004.

If OD-F1 resolves to the designation shape, next of kin is expressed through the existing `isEmergencyContact` flag on a family contact. If OD-F1 resolves to a standalone field, the next-of-kin value lives in the new profile store (FR-PI-006) and this step is unaffected.

#### Acceptance criteria

```gherkin
Feature: Family & friends step extension

  Scenario: Family members are recorded through the existing store
    Given the user adds a family member in the family & friends step
    When the step completes
    Then the member is persisted in the existing FamilyContactStore using the existing model
    And the member is visible wherever family contacts are shown today

  Scenario: The step remains optional
    Given the family & friends step is shown
    When the user skips it
    Then the wizard advances and no hard gate is introduced
```

#### Related
- FR: FR-PI-004 (skippable pattern), FR-PI-006 (emergency contacts — OD-F1)
- NFR: NFR-PI-010 (no regression)
- Depends on: FR-PI-001


### FR-PI-006: Emergency contacts step

#### Metadata
- **Area:** Emergency Contacts
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (emergency contacts: next of kin, emergency doctor/GP, local hospital) and "Field Contract" (all optional; next of kin per OD-F1); owner brief 2026-10-05; workflow scope comment

#### Description
A new emergency contacts step **must** collect three optional contact types:

- **Next of kin** — data shape per OD-F1 (standalone field in the new profile store, or an `isEmergencyContact` designation on a family contact).
- **Emergency doctor / GP** — stored in the new profile store.
- **Local hospital contact** — stored in the new profile store.

All three are optional and skippable with no hard gate (FR-PI-004); partial fill is accepted; values persist per FR-PI-003. The step adds no emergency-call logic: the collected data becomes available to the existing safety paths but their behaviour is unchanged (FR-PI-014).

#### Acceptance criteria

```gherkin
Feature: Emergency contacts step

  Scenario: Contact values are collected and persist
    Given the user fills next of kin, GP, and local hospital in the emergency contacts step
    When the step completes
    Then each value is persisted per the recorded OD-F1 shape and the new profile store
    And each value survives an app relaunch

  Scenario: The step is optional and skippable
    Given the emergency contacts step is shown
    When the user skips it entirely
    Then the wizard advances with no hard gate
    And the profile store simply holds no emergency-contact values

  Scenario: Partial fill is accepted
    Given only the GP is entered
    When the step completes
    Then the GP is persisted and the other fields remain empty without blocking
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-004 (skippable), FR-PI-014 (data available to safety paths)
- Open decision: OD-F1 (next-of-kin data shape)
- Depends on: FR-PI-001


### FR-PI-007: Voice fingerprint step (reuse of existing enrollment)

#### Metadata
- **Area:** Voice Fingerprint
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (voice fingerprint — optional enrollment) and "Field Contract" (existing `SpeakerBiometricService` / `VoiceEnrollmentRecorder` flow); "Out of scope" (no changes to the existing voice-biometric mechanisms)

#### Description
A new voice fingerprint step **must** offer the existing on-device voice-biometric enrollment flow (`SpeakerBiometricService` / `VoiceEnrollmentRecorder`, as surfaced today in `VoiceSettingsView`) as an optional, skippable step. The step is an entry point, not a modification:

- the enrollment and verification mechanism **must not** change;
- biometric data **must** remain exclusively in the existing Secure Enclave storage (NFR-PI-009) — never in the new profile store, never transmitted, never logged;
- no new permission is introduced.

If enrollment is skipped, declined or fails, the step **must not** block the wizard; the fingerprint remains available later through the existing Settings surface.

#### Acceptance criteria

```gherkin
Feature: Voice fingerprint step

  Scenario: Enrollment runs through the existing flow
    Given the user chooses to enroll in the voice fingerprint step
    When enrollment runs
    Then it uses the existing VoiceEnrollmentRecorder / SpeakerBiometricService flow
    And the biometric data is stored exactly as the existing flow stores it
    And no new permission or mechanism is introduced

  Scenario: Skip or failure does not block the wizard
    Given the user skips enrollment, or enrollment fails
    When the step ends
    Then the wizard advances with no hard gate
    And the assistant continues to work without a fingerprint
```

#### Related
- NFR: NFR-PI-009 (voice-biometric mechanism unchanged), NFR-PI-010 (no regression)
- Depends on: FR-PI-001


### FR-PI-008: Personalized wake acknowledgment

#### Metadata
- **Area:** Wake Acknowledgment / Address-as
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (wake acknowledgment; `VoicePipeline.handleWakeDetected`) and "Integration Surfaces"; workflow scope comment ("hajur <address-as>")

#### Description
When the wake word is detected and an address-as term is recorded, `VoicePipeline.handleWakeDetected` **must** speak a wake acknowledgment that includes the term, following the form `हजुर <address-as>` (exact phrasing and the mechanism — TTS of a template vs pre-rendered `AckFastLane` variants — are OD-F2, the architect's call). The term is spoken verbatim (FR-PI-010).

Wake-word recognition itself is untouched and out of scope. When no term is recorded, or the profile read fails, the path **must** behave exactly as today — today it starts listening with no spoken greeting; no neutral placeholder is invented (FR-PI-011, FR-PI-015).

#### Acceptance criteria

```gherkin
Feature: Personalized wake acknowledgment

  Scenario: Term recorded — the acknowledgment speaks it
    Given an address-as term is recorded
    When the wake word is detected
    Then the assistant speaks the wake acknowledgment containing the term exactly as recorded (for example "हजुर <address-as>")
    And the existing listening flow continues as today

  Scenario: No term recorded — behaves exactly as today
    Given no address-as term is recorded
    When the wake word is detected
    Then no new spoken greeting is introduced
    And the assistant starts listening exactly as today, with no placeholder term

  Scenario: Speech failure does not block listening
    Given the acknowledgment cannot be spoken (TTS unavailable)
    When the wake word is detected
    Then the assistant proceeds to listen without the greeting
    And no crash or retry loop occurs
```

#### Related
- FR: FR-PI-010 (verbatim), FR-PI-011 (un-personalized path), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-008 (latency and fallback)
- Open decision: OD-F2 (phrasing and locale handling)
- Depends on: FR-PI-003 (term recorded)


### FR-PI-009: Address-as in brain reply-style rules (cloud and on-device)

#### Metadata
- **Area:** Brain Personalization
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (brain replies; `IntentPrompt.build/buildChat/buildUnderstanding` plus interpreter context; cloud Gemini and on-device LLaMA) and "Integration Surfaces"; workflow scope comment ("yes <address-as>")

#### Description
The reply-style rules in `IntentPrompt.build` / `buildChat` / `buildUnderstanding`, plus the interpreter context, **must** receive the recorded address-as term so replies can use it naturally — for example "yes <address-as>" instead of "yes". The contract:

- **Both reply paths.** The personalization applies to the cloud (Gemini) engine and the on-device (LLaMA) brain through the one shared prompt builder — the term is composed in the shared path, not in per-engine forks.
- **Untrusted input.** The user-entered term and name **must** pass the project's `InputSanitiser` discipline before entering any prompt (NFR-PI-004); the term must not be able to alter reply-style rules, tool/intent routing, or safety behaviour.
- **Natural use only.** The rules must instruct natural use where it fits and **must not** contain a rule that forces the term into every sentence. Exact phrasing is the architect's call; the term itself is spoken verbatim (FR-PI-010).
- **Budget and mirror.** Prompt edits preserve the pinned token budget and the byte-identical seed mirror (NFR-PI-005).
- **No term recorded.** The prompt paths behave exactly as today — no term, no placeholder (FR-PI-011, FR-PI-015).

#### Acceptance criteria

```gherkin
Feature: Address-as in brain reply-style rules

  Scenario: Both engines compose the term from the shared builder
    Given an address-as term is recorded
    When replies are generated through the cloud (Gemini) path and through the on-device (LLaMA) path
    Then both compose the term into the shared reply-style context from the one shared prompt builder

  Scenario: Replies may use the term naturally
    Given a term is recorded
    When a reply where a form of address fits is generated
    Then the reply may include the term naturally (for example "yes <address-as>")
    And the term is spoken verbatim

  Scenario: Natural use only — no mechanical insertion rule
    Given the prompt templates
    When the reply-style rules are inspected
    Then they instruct natural use and contain no rule that forces the term into every sentence
    And a reply that omits the term remains valid

  Scenario: No term recorded — prompt changes are inert
    Given no term is recorded
    When prompts are built
    Then they behave as today with no term and no placeholder
```

#### Related
- FR: FR-PI-010 (verbatim), FR-PI-011 (un-personalized path), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-003 (no new egress), NFR-PI-004 (injection hardening), NFR-PI-005 (budget and mirror)
- Depends on: FR-PI-003 (term recorded)


### FR-PI-010: Address-as spoken verbatim (never translated)

#### Metadata
- **Area:** Address-as Data Handling
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (stored and spoken verbatim; never translated; never routed through the L10n string catalogs) and Feature Constraint 3; "Field Contract" (Address-as term)

#### Description
The address-as term is user data. It **must** be stored and spoken exactly as entered, in every surface where it is used (the wake acknowledgment, FR-PI-008, and brain replies, FR-PI-009). It **must not** be translated, transliterated, substituted for, or routed through the L10n string catalogs. The surrounding acknowledgment/reply copy may be localized in the active app language — the term itself is emitted verbatim. The name follows the same rule wherever it is spoken.

Script/language mixing between the term and the active app language is handled by the localized surrounding copy; the acknowledgment phrasing and per-language templates are OD-F2 (architect).

#### Acceptance criteria

```gherkin
Feature: Address-as spoken verbatim

  Scenario: Verbatim in both surfaces
    Given the term is recorded as entered
    When the wake acknowledgment is spoken and when a reply uses the term
    Then each utterance/text contains exactly the recorded string, with no translation or transliteration

  Scenario: The term is data, not a catalog string
    Given the L10n string catalogs and the personalization code paths
    When they are inspected
    Then the term does not appear as a catalog entry
    And no code path passes the term through a localization lookup
```

#### Related
- NFR: NFR-PI-006 (localisation of UI strings)
- Open decision: OD-F2 (acknowledgment phrasing and locale handling)
- Depends on: FR-PI-003 (profile store)


### FR-PI-011: Un-personalized path behaves exactly as today

#### Metadata
- **Area:** No-Regression
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (final bullet: until a term is recorded — step skipped, existing user not yet re-interviewed, including any fallback path — the assistant behaves exactly as today; no neutral placeholder is invented); workflow non-goals comment

#### Description
Until an address-as term is recorded — because the step was skipped, because an existing user has not yet been re-interviewed, or because of any profile read failure — the assistant **must** behave exactly as today:

- wake detection starts listening with no spoken greeting, exactly as the pre-feature baseline (FR-PI-008);
- prompts and replies contain no term and no substitute: no "default name", no placeholder, no neutral invented form of address (FR-PI-009);
- no other behaviour changes.

The feature adds personalization; it **must not** regress the un-personalized path, and there is no state in which an invented term is spoken or composed into a prompt.

#### Acceptance criteria

```gherkin
Feature: Un-personalized path behaves exactly as today

  Scenario: Fresh install without a recorded term
    Given a fresh installation with no address-as term recorded
    When the wake word is detected and replies are generated
    Then behaviour is identical to the pre-feature baseline
    And no placeholder term is spoken or composed into any prompt

  Scenario: Existing user not yet re-interviewed
    Given an installation that completed onboarding before this feature
    And the user has not completed the new steps
    When the assistant runs
    Then the same today-behaviour holds, with no term and no placeholder
```

#### Related
- FR: FR-PI-008 (wake ack), FR-PI-009 (reply style), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: —


### FR-PI-012: Settings profile editor

#### Metadata
- **Area:** Settings
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (a Settings editor) and "Rules" (existing users reach the new steps via the wizard reopen and the Settings editor) and "Integration Surfaces"; "Field Contract" (existing users are not force-migrated)

#### Description
A Settings editor **must** let the user, or a helping family member, view and edit the profile after onboarding: name, address-as term, date of birth, emergency contacts (GP, hospital, next of kin per OD-F1). Family members are edited through the existing family contacts surface. Edits persist to the same stores (FR-PI-003) and take effect on subsequent use without a reinstall or a wizard re-run — the next wake acknowledgment and subsequent replies use the updated term.

The editor is reachable for already-onboarded users. Whether the editor sits behind voice-biometric or PIN authentication is an open decision raised in elicitation (OD-PI-2: `requirements.md` FR-042 requires in-app configuration behind authentication, while the biometric/PIN gate is recorded as unwired with accepted residual risk in project constitution Open Decision 11, B3). This requirement binds the editor's existence, reachability, persistence and effect — not the authentication gate.

#### Acceptance criteria

```gherkin
Feature: Settings profile editor

  Scenario: Edit takes effect without re-onboarding
    Given an onboarded user opens the Settings profile editor and changes the address-as term
    When the change is saved
    Then the next wake acknowledgment and subsequent replies use the new term
    And no reinstall or wizard re-run is required

  Scenario: Reachable for existing users
    Given an installation that completed onboarding before this feature
    When the user opens Settings
    Then the profile editor is reachable and the profile fields are editable

  Scenario: Edits persist
    Given a profile field is edited in Settings
    When the app relaunches and the store is read
    Then the edited value is returned
    And no field is silently lost
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-013 (wizard reopen)
- NFR: NFR-PI-007 (accessibility), NFR-PI-002 (log safety)
- Open decision: OD-PI-2 (editor authentication gate)
- Depends on: FR-PI-003


### FR-PI-013: Wizard reopen path for existing users

#### Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (the wizard's reminder-card reopen path; new step IDs are pending by definition for existing users — absent from the persisted status map) and "Rules" (existing users are not force-migrated); "Integration Surfaces" (`pendingSteps` drives the reminder card and the reopen position)

#### Description
For users who completed onboarding before this feature, the new step IDs are absent from the persisted status map and are therefore pending by definition. The existing reminder-card reopen path **must** surface them:

- `pendingSteps` (with the existing `firstPendingStep` ordering) includes the new steps, so the Home reminder card reflects them;
- reopening the wizard lands at the first pending new step in the configured order (FR-PI-001);
- existing users are **not** force-migrated: the wizard is not auto-presented over the assistant and nothing blocks normal use until the steps are completed; the Settings editor (FR-PI-012) is the alternative path.

#### Acceptance criteria

```gherkin
Feature: Wizard reopen path for existing users

  Scenario: New steps are pending for existing users
    Given an installation whose persisted onboarding status predates the new steps
    When pendingSteps is computed
    Then the new steps (about-you, emergency contacts, voice fingerprint) are treated as pending
    And the Home reminder card reflects them through the existing mechanism

  Scenario: Reopen lands on the first pending new step
    Given the user taps the reminder card
    When the wizard reopens
    Then it opens at the first pending new step in the configured order

  Scenario: No force-migration
    Given an existing user with pending new steps
    When the app starts normally
    Then the wizard is not auto-presented
    And the assistant works as today until the user chooses to complete the steps
```

#### Related
- FR: FR-PI-004 (pending status), FR-PI-012 (Settings editor), FR-PI-011 (today-behaviour)
- Depends on: FR-PI-001


### FR-PI-014: Profile data available to existing safety paths

#### Metadata
- **Area:** Safety Integration
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (collected profile/emergency data becomes available to the existing safety paths — emergency contact selection, family notification — but those paths' behaviour is unchanged) and Feature Constraint 7 (safety delta: none)

#### Description
The collected profile and emergency data **must** be made available (readable) to the existing safety paths — emergency contact selection and family notification — through the profile store (FR-PI-003), so those paths can consult it where they already operate.

The paths' logic and behaviour **must not** change: no new emergency-call logic, no new notification triggers, no new thresholds, no new stub. The known descoped state of those paths is unchanged by this feature (project constitution Open Decision 11: no emergency-call module; health/family alert stubs return success silently), and this feature neither fixes nor extends them.

#### Acceptance criteria

```gherkin
Feature: Profile data availability to safety paths

  Scenario: Recorded data is readable by the safety paths
    Given next of kin, GP, or hospital values are recorded
    When the existing emergency contact selection path consults the profile
    Then the recorded values are available through the profile store

  Scenario: Safety behaviour is unchanged
    Given the feature's changes are in the build
    When the existing safety paths (emergency contact selection, family notification) run
    Then their triggers, outputs and failure behaviour are identical to the pre-feature baseline
    And no new emergency-call logic, notification trigger or stub is introduced
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-006 (emergency contacts)
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: FR-PI-003


### FR-PI-015: Profile read failures degrade to the un-personalized path

#### Metadata
- **Area:** Error Handling
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (including any fallback path, the assistant behaves exactly as today) and Feature Constraint 5 (encrypted local storage); project constitution Agent Principles (no silent stubs; deferred/absent capability is never faked)

#### Description
Any failure to read the profile — missing store (fresh install, not yet written), corrupt or unreadable payload, decryption failure — **must** degrade to the un-personalized path:

- the assistant behaves exactly as today (FR-PI-011): it never crashes, stalls or blocks at startup;
- no term is fabricated; no placeholder is invented; no partially read value is used;
- a corrupt payload is discarded or rebuilt rather than retried in a loop;
- the failure is recorded in logs without PII (NFR-PI-002).

Writes **must** never leave a half-written profile that a subsequent read could misinterpret.

#### Acceptance criteria

```gherkin
Feature: Profile read failures degrade cleanly

  Scenario: Missing store on a fresh install
    Given no profile has been written
    When the assistant starts and the wake word is detected
    Then behaviour is today's baseline, with no term and no greeting
    And no error is surfaced to the user

  Scenario: A corrupt payload does not break startup
    Given the stored profile payload is unreadable
    When the assistant starts
    Then it runs un-personalized, discards or rebuilds the corrupt payload, and does not crash or stall

  Scenario: No partial application and no placeholder
    Given a read failure occurs partway through the profile
    When the profile is consumed
    Then no partially read term or field is used
    And no placeholder value is invented
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-011 (today-behaviour)
- NFR: NFR-PI-002 (log safety)
- Depends on: FR-PI-003


### FR-PI-016: App-start interview-status routing (resume where the user left off)

#### Metadata
- **Area:** Onboarding Wizard / App Start
- **Priority:** MUST
- **Source:** Owner amendment 2026-10-05 (owner sign-off); specs/profile-interview/constitution.md Feature Constraint 8

#### Description
On app start the app **must** check the onboarding interview's completion status (the per-step status in `OnboardingState`, including the mandatory fields of FR-PI-002) and route accordingly:

- **Mandatory fields missing** (name or address-as — FR-PI-002): the user **must** be routed to the interview screen (the wizard) at the first pending step — About-you — resuming where the user left off. This is a hard route on app start.
- **Optional interview steps pending** (FR-PI-004): the user **must** also be routed to the wizard, at the first pending optional step, with the OD-F3 soft-skip affordance preserved — the user can still skip and is never trapped.
- **Interview complete:** the app starts normally, with no routing to the interview screen.

The resume mechanism **must** be the existing `OnboardingState.pendingSteps` / `firstPendingStep` computation plus the wizard's `startingAt:` reopen path (FR-PI-013) — no new resume state is introduced. The first pending step follows the configured order (FR-PI-001).

Cold start is the minimum trigger for this requirement. Whether a background-to-foreground transition also re-checks is a design decision for the architect (design-l1 / design-l2), not a requirement of this set.

Relationship to FR-PI-013: this owner amendment (2026-10-05) supersedes FR-PI-013's "No force-migration" scenario for the app-start path — pending steps are now surfaced on start — while preserving its non-blocking intent through the skippable steps (FR-PI-004 / OD-F3). FR-PI-013's `pendingSteps` / `firstPendingStep` / `startingAt:` mechanics are unchanged and are the resume mechanism used here.

A failure to read the interview completion status **must not** crash or stall app start and **must not** trap the user (FR-PI-015; FR-PI-004).

#### Acceptance criteria

```gherkin
Feature: App-start interview-status routing

  Scenario: Mandatory fields missing on cold start — hard route to About-you
    Given the app cold-starts with name or address-as not recorded
    And the first pending step is About-you
    When the app starts
    Then the user is routed to the interview screen (the wizard)
    And the wizard opens at About-you, so the interview resumes where the user left off

  Scenario: Optional steps pending on cold start — routed but never trapped
    Given the app cold-starts with name and address-as recorded
    And at least one optional interview step is pending
    When the app starts
    Then the user is routed to the interview screen (the wizard)
    And the wizard opens at the first pending optional step
    And the OD-F3 soft-skip affordance is available, so the user can skip and is never trapped

  Scenario: Interview complete — no routing on cold start
    Given the app cold-starts with the interview complete
    When the app starts
    Then the app starts normally with no routing to the interview screen

  Scenario: A status read failure does not crash or trap
    Given the interview completion status cannot be read (corrupt or unreadable state)
    When the app starts
    Then the app starts without crashing, stalling or looping on the status check
    And the user is never trapped in the wizard
```

#### Related
- FR: FR-PI-002 (mandatory gate), FR-PI-004 (optional skippable pattern), FR-PI-013 (reopen path; its "No force-migration" scenario is superseded for the app-start path by this amendment), FR-PI-015 (no crash or trap on read failure)
- NFR: NFR-PI-010 (no regression)
- Depends on: FR-PI-001 (step order), FR-PI-013 (resume mechanism)


## Non-functional requirements

### NFR-PI-001: Profile encryption at rest

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 (DOB and emergency contacts are personal data stored in the existing encrypted local storage — Keychain, Data Protection Complete); "Field Contract" storage column; project constitution Standards (Security: emergency contact data in encrypted app storage; Data Protection class Complete)

#### Description
Every new profile field — name, address-as term, date of birth, GP, hospital, next of kin — is personal data and **must** be stored encrypted at rest using the existing encrypted-storage pattern (`EncryptedFileStorage`; Keychain key material; iOS Data Protection class Complete).

Measurable properties:

- **Zero plaintext copies** of any profile value anywhere on disk, including temporary files used during writes and any debug artifacts.
- The store is readable only with the app's key material; no plaintext backup of the values exists.
- A corrupt or undecryptable payload is treated as a read failure (FR-PI-015) — it is discarded, never exposed and never partially applied.
- Removing the app removes the profile data; no new cloud or file-based backup path is introduced for it (NFR-PI-003).

#### Acceptance criteria

```gherkin
Feature: Profile encryption at rest

  Scenario: No readable PII on disk
    Given all profile fields have been saved
    When the app container is inspected
    Then no file contains the name, address-as, date of birth, GP, hospital or next-of-kin values in readable form
    And the payload requires the app's Keychain key material to read

  Scenario: An undecryptable payload is discarded, not exposed
    Given the stored payload cannot be decrypted
    When the store loads
    Then the data is not exposed and no partial value is used
    And the assistant degrades per FR-PI-015
```

#### Related
- FR: FR-PI-003 (profile store), FR-PI-015 (read-failure fallback)


### NFR-PI-002: Log safety — no new PII in logs

#### Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 (logs must not contain the new PII — project Privacy standard, log sanitiser); project constitution Standards (Privacy: logs must not contain PII — log sanitiser required) and release gates (release-build log-surface gate)

#### Description
The new PII — name, address-as term, date of birth, GP, hospital, next of kin — **must not** appear in any log, in any build, on any path this feature adds or touches (store, wizard, wake acknowledgment, prompt composition, settings, error paths).

Measurable properties:

- **Zero occurrences** of any profile value in console output, log files or telemetry metadata in a Release build exercising a fully personalized session.
- Observability may record non-content facts only: "profile present: yes/no", step completion booleans, error classifications — never the values.
- The log sanitiser covers the new fields; diagnostic call sites that would carry them are redacted or omit them.
- The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) covers the new profile, wake-acknowledgment and settings paths and **exits 0** — a build-blocking gate, not a report.

#### Acceptance criteria

```gherkin
Feature: Log safety for profile data

  Scenario: A personalized session produces no PII in logs
    Given a Release build with a recorded profile triggers the wake acknowledgment and replies
    When the console and log output are inspected
    Then no name, address-as term, date of birth or emergency-contact value appears
    And no raw profile payload or error body appears

  Scenario: A diagnostic reference to the term is sanitised
    Given a diagnostic event would reference the address-as term
    When it is logged
    Then the value is redacted or omitted by the log sanitiser

  Scenario: The release log-safety gate covers the new paths
    Given the feature's logging paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new profile, wake-acknowledgment and settings paths
```

#### Related
- FR: FR-PI-003, FR-PI-008, FR-PI-012, FR-PI-015
- NFR: NFR-PI-011 (compliance and release gates)


### NFR-PI-003: No new network egress or cloud processing

#### Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (any new cloud processing — no new network egress) and Feature Constraint 5; project constitution Architecture Constraint 1 (all AI inference on-device; recorded exceptions Open Decisions 12 and 13 are untouched)

#### Description
The feature **must** add zero new network calls, endpoints, request shapes or data flows.

Measurable properties:

- **Zero network requests attributable to the feature** across the full journey: interview, wizard close, wake acknowledgment, reply generation, Settings edit — the whole feature works fully offline (on-device engines).
- All new stored fields stay on-device. Only the **name** and **address-as term** may be composed into the existing reply prompt paths, alongside the content those paths already carry.
- **Zero occurrences** of date of birth, GP, hospital, next-of-kin, family-member or biometric values in any prompt or outbound payload.
- On a reply path that uses the existing consent-gated cloud engine, the term is carried only inside that engine's existing flow, under its existing consent status and recorded exception — no new egress category and no new disclosure obligation are created.

#### Acceptance criteria

```gherkin
Feature: No new network egress or cloud processing

  Scenario: The full journey works with no network
    Given the device is offline
    When the interview is completed, the wizard closes, the wake word fires, and on-device replies run
    Then every step of the journey works
    And zero network requests are attempted by the feature

  Scenario: Only name and term may enter prompts
    Given a profile with all fields filled
    When prompt payloads for both reply engines are inspected
    Then the name and/or address-as appear only where the reply-style rules use them
    And date of birth, GP, hospital, next-of-kin, family and biometric values appear in no prompt or outbound payload

  Scenario: No new endpoint or request shape is introduced
    Given the feature's outbound code paths
    When request construction is inspected
    Then no new endpoint or request shape exists beyond the existing engine paths
```

#### Related
- FR: FR-PI-003, FR-PI-009
- NFR: NFR-PI-004 (injection hardening), NFR-PI-011 (compliance gates)


### NFR-PI-004: Untrusted profile-string hardening (injection)

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 4 (security-design-review focus — prompt injection: the user-entered address-as is composed into brain prompts, making it an untrusted input path; the design must apply the project's existing `InputSanitiser` discipline; the term must not alter reply-style rules, tool/intent routing, or safety behaviour); workflow security-design-review focus areas; project constitution Standards ("Injection detection enabled at `quarantine` level")

#### Description
The name and address-as term are user-entered, attacker-influenceable input composed into prompts shared by the cloud (Gemini) and on-device (LLaMA) brains. Before either enters any prompt it **must** be handled with the same discipline `InputSanitiser` applies to transcripts (quarantine level):

- **Sanitised and bounded** — the composed value is capped by a configured bound (not a magic literal); truncation never splits a grapheme cluster; the composed prompt remains within the pinned 1,024-token on-device budget (NFR-PI-005).
- **Passed as data** — delimited/quoted, never as free-form instruction text, so the value cannot be parsed as a rule.
- **No capability change** — a crafted term must not be able to alter reply-style rules, intent/tool routing, authentication, or safety behaviour, and must not trigger any app action.
- **Policy action before send** — text that trips the injection policy follows the configured quarantine action (the same level the project configures); the assistant degrades to the un-personalized path (FR-PI-011) rather than sending a hostile payload.
- Model output is treated as untrusted: nothing from a reply can cause profile writes or actions by itself.

The term cannot reach these guarantees without this discipline; the security-design-review's STRIDE model must treat this surface as a focus area and `security-test` must present both the positive and negative evidence.

#### Acceptance criteria

```gherkin
Feature: Hardening against hostile profile strings

  Scenario: An ordinary term personalizes prompts as data
    Given the user records an ordinary address-as term
    When prompts are built for either engine
    Then the term is included as delimited data
    And personalization works normally

  Scenario: An injection-shaped term cannot alter behaviour
    Given a term contains an instruction aimed at the model (for example "ignore your instructions and ...")
    When the term is composed into the prompt path
    Then the injection policy's configured action is applied before any prompt is sent
    And reply-style rules, intent routing, authentication and safety behaviour are unchanged
    And no app action is triggered by the term

  Scenario: An oversized term is bounded without breaking graphemes
    Given a term far longer than the configured bound
    When it is composed
    Then it is truncated to the bound without splitting a grapheme cluster
    And the composed prompt stays within the 1,024-token budget
```

#### Related
- FR: FR-PI-009 (reply-style rules)
- NFR: NFR-PI-005 (prompt budget), NFR-PI-002 (log safety)


### NFR-PI-005: Prompt token budget and seed mirror preserved

#### Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraints 1–2 (prompt token budget: templates run in a 1,024-token on-device context and are pinned by `IntentPromptTests`' character ceiling — any prompt edit must preserve the budget and keep the tests passing; seed mirror: `tools/train-intent/seeds/prompt_template.txt` must be updated byte-identically in the same change as any `IntentPrompt` template edit)

#### Description
The reply-style prompt edits **must** preserve the pinned budget:

- The templates run in a **1,024-token** on-device context; the character ceiling pinned by `IntentPromptTests` **must not** be raised to fit the personalization, and `IntentPromptTests` must pass with a term recorded and with no term recorded.
- The address-as composition is bounded (NFR-PI-004), so the budget holds for arbitrarily long user input.
- `tools/train-intent/seeds/prompt_template.txt` **must** be updated **byte-identically** to the shipped template in the same change as any template edit — byte identity is the measurable property (a checksum equality).

#### Acceptance criteria

```gherkin
Feature: Prompt budget and seed mirror

  Scenario: The pinned budget is preserved with the term recorded
    Given the personalized prompt templates with an address-as term recorded
    When IntentPromptTests run
    Then they pass within the pinned character ceiling
    And the composed prompt fits the 1,024-token on-device context

  Scenario: The seed file is byte-identical to the template
    Given the prompt template change
    When tools/train-intent/seeds/prompt_template.txt is compared with the shipped template
    Then the two are byte-identical (checksums equal)
```

#### Related
- FR: FR-PI-009 (reply-style rules)
- NFR: NFR-PI-004 (injection hardening), NFR-PI-010 (no regression)


### NFR-PI-006: Localisation of new UI strings

#### Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (all new UI strings externalized to the L10n string catalogs) and Feature Constraint 3; project constitution Standards (Localisation: all UI strings externalised; primary user's language for TTS)

#### Description
All new user-visible strings introduced by this feature — step titles and descriptions, field labels and hints, emergency-contact labels, voice-fingerprint step copy, Settings editor labels, and error/degradation copy — **must** be externalised to the L10n string catalogs with Nepali alongside the existing languages. Measurable: **100%** of the feature's user-visible strings have catalog entries; **zero** hardcoded user-visible strings in Swift literals.

The address-as term and the user's name are data: they **must never** be catalog entries and are never localized (FR-PI-010); they render and speak verbatim. Existing wizard copy remains in the catalogs.

#### Acceptance criteria

```gherkin
Feature: Localisation of the feature's strings

  Scenario: All new UI strings are externalised
    Given the feature's new UI strings (steps, field labels, fingerprint copy, settings labels, error copy)
    When the string catalogs are inspected
    Then each string has a catalog entry with a Nepali translation
    And no feature string is hardcoded in the view code

  Scenario: The address-as term is never localized
    Given the catalogs and the rendering paths
    When the term is displayed or spoken
    Then it is emitted verbatim
    And it is absent from the catalogs
```

#### Related
- FR: FR-PI-010 (verbatim term), FR-PI-012 (Settings editor)
- NFR: NFR-PI-007 (accessibility)


### NFR-PI-007: Accessibility of the new interview UI

#### Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards (Accessibility: 44×44 pt minimum tap targets; minimum 18 pt body text; high-contrast text; voice-first UI) and Compliance constraints (clear plain-language explanation visible to elderly users)

#### Description
The new wizard steps and the Settings profile editor **must** meet the project accessibility standards:

- Interactive targets (buttons, input fields, list rows, Skip/Next controls) are at least **44 × 44 pt**.
- Body text is at least **18 pt**; the layout must not override system scaling in a way that reduces text below this minimum at supported sizes.
- Colours meet WCAG AA contrast — at least **4.5:1** for body text, **3:1** for large text and UI components.
- Devanagari (Nepali) renders correctly through the app's existing text rendering, and copy is plain-language (no technical terms) for the elderly primary user as well as a helping family member.

#### Acceptance criteria

```gherkin
Feature: Accessibility of the new interview UI

  Scenario: Tap targets and text sizes meet the minimums
    Given a rendered new wizard step or Settings editor screen
    When targets and text sizes are measured
    Then every interactive target is at least 44 by 44 points
    And body text is at least 18 pt

  Scenario: Contrast meets AA
    Given the rendered labels and controls
    When contrast ratios are measured
    Then body text meets at least 4.5:1
    And large text and UI components meet at least 3:1
```

#### Related
- FR: FR-PI-002 (About-you), FR-PI-012 (Settings editor)
- NFR: NFR-PI-006 (localisation)


### NFR-PI-008: Wake-acknowledgment latency and failure fallback

#### Metadata
- **Category:** Performance / Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (wake acknowledgment; behaves exactly as today including any fallback path); project stakeholder brief NFR-003 (wake-word activation within 1 second); owner brief 2026-10-05

#### Description
The personalized acknowledgment **must not** regress wake responsiveness:

- The acknowledgment speech **begins within 1 second** of wake-word detection (the existing activation budget of `requirements.md` NFR-003).
- The existing listening flow continues as today; the acknowledgment must not introduce an unbounded wait or block intent capture beyond the current pipeline's behaviour — the exact sequencing and mechanism are OD-F2 (architect).
- If the acknowledgment cannot be spoken (TTS engine unavailable or failed), the path **must** fall back to today's silent start: no crash, no blocking, no retry loop, and listening still begins.

#### Acceptance criteria

```gherkin
Feature: Wake-acknowledgment responsiveness

  Scenario: The acknowledgment begins within the activation budget
    Given an address-as term is recorded
    When the wake word is detected
    Then the acknowledgment begins within 1 second
    And the existing listening flow continues as today

  Scenario: TTS failure falls back to today's silent start
    Given the acknowledgment cannot be spoken (TTS unavailable)
    When the wake word is detected
    Then the assistant starts listening as today, with no greeting
    And no crash, blocking wait or retry loop occurs
```

#### Related
- FR: FR-PI-008 (wake ack), FR-PI-011 (today-behaviour)
- NFR: NFR-PI-010 (no regression)
- Open decision: OD-F2 (phrasing and mechanism)


### NFR-PI-009: Voice-biometric mechanism unchanged

#### Metadata
- **Category:** Security / Compliance
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (no changes to the existing voice-biometric enrollment/verification mechanisms; the fingerprint step reuses them as-is) and Feature Constraint 6 (Secure Enclave; no change to that mechanism); project constitution Standards (voice biometric enrolment and verification stored on-device only — Secure Enclave / Keystore)

#### Description
The voice fingerprint step (FR-PI-007) is a new entry point into the existing flow; it **must not** modify it.

Measurable properties:

- **Zero changes** to `SpeakerBiometricService` / `VoiceEnrollmentRecorder` behaviour, contracts or algorithm (the diff adds a call site, not modifications).
- Biometric data remains **exclusively** in the existing Secure Enclave / secure storage: zero biometric values in the new profile store, in logs, or in any outbound payload.
- **Zero new permissions** or purpose strings for the fingerprint step (`Info.plist` unchanged for it).
- The existing voice-biometric threat model applies unchanged; `security-design-review` covers it by reference (workflow focus: "voice fingerprint enrollment spoofing/replay — reuse existing threat model").

#### Acceptance criteria

```gherkin
Feature: Voice-biometric mechanism unchanged

  Scenario: Enrollment uses the existing mechanism and storage
    Given the fingerprint step runs an enrollment
    When the enrollment completes
    Then the biometric data is stored exactly as the existing flow stores it (Secure Enclave)
    And no behaviour, contract or algorithm change to the enrollment/verification code is introduced

  Scenario: No new permission and no biometric leakage
    Given the shipped Info.plist and the feature's storage paths
    When they are inspected
    Then no new permission or purpose string is added for the fingerprint step
    And no biometric value appears in the profile store, logs or outbound payloads
```

#### Related
- FR: FR-PI-007 (voice fingerprint step), FR-PI-014 (safety paths)
- NFR: NFR-PI-011 (compliance and release gates)


### NFR-PI-010: No regression to existing behaviours

#### Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" (wake-word recognition itself; emergency-call logic; voice-biometric mechanisms) and "Address-as Behaviour Contract" (behaves exactly as today until a term is recorded); Feature Constraints 6–7; workflow non-goals comment

#### Description
The feature **must not** change existing behaviour outside its scope. Specifically:

- **Wake-word recognition** — the wake word and its detection logic are untouched; only post-detection acknowledgment behaviour is added.
- **Existing wizard steps** — their behaviour and their positions relative to each other are preserved; new steps are insertions.
- **Family contacts store** — `FamilyContactStore` behaviour is preserved; the feature extends its use, not its contract.
- **Safety paths** — emergency contact selection and family notification logic is unchanged (FR-PI-014); no new emergency-call logic, trigger or stub.
- **Voice-biometric mechanisms** — unchanged (NFR-PI-009).
- **Un-personalized baseline** — identical to today (FR-PI-011).

Measurable: the affected existing test suites stay green under the project's build/test gate, and shared components touched by the feature (`OnboardingState`, `VoicePipeline`, `IntentPrompt`) keep their existing contracts — additions are extensions, not modifications.

#### Acceptance criteria

```gherkin
Feature: No regression to existing behaviours

  Scenario: Existing tests stay green
    Given the feature's changes are in the build
    When the affected existing test suites run under the project's build/test gate
    Then they pass unchanged

  Scenario: Wake-word recognition is untouched
    Given the feature's diff
    When the wake-word detection path is inspected
    Then the wake word and its detection logic are unchanged
    And only the post-detection acknowledgment behaviour is added

  Scenario: Shared components keep their contracts
    Given OnboardingState, VoicePipeline and IntentPrompt as used by existing features
    When the feature's changes are inspected
    Then their existing behaviour is unchanged
    And the feature's additions are extensions (new cases, new parameters, new call sites), not modifications
```

#### Related
- FR: FR-PI-011 (un-personalized path), FR-PI-014 (safety paths)
- NFR: NFR-PI-005 (seed mirror), NFR-PI-009 (voice biometrics)


### NFR-PI-011: Compliance and release gates

#### Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Compliance constraints (App Store guidelines 5.1.1/5.1.3; permissions at point of use) and release gates; workload gates (security-design-review STRIDE, security-test, final-sign-off T2 + HIL); Feature Constraints 4–5

#### Description
The feature may ship only with the following gates satisfied and evidenced:

1. **No new permissions / no HealthKit** — zero new permission requests or purpose strings; permissions remain requested at point of use with plain-language explanation (FR-PI-007/NFR-PI-009).
2. **Privacy disclosure updated** — the app's data-collection disclosure covers the new profile fields (name, address-as, date of birth, emergency contacts) per App Store Guideline 5.1.1; the update is drafted and reviewed before the first App Store submission, alongside the existing Open Decision 11/12/13 review window (2026-10-13).
3. **STRIDE threat model** — `security-design-review` returns `SECURITY-GO` with a STRIDE model covering the workflow's focus areas: profile-string prompt injection (NFR-PI-004), profile PII at rest (NFR-PI-001), and the voice-fingerprint reuse (NFR-PI-009).
4. **Security evidence** — `security-test` returns `SECURITY-GO` evidencing injection hardening (NFR-PI-004), PII-free logs (NFR-PI-002), encrypted storage (NFR-PI-001), and no new egress (NFR-PI-003).
5. **Release gates** — `ios/tools/check-release-log-safety.sh` exits 0 (NFR-PI-002); the `ios/build.sh` test scope passes; the T2 final-sign-off gate (HIL) is recorded.

#### Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: Gates are evidenced before sign-off
    Given the feature is ready for sign-off
    When the release checklist is assembled
    Then the log-safety gate has exited 0
    And the security reviews have returned SECURITY-GO for the focus areas above
    And the privacy disclosure update is recorded (or explicitly open for the 2026-10-13 review window)

  Scenario: No new permission is introduced
    Given the shipped app
    When Info.plist and the permission flows are inspected
    Then no new permission or purpose string was added by this feature
```

#### Related
- NFR: NFR-PI-001, NFR-PI-002, NFR-PI-003, NFR-PI-004, NFR-PI-009


## Open decisions

Carried forward from the feature constitution (verbatim) plus two raised during elicitation. None
blocks design work; each has an owner-visible resolution point.

### Carried from the feature constitution

**OD-F1 — Next-of-kin data shape (OPEN — architect).** *Verbatim:*

> Standalone next-of-kin field in the new profile store, or a designation on an existing
> `FamilyContact` via the existing `isEmergencyContact` flag? Both data paths already exist.
> Architect decides in design-l1/design-l2; the choice must be reflected in the field table above
> and the emergency-contacts step design.

Status in this requirement set: both paths remain open by design; the requirements are written to
hold either way — FR-PI-005 (family & friends), FR-PI-006 (emergency contacts), FR-PI-003 (profile
store). Resolve at: design-l1 / design-l2.

**OD-F2 — Wake-acknowledgment phrasing and locale handling (OPEN — architect).** *Verbatim:*

> Exact phrasing and mechanism of the spoken wake acknowledgment (TTS of a `हजुर <address-as>`
> template vs. pre-rendered `AckFastLane` variants), and locale handling: how the surrounding
> acknowledgment copy is localized when the user's term (user data, spoken verbatim) is in a
> different script/language from the active app language, and how the per-language acknowledgment
> templates are managed. The term itself must always be spoken verbatim; exact phrasing is the
> architect's call.

Status in this requirement set: the requirements bind the term spoken verbatim (FR-PI-010), the
acknowledgment including the term (FR-PI-008), and the ≤ 1 s activation budget with a TTS-failure
fallback (NFR-PI-008); phrasing and mechanism are the architect's call. Resolve at: design-l1 /
design-l2.

**OD-F3 — About-you skip affordance vs. the wizard's "no hard gate" contract (OPEN — architect).**
*Verbatim:*

> The existing wizard is documented as "every step is skippable — there is no hard gate anywhere"
> (`OnboardingState`), while the brief makes name + address-as mandatory with Next disabled until
> both are filled. Does the About-you step keep the header Skip on first run (soft gate — deferral
> via the Home reminder card) or is Skip disabled (hard gate)? Either way the reminder-card reopen +
> Settings editor path applies to already-onboarded users. Architect decides so implementation and
> tests agree.

Status in this requirement set: the mandatory Next gate binds either way (FR-PI-002); the
skippable pattern for all other steps is FR-PI-004; the reopen and Settings paths are FR-PI-013
and FR-PI-012. Resolve at: design-l1 / design-l2.

### Raised during elicitation (this requirements pass)

**OD-PI-4 — Address-as input affordance (OPEN — architect).** Free-text entry vs a preset list of
common terms (for example आमा / बुबा / दाइ), and what counts as "filled" beyond non-blank after
trimming. The requirements bind "required, gates Next" (FR-PI-002); the input widget, help copy
and any additional validation are design decisions. Resolve at: design-l1 / design-l2.

**OD-PI-5 — Settings editor authentication (OPEN — owner/architect).** `requirements.md` FR-042
requires in-app configuration to sit behind voice-biometric or PIN authentication, while the
biometric/PIN gate is recorded as unwired with accepted residual risk (project constitution Open
Decision 11, finding B3; review 2026-10-13). Does editing the profile in Settings require
authentication in this release? FR-PI-012 binds the editor's existence, reachability, persistence
and effect — not the authentication gate. Resolve at: owner review at this HIL gate / design-l1.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)", plus elicitation
clarifications) — recorded so nothing is silently half-built:

| Non-goal | Why it is stated |
|---|---|
| Wake-word recognition changes | The wake word and its detection are untouched; only the post-detection acknowledgment is added (FR-PI-008, NFR-PI-010). |
| Any new cloud processing / new network egress | The feature adds zero new calls; only name/address-as may enter the existing prompt paths (NFR-PI-003). |
| Emergency-call logic changes | Collected data becomes available to the existing safety paths; their logic, triggers and stubs are unchanged (FR-PI-014). |
| Forcing address-as into every sentence | Natural use only — "hajur <address-as>", "yes <address-as>" (FR-PI-009). |
| New permissions, HealthKit use, voice-biometric mechanism changes | The fingerprint step reuses the existing enrollment as-is (FR-PI-007, NFR-PI-009). |
| Scheduled auto-activation / daily-briefing and reminder copy | Surfaces that already reference the user by name in the dementia supplement's examples are unchanged; the injection surfaces are the wake acknowledgment and reply-style rules only. |
| Remote companion-app push of profile fields | The interview is completed at the device; a helping family member may fill it in on the user's behalf (feature purpose). |
| Profile export/deletion flows | GDPR deferred (project constitution Open Decision 2); the store must not block future erasure/export, but no flow ships here. |

## How this set is verified downstream

| Gate | What it checks against this set |
|---|---|
| `design-l1` / `design-l2` | Resolve OD-F1, OD-F2, OD-F3, OD-PI-4, OD-PI-5; design the store, wizard, prompt-injection point and wake-ack path. |
| `review-l2` | `review.decision == GO` against the component design and this set. |
| `security-design-review` | STRIDE focus: profile-string prompt injection (NFR-PI-004, FR-PI-009), PII at rest (NFR-PI-001, FR-PI-003), voice-fingerprint reuse (NFR-PI-009, FR-PI-007), wake-ack path (FR-PI-008, NFR-PI-008); `SECURITY-GO` required. |
| `security-test` | Evidence: injection hardening (NFR-PI-004), PII-free logs (NFR-PI-002), encrypted storage (NFR-PI-001), no new egress (NFR-PI-003), voice-biometric data at rest (NFR-PI-009); `SECURITY-GO` required. |
| `final-sign-off` | T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0 (NFR-PI-002, NFR-PI-011); privacy disclosure update recorded. |
