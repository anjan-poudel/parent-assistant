# NFR-CDP-008: Deterministic testability under the scoped-suite gate

## Metadata
- **Category:** Reliability / Testability
- **Priority:** MUST
- **Source:** Frozen design §8 ("scoped suites — the honest gate; full-bundle baseline is pre-existing red") and Risks ("the resolver is pure-static and closure-injected; scoped tests pin the matrix"); feature constitution Feature Constraint 12 ("Scoped/focused test suites are the honest gate ... The new resolver is pure-static and closure-injected so the chain matrix is deterministic without platform stubs."); workflow scope comment; project house practice (unit gates: focused tests + typecheck per unit; full suite once at the end).

## Description
The chain and its integration **must** be testable deterministically, without platform stubs. Measurable properties:

- **Zero platform dependencies in the matrix**: the WhatsApp probe is injected as a closure, Messenger handle availability is a plain boolean, and the resolver is pure-static — the chain matrix runs with **0 network calls and 0 app-installation requirements**.
- **Named scoped suites exist and pass**:
  - `CallChannelResolutionTests` — the full chain matrix: preferred feasible; preferred infeasible → secondary; both infeasible → phone; `secondary == primary` dedupe; per-contact pick wins as preferred; `fellBackFrom` content; the exhaustive 64-combination never-dead-end case (NFR-CDP-001).
  - `MethodResolverTests` — global-default step = settings primary mapped by call type; fallback applied before the confirmation.
  - Settings persistence — `secondaryCallApp` round-trip + `.phone` default (NFR-CDP-005).
  - Confirmation-prompt wording — the fallback disclosure names the routed channel.
  - Picker UI — the two sections render and persist.
- **Gate discipline**: scoped `-only-testing` runs are the honest gate; the full-bundle pre-existing red baseline is **recorded, not silently included or excluded**; the touched scoped suites show **0 new failures** versus the recorded baseline.

## Acceptance criteria

```gherkin
Feature: Deterministic coverage of the chain

  Scenario: The chain matrix runs without platform stubs
    Given the scoped test suites on a machine with no device and no installed apps
    When CallChannelResolutionTests runs the full matrix including the 64-combination case
    Then it completes deterministically with zero network calls
    And every cell's routed channel and fellBackFrom are asserted

  Scenario: The named suites cover the integration seams
    Given the feature's scoped suites
    When MethodResolverTests, the settings-persistence suite, the confirmation-wording checks and the picker-UI checks run
    Then each passes
    And the pre-existing full-bundle baseline is recorded alongside the results

  Scenario: No new failures are introduced in touched suites
    Given the recorded pre-feature baseline for the touched suites
    When the suites run against the feature build
    Then zero new failures appear
```

## Related
- FR: FR-CDP-005 (injected probe), FR-CDP-007/008 (the chain and its output), FR-CDP-012/013 (MethodResolver and wording)
- NFR: NFR-CDP-001 (the matrix that proves never-dead-ends), NFR-CDP-009 (baseline discipline)
