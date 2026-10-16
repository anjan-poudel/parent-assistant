# TG-09: Pipeline, Session Model, Plugin and Session View

> **Jira Epic:** Pipeline, Session Model, Plugin and Session View

## Description

The join point of the feature. The pipeline actor owns the stabiliser and walks each changed region
through the cache/dictionary layer, the consent gate, the cost latch and the tier, publishing
monotonic outcomes to the session model (including the origin → tier mapping, CL-3, and the
interruption-resume recovery). The plugin registers in the registry, opens by voice with **no**
provider-key guard, and presents the full-bleed session view with one close control.

Nothing downstream of this group is meaningful until it lands, and it cannot start until both the
camera track and the cloud track are complete.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-026](T-026-translation-pipeline-and-session-model.md) | Translation pipeline and session model (C13) | XL | T-002, T-003, T-006, T-007, T-009, T-010, T-012, T-013, T-014, T-015, T-016, T-017, T-019, T-020, T-021, T-022, T-023, T-024, T-025 | CRITICAL |
| [T-027](T-027-plugin-entry-and-session-view.md) | Plugin entry, registration and session view (C13) | L | T-005, T-006, T-008, T-015, T-021, T-025, T-026 | HIGH |

## Group effort estimate

- Optimistic (strictly sequential — T-027 builds on T-026): 6 days
- Realistic (1 dev on the chain): 6–7 days
