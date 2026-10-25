# T-132: Candidate assembly for did-you-mean probes

## Metadata
- **Group:** [TG-25 — Answer Classification and Merge](../index.md)
- **Component:** C-MTC-03 — new file `ios/ElderlyAssistant/Services/` + `Voice/DialogueCandidateBuilder.swift`
- **Agent:** dev
- **Effort:** S (1 day)
- **Risk:** MEDIUM
- **Depends on:** [T-125](../TG-24-dialogue-frame-foundations/T-125-dialogue-manager-frame-core.md), [T-126](../TG-24-dialogue-frame-foundations/T-126-dialogue-option-catalog.md), [T-130](T-130-keyword-intent-rule-provenance.md)
- **Blocks:** [T-134](../TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md), [T-138](../TG-27-observability-release-gate-and-security-evidence/T-138-release-log-gate-dialogue-roots.md)
- **Requirements:** [FR-MTC-004](../../../../define-requirements/FR/FR-MTC-004-candidate-choice-did-you-mean-probe.md), [FR-MTC-007](../../../../define-requirements/FR/FR-MTC-007-probe-budget-two-then-defaults.md), [NFR-MTC-010](../../../../define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md)

## Description
Turn the bounded near-match reading (T-130) into a did-you-mean candidate list:
one candidate per near-matched domain in rule order, a last-position general
hypothesis candidate only when at least one near-match exists, and a hard cap
at the frame's configured maximum. Zero candidates must yield no frame — the
caller keeps its existing honest dead-end line (FR-MTC-004 scenario 3).

## Acceptance criteria

```gherkin
Feature: Did-you-mean candidate assembly

  Scenario: Near-matches map one candidate per domain
    Given near-match readings for the news, video, music and app-launch families
    When candidates are built
    Then each domain contributes at most one candidate in its own compose form
    And a video near-match with no quotable query contributes no candidate
    And match keys record the matched rule tokens

  Scenario: The hypothesis candidate appears last and only alongside near-matches
    Given at least one near-match candidate
    When the list is built
    Then one general hypothesis candidate is appended in the last position
    And with zero near-matches the hypothesis is never offered alone

  Scenario: Zero near-matches build no frame
    Given an utterance with no near-match readings
    When candidates are built
    Then the candidate list is empty
    And the caller arms no frame and keeps its existing honest line

  Scenario: The cap keeps near-matches ahead of the hypothesis
    Given more candidate drafts than the configured maximum
    When the list is capped
    Then the retained candidates are the near-match candidates in rule order
    And the size never exceeds the configured maximum
```

## Implementation notes
- Use the frame config's maxCandidates (3) from T-125; the cap is a parameter,
  never a literal here.
- Never fabricate candidates: every candidate derives from a rule reading or
  the catalog vocabulary (FR-MTC-004). The hypothesis candidate is generic
  only; it must not invent a domain query.
- Candidate compose forms follow design-l2 §13; label rendering is template
  text from T-129 keys plus the rule's own vocabulary.
- Pure function: no frame mutation, no side effects; the caller (T-134) arms
  the frame. This keeps the trap surface (NFR-MTC-010) narrow.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueCandidateBuilderTests`)
- [ ] Zero-candidate behaviour pinned (no frame, existing line preserved)
- [ ] Focused suite green: `DialogueCandidateBuilderTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
