# Functional Requirements — Conversational Nepali Replies (v1)

29 functional requirements. IDs are namespaced `FR-CNR-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`), multi-turn-conversation used (`FR-MTC-NNN`),
family-contacts-unify used (`FR-FCU-NNN`) and call-dialer-primary-secondary used (`FR-CDP-NNN`).
This page covers the `conversational-nepali-replies` set (`FR-CNR-*`) only; the earlier feature
files remain in this folder and are not part of this feature's requirements or lock.

Phasing follows the owner-approved proposal: P0 (runtime, no training) → P1 (corpus + chat-aware
v17 fine-tune) → P2 (polish, after P1). P0 and P1 items are MUST (launch blockers for this
feature's success criteria); P2 items are SHOULD/COULD and are explicitly sequenced after P1.

| ID | Title | Area | Priority | Phase |
|----|-------|------|----------|-------|
| [FR-CNR-001](FR-CNR-001-nepali-chat-style-spec-single-source.md) | Nepali conversation style spec — one source of truth for the conversational register | Style Spec / Single Source | MUST | P0 |
| [FR-CNR-002](FR-CNR-002-persona-upgrade-both-seams.md) | Persona upgrade in both seams — same style contract, local and cloud | Persona / Local + Cloud Seams | MUST | P0 |
| [FR-CNR-003](FR-CNR-003-chat-turn-fixed-seed-temp.md) | Chat-turn sampling — fixed seed with temperature ~0.3, chat turns only | Decode / Chat Sampling | MUST | P0 |
| [FR-CNR-004](FR-CNR-004-command-decode-determinism-preserved.md) | Command-turn decode determinism preserved — temp-0 + fixed seed + GBNF untouched | Decode / Determinism Invariant | MUST | P0 |
| [FR-CNR-005](FR-CNR-005-grammar-guard-verify-never-rewrite.md) | Deterministic Nepali grammar guard at the polisher seam — verify, never rewrite | Grammar Guard / Verification | MUST | P0 |
| [FR-CNR-006](FR-CNR-006-guard-flag-escalation-honest-degradation.md) | Guard flag outcome — escalate to the cloud persona or a safe template; honest degradation | Grammar Guard / Degradation | MUST | P0 |
| [FR-CNR-007](FR-CNR-007-reply-grammar-flag-telemetry-no-content.md) | `reply_grammar_flag` telemetry — observability without user content | Grammar Guard / Telemetry | MUST | P0 |
| [FR-CNR-008](FR-CNR-008-cloud-first-chat-routing-toggle.md) | Cloud-first chat routing toggle — online routes to Gemini, local brain is the floor | Cloud Chat Routing | MUST | P0 |
| [FR-CNR-009](FR-CNR-009-cloud-chat-consent-disclosure-indicator.md) | Cloud chat consent, plain-language disclosure, visible indicator and revocation (the OD-12 shape) | Cloud Chat Consent & Disclosure | MUST | P0 |
| [FR-CNR-010](FR-CNR-010-cloud-chat-egress-scope.md) | Cloud chat egress scope — the chat turn's user content and nothing else | Cloud Chat Egress Scope | MUST | P0 |
| [FR-CNR-011](FR-CNR-011-explicit-gemini-chat-temperature.md) | Explicit Gemini chat temperature — a stated, reviewed value instead of a provider default | Cloud Chat Sampling Config | MUST | P0 |
| [FR-CNR-012](FR-CNR-012-cloud-chat-credential-and-content-hygiene.md) | Cloud chat credential and content hygiene — header-only key, content off the logs | Cloud Chat Hygiene | MUST | P0 |
| [FR-CNR-013](FR-CNR-013-single-decode-schema-unchanged.md) | Single-decode schema unchanged — one JSON, and an unreadable object abstains | Single-Decode Integrity | MUST | P0/P1 |
| [FR-CNR-014](FR-CNR-014-router-ladder-emergency-gate-unchanged.md) | Router ladder and the emergency path unchanged — emergency recall 1.00 is a gate, not a metric | Preserved Behaviours / Safety Path | MUST | P0/P1 |
| [FR-CNR-015](FR-CNR-015-stt-permissions-data-collection-unchanged.md) | STT pipeline, device permissions and data collection unchanged | Preserved Behaviours / Privacy & Permissions | MUST | P0/P1 |
| [FR-CNR-016](FR-CNR-016-v17-chat-aware-qlora-variant.md) | v17 — a chat-aware QLoRA variant of the existing training suite (same model family) | Training / v17 Suite Extension | MUST | P1 |
| [FR-CNR-017](FR-CNR-017-four-layer-corpus-construction.md) | Four-layer conversation corpus construction shaped by the style spec | Training Data / Corpus Construction | MUST | P1 |
| [FR-CNR-018](FR-CNR-018-ship-mix-provenance-manifest.md) | Ship-mix provenance manifest — no CC BY-NC contamination of a shipped artifact | Training Data / Provenance & Licensing | MUST | P1 |
| [FR-CNR-019](FR-CNR-019-chat-golden-heldout-eval-set.md) | `eval/chat_golden.jsonl` — a held-out chat evaluation set | Evaluation / Held-out Set | MUST | P1 |
| [FR-CNR-020](FR-CNR-020-new-chat-gates.md) | The new chat gates — honorific agreement, no AI-isms, LLM-judge quality | Evaluation / Chat Gates | MUST | P1 |
| [FR-CNR-021](FR-CNR-021-full-gate-harness-before-swap.md) | The full gate harness is the ship gate — existing regressions are non-negotiable | Evaluation / Regression Gates & Ship Gate | MUST | P1 |
| [FR-CNR-022](FR-CNR-022-v17-catalog-entry-versioned-reversible.md) | v17 catalog entry — versioned, reversible, gated, with per-device tier selection | Model Delivery / Catalog Swap | MUST | P1 |
| [FR-CNR-023](FR-CNR-023-chat-prompt-template-discipline.md) | Chat prompt/template discipline — seed byte-mirror, intent prompt untouched, no few-shot exemplars | Prompt Discipline / Seed Mirror | MUST | P0/P1 |
| [FR-CNR-024](FR-CNR-024-feasibility-honesty-reporting.md) | Feasibility honesty — every leg reported explicitly, no silent drop | Delivery / Feasibility Reporting | MUST | All |
| [FR-CNR-025](FR-CNR-025-dv-device-validation-completion-gate.md) | DV-1 … DV-6 device validation on Anzaan — the recorded completion gate | Validation / Completion Gate | MUST | All |
| [FR-CNR-026](FR-CNR-026-p2-dpo-on-judge-preferences.md) | P2 polish — DPO on judge preferences | P2 Polish / Preference Tuning | SHOULD | P2 |
| [FR-CNR-027](FR-CNR-027-p2-romanized-nepali-chat.md) | P2 polish — romanized-Nepali chat | P2 Polish / Romanized Input | COULD | P2 |
| [FR-CNR-028](FR-CNR-028-p2-4b-tier-per-device-resolver.md) | P2 polish — the 4B chat tier, admitted only through the per-device resolver | P2 Polish / Device Tiers | COULD | P2 |
| [FR-CNR-029](FR-CNR-029-p2-consent-based-real-transcripts.md) | P2 polish — consent-based real conversation transcripts as the gold source | P2 Polish / Own-Data Corpus | COULD | P2 |

## Coverage of the owner-approved proposal

| Proposal area | Requirements |
|---|---|
| §2 Nepali conversation pattern spec (the centerpiece) | FR-CNR-001; consumed by FR-CNR-002 (personas), FR-CNR-005 (guard checks), FR-CNR-017 (data prompts), FR-CNR-020 (gates) |
| §3 Data plan — Layers 1–4, license posture | FR-CNR-017, FR-CNR-018 |
| §4 Training — chat-aware v17 variant, recipe, data-not-prompt style | FR-CNR-016, FR-CNR-023; base/tier — FR-CNR-022, FR-CNR-028 |
| §5 Runtime (P0) — decode, grammar guard, cloud-first toggle, persona | FR-CNR-003 (decode), FR-CNR-005–007 (guard), FR-CNR-008–012 (cloud chat), FR-CNR-002 (persona) |
| §6 Evaluation and gates — new gates + non-negotiable regressions, device A/B, listening panel | FR-CNR-019, FR-CNR-020, FR-CNR-021, FR-CNR-025 |
| §7 Phasing and risks — P0/P1/P2, licensing, latency, gibberish | FR-CNR-024 (honesty), FR-CNR-026–029 (P2); risks bound by FR-CNR-004, FR-CNR-014, FR-CNR-018, FR-CNR-021 |
| "Single-decode architecture stays untouched" | FR-CNR-013, FR-CNR-014, FR-CNR-015 |
