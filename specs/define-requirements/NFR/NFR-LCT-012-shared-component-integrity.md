# NFR-LCT-012: Shared-component integrity — no regression to the appliance helper

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Agent Principles" (no agent may weaken `ApplianceOverlayMapper` or `ApplianceLabelLocalizer`); design §3

## Description
This feature extends components that the shipped appliance helper already depends on. It **must
not** change their contracts or behaviour:

- `ApplianceLabelLocalizer` — extended data set only; its exact-match rules, `Display(primary:
  secondary:)` shape and locale gating remain intact. No fuzzy matching is introduced.
- `ApplianceOverlayMapper` — reused unchanged for OCR normalized box → screen point conversion;
  its function contract is not modified.
- `GeminiClient` — the new text-only translation method goes through the existing `send(_:)`
  chokepoint (auth, timeout, observability, cost governor); no parallel request path is added.
- The appliance helper's existing behaviour and tests stay green; the shared cache addition must
  not change its observable outputs.

## Acceptance criteria

```gherkin
Feature: No regression to the shipped appliance helper

  Scenario: The appliance helper's existing tests still pass
    Given the feature's changes are in the build
    When the appliance helper's existing unit tests run under `ios/build.sh`
    Then they pass unchanged

  Scenario: The shared components' contracts are unchanged
    Given `ApplianceOverlayMapper` and `ApplianceLabelLocalizer` as used by the appliance helper
    When the feature's changes are inspected
    Then their existing public functions and behaviour are unchanged
    And the feature's additions are extensions (new entries, new callers), not modifications

  Scenario: One request chokepoint
    Given the new translation request path
    When outbound requests are traced
    Then they pass through the existing `GeminiClient.send(_:)` chokepoint
    And no alternate request construction bypasses it
```

## Related
- FR: FR-LCT-007, FR-LCT-020, FR-LCT-009
- NFR: NFR-LCT-005 (privacy)
