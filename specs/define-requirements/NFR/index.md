# Non-Functional Requirements — Medication Schedules and Reminders

10 non-functional requirements. IDs are namespaced `NFR-MSR-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
the earlier features used (`NFR-LCT-NNN`, `NFR-PI-NNN`, `NFR-SP-NNN`, `NFR-MTC-NNN`,
`NFR-FCU-NNN`, `NFR-CDP-NNN`, `NFR-CNR-NNN`). This page covers the
`medication-schedules-reminders` set (`NFR-MSR-*`) only; the earlier feature files remain in this
folder and are not part of this feature's requirements or lock. All 10 are MUST.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-MSR-001](NFR-MSR-001-llm-independence.md) | LLM independence — the medication scheduler unit stays free of LLM dependencies | Reliability | MUST |
| [NFR-MSR-002](NFR-MSR-002-pii-free-observability.md) | PII-free observability — hash-only medication identifiers, sanitised logs, gate-covered paths | Privacy / Security | MUST |
| [NFR-MSR-003](NFR-MSR-003-on-device-no-new-egress.md) | On-device label and photo processing — no new cloud egress for medication content | Privacy | MUST |
| [NFR-MSR-004](NFR-MSR-004-localisation-and-spoken-time.md) | Localisation and spoken times — every new string in Nepali and English, all spoken times through the formatter | Localisation | MUST |
| [NFR-MSR-005](NFR-MSR-005-accessibility-elderly-fit.md) | Accessibility — 44pt targets, 18pt body text, contrast, voice-first acknowledgement | Accessibility | MUST |
| [NFR-MSR-006](NFR-MSR-006-migration-compatibility.md) | Migration compatibility — legacy payloads keep loading, schedules are never lost to a missing key | Reliability / Compatibility | MUST |
| [NFR-MSR-007](NFR-MSR-007-devanagari-grapheme-regression-pin.md) | Devanagari grapheme-cluster behaviour regression-pinned — do not "fix" it | Localisation / Regression | MUST |
| [NFR-MSR-008](NFR-MSR-008-safety-test-coverage-and-confidence.md) | Safety-path test rigor — 100 per cent unit coverage, required integration tests, elevated confidence | Quality / Compliance | MUST |
| [NFR-MSR-009](NFR-MSR-009-compliance-and-release-gates.md) | Compliance and release gates — log-safety gate green, health-policy posture unchanged, honest baseline | Compliance | MUST |
| [NFR-MSR-010](NFR-MSR-010-reminder-firing-latency.md) | Reminder firing latency — the mapped clock time is the schedule of record | Reliability / Performance | MUST |

## Coverage of the constitution's safety delta and key constraints

| Safety delta / constraint | Covered by |
|---|---|
| (a) Scan-to-fill writes into a safety-critical schedule — OCR values require human confirmation before binding | [FR-MSR-006](../FR/FR-MSR-006-ocr-human-confirmation-before-binding.md), [FR-MSR-005](../FR/FR-MSR-005-scan-to-fill-additive.md) |
| (b) Slot-to-clock mapping — deterministic and total; the escalation engine receives an exact scheduled time | [FR-MSR-002](../FR/FR-MSR-002-deterministic-slot-to-clock-mapping.md), [FR-MSR-019](../FR/FR-MSR-019-existing-reminder-escalation-preserved.md), [NFR-MSR-010](NFR-MSR-010-reminder-firing-latency.md) |
| (c) Photo-as-intake-evidence augments and never replaces the acknowledgement + confirmation chain | [FR-MSR-013](../FR/FR-MSR-013-photo-evidence-augments-never-replaces.md), [FR-MSR-014](../FR/FR-MSR-014-photo-evidence-shared-slot-resolution.md), [FR-MSR-009](../FR/FR-MSR-009-acknowledgement-safety-sequence.md) |
| (d) Caregiver "always notified" extends the PII-free taxonomy with no new PII on the wire | [FR-MSR-017](../FR/FR-MSR-017-pii-free-wire.md), [FR-MSR-015](../FR/FR-MSR-015-significant-event-notification-set.md), [FR-MSR-016](../FR/FR-MSR-016-caregiver-channels-honest-delivery.md) |
| LLM independence of the medication scheduler unit | [NFR-MSR-001](NFR-MSR-001-llm-independence.md) |
| Persistence before alarm; process-kill re-arm within the unexpired window (FR-029) | [FR-MSR-022](../FR/FR-MSR-022-persistence-before-alarm-and-rearm.md), [NFR-MSR-008](NFR-MSR-008-safety-test-coverage-and-confidence.md) |
| Honest degradation — no silent stubs, no undelivered notification as success, the unwired photo machinery surfaced as itself | [FR-MSR-018](../FR/FR-MSR-018-honest-degradation-deferred-capabilities.md), [FR-MSR-016](../FR/FR-MSR-016-caregiver-channels-honest-delivery.md) |
| Migration without loss — optional fields, decoder defaults, legacy schedule times readable and representable | [NFR-MSR-006](NFR-MSR-006-migration-compatibility.md) |
| On-device label/photo processing; no new cloud egress | [NFR-MSR-003](NFR-MSR-003-on-device-no-new-egress.md) |
| PII-free observability (hashed entry identifier only) | [NFR-MSR-002](NFR-MSR-002-pii-free-observability.md) |
| Localisation ne/en; spoken times only via the formatter; Devanagari behaviour pinned | [NFR-MSR-004](NFR-MSR-004-localisation-and-spoken-time.md), [NFR-MSR-007](NFR-MSR-007-devanagari-grapheme-regression-pin.md) |
| Elderly-fit measures (44pt / 18pt / contrast / voice-first) | [NFR-MSR-005](NFR-MSR-005-accessibility-elderly-fit.md), [FR-MSR-021](../FR/FR-MSR-021-elderly-fit-ux-new-flows.md) |
| Test rigor and the elevated threshold on the dementia machinery | [NFR-MSR-008](NFR-MSR-008-safety-test-coverage-and-confidence.md), [FR-MSR-020](../FR/FR-MSR-020-dementia-machinery-preserved.md) |
