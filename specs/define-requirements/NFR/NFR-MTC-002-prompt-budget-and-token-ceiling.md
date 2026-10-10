# NFR-MTC-002: 1024-token ceiling and the pinned prompt budget are preserved

## Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Phase:** Phase 1 binding for state placement; the frame clause itself is Phase 2 (ships only with the v17 iteration)
- **Source:** Feature constitution Feature Constraint 1 ("1024-token ceiling. The brain context is a measured memory ceiling (2048 crashed 6 GB devices — study §5.1). Dialogue state lives in the app, never as transcript history in prompts. Any prompt clause must fit the ~300-token headroom inside the pinned `IntentPromptTests` budget") and Feature Constraint 5 (clause inside the pinned budget, mirror discipline); feasibility study §5.1 (measured: composed prompt ~696 qwen3 tokens, ~300 left for utterance + output, ~128 reserved; two shipped overflow bugs) and §6.4; worktree surfaces verified: `maxTokenCount: 1024` (`LlamaCommandInterpreter.swift:1199`, 2048-crash comment `:1159-1163`), the `IntentPromptTests` 3,000-character regression pin (measured 2,506 characters for the fixture, 2026-10-05) and the 696 qwen3-token measurement note (`IntentPromptTests.swift:105-131`).

## Description
The feature **must** respect the measured 1024-token brain context and the pinned prompt budget:

- **Dialogue state lives in the app, never in the prompt**: no transcript history, no turn array, no conversation log is ever added to the intent prompt (Phase 1 adds **0** prompt tokens; the frame is app state — FR-MTC-001).
- **Frame clause within the headroom (Phase 2)**: any frame clause must fit the ~300-token remaining budget (1024 context = ~696-token measured template + ~128-token output reserve + utterance); the study's sizing guidance is ~30–60 tokens. The clause ships only with the v17 training iteration (FR-MTC-018).
- **The pin must not be raised**: `IntentPromptTests`' regression tripwire (build() ≤ 3,000 characters for the pinned fixture; the pre-fix 2,361-token overflow is the named failure) stays in force and is not relaxed by this feature; with the clause present the test still passes.
- **`.raw` framing unchanged**: no system turn, no wrapper change (Feature Constraint 5); the prompt prefix stays byte-stable (NFR-MTC-011).

## Acceptance criteria

```gherkin
Feature: Prompt budget preservation

  Scenario: Phase 1 adds zero prompt tokens for dialogue state
    Given a dialogue frame is active
    When a command turn builds its intent prompt
    Then the prompt is identical to the no-frame prompt for the same utterance (no frame, history or state text added)

  Scenario: The Phase 2 clause stays inside the pinned budget
    Given the v17 iteration ships with the frame clause
    When IntentPromptTests runs
    Then build() stays within the 3,000-character pin and the 1024-token context
    And the pin value has not been raised

  Scenario: No transcript history accumulates across dialogue turns
    Given N consecutive dialogue turns have completed
    When an equivalent utterance builds its prompt
    Then its prompt size and prefix are identical to the first turn's
    And no utterance history is present
```

## Related
- FR: FR-MTC-018 (the clause and its shipping condition), FR-MTC-001 (state in the app)
- NFR: NFR-MTC-011 (prefix stability), NFR-MTC-005 (brain-free floor)
