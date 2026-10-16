# TG-26: Router Interception and Window State

> **Jira Epic:** Router Interception and Window State

## Description

The single integration point: the router interception block between the
confirmation hook and the safety net (C-MTC-05 part 1, T-133), the degenerate
triggers and did-you-mean upgrades reusing the R2 composition (C-MTC-05 part 2,
T-134), the `awaitingSlotAnswer` state with the 45 s answer window (C-MTC-07,
T-135) and the coordinator ownership, funnel and timeout wiring (C-MTC-08,
T-136). T-133 and T-134 edit the same file and are sequential, never parallel.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-133](T-133-router-dialogue-interception.md) | Router interception block, protocol and execution | XL (5 d) | T-125, T-126, T-128, T-131 | CRITICAL |
| [T-134](T-134-degenerate-triggers-and-did-you-mean.md) | Degenerate-music triggers and did-you-mean upgrades | L (3 d) | T-130, T-132, T-133 | HIGH |
| [T-135](T-135-voice-session-awaiting-slot-answer.md) | `awaitingSlotAnswer` state and 45 s window | M (2.5 d) | — | HIGH |
| [T-136](T-136-app-coordinator-dialogue-wiring.md) | Coordinator wiring: ownership, funnels, timeout | L (4 d) | T-127, T-133, T-135 | HIGH |

## Group effort estimate

- Optimistic (full parallel): 8 days
- Realistic (2 developers): 9 days
