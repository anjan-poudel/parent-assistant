# TG-23: Release Gates, Security Evidence and Device Validation

> **Jira Epic:** Release Gates, Security Evidence and Device Validation

## Description
Closes the feature: the release log-safety gate extension (C-SP-13, FEATURE_ROOTS additions), the golden-corpus supersession mechanics with the pinned-surface guard (C-3), the security evidence bundle covering all nine obligations from the security design review, and the DV-1..DV-7 device-validation protocol with its recorded result (C-SP-16, FR-SP-017).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-121](T-121-release-log-safety-gate.md) | Release log-safety gate FEATURE_ROOTS extension | S | T-107, T-110, T-118 | HIGH |
| [T-122](T-122-golden-corpus-supersession.md) | Golden-corpus supersession mechanics and pinned-surface guard (C-3) | M | T-116 | HIGH |
| [T-123](T-123-security-evidence-bundle.md) | Security evidence bundle (nine obligations) | M | T-120, T-121, T-122 | HIGH |
| [T-124](T-124-device-validation-protocol.md) | DV-1..DV-7 device-validation protocol and record (FR-SP-017) | L | T-119, T-120, T-121 | HIGH |

## Group effort estimate
- Optimistic (full parallel): 6–8 days
- Realistic (2 devs): 9 days
- Owner/device-dependent: T-124 requires the owner's device and the OD-S2 Dashboard registration; it cannot be compressed by parallelism.

## Owner dependencies (not agent work)
- OD-S2 Dashboard registration: owning account, client-ID paste-in, redirect-scheme acceptance (V-2), test-user registration, quota-extension filing, rollout-note approval.
- DV completion gate: the constitution requires the DV record before the feature is called done; T-124 is owner/device-dependent.
