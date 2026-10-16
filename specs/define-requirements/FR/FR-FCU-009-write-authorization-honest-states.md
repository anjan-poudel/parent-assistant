# FR-FCU-009: Write authorization — full, limited and denied are all honest states, detected not assumed

## Metadata
- **Area:** Photo / Authorization
- **Priority:** MUST
- **Source:** Feature constitution Photo Unification Contract binding property 2 ("full / limited / denied (and read-only records) are all honest states. Permission is requested at the point of use with plain-language explanation; a non-writable contact is detected, not assumed") and Feature Constraints 4–5; Safety & Compliance Delta (Write authority — the app's first write surface into the shared system address book); workflow `security-design-review` / `security-test` focus (authorization states handled honestly). Integration surfaces: `AddressBookDirectory.ContactsAccess` (:245; `.restricted` surfaced as `.denied`), `Info.plist` `NSContactsUsageDescription` (:115 — "the current copy is read/search-oriented; write disclosure must be honest when the write surface ships"), family editor photo setter; project constitution (permissions requested at the point of use with clear plain-language explanation).

## Description
The write path **must** handle authorization honestly:

- Permission is requested at the **point of use** (the family editor's photo setter), with plain-language explanation shown first — the same discipline as the existing read-side permission moments.
- **Full access, limited access** (the user granted access to selected contacts only), **denied/restricted**, and **read-only records** are all honest states. Per-record writability is **detected, not assumed**: under limited access the edited contact may not be visible or writable, and the app must find out honestly rather than assuming either way from the global permission.
- The app **must never claim an unverified write succeeded** — "updated" may be shown only after the system's save is confirmed (per design's verification; read-back or save result).
- The `NSContactsUsageDescription` copy must honestly disclose the photo-updating use before or with the write surface shipping — today's copy covers only reading/searching.
- The **elderly user is never asked to reason about address-book authorization**: any explanation or permission moment lives in the family member's editor; the parent's surfaces never show authorization dialogs or failures (FR-FCU-010 keeps the fallback neutral there).
- Denial is never nagged: with access denied, no repeating permission prompt is issued.

## Acceptance criteria

```gherkin
Feature: Honest authorization states for the photo write

  Scenario: Limited access with the edited contact writable
    Given Contacts access is limited to selected contacts
    And the edited contact is among the visible, writable ones
    When a photo is set
    Then the write proceeds and success is only shown once the save is confirmed

  Scenario: Limited access with the edited contact not writable
    Given Contacts access is limited and the edited contact is not writable under it
    When a photo is set
    Then the contact is detected as non-writable — not assumed
    And the app-local fallback applies per FR-FCU-010
    And no false success is shown

  Scenario: Access denied — no nagging, honest fallback (failure)
    Given Contacts access is denied or restricted
    When a photo is set
    Then no write is attempted or claimed
    And no repeating permission prompt is shown
    And the app-local fallback applies per FR-FCU-010

  Scenario: An unverified save is never presented as success
    Given a save the system does not confirm
    When the photo flow completes
    Then the app does not claim the system contact was updated

  Scenario: The permission copy discloses the photo-updating use
    Given the write surface ships
    When the Contacts permission prompt is read
    Then its copy plainly describes reading/searching and updating a contact's photo
```

## Related
- FR: FR-FCU-008 (write confinement), FR-FCU-010 (fallback), FR-FCU-007 (display)
- NFR: NFR-FCU-002 (CNSaveRequest failures never log raw content), NFR-FCU-005 (no authorization reasoning for the elderly user), NFR-FCU-009 (security-test SECURITY-GO evidence)
