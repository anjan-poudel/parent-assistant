# FR-MSR-021: Elderly-fit UX of the new flows — voice-first completion, plain language, vocabulary limit

## Metadata
- **Area:** Elderly-Fit UX
- **Priority:** MUST
- **Source:** Owner's brief scope point 7 ("core requirement: fit for forgetful elderly users", 2026-10-15); feature constitution "Feature Purpose & Scope" (primary user profile and observable success) and "Feature Constraints" 8; `requirements-dementia-supplement.md` §0.3 and NFR-D09 (read-only inputs); project constitution Accessibility standards.

## Description
Every new or revamped flow in this feature **must** be fit for its primary user: a forgetful elderly person (60+, many with cognitive challenges, non-English first language). Concretely:

- **Voice-first completion.** The intake loop — hearing the reminder, acknowledging, answering the confirmation challenge — is completable entirely by voice (or by the photo-evidence capture where the design provides it), with no touch interaction required at any step.
- **Plain language.** Prompts, acknowledgements, clarifications and notification copy use plain, familiar words; the sanctioned clarification copy (FR-MSR-008) is the only multi-part question form permitted.
- **Vocabulary limit.** No new flow may require the elder to learn command vocabulary beyond the established set: the activation path, yes/no, done/taken (simple or with medication and slot), and cancel.
- **One idea per utterance.** Prompt and acknowledgement utterances carry one idea; no stacked instructions. Response windows accommodate processing delay — no new flow introduces a pressure shorter than the shipped acknowledgement semantics (FR-MSR-019).
- **Near-zero friction.** The acknowledgement path adds no extra step for the unambiguous case versus the shared-slot case; friction only appears where disambiguation is genuinely required.

The quantitative elder-fit standards (target sizes, text sizes, contrast) are bound by NFR-MSR-005; the Devanagari matching behaviour is regression-pinned by NFR-MSR-007.

## Rationale
Owner point 7 is the core requirement, and the constitution fixes the observable success: the elder can always answer what they have taken and what they have not, with near-zero friction. That is a usability property of the new flows themselves — voice-first, plain, low-vocabulary — not just of the data they produce.

## Acceptance criteria

```gherkin
Feature: The new medication flows are fit for forgetful elderly users

  Scenario: The full intake loop completes without touch
    Given a medication reminder has fired on the elder's device
    When the elder acknowledges by voice and answers the confirmation challenge by voice
    Then the intake loop completed end to end
    And no step required a screen tap

  Scenario: The unambiguous acknowledgement adds no extra step
    Given exactly one reminder is pending
    When the elder says "Taken"
    Then the acknowledgement proceeds directly into the confirmation challenge
    And no naming or disambiguation step was added for the unambiguous case

  Scenario: No new vocabulary is required (failure guard)
    Given a proposed new flow that requires a command word or phrase outside the established set
    When it is reviewed against this requirement
    Then it is rejected
    And the flow must be completable with the established vocabulary or a yes/no answer

  Scenario: Prompts carry one idea at a time (edge)
    Given the prompts and acknowledgements in the new flows
    When each utterance is reviewed
    Then each carries one idea
    And no utterance stacks multiple instructions or open-ended choices
```

## Related
- FR: FR-MSR-007 (voice acknowledgement), FR-MSR-008 (sanctioned clarification form), FR-MSR-013 (photo path)
- NFR: NFR-MSR-005 (accessibility measures), NFR-MSR-004 (localisation and spoken times), NFR-MSR-007 (Devanagari pin)
