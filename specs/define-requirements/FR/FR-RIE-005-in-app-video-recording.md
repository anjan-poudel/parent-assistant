# FR-RIE-005: Record a video in the app — system camera UI, ships in v1

## Metadata
- **Area:** Video Capture
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" in-scope item 3; "Capture & Permissions Contract" property 1; OD-2 (RESOLVED 2026-10-25: in-app recording ships in v1 using the system camera UI).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope item 3, §Capture & Permissions Contract properties 1–2, §Decisions 2. Code surfaces: `ios/ElderlyAssistant/Services/Apps/CameraCapture.swift:41,55`; `ios/ElderlyAssistant/Services/Apps/PhotoCameraPresenter.swift:21`.

## Description
In-app video recording **must** ship in v1 (OD-2). The caregiver **must** be able to record a new video with the system camera UI (`UIImagePickerController` video capture or an AVFoundation system capture flow) and save it as the instruction. The recorded video is app data: stored locally in the instruction store (FR-RIE-011), never uploaded, transcribed, or AI-processed, never saved to the Photos library, and never shared to other apps. Recording **must** request camera and microphone at the point of use with plain-language disclosure (FR-RIE-025). Cancelling the system camera UI **must** return to the editor without changing the previous instruction and without an error state (FR-RIE-010). Recorded video is subject to the same acceptance limits as a picked video (FR-RIE-006).

## Acceptance criteria

```gherkin
Feature: A caregiver can record a video instruction in the app

  Scenario: Record and save a video instruction
    Given the caregiver is editing a routine reminder's instruction
    When the caregiver records a video with the system camera UI and accepts it
    Then the recording is stored locally in the app-managed instruction store
    And the reminder payload stores only a bare file name
    And the recording is playable at fire time

  Scenario: Cancelling the camera changes nothing (edge)
    Given the caregiver already has a saved video instruction
    When the caregiver opens the system camera UI and cancels
    Then the previous instruction is unchanged
    And no error is shown for the cancellation
```

## Related
- FR: FR-RIE-004 (library pick), FR-RIE-006 (limits), FR-RIE-010 (feedback), FR-RIE-011 (store), FR-RIE-025 (permissions)
- NFR: NFR-RIE-003 (no egress)
