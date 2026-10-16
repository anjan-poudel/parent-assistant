# T-131: Answer path — classification, merge and barge-in

## Metadata
- **Group:** [TG-25 — Answer Classification and Merge](../index.md)
- **Component:** C-MTC-02 — new file `ios/ElderlyAssistant/Services/` + `Voice/DialogueAnswerPath.swift`
- **Agent:** dev
- **Effort:** L (4 days)
- **Risk:** HIGH
- **Depends on:** [T-125](../TG-24-dialogue-frame-foundations/T-125-dialogue-manager-frame-core.md), [T-126](../TG-24-dialogue-frame-foundations/T-126-dialogue-option-catalog.md), [T-128](../TG-24-dialogue-frame-foundations/T-128-barge-in-predicate-access-widenings.md), [T-130](T-130-keyword-intent-rule-provenance.md)
- **Blocks:** [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md), [T-138](../TG-27-observability-release-gate-and-security-evidence/T-138-release-log-gate-dialogue-roots.md)
- **Requirements:** [FR-MTC-005](../../../../define-requirements/FR/FR-MTC-005-voice-answer-capture.md), [FR-MTC-006](../../../../define-requirements/FR/FR-MTC-006-deterministic-frame-merge-and-execution.md), [FR-MTC-008](../../../../define-requirements/FR/FR-MTC-008-say-it-again-escape.md), [FR-MTC-010](../../../../define-requirements/FR/FR-MTC-010-cancel-drops-the-frame.md), [FR-MTC-012](../../../../define-requirements/FR/FR-MTC-012-barge-in-strong-new-command.md), [NFR-MTC-005](../../../../define-requirements/NFR/NFR-MTC-005-degraded-brain-deterministic-path.md), [NFR-MTC-008](../../../../define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md)

## Description
The pure, model-free answer brain: classify one utterance against one live
frame (capture ladder with vectors V1–V14, escape first, barge-in before
cancel/amendment, L2-D1 ordering) and merge an answer into the frame's command
deterministically (`InterpretedCommand.merging(message:)` memberwise copy
preserving all fields). Also defines the total candidate matching used by the
candidate-choice kind (M-5). No exit path consults a model, the network or the
intent cache.

## Acceptance criteria

```gherkin
Feature: Deterministic dialogue answer classification and merge

  Scenario: A catalog alias answer merges to the canonical query
    Given a live slot-fill frame for music with the bhajan catalog group
    When the answer containing only the primary alias is classified and merged
    Then the classification is an answer with a catalog match
    And the merged command is the frame's command with the catalog's canonical query
    And no model, network or cache path is consulted

  Scenario: Free-text answers are kept after transcript preparation
    Given a live slot-fill frame with a default query
    When a free-text answer within the length bound is classified and merged
    Then the merged query is the prepared free text
    And every other field of the frame's command is preserved unchanged

  Scenario: The any-option pick uses the default query
    Given a live slot-fill frame with a default query
    When the any-option label is answered
    Then the merged query is the default query

  Scenario: An over-length raw answer is invalid and never truncated
    Given a live slot-fill frame
    When the raw answer is at or above the raw length bound
    Then the classification is invalid with the over-length reason
    And no prefix of the answer is merged, echoed or stored

  Scenario: Escape is classified before every other reading
    Given a live frame of either kind
    When the answer is the localized escape phrase
    Then the classification is escape
    And no merge is attempted

  Scenario: A strong new command barges in with the original utterance preserved
    Given a live frame
    When the answer is a strong new command in the sensitive, call, video, music or news families
    Then the classification is barge-in with the raw utterance preserved for re-read
    And no dialogue merge is applied

  Scenario: Music inside a music frame is an answer, not barge-in
    Given a live music-domain frame
    When the answer is a new music request
    Then the classification is an answer
    And the barge-in path is not taken

  Scenario: The classifier is total over hostile inputs
    Given answers with out-of-range option indices, empty strings and control characters
    When each is classified or merged
    Then each returns a closed outcome without crashing or addressing outside the frame
```

## Implementation notes
- Ladder order (design-l2 §11, L2-D1): length guard on the raw text first
  (V14: at or above the raw bound is invalid, never truncated) → escape →
  cancel / amendment → the B1–B7 barge-in predicates → degenerate/repetition
  (V3) → catalog alias (V13) → any-option (V7) → free text (V4) → else invalid.
- One named test per vector V1–V14; V5/V6 (degenerate invalid), V10 (amendment
  re-ask), V11 (non-leading negation does not veto a strong command), V12
  (barge-in) are the trap-sensitive rows.
- **M-5 (security-design-review).** `classify` and the option matcher are total:
  any index is either within bounds or a closed invalid outcome; no crash, no
  out-of-range addressing. Hostile indices covered in T-139's matrix too.
- **L2-D9 (R2 bounded reading).** Only a candidate's own domain extractor may
  claim free text in a candidate-choice frame; with no claim the reading is
  invalid (protects FR-MTC-004's never-fabricate rule).
- **E7 producer.** The merge is a pure function over the frame's captured
  command: with the brain unavailable the same inputs produce the same merged
  command; the deterministic-merge test proves no interpreter dependency.
- Sanitisation: every merged or spoken fragment passes the shared preparation
  helper (T-127 semantics); raw content never reaches the merge untouched
  (NFR-MTC-008).
- Keep `merging(message:)` a memberwise copy of all 14 stored fields — a new
  field added to `InterpretedCommand` must surface here as a compile error
  (verified against the shipped initialiser).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueAnswerPathTests`, one named test per vector V1–V14)
- [ ] M-5 pinned: totality test over hostile indices/inputs; no out-of-range addressing
- [ ] E7 DoD line: brain-absent merge produces the identical command (no model, network or cache consulted on any path)
- [ ] `merging(message:)` preserves every other field (field-count assertion test)
- [ ] Focused suite green: `DialogueAnswerPathTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
