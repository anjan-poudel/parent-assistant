# FR-LCT-008: Truthful tier attribution and no success without translation

## Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Feature constitution "v1 non-goals" (deferred work must be absent, not a silent stub); Design §4.4, §11 (D2)

## Description
Every translated string **must** carry the tier that actually produced it
(`TranslationResult.sourceTier`), and a tier **must not** return success when it did not translate.

- In v1 the only tiers that may produce a translation are **tier 0 (dictionary)** and
  **tier 2 (cloud, consent-gated)**.
- The **on-device NMT tier (tier 1) must be absent from v1** — not a stub, not a passthrough, not
  a "translate later" placeholder that reports success. No resolution path may attribute a result
  to tier 1. It is a v1.1 candidate and may not land until addendum §13.5's non-goal is revisited
  (design §11 D2).
- When no tier produced a translation, the result **must** report the failure honestly:
  `isFinal = true`, `degraded = true`, and the text shown is the original recognized text — never a
  fabricated or unmarked string.

## Acceptance criteria

```gherkin
Feature: Truthful tier attribution

  Scenario: A dictionary hit is attributed to tier 0
    Given a recognized label matches the curated dictionary
    When the translation resolves
    Then sourceTier reports dictionary
    And isFinal is true and degraded is false

  Scenario: A cloud translation is attributed to tier 2
    Given a recognized string is unresolved by the dictionary and consent is recorded
    When the cloud tier returns a translation
    Then sourceTier reports cloud
    And degraded is false

  Scenario: No tier can translate
    Given the dictionary cannot resolve the string and the cloud tier is unavailable
    When the resolution completes
    Then sourceTier does not claim a tier that did not translate
    And degraded is true
    And the text shown is the original recognized text

  Scenario: The deferred on-device NMT tier cannot produce a v1 result
    Given the v1 build
    When any translation path is exercised
    Then no result is attributed to an on-device NMT tier
    And no on-device NMT code path exists that returns a translated string
```

## Related
- NFR: NFR-LCT-010 (offline degradation integrity)
- Depends on: FR-LCT-007 (tier 0), FR-LCT-009 (tier 2)
