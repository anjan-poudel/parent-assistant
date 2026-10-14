# FR-CNR-024: Feasibility honesty — every leg reported explicitly, no silent drop

## Metadata
- **Area:** Delivery / Feasibility Reporting
- **Priority:** MUST
- **Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 4 ("**Feasibility honesty.** If fixed-seed temp ~0.3 does not hold reproducibly on any device tier (GBNF interplay, Metal backends), the design records it explicitly for the owner — no silent drop (workflow, design-l1)"); feature constitution OD-1 (the same clause repeated for the design decision) and Open Decisions preamble; workflow design-l1 task comment ("if any leg is not feasible … the design records it explicitly for the owner — no silent drop"); project constitution Agent Principles ("No silent stubs — deferred work throws explicit errors, never silently returns success"); the owner's standing request to be told when something is not feasible.

## Description
If any leg of this feature proves infeasible or only partially feasible, the deliverable **must** state it explicitly for the owner — the affected leg, the evidence, the narrower behaviour that ships instead, and what the user experience loses — rather than silently narrowing, deferring or dropping it. Named legs that must be reported honestly if they do not hold:

- **Chat sampling feasibility**: fixed-seed temperature ~0.3 reproducible on every supported device tier, including any GBNF interplay and Metal-backend effects (FR-CNR-003).
- **Grammar-guard coverage**: whether the deterministic checks catch the violations the spec names, and where they cannot (the guard verifies; where it cannot verify, that gap is reported).
- **Cloud chat routing**: whether consent + indicator + revocation work as specified on device, including the escalation path (FR-CNR-009).
- **Training outcome**: whether the corpus and gates reach their thresholds, and if not, what the measured shortfall is (FR-CNR-020/021).
- **4B tier admission**: whether a device tier can serve the larger variant within the latency/memory envelope (FR-CNR-028).
- **Any P0→P1→P2 sequencing deviation**: the owner's directive puts the full scope in this run, P0 first; a deviation from that ordering is reported, not assumed (feature OD-3).

The report is part of the final sign-off package, and a "not feasible" statement is an acceptable outcome — a silent drop is not.

## Acceptance criteria

```gherkin
Feature: Infeasibility is reported, never absorbed

  Scenario: A leg is feasible and ships as specified
    Given a leg that meets its requirement on the reference device
    When the sign-off package is assembled
    Then the leg is reported as delivered with its evidence

  Scenario: A leg is only partially feasible
    Given a leg that cannot hold as specified (e.g. temperature ~0.3 does not reproduce on a tier)
    When the deliverable is reported
    Then the limitation is stated explicitly for the owner
    And the narrower behaviour that ships is described along with what the user loses
    And no requirement is silently narrowed

  Scenario: A leg is dropped without a statement (failure)
    Given a shipped build in which a specified leg is absent, narrowed or deferred
    When the sign-off package is reviewed
    Then the absence is reported as a defect against this requirement
    And the owner statement is produced before sign-off completes
```

## Related
- FR: FR-CNR-003 (sampling feasibility), FR-CNR-020 (gate outcomes), FR-CNR-025 (the DV record), FR-CNR-028 (tier admission)
- NFR: NFR-CNR-011 (final-sign-off gates)
