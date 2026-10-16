# T-016: `CloudActivityIndicatorModel`

## Metadata
- **Group:** [TG-05 — Consent, Disclosure and the Cloud Indicator](index.md)
- **Component:** C10 — `CloudActivityIndicatorModel`
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md)
- **Blocks:** T-019, T-021
- **Requirements:** FR-LCT-011, NFR-LCT-007

## Description

Tell the elder when recognized text is leaving the device: an observable whose **only input is the
tier's in-flight request counter**, so it cannot disagree with reality. It appears when the counter
goes from zero to one and disappears when it returns to zero, is settable from nowhere else, and has no
dwell timer — a lingering indicator would be a false statement about cloud activity.

Source: `Services/LiveTranslate/` `CloudActivityIndicatorModel.swift` under `ios/ElderlyAssistant/`.
Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Truthful cloud activity indication

  Scenario: The indicator follows the in-flight counter exactly
    Given the tier's in-flight request counter
    When a request begins and later completes
    Then the indicator appears on the transition from zero and disappears on the return to zero
    And it is driven by the tier's released registry, so the two cannot disagree

  Scenario: Nothing else can turn the indicator on
    Given the settings layer, the overlay layer and the dictionary-only path
    When each attempts to influence the indicator
    Then none of them can set it
    And the always-show-original toggle cannot hide or show it (FR-LCT-011 scenario 3)

  Scenario: A very fast response flickers honestly
    Given a translation that resolves in a fraction of the sampling interval
    When it completes
    Then the indicator is on for exactly that interval and then off
    And no minimum-dwell timer is applied, because a lingering indicator would misstate activity

  Scenario: Failures and cancellations still return it to off
    Given a send that fails, times out, is cancelled or is ended by a gate decision
    When the attempt terminates
    Then the indicator returns to off through the same release path
    And the failure does not leave it latched on

  Scenario: The indicator renders as a symbol plus a label
    Given the indicator is visible
    When it is inspected
    Then it shows a symbol and a plain-language label in the active language
    And the label is a catalog key, not a literal (NFR-LCT-004)

  Scenario: Transitions are recorded without content
    Given the indicator turning on and off
    When the events are emitted
    Then the transitions are recorded with no text, no prompt and no identifiers (NFR-LCT-007)
```

## Implementation notes

- A `@MainActor` observable whose single input is the tier's in-flight counter (T-019); the count is
  maintained by the tier's `defer`-released registry, so every exit path — success, failure, timeout,
  cancellation, consent denial — releases without a dedicated code path.
- **No dwell timer and no debounce.** The design forbids a minimum-dwell timer explicitly: flicker on a
  very fast response is the honest display of a very fast response. Do not add one.
- Do not give it a configuration parameter: it has no tunable behaviour, and adding one would invite
  the dwell timer back.
- The label is a catalog key (T-005) in the active language; the wording's final form belongs to the
  OD3 copy review, but it must be a symbol **plus** label, never an icon alone.
- Emit `cloud_indicator_shown` / `cloud_indicator_hidden` with no metadata (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the indicator is off when a gate decision denies and when the cache serves the string
- [ ] A test asserts it returns to off on failure, timeout and cancellation
- [ ] A test asserts no other layer can set it and the toggle cannot hide it
- [ ] No content in any indicator event, asserted by test
- [ ] `ios/build.sh` passes
