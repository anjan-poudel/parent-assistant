# T-123: Security evidence bundle (nine obligations)

## Metadata
- **Group:** [TG-23 — Release Gates, Security Evidence and Device Validation](index.md)
- **Component:** C-SP-16 evidence artifact (security design review obligations 1 to 9)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-120](../TG-22-plugin-wiring-settings-and-localisation/T-120-settings-surface.md), [T-121](T-121-release-log-safety-gate.md), [T-122](T-122-golden-corpus-supersession.md)
- **Blocks:** [T-124](T-124-device-validation-protocol.md)
- **Requirements:** [NFR-SP-002](../../../../define-requirements/NFR/NFR-SP-002-log-safety.md), [NFR-SP-007](../../../../define-requirements/NFR/NFR-SP-007-credential-encryption-at-rest.md), [NFR-SP-008](../../../../define-requirements/NFR/NFR-SP-008-deeplink-uri-hardening.md), [NFR-SP-009](../../../../define-requirements/NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md), [NFR-SP-011](../../../../define-requirements/NFR/NFR-SP-011-compliance-and-release-gates.md)

## Description
Assembles the security evidence bundle the security design review demands: nine obligations, each with its producer task, its artifact or command, and its recorded output. The bundle is what a reviewer reads instead of trusting prose — every claim in the security review maps to one entry here.

## The nine obligations and their producers
1. Artifact secret scan: repository and built app image contain no client secret (PKCE-only proof) — producer: build artifacts + scan output.
2. Keychain placement and post-wipe sweep — producer: T-108 test results.
3. Callback reject matrix results — producer: T-109.
4. Refresh and revocation bounds, including the V-1 stance verification record — producer: T-110.
5. Hostile corpus results — producer: T-107.
6. Log-surface checks, including the DV-7 console and sysdiagnose capture — producers: T-121 and T-124.
7. Disclosure copy versus actual data flow — producer: T-117 copy plus T-120 surface, checked against the implemented flow.
8. Scope equality: requested set equals pinned set equals Dashboard-registered set — producer: T-109 pin; the Dashboard-registered column depends on the owner's OD-S2 registration (marked, may be recorded as pending until then).
9. Egress allowlist: the turn's URL set equals the two provider hosts — producer: T-116 pin test.

## Acceptance criteria

```gherkin
Feature: Security evidence bundle

  Scenario: Every obligation has a complete, reproducible entry
    Given the producers have run
    When the bundle is assembled
    Then all nine obligations carry a producer reference, an artifact or command, and recorded output
    And none is marked passed from prose alone

  Scenario: An incomplete or stale obligation fails the bundle
    Given one obligation whose producer result is missing or predates the final build
    When the bundle is validated
    Then the bundle is marked incomplete and names the obligation
    And the scope-equality entry is allowed to be pending only with the OD-S2 dependency recorded

  Scenario: The secret scan covers repo and app image
    Given the final build artifacts
    When the secret scan runs
    Then the repository scan reports zero findings
    And the app-image scan reports zero findings or is recorded as pending device-build with the dependency named
```

## Implementation notes
- The bundle records environment, build identity and command output per obligation; reproduce commands verbatim so a reviewer can rerun them.
- Obligation 8's Dashboard column is an owner input (OD-S2); record it as pending with the dependency named — never mark it passed on the agent's word.
- Obligation 6's device half is produced by T-124 (DV-7); the bundle references it and stays incomplete until it lands.
- Bundle location and naming follow the design's evidence plan and the shipped device-validation-artifact precedent; no secrets, tokens or query text are copied into the bundle itself (NFR-SP-002 applies to evidence files too).
- Keep the bundle machine-checkable where possible (command plus exit code), so completeness is a check, not a review opinion.

## Definition of done
- [ ] All nine obligations present with producer, artifact/command, and output
- [ ] Reproduce commands included and runnable by the reviewer
- [ ] Scope-equality Dashboard column either confirmed or explicitly pending with OD-S2 named
- [ ] No PII in logs — no secrets, tokens or query text inside the bundle
- [ ] Bundle validated by the completeness check
