# NFR-RIE-006: Migration compatibility — pre-feature payloads load; unknown kinds degrade honestly

## Metadata
- **Category:** Reliability / Compatibility
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 3 (new model fields optional with custom-decoder defaults; pre-existing `RoutineEntry` and `EventExtras` payloads must keep loading; never lose a household's reminder list or event index to a missing key; existing `decodeIfPresent` patterns are the precedent); §Feature Constraints 4.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract property 3, §Feature Constraints 4. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:135–145`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:41–45`.

## Description
New model fields **must** be optional with custom-decoder defaults (the `decodeIfPresent` precedent). One hundred per cent of pre-feature `RoutineEntry` and `EventExtras` payloads **must** decode unchanged: reminder lists and event indexes **must never** be lost to a missing or unknown key. A payload carrying an unknown or future instruction kind **must** decode without throwing, preserve all other fields, and present the honest unsupported state (no fake control; FR-RIE-024) rather than failing the owner. No migration **must** require rewriting or re-saving existing payloads.

Measurable targets: 100% of captured pre-feature fixtures decode with their original fields intact; 0 data-loss cases; 0 throws on an unknown kind; 0 forced rewrites.

## Acceptance criteria

```gherkin
Feature: Existing reminders and events survive the model change

  Scenario: A pre-feature routine payload still loads
    Given a captured pre-feature RoutineEntry payload with no instruction keys
    When the app decodes it
    Then all original fields are intact
    And the household's reminder list is preserved

  Scenario: A pre-feature event payload still loads
    Given a captured pre-feature EventExtras payload with only photoFilename
    When the app decodes it
    Then the event index is preserved
    And the event remains usable

  Scenario: An unknown future kind degrades honestly (edge)
    Given a payload carrying an instruction kind this release does not understand
    When the app decodes it
    Then decoding does not throw
    And the other entry/event fields remain intact
    And the entry remains usable with no fake instruction control
```

## Related
- FR: FR-RIE-001 (model), FR-RIE-024 (honest capability surface)
