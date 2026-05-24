# TG-04: Authentication & Security

> **Jira Epic:** Authentication & Security

## Description

Delivers the full authentication stack: voice biometric auth with mandatory Presentation Attack Detection (PAD) on both platforms, PIN fallback using Argon2id, and the AuthCoordinator that orchestrates the biometric-to-PIN-to-re-enrolment flow. Contains a CRITICAL BLOCKER from security-design-review (THREAT-001) that must be resolved before T-014 can start.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-014](T-014-voice-biometric-auth/) | VoiceBiometricAuth (PAD-required) | L+L | T-002, T-007, T-004 | HIGH |
| [T-016](T-016-pin-fallback-auth.md) | PinFallbackAuth (Argon2id) | S | T-002 | MEDIUM |
| [T-017](T-017-auth-coordinator.md) | AuthCoordinator | S | T-014, T-016 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel, 2 devs on T-014 subtasks, T-016 parallel): 6–10 days
- Realistic (2 devs): 8–14 days
