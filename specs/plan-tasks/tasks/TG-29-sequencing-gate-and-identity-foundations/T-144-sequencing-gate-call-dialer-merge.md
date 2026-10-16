# T-144: Sequencing gate — call-dialer merge verification and master merge

## Metadata
- **Group:** [TG-29 — Sequencing Gate and Identity Foundations](index.md)
- **Component:** Delivery sequencing gate (NFR-FCU-008)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on**: —
- **Blocks:** [T-145](T-145-family-contact-identity-model-and-nicknames.md), [T-147](T-147-localisation-keys-and-usage-disclosure.md), [T-148](../TG-30-contacts-access-link-verification-and-matching/T-148-contacts-access-limited-gate.md), [T-149](../TG-30-contacts-access-link-verification-and-matching/T-149-system-contact-link-service.md), [T-152](../TG-30-contacts-access-link-verification-and-matching/T-152-unified-search-tiers-and-dedupe.md), [T-154](../TG-31-write-seam-and-coordinator-integration/T-154-system-contact-photo-writer.md), [T-156](../TG-31-write-seam-and-coordinator-integration/T-156-coordinator-identity-and-link-refresh.md), [T-157](../TG-31-write-seam-and-coordinator-integration/T-157-coordinator-face-identity.md), [T-158](../TG-31-write-seam-and-coordinator-integration/T-158-link-unlink-seam-and-missed-call-names.md), [T-159](../TG-32-editor-and-call-surface-ui/T-159-wizard-find-and-link-steps.md), [T-160](../TG-32-editor-and-call-surface-ui/T-160-wizard-photo-step-and-save.md), [T-161](../TG-32-editor-and-call-surface-ui/T-161-callview-faces-and-caption.md), [T-162](../TG-32-editor-and-call-surface-ui/T-162-family-list-link-chip-and-face-migration.md), [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [NFR-FCU-008](../../../define-requirements/NFR/NFR-FCU-008-delivery-sequencing-call-dialer.md), [NFR-FCU-009](../../../define-requirements/NFR/NFR-FCU-009-test-and-release-gates.md)

## Description
Verify that the call-dialer workstream is merged to master and then merge master into `feat/family-contacts-unify` BEFORE any task touches shared surfaces (AppCoordinator, wizard files, LeafViews, SettingsView/CallingSettingsView-adjacent surfaces). This is the NFR-FCU-008 sequencing gate that protects the union of the call-dialer changes with the family-contacts changes.

## Acceptance criteria

```gherkin
Feature: Call-dialer sequencing gate

  Scenario: Call-dialer work is merged and master is integrated
    Given the call-dialer workstream PR is merged to master
    And `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` exists on master
    When master is merged into `feat/family-contacts-unify`
    Then the merge completes in the feature worktree
    And the merged tree builds (typecheck) with the existing frozen call-dialer tests passing

  Scenario: Call-dialer work is NOT yet merged
    Given the call-dialer workstream is not merged to master
    Or `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` does not exist on master
    When the gate runs
    Then it reports BLOCKED with the missing evidence identified
    And no shared-surface task (AppCoordinator, LeafViews, wizard, SettingsView-adjacent) starts
```

## Implementation notes
- Read-only checks first: run the call-dialer verification against master, then `git merge origin/master` inside the feature worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`). Resolve conflicts inside the worktree only.
- Existence check target: `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` — the directory `ios/EarlyAssistant/Services/Calls/` does not exist on the feature branch until master is merged.
- Record, in the completion notes: (a) the master merge commit id, (b) the list of conflict files resolved, (c) the frozen call-dialer test suites re-run as the merge gate, (d) any upstream commits that moved the integration-surface line anchors referenced by `specs/family-contacts-unify/constitution.md` (AppCoordinator :937/:6492/:6515/:6566/:6633, LeafViews, SettingsView, Info.plist :115).
- NFR-FCU-008 is a MUST: this gate is not advisory. If blocked, stop and report; do not proceed on shared surfaces.
- No feature source edits in this unit — it is a verification + merge commit unit.

## Definition of done
- [ ] Call-dialer merge evidence captured (merge commit on master + `ios/.../Services/Calls/CallChannelChain.swift` present)
- [ ] Master merged into `feat/family-contacts-unify` in the feature worktree
- [ ] Merged tree builds and the frozen call-dialer suites pass (focused gate, not the full suite)
- [ ] Line-anchor drift note written into the completion notes for downstream units
- [ ] Code reviewed and merged (paired review, confidence ≥ 0.85)
