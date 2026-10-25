# NFR-RIE-005: At-rest protection — complete file protection on every instruction video; no Photos/share exposure

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding properties 1–2 (video bytes protected at rest by iOS file protection — `.completeFileProtection`, the class the photo aids use; never Photos, never shared); OD-5 (RESOLVED 2026-10-25); §Feature Constraints 3.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract properties 1–2, §Decisions 5, §Feature Constraints 3. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:113–130` (`.completeFileProtection` at `:123`); `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:258–272`.

## Description
Every instruction video file **must** be written with the `.completeFileProtection` Data Protection class (the photo-aid class), so it is readable only while the device is unlocked. Files **must** live in the app's Application Support instruction roots, **not** in Documents, **not** in the Photos library, and **not** in any shared container. The file **must not** be exposed through a share sheet or the photo picker. Deleting an instruction **must** remove the protected file.

Measurable targets: 100% of instruction video files report `NSFileProtectionComplete`; 0 instruction files in the Photos library or shared containers; after deletion, 0 files remain in the owner's store subtree.

## Acceptance criteria

```gherkin
Feature: Instruction videos are protected at rest and never exposed

  Scenario: A saved video carries complete file protection
    Given a saved video instruction
    When the file's attributes are inspected
    Then the file reports the complete file protection class

  Scenario: The video is absent from Photos and share surfaces
    Given a saved video instruction
    When the photo library and share surfaces are inspected
    Then the video is not present in the Photos library
    And no share surface lists the video

  Scenario: Deletion leaves no recoverable file
    Given a saved video instruction
    When the instruction is deleted with its owner
    Then no file remains in the owner's instruction store subtree
```

## Related
- FR: FR-RIE-011 (store), FR-RIE-014 (delete with owner)
- NFR: NFR-RIE-007 (storage footprint)
