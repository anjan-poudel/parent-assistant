# NFR-MTC-007: Sustained multi-turn stability on 6 GB devices — no jetsam

## Metadata
- **Category:** Reliability / Performance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone; validated by DV-5)
- **Source:** Feature constitution "Success Criteria" ("No jetsam kills across sustained multi-turn use on Anzaan") and DV-5 ("sustained multi-turn without jetsam (post-conversation jetsam log pull)"); feasibility study §5.1/§5.3 (1024-token ceiling is a memory limit; multi-turn multiplies the turn-count risk; PR #156 landed the OOM hardening) and §8 (OOM mitigation row); project constitution safety service stance.

## Description
Sustained multi-turn dialogue **must not** introduce memory-pressure failures on the reference 6 GB-class device:

- **Measurable**: a sustained dialogue session (the DV scripted sequence, ≥ 10 consecutive dialogue turns including probe→answer pairs and one degraded-brain turn) on Anzaan produces **0 jetsam kills attributable to the voice stack**; a post-conversation JetsamEvent log pull is the evidence.
- **Inherits PR #156 policy**: per-turn STT release (`WhisperPostTurnPolicy.ReleaseReason.brainOverBudget` behaviour) and the pressure-tiered brain pick stay in force; the frame machinery adds no keeper of large allocations, no second resident model, no new warm-up.
- **Bounded turn cost**: each dialogue turn's memory profile is no worse than today's equivalent single turn (probe text and catalog are small static data; the frame is a tiny app object); the feature must not turn N turns into N times the worst-case resident set.
- **Regression signal**: if a jetsam occurs, the JetsamEvent log pull is recorded with the feature and the feature fails its completion gate (FR-MTC-020).

## Acceptance criteria

```gherkin
Feature: Sustained multi-turn stability

  Scenario: A sustained multi-turn session produces no voice-stack jetsam
    Given a 6 GB-class reference device in Release configuration
    When a sustained multi-turn session (probe/answer turns plus a degraded-brain turn) runs
    Then the post-conversation JetsamEvent pull shows 0 voice-stack kill events
    And the session completes without a crash

  Scenario: Per-turn memory is bounded like today's turns
    Given the dialogue feature is built
    When a dialogue turn's resident set is compared to a comparable single turn
    Then no new large allocation or resident model is added by the frame machinery
    And PR #156's release/pick policies remain in effect
```

## Related
- FR: FR-MTC-020 (DV-5 records this), FR-MTC-014 (session state), FR-MTC-018 (Phase 2 must not add resident cost)
- NFR: NFR-MTC-005 (degraded-brain path), NFR-MTC-001 (turn envelope)
