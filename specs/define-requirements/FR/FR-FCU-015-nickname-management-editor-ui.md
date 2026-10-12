# FR-FCU-015: Family-editor nickname management UI

## Metadata
- **Area:** Nicknames / Editor UI
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 3 (multiple nicknames per family contact, "e.g. sanu, syanu, Devanagari forms"); workflow `define-requirements` scope comment (ask 3 UI: "family editor photo setter and nickname management"; "ne/en copy for all new UI"); Feature Constraints 11 (localisation) and 2 (migration); integration surface: `FamilyContactsSettingsView` (`SettingsView.swift:1529`; wizard nickname step :2575 — currently a single free-text field), `AppCoordinator` plumbing (`addFamilyContact` :6515, `updateFamilyContact` :6566), `FamilyContactValidation` (save-gate; extended only if design makes new fields gate Save — today the email rule is the only gate).

## Description
The family editor **must** let the family member manage multiple nicknames/name variations per contact:

- Add entries, edit entries, remove entries — the exact control shape (list editor, chips, add-field) is design-level; the capability binds.
- The legacy single nickname **pre-populates** the new control (migration visible; the family member does not re-enter it).
- Saving writes through the normal store path (`AppCoordinator` plumbing → `FamilyContactStore`) and takes effect immediately in search and voice resolution — no restart, no stale index.
- A removed entry stops matching immediately in both surfaces.
- The management surface lives with the family contact management in Settings (house placement: the family editor), localized ne/en (NFR-FCU-004) and accessible per the house standards (NFR-FCU-005).
- Save-gate rules (`FamilyContactValidation.issue`) are extended only if design makes the new fields gate Save; migrating a legacy contact and saving without edits must never be blocked by a new rule.

## Acceptance criteria

```gherkin
Feature: Nickname management in the family editor

  Scenario: Add two variations and use them immediately
    Given the family member edits a contact
    When they add the nicknames "sanu" and "सानु" and save
    Then both are stored
    And both are immediately matchable in search and in voice resolution

  Scenario: Editing and removing entries takes effect immediately
    Given a contact with nicknames "sanu" and "syanu"
    When the family member removes "syanu" and saves
    Then "syanu" no longer matches in search or voice
    And "sanu" still matches

  Scenario: A legacy contact opens with its nickname pre-populated
    Given a contact saved with the old single nickname field
    When the editor opens it
    Then the old nickname appears as one nickname entry
    And saving without changes preserves it (no loss)
```

## Related
- FR: FR-FCU-011 (storage/migration), FR-FCU-012 (search), FR-FCU-013 (voice), FR-FCU-001 (the link add flow shares this editor)
- NFR: NFR-FCU-004 (localisation ne/en), NFR-FCU-005 (accessibility), NFR-FCU-006 (migration compatibility)
