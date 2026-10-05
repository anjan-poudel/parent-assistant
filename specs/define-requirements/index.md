# Requirements — Profile Interview + Address-as

Feature: `profile-interview` (worktree branch `feat/profile-interview`, worktree
`elderly-ai-assistant-profile-interview`).
Status: **owner-approved** — the HIL gate at risk tier T1 was approved 2026-10-05, with the
owner amendment of the same date (adds FR-PI-016, app-start interview-status routing); the
locked snapshot is re-baselined.
Task: `define-requirements`, agent `ba`, contract `requirements_doc` + `requirements_lock`.
Date: 2026-10-05.

## Summary
- Functional requirements: **16** (`FR-PI-001` … `FR-PI-016`)
- Non-functional requirements: **11** (`NFR-PI-001` … `NFR-PI-011`)
- Areas covered: Onboarding Wizard (including About-you, app-start routing and the reopen
  path), Profile Storage, Family & Friends, Emergency Contacts, Voice Fingerprint, Wake
  Acknowledgment, Brain Personalization, Address-as Data Handling, Settings, Safety Integration,
  No-Regression, Error Handling. NFR categories: Security, Privacy, Performance, Reliability,
  Maintainability, Localisation, Accessibility, Compliance.
- v1 scope: three new first-run interview steps (about-you: name + address-as required, DOB
  optional; emergency contacts: next of kin, GP, hospital — all optional; voice fingerprint:
  optional, reusing the existing enrollment), an extension of the family & friends step, a new
  encrypted profile store, address-as injected into the wake acknowledgment
  (`हजुर <address-as>`) and the brain reply-style rules (`IntentPrompt.build/buildChat/
  buildUnderstanding` + interpreter context, cloud Gemini and on-device LLaMA), a Settings
  editor, the wizard reopen path for existing users, and the rule that the assistant behaves
  exactly as today until a term is recorded.
- Primary sources of truth: owner brief (2026-10-05, recorded in
  `specs/profile-interview/init-report.md`), `specs/profile-interview/constitution.md` (feature
  constitution — Field Contract, Address-as Behaviour Contract, Open Decisions OD-F1/OD-F2/
  OD-F3, out-of-scope list), `specs/profile-interview/workflow.yaml` (the `define-requirements`
  scope comment), and the project `constitution.md` (Architecture Constraints, Standards,
  release gates).
- Read-only stakeholder briefs: `requirements.md` (baseline; FR-042 in-app configuration and
  NFR-003 wake latency are cited) and `requirements-dementia-supplement.md` (context only; its
  personalized-copy examples already presuppose the assistant knows the user's form of address).

## Contents
- [FR/index.md](FR/index.md) — functional requirements (16 files, `FR-PI-001` … `FR-PI-016`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (11 files, `NFR-PI-001` … `NFR-PI-011`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also still contain the previously shipped
live-camera-translation requirement files (`FR-LCT-NNN-*`, `NFR-LCT-NNN-*`), left in place; the
indexes on this page cover the `profile-interview` set only.

### Functional requirements
Wizard & interview: [FR-PI-001](FR/FR-PI-001-interview-step-order.md),
[FR-PI-002](FR/FR-PI-002-about-you-mandatory-fields.md),
[FR-PI-004](FR/FR-PI-004-optional-step-skippable-pattern.md),
[FR-PI-013](FR/FR-PI-013-wizard-reopen-for-existing-users.md),
[FR-PI-016](FR/FR-PI-016-app-start-interview-routing.md) ·
Data capture: [FR-PI-003](FR/FR-PI-003-encrypted-profile-store.md),
[FR-PI-005](FR/FR-PI-005-family-and-friends-step.md),
[FR-PI-006](FR/FR-PI-006-emergency-contacts-step.md),
[FR-PI-007](FR/FR-PI-007-voice-fingerprint-step.md) ·
Address-as behaviour: [FR-PI-008](FR/FR-PI-008-wake-acknowledgment-address-as.md),
[FR-PI-009](FR/FR-PI-009-brain-reply-style-address-as.md),
[FR-PI-010](FR/FR-PI-010-address-as-spoken-verbatim.md) ·
Post-onboarding & edges: [FR-PI-011](FR/FR-PI-011-unpersonalized-path-unchanged.md),
[FR-PI-012](FR/FR-PI-012-settings-profile-editor.md),
[FR-PI-014](FR/FR-PI-014-safety-path-data-availability.md),
[FR-PI-015](FR/FR-PI-015-profile-read-failure-fallback.md)

### Non-functional requirements
[NFR-PI-001](NFR/NFR-PI-001-profile-encryption-at-rest.md) encryption at rest ·
[NFR-PI-002](NFR/NFR-PI-002-log-safety.md) log safety ·
[NFR-PI-003](NFR/NFR-PI-003-no-new-egress.md) no new egress ·
[NFR-PI-004](NFR/NFR-PI-004-profile-string-injection-hardening.md) injection hardening ·
[NFR-PI-005](NFR/NFR-PI-005-prompt-budget-and-seed-mirror.md) prompt budget/seed mirror ·
[NFR-PI-006](NFR/NFR-PI-006-localisation.md) localisation ·
[NFR-PI-007](NFR/NFR-PI-007-accessibility.md) accessibility ·
[NFR-PI-008](NFR/NFR-PI-008-wake-ack-latency-and-fallback.md) wake-ack latency/fallback ·
[NFR-PI-009](NFR/NFR-PI-009-voice-biometric-unchanged.md) voice biometrics unchanged ·
[NFR-PI-010](NFR/NFR-PI-010-no-regression-existing-flows.md) no regression ·
[NFR-PI-011](NFR/NFR-PI-011-compliance-and-release-gates.md) compliance gates

## Open decisions
Carried forward from the feature constitution (verbatim) plus two raised during elicitation.
None blocks design work; each has an owner-visible resolution point. Full text in the
consolidated doc's Open decisions section.

| # | Decision | Status in this requirement set | Resolve at |
|---|---|---|---|
| OD-F1 | **Next-of-kin data shape** — standalone field in the new profile store vs the existing `isEmergencyContact` designation on a `FamilyContact` | Both paths remain open; the requirements are written to hold either way (FR-PI-005, FR-PI-006, FR-PI-003) | design-l1 / design-l2 |
| OD-F2 | **Wake-acknowledgment phrasing and locale handling** — TTS of a `हजुर <address-as>` template vs pre-rendered `AckFastLane` variants; localized surrounding copy vs a verbatim term in another script/language | Requirement binds the term spoken verbatim and the ≤ 1 s activation budget; phrasing/mechanism is the architect's call (FR-PI-008, FR-PI-010, NFR-PI-008) | design-l1 / design-l2 |
| OD-F3 | **About-you skip affordance vs the wizard's "no hard gate" contract** — Skip on first run (soft gate, deferral via reminder card) vs Skip disabled (hard gate) | The mandatory Next gate binds either way; the reopen + Settings paths apply regardless (FR-PI-002, FR-PI-004, FR-PI-013) | design-l1 / design-l2 |
| OD-PI-4 | **Address-as input affordance** (raised in elicitation) — free-text entry vs preset terms; what counts as "filled" beyond non-blank after trimming | Requirement binds "required, gates Next"; the input widget and any validation beyond non-blank are design decisions (FR-PI-002) | design-l1 / design-l2 |
| OD-PI-5 | **Settings editor authentication** (raised in elicitation) — `requirements.md` FR-042 requires in-app configuration behind biometric/PIN, while the biometric/PIN gate is recorded as unwired with accepted residual risk (project constitution Open Decision 11, B3) | Requirement binds the editor's existence, reachability, persistence and effect — not the auth gate (FR-PI-012) | owner review at this HIL gate / design-l1 |

## Out of scope
Explicitly not in scope (from the feature constitution's "Out of scope (must not change)" list,
plus clarifications recorded during elicitation):

- **Wake-word recognition itself** — the wake word and its detection are untouched.
- **Any new cloud processing** — no new network egress; only the existing consent-gated engine
  flows are involved (NFR-PI-003).
- **Emergency-call logic** — collected profile/emergency data becomes available to the existing
  safety paths, but their behaviour is unchanged; no new emergency-call module, trigger or stub.
- **Forcing address-as into every sentence** — the term is used only where it fits naturally.
- **New permissions, HealthKit use, or changes to the existing voice-biometric
  enrollment/verification mechanisms** — the fingerprint step reuses them as-is.
- **Scheduled auto-activation / daily-briefing and reminder copy** — surfaces that already
  reference the user by name or term in the dementia supplement's examples are not changed by
  this feature; the injection surfaces are the wake acknowledgment and the brain reply-style
  rules only.
- **Remote companion-app push of profile fields** (name, address-as, DOB, emergency contacts) —
  the interview is completed at the device; a helping family member may fill it in on the
  user's behalf, as today.
- **Profile data export/deletion flows** — GDPR is deferred (project constitution Open
  Decision 2); the store must not make future erasure/export impossible, but no flow ships here.

## Related
- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
- Feature constitution: [`../profile-interview/constitution.md`](../profile-interview/constitution.md)
- Owner brief + scaffold probe: [`../profile-interview/init-report.md`](../profile-interview/init-report.md)
