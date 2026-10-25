# FR-RIE-020: Playback failure — plain localized message, reminder stays, always dismissible, PII-free log

## Metadata
- **Area:** Failure Handling
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 5 (missing/corrupt/unplayable video shows a short, localized, plain-language message while the reminder's title/time remain; the screen can always be dismissed; never a blank screen, endless spinner, raw error, or error code; failure logged PII-free); §Feature Constraints 5.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 5, §Feature Constraints 5 and 9, §Safety & Compliance Delta. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift:42–66`; `ios/ElderlyAssistant/App/VisualAidViews.swift:108–209`.

## Description
A missing, corrupt, unsupported, deleted, or otherwise unplayable video **must** produce a short, localized, plain-language message (for example "This video is not available right now.") while the reminder's or event's own content (title and time) remains on screen. The screen **must** always be dismissible (no modal dead end) and **must never** show a blank screen, an endless spinner, a raw error, or an error code. The failure **must** be logged PII-free: event type and outcome only — no title, caption, file name, path, entry identifier in clear, or video content (NFR-RIE-004). The same plain fallback applies when the file is rejected by the traversal guard (FR-RIE-012) or fails to load after a replace (FR-RIE-013).

## Acceptance criteria

```gherkin
Feature: An unusable video degrades to a plain message without losing the reminder

  Scenario: A missing file at Play shows a plain message
    Given the fired screen with a video instruction whose file is missing
    When the user taps Play
    Then a short plain-language unavailable message is shown
    And the reminder title and time remain visible
    And the screen can be dismissed

  Scenario: A corrupt file shows no raw error (failure)
    Given the fired screen with a corrupt video instruction
    When playback is attempted
    Then a short plain-language unavailable message is shown
    And no raw error, OSStatus code or technical detail is shown
    And the screen can be dismissed

  Scenario: The failure log carries no PII (edge)
    Given a video playback failure
    When the failure is logged
    Then the log entry contains the event type and outcome only
    And it contains no title, caption, file name, path or entry identifier in clear

  Scenario: Loading never spins forever (edge)
    Given a video instruction that cannot be loaded
    When the fired screen resolves the instruction
    Then the screen resolves to content or the plain fallback within the bounded time
    And no spinner remains indefinitely
```

## Related
- FR: FR-RIE-012 (traversal guard), FR-RIE-015 (always fires), FR-RIE-019 (tap path)
- NFR: NFR-RIE-004 (PII-free logging), NFR-RIE-008 (fallback within 1 s)
