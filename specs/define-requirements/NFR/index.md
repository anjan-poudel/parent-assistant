# Non-Functional Requirements — Family Contacts Unify (v1)

9 non-functional requirements. IDs are namespaced `NFR-FCU-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`NFR-LCT-NNN`), profile-interview used (`NFR-PI-NNN`),
spotify-music-integration used (`NFR-SP-NNN`) and multi-turn-conversation used (`NFR-MTC-NNN`).
This page covers the `family-contacts-unify` set (`NFR-FCU-*`) only; the earlier feature files
remain in this folder and are not part of this feature's requirements or lock.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-FCU-001](NFR-FCU-001-nickname-index-and-match-performance.md) | Nickname index and matching performance stay within the interaction envelope | Performance | MUST |
| [NFR-FCU-002](NFR-FCU-002-pii-log-safety.md) | PII / log safety — names, nicknames, numbers, links and photos never reach logs | Privacy / Security | MUST |
| [NFR-FCU-003](NFR-FCU-003-no-new-network-egress.md) | No new network egress — contacts, links, nicknames and photos stay on-device | Privacy | MUST |
| [NFR-FCU-004](NFR-FCU-004-localisation-ne-en.md) | Localisation — every new user-visible string exists in ne and en | Localisation | MUST |
| [NFR-FCU-005](NFR-FCU-005-accessibility-voice-first.md) | Accessibility — voice-first capability, house touch standards, no authorization reasoning for the elderly user | Accessibility | MUST |
| [NFR-FCU-006](NFR-FCU-006-migration-compatibility.md) | Migration compatibility — legacy payloads load, nothing is lost | Reliability | MUST |
| [NFR-FCU-007](NFR-FCU-007-grapheme-regression-pin.md) | Devanagari substring / grapheme-cluster behavior regression-pinned | Reliability | MUST |
| [NFR-FCU-008](NFR-FCU-008-delivery-sequencing-call-dialer.md) | Delivery sequencing and scope separation vs call-dialer-primary-secondary | Compliance | MUST |
| [NFR-FCU-009](NFR-FCU-009-test-and-release-gates.md) | Test gate, release gates and baseline honesty | Compliance | MUST |

## Coverage of the security-relevant surfaces (workflow focus areas)

| Surface (workflow `security-design-review` / `security-test` focus) | Covered by |
|---|---|
| Write authority — the app's first write into the shared system address book; blast radius confined to the edited contact's photo; no bulk mutation; wrong-contact write prevented by construction | [FR-FCU-008](../FR/FR-FCU-008-photo-write-confined-to-edited-contact.md), [FR-FCU-009](../FR/FR-FCU-009-write-authorization-honest-states.md), [NFR-FCU-009](NFR-FCU-009-test-and-release-gates.md) |
| Identity integrity — a wrong link merges two people; a nickname matching several contacts must never silently dial the wrong person; unlink semantics; stale-link degradation | [FR-FCU-005](../FR/FR-FCU-005-unlink-both-records-intact.md), [FR-FCU-006](../FR/FR-FCU-006-stale-link-degradation.md), [FR-FCU-014](../FR/FR-FCU-014-ambiguous-nickname-never-wrong-person.md), [FR-FCU-003](../FR/FR-FCU-003-link-aware-dedupe-unified-search.md) |
| Degradation safety — permission denied/limited/read-only or a failed save falls back to the app-local photo with honest UI; no data loss, no false success, no crash | [FR-FCU-009](../FR/FR-FCU-009-write-authorization-honest-states.md), [FR-FCU-010](../FR/FR-FCU-010-non-writable-photo-fallback.md), [FR-FCU-007](../FR/FR-FCU-007-photo-display-precedence.md) |
| PII discipline — names/numbers/photos off the logs beyond B2/T-050; `check-release-log-safety.sh` covers the new write/fallback/resolution paths | [NFR-FCU-002](NFR-FCU-002-pii-log-safety.md), [FR-FCU-006](../FR/FR-FCU-006-stale-link-degradation.md) |
| No new egress — nothing leaves the device; no new network surface or data collection | [NFR-FCU-003](NFR-FCU-003-no-new-network-egress.md) |
| Matching-semantics integrity — reuse not fork; grapheme behavior regression-pinned (no "fixes") | [NFR-FCU-007](NFR-FCU-007-grapheme-regression-pin.md), [FR-FCU-012](../FR/FR-FCU-012-nickname-matching-in-search.md), [FR-FCU-013](../FR/FR-FCU-013-nickname-matching-in-voice-resolution.md) |
| Migration integrity — pre-change payloads load; the pre-change single nickname still matches; no loss | [NFR-FCU-006](NFR-FCU-006-migration-compatibility.md), [FR-FCU-002](../FR/FR-FCU-002-link-reference-storage-and-migration.md), [FR-FCU-011](../FR/FR-FCU-011-multi-nickname-storage-and-migration.md) |
