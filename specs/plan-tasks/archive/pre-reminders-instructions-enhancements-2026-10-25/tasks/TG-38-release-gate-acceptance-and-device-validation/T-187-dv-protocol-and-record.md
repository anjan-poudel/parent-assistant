# T-187 — DV-1..6 device-validation protocol and record (completion gate)

## Metadata
- **Group:** [TG-38 — Release Gate, Acceptance and Device Validation](index.md)
- **Component:** Device validation (Anzaan)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: T-186 ([T-186](T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Blocks:** T-188 ([T-188](../TG-39-p2-polish-and-feasibility-honesty/T-188-p2-dpo-on-judge-preferences.md)), T-192 ([T-192](../TG-39-p2-polish-and-feasibility-honesty/T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-025](../../../define-requirements/FR/FR-CNR-025-dv-device-validation-completion-gate.md), [FR-CNR-016](../../../define-requirements/FR/FR-CNR-016-v17-chat-aware-qlora-variant.md), [NFR-CNR-002](../../../define-requirements/NFR/NFR-CNR-002-listening-turn-latency-envelope.md), [NFR-CNR-003](../../../define-requirements/NFR/NFR-CNR-003-memory-and-jetsam-device-tiers.md), [NFR-CNR-009](../../../define-requirements/NFR/NFR-CNR-009-accessibility.md)

## Description
Produce the DV-1..6 device-validation protocol for the Anzaan session — exact steps, expected outcomes and a record slot per item, executable in one session without authoring anything on the device — and execute it when a session is available. DV-1..6 are the completion gate: local chat quality, cloud chat consent and indicator with a lossless toggle-back, honest offline degradation, emergency phrasing recall, command determinism, and the elderly listening panel side-by-side verdict. With no session, every item is recorded BLOCKED with the reason; never a fabricated pass.

## Acceptance criteria

```gherkin
Feature: Device validation as the completion gate

  Scenario: The protocol and record are prepared
    Given the DV-1..6 checklist as recorded in the feature workflow
    When the protocol is written
    Then every item has exact steps, expected outcomes and a record slot for pass, fail or blocked
    And it can be executed in one session without authoring anything on the device

  Scenario: The session executes the checklist
    Given an available Anzaan session and the built app
    When DV-1..6 are executed step by step
    Then each item is recorded with its observed result, in the item's own words
    And any fail is recorded verbatim with reproduction steps — not retried away

  Scenario: Each item carries its evidence class
    Given the recorded results
    When a reader inspects an item
    Then DV-1 cites the guard and cloud-chat telemetry (classification only), DV-4 cites the emergency phrasing outcomes, DV-5 cites reminder/alarm behaviour at temperature zero, DV-6 cites the panel's side-by-side verdict
    And no item's evidence is a unit test standing in for a device observation

  Scenario: No session available
    Given no Anzaan session
    When this task completes
    Then every item is recorded BLOCKED with the reason
    And the feature's completion status is explicitly device-validation-outstanding
```

## Acceptance criteria — failure paths

```gherkin
Feature: Device validation failure behaviour

  Scenario: A DV item fails on device
    Given a DV step producing an unexpected outcome
    When it is recorded
    Then the failure keeps reproduction steps, the item stays failed in the record, and the completion gate is not marked passed

  Scenario: A partial session
    Given a session ending after some items
    When the record is finalized
    Then executed items carry observed results and the remainder is BLOCKED — no inference, no filling in from unit tests

  Scenario: The build under test is not the built artifact
    Given a session run against a build whose identity does not match the recorded build
    When results are recorded
    Then the record is marked invalid for the gate (results must name the build they were observed on)
```

## Inputs and expected result

**Input:** the DV-1..6 checklist from the feature workflow; the acceptance record and integrated tree (T-186); the house device-install recipe; the telemetry events the items cite (guard flag, cloud chat, fallback — classification only).

**Output:** the device-validation protocol with the per-item record, executed or BLOCKED, written as `specs/CNR-device-validation-protocol.md` following the house convention of the earlier feature protocols.

**Declared files:** `specs/CNR-device-validation-protocol.md`

## Implementation notes
- Item set, verbatim from the workflow: DV-1 local chat quality (warm, grammatical, honorific agreement, particles within budget, no AI-isms, and a seeded guard flag engaging the safe template); DV-2 cloud chat consent plus visible indicator, and toggling off returning to the on-device brain without losing chat; DV-3 offline chat degrading honestly to the local brain (no crash, no false success); DV-4 emergency phrasing triggering exactly (recall untouched on device); DV-5 command determinism unchanged (for example reminders and alarms at temperature zero); DV-6 the elderly listening panel's side-by-side verdict recorded.
- Protocol conventions from the house protocols (the earlier feature's device-validation documents): a why/binding section, environment and build identity, prerequisites, how to run, record fields, per-item sections, the record, the completion gate and capture discipline. The build identity must be recorded per session — a result without it is not gate evidence.
- Evidence classes: the guard flag and cloud-chat events are read only for their classification fields (a content-bearing field in a log is itself a finding); the telemetry is read, not transcribed with content.
- Honesty doctrine: BLOCKED with a reason is a legitimate terminal state for the session-less case; the feature stays outstanding until a session runs; the record never infers a pass from unit tests, from the acceptance sweep or from the training-box gates.
- Release-gate evidence: the record also carries the release log-safety gate's exit-zero result for the built artifact, as the workflow names it part of the gate.
- Memory and latency observations (NFR-CNR-002/003): each chat item notes the felt latency and any eviction or reload the session observed on the reference tier; a second resident model or a reload per turn is a finding, not a curiosity.

## Definition of done
- [ ] Protocol written with per-item steps, expected outcomes and record slots
- [ ] Build identity recorded; results reference it
- [ ] If a session ran: DV-1..6 recorded with observed results (pass, fail or blocked verbatim) and per-item evidence cited
- [ ] If no session: every item BLOCKED with the reason, no pass claimed
- [ ] Release log gate exit-zero recorded for the built artifact
- [ ] Structured for mechanical verification at final-sign-off
- [ ] Any fail has reproduction steps and the completion gate remains open
