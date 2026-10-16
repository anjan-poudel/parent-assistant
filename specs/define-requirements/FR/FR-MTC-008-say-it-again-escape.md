# FR-MTC-008: "No — let me say it again" escape re-arms a fresh capture

## Metadata
- **Area:** Answer Capture / Escape
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Both kinds share ... the same constraints (template text, 45 s deadline, free-text always accepted, the 'no — let me say it again' escape re-arming a fresh capture)" and the `.candidateChoice` row ("a 'no — let me say it again' re-capture escape"); feasibility study §6.2 ("a 'no — let me say it again' escape that re-arms a fresh capture").

## Description
Both probe kinds **must** offer an escape: when the user says the "no — let me say it again" phrase (localized ne/en), the system **must** drop the current probe's framing, speak a brief acknowledgement, and re-arm a fresh capture so the user can say what they meant in their own words. Binding properties:

- **Recognised in both probe kinds** (`.slotFill` and `.candidateChoice`) and in the active language of the probe.
- **Executes nothing**: the escape itself resolves nothing and must never execute the pending command, a candidate, or any other action.
- **Fresh capture re-armed**: the user is immediately back in listening for a fresh utterance; their next utterance is their new attempt at the request, handled by the normal turn path (a fresh command, or an answer if it resolves against the still-pending probe context — the composition is design's to fix; the requirement is that the user is never stuck and nothing executes unasked).
- **No dead end**: the escape always produces the acknowledgement and the re-armed capture — never silence, never a repeated probe line only.
- **Never countable as a hostile input**: the escape cannot be used to bypass the emergency precedence or the frame's safety rules (FR-MTC-011; NFR-MTC-008).

## Acceptance criteria

```gherkin
Feature: The say-it-again escape

  Scenario: The escape re-arms a fresh capture in a slot-fill probe
    Given the slot-fill probe is outstanding
    When the user says the localized "no — let me say it again" phrase
    Then Pip briefly acknowledges and re-arms listening for a fresh utterance
    And the user is not stuck in a repeated question

  Scenario: The escape never executes anything by itself
    Given any probe is outstanding
    When the escape phrase is spoken
    Then neither the pending command nor any candidate is executed
    And no probe line is repeated as the only response

  Scenario: The escape works in a did-you-mean probe too
    Given the did-you-mean probe is outstanding
    When the user says the escape phrase in the active language
    Then the same acknowledgement and fresh capture follow
```

## Related
- FR: FR-MTC-003/FR-MTC-004 (the two probe kinds it serves), FR-MTC-005 (capture), FR-MTC-011 (safety precedence)
- NFR: NFR-MTC-010 (no stuck states), NFR-MTC-006 (localisation)
