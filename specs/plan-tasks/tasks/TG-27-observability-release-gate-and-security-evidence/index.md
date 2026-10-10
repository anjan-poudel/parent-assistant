# TG-27: Observability, Release Gate and Security Evidence

> **Jira Epic:** Observability, Release Gate and Security Evidence

## Description

The release-blocking safety surfaces: the six new `LogSanitiser` metadata keys
(M-4), the release log gate's `FEATURE_ROOTS` extension plus fixture entries
(E4), the hostile-answer corpus and trap-matrix suites (E1–E3) and the
cache-bypass, log-capture and egress suites (E5, E6, E8, V-3). T-142 in TG-28
closes the record with the evidence index.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-137](T-137-log-sanitiser-dialogue-keys.md) | `LogSanitiser` dialogue metadata keys (M-4) | S (0.5 d) | — | MEDIUM |
| [T-138](T-138-release-log-gate-dialogue-roots.md) | Release log gate: feature roots and fixtures | S (1 d) | T-125, T-126, T-131, T-132 | HIGH |
| [T-139](T-139-hostile-corpus-and-trap-suites.md) | Hostile-answer corpus and trap matrix suites | L (3.5 d) | T-131, T-133, T-134, T-136 | HIGH |
| [T-140](T-140-cache-bypass-log-and-egress-suites.md) | Cache-bypass, log-capture and egress suites | M (2.5 d) | T-133, T-134, T-136, T-137, T-138 | HIGH |

## Group effort estimate

- Optimistic (full parallel): 4 days
- Realistic (2 developers): 5 days
