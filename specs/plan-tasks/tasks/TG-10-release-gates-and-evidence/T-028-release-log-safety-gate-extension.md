# T-028: Release Log-Safety Gate Extension

## Metadata
- **Group:** [TG-10 — Release Gates and Evidence](index.md)
- **Component:** the build-blocking release log-safety gate (`ios/tools/` scripts)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md), [T-019](../TG-06-cloud-translation-tier/T-019-cloud-translation-tier.md), [T-027](T-027-plugin-entry-and-session-view.md)
- **Blocks:** T-029, T-030
- **Requirements:** NFR-LCT-006, NFR-LCT-007, NFR-LCT-012, NFR-LCT-013 · **AM-5** · **SD-5, SD-6**

## Description

Extend the project's build-blocking release log-safety gate to cover this feature's rule family over
its new scan roots, so a Release build fails if the feature logs content, bypasses the sanitiser, or
emits a key outside the allow-list. This is the mechanical arm of the content-free-logs invariant: the
gate runs in Release and blocks the build rather than warning.

Sources: `ios/tools/` `check-release-log-safety.sh` and its Python checker, and the new scan roots
under `Services/LiveTranslate/` and the Gemini client's translation file. No product Swift changes
beyond what the new rules require.

## Acceptance criteria

```gherkin
Feature: Release log safety gate covers the feature

  Scenario: A Release build fails when the feature logs content
    Given a Release build in which a feature source emits recognized or translated text through the log bus
    When the gate runs
    Then the build fails and names the offending source and the rule (AM-5, SD-5)
    And the failure is not downgraded to a warning

  Scenario: The new roots are covered and the gate exits clean on the final sources
    Given the feature's sources
    When the gate runs in Release configuration over the new roots
    Then it exits with success
    And the gate remains part of the standard build path, not an optional extra

  Scenario: The rule family covers the feature's real failure modes
    Given the gate's rule set
    When the feature's sources are scanned
    Then the rules cover direct logging, bypassing the sanitiser, unlisted metadata keys, and interpolating a text value into an event
    And every rule has a positive and a negative fixture proving it fires and stays quiet (AM-5, SD-6)

  Scenario: The gate does not create false confidence
    Given a source that evades the rules by construction
    When the rule set is reviewed
    Then the evasion is documented as a known limitation of the gate (AM-5)
    And the runtime allow-list tests from T-003 remain the primary safeguard

  Scenario: Existing rules and their fixtures still pass
    Given the gate's pre-existing rules
    When the extension lands
    Then every existing fixture behaves as before (NFR-LCT-012)
```

## Implementation notes

- The gate already exists and is wired into the project's build script; this is a rule-family extension
  plus fixtures over new roots, not a new gate. Match its existing structure for rules, fixtures and
  exit codes.
- Rules are written against the project's logging idioms and the feature's typed emitters (T-003): the
  strongest rule makes an undeclared key or an interpolated text value a build failure.
- Fixtures live beside the gate's existing fixtures: one positive (must fail) and one negative (must
  pass) per new rule. A rule without a positive fixture is not a rule.
- Document the known limitation honestly in the gate's own documentation: static rules cannot see
  through every indirection, which is why the runtime allow-list tests (T-003) remain required.
  Over-claiming the gate's coverage would undermine the evidence at `security-test`.
- Do not weaken or reorder existing rules to make the new ones fit.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Each new rule has a positive and a negative fixture, with the existing fixture suite passing unmodified
- [ ] The gate runs in the standard Release path, covers the new roots, and blocks the build on violation
- [ ] The gate's documented limitations are updated with the evasion case (AM-5)
- [ ] `ios/build.sh` passes
