# T-139: Hostile-answer corpus and trap matrix suites

## Metadata
- **Group:** [TG-27 — Observability, Release Gate and Security Evidence](../index.md)
- **Component:** new tests `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueHostileCorpusTests.swift` and `DialogueTrapMatrixTests.swift`
- **Agent:** dev
- **Effort:** L (3.5 days)
- **Risk:** HIGH
- **Depends on:** [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md), [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md), [T-134](../TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md), [T-136](../TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md)
- **Blocks:** [T-141](../TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md), [T-142](../TG-28-acceptance-evidence-and-device-protocol/T-142-security-evidence-index.md)
- **Requirements:** [FR-MTC-011](../../../../define-requirements/FR/FR-MTC-011-emergency-precedence-mid-frame.md), [NFR-MTC-008](../../../../define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md), [NFR-MTC-010](../../../../define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md)

## Description
Turn the security-design-review's E1–E3 obligations into executable suites: the
emergency-precedence proof, the hostile free-text answer corpus running through
the production-shaped (non-nil) seam, and the trap matrix that ends every
mid-window interruption in a terminal resolution. These suites are the feature's
adversarial evidence; each row asserts an observable effect, never merely that a
call returned.

## Acceptance criteria

```gherkin
Feature: Hostile answers and trap paths

  Scenario: Emergency mid-frame dispatches independently of the frame clear
    Given a live frame and an emergency utterance
    When the utterance is routed
    Then emergency dispatch runs
    And with the frame clear forced to a no-op the dispatch still runs (E1)
    And the frame is cleared with the emergency outcome afterwards

  Scenario: Hostile answers through the production-shaped seam change nothing beyond the frame's admissible effects
    Given a live frame and the non-nil production seam
    When each hostile corpus row is answered (injection markers, control characters, tool-shaped payloads, candidate poisoning, authority claims)
    Then each row resolves to a closed classification or a re-probe
    And the interpreter spy and cache spy record zero calls and the process does not crash (E2)

  Scenario: Out-of-range candidate indices are refused end to end
    Given a live candidate-choice frame
    When a hostile index answer is routed
    Then the executor refuses it and no candidate outside the list is addressed (M-5, E2)

  Scenario: The trap matrix terminates every interruption
    Given the trap rows: cancel, escape, barge-in, timeout, expiry, Talk mid-window, watchdog mid-window and pipeline events mid-window
    When each row runs against a live frame
    Then each row reaches a terminal resolution with no live frame left behind (E3)
    And after the window hourglass passes no half-open window exists
    And resolving twice is a no-op in every row
```

## Implementation notes
- **E1:** assert dispatch by the emergency double's side effect with the clear
  forced to a no-op — the proof must be independent of the new code path.
- **E2:** the hostile corpus must run through the same wiring the app uses
  (non-nil seam; production-shaped coordinator tester, not a bespoke nil-seam
  harness — M-3). One named test per corpus row; assert zero interpreter
  invocations, zero cache invocations and no crash for every row.
- **E3:** use the session machine's test clock; assert terminal resolution and
  idempotent resolve per row; the pipeline-events row is the M-1 pin, the
  Talk/watchdog rows are the M-2 pins.
- **M-5:** the hostile-index row exercises the executor's bounds check
  (T-133) on top of the classifier's totality (T-131).
- These files are the E1/E2/E3 producer evidence; results feed the T-142
  index.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueHostileCorpusTests`, `DialogueTrapMatrixTests`; one named test per corpus and trap row)
- [ ] E1 DoD: emergency dispatch proven with the frame clear forced to a no-op
- [ ] E2 DoD: every corpus row resolves to the frame's admissible effects or a re-probe/close; no interpreter, no cache, no crash
- [ ] E3 DoD: every trap row reaches a terminal resolution; no half-open window after the window passes
- [ ] M-1/M-2/M-3/M-5 pins referenced in test names or comments so the T-142 index can cite them
- [ ] Focused suites green: both new suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
