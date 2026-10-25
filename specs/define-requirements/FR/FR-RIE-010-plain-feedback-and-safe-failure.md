# FR-RIE-010: Plain visible feedback — choose, record, save, replace, remove; cancellation and failure never silent

## Metadata
- **Area:** Caregiver Editing
- **Priority:** MUST
- **Source:** Feature constitution "Capture & Permissions Contract" property 4 (choosing, recording, saving, replacing and removing each produce a clear state; cancellation is an outcome, not an error; save failures keep the draft or previous instruction and say so — never a silent no-op); root Agent Principles "No silent stubs".
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Capture & Permissions Contract property 4, §Feature Constraints 5 and 9, §Safety & Compliance Delta ("No silent stubs"). Code surfaces: `ios/ElderlyAssistant/App/VisualAidViews.swift:352,530–543` (editor draft-commit precedent); `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:396–414` (save-failure handling precedent).

## Description
Choosing, recording, saving, replacing and removing an instruction **must** each produce a clear, plain-language state in the caregiver UI (for example a saved preview, a progress state, or an empty state). Cancellation **must** be treated as an outcome, not an error, and **must** leave the instruction unchanged. A save or import failure **must** keep the caregiver's draft or the previous instruction intact and say plainly that it did not save; it **must never** be a silent no-op, a silent success, or a raw error. These rules apply to text, image and video instructions and to both surfaces.

## Acceptance criteria

```gherkin
Feature: Every instruction action has visible, plain feedback

  Scenario: A successful save shows a clear saved state
    Given the caregiver has chosen a video instruction
    When the save succeeds
    Then the editor shows a clear saved state with the new instruction preview

  Scenario: Cancellation is an outcome, not an error (edge)
    Given the caregiver has a saved video instruction
    When the caregiver starts a replacement and cancels
    Then the previous instruction is unchanged
    And no error state is shown

  Scenario: A save failure keeps the previous instruction and says so (failure)
    Given the caregiver has a saved instruction
    When saving a replacement fails
    Then the previous instruction remains intact and playable
    And a plain-language message says the save did not complete
    And the screen does not report success

  Scenario: Removing an instruction shows an empty state and keeps the owner
    Given a routine reminder with a video instruction
    When the caregiver removes the instruction
    Then the instruction store entry is removed
    And the editor shows a clear empty state
    And the routine reminder itself remains
```

## Related
- FR: FR-RIE-006 (rejection feedback), FR-RIE-009 (edit surfaces), FR-RIE-013 (transactional replace)
- NFR: NFR-RIE-004 (PII-free logs)
