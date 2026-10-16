# FR-CNR-013: Single-decode schema unchanged — one JSON, and an unreadable object abstains

## Metadata
- **Area:** Single-Decode Integrity
- **Priority:** MUST
- **Source:** Proposal §1 ("The single-decode architecture (one JSON: `intent` + `response` + `confidence`) stays untouched — the router and its emergency gate must not regress") and §4 ("Same single-decode shape (schema unchanged) → no chain/router surgery, catalog swap only"); feature constitution "Out of scope (must not change)" ("The single-decode schema — one JSON (`intent` + response/reply + `confidence`). No chain/router surgery; the v17 variant is a catalog swap") and Runtime Contract "Chat decode (P0)" property 3 and "Model & Training Contract" property 1. Surfaces: `IntentPrompt.buildChat`, `chatJSONSchema` (GBNF), `LocalBrainChain.respondToChat` (:268-294), `IntentRouter.interpretLocalLadder` (:259-291).

## Description
The feature **must not** change the single-decode architecture. Chat continues to be produced as **one JSON object** carrying intent, response/reply and confidence, constrained by the existing GBNF chat schema, and chat keeps flowing through the existing capability rule (`LocalBrainChain.respondToChat`) and the existing chat pre-check (`IntentRouter.interpretLocalLadder`). Binding properties:

- **No chain or router surgery.** No new decode stage, no second model call to compose the reply, no post-hoc JSON repair layer that changes the contract. The P1 model arrives as a catalog swap (FR-CNR-022), not as a new pipeline.
- **The GBNF `chatJSONSchema` constraint continues to apply** (FR-CNR-003).
- **A model that cannot produce a readable object ABSTAINS (nil)** — it never speaks malformed output, never emits a partially parsed reply, and never falls back to speaking raw model text.
- The abstention path retains the existing abstain/honesty discipline that the abstention gate (≥0.90) and the claw-back data keep trained in (FR-CNR-017).

## Acceptance criteria

```gherkin
Feature: The single-decode shape is unchanged by this feature

  Scenario: A chat turn still produces one JSON object
    Given a chat turn on the shipped feature build
    When the model output is decoded
    Then it is one JSON object carrying intent, reply and confidence
    And it was produced without an added decode stage

  Scenario: The chat route and pre-check semantics are unchanged
    Given the same inputs as the pre-change build
    When a chat turn is routed
    Then it travels the same capability rule and chat pre-check decision points
    And no chain/router structure was added or re-ordered by this feature

  Scenario: An unreadable output abstains (failure)
    Given a chat decode whose output cannot be parsed as a readable JSON object
    When the turn is handled
    Then the system abstains
    And no malformed or partially parsed text is spoken
```

## Related
- FR: FR-CNR-003 (chat sampling), FR-CNR-014 (router/emergency), FR-CNR-020 (gates include abstention), FR-CNR-021 (harness)
- NFR: NFR-CNR-008 (gate thresholds)
