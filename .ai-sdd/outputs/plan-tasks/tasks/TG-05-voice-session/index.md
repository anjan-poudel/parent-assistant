# TG-05: Voice Session

> **Jira Epic:** Voice Session

## Description

Delivers the `VoiceSessionCoordinator` finite state machine (FSM) that orchestrates the complete end-to-end voice interaction flow: IDLE → LISTENING → TRANSCRIBING → AUTHENTICATING → PROCESSING → RESPONDING → IDLE. This is the top-level integration point that wires together all TG-02 (voice I/O), TG-03 (AI), and TG-04 (auth) components.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-022](T-022-voice-session-coordinator/) | VoiceSessionCoordinator | M+M | T-005, T-009, T-012, T-017, T-021, T-007 | HIGH |

## Group effort estimate

- Optimistic (full parallel, 2 devs on iOS + Android subtasks): 3–5 days
- Realistic (2 devs): 6–10 days
