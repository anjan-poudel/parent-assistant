# TG-04: Tier-0 Dictionary and Persistent Cache

> **Jira Epic:** Tier-0 Dictionary and Persistent Cache

## Description

Extends the shipped curated dictionary by data only (C06) and builds the one shared, persistent,
encrypted translation store (C05) with the dictionary as a read-through layer, an LRU bound on
general entries, a monotone ordering counter (AM-6) and self-healing failure behaviour — then wires
the appliance helper's presentation seam onto the same store without changing what it renders today.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-011](T-011-curated-dictionary-extension.md) | Curated dictionary extension (C06, data only) | M | — | MEDIUM |
| [T-012](T-012-label-translation-cache.md) | `LabelTranslationCache` (C05, AM-6) | L | T-001, T-003, T-011 | HIGH |
| [T-013](T-013-appliance-helper-shared-cache-seam.md) | Appliance-helper shared-cache presentation seam (R8 / CL-7) | M | T-011, T-012 | HIGH |

## Group effort estimate

- Optimistic (T-011 authoring in parallel with T-012 groundwork): 3–4 days
- Realistic (2 devs; T-013 needs both): 4–7 days
