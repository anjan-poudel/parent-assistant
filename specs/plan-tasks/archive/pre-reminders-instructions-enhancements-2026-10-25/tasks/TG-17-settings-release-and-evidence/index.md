# TG-17: Settings, Log Safety and Release Evidence

> **Jira Epic:** Settings, Log Safety and Release Evidence

## Description

Closes the feature: the Settings destination that makes every field editable after the interview (FR-PI-012), the fail-closed log-safety coverage that puts the feature's own sources under the strict gate rules (AM-4), and the release-evidence bundle that runs the device-side obligations and the OD-A1 latency measurement. The last task is a coordinator task, not a code task — it produces evidence, not behavior.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-103](T-103-profile-settings-editor.md) | Profile Settings editor + destination row (C04) | M | T-092, T-093, T-097, T-098 | MEDIUM |
| [T-104](T-104-log-safety-coverage.md) | Log-safety coverage — redacted keys + feature roots (C10) | M | T-102, T-103 | HIGH |
| [T-105](T-105-release-evidence-and-device-validation.md) | Release evidence bundle + device validation (obligations 4, 5, 7; OD-A1) | L | T-094, T-096, T-102, T-103, T-104 | HIGH |

## Group effort estimate

- Optimistic (full parallel where the dependencies allow): 4–5 days
- Realistic (2 devs): 8–10 days
