# TG-10: Release Gate, Security Evidence and Device Validation

> **Jira Epic:** Release Gate, Security Evidence and Device Validation

## Description

Closes the gates the workflow actually checks. The release log-safety gate gains a rule family for
this feature's content class over the new scan roots and must exit 0 (AM-5) — this gates both
`security-test` and `final-sign-off`. The evidence suite produces, against a stubbed transport, the
exact assertions `security-test` cites (AM-10): consent enforcement including the
withdrawal-between-attempts case, text-only egress on every path including the retry, degradation
integrity, indicator integrity, log-surface survival of the new metadata keys, and cache-at-rest.
Finally, the device protocol turns the nominal OD1 / OD2 / OD5 / R10 values into measured ones.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-028](T-028-release-log-safety-gate-extension.md) | Release log-safety gate extension (AM-5) | M | T-003, T-019, T-027 | HIGH |
| [T-029](T-029-security-evidence-suite.md) | Security evidence suite (AM-10) | L | T-003, T-012, T-014, T-017, T-018, T-019, T-026, T-027, T-028 | HIGH |
| [T-030](T-030-device-validation-protocol.md) | Device validation protocol (OD1, OD2, OD5, R10) | M | T-028, T-029 | HIGH |

## Group effort estimate

- Optimistic (strictly sequential — T-029 builds on T-028 and T-030 on both): 4–5 days
- Realistic (2 devs): 5–6 days
