# T-019: `CloudTranslationTier` Orchestration

## Metadata
- **Group:** [TG-06 — Consent-Gated Cloud Translation Tier](index.md)
- **Component:** C08 orchestration + C15 cost integration
- **Agent:** dev
- **Effort:** XL
- **Risk:** CRITICAL
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-012](../TG-04-dictionary-and-cache/T-012-label-translation-cache.md), [T-014](../TG-05-consent-and-disclosure/T-014-consent-gate.md), [T-016](../TG-05-consent-and-disclosure/T-016-cloud-activity-indicator.md), [T-017](T-017-scene-text-sanitiser.md), [T-018](T-018-gemini-translate-client-and-prompt.md)
- **Blocks:** T-026, T-028, T-029
- **Requirements:** FR-LCT-009, FR-LCT-013, FR-LCT-018, NFR-LCT-001, NFR-LCT-010 · **AM-1, AM-8** · **CL-1, CL-2, CL-3, CL-4**

## Description

Orchestrate one translation attempt end to end in the design's fixed order — need, sanitise, consent,
budget, in-flight dedupe, one batched request, validated decode, store, release — with retry policy
centralised here rather than at any call site. The session-scoped cost latch closes after the first
refusal and never reopens in the session, and every termination is a rendered state.

Source: `Services/LiveTranslate/` `CloudTranslationTier.swift` (an actor) consuming the shipped
`GeminiClient` and `GeminiCostGovernor` under `ios/ElderlyAssistant/`. Tests mirror under
`ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Bounded, policy-correct cloud translation

  Scenario: The orchestration order is fixed
    Given a set of unresolved strings
    When an attempt runs
    Then it validates the need, sanitises and bounds, checks consent, checks budget, claims the keys, issues one batched request, decodes and validates, stores, and releases in that order
    And each step's policy lives here, not at a call site

  Scenario: A transient failure is retried once and only once
    Given a transport timeout, an offline or connection-lost failure, an HTTP 408 / 429 / 5xx, or a malformed or empty response
    When the tier handles it
    Then it retries at most once, re-using the same text-only payload shape
    And a second failure terminates the batch as degraded (FR-LCT-009)

  Scenario: Non-retryable failures never retry
    Given a policy refusal, an invalid request, an unconfigured provider, a consent failure, a spent budget or an exceeded deadline
    When the tier handles it
    Then no retry is attempted
    And the failure maps through the outcome's reason table rather than a re-derived classification (CL-4)

  Scenario: Consent is re-read before the retry
    Given a transient failure and a grant withdrawn before the retry attempt
    When the retry is considered
    Then the gate is consulted again, the retry is not attempted, and nothing is sent (AM-1, CL-2)

  Scenario: In-flight keys are claimed once and never re-requested
    Given the same unresolved key arriving from two regions in one cycle
    When the tier processes it
    Then the first claims it atomically and the second resolves when that request completes
    And one attempt is made and both regions resolve from it (AM-8, CL-1)

  Scenario: A resolved region never flips back to pending
    Given a resolved outcome for a region whose text is unchanged
    When the next cycle runs without that string
    Then the region stays resolved (FR-LCT-018)

  Scenario: Every claimed key is released on every exit path
    Given a request that ends by success, failure, timeout, cancellation or a gate decision
    When it terminates
    Then every claimed key is released in a deferred step
    And the indicator returns to off through the same release (T-016)

  Scenario: The deadline has one source of truth
    Given the batch deadline
    When it is derived
    Then it is the client's configured base timeout plus the configured grace
    And no second, divergent timeout constant exists in the feature (CL-8)

  Scenario: A spent budget latches for the session and never reopens
    Given the governor refusing a call
    When the tier observes the refusal
    Then it latches for the rest of the session and issues no further request in any shape
    And every cloud-bound region terminates as degraded with the cost reason, never with a tier claim (FR-LCT-013)
    And raising the cap mid-session does not reopen it — the next session re-consults the governor

  Scenario: Degradation is honest and specific
    Given any failure above
    When the outcome is published
    Then the region is degraded with its original text and the specific reason from the mapping
    And the reason is never a generic failure (CL-4)
```

## Implementation notes

- **The retryability table is the authority, not this task.** Classify through the design's
  **"Failure modes and retryability per asynchronous operation"** table in `specs/design-component.md`
  (rows 10–20 cover this tier). Do not cite any "C23" — that identifier does not exist in the
  component inventory (CL-8).
- **AM-1 / CL-2**: the consent re-read before a retry is a hard step, not an optimisation to skip
  because the first attempt already passed the gate.
- **AM-8 / CL-1**: one terminal outcome per region per cycle; the atomic claim is what makes duplicate
  strings in one scene a single attempt with a single shared outcome.
- **CL-3**: attribution maps resolution origin to tier explicitly — dictionary-layer hits and cache hits
  attribute dictionary; only a genuine cloud response attributes cloud. A cache-written cloud
  translation served later attributes dictionary, because it did not translate this time. Cover the
  mapper with unit tests.
- Deadline: the client's configured base timeout (the shipped 25 s) plus `cloudDeadlineGraceSeconds`
  (5). Exceeding it terminates the regions as degraded rather than leaving an unbounded pending state.
  `cloudMaxRetries` stays 1.
- Cost: consume the shipped governor exactly as shipped — `allowsCall()` is checked inside the client
  before any network work and `recordCall()` at the transport boundary. Do not re-implement the budget
  or add a second counter. The latch is the feature's only addition, and its `cost_exhausted_latched`
  event is additional to the governor's own unchanged events.
- Batching is the real cost lever: one scene's unresolved strings are one attempt, not one per string;
  a set exceeding the batch bounds splits into sequential batches rather than dropping strings.
- Emit `translation_batch_resolved` (with `resolvedCount`, `unresolvedCount`, `durationMs`),
  `translation_degraded`, `translation_dedupe_hit`, `cost_exhausted_latched` with counts and
  closed-vocabulary reasons only (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts exactly one retry for each transient class and none for each non-retryable class
- [ ] A test asserts consent is re-read before the retry and a withdrawal blocks it (AM-1)
- [ ] A test asserts the latched budget prevents further calls for the session, including after a cap change (FR-LCT-013)
- [ ] A test asserts a duplicate string in a cycle produces one attempt and one outcome (AM-8)
- [ ] Mapper tests cover origin-to-tier attribution for every path (CL-3)
- [ ] A test asserts every claimed key is released on every exit path
- [ ] Integration test against a stubbed transport, with the failure table's cases injected
- [ ] `ios/build.sh` passes
