# NFR-FCU-008: Delivery sequencing and scope separation vs call-dialer-primary-secondary

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 ("Explicitly distinct from `call-dialer-primary-secondary`; sequencing. Do not absorb or redesign it. Implementation merges master AFTER its PR merges (queue behind it), expecting conflicts in `MethodResolver.swift` / `LeafViews.swift` family-contact call surfaces") and the Sequencing Note (owner constraint); workflow header SEQUENCING block; Out of scope ("`call-dialer-primary-secondary` — explicitly distinct, in flight; do not absorb, redesign, or merge its scope"); owner instruction for this task: "Call-dialer sequencing (implementation queues behind its merge) is an NFR/constraint, not a design task here."

## Description
This feature is **explicitly distinct** from `call-dialer-primary-secondary` and must not absorb or redesign it:

- Implementation **merges master AFTER call-dialer's PR merges** (queue behind it) before implementation work starts — the scaffold base is master `8089c735`; the in-flight sibling touches the same Contacts surface (`MethodResolver.swift`, `LeafViews.swift`, `AppCoordinator.swift`, `CallingSettingsView.swift`).
- Expected conflicts in the family-contact call surfaces are resolved as a union that **preserves call-dialer's shipped behavior**; the feature's diff introduces no redesign of call-routing/dialer scope and no absorption of call-dialer's deliverables.
- If call-dialer is unmerged, implementation **waits** — no parallel edits of the conflicting surfaces.
- Measurable evidence: the implementation branch's master merge includes the call-dialer PR (git-history evidence), and the feature's diff touches the named surfaces only through the requirement seams (review evidence), with call-dialer behavior regression-checked after the merge.

## Acceptance criteria

```gherkin
Feature: Sequencing and scope separation vs call-dialer

  Scenario: Implementation starts only after the dependency merged
    Given call-dialer-primary-secondary's PR exists in flight
    When implementation of this feature begins
    Then the branch has merged master including that PR (git evidence recorded)
    And no conflicting surface was edited before that merge

  Scenario: The diff does not absorb call-dialer's scope
    Given the feature's completed diff after the merge
    When it is reviewed against call-dialer's scope
    Then no call-routing/dialer redesign is present
    And the conflicting files resolve to a union preserving call-dialer's behavior

  Scenario: Unmerged dependency blocks parallel edits (failure/guard)
    Given call-dialer's PR is not yet merged
    When implementation work is about to edit the conflicting surfaces
    Then the work waits rather than forking the surface
```

## Related
- FR: FR-FCU-013 (the `MethodResolver` nickname seam — the named conflict surface), FR-FCU-004 (`CallView` family rows)
- NFR: NFR-FCU-009 (review gates where the evidence is checked)
