# FR-LCT-022: LiveTranslatePlugin voice entry and session lifecycle

## Metadata
- **Area:** Plugin & Session
- **Priority:** MUST
- **Source:** Design §0, §2, §4.6; feature constitution "Known integration surface" (session-local commands, no intent-encoder retraining); `ApplianceHelperPlugin` precedent

## Description
Live translation **must** ship as a new voice-invokable plugin, `LiveTranslatePlugin`, registered
in the plugin registry as a sibling of `ApplianceHelperPlugin`:

- **voice entry** — the elder opens it by voice ("translate this" in English or Nepali); the
  plugin's entry is session-local command matching in the same shape as the appliance helper's
  entry. The shared intent encoder is **not** retrained and no global intent vocabulary is added
  for this feature.
- **session commands** — at minimum: "read this to me" (FR-LCT-021), the "always show original"
  toggle phrase (FR-LCT-017), and "stop"/close. Commands are session-local, parsed in the plugin's
  session.
- **presentation** — the plugin presents its own full-bleed SwiftUI view; there is one obvious
  close control (≥ 44 pt) that stops the camera session and returns the elder to the assistant.
- **session lifecycle** — backgrounding, a phone call, or an interruption pauses the capture
  session; returning to the foreground resumes it. Overlays for the visible scene reappear from
  the cache without a new cloud request. No overlay state may be silently lost on resume.

## Acceptance criteria

```gherkin
Feature: Plugin entry and session lifecycle

  Scenario: Voice entry opens live translation
    Given the assistant is listening
    When the elder says "translate this" (or the Nepali equivalent)
    Then the live translation view opens with the camera preview
    And the shared intent encoder has not been retrained or extended for this feature

  Scenario: Interruption pauses and resumes the session
    Given the live translation view is open and showing overlays
    When the app is backgrounded (or a phone call arrives) and then returns to the foreground
    Then the capture session is paused and resumed
    And previously resolved overlays reappear from the cache without a new cloud request

  Scenario: One obvious exit
    Given the live translation view is open
    When the elder taps the close control
    Then the capture session stops
    And the elder returns to the assistant without further prompts
```

## Related
- FR: FR-LCT-021 (voice reading), FR-LCT-017 (toggle), FR-LCT-001 (preview)
- NFR: NFR-LCT-003 (accessibility), NFR-LCT-004 (localisation), NFR-LCT-012 (no regression)
- Depends on: FR-LCT-001, FR-LCT-002
