# T-134: Degenerate-music triggers and did-you-mean upgrades

## Metadata
- **Group:** [TG-26 — Router Interception and Window State](../index.md)
- **Component:** C-MTC-05 part 2 — `Services/` + `Voice/CommandRouter.swift` (music arm, interpreted-music block, rephrase-discard site, keyword-remainder reprompt); extend `ios/ElderlyAssistantTests/Services/` + `Voice/CommandRouterMusicTests.swift`
- **Agent:** dev
- **Effort:** L (3 days)
- **Risk:** HIGH
- **Depends on:** [T-130](../TG-25-answer-classification-and-merge/T-130-keyword-intent-rule-provenance.md), [T-132](../TG-25-answer-classification-and-merge/T-132-dialogue-candidate-builder.md), [T-133](T-133-router-dialogue-interception.md)
- **Blocks:** [T-139](../TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md), [T-140](../TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md), [T-141](../TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md)
- **Requirements:** [FR-MTC-002](../../../../define-requirements/FR/FR-MTC-002-degenerate-music-query-detection.md), [FR-MTC-003](../../../../define-requirements/FR/FR-MTC-003-slot-fill-probe.md), [FR-MTC-004](../../../../define-requirements/FR/FR-MTC-004-candidate-choice-did-you-mean-probe.md), [FR-MTC-007](../../../../define-requirements/FR/FR-MTC-007-probe-budget-two-then-defaults.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Wire the triggers that open frames, per design-l2 §14 edits 2–7: a degenerate
music outcome (keyword route or interpreted command with an absent query) opens
the slot-fill probe instead of a blind search; a rephrase dead end with
candidates upgrades to an honest lead plus the did-you-mean probe; the keyword
remainder reprompt gains the same upgrade when candidates exist. Specific
queries stay byte-identical, and every honest no-candidate line keeps its
shipped wording.

## Acceptance criteria

```gherkin
Feature: Frame-opening triggers with honest fallbacks

  Scenario: A degenerate music intake opens the probe instead of a blind search
    Given the music verb plus the generic marker is routed by keyword
    When the degenerate outcome is detected
    Then no music playback is attempted
    And a slot-fill probe is composed, spoken and armed with the catalog options and the default query

  Scenario: A specific query is untouched by the degenerate detection
    Given a specific occasion and artist phrase with the music verb
    When the normal music arm runs
    Then the fired music request equals the shipped request byte-for-byte
    And no dialogue frame is armed

  Scenario: An interpreted music command without a query opens the probe
    Given the interpreted path produces a music command with an absent query
    When the command is dispatched
    Then the probe path runs instead of a null-query search

  Scenario: A rephrase dead end with candidates upgrades to the did-you-mean probe
    Given a rephrase dead end whose utterance yields at least one near-match
    When the discard path runs
    Then the taken rephrase command is bound and composed with the frame
    And the honest lead line plus the did-you-mean probe are spoken and the frame is armed

  Scenario: A rephrase dead end with zero candidates keeps the shipped line
    Given a rephrase dead end whose utterance yields no near-match
    When the discard path runs
    Then the shipped discard line is spoken byte-identically
    And no frame is armed

  Scenario: The keyword remainder reprompt upgrades only when candidates exist
    Given the keyword remainder path with near-match candidates
    When the reprompt is composed
    Then the honest prefixed reprompt plus the did-you-mean probe are spoken and the frame is armed
    And with zero candidates the shipped reprompt line is byte-identical
```

## Implementation notes
- **C-5 (review-l2).** Bind the taken rephrase command at `CommandRouter.swift:806`
  (`taken`) and compose it into the frame; the current drop becomes a capture.
- Trigger sites: the music arm `:1223-1234` (degenerate branch), the
  interpreted-music block, the rephrase-discard site (:806 region), and the
  keyword-remainder honest lines (`:1968-2030`, incl. `router.reprompt` at
  `:2021` and the sensitive-blocked block `:1973-1980`).
- Every degenerate event uses the closed vocabulary (`dialogue_degenerate_query`
  with the intake source; `dialogue_probe_spoken` on speak).
- **NFR-MTC-012.** The no-candidate branches, the cloud-failure branch and the
  no-brain honest lines are byte-identical; the upgrade is additive on the
  candidate-positive path only.
- **V-2.** No console writes; events only.
- Sequential with T-133 (same file): rebase on T-133 before starting.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (extended `CommandRouterMusicTests` + degenerate-trigger tests)
- [ ] C-5 pinned: the taken rephrase command is bound and composed (test asserts the composed frame query)
- [ ] Byte-identity pins: specific music requests, zero-candidate lines, cloud-failure branch unchanged
- [ ] V-2: no console write added
- [ ] Focused suites green: `CommandRouterMusicTests` + keyword-remainder suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
