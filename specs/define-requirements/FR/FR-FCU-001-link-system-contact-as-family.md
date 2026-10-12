# FR-FCU-001: Link a system contact as a family contact (the LINK flow)

## Metadata
- **Area:** Link / Add Flow
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 1 — "search a system contact and add it as a family contact" so the two records are ONE person; feature constitution Feature Purpose & Scope ("LINK — search a system contact and add/link it as a family contact, so the two records are ONE person and never two rows anywhere in the app") and Link Identity & Dedupe Contract binding property 1; workflow `define-requirements` scope comment (ask 1). Integration surfaces: `FamilyContactsSettingsView` (`ios/ElderlyAssistant/App/SettingsView.swift:1529`), `AddressBookDirectory` (read path; `ContactsAccess` at :245, read-only sweep `allEntries()` at :386), `FamilyContactStore`.

## Description
The family contact editor **must** let the family member search the system address book and add a found system contact as a family contact whose stored record carries an explicit LINK to that system record. Binding properties:

- The pick produces **exactly one family contact carrying the link** — from creation, the pair is one person (rendered once per FR-FCU-003/FR-FCU-004).
- Search reuses the existing system-contact read path (`AddressBookDirectory` / `SystemContactSearch`); point-of-use Contacts permission handling stays as today (honest states — `ContactsAccess`, no nagging, the app works fully if the user says no).
- The family fields (name, phone, relationship, preferences, photo) remain the app's own data on the one family record; which values are prefilled from the system record and which are asked of the family member is design-level (design-l1).
- A system contact **already linked** to an existing family contact must not be linked a second time: the flow must never create two identity records claiming one system record (steer to the existing family contact; the exact mechanics are design-level).
- When the address book cannot be consulted (permission not determined or denied), the flow shows the honest state and degrades to today's manual entry — **no phantom link** is written and nothing is silently wrong.
- The link is stored under the house migration rule (FR-FCU-002).

## Acceptance criteria

```gherkin
Feature: Add a system contact as a family contact (link)

  Scenario: Search, pick, and add a system contact as a linked family contact
    Given Contacts access allows reading the address book
    And a system contact "सीता शर्मा" exists with no family contact yet
    When the family member searches "सीता" in the family editor's add flow and picks the contact
    Then exactly one family contact is created carrying a stored link to that system record
    And the person appears once in the call list and in search results

  Scenario: An already-linked system contact cannot be linked twice
    Given a system contact is already linked to an existing family contact
    When the family member searches for it in the add flow
    Then no second family contact claiming that system record is created
    And the flow steers to the existing family contact instead

  Scenario: Address book unavailable — honest state, no phantom link (failure)
    Given Contacts access is denied or not determined
    When the family member opens the add flow
    Then the honest permission state is shown, with the point-of-use request where applicable
    And today's manual entry remains available
    And no link is stored
```

## Related
- FR: FR-FCU-002 (link storage/migration), FR-FCU-003 (link-aware dedupe), FR-FCU-004 (one person everywhere), FR-FCU-005 (unlink), FR-FCU-006 (stale-link degradation), FR-FCU-015 (editor)
- NFR: NFR-FCU-002 (PII/logs), NFR-FCU-005 (accessibility), NFR-FCU-006 (migration compatibility)
