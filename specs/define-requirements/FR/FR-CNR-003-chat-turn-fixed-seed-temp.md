# FR-CNR-003: Chat-turn sampling — fixed seed with temperature ~0.3, chat turns only

## Metadata
- **Area:** Decode / Chat Sampling
- **Priority:** MUST
- **Source:** Proposal §5.1 ("keep temp 0 + fixed seed for commands (invariant), but for **chat turns** use fixed-seed temp ~0.3 — still fully reproducible (the gibberish bug was *random* seed), yet it escapes greedy's most-cliché tokens"); proposal §1 root cause 2 (greedy decoding picks the most cliché, assistant-like phrasing); feature constitution Runtime Contract "Chat decode (P0)" properties 2–4 and OD-1 (exact value + plumbing is design-l1's). Surfaces: `LlamaCommandInterpreter.OnDeviceSampling` (:404-417), handle creation (:1391-1398), `respondToChat` (:709), GBNF `chatJSONSchema` (:350).

## Description
Chat turns **must** be decoded with a fixed seed and temperature ~0.3 (exact value and the per-turn-override vs. shape-specific-handle plumbing is design-l1's, feature OD-1), while command turns keep the existing temp-0 invariants (FR-CNR-004). Binding properties:

- **Reproducible by construction**: same transcript and same assistant state → same reply. The gibberish defect was a *random* seed; a fixed seed at ~0.3 keeps the NO-GIBBERISH class closed.
- **Chat turns only**: the change is scoped to the chat decode path (`respondToChat` and the chat-capability route); no command, emergency or ladder decode is affected.
- **The GBNF `chatJSONSchema` constraint continues to apply** to the chat decode — one JSON object (`intent`/`reply`/`confidence`); a decode that cannot produce a readable object ABSTAINS (nil) rather than speaking malformed output (FR-CNR-013).
- **Feasibility honesty**: if fixed-seed temp ~0.3 does not hold reproducibly on any device tier (GBNF interplay, Metal backends), the limitation is recorded explicitly for the owner (FR-CNR-024) — never silently dropped, and the chat path never reverts to an unreproducible configuration.

## Acceptance criteria

```gherkin
Feature: Reproducible chat-turn decoding at a fixed seed and temperature ~0.3

  Scenario: A chat turn is reproducible
    Given the same transcript and the same assistant state
    When the same chat turn is decoded twice on the same device tier
    Then the two replies are identical

  Scenario: The chat change does not reach the command path
    Given a session that handles a chat turn and a command turn
    When the chat sampler is active
    Then the command turn is decoded under the unchanged temp-0 + fixed-seed + GBNF configuration

  Scenario: The chat decode still emits one readable JSON object
    Given a chat turn decoded at the chat sampling setting
    When the model output is parsed
    Then it is a single JSON object carrying intent, reply and confidence
    And an unreadable output abstains instead of being spoken

  Scenario: The setting does not reproduce on a device tier (failure)
    Given a device tier where fixed-seed temperature ~0.3 does not reproduce
    When the configuration is evaluated
    Then the limitation is recorded explicitly for the owner
    And no unreproducible chat sampling setting ships silently
```

## Related
- FR: FR-CNR-004 (command invariants), FR-CNR-013 (single-decode schema), FR-CNR-024 (feasibility honesty)
- NFR: NFR-CNR-001 (chat reply reproducibility)
