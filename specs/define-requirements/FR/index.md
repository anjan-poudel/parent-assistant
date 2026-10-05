# Functional Requirements — Profile Interview + Address-as (v1)

16 functional requirements. IDs are namespaced `FR-PI-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention the live-camera-translation feature uses with `FR-LCT-NNN` and the dementia
supplement with `FR-DNN`.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-PI-001](FR-PI-001-interview-step-order.md) | Interview step order in the first-run wizard | Onboarding Wizard | MUST |
| [FR-PI-002](FR-PI-002-about-you-mandatory-fields.md) | About-you mandatory fields gate Next | Onboarding Wizard / About-you | MUST |
| [FR-PI-003](FR-PI-003-encrypted-profile-store.md) | Encrypted profile store | Profile Storage | MUST |
| [FR-PI-004](FR-PI-004-optional-step-skippable-pattern.md) | Optional steps remain skippable with pending status | Onboarding Wizard | MUST |
| [FR-PI-005](FR-PI-005-family-and-friends-step.md) | Family & friends step extension | Family & Friends | MUST |
| [FR-PI-006](FR-PI-006-emergency-contacts-step.md) | Emergency contacts step | Emergency Contacts | MUST |
| [FR-PI-007](FR-PI-007-voice-fingerprint-step.md) | Voice fingerprint step (reuse of existing enrollment) | Voice Fingerprint | MUST |
| [FR-PI-008](FR-PI-008-wake-acknowledgment-address-as.md) | Personalized wake acknowledgment | Wake Acknowledgment / Address-as | MUST |
| [FR-PI-009](FR-PI-009-brain-reply-style-address-as.md) | Address-as in brain reply-style rules (cloud and on-device) | Brain Personalization | MUST |
| [FR-PI-010](FR-PI-010-address-as-spoken-verbatim.md) | Address-as spoken verbatim (never translated) | Address-as Data Handling | MUST |
| [FR-PI-011](FR-PI-011-unpersonalized-path-unchanged.md) | Un-personalized path behaves exactly as today | No-Regression | MUST |
| [FR-PI-012](FR-PI-012-settings-profile-editor.md) | Settings profile editor | Settings | MUST |
| [FR-PI-013](FR-PI-013-wizard-reopen-for-existing-users.md) | Wizard reopen path for existing users | Onboarding Wizard | MUST |
| [FR-PI-014](FR-PI-014-safety-path-data-availability.md) | Profile data available to existing safety paths | Safety Integration | MUST |
| [FR-PI-015](FR-PI-015-profile-read-failure-fallback.md) | Profile read failures degrade to the un-personalized path | Error Handling | MUST |
| [FR-PI-016](FR-PI-016-app-start-interview-routing.md) | App-start interview-status routing (resume where the user left off) | Onboarding Wizard / App Start | MUST |

## Areas
Onboarding Wizard (3), Onboarding Wizard / About-you (1), Onboarding Wizard / App Start (1),
Profile Storage (1), Family & Friends (1), Emergency Contacts (1), Voice Fingerprint (1), Wake
Acknowledgment / Address-as (1), Brain Personalization (1), Address-as Data Handling (1),
No-Regression (1), Settings (1), Safety Integration (1), Error Handling (1).

## Related
- [NFR index](../NFR/index.md) — 11 non-functional requirements
- [Requirements index](../index.md)
