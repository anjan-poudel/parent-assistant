# FR-CNR-020: The new chat gates — honorific agreement, no AI-isms, LLM-judge quality

## Metadata
- **Area:** Evaluation / Chat Gates
- **Priority:** MUST
- **Source:** Proposal §6 ("New gates: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge (reuse the `stt_judge_eval` judge pattern or Gemini) mean ≥4/5 on naturalness/grammar/warmth/brevity"); feature constitution "Mixture and gate harness" property 2 and "Nepali Conversation Style-Spec Contract" property 8 ("The honorific-agreement and no-AI-ism eval gates and the grammar guard's checks are implementations of this spec; a gate failure is a spec violation"); workflow scope comment. Surface: `tools/train-intent/eval/` (the harness), `eval/chat_golden.jsonl` (FR-CNR-019).

## Description
Three new chat gates **must** be implemented over `eval/chat_golden.jsonl` and **must** meet their thresholds for the catalog swap to be eligible:

| Gate | Threshold | Measures |
|---|---|---|
| Honorific agreement | pass rate **≥0.98** | तपाईं + honorific verb agreement, no तिमी toward the elder |
| No AI-isms | pass rate **≥0.98** | no lists/markdown, no "म एक AI हुँ", no canned service phrases, no translation-ese, no over-politeness |
| LLM-judge quality | mean **≥4/5** | naturalness, grammar, warmth, brevity (reusing the existing `stt_judge_eval` judge pattern or Gemini) |

Binding properties:
- **The gates implement the style spec** (FR-CNR-001): a gate failure is a spec violation, and the spec — not a gate-local heuristic — is the authority. A gate's rubric is derived from the spec, not authored beside it.
- **Thresholds are ship conditions, not targets**: a result below threshold is a failed gate (FR-CNR-021), never rounded, re-scoped or waived without the owner.
- **Judge reproducibility**: the LLM-judge configuration, judge model/version and prompt are recorded with the result so a gate verdict can be re-derived.
- **The gate run's result is recorded as release evidence** together with the fixture version (FR-CNR-019) and the model artifact identity.

## Acceptance criteria

```gherkin
Feature: The new chat gates gate the swap

  Scenario: All three gates are evaluated over the held-out set
    Given the candidate v17 model and eval/chat_golden.jsonl
    When the chat gate harness runs
    Then it reports honorific-agreement pass rate, no-AI-ism pass rate, and the LLM-judge mean over naturalness/grammar/warmth/brevity
    And each result is recorded with the fixture version and judge configuration

  Scenario: Thresholds are met and the candidate is eligible
    Given the gate run results
    When honorific agreement is ≥0.98, no-AI-ism is ≥0.98 and the judge mean is ≥4/5
    Then the chat gates are green
    And the candidate proceeds to the full harness (FR-CNR-021)

  Scenario: A gate fails (failure)
    Given a candidate with any chat gate below its threshold
    When the swap is considered
    Then the swap is blocked
    And the shortfall is reported to the owner rather than absorbed by loosening the gate
```

## Related
- FR: FR-CNR-001 (the spec the gates implement), FR-CNR-019 (fixture), FR-CNR-021 (full harness), FR-CNR-022 (swap discipline), FR-CNR-017 (data shaped to satisfy them)
- NFR: NFR-CNR-008 (thresholds in measurable form)
