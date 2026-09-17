# TG-06: Sanitiser, Client Method and Tier Orchestration

> **Jira Epic:** Sanitiser, Client Method and Tier Orchestration

## Description

The cloud egress path, end to end: recognized scene text is bounded and detect-only-quarantined
before it can enter a payload (C07); the only translation request builder is a new method on the
existing `send(_:)` chokepoint that carries text parts only and no tools (C08, AM-7, AM-9); and the
tier orchestrates consent, the session cost latch (C15), in-flight dedupe with terminal outcomes
(AM-8), one batched request, at most one retry with a consent re-read and cancellation treated as
terminal (AM-1), a deadline, and response validation.

This is the CRITICAL-risk group: AM-1, AM-2 (T-003) and AM-5 (T-028) gate `security-test`, and
`security-test` cannot return `SECURITY-GO` while any of them is open.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-017](T-017-scene-text-sanitiser.md) | `SceneTextSanitiser` (C07) | M | T-001, T-004 | HIGH |
| [T-018](T-018-gemini-translate-client-and-prompt.md) | `GeminiClient.translateStrings` and prompt handling (AM-7, AM-9) | L | T-001, T-002, T-014, T-017 | CRITICAL |
| [T-019](T-019-cloud-translation-tier.md) | `CloudTranslationTier` orchestration (C08, C15, AM-1, AM-8) | XL | T-001, T-002, T-012, T-014, T-016, T-017, T-018 | CRITICAL |

## Group effort estimate

- Optimistic (T-017 in parallel with T-014/T-018 groundwork): 4–5 days
- Realistic (2 devs, T-019 on the critical track): 6–7.5 days
