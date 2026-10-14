# FR-CNR-023: Chat prompt/template discipline — seed byte-mirror, intent prompt untouched, no few-shot exemplars

## Metadata
- **Area:** Prompt Discipline / Seed Mirror
- **Priority:** MUST
- **Source:** Proposal §4 ("**Style via data, not prompt tokens**: no few-shot exemplars in the device prompt (they eat the 1,024 budget) … Add `seeds/chat_prompt_template.txt` byte-mirrored to `IntentPrompt.buildChat`, same discipline as the intent prompt"); feature constitution "Prompt/seed discipline" 1–3 and "Persona seams and Gemini chat temperature" property 2, "Out of scope (must not change)" ("Few-shot exemplars in the on-device prompt — style travels via data, not prompt tokens"); workflow `security-design-review` / `security-test` focus ("seeds/chat_prompt_template.txt byte-mirrors IntentPrompt.buildChat"). Surfaces: `tools/train-intent/seeds/` (`prompt_template.txt` existing, `chat_prompt_template.txt` new), `IntentPrompt.buildChat` (:197-211), `IntentPromptTests` (1,024-token ceiling and the intent-prompt pin).

## Description
The chat prompt template **must** be governed by the same seed-mirror discipline the intent prompt uses:

- **Byte-mirror, same change.** `tools/train-intent/seeds/chat_prompt_template.txt` byte-mirrors the text produced by `IntentPrompt.buildChat`; any `buildChat` edit lands together with its seed update in the same change. Never a mirror "to be refreshed later".
- **The pinned intent prompt stays byte-identical.** `IntentPrompt.build`'s text, its `seeds/prompt_template.txt` mirror and the `IntentPromptTests` pin are untouched by this feature; the chat template is a separate artifact.
- **Within the pinned token budget.** The chat template (persona + template + turn) stays within the 1,024-token on-device ceiling enforced by `IntentPromptTests`; the persona upgrade (FR-CNR-002) is kept short precisely to respect this.
- **No few-shot exemplars in the device prompt.** The conversational register is demonstrated by the training corpus, not by prompt tokens — adding exemplar turns to the prompt is a defect against this requirement (and against the token budget).
- **The template change is verifiable**: the mirror check is mechanical (byte comparison), so a drift between code and seed is detectable in the test suite rather than by review.

## Acceptance criteria

```gherkin
Feature: The chat template and its seed mirror stay in lockstep

  Scenario: The seed mirrors the code
    Given the shipped feature build
    When tools/train-intent/seeds/chat_prompt_template.txt is compared with the text IntentPrompt.buildChat produces
    Then they are byte-identical

  Scenario: A buildChat edit carries its seed update in the same change
    Given a change that edits IntentPrompt.buildChat
    When the change set is reviewed
    Then chat_prompt_template.txt is updated in the same commit
    And the template remains within the pinned 1,024-token budget

  Scenario: The intent prompt and its pin are untouched
    Given the pre-change intent prompt, its seed mirror and the IntentPromptTests pin
    When the feature's change set is inspected
    Then all three are byte-identical to their pre-change content

  Scenario: Exemplars are injected into the device prompt (failure)
    Given a chat prompt containing few-shot exemplar turns
    When the prompt is inspected
    Then the injection is reported as a defect
    And it is removed before ship (style travels via data, not prompt tokens)
```

## Related
- FR: FR-CNR-002 (persona text inside the template), FR-CNR-013 (single-decode shape), FR-CNR-016 (style learned from data)
- NFR: NFR-CNR-004 (token budget), NFR-CNR-005 (byte-mirror discipline)
