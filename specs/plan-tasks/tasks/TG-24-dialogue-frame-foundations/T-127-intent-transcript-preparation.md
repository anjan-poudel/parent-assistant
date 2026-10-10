# T-127: Shared input-seam helper (`IntentTranscriptPreparation`)

## Metadata
- **Group:** [TG-24 — Dialogue Frame Foundations](../index.md)
- **Component:** C-MTC-08c — new file `ios/ElderlyAssistant/Services/` + `Intents/IntentTranscriptPreparation.swift`; edit `Services/` + `Intents/LocalBrainChain.swift`
- **Agent:** dev
- **Effort:** S (1 day)
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-136](../TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md)
- **Requirements:** [NFR-MTC-008](../../../../define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md), [FR-MTC-006](../../../../define-requirements/FR/FR-MTC-006-deterministic-frame-merge-and-execution.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Extract the transcript-preparation order (raw capture, sanitisation, optional
seam transform, prepared text) into a shared helper so the answer path (T-136's
`prepareDialogueAnswerText`) and `LocalBrainChain.turnInput` use one source of
truth. The rewire must be behaviour-preserving byte-for-byte: the helper is the
same order, the same inputs, the same outputs.

## Acceptance criteria

```gherkin
Feature: Shared transcript preparation seam

  Scenario: A non-nil seam produces the same prepared text as the historical path
    Given transcript fixtures including a transform-hit and a transform-miss input
    And a seam that applies the production transform
    When the helper prepares each fixture
    Then raw, sanitised and prepared values match the historical turn-input outputs byte-for-byte

  Scenario: A nil seam is a raw pass-through and is test-only parity
    Given the same fixtures and a nil seam
    When the helper prepares each fixture
    Then the sanitised and prepared values equal the raw transcript unchanged
    And the helper documents that production always wires the seam non-nil

  Scenario: A transform-hit input never yields an unprepared value
    Given a transcript containing text the production transform rewrites
    When the helper prepares it with the production seam
    Then the prepared value contains the transformed text
    And no code path returns the untransformed text as prepared

  Scenario: The chain rewire changes no existing behaviour
    Given the existing brain-chain test suite
    When the chain delegates to the shared helper
    Then every existing chain test passes unmodified
```

## Implementation notes
- **C-5 (review-l2).** Comment the nil-seam raw-passthrough parity in the new
  helper next to the seam parameter, citing the shipped nil-seam path at
  `LocalBrainChain.swift:275-285`.
- **M-3 (security-design-review).** This helper is the sanitiser discipline's
  single seam; the production wiring is pinned non-nil at
  `AppCoordinator.swift:1824` and re-pinned by T-136's focused test. The
  nil-seam branch exists for parity tests only.
- Keep the helper free of side effects: pure function over (raw, seam); no
  caching, no logging (NFR-MTC-012 log-safety by construction).
- Rewire `turnInput` in place; do not rename or move existing public surface.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`IntentTranscriptPreparationTests`)
- [ ] C-5 parity comment present in the helper
- [ ] Existing `LocalBrainChain` tests pass unmodified; no output diff on fixtures
- [ ] Focused suites green: `IntentTranscriptPreparationTests` + the existing brain-chain suite; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
