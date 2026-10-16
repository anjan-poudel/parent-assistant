# NFR-MTC-005: The frame survives a degraded or absent brain — deterministic path

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 4 ("Deterministic merge works with the brain absent or degraded. This is Phase 1's core guarantee: the frame survives a degraded or skipped brain turn and executes via the deterministic merge. The PR #156 hardening must stay intact (per-turn STT release, pressure-tiered brain pick); brain-assisted merge is Phase 2 only") and "Success Criteria" ("Brain-degraded turns fall back to the deterministic merge or one more probe"); feasibility study §5.3 (degradation ladder) and §6.3.3; workflow `security-design-review` focus ("Degraded-brain path: the deterministic merge must not weaken the emergency/safety gates when the brain is absent or evicted"); worktree surfaces verified: `PressureBrainPick` (4B→1.7B→1B→lightweight, `Services/Voice/PressureBrainPick.swift`), degraded-mode pill (PR #156, `437631e`).

## Description
The dialogue frame **must** function with the brain absent, skipped, unavailable (downloading/setup) or pressure-evicted:

- **Zero model dependency in Phase 1**: probe trigger, probe text, answer capture, catalog canonicalisation and the merge/execution path require **no model call and no prompt tokens** — the owner's bhajan example works end-to-end with the brain entirely absent.
- **Frame survives mid-dialogue degradation**: if the brain pick degrades between the probe and the answer (4B → 1.7B → 1B → lightweight → brainless), the frame is unaffected — deterministic merge carries the dialogue (DV-4).
- **PR #156 hardening intact**: the per-turn STT release policy and the pressure-tiered brain pick remain in force and are not weakened or bypassed by the frame path (no new resident model, no new warm-up, no extra turn peak-memory work); no jetsam regression (NFR-MTC-007).
- **Safety gates unchanged under degradation**: with the brain absent, emergency precedence, cancel and timeout rules behave identically (FR-MTC-011); the deterministic path never skips a safety check because a model is missing.
- **Unresolvable answers terminate cleanly**: when even the deterministic merge cannot extract a value and (Phase 2) the brain is unavailable, the system asks one more probe within the cap and then executes with defaults — never a stuck state (FR-MTC-007).

## Acceptance criteria

```gherkin
Feature: Degraded-brain dialogue survival

  Scenario: The full dialogue completes with the brain absent
    Given no brain model is loaded
    When the user triggers the bhajan probe and answers "दुर्गा भजन"
    Then the probe is spoken and the answer merges deterministically
    And the merged command executes with zero model calls

  Scenario: A mid-dialogue brain eviction does not break the frame
    Given a probe was asked while a 4B brain was resident
    When the brain is pressure-evicted before the answer turn
    Then the answer is still captured and merged on the deterministic path
    And the dialogue completes without error

  Scenario: PR #156 memory policy remains in force
    Given the feature is built
    When a multi-turn dialogue runs on the 6 GB device
    Then the per-turn STT release policy and pressure-tiered brain pick behave as shipped in PR #156
    And the frame path adds no new resident model or warm-up work
```

## Related
- FR: FR-MTC-006 (deterministic merge), FR-MTC-007 (cap), FR-MTC-011 (safety under degradation), FR-MTC-018 (the Phase 2 brain assist this floor outranks)
- NFR: NFR-MTC-007 (stability), NFR-MTC-001 (latency with no model wait)
