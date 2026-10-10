# Non-Functional Requirements — Multi-Turn Conversation (v1)

12 non-functional requirements. IDs are namespaced `NFR-MTC-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`NFR-LCT-NNN`), profile-interview used (`NFR-PI-NNN`)
and spotify-music-integration used (`NFR-SP-NNN`). This page covers the
`multi-turn-conversation` set (`NFR-MTC-*`) only; the earlier feature files remain in this
folder and are not part of this feature's requirements or lock.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-MTC-001](NFR-MTC-001-probe-turn-latency.md) | Probe and answer turns stay within the existing turn envelope | Performance | MUST |
| [NFR-MTC-002](NFR-MTC-002-prompt-budget-and-token-ceiling.md) | 1024-token ceiling and the pinned prompt budget are preserved | Reliability / Maintainability | MUST |
| [NFR-MTC-003](NFR-MTC-003-no-new-network-egress.md) | No new network egress — probes and answers stay on-device | Privacy | MUST |
| [NFR-MTC-004](NFR-MTC-004-log-safety.md) | Log safety — probe and answer text never reach logs | Privacy / Security | MUST |
| [NFR-MTC-005](NFR-MTC-005-degraded-brain-deterministic-path.md) | The frame survives a degraded or absent brain — deterministic path | Reliability | MUST |
| [NFR-MTC-006](NFR-MTC-006-localisation.md) | Localisation of every dialogue string (ne/en) | Localisation | MUST |
| [NFR-MTC-007](NFR-MTC-007-sustained-multi-turn-stability.md) | Sustained multi-turn stability on 6 GB devices — no jetsam | Reliability / Performance | MUST |
| [NFR-MTC-008](NFR-MTC-008-answer-sanitisation-and-injection-safety.md) | Answer-path sanitisation and injection safety | Security | MUST |
| [NFR-MTC-009](NFR-MTC-009-voice-only-accessibility.md) | Voice-only accessibility of probes and answer capture | Accessibility | MUST |
| [NFR-MTC-010](NFR-MTC-010-frame-trap-resistance.md) | Frame-trap resistance — zero stuck states | Reliability / Safety | MUST |
| [NFR-MTC-011](NFR-MTC-011-kv-prefix-stability.md) | KV-prefix stability — the frame clause never mutates the template prefix | Performance / Reliability | MUST |
| [NFR-MTC-012](NFR-MTC-012-compliance-and-release-gates.md) | Compliance, no-regression and release gates | Compliance | MUST |

## Coverage of the security-relevant surfaces (workflow focus areas)

| Surface (workflow `security-design-review` / `security-test` focus) | Covered by |
|---|---|
| Emergency precedence mid-dialogue: emergency keywords win mid-frame; a hostile or corrupted answer cannot bypass the override | [FR-MTC-011](../FR/FR-MTC-011-emergency-precedence-mid-frame.md), [NFR-MTC-010](NFR-MTC-010-frame-trap-resistance.md) |
| Free-text answer injection: answers enter routing mid-frame; interception must open no new injection surface | [NFR-MTC-008](NFR-MTC-008-answer-sanitisation-and-injection-safety.md), [FR-MTC-009](../FR/FR-MTC-009-pre-ladder-answer-interception.md), [FR-MTC-017](../FR/FR-MTC-017-transcript-cache-bypass.md) |
| Frame-trap resistance: cancel, barge-in and the 45 s timeout must always recover | [FR-MTC-010](../FR/FR-MTC-010-cancel-drops-the-frame.md), [FR-MTC-012](../FR/FR-MTC-012-barge-in-strong-new-command.md), [FR-MTC-013](../FR/FR-MTC-013-timeout-silent-rearm.md), [NFR-MTC-010](NFR-MTC-010-frame-trap-resistance.md) |
| Log sanitisation: probe texts and captured answers must not reach logs (B2/T-050 precedent) | [NFR-MTC-004](NFR-MTC-004-log-safety.md), [NFR-MTC-012](NFR-MTC-012-compliance-and-release-gates.md) |
| No new egress: probes and answers stay on-device | [NFR-MTC-003](NFR-MTC-003-no-new-network-egress.md) |
| Degraded-brain path: the deterministic merge must not weaken the emergency/safety gates | [NFR-MTC-005](NFR-MTC-005-degraded-brain-deterministic-path.md), [FR-MTC-011](../FR/FR-MTC-011-emergency-precedence-mid-frame.md) |

## Related

- [FR index](../FR/index.md) — 20 functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
