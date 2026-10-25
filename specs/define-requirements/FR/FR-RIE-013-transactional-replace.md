# FR-RIE-013: Transactional replace — write the new video before the index points at it

## Metadata
- **Area:** Storage Lifecycle
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 5 ("a replacement video is written before the index points at it; the old file is deleted only after the index update succeeds — the `FreeFormEventService.setPhoto` precedent"; a failed write leaves the previous instruction intact and reports the failure plainly).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract property 5, §Feature Constraints 3 and 5. Code surfaces: `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:396–414`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:110–115`.

## Description
Replacing an instruction video **must** be transactional in the direction that cannot lose data, following the `FreeFormEventService.setPhoto` precedent: the new file **must** be written before the encrypted index (or model payload) points at it, and the old file **must** be deleted only after the index update succeeds. If the new write or the index update fails, the previous instruction **must** remain intact and playable, the failure **must** be reported plainly (FR-RIE-010), and no partially written file is left referenced or orphaned. Text and image replacements follow the same ordering rule with their own stores.

## Acceptance criteria

```gherkin
Feature: Replacing an instruction never loses the previous one

  Scenario: A successful replace swaps the file after the index update
    Given a routine reminder with a saved video instruction
    When the caregiver saves a replacement video successfully
    Then the encrypted index points at the new file
    And the old file is deleted only after the index update succeeded
    And exactly one video file remains for the reminder

  Scenario: A failed write leaves the previous instruction intact (failure)
    Given a routine reminder with a saved video instruction
    When writing the replacement video fails
    Then the previous instruction remains intact and playable
    And the encrypted index is unchanged
    And a plain-language message reports that the save did not complete

  Scenario: A failed index update does not leave a new file referenced (failure)
    Given the replacement file was written
    When updating the encrypted index fails
    Then the index still points at the previous file
    And the new file is not presented as the instruction
    And the failure is reported plainly
```

## Related
- FR: FR-RIE-006 (acceptance limits), FR-RIE-010 (feedback), FR-RIE-011 (store), FR-RIE-014 (delete with owner)
- NFR: NFR-RIE-007 (zero orphans)
