# NFR-SP-004: Prompt token budget preserved

## Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 3 ("`IntentPromptTests` pins the intent prompt's token budget; music/Spotify prompt additions must fit it. The YouTube route's zero-prompt-token discipline is the model"); the project precedent `NFR-PI-005-prompt-budget-and-seed-mirror`

## Description
Music-intent wording changes in the intent/prompt layer **must** fit inside the existing pinned prompt budget, without raising the pin. Measurable properties:

- **Pinned budget holds**: `IntentPromptTests` (the token/character ceiling on the intent prompt) passes unchanged; the pinned ceiling value is not increased to accommodate music wording.
- **Zero-token preference is exercised**: the deterministic keyword path (FR-SP-013) is the primary music classification route, so the model prompt's music wording can stay small; whatever wording is added must fit the remaining budget.
- **Seed mirror**: if any prompt template text changes, the byte-mirrored training seed (`tools/train-intent/seeds/prompt_template.txt`) is updated in the same change and the project's prompt-mirror check passes (`ios/tools/check-prompt-mirror.sh`).
- **No behaviour drift**: the budget-preservation must not regress existing intents — the prompt's other rules are unchanged except for the deliberate music wording (NFR-SP-006).

## Acceptance criteria

```gherkin
Feature: Prompt budget preserved

  Scenario: The pinned intent prompt budget still passes with music wording
    Given the music wording has been added to the intent/prompt layer
    When IntentPromptTests run
    Then they pass with the pinned ceiling unchanged

  Scenario: The prompt and seed mirror stay in sync
    Given the intent prompt template text changed
    When the prompt-mirror check runs
    Then the training seed mirror matches byte-for-byte
    And the check passes

  Scenario: An over-budget wording change is rejected, not accommodated
    Given a wording change that would exceed the pinned ceiling
    When the change is proposed
    Then it fails IntentPromptTests
    And the pinned ceiling is not raised to accept it
```

## Related
- FR: FR-SP-013 (deterministic rule — the zero-prompt path), FR-SP-015 (routing)
- NFR: NFR-SP-006 (no regression)
