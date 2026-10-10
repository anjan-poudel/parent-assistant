# NFR-MTC-011: KV-prefix stability — the frame clause never mutates the template prefix

## Metadata
- **Category:** Performance / Reliability
- **Priority:** MUST
- **Phase:** Phase 2 (the clause itself ships only with the v17 iteration; the constraint is binding on any prompt-affecting change of this feature)
- **Source:** Feature constitution Feature Constraint 6 ("KV-prefix stability. The frame clause must not mutate the byte-stable template prefix (the vendored LLM prefix-reuse path depends on it — study §5.3)"); feasibility study §5.3 ("The reuse depends on the template prefix being byte-stable between turns, which is one more reason the frame clause must not mutate the template") and §6.4; worktree surface: the vendored `LLM.swift` prompt-prefix KV reuse (`prepareContext(for:)` diffs the new prompt against the previous context and decodes only the divergent tail).

## Description
The vendored LLM path re-uses the KV cache for the byte-stable prompt prefix between turns; the frame clause (and anything else this feature adds to a prompt) **must** preserve that property:

- **Byte-stable prefix**: for consecutive turns in a dialogue, the template prefix bytes are identical whether or not a frame is active — the clause is appended inside the utterance/user segment (per the study's placement, "append to the user turn"), never inside or ahead of the stable prefix.
- **Reuse preserved**: between dialogue turns, only the utterance tail is re-decoded (tens of tokens), not the ~700-token template — the study's measured benefit that makes multi-turn turns cheaper than the pre-#156 churn.
- **Verifiable**: a test compares prompt prefix bytes across frame/no-frame turns and asserts identity; a second check asserts the divergent tail is the only re-decoded region (the reuse path engages).
- **No prompt change at all in Phase 1**: this NFR binds vacuously in Phase 1 (no clause exists) and becomes load-bearing with FR-MTC-018.

## Acceptance criteria

```gherkin
Feature: KV-prefix stability

  Scenario: Prefix bytes are identical with and without an active frame
    Given the v17 frame clause is present in a build
    When the prompt is built for the same utterance with a frame active and inactive
    Then the template prefix bytes are identical between the two prompts
    And only the utterance segment differs

  Scenario: Prefix reuse engages between dialogue turns
    Given consecutive dialogue turns run with a resident brain
    When the second turn decodes
    Then only the divergent utterance tail is decoded
    And the ~700-token template prefix is not re-decoded

  Scenario: Phase 1 changes no prompt bytes at all
    Given a Phase 1 build (no clause)
    When prompts are compared with the pre-feature build
    Then they are byte-identical
```

## Related
- FR: FR-MTC-018 (the clause this binds), FR-MTC-001 (state lives in the app)
- NFR: NFR-MTC-002 (prompt budget), NFR-MTC-001 (per-turn latency)
