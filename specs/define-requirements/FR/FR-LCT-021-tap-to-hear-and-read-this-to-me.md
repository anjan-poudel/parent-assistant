# FR-LCT-021: Tap-to-hear and "read this to me"

## Metadata
- **Area:** Voice Output
- **Priority:** MUST
- **Source:** Design §1, §4.6, §6; feature constitution "Scope" (tap-to-hear and "read this to me" via the existing Piper voices)

## Description
The system **must** support hearing translations through the existing on-device speech stack
(`SpeakQueue` with the active-language Piper voice):

- **tap-to-hear**: tapping a region's bubble speaks that region's translation (tap target ≥ 44 pt);
- **"read this to me"**: a session voice command that speaks the visible regions' translations
  **top-to-bottom** in screen order; "stop" halts the reading;
- auto-speak of every new translation is a **non-goal** — nothing is spoken without an explicit
  tap or command (design §1 non-goals, to avoid noise in multi-label scenes);
- if speech fails, the visual translation **must** remain visible and no retry loop may start
  (existing `SpeakQueue` degradation).

## Acceptance criteria

```gherkin
Feature: Hearing translations

  Scenario: Tap-to-hear speaks one region
    Given a region has a resolved translation
    When the elder taps its bubble
    Then the translation is spoken in the active language
    And no other region is spoken

  Scenario: "Read this to me" reads visible regions top-to-bottom
    Given several stable regions with resolved translations are visible
    When the elder says "read this to me"
    Then the translations are spoken in top-to-bottom screen order
    And saying "stop" halts the reading

  Scenario: Nothing is spoken automatically
    Given a new region gains a resolved translation
    When the elder does not tap or ask
    Then no speech is produced

  Scenario: Speech failure does not remove the visual translation
    Given a tap-to-hear request fails in the speech stack
    Then the visual translation remains visible
    And no retry loop is started
```

## Related
- FR: FR-LCT-018 (overlay states), FR-LCT-022 (session commands)
- NFR: NFR-LCT-003 (accessibility), NFR-LCT-004 (localisation)
- Depends on: FR-LCT-005 (stable regions)
