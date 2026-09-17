# T-029: Security Evidence Suite

## Metadata
- **Group:** [TG-10 — Release Gates and Evidence](index.md)
- **Component:** security-critical-path test suite and evidence index for the `security-test` gate
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md), [T-012](../TG-04-dictionary-and-cache/T-012-label-translation-cache.md), [T-014](../TG-05-consent-and-disclosure/T-014-consent-gate.md), [T-017](../TG-06-cloud-translation-tier/T-017-scene-text-sanitiser.md), [T-018](../TG-06-cloud-translation-tier/T-018-gemini-translate-client-and-prompt.md), [T-019](../TG-06-cloud-translation-tier/T-019-cloud-translation-tier.md), [T-026](T-026-translation-pipeline-and-session-model.md), [T-027](T-027-plugin-entry-and-session-view.md), [T-028](T-028-release-log-safety-gate-extension.md)
- **Blocks:** T-030
- **Requirements:** FR-LCT-014, NFR-LCT-001, NFR-LCT-005, NFR-LCT-006, NFR-LCT-007, NFR-LCT-008, NFR-LCT-009, NFR-LCT-013 · **AM-10** · **E1–E8 paths**

## Description

Consolidate the evidence that closes AM-1 through AM-10 into one suite the `security-test` gate can
read: consent fail-closed behaviour, text-only egress, content-free logs, encrypted cache at rest,
structural-character and marker resistance, the cost latch, and the negative cases that prove each
guard is a guard. The suite must demonstrate each guard **refusing** as well as permitting — a positive
test alone is not evidence.

Source: test targets under `ios/ElderlyAssistantTests/` `Services/LiveTranslate/` and the suite's
evidence index under the feature's spec area. No product source changes here except fixes for what the
suite proves broken.

## Acceptance criteria

```gherkin
Feature: Security evidence for the security-test gate

  Scenario: Every mandatory amendment has a named test
    Given amendments AM-1 through AM-10
    When the suite's index is read
    Then each amendment maps to at least one named test (AM-10)
    And each mapped test exists and passes in the standard test run

  Scenario: Consent guards are proven by refusal, not only by success
    Given the gate's failure modes (not recorded, stale version, denied, unreadable, revoked, revocation write failure)
    When the suite runs
    Then each denies, and the suite asserts that nothing was sent in each case
    And the withdrawal-between-attempts case asserts the retry did not occur (AM-1, AM-4, AM-7)

  Scenario: Zero requests are observed without a record
    Given an instrumented client double that records every outbound request
    When the feature is exercised under a dictionary miss, a batch and the retry path with no consent record
    Then zero requests are recorded in every one of those cases
    And the positive case (recorded consent) observes exactly the expected request

  Scenario: Egress is text-only and single-channel
    Given the instrumented client double
    When translation requests are made
    Then every request contains only sanitised items and the instruction text
    And no image, media, attachment, tool or grounding field appears in any request (AM-9)

  Scenario: Structural characters and marker-shaped input cannot change behaviour
    Given items containing the batch's structural characters, newlines, marker shapes and over-long text
    When the pipeline runs
    Then each string is translated to its own id or quarantined
    And no string changes the request's structure or the set of ids returned (AM-10)

  Scenario: Logs and events are content-free under a content-rich run
    Given a run in which translations, quarantined text and consent states all occur
    When every emitted event is captured and inspected
    Then no event field contains recognized text, translated text, a prompt or an identifier
    And every emitted key is in the allow-list (AM-2, AM-10)

  Scenario: The cache is encrypted at rest on a real write
    Given a populated cache
    When the on-disk bytes are inspected
    Then no plaintext recognized string or translation is present
    And the storage channel matches the placement policy (NFR-LCT-008)

  Scenario: The spend guard holds under repeated pressure
    Given the governor refusing a call
    When many batches are requested in the session
    Then the latch closes, exactly one latch event is recorded and no further request is made in any shape (NFR-LCT-013)

  Scenario: Every enumerated egress path is exercised
    Given the design's path enumeration for content egress
    When the suite runs
    Then each enumerated path is exercised by at least one test
    And any path that could not be exercised is recorded as a gap rather than covered by assertion

  Scenario: The evidence index states what was not proven
    Given the suite's results
    When the evidence index is read
    Then it lists the residual risks and the known gate limitations honestly (SR-1, AM-5)
    And it does not claim coverage for behaviour that was not exercised
```

## Implementation notes

- Coverage approach: instrument the client double (T-018), the log bus (T-003) and the storage layer
  (T-012/T-014) rather than asserting on product internals — evidence must come from the boundary, not
  from a white-box assumption.
- Negative-first: for each guard, the test that matters is the one proving it refuses. Order the suite
  so a permissive regression fails loudly and early.
- The suite is the grading subject for the `security-test` gate; the gate's completion is a workflow
  action, not part of this task. Do not run or edit workflow state.
- Residual risk SR-1 remains a recorded residual: document it in the evidence index, do not attempt to
  retire it silently. SD-5's joint review input is an owner action.
- Keep the suite runnable in the standard test invocation so it cannot rot; no manual setup beyond the
  test doubles.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Every amendment AM-1 through AM-10 maps to at least one named, passing test in the evidence index
- [ ] Every guard has a negative test proving refusal, not only a positive test
- [ ] The instrumented client double asserts zero requests in every denial scenario, including the retry path
- [ ] The evidence index lists residual risks, known limitations and unexercised paths (SR-1, AM-5)
- [ ] Integration test against stubbed transport and storage APIs
- [ ] Verified that a crash or hang of the translation model cannot affect consent, dictionary or capture paths
- [ ] `ios/build.sh` passes
