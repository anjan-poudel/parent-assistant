# FR-LCT-009: Tier 2 text-only cloud translation

## Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Design §2, §4.4 (tier 2), §7; project constitution Open Decision 13 (recorded 2026-09-16)

## Description
Strings the dictionary cannot resolve **may** be translated by the cloud tier (tier 2) through
the existing `GeminiClient` request chokepoint, subject to FR-LCT-010 (consent), FR-LCT-013 (cost
governor) and FR-LCT-014 (text-only egress).

- The request is **text-only**: the unresolved strings plus the target language and the detected
  source language per string. No image, no `inlineData` part, no photo, ever.
- Unresolved strings from one scene **must** be sent as **one batched request** where the batch
  size permits, not one request per string.
- **In-flight deduplication is mandatory**: while a key is pending, no second request may be
  fired for it.
- A transient provider error is retried at most once; a provider block/policy error is not
  retried. Timeouts are configurable parameters, not hardcoded constants.
- The tier **must** fail honestly on any failure (FR-LCT-008, FR-LCT-023); it must never silently
  drop a string or report success without a translation.

## Acceptance criteria

```gherkin
Feature: Tier 2 cloud translation

  Scenario: Unresolved strings from one scene are batched into a single call
    Given consent is recorded and the dictionary cannot resolve 8 recognized strings
    When the cloud tier resolves them
    Then exactly one request is sent carrying all 8 strings
    And the request carries text only

  Scenario: A pending key does not fire a duplicate request
    Given a string is already in flight to the cloud tier
    When the same string is observed again before the reply arrives
    Then no second request is sent for that string

  Scenario: Transient failure is retried once then reported honestly
    Given the cloud tier returns a transient error
    When the retry also fails
    Then the region is reported as degraded (original text plus an offline indication)
    And no further retries are attempted for that region

  Scenario: Provider policy block
    Given the cloud tier refuses the request under its policy
    When the response is received
    Then no retry is attempted
    And the region is reported as degraded
```

## Related
- FR: FR-LCT-010 (consent), FR-LCT-013 (cost governor), FR-LCT-014 (text-only egress), FR-LCT-018 (overlay states)
- NFR: NFR-LCT-009 (untrusted text hardening), NFR-LCT-001 (latency)
- Depends on: FR-LCT-003 (OCR), FR-LCT-007 (tier 0)
