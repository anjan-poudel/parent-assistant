# TG-15: Personalization Paths — Prompt Clause, Seed Mirror, Wake Ack

> **Jira Epic:** Personalization Paths — Prompt Clause, Seed Mirror, Wake Ack

## Description

The two paths the profile actually travels on: the reply-side prompt clause (with its training-seed mirror and the build-blocking gate that keeps them byte-equal), and the wake-time acknowledgment (pipeline extraction, the ack service, and its wiring). Everything here consumes the TG-14 foundations; nothing here writes profile data.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-094](T-094-prompt-clause-and-seed-mirror-gate.md) | Prompt clause + seed mirror + build gate (C06, C08) | L | T-091, T-092 | HIGH |
| [T-095](T-095-capture-extraction-and-ack-seam.md) | `VoicePipeline.beginCapture` extraction + ack seam (C05) | M | — | HIGH |
| [T-096](T-096-wake-acknowledgment-service.md) | `WakeAcknowledgmentService` + coordinator wiring (C05) | L | T-092, T-093, T-095 | HIGH |

## Group effort estimate

- Optimistic (full parallel where the dependencies allow): 6–8 days
- Realistic (2 devs): 9.5–12 days
