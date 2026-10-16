# T-022: "Always Show Original Text" Toggle

## Metadata
- **Group:** [TG-07 — Overlay Presentation](index.md)
- **Component:** C11 + C14 — `alwaysShowOriginal` in `LiveTranslateSettings`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-020](T-020-overlay-placement.md), [T-021](T-021-overlay-view-and-states.md)
- **Blocks:** T-023, T-026
- **Requirements:** FR-LCT-017, NFR-LCT-004, NFR-LCT-012 · OD2

## Description

Give the elder one obvious control that keeps the original text visible alongside translations —
reachable by touch on the overlay and by voice — with a remembered preference that takes effect on the
next rendered frame. The toggle changes the overlay's form and nothing else: it cannot affect
translation, consent, cost, capture, or the cloud indicator.

Source: `Services/LiveTranslate/` `LiveTranslateSettings.swift` and the overlay's touch entry point
under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Always-show-original display preference

  Scenario: The control is reachable by touch in the overlay
    Given the elder is in live translation
    When they look for the original-text preference
    Then a labelled control is reachable by touch in the overlay chrome
    And its label is in the active language, Nepali first (FR-LCT-017)

  Scenario: Enabling keeps originals visible alongside translations
    Given the preference is off
    When the elder enables it
    Then resolved regions show the original text alongside the translation without hiding either
    And the change takes effect on the next rendered frame, without restarting the session

  Scenario: The preference survives relaunch
    Given the preference was enabled
    When the app is relaunched and the feature opens
    Then the preference is still enabled
    And it is read from the persisted settings store

  Scenario: The preference changes nothing else
    Given the preference in either state
    When a session runs
    Then translation results, consent state, cost accounting, capture behaviour and the cloud indicator are identical in both states (NFR-LCT-012)

  Scenario: The preference is never a consent or privacy control
    Given the preference in either state
    When consent is withdrawn
    Then no send occurs regardless of the preference
    And the control is not presented as affecting what leaves the device

  Scenario: A voice command and the touch control agree
    Given the elder changes the preference by voice
    When the overlay renders next
    Then the touch control reflects the same state
    And the two cannot disagree (both paths write the same setting)
```

## Implementation notes

- Persist as a boolean under the declared preference key through the shipped `UserDefaults` precedent
  (the same pattern as the persisted app language): this is a UI preference containing no user content,
  so it does **not** go on the encrypted file channel.
- Default is `false` (smart mix on), the design's nominal value, confirmed at the first device demo
  (OD2, T-030). Do not change the default here.
- The control must be reachable by touch **and** by voice: the voice path is the `set-show-original`
  command (T-023), and both must write the same setting.
- Keep it out of the consent and indicator surfaces: grouping it there would imply it affects egress.
  It cannot hide or show the cloud indicator (T-016).
- The overlay honours the setting when it renders; the placement contract does not change with it
  (T-020).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the preference round-trips across a simulated relaunch
- [ ] A test asserts translation, consent, cost and indicator behaviour are identical in both states
- [ ] A test asserts the touch control and the voice command write the same setting
- [ ] `ios/build.sh` passes
