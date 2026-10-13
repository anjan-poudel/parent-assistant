# NFR-FCU-005: Accessibility — voice-first capability, house touch standards, no authorization reasoning for the elderly user

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Feature constitution Photo Unification Contract binding property 6 ("the elderly user is never asked to reason about address-book authorization") and Success Criteria (voice-first resolution: "typed or spoken"); project constitution Standards (voice-first UI — every function accessible by voice without touch; ≥44×44 pt tap targets; minimum 18pt body text; localisation of all strings); Target Users (elderly, cognitive/motor challenges; family member as secondary user managing contacts). Integration surfaces: `CallView`/`UnifiedContactResultRow` (LeafViews.swift), `FamilyContactsSettingsView` (SettingsView.swift), `FaceAvatar` fallback.

## Description
The new capabilities **must** meet the house accessibility standards for this user population:

- **Voice-first**: a nickname (including a Devanagari variation) resolves and calls by voice with **zero touch** (FR-FCU-013/FR-FCU-014); the elderly user needs no new touch UI for anything this feature delivers to them.
- **Touch standards** where touch exists (the family member's editor, family rows/tiles): every new interactive control is **≥ 44×44 pt**; text uses the established appearance typography tokens so Dynamic Type grows without clipping (no fixed-point font sizes introduced); no content clipped at Accessibility XXXL.
- **No authorization reasoning**: the elderly user's surfaces never show a permission explanation, authorization dialog, or write-failure state; the photo fallback is a labeled state in the family member's editor and silent/neutral elsewhere (FR-FCU-010). The parent is never asked about the address book.
- **VoiceOver**: new controls carry accessible labels; photos are hidden from VoiceOver per the existing pattern where a label would add nothing (initials avatars keep their legacy exposure); nickname entries are readable and removable via the standard accessible interactions.

## Acceptance criteria

```gherkin
Feature: Accessibility of the new capabilities

  Scenario: A nickname call completes voice-only, with zero touch
    Given a contact with a recorded nickname
    When the user speaks the nickname and confirms by voice
    Then the call flow completes without any touch interaction

  Scenario: House touch standards hold on the new controls
    Given the family editor's new link/photo/nickname controls
    When rendered at Accessibility XXXL on the reference device
    Then every interactive control measures at least 44×44 pt
    And no label or control clips or truncates
    And text scales through the appearance typography tokens

  Scenario: No authorization reasoning is asked of the elderly user (failure-adjacent)
    Given the write falls back (denied/limited/read-only)
    When the elderly user's surfaces are displayed
    Then no authorization explanation, dialog or failure state appears
    And the photo simply shows per the display precedence
```

## Related
- FR: FR-FCU-013 (voice), FR-FCU-014 (ambiguity disambiguation is by voice), FR-FCU-010 (fallback neutrality), FR-FCU-015 (editor accessibility)
- NFR: NFR-FCU-004 (localisation of the same copy), NFR-FCU-009 (test gate)
