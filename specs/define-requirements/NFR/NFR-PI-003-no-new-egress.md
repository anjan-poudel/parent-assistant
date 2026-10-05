# NFR-PI-003: No new network egress or cloud processing

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (any new cloud processing — no new network egress) and Feature Constraint 5; project constitution Architecture Constraint 1 (all AI inference on-device; recorded exceptions Open Decisions 12 and 13 are untouched)

## Description
The feature **must** add zero new network calls, endpoints, request shapes or data flows.

Measurable properties:

- **Zero network requests attributable to the feature** across the full journey: interview, wizard close, wake acknowledgment, reply generation, Settings edit — the whole feature works fully offline (on-device engines).
- All new stored fields stay on-device. Only the **name** and **address-as term** may be composed into the existing reply prompt paths, alongside the content those paths already carry.
- **Zero occurrences** of date of birth, GP, hospital, next-of-kin, family-member or biometric values in any prompt or outbound payload.
- On a reply path that uses the existing consent-gated cloud engine, the term is carried only inside that engine's existing flow, under its existing consent status and recorded exception — no new egress category and no new disclosure obligation are created.

## Acceptance criteria

```gherkin
Feature: No new network egress or cloud processing

  Scenario: The full journey works with no network
    Given the device is offline
    When the interview is completed, the wizard closes, the wake word fires, and on-device replies run
    Then every step of the journey works
    And zero network requests are attempted by the feature

  Scenario: Only name and term may enter prompts
    Given a profile with all fields filled
    When prompt payloads for both reply engines are inspected
    Then the name and/or address-as appear only where the reply-style rules use them
    And date of birth, GP, hospital, next-of-kin, family and biometric values appear in no prompt or outbound payload

  Scenario: No new endpoint or request shape is introduced
    Given the feature's outbound code paths
    When request construction is inspected
    Then no new endpoint or request shape exists beyond the existing engine paths
```

## Related
- FR: FR-PI-003, FR-PI-009
- NFR: NFR-PI-004 (injection hardening), NFR-PI-011 (compliance gates)
