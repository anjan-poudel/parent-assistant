# FR-LCT-017: "Always show original text" toggle

## Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §1, §4.5, §10 Open Decision 2; feature constitution binding rule 6 (the toggle ships with the D1 divergence)

## Description
The system **must** provide an "always show original text" setting that reduces the overlay to
**pure callout mode**: when enabled, no in-place replacement is drawn and every translated region
uses an anchored callout (FR-LCT-016). The setting ships alongside the D1 in-place rule, is
reachable by touch and by voice (FR-LCT-022), persists across sessions, and takes effect on the
next rendered frame without restarting the feature.

The default value of this setting is confirmed at the first device demo (design §10 Open Decision
2); the requirement binds its existence, reachability and effect, not the default.

## Acceptance criteria

```gherkin
Feature: Always-show-original toggle

  Scenario: Enabling the toggle removes in-place replacement
    Given a short dictionary-known label that would otherwise be drawn in place
    When the elder enables "always show original text"
    Then the original printed text is no longer covered by the overlay
    And an anchored callout carries the translation

  Scenario: The setting persists
    Given the elder enabled "always show original text"
    When the elder closes and reopens live translation
    Then the setting is still enabled
```

## Related
- FR: FR-LCT-015 (in-place rule), FR-LCT-016 (callouts), FR-LCT-022 (voice control)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-015
