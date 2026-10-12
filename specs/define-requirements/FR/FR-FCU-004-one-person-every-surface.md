# FR-FCU-004: One person across every people surface — call list, voice resolution, missed-call correlation

## Metadata
- **Area:** Identity / Cross-surface
- **Priority:** MUST
- **Source:** Feature constitution Link Identity & Dedupe Contract binding property 1 ("A linked (family ↔ system) pair is ONE person everywhere: unified search results, the call list's family rows, voice call resolution, and missed-call correlation — never two rows, for any query"); Feature Constraint 6 ("One person, one row"); integration surfaces: `CallView` (`ios/ElderlyAssistant/App/LeafViews.swift:918`; family rows :1747; `UnifiedContactResultRow` :2288), `ContactResolver` (`Services/Intents/ContactResolver.swift`), `MissedCallContactResolver` ("Number→person correlation must respect links so dial-back renders one person").

## Description
A linked pair **must** render and resolve as ONE person in every surface that shows or resolves people:

- **Unified search**: exactly one row per linked person (FR-FCU-003).
- **The call list**: the person appears once — no duplicate tile/row is introduced by the system twin, and double-linking is prevented at creation (FR-FCU-001).
- **Voice call resolution**: a spoken name, nickname/variation, relationship or number matching either side of the linked pair resolves to the ONE family contact — the system twin never creates a spurious rival candidate, and there is exactly one confirmation.
- **Missed-call correlation** (`MissedCallContactResolver`): a missed call from any number belonging to either side of the linked pair correlates to the one person; dial-back names the person once, and the correlation must reach the linked person even when the dialed number is the system record's number rather than the family record's stored phone.
- The guarantee holds for any query/formulation: no surface may reintroduce a duplicate for a linked pair.

## Acceptance criteria

```gherkin
Feature: One person across every people surface

  Scenario: The call list shows the linked person once
    Given a system contact is linked as a family contact
    When the call list is displayed
    Then the person appears exactly once in the family rows
    And no book twin of the same person is presented as a second person

  Scenario: Voice resolution reaches the one linked person, not a rival twin
    Given a family contact linked to a system record of the same person
    When the user says "call <name of either side>"
    Then the one family contact is resolved
    And exactly one confirmation is spoken — the system twin creates no ambiguity

  Scenario: A missed call from the system record's number dials back as the one person
    Given a linked pair
    And a missed call recorded from the system record's number
    When the missed call is displayed
    Then it names the one linked person
    And dial-back targets that one person, not a second entry
```

## Related
- FR: FR-FCU-001 (no double-linking), FR-FCU-003 (search dedupe), FR-FCU-013 (voice nickname matching), FR-FCU-014 (ambiguity safety)
- NFR: NFR-FCU-002 (log safety on resolution paths), NFR-FCU-009 (test gate: `MissedCallContactResolverTests`)
