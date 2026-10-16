# FR-PI-011: Un-personalized path behaves exactly as today

## Metadata
- **Area:** No-Regression
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (final bullet: until a term is recorded — step skipped, existing user not yet re-interviewed, including any fallback path — the assistant behaves exactly as today; no neutral placeholder is invented); workflow non-goals comment

## Description
Until an address-as term is recorded — because the step was skipped, because an existing user has not yet been re-interviewed, or because of any profile read failure — the assistant **must** behave exactly as today:

- wake detection starts listening with no spoken greeting, exactly as the pre-feature baseline (FR-PI-008);
- prompts and replies contain no term and no substitute: no "default name", no placeholder, no neutral invented form of address (FR-PI-009);
- no other behaviour changes.

The feature adds personalization; it **must not** regress the un-personalized path, and there is no state in which an invented term is spoken or composed into a prompt.

## Acceptance criteria

```gherkin
Feature: Un-personalized path behaves exactly as today

  Scenario: Fresh install without a recorded term
    Given a fresh installation with no address-as term recorded
    When the wake word is detected and replies are generated
    Then behaviour is identical to the pre-feature baseline
    And no placeholder term is spoken or composed into any prompt

  Scenario: Existing user not yet re-interviewed
    Given an installation that completed onboarding before this feature
    And the user has not completed the new steps
    When the assistant runs
    Then the same today-behaviour holds, with no term and no placeholder
```

## Related
- FR: FR-PI-008 (wake ack), FR-PI-009 (reply style), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: —
