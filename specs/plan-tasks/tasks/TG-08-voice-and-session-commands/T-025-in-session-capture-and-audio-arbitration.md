# T-025: In-Session Capture and Audio Arbitration

## Metadata
- **Group:** [TG-08 — Voice Output and Session Commands](index.md)
- **Component:** C01 capture configuration + C12 command capture
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-006](../TG-02-camera-and-detection/T-006-live-camera-session.md), [T-023](T-023-session-command-parser.md), [T-024](T-024-spoken-output.md)
- **Blocks:** T-026, T-027
- **Requirements:** FR-LCT-021, NFR-LCT-005, NFR-LCT-011

## Description

Give the session a **single-utterance** microphone for commands — the shipped plugin precedent, not
always-on listening — configured so the camera and the microphone coexist with other audio, with the
microphone paused while the feature is speaking so it does not hear itself. Teardown releases the
microphone as completely as the camera.

Source: `Services/LiveTranslate/` `LiveCameraSession.swift` audio configuration plus the recognition
lifecycle under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: In-session microphone use

  Scenario: A spoken command is captured as a single utterance
    Given the session is running
    When the elder says a command phrase
    Then the utterance is captured and handed to the parser (T-023)
    And capture is not always-on: it runs for the command window, not continuously

  Scenario: The feature does not hear itself
    Given the feature is speaking a translation
    When recognition would otherwise be active
    Then the microphone is paused for the duration of the speech
    And the feature's own output is never recognised as a command (C12)

  Scenario: Recording coexists with background audio
    Given another app is playing audio
    When the session starts and a command is captured
    Then the audio configuration allows recording alongside it with no session error
    And the other app's audio is not muted by starting the session

  Scenario: Closing releases the microphone as completely as the camera
    Given the session is running with the microphone available
    When the session closes
    Then recognition stops, the audio resources are released and the microphone indicator goes out
    And no recognition callback fires after teardown

  Scenario: An interruption pauses capture and resumes safely
    Given an interruption such as a call
    When it begins and then ends
    Then capture pauses and resumes without duplicating a command or losing the session
    And no command fires from pre-interruption audio on resume

  Scenario: Command audio is never retained or uploaded
    Given a recognised command
    When it is handled
    Then no audio is written to storage and no audio leaves the device
    And no transcript text appears in any event (NFR-LCT-005)
```

## Implementation notes

- Capture is the plugin's **single-utterance in-session microphone**, following the shipped appliance
  helper's precedent — explicitly **not** always-on listening (C12). Do not add a continuous recogniser
  to make commands feel faster.
- Recording category with the music-and-recording option (or the project's equivalent) so starting the
  session does not interrupt the elder's audio. Keep the category string in one place.
- Self-speech exclusion: pause recognition while the feature is speaking and resume after — a
  straightforward gate is preferable to acoustic echo suppression and is far easier to test.
- Teardown order matters: stop recognition, drain the command queue, release audio, then the capture
  session (T-006). A callback after teardown is the failure this guards against.
- Reuse the shipped recognition component rather than opening a second recognition session; the
  shipped microphone permission and explanation surfaces are unchanged by this feature.
- Emit no audio content, no transcript and no command text — only mapped-action counts (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts capture is single-utterance and no command fires from the feature's own speech
- [ ] A test asserts teardown releases the microphone with no callback after teardown
- [ ] A test asserts no audio is retained beyond the command window and none is uploaded
- [ ] Integration test against a stubbed audio session, including the interruption path
- [ ] `ios/build.sh` passes
