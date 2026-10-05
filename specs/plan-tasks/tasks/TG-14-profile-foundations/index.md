# TG-14: Profile Foundations — Store, Guard, Seams, Strings

> **Jira Epic:** Profile Foundations — Store, Guard, Seams, Strings

## Description

Delivers the base every other group builds on: the one encrypted profile record (C01), the prompt-injection discipline and read seam for the single profile string that may enter a prompt (C07), the coordinator writer/snapshot seam (C01 writer), and the localisation catalogue additions (C09). Nothing here is user-facing by itself; every later task consumes these interfaces exactly as settled in `specs/design-l2.md` §5.1, §5.3, §5.6 and C09.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-090](T-090-user-profile-store.md) | `UserProfileStore` — encrypted profile record (C01) | L | — | HIGH |
| [T-091](T-091-profile-prompt-guard-and-personalization.md) | `ProfilePromptTextGuard` + `ProfilePersonalization` (C07, AM-1, AM-2) | M | T-090 | HIGH |
| [T-092](T-092-coordinator-profile-seams.md) | Coordinator profile seams — writer, snapshot, personalization (C01) | M | T-090, T-091 | MEDIUM |
| [T-093](T-093-l10n-catalog-additions.md) | L10n catalogue additions (C09) | M | — | MEDIUM |

## Group effort estimate

- Optimistic (full parallel where the dependencies allow): 6–8 days
- Realistic (2 devs): 9.5–12 days
