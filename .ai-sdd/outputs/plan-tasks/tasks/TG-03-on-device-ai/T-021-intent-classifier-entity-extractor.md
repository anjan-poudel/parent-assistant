# T-021: IntentClassifier + EntityExtractor

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** IntentClassifier, EntityExtractor
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-020](T-020-input-sanitiser-context-window-manager.md)
- **Blocks:** [T-022](../TG-05-voice-session/T-022-voice-session-coordinator/index.md)
- **Requirements:** FR-008

## Description

Implement `IntentClassifier` and `EntityExtractor` as prompt-engineering layers over `LlamaInferenceEngine`, as specified in L2 §4.2. JSON-schema-based response parsing. Both components use `InputSanitiser.sanitise(.quarantine)` before every LLM call.

## Acceptance criteria

```gherkin
Feature: IntentClassifier and EntityExtractor

  Scenario: Call intent with contact entity is extracted correctly
    Given a voice transcript "Call [name] on Messenger"
    When the IntentClassifier and EntityExtractor process the transcript
    Then the intent is CALL_CONTACT
    And the contact_name entity is extracted

  Scenario: Reminder intent with time entity is extracted correctly
    Given a voice transcript "Remind me to take my medication at 8 PM"
    When the IntentClassifier and EntityExtractor process the transcript
    Then the intent is SET_REMINDER
    And the time entity is extracted as 8 PM

  Scenario: Health query intent is classified correctly
    Given a voice transcript "Check my heart rate"
    When the IntentClassifier processes the transcript
    Then the intent is HEALTH_QUERY

  Scenario: Malformed LLM JSON response is handled gracefully
    Given the LLM returns a malformed JSON response
    When the IntentClassifier attempts to parse the response
    Then no exception is thrown
    And the result falls back to GENERAL_CONVERSATION intent

  Scenario: Input is sanitised before LLM call
    Given the IntentClassifier is wired to a mock LlamaInferenceEngine
    When a transcript is processed
    Then sanitise(.quarantine) is called on the input before infer() is called
    And this is verified via the mock

  Scenario: End-to-end intent extraction with real LLM inference
    Given the full stack with real llama.cpp inference is available
    When a raw transcript is processed through the full pipeline
    Then the correct intent and entities are produced
    Note: this is a slow test, run nightly only
```

## Implementation notes

- Prompt-engineering layers over `LlamaInferenceEngine`; JSON-schema response parsing.
- `InputSanitiser.sanitise(.quarantine)` must be called before every LLM call — verified via mock.
- End-to-end integration test with real llama.cpp runs nightly (marked as slow test).
- Google Calendar OAuth 401 detection tested on CI with a mock OAuth server.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (fast tests on CI, slow E2E nightly)
- [ ] Sanitisation wiring verified via mock integration test on CI
- [ ] No PII in logs
