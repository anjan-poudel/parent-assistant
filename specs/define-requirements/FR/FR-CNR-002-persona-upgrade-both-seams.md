# FR-CNR-002: Persona upgrade in both seams — same style contract, local and cloud

## Metadata
- **Area:** Persona / Local + Cloud Seams
- **Priority:** MUST
- **Source:** Proposal §5.4 ("Persona upgrade: bake the style spec's concrete rules (particles budget, code-switch nouns, forbidden AI-isms) into `chatSystemPrompt` … and `replyPersona` — kept short for the token budget") and §2 ("Style is declared, never demonstrated": the persona says the register but the model has no data showing it); feature constitution "Persona seams and Gemini chat temperature" properties 1–3; workflow `define-requirements` scope comment. Surfaces: `LlamaCommandInterpreter.chatSystemPrompt` (:552-563); `GeminiCommandInterpreter.replyPersona` (:35-44); `IntentPrompt.buildChat` (:197-211) for the local template.

## Description
Both chat personas **must** be rewritten so their concrete rules are the style spec's rules (FR-CNR-001) — particles budget, code-switch nouns, forbidden AI-isms, register, sentence shape — and the two **must** carry the same contract so the local and cloud paths cannot drift apart. Binding properties:

- The persona text implements the spec's *concrete* rules; it does not describe the goal in the abstract ("warm grandchild" alone is exactly the failure this feature fixes).
- The persona stays **short** for the token budget (it shares the 1,024-token on-device ceiling, NFR-CNR-004) — the style is carried by the training data, not by prompt tokens.
- The personas are **declarative only**: no few-shot exemplar turns in the device prompt (style travels via data, not prompt tokens — a feature non-goal).
- The pinned intent prompt (`IntentPrompt.build` text, byte-mirrored by `seeds/prompt_template.txt` and pinned by `IntentPromptTests`) stays **byte-identical**; the chat template (`IntentPrompt.buildChat`) follows the seed-mirror rule of FR-CNR-023.
- A rule change reaches the personas via the spec (FR-CNR-001) — never by editing one persona in isolation.

## Acceptance criteria

```gherkin
Feature: Both chat personas implement the style spec and cannot drift

  Scenario: The local and cloud personas carry the same style contract
    Given the shipped feature
    When chatSystemPrompt and replyPersona are compared against the style spec
    Then each states the register, particles budget, code-switch and forbidden-AI-ism rules
    And no rule is present in one persona and absent from the other

  Scenario: The persona is declarative, not demonstrative
    Given the on-device chat prompt built by IntentPrompt.buildChat
    When it is inspected
    Then it contains no few-shot exemplar turns
    And the style rules are carried by the persona text plus the training corpus

  Scenario: The locked intent prompt is untouched
    Given the pinned intent prompt and its seed mirror
    When the feature's change set is inspected
    Then both are byte-identical to their pre-change content
    And IntentPromptTests' pin on the intent prompt still passes

  Scenario: A one-sided persona edit (failure)
    Given an edit that changes the style contract in one persona only
    When the change is reviewed
    Then it is rejected as drift between the local and cloud paths
    And the rule is corrected in the style spec first
```

## Related
- FR: FR-CNR-001 (the spec), FR-CNR-023 (template discipline), FR-CNR-011 (cloud sampling), FR-CNR-008 (cloud chat routing)
- NFR: NFR-CNR-004 (token budget), NFR-CNR-005 (byte-mirror discipline)
