# T-004: ObservabilityBus + LogSanitiser

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../index.md)
- **Component:** ObservabilityBus, LogSanitiser
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on:** [T-001](T-001-repository-cicd-scaffolding.md)
- **Blocks:** T-005 through T-032 (all tasks emit observability events)
- **Requirements:** NFR-015, NFR-016

## Description

Implement `ObservabilityBus` protocol and `LogSanitiser` wrapper as described in L2 §2.3. The sanitiser must strip PII patterns before any event is written. Implement for both iOS and Android — shared logic is extractable to a shared module.

## Acceptance criteria

```gherkin
Feature: ObservabilityBus and LogSanitiser

  Scenario: ObservabilityEvent struct matches L2 schema
    Given the ObservabilityEvent struct/data class is defined
    When its fields are compared to L2 §2.3 schema
    Then every field matches exactly with correct types

  Scenario: LogSanitiser wraps ObservabilityBus at emission
    Given ObservabilityBus is configured with LogSanitiser
    When any component emits an event
    Then the event passes through LogSanitiser before being written
    And no component can bypass the sanitiser

  Scenario: Health values are redacted before emission
    Given an event contains a mock health value such as "98.6"
    When the event is emitted via ObservabilityBus
    Then the health value is redacted in the written event

  Scenario: Contact names are redacted before emission
    Given an event contains a mock contact name
    When the event is emitted via ObservabilityBus
    Then the contact name is redacted in the written event

  Scenario: Non-PII fields pass through unchanged
    Given an event contains component name, eventType, durationMs, outcome, and errorCode
    When the event is emitted via ObservabilityBus
    Then all non-PII fields are present and unchanged in the written event

  Scenario: Sanitisation rules are enumerated in a testable allowlist
    Given the LogSanitiser implementation
    When the sanitisation rules are inspected
    Then all rules are defined in a unit-testable allowlist
    And no ad-hoc per-component regex is used
```

## Implementation notes

- Both iOS and Android implementations required; shared logic may be extracted to a shared module.
- Sanitisation allowlist must be tested exhaustively in unit test suite.
- LogSanitiser must be the single wrap point — no component bypasses it.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Sanitisation allowlist tested exhaustively (unit tests for both platforms)
- [ ] No PII in logs — verified by automated test
