# FR-FCU-008: Photo write confined to the edited contact's photo

## Metadata
- **Area:** Photo / Write Path
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 2 ("when setting a contact's picture, update the system contact's photo"); feature constitution Photo Unification Contract binding properties 1 and 5 ("the app may write ONLY the edited contact's photo, via `CNContactStore`/`CNSaveRequest` — one contact at a time, no bulk rewrites, no other fields"; "The system record must never be corrupted or silently mangled; a failed write is a no-op on the system side, never a partial mutation") and Feature Constraint 5 ("`CNSaveRequest` only, photo only"); workflow `security-design-review` focus (write authority blast radius). Integration surfaces: currently no `CNSaveRequest` exists in the app — new write seam (file/name design-l1's to decide; injectable per the house pure-static seam pattern); family editor photo setter (`SettingsView.swift` `PhotosPicker` at :2485, picked-photo load :2511, photo step); `ContactPhotoStore`.

## Description
When a photo is set (or changed) for a family contact whose system record is writable and linked, the app **must** update ONLY that one system contact's photo:

- `CNContactStore`/`CNSaveRequest` usage is confined to the **edited contact's own linked record** — one contact at a time, never a bulk rewrite, never another contact. A wrong-target write must be **prevented by construction**, not merely detected afterwards.
- **No other field** of the system record is ever modified — no name, number, labels, notes or any non-photo property.
- The write carries the photo data only. The app-local `ContactPhotoStore` write continues on today's path, so the picked photo is never lost even when the system write fails (FR-FCU-010).
- A failed or rejected write is a **no-op on the system side** — the stored system record remains valid; never a partial mutation, never corruption.
- No system write is attempted for an unlinked contact (today's behavior, exactly).
- The write seam is injectable for tests (house pattern: thin platform glue, pure logic testable; `CNContactStore` is not constructible/fakeable in unit tests).

## Acceptance criteria

```gherkin
Feature: Photo write confined to the edited contact

  Scenario: Setting a photo updates only that contact's photo on the system side
    Given a linked family contact whose system record is writable
    When the family member sets or changes the contact's photo
    Then the added system record is exactly the edited contact's linked record
    And it carries only the photo change — verified by read-back
    And the app-local photo is stored as today

  Scenario: The save touches no other contact and no other field (confinement)
    Given any photo set through the editor
    When the resulting save request is inspected in tests
    Then it targets exactly one contact — the edited contact's linked record
    And it contains only the photo field
    And no bulk or multi-contact mutation exists

  Scenario: A failed write is a no-op on the system side (failure)
    Given a writable-looking system record and a save that fails
    When the failure occurs
    Then the system record is unchanged — no partial mutation, no corruption
    And the app-local photo is intact

  Scenario: An unlinked contact never triggers a system write
    Given a family contact with no link
    When the family member sets a photo
    Then the photo is stored app-local exactly as today
    And no system write is attempted
```

## Related
- FR: FR-FCU-009 (authorization states), FR-FCU-010 (fallback), FR-FCU-007 (display precedence), FR-FCU-002 (the link the write targets)
- NFR: NFR-FCU-002 (write paths never log contact content), NFR-FCU-009 (test gate: write-seam tests)
