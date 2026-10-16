# T-027: `LiveTranslatePlugin`, Entry and Session View

## Metadata
- **Group:** [TG-09 — Plugin Session and Pipeline Integration](index.md)
- **Component:** C13 — `LiveTranslatePlugin` and the full-bleed session view
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md), [T-006](../TG-02-camera-and-detection/T-006-live-camera-session.md), [T-008](../TG-02-camera-and-detection/T-008-camera-permission-surfaces.md), [T-015](../TG-05-consent-and-disclosure/T-015-consent-prompt-and-revocation.md), [T-021](../TG-07-overlay/T-021-overlay-view-and-states.md), [T-025](../TG-08-voice-and-session-commands/T-025-in-session-capture-and-audio-arbitration.md), [T-026](T-026-translation-pipeline-and-session-model.md)
- **Blocks:** T-028, T-029, T-030
- **Requirements:** FR-LCT-001, FR-LCT-022, FR-LCT-023, NFR-LCT-004, NFR-LCT-011, NFR-LCT-012

## Description

Register the feature as a plugin following the shipped pattern exactly — identifier, display name key,
universal applicability, an intent contribution and a presentation view — and own the session view and
lifecycle: start on appear, stop on close, pause in the background, resume on foreground. One
deliberate divergence from the template: the plugin must **not** guard on provider availability, because
the feature must open with no key and no network.

Source: `Services/Plugins/` `LiveTranslatePlugin.swift` and `App/LiveTranslate/` `LiveTranslateView.swift`
under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Plugin entry and session lifecycle

  Scenario: The plugin follows the shipped pattern
    Given the shipped plugin protocol
    When the feature's plugin is inspected
    Then it declares its identifier, its display-name key, universal applicability, and an intent contribution mapping the entry phrases onto its action
    And its handler returns a spoken-and-presented result and its presentation view builds the session model (FR-LCT-022)

  Scenario: The plugin opens with no provider key and no network
    Given no configured provider key and no connectivity
    When the plugin's handler runs
    Then it opens the session rather than refusing
    And it does not copy the shipped template's availability guard (unavailability surfaces later, per region, as honest degradation)

  Scenario: The shared intent vocabulary is not extended
    Given the shared intent encoder and the plugin's own prompt fragment
    When entry phrases are spoken
    Then the encoder reads this plugin's fragment
    And the encoder is not retrained and no global intent vocabulary is added

  Scenario: The feature is reachable in one clear action
    Given the app's main feature surface
    When it is displayed
    Then live translation is listed with a plain-language label and icon in the active language
    And selecting it presents the full-bleed session view (FR-LCT-001)

  Scenario: The close control is always reachable and tears the session down
    Given any feature state, including a dense overlay and an in-flight send
    When the elder uses the close control
    Then the capture session stops, the microphone is released and speech is drained
    And the assistant is returned to without further prompts

  Scenario: Backgrounding pauses rather than running a background session
    Given the feature is open
    When the app is backgrounded and then foregrounded
    Then capture pauses in the background and resumes once on foreground
    And no frames are processed while backgrounded (NFR-LCT-011)

  Scenario: The entry point costs nothing when unused
    Given the app launching without opening live translation
    When startup completes
    Then no capture session, recognition session or feature network client is created
    And the shipped features' startup behaviour is unchanged (NFR-LCT-012)

  Scenario: The surface is usable at the app's accessibility settings
    Given maximum dynamic type and the screen reader enabled
    When the feature is opened and used
    Then every control is reachable and labelled in the active language
    And the overlay hides no control (NFR-LCT-004)
```

## Implementation notes

- Follow the app's existing plugin pattern exactly; do not introduce a new plugin mechanism or a second
  navigation stack. All labels and the display-name key are catalog-backed (T-005).
- **The one deliberate divergence**: do not copy the shipped appliance helper's provider-availability
  guard. The feature must open unconditionally — no provider key, no network, no camera permission is
  required to open. Unavailability surfaces per region as an honest degraded state. Copying the guard
  would be a correctness bug, not a style choice.
- Entry uses the shared intent encoder reading this plugin's own prompt fragment: the encoder is not
  retrained and no global intent vocabulary is added (the project's known-integration-surface rule).
- Lifecycle asymmetry to respect: stop is synchronous and complete; start may end in the explanation,
  denial or unavailable state (T-008). The view renders those outcomes rather than assuming success.
  A re-entrant appear must not start a second session.
- The session view owns the consent prompt (T-015), the indicator (T-016) and the toggle (T-022) as
  chrome around the overlay — do not nest them inside the overlay.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the plugin opens with no provider key and no network (no availability guard)
- [ ] A test asserts a re-entrant appear does not start a second session
- [ ] A test asserts nothing is created at launch when the feature is not opened
- [ ] A test asserts backgrounding stops frame processing and foregrounding resumes once
- [ ] An accessibility test covers the root view and its chrome in the Nepali locale
- [ ] `ios/build.sh` passes
