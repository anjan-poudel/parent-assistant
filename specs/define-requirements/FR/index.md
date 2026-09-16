# Functional Requirements — Live Camera Translation (v1)

23 functional requirements. IDs are namespaced `FR-LCT-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
the dementia supplement uses with its `FR-DNN` IDs.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-LCT-001](FR-LCT-001-live-camera-preview.md) | Live camera preview without photo capture | Camera Capture | MUST |
| [FR-LCT-002](FR-LCT-002-camera-permission-and-disclosure.md) | Camera permission and purpose disclosure | Camera Capture / Compliance | MUST |
| [FR-LCT-003](FR-LCT-003-on-device-ocr-language-detection.md) | On-device OCR with automatic language detection | Text Detection | MUST |
| [FR-LCT-004](FR-LCT-004-region-tracking-between-ocr-passes.md) | Region tracking between OCR passes | Text Detection | SHOULD |
| [FR-LCT-005](FR-LCT-005-region-stabilisation-hysteresis.md) | Stable text regions with hysteresis and change-only events | Region Stabilisation | MUST |
| [FR-LCT-006](FR-LCT-006-decluttering-dense-scenes.md) | Decluttering for dense multi-region scenes | Region Stabilisation | MUST |
| [FR-LCT-007](FR-LCT-007-dictionary-tier-0.md) | Tier 0 curated dictionary translation | Translation | MUST |
| [FR-LCT-008](FR-LCT-008-truthful-tier-attribution.md) | Truthful tier attribution and no success without translation | Translation | MUST |
| [FR-LCT-009](FR-LCT-009-cloud-tier-text-only-translation.md) | Tier 2 text-only cloud translation (batched, deduped) | Translation | MUST |
| [FR-LCT-010](FR-LCT-010-consent-gate.md) | Consent gate before any cloud translation | Privacy & Consent | MUST |
| [FR-LCT-011](FR-LCT-011-cloud-activity-indicator.md) | Visible cloud-activity indicator | Privacy & Consent | MUST |
| [FR-LCT-012](FR-LCT-012-consent-revocation-offline-mode.md) | Consent revocation degrades to dictionary-only offline mode | Privacy & Consent | MUST |
| [FR-LCT-013](FR-LCT-013-cost-governor-fails-closed.md) | Cost governor bound and fail-closed behaviour | Cost Governance | MUST |
| [FR-LCT-014](FR-LCT-014-text-only-egress.md) | Text-only egress guarantee | Privacy & Consent | MUST |
| [FR-LCT-015](FR-LCT-015-smart-mix-in-place-replacement.md) | Smart-mix in-place replacement (bounded) | Overlay | MUST |
| [FR-LCT-016](FR-LCT-016-anchored-callouts.md) | Anchored callouts that never obscure the original | Overlay | MUST |
| [FR-LCT-017](FR-LCT-017-always-show-original-toggle.md) | "Always show original text" toggle | Overlay | MUST |
| [FR-LCT-018](FR-LCT-018-overlay-progress-and-failure-states.md) | Pending and failed translation states in the overlay | Overlay | MUST |
| [FR-LCT-019](FR-LCT-019-persistent-encrypted-cache.md) | Persistent encrypted translation cache | Caching | MUST |
| [FR-LCT-020](FR-LCT-020-shared-cache-and-dictionary.md) | Shared dictionary and translation cache with the appliance helper | Caching | MUST |
| [FR-LCT-021](FR-LCT-021-tap-to-hear-and-read-this-to-me.md) | Tap-to-hear and "read this to me" | Voice Output | MUST |
| [FR-LCT-022](FR-LCT-022-plugin-voice-entry-and-session.md) | LiveTranslatePlugin voice entry and session lifecycle | Plugin & Session | MUST |
| [FR-LCT-023](FR-LCT-023-honest-degradation-and-offline.md) | Honest degradation — never silently report success | Error Handling | MUST |

## Areas
Camera Capture (2), Text Detection (2), Region Stabilisation (2), Translation (3), Privacy &
Consent (4), Cost Governance (1), Overlay (4), Caching (2), Voice Output (1), Plugin & Session (1),
Error Handling (1).

## Related
- [NFR index](../NFR/index.md) — 13 non-functional requirements
- [Requirements index](../index.md)
