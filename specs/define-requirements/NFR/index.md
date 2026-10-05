# Non-Functional Requirements — Profile Interview + Address-as (v1)

11 non-functional requirements. IDs are namespaced `NFR-PI-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`).

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-PI-001](NFR-PI-001-profile-encryption-at-rest.md) | Profile encryption at rest | Security | MUST |
| [NFR-PI-002](NFR-PI-002-log-safety.md) | Log safety — no new PII in logs | Privacy / Security | MUST |
| [NFR-PI-003](NFR-PI-003-no-new-egress.md) | No new network egress or cloud processing | Privacy | MUST |
| [NFR-PI-004](NFR-PI-004-profile-string-injection-hardening.md) | Untrusted profile-string hardening (injection) | Security | MUST |
| [NFR-PI-005](NFR-PI-005-prompt-budget-and-seed-mirror.md) | Prompt token budget and seed mirror preserved | Reliability / Maintainability | MUST |
| [NFR-PI-006](NFR-PI-006-localisation.md) | Localisation of new UI strings | Localisation | MUST |
| [NFR-PI-007](NFR-PI-007-accessibility.md) | Accessibility of the new interview UI | Accessibility | MUST |
| [NFR-PI-008](NFR-PI-008-wake-ack-latency-and-fallback.md) | Wake-acknowledgment latency and failure fallback | Performance / Reliability | MUST |
| [NFR-PI-009](NFR-PI-009-voice-biometric-unchanged.md) | Voice-biometric mechanism unchanged | Security / Compliance | MUST |
| [NFR-PI-010](NFR-PI-010-no-regression-existing-flows.md) | No regression to existing behaviours | Reliability | MUST |
| [NFR-PI-011](NFR-PI-011-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST |

## Coverage of the security-relevant surfaces
| Surface (workflow focus) | Covered by |
|---|---|
| Profile-string prompt injection into IntentPrompt templates (cloud + on-device) | [NFR-PI-004](NFR-PI-004-profile-string-injection-hardening.md), [FR-PI-009](../FR/FR-PI-009-brain-reply-style-address-as.md) |
| Profile PII at rest (name, address-as, DOB, GP, hospital, next of kin) | [NFR-PI-001](NFR-PI-001-profile-encryption-at-rest.md), [FR-PI-003](../FR/FR-PI-003-encrypted-profile-store.md) |
| Log surface PII (no name/term/DOB/contact values) | [NFR-PI-002](NFR-PI-002-log-safety.md) |
| Egress discipline (no new network egress; only name/term in prompts) | [NFR-PI-003](NFR-PI-003-no-new-egress.md) |
| Voice fingerprint enrollment spoofing/replay (reuse existing threat model) | [NFR-PI-009](NFR-PI-009-voice-biometric-unchanged.md), [FR-PI-007](../FR/FR-PI-007-voice-fingerprint-step.md) |
| Wake-acknowledgment path (no new egress; no sensitive data beyond the term) | [FR-PI-008](../FR/FR-PI-008-wake-acknowledgment-address-as.md), [NFR-PI-008](NFR-PI-008-wake-ack-latency-and-fallback.md) |
| Un-personalized fallback integrity (no placeholder; no regression) | [FR-PI-011](../FR/FR-PI-011-unpersonalized-path-unchanged.md), [FR-PI-015](../FR/FR-PI-015-profile-read-failure-fallback.md) |

## Related
- [FR index](../FR/index.md) — 15 functional requirements
- [Requirements index](../index.md)
