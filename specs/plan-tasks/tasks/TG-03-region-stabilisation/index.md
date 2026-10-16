# TG-03: Region Stabilisation and Decluttering

> **Jira Epic:** Region Stabilisation and Decluttering

## Description

Turns raw per-pass OCR observations into stable, identified text regions with two-sided hysteresis
and change-only events (C03) — the single gate that bounds translation traffic — and declutters dense
multi-region scenes (a menu page) before anything is rendered or requested.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-009](T-009-text-region-stabilizer.md) | `TextRegionStabilizer` (C03) | M | T-001, T-007 | HIGH |
| [T-010](T-010-decluttering-merge-and-cap.md) | Decluttering — merge and region cap (C03) | M | T-001, T-009 | HIGH |

## Group effort estimate

- Optimistic (full parallel on the pure-logic suites): 1.5–2 days
- Realistic (1 dev, T-010 extends T-009's type): 2–2.5 days
