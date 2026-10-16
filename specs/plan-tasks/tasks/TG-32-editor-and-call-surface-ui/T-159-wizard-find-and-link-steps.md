# T-159: Wizard find step — link section, prefill, steering and claimant guard

## Metadata
- **Group:** [TG-32 — Editor and Call-Surface UI](index.md)
- **Component:** OnboardingWizard / family find step
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-152 ([T-152](../TG-30-contacts-access-link-verification-and-matching/T-152-unified-search-tiers-and-dedupe.md)), T-158 ([T-158](../TG-31-write-seam-and-coordinator-integration/T-158-link-unlink-seam-and-missed-call-names.md))
- **Blocks:** [T-160](T-160-wizard-photo-step-and-save.md)
- **Requirements:** [FR-FCU-001](../../../define-requirements/FR/FR-FCU-001-link-system-contact-as-family.md), [FR-FCU-003](../../../define-requirements/FR/FR-FCU-003-link-aware-dedupe-unified-search.md), [FR-FCU-012](../../../define-requirements/FR/FR-FCU-012-nickname-matching-in-search.md), [NFR-FCU-005](../../../define-requirements/NFR/NFR-FCU-005-accessibility-voice-first.md)

## Description
Extend the wizard find step per design L2 §2.2/2.3: the link section offering a verified system-contact match, prefill from the chosen contact, the steering/claimant logic (`storedClaimant`) preventing a second family contact from silently claiming an already-linked number, and the steering callback plumbed through its parent call site. Includes the UnifiedContactSearch drift pin (tier-list parity test) so the wizard's tier presentation cannot drift from the search engine.

## Acceptance criteria

```gherkin
Feature: Wizard find step with linking

  Scenario: Verified system match offers the link section
    Given a system contact matching the typed name with a verified identity
    When the find step renders results
    Then the link section offers "link this contact" with the verified match
    And choosing it prefills the family contact fields from the system contact

  Scenario: Nickname search surfaces the contact
    Given a family contact with nickname "आमा"
    When "आमा" is typed in the find step
    Then the result appears via the nickname tier (FR-FCU-012)

  Scenario: Steering guard (storedClaimant)
    Given a number already linked to family contact A
    When the user attempts to link the same number to a new contact B
    Then the step steers to the existing claimant A (storedClaimant) instead of silently re-linking
    And the steering callback fires through the parent call site

  Scenario: Tier-list drift pin
    Given the FamilyMatchTier list
    When the wizard's presentation mapping is compared to the search engine's list
    Then they match exactly (drift test)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Find step failure handling

  Scenario: No match found
    Given the typed name matches nothing
    When the step renders
    Then it shows the honest empty state and offers to proceed with manual entry — no crash, no dead-end

  Scenario: Contacts access denied or limited
    Given contacts access is denied (or limited with no matching chosen contact)
    When the find step renders
    Then the link section is absent or disabled with the honest explanation (never an empty but enabled section)

  Scenario: Voice-first accessibility
    Given a screen-reader user on the find step
    When results and the link section render
    Then all targets are >= 44pt and the content is reachable and labelled (NFR-FCU-005)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/OnboardingWizardView.swift` (find step; design L2 §2.2/2.3; the nickname-step restructure from T-145 is already in place) plus the steering callback's parent call site (`ios/ElderlyAssistant/App/ProfileInterviewSteps.swift` if the flow routes there — confirm from the merge diff); tests extending the wizard/onboarding suites plus the drift pin test.
- Uses `UnifiedContactSearch.search(index:)` from T-152 (already carrying the nickname tier) and `setFamilyContactLink` from T-158; no store or address-book access directly from the view.
- Localisation: use only the T-147 frozen keys; no inline user-facing strings (NFR-FCU-004).
- Shared-surface unit (post-T-144).
- Unit gate (focused): wizard find-step suite + drift pin + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused wizard find-step suite + drift pin + typecheck
- [ ] storedClaimant steering + callback pinned
- [ ] >= 44pt targets and screen-reader labels on new controls (NFR-FCU-005)
- [ ] No inline user-facing strings (frozen L10n keys only)
- [ ] No PII in logs
