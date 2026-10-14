# FR-CNR-004: Command-turn decode determinism preserved — temp-0 + fixed seed + GBNF untouched

## Metadata
- **Area:** Decode / Determinism Invariant
- **Priority:** MUST
- **Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 1 ("Commands keep the NO-GIBBERISH invariants, byte-for-byte … `OnDeviceSampling` and the handle creation are not moved by this feature. Command determinism is regression-visible as DV-5") and "Out of scope (must not change)" ("Command-turn decode determinism: temp-0 + fixed seed + GBNF `commandJSONSchema` are the NO-GIBBERISH invariants and stay untouched"); proposal §5.1 and §7 risks ("mitigated by keeping the temp-0/seed/GBNF discipline"). Surfaces: `LlamaCommandInterpreter.swift:404-417` (`OnDeviceSampling`, `fixedSeed` = 20_260_907), `:1391-1398` (handle creation), `commandJSONSchema`.

## Description
The command path's decode determinism **must** remain byte-for-byte as shipped: temperature 0 (`OnDeviceSampling`), the fixed seed (20_260_907), and the GBNF `commandJSONSchema` constraint. `OnDeviceSampling` and the LLM handle creation are not moved, reparameterised or bypassed by this feature, and the chat sampling change (FR-CNR-003) **must** not leak into any command, ladder, emergency or reminder turn. This is a safety-relevant invariant: a non-deterministic command turn is a heard-by-the-user defect on a path the elderly user depends on, and it is the regression the NO-GIBBERISH fix closed.

## Acceptance criteria

```gherkin
Feature: Command turns stay byte-for-byte deterministic

  Scenario: A command turn is unchanged across the feature
    Given the pre-change baseline behaviour of a command turn (e.g. a reminder or alarm request)
    When the feature's build handles the same turn
    Then the decoded result and its determinism properties are unchanged
    And repeated runs produce the identical result

  Scenario: A chat turn cannot alter command decoding
    Given a session in which a chat turn was decoded at the chat sampling setting
    When a command turn follows
    Then it is decoded under temp-0 + fixed seed + commandJSONSchema
    And no chat sampling parameter is observable on that path

  Scenario: A command turn differs from the baseline (failure)
    Given a build in which a command turn's decode configuration or output changed
    When the regression is detected
    Then the change is rejected as a NO-GIBBERISH invariant violation
    And the chat feature does not ship in that state
```

## Related
- FR: FR-CNR-003 (chat sampling), FR-CNR-014 (router/emergency invariants), FR-CNR-025 (DV-5 records this on device)
- NFR: NFR-CNR-008 (gate thresholds), NFR-CNR-011 (release gates)
