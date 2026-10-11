# Non-Functional Requirements — Call Dialer Primary/Secondary

10 non-functional requirements. IDs are namespaced `NFR-CDP-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`NFR-LCT-NNN`), profile-interview used (`NFR-PI-NNN`),
spotify-music-integration used (`NFR-SP-NNN`) and multi-turn-conversation used (`NFR-MTC-NNN`).
This page covers the `call-dialer-primary-secondary` set (`NFR-CDP-*`) only; the earlier feature
files remain in this folder and are not part of this feature's requirements or lock.

Every NFR carries a measurable target or threshold (the never-dead-end matrix, the ≤ 100 ms
latency budget, the 100% persistence round-trip, the 100% ne/en key parity, the release log-gate
exit 0).

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-CDP-001](NFR-CDP-001-chain-never-dead-ends.md) | The chain never dead-ends — zero dead ends across the exhaustive configuration matrix | Reliability / Safety | MUST |
| [NFR-CDP-002](NFR-CDP-002-local-probes-no-new-egress.md) | Feasibility probes are local — no new network, data, identity or privacy surface | Privacy | MUST |
| [NFR-CDP-003](NFR-CDP-003-log-safety.md) | Log safety — numbers, handles and announcement content never reach logs beyond the existing policy | Privacy / Security | MUST |
| [NFR-CDP-004](NFR-CDP-004-fallback-resolution-latency.md) | Fallback-resolution latency budget — local probes at call time, user-paced | Performance | MUST |
| [NFR-CDP-005](NFR-CDP-005-persistence-round-trip.md) | `secondaryCallApp` persistence round-trip reliability | Reliability (Persistence) | MUST |
| [NFR-CDP-006](NFR-CDP-006-picker-accessibility.md) | Accessibility of the Primary and Fallback dialer pickers | Accessibility | MUST |
| [NFR-CDP-007](NFR-CDP-007-localisation-completeness.md) | Localisation completeness — 100% ne/en parity for every new string | Localisation | MUST |
| [NFR-CDP-008](NFR-CDP-008-deterministic-testability.md) | Deterministic testability under the scoped-suite gate | Reliability / Testability | MUST |
| [NFR-CDP-009](NFR-CDP-009-no-regression-shipped-call-paths.md) | No regression to the shipped voice pipeline, emergency and dial-back paths | Reliability (Regression) | MUST |
| [NFR-CDP-010](NFR-CDP-010-compliance-and-release-gates.md) | Compliance, review and release gates; DV-1..7 acceptance | Compliance | MUST |

## Coverage of the security-relevant surfaces (workflow focus areas)

The workflow's `security-design-review` and `security-test` carry five named focus areas; each
maps onto this set as follows:

| Focus area (workflow) | Covered by |
|---|---|
| GSM hard floor: no configuration (including `secondary == primary`) may produce a dead-end chain | [NFR-CDP-001](NFR-CDP-001-chain-never-dead-ends.md), [FR-CDP-006](../FR/FR-CDP-006-facetime-and-phone-always-feasible.md), [FR-CDP-007](../FR/FR-CDP-007-chain-preferred-secondary-phone.md) |
| Emergency precedence untouched: emergency semantics and the override protocol survive routing; dial-back never delays escalation | [FR-CDP-018](../FR/FR-CDP-018-preserved-behaviours.md), [FR-CDP-014](../FR/FR-CDP-014-override-protocol-preserved.md), [FR-CDP-011](../FR/FR-CDP-011-missed-call-dial-back-routes-the-chain.md), [NFR-CDP-009](NFR-CDP-009-no-regression-shipped-call-paths.md) |
| Feasibility probes local-only: no new egress, no new data collection (handles/numbers are PII) | [NFR-CDP-002](NFR-CDP-002-local-probes-no-new-egress.md), [FR-CDP-004](../FR/FR-CDP-004-messenger-feasibility-handle-on-file.md), [FR-CDP-005](../FR/FR-CDP-005-whatsapp-feasibility-installed-probe.md) |
| Announcement honesty: the spoken confirmation/announcements name the actually-routed channel (`fellBackFrom`); no silent route changes | [FR-CDP-008](../FR/FR-CDP-008-fellbackfrom-attempt-order.md), [FR-CDP-013](../FR/FR-CDP-013-fallback-before-spoken-confirmation.md), [FR-CDP-015](../FR/FR-CDP-015-launch-fail-fallback-announced.md), [FR-CDP-016](../FR/FR-CDP-016-automatic-routing-with-announcement.md) |
| Log sanitisation: numbers/handles must not reach logs beyond the existing transcript policy (B2/T-050) | [NFR-CDP-003](NFR-CDP-003-log-safety.md), [NFR-CDP-010](NFR-CDP-010-compliance-and-release-gates.md) |

## Related

- [FR index](../FR/index.md) — 19 functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
