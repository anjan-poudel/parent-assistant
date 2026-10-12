# FR-FCU-010: Non-writable fallback — no loss, no false success, no crash

## Metadata
- **Area:** Photo / Fallback & Degradation
- **Priority:** MUST
- **Source:** Feature constitution Photo Unification Contract binding properties 4 and 6 ("when the system contact is not writable — permission denied, limited access, or a read-only record — the picked photo stays app-local exactly as today (`ContactPhotoStore`), with honest UI state. Never crash; never lose the picked photo; never claim an unverified write succeeded"; "photo operations never surface a throw or a failure dialog… the elderly user is never asked to reason about address-book authorization") and Feature Constraint 4 (the pre-authorized fallback); DV-4; workflow `security-test` focus (write-failure and permission-denied paths never lose the picked photo, never claim unverified success).

## Description
When the system contact is not writable — permission denied, limited access without this contact, a read-only record, a save failure — **or there is no link at all**:

- The picked photo stays **app-local exactly as today**: stored through `ContactPhotoStore` (`photoFilename` reference; ≤512px JPEG; non-throwing, best-effort by design). The existing photo stack's behavior is preserved, not redesigned.
- The photo is **never lost**, and the UI **never claims an unverified success** (FR-FCU-009).
- The write failure is a **no-op on the system side** (FR-FCU-008) and produces **no failure dialog** for the elderly user — consistent with the photo stack never throwing and never surfacing failures to that audience.
- **No crash** and no thrown error is surfaced anywhere; the fallback is a **labeled state** where the family member needs the honesty (the editor), and silent/neutral on the parent's surfaces.
- Display follows FR-FCU-007 precedence: the app-local photo shows; the initials avatar if none.
- A later photo set with writable access can update the system record; whether the earlier app-local photo is retroactively pushed is design-level (not required).

## Acceptance criteria

```gherkin
Feature: App-local fallback when the system contact is not writable

  Scenario: Write access denied — the picked photo stays app-local, nothing lost
    Given a linked contact whose system record is not writable (denied/limited/read-only)
    When the family member sets a photo
    Then the photo is stored app-local exactly as today
    And it is displayed per the photo precedence
    And an honest state identifies the photo as kept on this phone
    And nothing crashes and no photo is lost

  Scenario: Save failure keeps the app-local photo, no false success (failure)
    Given a writable-looking system record and a save that fails
    When the failure occurs
    Then the system record is unchanged (no-op)
    And the picked photo remains app-local
    And no success is claimed and no failure dialog interrupts the elderly user

  Scenario: No link — today's behavior exactly
    Given a family contact with no link
    When the family member sets a photo
    Then the app-local path applies exactly as before this feature
    And no error appears anywhere
```

## Related
- FR: FR-FCU-007 (display precedence), FR-FCU-008 (no-op write), FR-FCU-009 (authorization honesty)
- NFR: NFR-FCU-005 (accessibility — no authorization reasoning for the elderly user), NFR-FCU-002 (error paths log no PII)
