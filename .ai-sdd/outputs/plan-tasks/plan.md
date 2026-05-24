# Task Breakdown — Elderly AI Assistant

## Summary
- Task groups: 7 (Jira Epics)
- Total tasks: 21 parent tasks (32 original task IDs preserved)
- Subtasks: 24 subtasks (platform splits)
- Estimated effort: 27–45 days (full parallel) / 73–121 days (sequential)
- Critical path: T-001 → T-002 → T-018 → T-020 → T-021 → T-022

## Contents
- [tasks/index.md](tasks/index.md) — all task groups

## Critical path

The longest dependency chain runs through TG-01 → TG-03 → TG-05:

```
T-001 → T-002-a → T-018-a → T-020 → T-021 → T-022-a
```

Sequential effort on this chain: ~27 days iOS.

**Safety-critical path (independent of LLM — should be delivered first):**
```
T-001 → T-002-a → T-024-a → T-026-a
```
Sequential effort: ~12 days iOS.

**Full parallelisation opportunity:** iOS and Android streams run simultaneously across all task groups. TG-06 (Safety-Critical Services) can be developed fully in parallel with TG-03 (On-Device AI) and TG-04 (Authentication). The safety-critical services have no LLM dependency by design.

## Key risks

1. **HIGH — PAD/liveness detection BLOCKER (T-014-a, T-014-b):** THREAT-001 from security-design-review.md requires a PAD design note to be reviewed and approved before either VoiceBiometricAuth subtask can start. This is a CI gate.
2. **HIGH — LLM OOM on low-end Android (T-018-b):** Runtime RAM check required; decline load if < 2.5 GB available with user-visible notice.
3. **HIGH — Emergency silent TTS failure (T-012-a, T-012-b, T-026-a, T-026-b):** Platform-native TTS fallback required; blocking CI test failure.
4. **HIGH — Safety-critical services not isolated from LLM (T-024–T-028):** Build target isolation enforced; CI build test verifies no LLM import.
5. **HIGH — Signal Protocol prekey exhaustion (T-030):** Pre-generate 100 prekeys; auto-refresh when supply < 5.
6. **MEDIUM — iOS BGTaskScheduler budget exceeded (T-028-a):** Local notifications as primary; BGTask supplemental only.
7. **MEDIUM — openWakeWord model size in app binary (T-005-a, T-005-b):** Download-on-first-launch with fallback to manual activation.

## Security blockers

From `security-design-review.md`:

- **THREAT-001 — BLOCKER on T-014-a and T-014-b (VoiceBiometricAuth):** PAD/liveness detection design note must be reviewed and approved by the security reviewer before either VoiceBiometricAuth subtask can start. The implementing team must document which PAD approach is selected: (a) ECAPA-TDNN variant with built-in PAD, or (b) AASIST-based separate anti-spoofing model.

---

## Task Group Summary

| Group | Title | Tasks | Subtasks | Key Risk |
|-------|-------|-------|----------|----------|
| [TG-01](tasks/TG-01-foundation-infrastructure/index.md) | Foundation & Infrastructure | 3 | 2 (T-002) | MEDIUM |
| [TG-02](tasks/TG-02-voice-interface/index.md) | Voice Interface | 5 | 8 (T-005, T-007, T-009, T-012) | MEDIUM |
| [TG-03](tasks/TG-03-on-device-ai/index.md) | On-Device AI | 3 | 2 (T-018) | HIGH |
| [TG-04](tasks/TG-04-authentication-security/index.md) | Authentication & Security | 3 | 2 (T-014) | HIGH |
| [TG-05](tasks/TG-05-voice-session/index.md) | Voice Session | 1 | 2 (T-022) | HIGH |
| [TG-06](tasks/TG-06-safety-critical-services/index.md) | Safety-Critical Services | 3 | 6 (T-024, T-026, T-028) | HIGH (SAFETY CRITICAL) |
| [TG-07](tasks/TG-07-remote-configuration/index.md) | Remote Configuration | 3 | 2 (T-032) | HIGH/MEDIUM |
| **Total** | | **21** | **24** | |

---

## Traceability

| Task | Requirements Covered |
|------|---------------------|
| T-002 (a+b) | NFR-015, NFR-016 |
| T-004 | NFR-015, NFR-016 |
| T-005 (a+b) | FR-004, NFR-006, NFR-007 |
| T-007 (a+b) | FR-004, NFR-006, NFR-007 |
| T-009 (a+b) | FR-001, FR-002, FR-005, NFR-001 |
| T-011 | FR-005 |
| T-012 (a+b) | FR-002, FR-003, FR-006 |
| T-014 (a+b) | FR-011, FR-012, FR-013, NFR-011 |
| T-016 | FR-014 |
| T-017 | FR-013, FR-014, FR-015 |
| T-018 (a+b) | FR-007, FR-008, FR-009, NFR-002 |
| T-020 | NFR-013 (prompt injection) |
| T-021 | FR-008 |
| T-022 (a+b) | FR-001–FR-006, NFR-001–NFR-002 |
| T-024 (a+b) | FR-031, FR-032, NFR-004, NFR-026 |
| T-026 (a+b) | FR-033, FR-034, FR-035, FR-036, NFR-026, NFR-028 |
| T-028 (a+b) | FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027 |
| T-030 | FR-038, FR-039, NFR-012 |
| T-031 | FR-040, FR-041, FR-042 |
| T-032 (a+b) | FR-038–FR-046 |
