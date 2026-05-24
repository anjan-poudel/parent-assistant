# T-020: InputSanitiser + ContextWindowManager

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** InputSanitiser, ContextWindowManager
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-018](T-018-llama-inference-engine/index.md)
- **Blocks:** [T-021](T-021-intent-classifier-entity-extractor.md)
- **Requirements:** NFR-013 (prompt injection)

## Description

Implement `InputSanitiser` (quarantine and standard levels) and `ContextWindowManager` from L2 §4.1. Sanitisation blocklist covers model template tokens, known adversarial patterns, system prompt overrides, and role-marker tokens. Max input 2000 chars. Context window budget enforced per L2 §4.1. All external inputs must reach the LLM only after sanitisation.

## Acceptance criteria

```gherkin
Feature: InputSanitiser and ContextWindowManager

  Scenario: Quarantine level blocks all INST and role-marker tokens
    Given InputSanitiser is configured at quarantine level
    When input containing INST tokens, system/user/assistant role markers,
     and role-override patterns is sanitised
    Then all such tokens are blocked or stripped from the output

  Scenario: 50 adversarial inputs are all rejected at quarantine level
    Given the OWASP LLM prompt injection test fixture (50 patterns)
    When each pattern is passed through sanitise(.quarantine)
    Then all 50 patterns are rejected or rendered harmless

  Scenario: Standard level strips control characters
    Given InputSanitiser is configured at standard level
    When input containing standard control characters is sanitised
    Then all control characters are stripped from the output

  Scenario: Input over 2000 characters is truncated
    Given an input string of 2001 or more characters
    When sanitise() is called at any level
    Then the output is truncated to exactly 2000 characters

  Scenario: ContextWindowManager removes oldest messages first
    Given the context window has reached its budget
    When trimContext() is called
    Then the oldest messages in the context are removed first
    And the most recent messages are retained

  Scenario: System prompt budget is enforced at 512 tokens
    Given a system prompt exceeding 512 tokens is provided
    When the context is assembled
    Then the system prompt is constrained to 512 tokens or fewer

  Scenario: All external inputs reach LLM only after sanitisation
    Given a test that bypasses the InputSanitiser and sends input directly to LlamaInferenceEngine
    When the test runs
    Then it is blocked by the architecture
    And a corresponding integration test verifies voice transcripts, calendar data,
     and contact names all pass through sanitise(.quarantine) before reaching infer()
```

## Implementation notes

- All 50 OWASP LLM adversarial fixture patterns must be tested on CI.
- Integration test (sanitisation path to LLM) required on CI.
- Security reviewer sign-off required before merge.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] All 50 adversarial prompt injection fixture tests passing on CI
- [ ] Integration test: all external inputs sanitised before reaching LLM, passing on CI
- [ ] Security reviewer sign-off before merge
- [ ] No PII in logs
