# FR-FCU-007: Photo display precedence — system photo, then app-local, then initials

## Metadata
- **Area:** Photo / Display
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 2 ("pull photos from system contacts for display"); feature constitution Photo Unification Contract binding property 3 ("Display precedence: the system contact's photo when present, else the app-local `photoFilename` thumbnail, else the existing initials avatar") and Success Criteria ("The displayed photo reflects the system contact when one is present"); DV-3. Integration surfaces: `AppCoordinator.contactPhoto(for:)` (AppCoordinator.swift:6492), `ContactPhotoStore.load(named:)`, `ContactTile` / `UnifiedContactResultRow` / family editor rows (`FamilyContactsSettingsView` contact rows + `DownsampledImageCache`), `FaceAvatar` (initials fallback).

## Description
Wherever the app displays a family contact's face (family editor rows, call-list tiles, unified search result rows for family contacts), the displayed photo **must** follow the precedence:

1. The system contact's photo, when one is present and readable;
2. else the app-local `ContactPhotoStore` thumbnail (`photoFilename`);
3. else the existing initials avatar (`FaceAvatar`).

Binding properties:

- The precedence applies to a family contact with an established system counterpart — the linked record (FR-FCU-002); whether a number match may establish the counterpart for an unlinked contact is design-level (recorded in the assumptions), not required here.
- The display reflects the current system photo on refresh; no full-size decode regression — the existing downsampling path (`DownsampledImageCache`) is reused, keeping image work off the body as today.
- A missing, unreadable or removed system photo falls back silently to the app-local photo, then the initials avatar — never an error state for either user.
- Non-family book rows keep today's rendering (initials avatar, no photo) — unchanged by this feature.

## Acceptance criteria

```gherkin
Feature: Photo display precedence for family contacts

  Scenario: The system contact's photo wins when present
    Given a linked family contact whose system record has a photo
    And the family contact also has an app-local photo
    When the family row/tile is displayed
    Then the system contact's photo is shown

  Scenario: No system photo — the app-local photo is shown
    Given a linked family contact whose system record has no photo
    And the family contact has an app-local photo
    When the family row/tile is displayed
    Then the app-local photo is shown (today's behavior preserved)

  Scenario: Neither photo exists — the initials avatar is shown
    Given a family contact with no system photo and no app-local photo
    When the family row/tile is displayed
    Then the existing initials avatar is shown
    And no error or placeholder failure state appears
```

## Related
- FR: FR-FCU-008 (write path), FR-FCU-009 (authorization), FR-FCU-010 (fallback)
- NFR: NFR-FCU-002 (photo data never logged), NFR-FCU-005 (accessibility on photo surfaces)
