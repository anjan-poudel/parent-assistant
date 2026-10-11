# FR-FCU-016: Feasibility honesty — the three asks reported explicitly, no silent drop

## Metadata
- **Area:** Delivery / Feasibility Reporting
- **Priority:** MUST
- **Source:** Owner request 2026-10-12 — "If not feasible, tell the owner" (feasibility honesty is itself an owner requirement); feature constitution Feature Constraint 12 ("If any of the three asks proves infeasible on iOS (e.g. the write-permission model), the deliverable states it explicitly for the owner — no silent drop (the owner asked to be told)") and Success Criteria ("Any infeasible ask is stated explicitly for the owner"); workflow design-l1 scope comment ("Feasibility honesty: if any of the three asks is not feasible on the target iOS … the design records it explicitly for the owner — no silent drop"). The three pre-authorized fallbacks are recorded in the constitution (LINK dedupe; PHOTO app-local fallback; NICKNAMES store-as-entered).

## Description
The feature's design and sign-off artifacts **must** state, explicitly and per ask (LINK, PHOTO unification, NICKNAMES), whether each is feasible and delivered as specified:

- The statement is part of the design record from design-l1 forward and of the final sign-off record, so the owner can act on it at the T1 story gate and the T2 sign-off.
- Any infeasible or partially infeasible ask is **named**, with: the ask, the platform/technical constraint, the behavior actually delivered, and the pre-authorized fallback taken — no silent drop and no claim of delivery.
- A partially infeasible sub-capability (e.g. writes under limited access, or write support on a specific iOS version) is reported as a bounded behavior with its honest fallback — neither dropped nor overstated as fully delivered.
- Nothing about the three asks may be silently omitted from the report.

## Acceptance criteria

```gherkin
Feature: Feasibility honesty for the three owner asks

  Scenario: All three asks feasible — the report says so with evidence
    Given LINK, PHOTO unification and NICKNAMES are all feasible as specified
    When the design and sign-off artifacts are produced
    Then each ask is stated as delivered
    And evidence pointers (design sections, tests, DV items) are cited

  Scenario: An infeasible ask is named with its fallback (failure)
    Given one of the three asks cannot be delivered as specified on the target iOS
    When the design record and final sign-off are produced
    Then that ask is named explicitly
    And the platform constraint and the fallback actually taken are stated
    And the feature does not claim the ask delivered

  Scenario: A partially infeasible sub-capability is bounded, not dropped
    Given a sub-capability (e.g. the write under limited access) delivers only conditionally
    When the report is produced
    Then the limitation is stated as a bounded behavior with its honest fallback
    And it is neither omitted nor overstated
```

## Related
- FR: FR-FCU-009 (the authorization case most likely to be bounded), FR-FCU-010 (fallback honesty), FR-FCU-017 (the DV record accompanies the statement)
- NFR: NFR-FCU-009 (gate mechanics carrying the statement to final sign-off)
