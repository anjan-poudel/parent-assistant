# FR-LCT-002: Camera permission and purpose disclosure

## Metadata
- **Area:** Camera Capture / Compliance
- **Priority:** MUST
- **Source:** Design §4.1, §7; feature constitution "Standards → Release gates"; project constitution Compliance constraints; Open Decision 13 (recorded 2026-09-16)

## Description
The system **must** request camera permission at the point of use with a plain-language
explanation in the active language, and **shall** handle every permission state without leaving
the elder at a dead end:

- **Not yet asked** — the explanation is shown before the system prompt.
- **Denied** — an explanatory screen with a Settings deep link (the existing permission-denied
  pattern used for the microphone), never a silent blank view.
- **Granted** — the live translation view opens directly.

`ios/ElderlyAssistant/Info.plist` `NSCameraUsageDescription` **must** disclose the live
translation use and the conditional text-to-cloud send, in addition to the existing medication
verification and appliance photo uses (the final consent/disclosure copy is reviewed before the
first App Store submission — design §10 Open Decision 3).

## Acceptance criteria

```gherkin
Feature: Camera permission and purpose disclosure

  Scenario: Permission granted on first use
    Given the elder has not yet granted camera permission
    When the elder invokes live translation
    Then a plain-language explanation of the camera use is shown in the active language
    And on granting, the live translation view opens

  Scenario: Permission denied
    Given the elder has denied camera permission
    When the elder invokes live translation
    Then an explanatory screen is shown in the active language with a link to Settings
    And the elder can return to the assistant without being trapped in the view

  Scenario: Purpose string discloses live translation and the cloud text send
    Given the shipped Info.plist
    When the camera purpose string is inspected
    Then it states that live translation uses the camera
    And it states that recognized text (never images) may be sent to the assistant's cloud service when the dictionary cannot translate it
```

## Related
- NFR: NFR-LCT-013 (compliance and release gates)
- Depends on: —
