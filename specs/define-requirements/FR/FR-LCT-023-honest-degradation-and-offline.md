# FR-LCT-023: Honest degradation — never silently report success

## Metadata
- **Area:** Error Handling
- **Priority:** MUST
- **Source:** Design §4.2, §8 (error handling table), §4.4 (`degraded`); feature constitution binding rule 7

## Description
Every degradation path **must** be visible and honest. No path may report success without a
translation, retry-loop, or leave the elder without the information that the text on screen is
not translated:

| Condition | Required behaviour |
|---|---|
| No text in frame | Empty-state hint in the active language; no error surfaced |
| No network / no consent / no budget | Original text plus an "offline"/unavailable indication; the dictionary and cache keep working |
| Transient provider error | At most one retry, then the offline indication |
| Provider policy block | No retry; the offline indication |
| Camera denied | Explanatory screen plus Settings link (FR-LCT-002) |
| Camera session interrupted | Pause and resume; cached overlays persist |
| Speech failure | The visual translation remains; no retry loop |
| App killed while the view is open | Nothing is half-written; the cache is consistent on relaunch |

Timeouts and retry counts are configurable parameters, not hardcoded constants. Deferred or
absent capability is never faked: see FR-LCT-008.

## Acceptance criteria

```gherkin
Feature: Honest degradation

  Scenario: Offline with no dictionary hit
    Given the device is offline and a recognized string is not in the dictionary or cache
    When the translation tiers resolve
    Then the original text is shown with an offline indication
    And the feature does not block or crash
    And the result reports degraded rather than success

  Scenario: Nothing is silently dropped when a tier fails
    Given a region was sent to the cloud tier and the request failed
    When the overlay is rendered
    Then that region still shows its original text with an honest indication
    And no region with a failure is removed without explanation

  Scenario: Recovery when connectivity returns
    Given the app showed offline indications for unresolved regions
    When connectivity returns and the scene is still visible
    Then the unresolved regions are retried once under the normal consent and cost rules
    And their overlays update to the translation when it arrives
```

## Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-013 (governor), FR-LCT-018 (overlay states)
- NFR: NFR-LCT-010 (offline degradation integrity), NFR-LCT-011 (configurable parameters)
- Depends on: FR-LCT-003, FR-LCT-009
