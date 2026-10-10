# FR-SP-011: Free-tier degradation to the spotify: deep-link fallback

## Metadata
- **Area:** Degradation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 ("Premium reality is an NFR — degradation must be honest… free-tier or unlinked-account remote control must degrade to the `spotify:` deep-link fallback with clear messaging, never a silent failure") and "Music Request Routing & Degradation Contract" (degradation bullets); DV-4; OD-S3 (exact precedence and copy — open)

## Description
Playback control requires a Spotify Premium account. When a music request reaches a linked Spotify account that cannot be remote-controlled — free tier, or any account state where remote control is unavailable — the system **must** degrade to the `spotify:` deep-link fallback with clear messaging:

- a validated `spotify:` deep link (FR-SP-007) is opened for the resolved request (e.g. the track, or `spotify:search:<encoded query>`);
- the user hears an explicit localized line that says what actually happened, never a claim that remote playback was started. Illustrative copy (exact copy for the degradation paths is OD-S3): "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।" / "Opening Spotify — play it there.";
- the honest free-tier line **must not** be skipped in favour of pretending control succeeded, and the deep link **must not** be suppressed silently;
- if the `spotify:` scheme cannot be opened (app absent — Feature Constraint 8), the outcome follows the honest-app-absent rule (FR-SP-012), never a fabricated success.

The precedence between this free-tier deep-link path and the YouTube fallback (FR-SP-004), per account/service state, and the exact copy for each path, is OD-S3. Both rules bind; OD-S3 resolves composition. Whether a Premium account is detected ahead of the request or by the provider response is a design decision constrained only by this honesty rule.

## Acceptance criteria

```gherkin
Feature: Free-tier degradation to the spotify: deep-link fallback

  Scenario: A free-tier linked account degrades to the deep link with clear messaging
    Given a Spotify account is linked on the free tier
    When the user says "भजन बजाऊ" and Spotify cannot remote-control playback
    Then a validated spotify: deep link is opened for the request
    And the user hears an explicit localized line saying Spotify was opened
    And the line does not claim remote playback was started

  Scenario: The deep link cannot be opened — honest outcome, no pretense
    Given the free-tier degradation path is chosen
    And the spotify: scheme cannot be opened on the device
    Then the user hears the honest app-absent line (FR-SP-012)
    And no playback success is claimed

  Scenario: A controllable Premium account does not take this path
    Given a Premium linked account capable of remote control
    When the user says "गीत चलाऊ"
    Then playback control is attempted normally
    And the free-tier deep-link messaging is not used
```

## Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-007 (deep-link construction), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)
