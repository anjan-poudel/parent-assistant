# NFR-PI-005: Prompt token budget and seed mirror preserved

## Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraints 1–2 (prompt token budget: templates run in a 1,024-token on-device context and are pinned by `IntentPromptTests`' character ceiling — any prompt edit must preserve the budget and keep the tests passing; seed mirror: `tools/train-intent/seeds/prompt_template.txt` must be updated byte-identically in the same change as any `IntentPrompt` template edit)

## Description
The reply-style prompt edits **must** preserve the pinned budget:

- The templates run in a **1,024-token** on-device context; the character ceiling pinned by `IntentPromptTests` **must not** be raised to fit the personalization, and `IntentPromptTests` must pass with a term recorded and with no term recorded.
- The address-as composition is bounded (NFR-PI-004), so the budget holds for arbitrarily long user input.
- `tools/train-intent/seeds/prompt_template.txt` **must** be updated **byte-identically** to the shipped template in the same change as any template edit — byte identity is the measurable property (a checksum equality).

## Acceptance criteria

```gherkin
Feature: Prompt budget and seed mirror

  Scenario: The pinned budget is preserved with the term recorded
    Given the personalized prompt templates with an address-as term recorded
    When IntentPromptTests run
    Then they pass within the pinned character ceiling
    And the composed prompt fits the 1,024-token on-device context

  Scenario: The seed file is byte-identical to the template
    Given the prompt template change
    When tools/train-intent/seeds/prompt_template.txt is compared with the shipped template
    Then the two are byte-identical (checksums equal)
```

## Related
- FR: FR-PI-009 (reply-style rules)
- NFR: NFR-PI-004 (injection hardening), NFR-PI-010 (no regression)
