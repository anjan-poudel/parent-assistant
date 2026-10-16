# TG-05: Consent Gate, Prompt, Revocation and Cloud-Activity Indicator

> **Jira Epic:** Consent Gate, Prompt, Revocation and Cloud-Activity Indicator

## Description

Implements the feature's compliance basis: one version-stamped consent record read at the point of
use and fail-closed on every non-granted state (C09), with revocation that takes effect in memory
before storage (AM-4); the prompt shown at the first cloud need with no timeout; and the
cloud-activity indicator whose only input is the tier's in-flight counter (C10).

This group is what `security-test` reads first: the positive case (consent recorded, one request
observed) and the negative case (no consent, zero requests on every path including the retry).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-014](T-014-consent-gate.md) | `LiveTranslateConsentGate` (C09, AM-4) | L | T-001, T-002, T-003 | CRITICAL |
| [T-015](T-015-consent-prompt-and-revocation.md) | Consent prompt and revocation surfaces | M | T-005, T-014 | CRITICAL |
| [T-016](T-016-cloud-activity-indicator.md) | `CloudActivityIndicatorModel` (C10) | S | T-001, T-003 | MEDIUM |

## Group effort estimate

- Optimistic (T-016 and T-014 in parallel, T-015 after): 3 days
- Realistic (2 devs): 4–5 days
