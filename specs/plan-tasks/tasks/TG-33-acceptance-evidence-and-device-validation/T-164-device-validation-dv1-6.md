# T-164: DV-1..6 device validation protocol and record (completion gate)

## Metadata
- **Group:** [TG-33 — Acceptance, Evidence and Device Validation](index.md)
- **Component:** Device validation (Anzaan)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on**: T-163 ([T-163](T-163-acceptance-and-release-gates.md))
- **Blocks:** —
- **Requirements:** [FR-FCU-017](../../../define-requirements/FR/FR-FCU-017-device-validation-completion-gate.md), [FR-FCU-016](../../../define-requirements/FR/FR-FCU-016-feasibility-honesty-reporting.md), [NFR-FCU-005](../../../define-requirements/NFR/NFR-FCU-005-accessibility-voice-first.md)

## Description
Produce the DV-1..6 device-validation protocol and record for the Anzaan device session — and execute it when a session is available. DV-1..6 are the completion gate for the feature (FR-FCU-017): the feature is not complete until the checklist is recorded and passed. If no device session is available, this task must report BLOCKED honestly — never a fabricated pass.

## Acceptance criteria

```gherkin
Feature: Device validation completion gate

  Scenario: Protocol and record prepared
    Given the DV-1..6 checklist as defined in the feature constitution
    When the protocol is written
    Then every DV item has: exact steps, expected outcomes, and a record slot for pass/fail/blocked
    And the protocol can be executed in one session without authoring anything on the device

  Scenario: Session executes the checklist
    Given an available Anzaan device session and the built app
    When DV-1..6 are executed step by step
    Then each item is recorded as PASS with the observed result (per FR-FCU-017)
    And any FAIL is recorded verbatim with reproduction steps — not retried away

  Scenario: No session available
    Given no Anzaan device session is available
    When this task completes
    Then the record reports each DV item as BLOCKED (not PASS), with the reason
    And the feature completion status is explicitly "device validation outstanding" (honest reporting per FR-FCU-016)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Device validation failure handling

  Scenario: A DV item fails on device
    Given a DV step produces an unexpected outcome
    When it is recorded
    Then the failure is logged with reproduction steps, the item stays FAIL in the record
    And the completion gate is not marked passed

  Scenario: Partial session
    Given the session ends after DV-1..3
    When the record is finalized
    Then executed items carry observed results and the remainder is BLOCKED — no inference, no filling from unit tests
```

## Implementation notes
- The checklist content is DV-1..6 exactly as recorded in `specs/family-contacts-unify/constitution.md` — execute as written; do not re-interpret or extend the checklist in this task.
- Build/install procedure: use the house device-install recipe (bundle id derived from the built artifact; `ios/build.sh` is canonical).
- Accessibility spot-checks belong to the DV items that specify them (NFR-FCU-005); record what was observed.
- The record feeds the final-sign-off gate comments (DV-1..6); keep it structured (per-item status + evidence) so the sign-off can verify mechanically.
- This task cannot be marked complete with fabricated results; BLOCKED-with-reason is an acceptable terminal state for the session-less case, but the feature remains outstanding until a session runs.

## Definition of done
- [ ] Protocol written with per-item steps, expected outcomes and record slots
- [ ] If session available: all DV-1..6 recorded with observed results (PASS/FAIL/BLOCKED verbatim)
- [ ] If session unavailable: every item recorded BLOCKED with the reason; no PASS claimed
- [ ] Record structured for mechanical verification at final-sign-off
- [ ] Any FAIL has reproduction steps and the completion gate remains open
