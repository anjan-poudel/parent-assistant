# FR-MTC-020: DV-* device validation recorded and passed (completion gate)

## Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Phase:** Completion gate (device validation on Anzaan; per the study §7 the DV checklist closes the feature — run before final sign-off)
- **Source:** Feature constitution "Completion gate — DV-* device validation on Anzaan (the DV pattern of prior shipped features, recorded with the feature spec)" (DV-1 … DV-5) and "Phase 0 prerequisite: the outstanding PR #156 device smoke — conversation → no jetsam → pull JetsamEvent logs — must be run as the Phase 0 gate"; feasibility study §7 (Phase 0/Phase 3); workflow `final-sign-off` comment ("DV-* device validation on Anzaan is part of the completion gate"); precedent: `SP-device-validation-protocol.md` / `LCT-device-validation-protocol.md`.

## Description
The feature **must not** be considered done until the DV-* checklist is executed on the reference device (Anzaan) and recorded with the feature spec, in the same shape as the prior shipped features' device-validation records:

- **DV-1 — probe → answer → correct playback** (the owner's bhajan example): "play bhajans" → probe → "dasain durga bhajans" → dasain durga bhajan playback.
- **DV-2 — timeout**: 45 s expiry drops the frame silently and re-arms; the next utterance is a fresh command.
- **DV-3 — barge-in**: a strong new command mid-frame executes and drops the frame.
- **DV-4 — mid-dialogue degraded-brain turn**: the deterministic merge carries the dialogue when the brain is degraded/absent.
- **DV-5 — sustained multi-turn without jetsam**: post-conversation JetsamEvent log pull shows no voice-stack kills (NFR-MTC-007).
- **Phase 0 prerequisite first**: the outstanding PR #156 device smoke (conversation → no jetsam → pull JetsamEvent logs) is run and recorded **before** the DV-* work begins (feature constitution Phase 0; scope comment "Phase 0 prerequisite: PR #156 ... its Anzaan device smoke is still outstanding").
- **Recorded results**: each DV item is recorded as passed/failed with the evidence (log pulls, session notes) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — no silent waiver.

## Acceptance criteria

```gherkin
Feature: Device-validation completion gate

  Scenario: Every DV item is executed on Anzaan and recorded
    Given the Phase 0 prerequisite smoke is complete
    When final validation runs
    Then DV-1 through DV-5 are each executed on the reference device
    And each result (pass/fail with evidence) is recorded with the feature spec

  Scenario: The Phase 0 prerequisite is satisfied before DV work
    Given PR #156's device smoke has not yet been run
    When device validation is about to start
    Then the smoke (conversation → no jetsam → JetsamEvent pull) is run and recorded first
    And its result is attached to the feature record

  Scenario: A failed DV blocks completion (failure scenario)
    Given any DV item fails (e.g. DV-5 shows a voice-stack jetsam kill)
    When completion is assessed
    Then the feature does not pass final sign-off
    And the failure is fixed and the item re-run before sign-off proceeds
```

## Related
- FR: FR-MTC-013 (DV-2), FR-MTC-012 (DV-3), FR-MTC-006 (DV-4), FR-MTC-003/006 (DV-1)
- NFR: NFR-MTC-007 (DV-5 stability), NFR-MTC-012 (release gates)
