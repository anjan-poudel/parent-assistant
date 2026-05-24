# T-011: AccentTuner

## Metadata
- **Group:** [TG-02 — Voice Interface](../index.md)
- **Component:** AccentTuner
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-009](T-009-stt-engine/index.md), [T-002](../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md)
- **Blocks:** —
- **Requirements:** FR-005

## Description

Implement `AccentTuner` protocol from L2 §3.5. Background batch training from enrolled voice samples (minimum 20 utterances). Raw audio samples deleted immediately after training. Adapter stored in `EncryptedLocalStorage`. Progressive progress reporting via callback. Shared implementation for both iOS and Android.

## Acceptance criteria

```gherkin
Feature: AccentTuner iOS and Android

  Scenario: Protocol interface matches L2 §3.5 exactly
    Given the AccentTuner implementation
    When its interface is compared to L2 §3.5
    Then enrol, update, and currentAdapterVersion are present with correct signatures

  Scenario: Fewer than 20 samples returns insufficient samples error
    Given 19 or fewer audio samples are provided to enrol()
    When enrol() is called
    Then the result is Failure(.insufficientSamples(required: 20, provided: N))
    And no partial adapter is stored

  Scenario: Sufficient samples produce adapter stored in EncryptedLocalStorage
    Given 20 or more audio samples are provided
    When enrol() completes successfully
    Then the adapter is written to EncryptedLocalStorage
    And STTEngine.loadAccentAdapter() is called with the new adapter path

  Scenario: Raw audio buffers are deallocated after training
    Given enrol() is called with audio samples
    When enrol() returns
    Then all raw AudioBuffer instances are zeroed and deallocated
    And no raw audio data remains in memory

  Scenario: Training failure retains previous adapter version
    Given an existing adapter is present
    When enrol() fails during training
    Then the previous adapter version is still active
    And no regression occurs in transcription quality

  Scenario: Progress callback fires during training
    Given enrol() is called with sufficient samples
    When training is in progress
    Then the progress callback fires at regular intervals
    And the reported progress increases monotonically toward completion
```

## Implementation notes

- Shared implementation for both iOS and Android.
- Raw audio samples are deleted immediately after training — enforced by test (audio buffer deallocation).
- Adapter stored in `EncryptedLocalStorage`; STTEngine.loadAccentAdapter() called after successful training.
- Privacy test (audio buffer deallocation) run in both iOS and Android test suites.
- Integration test verifying adapter storage and STTEngine reload run on CI.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Privacy test (raw audio buffer deallocation) verified on both platforms
- [ ] Integration test: adapter stored and STTEngine reloaded on CI
- [ ] No PII in logs
