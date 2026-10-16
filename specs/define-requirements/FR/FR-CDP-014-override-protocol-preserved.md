# FR-CDP-014: Override protocol and near-miss disclosure preserved unchanged

## Metadata
- **Area:** Voice Path / Override Protocol
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 2 ("The override protocol and near-miss disclosure are preserved unchanged") + Goal 4 + Decision 5; feature constitution Feature Constraint 6 ("the override protocol (\"होइन, फोन नै गर\") is preserved unchanged"); workflow scope comment; DV-5.

## Description
The call-confirmation correction protocol **must** keep working exactly as today (`handleCallConfirmationOverride`):

- "होइन, फोन नै गर" (or any method-amendment utterance) **must** still amend the pending call action's method, re-confirm once, and let the following yes/no execute as normal — the override pair remains the flywheel's capture.
- The existing no-handle gate on overrides **must** be preserved: amending to Messenger for a contact with no usable handle speaks the existing refusal line (`router.call.messengerNoHandle`) and keeps the original action pending, so "हो" still places the original and a further correction still re-plans.
- The **near-miss disclosure** **must** be preserved: a near-miss contact resolution is still disclosed in the same utterance as the confirmation (heard name + proposed name), before the yes that gates the call.
- The fallback disclosure (FR-CDP-013) **must** compose with — never replace or suppress — these existing lines; an override after a fallback still executes the amended method through the normal confirmation.

## Acceptance criteria

```gherkin
Feature: Override protocol and near-miss disclosure preserved

  Scenario: The phone override still switches the call and re-confirms once
    Given a call confirmation is pending (with a fallback disclosure if a fallback occurred)
    When the user says "होइन, फोन नै गर"
    Then the pending method is amended to a phone call
    And the confirmation is re-asked once
    And a following "हो" executes the phone call

  Scenario: The override no-handle gate is preserved
    Given a call confirmation is pending for a contact with no usable Messenger handle
    When the user overrides to Messenger
    Then the existing refusal line is spoken
    And the original pending action stays pending
    And "हो" still places the original call

  Scenario: Near-miss disclosure is preserved alongside a fallback disclosure
    Given the heard name resolves only as a near miss and the chain fell back to another channel
    When the confirmation is spoken
    Then the utterance discloses the heard name and the proposed name
    And it also names the routed channel and the skipped channel
    And the call executes only after "yes"
```

## Related
- FR: FR-CDP-012/013 (voice path + fallback disclosure), FR-CDP-018 (no new dialogue flow)
- NFR: NFR-CDP-009 (regression pin on the override machinery)
