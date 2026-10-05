# NFR-PI-010: No regression to existing behaviours

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" (wake-word recognition itself; emergency-call logic; voice-biometric mechanisms) and "Address-as Behaviour Contract" (behaves exactly as today until a term is recorded); Feature Constraints 6–7; workflow non-goals comment

## Description
The feature **must not** change existing behaviour outside its scope. Specifically:

- **Wake-word recognition** — the wake word and its detection logic are untouched; only post-detection acknowledgment behaviour is added.
- **Existing wizard steps** — their behaviour and their positions relative to each other are preserved; new steps are insertions.
- **Family contacts store** — `FamilyContactStore` behaviour is preserved; the feature extends its use, not its contract.
- **Safety paths** — emergency contact selection and family notification logic is unchanged (FR-PI-014); no new emergency-call logic, trigger or stub.
- **Voice-biometric mechanisms** — unchanged (NFR-PI-009).
- **Un-personalized baseline** — identical to today (FR-PI-011).

Measurable: the affected existing test suites stay green under the project's build/test gate, and shared components touched by the feature (`OnboardingState`, `VoicePipeline`, `IntentPrompt`) keep their existing contracts — additions are extensions, not modifications.

## Acceptance criteria

```gherkin
Feature: No regression to existing behaviours

  Scenario: Existing tests stay green
    Given the feature's changes are in the build
    When the affected existing test suites run under the project's build/test gate
    Then they pass unchanged

  Scenario: Wake-word recognition is untouched
    Given the feature's diff
    When the wake-word detection path is inspected
    Then the wake word and its detection logic are unchanged
    And only the post-detection acknowledgment behaviour is added

  Scenario: Shared components keep their contracts
    Given OnboardingState, VoicePipeline and IntentPrompt as used by existing features
    When the feature's changes are inspected
    Then their existing behaviour is unchanged
    And the feature's additions are extensions (new cases, new parameters, new call sites), not modifications
```

## Related
- FR: FR-PI-011 (un-personalized path), FR-PI-014 (safety paths)
- NFR: NFR-PI-005 (seed mirror), NFR-PI-009 (voice biometrics)
