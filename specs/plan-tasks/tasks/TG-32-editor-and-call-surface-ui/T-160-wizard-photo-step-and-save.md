# T-160: Wizard photo step, write-access cards and save flow

## Metadata
- **Group:** [TG-32 — Editor and Call-Surface UI](index.md)
- **Component:** OnboardingWizard photo step + save flow
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on**: T-159 ([T-159](T-159-wizard-find-and-link-steps.md))
- **Blocks:** [T-162](T-162-family-list-link-chip-and-face-migration.md)
- **Requirements:** [FR-FCU-007](../../../define-requirements/FR/FR-FCU-007-photo-display-precedence.md), [FR-FCU-008](../../../define-requirements/FR/FR-FCU-008-photo-write-confined-to-edited-contact.md), [FR-FCU-009](../../../define-requirements/FR/FR-FCU-009-write-authorization-honest-states.md), [FR-FCU-010](../../../define-requirements/FR/FR-FCU-010-non-writable-photo-fallback.md), [FR-FCU-015](../../../define-requirements/FR/FR-FCU-015-nickname-management-editor-ui.md)

## Description
Extend the wizard photo step and save flow per design L2 §2.4/2.6: write-access cards that explain when a photo can and cannot be written to the linked system contact, the `photoStateLine` that renders the honest outcome, the Done footer, and the nickname list editor (FR-FCU-015) with the 64-char input cap (F5). F4 decision: the `.written` state renders the label `family.photo.state.updatedInSystem`.

## Acceptance criteria

```gherkin
Feature: Wizard photo step and honest save states

  Scenario: Photo written to the linked system contact shows the honest label (F4)
    Given a linked contact with write access
    When the photo is processed, written via the T-154 writer, and read-back verified
    Then the photo step renders `family.photo.state.updatedInSystem`
    And the code comment documents this as the F4 recommended path (design-doc alignment deferred to T-165)

  Scenario: Nickname list editor
    Given the nickname step
    When the user adds and removes nicknames
    Then entries persist as a list (multi-nickname) and save with the contact (FR-FCU-015)
    And a nickname longer than 64 characters is capped at input time

  Scenario: Non-writable link shows the fallback card
    Given a linked system contact that cannot be written
    When the photo step renders
    Then the write-access card explains the non-writable state with honest copy (FR-FCU-009)
    And the save proceeds with the family photo as the display photo (FR-FCU-010)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Photo step failure handling

  Scenario: Write fails after save
    Given the writer returns a failure outcome
    When the step renders the final state
    Then the photoStateLine shows the honest failure state (never "updated in system")
    And the local family photo remains available

  Scenario: Limited access
    Given contacts access is limited and the chosen contact is outside the limited selection
    When the photo step renders
    Then the write path is disabled with the honest explanation and no write is attempted

  Scenario: Save with nothing to change
    Given no photo and no nickname change
    When the user presses Done
    Then the save is a no-op for the system contact (no empty write, no CNSaveRequest)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/OnboardingWizardView.swift` (photo/save step + Done footer; design L2 §2.4/2.6) and `ios/ElderlyAssistant/App/ProfileInterviewSteps.swift` (nickname list editor step), consuming the T-154 writer outcome mapping and `FamilyPhotoEditorState` (model from T-145, strings from T-147); tests: wizard photo-step suite + save-flow tests.
- F4: render `family.photo.state.updatedInSystem` on `.written`; add the comment noting the deliberate label vs the design-doc wording (alignment is a T-165 doc task). Do not invent a second string.
- Access gating uses T-148 `ContactsAccess` (`allowsReading`, `.limited`); write-disabled card copy must come from the frozen keys.
- Accessibility: >= 44pt targets, labelled controls, screen-reader reachable cards (NFR-FCU-005).
- Shared-surface unit (post-T-144); depends on T-159 for the step flow.
- Unit gate (focused): wizard photo-step + save-flow suites + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused wizard photo/save suites + typecheck
- [ ] F4 label rendered on `.written`; comment aligned (doc fix tracked in T-165)
- [ ] F5 64-char nickname cap enforced at input time (test-pinned)
- [ ] Honest states for written / non-writable / failed / limited (no false success)
- [ ] No inline user-facing strings; >= 44pt targets; no PII in logs
