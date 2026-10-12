# FR-CDP-013: Fallback resolves before the spoken confirmation; the prompt names the routed channel

## Metadata
- **Area:** Voice Path / Spoken Confirmation
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 2 ("`requestCallConfirmation` runs the feasibility fallback BEFORE pending the action ... The confirmation prompt names the routed channel and discloses what was skipped — \"Messenger isn't available — call Syanu via WhatsApp, okay?\"") + Goal 4 + Decision 5; feature constitution "In scope" bullet 5 and Feature Constraint 6; workflow `security-design-review` focus ("the spoken confirmation names the actually-routed channel (`fellBackFrom`); no silent route changes"); DV-2.

## Description
`requestCallConfirmation` **must** run the feasibility fallback **before** pending the action and rendering the prompt:

- The existing Messenger-no-handle refusal becomes a chain hop: Messenger without a usable handle → the settings secondary → GSM. The elder is never asked to yes/no an action that can only fail (the existing no-yes/no-trap property is preserved).
- The confirmation prompt **must** name the actually-routed channel and disclose what was skipped, composed from `fellBackFrom` (FR-CDP-008) — e.g. "Messenger isn't available — call Syanu via WhatsApp, okay?" — via the new catalog key `router.call.fallbackDisclosure` (ne/en, FR-CDP-017).
- On "yes", the call executes on the routed channel; the context carries the routed channel (not the originally-preferred one) into execution and the flywheel capture.
- The existing multi-turn confirmation machinery **must** be reused exactly (Decision 5, Feature Constraint 6): pend → open the existing confirmation window → yes/no → execute/override/timeout, with **no new dialogue flow**, no new question kind and no new state.
- When nothing falls back, the prompt is exactly today's wording.

## Acceptance criteria

```gherkin
Feature: Fallback applied before the spoken confirmation

  Scenario: The prompt names the routed channel and discloses the skip
    Given the settings primary is Messenger and the contact has no handle on file
    And the settings fallback is WhatsApp
    When the user asks to call the contact without naming an app
    Then the pending action is built for WhatsApp (not the infeasible Messenger)
    And the spoken confirmation names WhatsApp as the channel and discloses that Messenger was unavailable
    And on "yes" the call executes via WhatsApp

  Scenario: Both channels infeasible route to GSM with the floor announced
    Given the settings primary and fallback are both infeasible for the target
    When the user asks to call the contact
    Then the pending action is a phone (GSM) call
    And the spoken confirmation names the phone channel via the floor

  Scenario: No fallback keeps today's prompt
    Given the preferred channel is feasible
    When the user asks to call the contact
    Then the confirmation prompt is unchanged from before the feature
    And no fallback disclosure is appended
```

## Related
- FR: FR-CDP-007/008 (chain + provenance), FR-CDP-012 (method resolution feeding this), FR-CDP-014 (override lines compose with the disclosure), FR-CDP-016 (no ask-before-fallback)
- NFR: NFR-CDP-003 (no content leakage in prompts/logs), NFR-CDP-008 (wording pinned by tests)
