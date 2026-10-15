# NFR-MSR-001: LLM independence — the medication scheduler unit stays free of LLM dependencies

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Project constitution Safety-critical constraints and `requirements.md` FR-009 (read-only input); `docs/medication-scheduler-implementation-plan.md` safety invariant 1 (no LLM symbols in the medication scheduler compilation unit); feature constitution "Intake Acknowledgement & Recording Contract" binding property 7 and "Feature Constraints" 1.

## Description
The medication scheduler compilation unit **must not** depend on the on-device language model (no dependency on the LLM inference engine). Reminder firing, escalation, the acknowledgement → challenge → double-dose → record sequence, and intake recording must all operate when the LLM is busy, unavailable, not loaded, or in rework.

Measurable form: a build/link inspection of the medication scheduler unit finds zero LLM-inference symbols, and the safety-path integration test passes with the LLM made unavailable.

## Acceptance criteria

```gherkin
Feature: Medication safety paths run without the language model

  Scenario: The safety sequence completes while the LLM is unavailable
    Given the on-device LLM is unavailable (busy, failed to load, or stopped)
    When a reminder fires and the elder acknowledges through the challenge sequence
    Then the reminder fires, the sequence completes and the dose is recorded
    And no step waited on the LLM

  Scenario: Symbol inspection finds no LLM dependency (failure guard)
    Given the medication scheduler compilation unit
    When its dependencies are inspected (build/link symbol check)
    Then no LLM-inference symbols are present in the unit
    And a discovered dependency fails the check and is removed
```

## Related
- FR: FR-MSR-019 (escalation preserved), FR-MSR-022 (persistence and re-arm)
- NFR: NFR-MSR-008 (test rigor)
