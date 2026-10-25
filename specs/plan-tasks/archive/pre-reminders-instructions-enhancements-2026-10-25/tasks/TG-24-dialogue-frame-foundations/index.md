# TG-24: Dialogue Frame Foundations

> **Jira Epic:** Dialogue Frame Foundations

## Description

Delivers the new dialogue-frame core (C-MTC-01 `DialogueManager` + `DialogueFrame`
+ `DialogueProbeComposer`), the curated on-device option catalog (C-MTC-04), the
shared input-seam helper (C-MTC-08c `IntentTranscriptPreparation`), the two
barge-in predicate access widenings (L2-D2) and the 17-key localisation inventory
(C-MTC-09). Everything here is a dependency of the answer path, the router
interception and the coordinator wiring, and none of it changes shipped behaviour
on its own.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-125](T-125-dialogue-manager-frame-core.md) | Dialogue frame, manager and probe composer | M (2 d) | — | HIGH |
| [T-126](T-126-dialogue-option-catalog.md) | Curated option catalog and bundled resource | M (2 d) | — | MEDIUM |
| [T-127](T-127-intent-transcript-preparation.md) | Shared input-seam helper | S (1 d) | — | MEDIUM |
| [T-128](T-128-barge-in-predicate-access-widenings.md) | Barge-in predicate access widenings | S (0.5 d) | — | LOW |
| [T-129](T-129-dialogue-localisation-keys.md) | `dialogue.*` localisation inventory (17 keys) | S (1 d) | — | MEDIUM |

## Group effort estimate

- Optimistic (full parallel): 2 days
- Realistic (2 developers): 4 days
