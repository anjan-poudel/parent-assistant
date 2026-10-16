# T-143: DV-1..DV-5 protocol and record (FR-MTC-020) — PROTOCOL

## Metadata
- **Group:** [TG-28 — Acceptance, Evidence and Device Protocol](../index.md)
- **Component:** deliverable `specs/MTC-device-validation-protocol.md` (new document)
- **Agent:** dev
- **Effort:** S (1 day)
- **Risk:** MEDIUM
- **Depends on:** [T-136](../TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md), [T-138](../TG-27-observability-release-gate-and-security-evidence/T-138-release-log-gate-dialogue-roots.md)
- **Blocks:** — (gates final sign-off)
- **Requirements:** [FR-MTC-020](../../../../define-requirements/FR/FR-MTC-020-device-validation-completion-gate.md), [NFR-MTC-007](../../../../define-requirements/NFR/NFR-MTC-007-sustained-multi-turn-stability.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)
- **Task type:** PROTOCOL — authoring is agent work; execution is owner/device-dependent

## Description
Author the device-validation protocol and record for DV-1..DV-5: verbatim item
text from the constitution and design-l1, preconditions (with the outstanding
Phase 0 PR #156 smoke as step zero), per-item steps and pass criteria, the
per-session record format (date, device, build, dialogue transcript, outcome,
JetsamEvent pull) and the completion gate (any failed item blocks final
sign-off until fixed and re-run). The run itself happens on Anzaan, performed
by the owner; this task's deliverable is the protocol and the recording
structure, plus the completed record when the run occurs.

## Acceptance criteria

```gherkin
Feature: Device-validation protocol and record

  Scenario: The protocol covers all five device items
    Given the DV plan in the constitution and design-l1 §6
    When the protocol is authored
    Then DV-1..DV-5 appear with their verbatim item text, preconditions, steps and pass criteria
    And the record fields are defined per item (date, device, build, transcript, outcome, evidence pull)

  Scenario: The Phase 0 prerequisite gates the run
    Given the outstanding PR #156 device smoke
    When the protocol's step zero is read
    Then the smoke must pass before any DV item runs
    And a failed step zero stops the session without partial results

  Scenario: A failed item blocks final sign-off
    Given a DV item whose record shows a failure
    When the completion gate is evaluated
    Then sign-off remains blocked until a fix and a re-run are recorded (FR-MTC-020)

  Scenario: The run leaves no jetsam behind
    Given a completed device session covering the multi-turn dialogue
    When the record is reviewed
    Then a JetsamEvent pull after the session is attached (NFR-MTC-007)
    And no new jetsam event for the app appears in the pull
```

## Implementation notes
- Adopt the DV-1..DV-5 item wording verbatim from the constitution's DV table
  and design-l1 §6; do not paraphrase pass criteria.
- Step zero is the Phase 0 PR #156 smoke (conversation → no jetsam →
  JetsamEvent pull), which is outstanding at planning time; the protocol
  records it as a hard prerequisite, not a task.
- The record accumulates in the protocol document (or an appended record
  section) with one block per session; each block references the build
  (bundle version / commit) and the evidence pull.
- Device dependence: mark the execution block clearly so the workflow's final
  review treats missing execution as an open gate item, not a missing
  deliverable; the deliverable is complete when the protocol exists and the
  record structure is validated.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by the protocol structure and its checks
- [ ] `specs/MTC-device-validation-protocol.md` exists with DV-1..DV-5, step zero and the record format
- [ ] Phase 0 prerequisite recorded as step zero (PR #156 smoke outstanding)
- [ ] Execution marked owner/device-dependent; the completed record is verified at final sign-off before the gate can pass
