# T-133: Router interception block, protocol and execution

## Metadata
- **Group:** [TG-26 — Router Interception and Window State](../index.md)
- **Component:** C-MTC-05 part 1 — `Services/` + `Voice/CommandRouter.swift`; new test `ios/ElderlyAssistantTests/Services/` + `Voice/CommandRouterDialogueTests.swift`
- **Agent:** dev
- **Effort:** XL (5 days)
- **Risk:** CRITICAL
- **Depends on:** [T-125](../TG-24-dialogue-frame-foundations/T-125-dialogue-manager-frame-core.md), [T-126](../TG-24-dialogue-frame-foundations/T-126-dialogue-option-catalog.md), [T-128](../TG-24-dialogue-frame-foundations/T-128-barge-in-predicate-access-widenings.md), [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md)
- **Blocks:** [T-134](T-134-degenerate-triggers-and-did-you-mean.md), [T-136](T-136-app-coordinator-dialogue-wiring.md), [T-139](../TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md), [T-140](../TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md), [T-141](../TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md)
- **Requirements:** [FR-MTC-001](../../../../define-requirements/FR/FR-MTC-001-dialogue-frame-lifecycle.md), [FR-MTC-006](../../../../define-requirements/FR/FR-MTC-006-deterministic-frame-merge-and-execution.md), [FR-MTC-007](../../../../define-requirements/FR/FR-MTC-007-probe-budget-two-then-defaults.md), [FR-MTC-008](../../../../define-requirements/FR/FR-MTC-008-say-it-again-escape.md), [FR-MTC-009](../../../../define-requirements/FR/FR-MTC-009-pre-ladder-answer-interception.md), [FR-MTC-010](../../../../define-requirements/FR/FR-MTC-010-cancel-drops-the-frame.md), [FR-MTC-011](../../../../define-requirements/FR/FR-MTC-011-emergency-precedence-mid-frame.md), [FR-MTC-012](../../../../define-requirements/FR/FR-MTC-012-barge-in-strong-new-command.md), [FR-MTC-013](../../../../define-requirements/FR/FR-MTC-013-timeout-silent-rearm.md), [FR-MTC-017](../../../../define-requirements/FR/FR-MTC-017-transcript-cache-bypass.md), [NFR-MTC-004](../../../../define-requirements/NFR/NFR-MTC-004-log-safety.md), [NFR-MTC-008](../../../../define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md), [NFR-MTC-010](../../../../define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md)

## Description
The feature's single integration point: the pre-ladder interception block in
`route()` between the confirmation hook's closing brace and the safety net
(design-l2 §12.2–§12.5), the six `VoiceCommandCoordinating` members the router
needs, the emergency post-dispatch frame clear (§12.3), the execution helpers
(§12.5) and the first focused suite, `CommandRouterDialogueTests`. The
emergency block stays absolute; the confirmation hook body stays byte-identical;
a consumed answer turn never reaches the interpreter or the transcript cache.

## Acceptance criteria

```gherkin
Feature: Pre-ladder dialogue answer interception

  Scenario: A consumed answer turn never reaches the interpreter or the cache
    Given a live frame and the interpreter and cache doubles armed with counters
    When the answer utterance is routed
    Then the router consumes it on the answer path
    And the interpreter counter and the cache counter both remain zero

  Scenario: Emergency dispatch is untouched and only then clears the frame
    Given a live frame and an emergency utterance
    When the utterance is routed
    Then emergency dispatch runs exactly as before the feature
    And with the frame clear forced to a no-op the dispatch still runs unchanged
    And the frame is cleared with the emergency outcome after dispatch

  Scenario: Cancel and escape are spoken and terminal for the turn
    Given a live frame
    When the cancel phrase or the escape phrase is routed
    Then the localized acknowledgement is spoken
    And the frame is cleared and the turn returns without running the normal ladder

  Scenario: A barge-in resolves the frame and falls through exactly once
    Given a live frame and a strong new command
    When it is routed
    Then the frame resolves as superseded
    And the normal ladder handles the utterance exactly once

  Scenario: An invalid answer consumes one attempt and re-probes or exhausts
    Given a live frame at attempt one and a degenerate answer
    When it is routed
    Then the attempt count increments and an invalid answer event is emitted with its reason metadata
    And the frame re-probes with the retry variant

  Scenario: Slot-fill exhaustion executes the default query
    Given a slot-fill frame whose attempts are exhausted
    When another invalid answer is routed
    Then the frame's default query is executed through the normal music arm

  Scenario: Candidate-choice exhaustion closes honestly without executing anything
    Given a candidate-choice frame whose attempts are exhausted
    When another invalid answer is routed
    Then the exhausted close line is spoken with the dialogue exhausted event
    And no candidate and no default is executed

  Scenario: An expired frame leaves the next utterance a fresh command
    Given a frame whose window expired a moment before the utterance
    When the utterance is routed
    Then no frame is live and the normal ladder handles it as a fresh command

  Scenario: The confirmation hook is behaviourally untouched
    Given a live frame and a pending confirmation
    When the utterance is routed
    Then the confirmation hook handles it exactly as before the feature
    And its body remains unmodified

  Scenario: The candidate executor bounds-checks hostile indices
    Given a candidate execution request with an out-of-range index
    When the executor runs
    Then it refuses the index without addressing outside the candidate list or crashing
```

## Implementation notes
- Placement: insert the block after the confirmation hook's closing brace
  (`CommandRouter.swift:886`) and before the safety net (`:888-899`). The
  emergency block (`:779-783`) remains textually ahead; the only change there is
  a post-dispatch, side-effect-only frame clear (§12.3).
- **C-2 (review-l2).** When implementing the news candidate execution (§12.5),
  mirror the real relaxed news arm `:1210-1217`; `:1131-1138` is the strict
  stage reference. Do not copy the comment-block anchor.
- **C-3 (review-l2).** Emit the invalid-answer event by direct
  `ObservabilityEvent` construction (pattern `:1406-1413`) so the `reason`
  metadata survives; never drop metadata to fit the two-argument helper
  (`:3982-3991` emits with hardcoded empty metadata).
- **M-5 pins here too:** the executor validates the option index against the
  candidate count before use (belt-and-braces over T-131's totality).
- **V-1.** The gibberish guard keeps its shipped position ahead of the block;
  rejected noise consumes no attempt. **V-4.** The sanity guard keeps its
  shipped placement; record both in the task log for the T-142 index.
- **V-2.** Add no console write anywhere in this diff; all observability goes
  through the closed event vocabulary (NFR-MTC-004).
- **FR-MTC-017 structural:** every consumed arm returns before the interpreter
  and the transcript cache; the answer text is never interned.
- The six protocol members mirror design-l2 §12.1; their implementations land
  in T-136 (coordinator) — this task defines and consumes the protocol surface.
- Keep `CommandRouterMusicTests` doubles intact; the new suite adds its own
  router double with the six members.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`CommandRouterDialogueTests`)
- [ ] Placement pinned: `testAnswerTurnNeverReachesThe` + `InterpreterOrCache` (spy counters zero)
- [ ] C-2 news-parity anchors used (`:1210-1217` relaxed / `:1131-1138` strict)
- [ ] C-3 direct event construction carries `reason`; the metadata is never dropped
- [ ] M-5 executor bounds check in place and tested with a hostile index
- [ ] Safety: emergency dispatch proven with the frame clear forced to a no-op (E1 producer side); no model dependency on any consumed path (an unavailable brain cannot affect emergency, cancel, escape, expiry or barge-in)
- [ ] V-1 and V-4 recorded in the task log (gibberish order consumes no attempt; sanity guard placement unchanged)
- [ ] V-2: the diff adds no console write; events only
- [ ] Focused suite green: `CommandRouterDialogueTests` + existing router suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
