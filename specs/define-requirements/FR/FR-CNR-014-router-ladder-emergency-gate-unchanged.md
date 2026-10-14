# FR-CNR-014: Router ladder and the emergency path unchanged — emergency recall 1.00 is a gate, not a metric

## Metadata
- **Area:** Preserved Behaviours / Safety Path
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" ("The router ladder and emergency gate behavior; the chat pre-check semantics beyond wiring the routing toggle") and "Cloud-first chat routing toggle (P0)" property 1; Safety & Compliance Delta 1 ("The v17 chat variant is a catalog swap of the SAME single-decode model that answers commands and the emergency path — a chat-data regression is a safety regression. Therefore all existing gates (emergency recall 1.00 above all) are non-negotiable regressions"); proposal §1 and §6 ("**emergency recall 1.00**"); project constitution Safety-critical constraints (emergency calling logic isolated in a hardened module; not blocked by the on-device LLM being busy or unavailable); workflow scope comment. Surfaces: `IntentRouter` ladder (:259-291, :308-395), `LocalBrainChain`, the emergency path, `AppCoordinator.defaultBrainModelID`.

## Description
The router ladder, the emergency gate and the safety routing behaviour **must** keep their pre-change semantics exactly, while the chat changes land around them:

- **The chat toggle never alters ladder ordering, ladder triggers, or the emergency gate.** Chat routing is wired into the chat path; it does not intercept, delay, re-order or re-classify emergency or command turns (FR-CNR-010).
- **The emergency path is not blocked by chat.** A chat turn in flight — local or cloud — never blocks, delays past its confined budget, or suppresses an emergency trigger; the emergency module's isolation from on-device LLM availability is preserved.
- **Emergency recall 1.00 remains a gate.** Because the v17 chat variant is the *same* single-decode model answering the intent and emergency paths, the emergency gate is a ship condition, never a monitored metric that may drift (FR-CNR-021). Emergency phrasing behaviour is re-verified on device (DV-4, FR-CNR-025).
- **Existing behaviour is preserved, not "improved":** no chat-driven change to emergency phrasing handling, threshold logic, or the trigger confirmation seam.

## Acceptance criteria

```gherkin
Feature: The ladder and emergency path are untouched by chat work

  Scenario: The ladder behaves exactly as before
    Given a set of turns used as the pre-change reference (commands, chat, ambiguous and emergency phrasing)
    When the feature build routes them
    Then every routing decision and trigger point matches the pre-change behaviour
    And only the chat path reflects the new routing toggle

  Scenario: A chat turn never blocks or delays an emergency trigger
    Given a chat turn in flight (local decode or cloud request)
    When an emergency utterance is spoken
    Then the emergency path triggers as it does without the chat feature
    And no chat state (routing, consent, guard) gates it

  Scenario: Emergency recall drops below 1.00 (failure)
    Given the post-change model evaluated on the emergency suite
    When recall is measured
    Then a result below 1.00 is a failed gate
    And the catalog swap does not ship in that state
```

## Related
- FR: FR-CNR-004 (command determinism), FR-CNR-008 (chat routing), FR-CNR-010 (egress scope), FR-CNR-021 (harness), FR-CNR-025 (DV-4)
- NFR: NFR-CNR-008 (gate thresholds), NFR-CNR-011 (release gates)
