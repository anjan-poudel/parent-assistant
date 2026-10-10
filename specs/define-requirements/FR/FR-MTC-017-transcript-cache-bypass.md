# FR-MTC-017: Transcript-cache bypass during answer capture

## Metadata
- **Area:** Cache Discipline
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 7 ("During `awaitingSlotAnswer`, the transcript cache (`IntentCommandCache`) is bypassed — answers are never cacheable inputs; only confirmed *merged* commands are recorded"); feasibility study §8 ("`IntentCommandCache` short-circuits the frame — during `awaitingSlotAnswer`, bypass the transcript cache (answers are never cacheable inputs); only confirmed *merged* commands are recorded"); worktree surface verified: `Services/Intents/IntentCommandCache.swift` (normalized-transcript → command cache sitting "in `IntentRouter` BEFORE any model", header invariants `:1-27`).

## Description
While a frame is awaiting an answer, the normalized-transcript → command cache (`IntentCommandCache`) **must** be bypassed on both directions of its interface:

- **No cache reads for answers**: the answer transcript is never resolved from the cache — an answer is frame-relative (e.g. a bare "दुर्गा" is only meaningful against the outstanding probe) and must never be executed as a standalone cached command. The interception (FR-MTC-009) and the deterministic merge (FR-MTC-006) own the answer turn.
- **No cache writes for answers**: answer utterances are never recorded as cacheable transcripts; the cache's "freshest **confirmed** interpretation wins" discipline only ever sees confirmed command executions.
- **Only confirmed merged commands may be recorded**: after a merged command actually executes (with the normal confirmation discipline for its tier), the existing caching rules apply to that confirmed execution — and `IntentCommandCache.isCacheable` semantics stay unchanged (music remains cacheable for real commands; answers, which never execute standalone, are not candidates).
- **After resolution, normal caching resumes**: once the frame resolves, the next real command uses the cache exactly as today (its first-hit speed and its confirmation invariants unchanged; NFR-MTC-012).
- **Answer text stays out of any cross-session store**: no answer transcript is interned into the encrypted cache store or any other persistence (FR-MTC-001's no-persistence rule).

## Acceptance criteria

```gherkin
Feature: Transcript-cache bypass during answer capture

  Scenario: An answer that exactly matches a cached transcript is not served from the cache
    Given the transcript "दुर्गा" exists in the command cache from some earlier confirmed command
    And the frame is awaiting an answer
    When the user says "दुर्गा" as the answer
    Then the cache does not resolve it
    And the answer is handled by the frame's capture and merge path

  Scenario: An answer is never interned into the cache
    Given the user answers a probe (valid, invalid, or cancelled)
    When the turns complete
    Then no answer transcript is recorded as a cacheable entry

  Scenario: A confirmed merged command is recorded and behaves like any confirmed execution
    Given the probe answered with "दुर्गा भजन" and the merged command executed and completed its normal confirmation discipline
    When the user next says a real command that is cacheable
    Then the cache behaves exactly as today for that command
    And nothing about the bypass changed the cache's normal semantics
```

## Related
- FR: FR-MTC-009 (interception owns the answer turn), FR-MTC-006 (merge), FR-MTC-001 (no persistence)
- NFR: NFR-MTC-012 (cache semantics unchanged outside the window), NFR-MTC-008 (no new injection surface via cached answers)
