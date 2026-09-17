# Non-Functional Requirements — Live Camera Translation (v1)

13 non-functional requirements. IDs are namespaced `NFR-LCT-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`).

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-LCT-001](NFR-LCT-001-overlay-responsiveness.md) | Overlay responsiveness and translation latency | Performance | MUST |
| [NFR-LCT-002](NFR-LCT-002-ocr-cadence-and-thermal-budget.md) | OCR cadence, battery and thermal budget | Performance | MUST |
| [NFR-LCT-003](NFR-LCT-003-accessibility-standards.md) | Accessibility — tap targets, overlay text, contrast | Accessibility | MUST |
| [NFR-LCT-004](NFR-LCT-004-localisation.md) | Localisation of new UI strings | Localisation | MUST |
| [NFR-LCT-005](NFR-LCT-005-no-image-or-unrelated-content-egress.md) | Privacy — no image or unrelated-content egress | Privacy | MUST |
| [NFR-LCT-006](NFR-LCT-006-log-safety.md) | Log safety — no recognized or translated text in logs | Privacy / Security | MUST |
| [NFR-LCT-007](NFR-LCT-007-consent-enforcement-and-auditability.md) | Consent enforcement and auditability | Compliance / Security | MUST |
| [NFR-LCT-008](NFR-LCT-008-cache-at-rest.md) | Cache at rest — encrypted, keyed, bounded | Security / Privacy | MUST |
| [NFR-LCT-009](NFR-LCT-009-untrusted-scene-text-hardening.md) | Untrusted scene text hardening (injection) | Security | MUST |
| [NFR-LCT-010](NFR-LCT-010-offline-degradation-integrity.md) | Offline degradation integrity — no false success | Reliability | MUST |
| [NFR-LCT-011](NFR-LCT-011-configurable-parameters.md) | Configurable parameters — no hardcoded operational constants | Reliability / Maintainability | SHOULD |
| [NFR-LCT-012](NFR-LCT-012-shared-component-integrity.md) | Shared-component integrity — no regression to the appliance helper | Reliability | MUST |
| [NFR-LCT-013](NFR-LCT-013-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST |

## Coverage of the security-relevant surfaces
| Surface (workflow focus) | Covered by |
|---|---|
| Untrusted OCR text reaching the cloud prompt (injection) | [NFR-LCT-009](NFR-LCT-009-untrusted-scene-text-hardening.md), [FR-LCT-009](../FR/FR-LCT-009-cloud-tier-text-only-translation.md) |
| Consent-gate enforcement | [NFR-LCT-007](NFR-LCT-007-consent-enforcement-and-auditability.md), [FR-LCT-010](../FR/FR-LCT-010-consent-gate.md) |
| Egress leakage (images never leave; no unrelated content) | [NFR-LCT-005](NFR-LCT-005-no-image-or-unrelated-content-egress.md), [FR-LCT-014](../FR/FR-LCT-014-text-only-egress.md) |
| Persistent cache as user content at rest | [NFR-LCT-008](NFR-LCT-008-cache-at-rest.md), [FR-LCT-019](../FR/FR-LCT-019-persistent-encrypted-cache.md) |
| Cloud indicator present and not spoofable | [FR-LCT-011](../FR/FR-LCT-011-cloud-activity-indicator.md) |
| Offline degradation never silently reports success | [NFR-LCT-010](NFR-LCT-010-offline-degradation-integrity.md), [FR-LCT-023](../FR/FR-LCT-023-honest-degradation-and-offline.md) |
| Cost governor cap fails closed | [FR-LCT-013](../FR/FR-LCT-013-cost-governor-fails-closed.md) |

## Related
- [FR index](../FR/index.md) — 23 functional requirements
- [Requirements index](../index.md)
