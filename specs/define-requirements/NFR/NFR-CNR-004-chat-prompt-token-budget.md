# NFR-CNR-004: Chat prompt token budget — the 1,024-token ceiling holds

## Metadata
- **Category:** Performance / Resource Budget
- **Priority:** MUST
- **Source:** Proposal §4 ("no few-shot exemplars in the device prompt (they eat the **1,024 budget**)"); feature constitution "Prompt/seed discipline" property 2 ("The chat template stays within the pinned 1,024-token on-device budget (`IntentPromptTests`' ceiling)") and "Model & Training Contract" property 3 (extended-tokenizer base leaves "budget inside the 1,024-token ceiling"); workflow `security-design-review` focus ("chat templates stay within the 1,024-token budget").

## Description
The on-device chat prompt **must** stay within the pinned 1,024-token budget enforced by `IntentPromptTests`. Measurable properties:

- **Ceiling**: the fully assembled chat prompt (system persona + template + the turn being answered) tokenises to **≤1,024 tokens**; the existing ceiling test remains green and now covers the upgraded chat template.
- **No exemplar inflation**: **0** few-shot exemplar turns are present in the device chat prompt (style travels via data — FR-CNR-023); the persona upgrade is kept short enough that the rules fit without pushing the assembly over the ceiling.
- **Headroom is not silently consumed**: the persona/rule additions (FR-CNR-002) are within budget, and any requirement to exceed the ceiling is reported as a design-level conflict rather than satisfied by truncating user context (a truncated turn degrades intent quality on the safety-critical model).
- **Cloud prompt does not substitute**: exceeding the local ceiling is not "solved" by routing more turns to the cloud — the local path must be able to answer within budget offline (FR-CNR-008, DV-3).

## Acceptance criteria

```gherkin
Feature: The chat prompt stays inside the 1,024-token ceiling

  Scenario: The assembled chat prompt fits the ceiling
    Given the upgraded chat persona, the chat template and a representative turn
    When the prompt is tokenised by the suite's budget test
    Then the total is ≤1,024 tokens
    And the test stays green

  Scenario: No exemplar turns inflate the prompt
    Given the shipped device chat prompt
    When it is inspected
    Then it contains 0 few-shot exemplar turns

  Scenario: The budget is exceeded (failure)
    Given a build whose assembled chat prompt exceeds 1,024 tokens
    When the budget test runs
    Then the build fails the gate
    And the conflict is resolved in the persona/rules or reported as a design issue
    And user context is not silently truncated to make the fit
```

## Related
- FR: FR-CNR-002 (persona text), FR-CNR-013 (single-decode), FR-CNR-023 (template discipline and no exemplars)
- NFR: NFR-CNR-003 (working set), NFR-CNR-005 (byte-mirror discipline)
