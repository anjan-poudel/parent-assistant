# NFR-SP-001: Provider search responsiveness and timeout budget

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (the Spotify tool mirrors `YouTubeTool`, whose fetch budget is the project's tool-timeout precedent) and the degradation contract (no silent failure / no hang); project constitution Agent Principles (timeouts are configurable parameters, not hardcoded constants)

## Description
A music request **must** resolve to a spoken outcome within a bounded time — an elderly voice-first user is never left in silence with no feedback. Measurable targets:

- **Provider round-trip budget**: each provider search uses a configurable timeout with a default of **8 s**, mirroring `YouTubeTool.fetchTimeoutSeconds` = 8 s (the same budget as the weather/search tools). The timeout is a parameter of the tool, not a hardcoded constant.
- **Outcome budget**: when at least one configured provider answers within its budget, the user hears the outcome (playback line, deep-link line, or fallback line) within **10 s** of the request being recognized, on a working network.
- **Negative budget**: when a provider exceeds its budget, the honest timeout outcome (FR-SP-012) is produced by the budget deadline; **no path blocks for more than 16 s total** (two sequential provider budgets) before speaking.
- **No unbounded waits**: no music path waits on an unbounded socket, an infinite retry, or a revoked-grant loop (FR-SP-010); retries are bounded and counted.

## Acceptance criteria

```gherkin
Feature: Provider search responsiveness

  Scenario: An answered request produces a spoken outcome within the budget
    Given a working network and a provider that answers within its budget
    When the user says "भजन बजाऊ"
    Then the spoken outcome occurs within 10 s of the request being recognized

  Scenario: A slow provider is cut off at the budget with an honest line
    Given a provider that does not answer
    When the budget (default 8 s) elapses
    Then the timeout outcome is produced by the deadline
    And the user hears the corresponding localized line

  Scenario: The timeouts are configurable, not hardcoded
    Given the tool is constructed with an injected timeout
    When the value differs from the default
    Then the tool uses the injected value in its request budget
```

## Related
- FR: FR-SP-002 (search), FR-SP-007 (tool), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)
