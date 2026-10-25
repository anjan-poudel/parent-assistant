# T-125: Dialogue frame, manager and probe composer

## Metadata
- **Group:** [TG-24 — Dialogue Frame Foundations](../index.md)
- **Component:** C-MTC-01 — new file `ios/ElderlyAssistant/Services/` + `Voice/DialogueManager.swift`
- **Agent:** dev
- **Effort:** M (2 days)
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md), [T-132](../TG-25-answer-classification-and-merge/T-132-dialogue-candidate-builder.md), [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md)
- **Requirements:** [FR-MTC-001](../../../../define-requirements/FR/FR-MTC-001-dialogue-frame-lifecycle.md), [FR-MTC-003](../../../../define-requirements/FR/FR-MTC-003-slot-fill-probe.md), [FR-MTC-007](../../../../define-requirements/FR/FR-MTC-007-probe-budget-two-then-defaults.md), [FR-MTC-016](../../../../define-requirements/FR/FR-MTC-016-template-generated-probes.md), [NFR-MTC-009](../../../../define-requirements/NFR/NFR-MTC-009-voice-only-accessibility.md)

## Description
Create the dialogue-frame core exactly per design-l2 §8: `DialogueFrame` with
its two factories (slot-fill and candidate-choice), `DialogueFrameResolution`
(closed enum including the `.emergency` outcome), `DialogueError` (closed case
vocabulary), `DialogueConfig` values (maxProbes 2, maxCandidates 3,
maxSlotOptions 4) and `DialogueManager` with injected answer-window value and
injected clock. It owns arm-time validation, expiry-aware reads, attempt
restamping, idempotent resolution and template-only probe composition. No other
component may store frame state.

## Acceptance criteria

```gherkin
Feature: Dialogue frame lifecycle and probe composition

  Scenario: Arming stamps the deadline from the injected window and stores one frame
    Given a slot-fill frame draft with candidates and a default query
    And the injected answer window is W seconds and the clock is T
    When the frame is armed through the manager
    Then exactly one frame is held with a deadline of T + W
    And the frame records its probe kind, the missing slot and attempt 1

  Scenario: An expired frame resolves to no frame on read
    Given an armed frame whose deadline has passed
    When the live frame is read
    Then no frame is returned
    And the next utterance is handled as a fresh command by the caller

  Scenario: Arming is refused while a window is live
    Given a live frame
    When a second frame is armed
    Then the arm throws the closed window-busy error
    And the live frame and its deadline are untouched

  Scenario: A draft with neither candidates nor a default is not armable
    Given a frame draft with no candidates and no default query
    When the arm runs
    Then it throws the closed no-resolution error
    And no frame is stored

  Scenario: A re-probe restamps the deadline without changing the captured data
    Given a live frame and a later clock reading
    When the attempt is noted
    Then the attempt count increments and the deadline restamps from the later reading
    And the captured query and candidates are unchanged

  Scenario: Resolution clears every field and is idempotent
    Given a live frame
    When it is resolved with any outcome in the closed set
    Then the held frame is cleared
    And a second resolution of the same frame is a no-op

  Scenario: Probe text is template-composed with bounded options
    Given a slot-fill frame and a loaded catalog group with more labels than the cap
    When the probe text is composed for the Nepali locale
    Then the question is the group's localized template with at most the capped labels plus the any-option label
    And the retry variant prefixes the localized retry prefix exactly once
```

## Implementation notes
- Main-queue confinement mirrors the existing confirmation window design; no
  locks, no actors (the manager is only touched on the main queue).
- **C-1 (review-l2).** The answer-window default arrives as an injected value;
  do not address `Config.confirmationTimeoutSeconds` at the type level anywhere
  (it is an instance `var` at `App/VoiceSessionStateMachine.swift:95`). Keep the
  value single-source there; the coordinator passes it in (T-136).
- The 45 s window, the probe cap and the option cap are parameters, never inline
  literals in call bodies (design-l2 §27; OD-M1 default 2 probes).
- Probe composition is template-only: fixed localizable strings plus catalog
  labels; model-generated text is out of scope (NFR-MTC-009: every probe is
  spoken, no screen interaction required).
- The composer resolves labels through `L10n` keys added by T-129; matching
  tables are plain inputs, not file reads.
- File-scope: this file is new; nothing else in the wave edits it.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueFrameTests`)
- [ ] C-1 pinned: the init takes the window by injection; no new literal; no type-level access to the session machine's instance config
- [ ] Config knobs (2 / 3 / 4) are constructor values with the design defaults, not call-site literals
- [ ] Focused suite green: `DialogueFrameTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
- [ ] This file writes no console output and no observability metadata (log safety by construction)
