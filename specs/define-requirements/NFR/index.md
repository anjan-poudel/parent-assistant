# Non-Functional Requirements — Reminders Instructions Enhancements

10 non-functional requirements. IDs are namespaced `NFR-RIE-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
the earlier features used (`NFR-MSR-NNN`, `NFR-CNR-NNN`, `NFR-CDP-NNN`, `NFR-FCU-NNN`,
`NFR-LCT-NNN`, `NFR-MTC-NNN`, `NFR-PI-NNN`, `NFR-SP-NNN`). This page covers the
`reminders-instructions-enhancements` set (`NFR-RIE-*`) only; the earlier feature files remain in
this folder and are not part of this feature's requirements or lock. All 10 are MUST.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-RIE-001](NFR-RIE-001-accessibility-elderly-fit.md) | Accessibility — 44pt targets, 18pt body, VoiceOver, dynamic type, no fine-motor or swipe-only controls | Accessibility | MUST |
| [NFR-RIE-002](NFR-RIE-002-localisation-en-ne.md) | Localisation — every new string in English and Nepali; no hardcoded user-visible text | Localisation | MUST |
| [NFR-RIE-003](NFR-RIE-003-no-new-egress.md) | No new network egress — instruction media never leaves the device | Privacy | MUST |
| [NFR-RIE-004](NFR-RIE-004-pii-free-logging-and-release-gate.md) | PII-free observability — event type + outcome only; release log gate green | Privacy / Security | MUST |
| [NFR-RIE-005](NFR-RIE-005-at-rest-file-protection.md) | At-rest protection — complete file protection on every instruction video; no Photos/share exposure | Security | MUST |
| [NFR-RIE-006](NFR-RIE-006-migration-compatibility.md) | Migration compatibility — pre-feature payloads load; unknown kinds degrade honestly | Reliability / Compatibility | MUST |
| [NFR-RIE-007](NFR-RIE-007-storage-footprint-and-orphans.md) | Storage footprint — one video per owner, ≤200 MiB, zero orphans after replace/delete | Storage / Reliability | MUST |
| [NFR-RIE-008](NFR-RIE-008-playback-responsiveness.md) | Playback responsiveness — player within 500 ms, first frame within 2 s, fallback within 1 s | Performance | MUST |
| [NFR-RIE-009](NFR-RIE-009-playback-seam-and-test-gates.md) | Testability and gate — injectable playback seam, scripted failure paths, one device smoke | Quality / Reliability | MUST |
| [NFR-RIE-010](NFR-RIE-010-preserved-baseline-and-release-gates.md) | Preserved baseline and release gates — medication paths, notification outcomes and no-instruction UI unchanged | Compliance / Reliability | MUST |

## Coverage of the constitution's binding properties

| Binding property / constraint | Covered by |
|---|---|
| Reminder always fires; media failure degrades to the reminder | [FR-RIE-015](../FR/FR-RIE-015-reminder-always-fires.md), [FR-RIE-020](../FR/FR-RIE-020-playback-failure-plain-fallback.md) |
| Presentation handlers always return false; banner/list/sound unchanged | [FR-RIE-016](../FR/FR-RIE-016-presentation-handlers-always-false.md), [NFR-RIE-010](NFR-RIE-010-preserved-baseline-and-release-gates.md) |
| Notification taxonomy full-REPLACE discipline; scoped cancels only | [FR-RIE-021](../FR/FR-RIE-021-notification-taxonomy-preserved.md), [NFR-RIE-010](NFR-RIE-010-preserved-baseline-and-release-gates.md) |
| No video in the notification attachment store | [FR-RIE-022](../FR/FR-RIE-022-video-not-in-notification-attachments.md) |
| Transactional replace and delete-with-owner lifecycle | [FR-RIE-013](../FR/FR-RIE-013-transactional-replace.md), [FR-RIE-014](../FR/FR-RIE-014-delete-with-owner.md), [NFR-RIE-007](NFR-RIE-007-storage-footprint-and-orphans.md) |
| Filename hygiene / traversal guard | [FR-RIE-012](../FR/FR-RIE-012-filename-hygiene-traversal-guard.md) |
| Migration-safe tolerant decoding, never lose existing data | [NFR-RIE-006](NFR-RIE-006-migration-compatibility.md) |
| Complete file protection; app data, never Photos/shared | [FR-RIE-011](../FR/FR-RIE-011-video-storage-layout-and-protection.md), [NFR-RIE-005](NFR-RIE-005-at-rest-file-protection.md) |
| Camera/mic disclosure in Info.plist; denial non-blocking | [FR-RIE-025](../FR/FR-RIE-025-camera-microphone-permissions.md) |
| PII-free logging and release log gate | [NFR-RIE-004](NFR-RIE-004-pii-free-logging-and-release-gate.md), [FR-RIE-020](../FR/FR-RIE-020-playback-failure-plain-fallback.md) |
| On-device only; no new egress | [NFR-RIE-003](NFR-RIE-003-no-new-egress.md) |
| en + ne localisation; spoken times via `SpokenTime` | [NFR-RIE-002](NFR-RIE-002-localisation-en-ne.md) |
| 44pt+ / 18pt+ / VoiceOver / dynamic type / no fine-motor | [NFR-RIE-001](NFR-RIE-001-accessibility-elderly-fit.md) |
| No silent stubs or false capability claims | [FR-RIE-024](../FR/FR-RIE-024-honest-capability-surface.md), [FR-RIE-010](../FR/FR-RIE-010-plain-feedback-and-safe-failure.md) |
| Plain-language, dismissal-always failure handling | [FR-RIE-020](../FR/FR-RIE-020-playback-failure-plain-fallback.md), [NFR-RIE-002](NFR-RIE-002-localisation-en-ne.md) |
| Test rigor: scoped suites, playback seam, device smoke, full-suite baseline | [NFR-RIE-009](NFR-RIE-009-playback-seam-and-test-gates.md), [NFR-RIE-010](NFR-RIE-010-preserved-baseline-and-release-gates.md) |
| Safety delta none; no medication path change; no new ack/escalation | [FR-RIE-023](../FR/FR-RIE-023-no-new-ack-escalation-machinery.md), [NFR-RIE-010](NFR-RIE-010-preserved-baseline-and-release-gates.md) |
