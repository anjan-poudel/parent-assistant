# T-137: `LogSanitiser` dialogue metadata keys (M-4)

## Metadata
- **Group:** [TG-27 — Observability, Release Gate and Security Evidence](../index.md)
- **Component:** `Services/` + `Observability/LogSanitiser.swift`; extend `ios/ElderlyAssistantTests/Services/` + `Observability/LogSanitiserTests.swift`
- **Agent:** dev
- **Effort:** S (0.5 day)
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-140](T-140-cache-bypass-log-and-egress-suites.md)
- **Requirements:** [NFR-MTC-004](../../../../define-requirements/NFR/NFR-MTC-004-log-safety.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Admit exactly the six new dialogue metadata keys into the log allow-list —
`intake`, `probe_kind`, `attempt`, `option_count`, `capture_form`,
`merge_source` — each with a justification comment and its closed token set,
and confirm `reason` is already admitted and carries the new closed dialogue
tokens. The default-deny posture is unchanged: any unlisted key is still
dropped, and no key may ever carry verbatim transcript content.

## Acceptance criteria

```gherkin
Feature: Dialogue metadata log-allow-list

  Scenario: The six new keys are admitted with closed value sets
    Given the updated allow-list
    When a dialogue event carries the six new keys with in-vocabulary values
    Then every pair survives the filter and appears sanitised in the output

  Scenario: The reused reason key is already admitted
    Given a dialogue event whose reason value is an in-vocabulary dialogue token
    When the filter runs
    Then the reason pair survives without any allow-list change for it

  Scenario: An unlisted key is still dropped
    Given an event carrying an unlisted key whose value is verbatim answer text
    When the filter runs
    Then the unlisted key never appears in any output sink
    And the allowed pairs of the same event are unaffected

  Scenario: Out-of-vocabulary token values fail closed
    Given an event whose new-key value is outside its documented token set
    When the filter or the event producer validates it
    Then the value is rejected or redacted rather than logged
```

## Implementation notes
- **M-4 (security-design-review).** Six NEW keys (do not re-add `reason`; it is
  already in `allowedKeys`, `LogSanitiser.swift:175` region). Each new key's
  comment names its closed token vocabulary:
  `intake` {keyword, interpreted, rephrase, remainder}; `probe_kind` {slotFill,
  candidateChoice}; `attempt` {1, 2}; `option_count` {0..n bounded};
  `capture_form` {catalog, anyOption, freeText, index}; `merge_source`
  {catalog, default, freeText, amendment}.
- No value may carry user text: all six are enumerations or small counts by
  construction (NFR-MTC-004).
- This task is the E5 producer; the allow-list diff and the end-to-end capture
  assertions land in T-140.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`LogSanitiserTests` extended)
- [ ] Exactly six new keys; `reason` untouched; unlisted-key drop pinned (E5 producer line)
- [ ] Justification comments with closed token sets present for every new key
- [ ] Focused suite green: `LogSanitiserTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
