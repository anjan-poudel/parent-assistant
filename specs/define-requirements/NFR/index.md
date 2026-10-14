# Non-Functional Requirements — Conversational Nepali Replies (v1)

11 non-functional requirements. IDs are namespaced `NFR-CNR-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`NFR-LCT-NNN`), profile-interview used (`NFR-PI-NNN`),
spotify-music-integration used (`NFR-SP-NNN`), multi-turn-conversation used (`NFR-MTC-NNN`),
family-contacts-unify used (`NFR-FCU-NNN`) and call-dialer-primary-secondary used (`NFR-CDP-NNN`).
This page covers the `conversational-nepali-replies` set (`NFR-CNR-*`) only; the earlier feature
files remain in this folder and are not part of this feature's requirements or lock.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-CNR-001](NFR-CNR-001-chat-reply-reproducibility.md) | Chat reply reproducibility — fixed seed, same input, same reply | Reliability / Determinism | MUST |
| [NFR-CNR-002](NFR-CNR-002-listening-turn-latency-envelope.md) | Listening-turn latency envelope — chat replies stay within the spoken-conversation budget | Performance | MUST |
| [NFR-CNR-003](NFR-CNR-003-memory-and-jetsam-device-tiers.md) | Memory and jetsam behaviour — one brain resident, zero feature-attributable terminations | Reliability / Resource Behaviour | MUST |
| [NFR-CNR-004](NFR-CNR-004-chat-prompt-token-budget.md) | Chat prompt token budget — the 1,024-token ceiling holds | Performance / Resource Budget | MUST |
| [NFR-CNR-005](NFR-CNR-005-prompt-template-byte-mirror.md) | Prompt-template byte-mirror discipline — seed and code cannot drift | Reliability / Build Discipline | MUST |
| [NFR-CNR-006](NFR-CNR-006-log-safety.md) | Log safety — no conversation content, transcript or key material in any log | Privacy / Security | MUST |
| [NFR-CNR-007](NFR-CNR-007-telemetry-content-hygiene.md) | Telemetry content hygiene — every new event carries classification only | Privacy | MUST |
| [NFR-CNR-008](NFR-CNR-008-gate-thresholds.md) | Gate thresholds — the measurable ship conditions for the v17 swap | Quality / Evaluation Gates | MUST |
| [NFR-CNR-009](NFR-CNR-009-accessibility.md) | Accessibility — voice-first, house touch standards, and no routing reasoning asked of the elderly user | Accessibility | MUST |
| [NFR-CNR-010](NFR-CNR-010-localisation-ne-en.md) | Localisation — every new user-visible string exists in Nepali and English | Localisation | MUST |
| [NFR-CNR-011](NFR-CNR-011-compliance-and-release-gates.md) | Compliance and release gates — workflow gates, the log gate, and honest baseline reporting | Compliance | MUST |

## Coverage of the workflow's security focus areas

| Focus area (workflow `security-design-review` / `security-test`) | Covered by |
|---|---|
| Safety-gate regression on the shared model — the v17 chat variant serves the intent and emergency paths; catalog swap versioned/reversible; command decode determinism untouched | [FR-CNR-004](../FR/FR-CNR-004-command-decode-determinism-preserved.md), [FR-CNR-014](../FR/FR-CNR-014-router-ladder-emergency-gate-unchanged.md), [FR-CNR-021](../FR/FR-CNR-021-full-gate-harness-before-swap.md), [FR-CNR-022](../FR/FR-CNR-022-v17-catalog-entry-versioned-reversible.md), [NFR-CNR-008](NFR-CNR-008-gate-thresholds.md) |
| NEW cloud egress surface — chat conversation content reaches Gemini via routing and guard escalation; consent/disclosure in the OD-12 shape; never blocks chat | [FR-CNR-008](../FR/FR-CNR-008-cloud-first-chat-routing-toggle.md), [FR-CNR-009](../FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [FR-CNR-010](../FR/FR-CNR-010-cloud-chat-egress-scope.md), [FR-CNR-006](../FR/FR-CNR-006-guard-flag-escalation-honest-degradation.md) |
| Credential + content hygiene — key in header only, never URLs or logs; conversation content off the logs; the flag event carries no user content | [FR-CNR-012](../FR/FR-CNR-012-cloud-chat-credential-and-content-hygiene.md), [FR-CNR-007](../FR/FR-CNR-007-reply-grammar-flag-telemetry-no-content.md), [NFR-CNR-006](NFR-CNR-006-log-safety.md), [NFR-CNR-007](NFR-CNR-007-telemetry-content-hygiene.md) |
| Guard integrity — verify-never-rewrite; honest degradation on guard failure; never a false success | [FR-CNR-005](../FR/FR-CNR-005-grammar-guard-verify-never-rewrite.md), [FR-CNR-006](../FR/FR-CNR-006-guard-flag-escalation-honest-degradation.md) |
| Data provenance — ship mix CC-BY/Apache/MIT + synthetic + own data only; no CC BY-NC contamination; provenance manifest as evidence | [FR-CNR-018](../FR/FR-CNR-018-ship-mix-provenance-manifest.md), [FR-CNR-017](../FR/FR-CNR-017-four-layer-corpus-construction.md) |
| Prompt discipline — 1,024-token budget; `chat_prompt_template.txt` byte-mirrors `IntentPrompt.buildChat`; intent prompt untouched; no few-shot exemplars | [FR-CNR-023](../FR/FR-CNR-023-chat-prompt-template-discipline.md), [NFR-CNR-004](NFR-CNR-004-chat-prompt-token-budget.md), [NFR-CNR-005](NFR-CNR-005-prompt-template-byte-mirror.md) |
| Determinism and resource behaviour on device tiers — fixed-seed reproducibility; latency envelope; one brain resident; jetsam | [NFR-CNR-001](NFR-CNR-001-chat-reply-reproducibility.md), [NFR-CNR-002](NFR-CNR-002-listening-turn-latency-envelope.md), [NFR-CNR-003](NFR-CNR-003-memory-and-jetsam-device-tiers.md) |
| Unchanged surfaces — STT pipeline, permissions, data collection, ladder/emergency path, single-decode schema | [FR-CNR-013](../FR/FR-CNR-013-single-decode-schema-unchanged.md), [FR-CNR-015](../FR/FR-CNR-015-stt-permissions-data-collection-unchanged.md) |
