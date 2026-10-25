# FR-RIE-004: Pick an existing video from the library — first-class, permission-free source

## Metadata
- **Area:** Video Capture
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" in-scope item 3; "Capture & Permissions Contract" property 1 (library pick is first-class and needs no photo-library permission).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope item 3, §Capture & Permissions Contract property 1, §Decisions 2. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:26–30`; `ios/ElderlyAssistant/App/EventsView.swift:295`.

## Description
The caregiver **must** be able to choose an existing video from the phone's photo library using the out-of-process photo-picker pattern already used for photo aids (`PHPickerViewController` / `PhotosPicker`), which requires no photo-library permission. The chosen video **must** be imported into the app-managed instruction store (FR-RIE-011) as app data; it is never referenced in place from the library, never re-saved to the Photos library, and never listed in the photo picker as an app asset. Library pick **must** remain available and fully functional when the camera or microphone is unavailable or denied (FR-RIE-025) and when the reminder/event has no other media. Choosing a library video is subject to the same acceptance limits as recording (FR-RIE-006) and the same plain feedback rules (FR-RIE-010).

## Acceptance criteria

```gherkin
Feature: An existing video can be chosen from the photo library

  Scenario: Library video is imported into the app store
    Given the caregiver is editing a routine reminder's instruction
    When the caregiver picks a video from the photo library and saves it
    Then the video is copied into the app-managed instruction store for that reminder
    And the encrypted payload stores only the bare file name
    And the video is playable at fire time

  Scenario: Library pick works when the camera is unavailable (edge)
    Given camera access is denied or the device camera is unavailable
    When the caregiver chooses a video from the photo library and saves it
    Then the library pick and save succeed
    And the reminder remains scheduled and intact
```

## Related
- FR: FR-RIE-005 (in-app recording), FR-RIE-006 (limits), FR-RIE-010 (feedback), FR-RIE-011 (store), FR-RIE-025 (permissions)
- NFR: NFR-RIE-003 (no egress)
