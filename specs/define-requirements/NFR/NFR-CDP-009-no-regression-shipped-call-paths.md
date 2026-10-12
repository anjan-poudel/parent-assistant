# NFR-CDP-009: No regression to the shipped voice pipeline, emergency and dial-back paths

## Metadata
- **Category:** Reliability (Regression)
- **Priority:** MUST
- **Source:** Frozen design Risks ("Regression on just-shipped call paths (PRs #161–#168): the chain replaces only the single Messenger hard-rule and the hardcoded voice default; the resolver is pure-static and closure-injected; scoped tests pin the matrix") and non-goals ("No changes to the just-shipped voice pipeline beyond the named MethodResolver seam"); feature constitution Feature Constraint 7 ("The regression risk is to the just-shipped voice pipeline, emergency-contact and dial-back paths (PRs #161–#168) — do not refactor beyond the named seams"); workflow `security-design-review`/`security-test` focus (emergency precedence; dial-back).

## Description
The feature **must** leave every behaviour it does not explicitly re-specify identical to the pre-feature build, and its change surface **must** stay limited to the named seams. Measurable properties:

- **Change surface**: the touched production files are the named seams only — `resolvedCallChannel`, `resolvedMissedCallChannel`/`missedCallDialAction`, MethodResolver's global-default step, `requestCallConfirmation`'s gating/prompt composition, the new pure-static resolver, `CallingSettingsView`, `AppCoordinator`'s new preference, and the string catalog: **0 refactors beyond**.
- **Emergency path**: emergency-contact resolution outputs are **identical to pre-feature** for its pinned matrix (0 diffs in its suite); nothing on the emergency path consults the chain.
- **Dial-back path**: dial-back identity resolution and the honest lines (numberless row → Phone app; non-dialable number → spoken line) are unchanged (0 diffs in their pinned cases).
- **Voice pipeline (#161–#168)**: the override protocol, near-miss disclosure and multi-turn confirmation mechanics behave identically; their suites show **0 new failures** versus the recorded pre-feature baseline.
- **Scoped-suite evidence**: the touched suites run green against the baseline; deviations are reworked, not waived.

## Acceptance criteria

```gherkin
Feature: No regression outside the re-specified behaviour

  Scenario: Emergency behaviour is bit-identical
    Given the emergency-contact resolution matrix
    When it is exercised against the feature build and compared with the pre-feature baseline
    Then zero output differences exist
    And the emergency path performs no chain resolution

  Scenario: Dial-back and voice-pipeline suites stay green
    Given the recorded pre-feature baselines for the dial-back, override, near-miss and multi-turn confirmation suites
    When the feature build runs the same suites
    Then zero new failures exist
    And the honest dial-back lines behave exactly as before

  Scenario: The change surface stays within the named seams
    Given the feature's build diff
    Then it touches only the named seams, the new resolver, the settings view and the catalog
    And no CallRouter service or per-contact preference storage is introduced
```

## Related
- FR: FR-CDP-011 (dial-back), FR-CDP-014 (override/near-miss), FR-CDP-018 (preserved behaviours)
- NFR: NFR-CDP-008 (scoped suites and baseline discipline), NFR-CDP-010 (gates)
