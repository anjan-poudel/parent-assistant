# FR-CDP-018: Preserved behaviours — no new dialogue flow, emergency semantics untouched, no silent failures

## Metadata
- **Area:** Safety Boundary / Regression
- **Priority:** MUST
- **Source:** Frozen design Goal 4 and non-goals ("No dedicated `CallRouter` service"; "Emergency-contact semantics untouched"; "No changes to the just-shipped voice pipeline beyond the named MethodResolver seam") + Decision 5; feature constitution Out of scope ("A dedicated `CallRouter` service"; "Per-contact primary/secondary storage"; "Emergency-contact semantics"; "A new dialogue flow"; "The no-silent-failure principle ...") and Feature Constraints 6, 7, 8; workflow scope non-goals ("no change to emergency-contact semantics; a new dialogue flow; any new network surface") and `security-design-review` focus ("Emergency precedence untouched ... dial-back must never delay an emergency escalation").

## Description
The feature **must not** change the following behaviours:

- **No new dialogue flow** — the existing multi-turn confirmation (pend → existing confirmation window → yes/no → override/timeout → execute) is reused exactly; no new question kind, no new session state, no new prompt sequence (Decision 5, Feature Constraint 6).
- **Emergency-contact semantics untouched** — emergency-contact resolution (the existing `NotifyChannel.resolve`-based path) and emergency escalation keep their exact current semantics; the feasibility chain, the probes and the fallback announcements **must not** wrap, reroute or delay emergency paths (Feature Constraint 7's non-goal; workflow security focus).
- **No silent failures** — every infeasible-preferred, both-infeasible and launch-fail outcome on the new paths is announced through an existing lane (FR-CDP-013/015/016); the existing honest lines (dial-back dead row, override refusal, web-chat disclosure) stay intact.
- **No `CallRouter` service** — the feature extends the existing resolution seams only; **no per-contact primary/secondary storage** — explicit picks remain chain inputs only (Feature Constraints 5, 7).

## Acceptance criteria

```gherkin
Feature: Preserved behaviours at the safety boundary

  Scenario: The emergency path is functionally unchanged
    Given the emergency-contact resolution and escalation paths
    When their existing matrix is exercised against a build with this feature
    Then their outputs are identical to pre-feature behaviour
    And the chain, feasibility probes and fallback announcements are not applied to them
    And no escalation is delayed or rerouted

  Scenario: The confirmation mechanics introduce no new dialogue
    Given a call confirmation is pending
    When the user answers yes, no, overrides, or lets it time out
    Then each behaviour is exactly as before the feature
    And no new question, state or prompt appears

  Scenario: No outcome on the new paths is silent
    Given an infeasible preferred channel, an infeasible pair, or a launch failure
    When the call is initiated on any path (tap, dial-back, voice)
    Then a spoken line names the outcome
    And zero silent failures occur
```

## Related
- FR: FR-CDP-013/014 (reused confirmation + override), FR-CDP-015/016 (never-silent announcements), FR-CDP-011 (dial-back does not delay escalation)
- NFR: NFR-CDP-009 (regression evidence), NFR-CDP-002 (no new surface)
