# FR-LCT-013: Cost governor bound and fail-closed behaviour

## Metadata
- **Area:** Cost Governance
- **Priority:** MUST
- **Source:** Design §4.4 (tier 2), §5, §8; feature constitution binding rule 7; project constitution Open Decision 13 ("bounded per-session by the existing GeminiCostGovernor")

## Description
Tier-2 activity **must** be bounded by the existing cost governor (`GeminiCostGovernor`), through
which every cloud call in this app already passes. When the governor refuses a call:

- the tier **must fail closed**: no request is issued and the affected regions show the original
  text with the honest unavailable/offline indication;
- after the cap is reached, the failure applies **for the rest of the session** — the system
  **must not** enter a silent retry loop or fall back to a different unmetered request shape;
- the refusal **must not** degrade any other feature or leave the elder without the camera view.

**Known inconsistency to be resolved by design (recorded open decision):** the shipped
`GeminiCostGovernor` counts calls **per day** with a family-editable cap, while design §4.4
describes a "per-session" cap. The requirement binds the *behaviour* (bounded calls, fail closed,
no retry loop); whether v1 adds a per-session sub-cap inside the per-day governor or relies on the
per-day cap is for `design-component` to decide and record. Either way the cap value must be a
configurable parameter, not a hardcoded constant.

## Acceptance criteria

```gherkin
Feature: Cost governor fails closed

  Scenario: The cap is reached mid-session
    Given the cost governor reports no budget remaining
    When an unresolved string would otherwise be sent to the cloud tier
    Then no request is issued
    And the affected regions show the original text with an honest unavailable indication
    And the camera view and dictionary translations keep working

  Scenario: No silent retry loop after the cap
    Given the cap has been reached
    When the scene changes and new unresolved strings appear
    Then no cloud request is issued for the rest of the session
    And no repeated retry attempts are made for the same key

  Scenario: Attempts refused by the governor are not counted as translations
    Given a cloud request is refused by the cost governor
    When the region's result is reported
    Then the result reports degraded (no tier produced a translation)
```

## Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-023 (degradation)
- NFR: NFR-LCT-010 (offline degradation integrity), NFR-LCT-011 (configurable parameters)
- Depends on: FR-LCT-009
