# FR-RIE-025: Camera and microphone at point of use — plain disclosure, denial non-blocking

## Metadata
- **Area:** Capture Permissions
- **Priority:** MUST
- **Source:** Feature constitution "Capture & Permissions Contract" property 2 (recording is the only new permission surface; camera and microphone requested at the point of use with plain-language explanation; the app works fully if either is denied; `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` must be amended to disclose video recording and that the recording stays on the device); §Feature Constraints 8.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Capture & Permissions Contract property 2, §Feature Constraints 8, §Safety & Compliance Delta "Permissions". Code surfaces: `ios/ElderlyAssistant/Info.plist:113–114` (`NSCameraUsageDescription`), `:121–122` (`NSMicrophoneUsageDescription`); `ios/ElderlyAssistant/Services/Apps/CameraCapture.swift:41,55`.

## Description
Camera and microphone **must** be requested at the point of use (first record attempt) with a plain-language explanation visible to the user. `Info.plist`'s `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` **must** be amended to disclose video recording and that the recording stays on the device, while retaining the existing disclosures (medication/appliance photos, live translation, voice commands). A denial of either permission **must** be non-blocking: recording is unavailable with a plain explanation, but library pick (FR-RIE-004), the reminder/event, and all other app functionality continue to work. Permission **must not** be requested at app launch, and a refusal **must not** produce a crash, a loop of prompts, or a raw error.

## Acceptance criteria

```gherkin
Feature: Recording permissions are asked for plainly and denial is not a dead end

  Scenario: First recording asks at the point of use
    Given the caregiver taps record for the first time
    When the system permission prompts appear
    Then camera is requested first and microphone next
    And each prompt's purpose states video recording and that the recording stays on the device
    And granting both allows recording

  Scenario: Camera denial leaves the rest working (edge)
    Given the caregiver denies camera access
    When the caregiver returns to the instruction editor
    Then recording is unavailable with a plain-language explanation
    And library pick still works
    And the reminder/event remains intact
    And the app does not crash or loop the prompt

  Scenario: Microphone denial leaves the rest working (edge)
    Given the caregiver denies microphone access
    When the caregiver tries to record
    Then recording is unavailable with a plain-language explanation
    And library pick still works
    And the reminder/event remains intact
    And the app does not crash or loop the prompt

  Scenario: Info.plist discloses video recording and on-device storage
    Given the shipped Info.plist
    When the camera and microphone usage descriptions are read
    Then both disclose video recording
    And both state that the recording stays on the device
    And the existing disclosures are retained
```

## Related
- FR: FR-RIE-004 (library pick), FR-RIE-005 (recording), FR-RIE-010 (feedback)
- NFR: NFR-RIE-002 (localisation of explanations)
