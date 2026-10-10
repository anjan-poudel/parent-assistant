# TG-28: Acceptance, Evidence and Device Protocol

> **Jira Epic:** Acceptance, Evidence and Device Protocol

## Description

The feature close-out: the end-to-end acceptance suite with the bhajan anchor
scenario plus the no-regression sweep across all pinned surfaces (T-141), the
security evidence index tying every E-row to its producer output (T-142), and
the FR-MTC-020 device-validation protocol/record for DV-1..DV-5 on Anzaan — a
PROTOCOL task whose execution is owner/device-dependent (T-143).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-141](T-141-end-to-end-acceptance-and-regression-sweep.md) | End-to-end acceptance and no-regression sweep | M (2.5 d) | T-133, T-134, T-136, T-139, T-140 | HIGH |
| [T-142](T-142-security-evidence-index.md) | Security evidence index (E1..E8, V-1..V-4, R1..R5) | S (1.5 d) | T-138, T-139, T-140, T-141 | HIGH |
| [T-143](T-143-device-validation-protocol.md) | DV-1..DV-5 protocol and record (FR-MTC-020) | S (1 d) | T-136, T-138 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel): 3 days
- Realistic (2 developers): 3.5 days
