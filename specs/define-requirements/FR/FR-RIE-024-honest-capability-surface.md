# FR-RIE-024: Honest capability surface — YouTube link not shipped, no fake control, room left for a later link kind

## Metadata
- **Area:** Honesty / Capability Surface
- **Priority:** MUST
- **Source:** Feature constitution OD-3 (RESOLVED 2026-10-25: YouTube links not shipped in v1; the model leaves room for a later `link` instruction kind — URL stored, not bytes, played through the existing YouTube integration with honest offline/failure handling); OD-6 (no background video claim); §Safety & Compliance Delta "No silent stubs"; root Agent Principles.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Decisions 3 and 6, §Safety & Compliance Delta, §Feature Constraints 1. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:126–145` (tolerant decode precedent); `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:41–45`.

## Description
YouTube links **must not** ship in v1 (OD-3). The caregiver UI **must** expose no YouTube/link instruction control, no URL field, and no affordance that implies a link instruction exists; no deferred capability is presented as if shipped (no silent stubs, no false success). The model **must** leave room for a later `link` instruction kind (a URL stored as a string, not bytes, to be played through the existing YouTube integration with honest offline/failure handling later) without foreclosing it. A payload carrying an unknown or future instruction kind **must** decode tolerantly and present the reminder with no fake instruction control (honest unsupported state; NFR-RIE-006). The UI **must not** claim background or cold-launch video playback (FR-RIE-019). In-app recording and library pick, which do ship, **must not** be presented as placeholders.

## Acceptance criteria

```gherkin
Feature: The UI claims only what v1 ships

  Scenario: No YouTube or link control is offered
    Given the caregiver's routine and event instruction editors
    When the available instruction controls are inspected
    Then there is no YouTube control, link control or URL field
    And no control claims a capability that is not shipped

  Scenario: A future link kind degrades honestly (edge)
    Given a payload carrying an instruction kind of "link" that this release does not support
    When the entry or event is loaded
    Then the payload decodes without failing
    And the reminder/event fields remain intact
    And no fake link or Play control is shown

  Scenario: No background video claim
    Given the video instruction UI and the feature report
    When they are inspected
    Then neither claims that video plays without opening the app
    And the foreground-only limitation is stated honestly
```

## Related
- FR: FR-RIE-001 (model), FR-RIE-019 (foreground honesty)
- NFR: NFR-RIE-006 (unknown-kind tolerance)
