# FR-LCT-011: Visible cloud-activity indicator

## Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 2; project constitution Open Decision 12 (indicator precedent) and Open Decision 13; design §4.6

## Description
While the cloud tier is active — that is, from the moment a tier-2 request is issued until its
result (or failure) has been applied — the system **must** show a visible indicator in the live
translation view that text is being translated by the cloud service.

- The indicator's state **must** be driven by actual tier-2 activity, not by settings or by a
  static decoration: it appears only when a request is in flight and disappears when the tier is
  idle.
- The indicator **must not** be spoofable or suppressible by any state that does not reflect
  cloud activity (e.g. it must not be hidden by the "always show original text" toggle, by a
  dictionary-only session, or by an overlay mode).
- The indicator must be understandable to the elder: a symbol plus a plain-language label in the
  active language, not an icon alone (pending final consent/disclosure copy review — design §10
  Open Decision 3).

## Acceptance criteria

```gherkin
Feature: Cloud-activity indicator

  Scenario: Indicator appears while a cloud request is in flight
    Given consent is recorded
    When a tier-2 request is issued
    Then a visible indicator states that text is being translated by the cloud service
    And the indicator remains visible until the request resolves or fails

  Scenario: Indicator is absent when the cloud tier is idle
    Given no tier-2 request is in flight
    When the elder uses live translation offline with the dictionary
    Then no cloud-activity indicator is shown

  Scenario: Indicator cannot be suppressed while the cloud tier is active
    Given a tier-2 request is in flight
    When the overlay mode is changed (for example the always-show-original toggle)
    Then the cloud-activity indicator remains visible
```

## Related
- FR: FR-LCT-010 (consent gate), FR-LCT-013 (cost governor)
- NFR: NFR-LCT-007 (consent enforcement and auditability)
- Depends on: FR-LCT-009 (tier 2)
