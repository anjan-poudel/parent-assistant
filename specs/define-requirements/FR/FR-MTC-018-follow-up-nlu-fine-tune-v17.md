# FR-MTC-018: Phase 2 — follow-up NLU fine-tune v17 with the frame clause

## Metadata
- **Area:** NLU Training (Phase 2)
- **Priority:** SHOULD (Phase 2 — ships only with the training iteration; escalates to MUST if OD-M3 sequences it into the release)
- **Phase:** Phase 2 (later phase — follow-up NLU fine-tune v17; data authoring may proceed in parallel per OD-M3, but the clause ships ONLY with the training iteration)
- **Source:** Feature constitution "In scope" Phase 2 ("follow-up-turn training data (golden corpus + synthetic follow-ups), `prompt_template` mirror update, LoRA on the existing training pipeline, query-slot gates, brain-assisted frame merge"), Feature Constraint 5 ("The Phase 2 frame clause ships only together with the v17 training iteration ... mirrored byte-identically in `tools/train-intent/seeds/prompt_template.txt` in the same change, and must not alter the `.raw` framing") and the answer-turn contract step 4 ("Optional brain resolution (Phase 2 only)"); feasibility study §6.3.4 (the frame clause), §6.4 (constraints), §7 Phase 2; OD-M3 (OPEN — sequencing).

## Description
Phase 2 turns the same dialogue mechanism from curated to general via the follow-up NLU iteration. Binding properties:

- **Follow-up-turn training data**: golden-corpus additions plus synthetic follow-ups (e.g. a bare "दशैं दुर्गा भजन" against frame-marked contexts), covering the answer forms of FR-MTC-005 and both probe kinds.
- **Frame clause ships ONLY with the training iteration**: the optional brain-resolution clause (a compact "answer to the earlier question about music; missing detail: kind of bhajan" addition inside the ~300-token headroom) is injected into the runtime prompt **only** in the same change that ships the retrained model (v17) and its training data — injecting it without training data is the named prompt-identity-drift hazard (NFR-MTC-002, NFR-MTC-011).
- **Prompt mirror byte-identical**: `tools/train-intent/seeds/prompt_template.txt` is updated in the same change and stays byte-identical to the runtime prompt template; the `.raw` framing (no system turn) is not altered.
- **Query-slot gates**: new query-slot accuracy gates run alongside the existing contact/time slot gates (the slot-canon precedent: gates fail → retrain, don't ship).
- **Brain-assisted frame merge (optional resolution)**: when the deterministic merge cannot extract a value (e.g. "the one from yesterday"), the answer turn may ask the brain once with the compact frame clause; if the brain is unavailable, the system asks one more probe (within the cap) and then executes with defaults (FR-MTC-007) — Phase 1's deterministic path remains the floor at all times (NFR-MTC-005).

## Acceptance criteria

```gherkin
Feature: Phase 2 follow-up NLU (v17)

  Scenario: The frame clause is never injected without its training iteration
    Given a release built without the v17 follow-up training artifacts
    When answer turns are processed
    Then the frame clause is not present in any prompt
    And the deterministic merge path is used

  Scenario: The training mirror is byte-identical in the same change
    Given the frame clause is added to the runtime prompt template
    When the change is inspected
    Then tools/train-intent/seeds/prompt_template.txt is updated in the same change
    And the mirror is byte-identical to the runtime template
    And the .raw framing is unaltered

  Scenario: Brain-assisted resolution merges an otherwise-unmergeable answer
    Given the deterministic merge cannot extract a value from the answer ("the one from yesterday")
    And the v17 brain is available
    When the answer turn runs
    Then the brain resolves the answer against the compact frame clause
    And the merged command executes through the normal path

  Scenario: A brain-unavailable answer still terminates cleanly
    Given the deterministic merge cannot extract a value
    And the brain is unavailable
    When the answer turn runs
    Then the system asks one more probe (within the cap)
    And then executes with defaults if the answer remains unresolved
```

## Related
- FR: FR-MTC-006 (the deterministic floor), FR-MTC-007 (probe cap), FR-MTC-016 (the model never writes probe text)
- NFR: NFR-MTC-002 (prompt budget), NFR-MTC-011 (KV-prefix stability), NFR-MTC-005 (degraded-brain floor)
