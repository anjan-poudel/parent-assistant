# T-140: Cache-bypass, log-capture and egress suites

## Metadata
- **Group:** [TG-27 — Observability, Release Gate and Security Evidence](../index.md)
- **Component:** new tests `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueCacheBypassTests.swift` and `Services/` + `Observability/DialogueLogAndEgressTests.swift`
- **Agent:** dev
- **Effort:** M (2.5 days)
- **Risk:** HIGH
- **Depends on:** [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md), [T-134](../TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md), [T-136](../TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md), [T-137](T-137-log-sanitiser-dialogue-keys.md), [T-138](T-138-release-log-gate-dialogue-roots.md)
- **Blocks:** [T-141](../TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md), [T-142](../TG-28-acceptance-evidence-and-device-protocol/T-142-security-evidence-index.md)
- **Requirements:** [FR-MTC-017](../../../../define-requirements/FR/FR-MTC-017-transcript-cache-bypass.md), [NFR-MTC-003](../../../../define-requirements/NFR/NFR-MTC-003-no-new-network-egress.md), [NFR-MTC-004](../../../../define-requirements/NFR/NFR-MTC-004-log-safety.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Prove the three boundary properties the design promises: answer turns bypass the
transcript cache and never enter persistence (E8, V-3), no dialogue path emits
user content to logs (E4/E5 runtime half), and no dialogue path constructs any
new network egress (E6). These are evidence suites: a green suite here is the
security-test gate's raw material.

## Acceptance criteria

```gherkin
Feature: Cache, log and egress boundaries

  Scenario: A cached transcript does not serve an answer turn
    Given a confirmed-command cache entry that would match the answer utterance
    When the answer is routed to a live frame
    Then the cached transcript is not served
    And the answer text is never interned into the cache (E8)

  Scenario: Frame execution leaves persistence untouched
    Given a live frame about to execute its merged command
    When the merged command executes
    Then the pending transcript stays nil on the frame path
    And the confirmed-execution recording behaviour is unchanged (V-3)

  Scenario: A full dialogue emits no content to any sink
    Given a capturing log sink and the full dialogue scenario set (probe, answer, merge, cancel, timeout, escape, exhaustion, did-you-mean)
    When each scenario runs
    Then every emitted payload contains only allow-listed keys
    And no raw or partial transcript text appears in any sink (E4/E5)

  Scenario: The allow-list diff is exactly the six new keys
    Given the allow-list before and after the feature diff
    When the keys are compared
    Then exactly the six documented keys were added and the reason key was reused (E5)
    And an out-of-vocabulary token value is rejected or redacted

  Scenario: No dialogue path constructs new network egress
    Given the dialogue source files and a network-construction spy suite
    When every dialogue path executes (probe, answer, merge, cancel, exhaustion, default execution)
    Then no new host, endpoint or transport is constructed (E6)
    And the merged music execution goes through the existing offline helper only
```

## Implementation notes
- **E8 / FR-MTC-017 / V-3:** re-verify the answer flow vs persistence boundary
  AFTER implementation (V-3 is a re-verification, not an assumption): spy on
  the cache and on the transcript hand-off; assert zero writes on the frame
  path and no change to the confirmed-execution recording (the recording keeps
  working for confirmed commands — negative control row).
- **E4/E5:** drive a capturing sink through the production pipeline
  (sanitiser + allow-list); assert absence of content by scanning payload
  strings for planted markers (plant distinctive tokens in the fixtures, then
  assert they never appear). This complements the static gate from T-138.
- **E6:** combine a source-audit check (no new URL/transport construction in
  the feature's files) with a runtime spy over the executed paths; the merged
  music request must reach the existing playback helper only (NFR-MTC-003).
- Keep the suites deterministic: inject the clock and the doubles; no sleeps.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueCacheBypassTests`, `DialogueLogAndEgressTests`)
- [ ] E4/E5 DoD: log capture over a full dialogue shows zero content; allow-list diff is exactly six new keys with closed tokens and the unlisted-key drop in force
- [ ] E6 DoD: egress audit shows no new host, endpoint or transport construction
- [ ] E8 DoD: no answer text reaches `pendingTranscript` or the intent cache (`testPendingTranscriptStaysNilOnFrame` + `Execution`; `testConfirmedExecutionRecordingIs` + `Unchanged` as the negative control)
- [ ] V-3 re-verified and recorded in the task log
- [ ] Focused suites green: both new suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
