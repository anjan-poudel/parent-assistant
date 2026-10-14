# T-185 — Release log-surface gate coverage for the new chat paths

## Metadata
- **Group:** [TG-38 — Release Gate, Acceptance and Device Validation](index.md)
- **Component:** Release log-safety gate (design-l1 section 16; FR-CNR-012)
- **Agent:** dev
- **Effort:** S (about 1 day)
- **Risk:** HIGH
- **Depends on**: T-168 ([T-168](../TG-34-style-spec-chat-decode-and-persona-seams/T-168-cloud-chat-responder-and-explicit-temperature.md)), T-174 ([T-174](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-174-guard-flag-resolution-at-the-dispatch-seam.md)), T-175 ([T-175](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-175-router-cloud-first-chat-lane.md)), T-177 ([T-177](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-177-indicator-revocation-and-coordinator-wiring.md))
- **Blocks:** T-186 ([T-186](T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-012](../../../define-requirements/FR/FR-CNR-012-cloud-chat-credential-and-content-hygiene.md), [NFR-CNR-006](../../../define-requirements/NFR/NFR-CNR-006-log-safety.md), [NFR-CNR-011](../../../define-requirements/NFR/NFR-CNR-011-compliance-and-release-gates.md)

## Description
Extend the release log-safety gate over the feature's new sources so that conversation content, reply text and key material cannot reach a Release log surface: the new chat, routing, guard and consent paths join the stricter feature role (no Release-compiled console write in these sources at all; content forbidden in any configuration; event fields restricted to the allowed-key set), the gate keeps its place ahead of every test scope in the build, and the existing fixtures prove the new coverage is real.

## Acceptance criteria

```gherkin
Feature: The release log gate covers the new chat paths

  Scenario: The gate passes over the shipped sources
    Given the feature's new sources (chat responder, router lane, guard, consent and indicator paths)
    When the release log-safety gate runs
    Then it exits zero with the new paths inside its coverage
    And the gate runs ahead of the test scopes in the build (its exit code gates the build)

  Scenario: The stricter role is applied to the new paths
    Given a Release-compiled console write in one of the feature's sources
    When the gate runs
    Then it fails, naming the file and the statement (the stricter role forbids the write regardless of what it renders)

  Scenario: Content in any configuration is caught
    Given a transcript or reply text rendered into a console write or an event field in any build configuration
    When the gate runs
    Then it fails

  Scenario: Event fields stay inside the allowed-key set
    Given the reply-grammar-flag event and the fallback events
    When the gate inspects the emission sites
    Then every event key is in the sanitizer's allowed-key set and no text value is interpolated into a field
```

## Acceptance criteria — failure paths

```gherkin
Feature: Gate failure behaviour

  Scenario: A seeded violation proves the coverage
    Given a deliberately seeded raw print in a new feature path
    When the gate runs
    Then it fails and names that file (a demonstration that the coverage is real, not assumed)

  Scenario: An uncovered new path
    Given a feature source file that renders content and is not inside any scanned root
    When the coverage is audited
    Then the missing root is reported as a gate defect and the file is added — the gate must not be able to pass by not looking

  Scenario: The existing fixtures are not weakened
    Given the pre-existing rule families and their fixtures
    When the extended gate runs
    Then the existing fixtures behave exactly as before (this unit adds coverage; it removes no rule and relaxes no fixture)
```

## Inputs and expected result

**Input:** the shipped release log-safety gate (script, wrapper and fixtures) and its rule families; the feature's new source paths and their console-write/event-emission sites (T-168, T-174, T-175, T-177); the sanitizer's allowed-key policy.

**Output:** the extended gate coverage over the new paths with the stricter feature role, the seeded-violation demonstration, and the audit that no new content-rendering path is unscanned.

**Declared files:** `ios/tools/check-release-log-safety.py`, `ios/tools/check-release-log-safety.sh`

## Implementation notes
- The gate's stricter feature role exists for exactly this situation: a feature whose sources have no legitimate content-bearing console write joins the roots where any Release-compiled write fails, and where content in any configuration fails. The new chat sources have no legitimate content write either — the guard emits a verdict, events carry classification, the consent gate carries a record.
- Keep the rule semantics intact: rule families and their fixtures are untouched; this unit changes the set of scanned roots and (where needed) the statements the stricter role inspects.
- The build wiring is the enforcement point: the gate's exit code must be able to fail the build ahead of every test scope (it already is wired in the house build script — confirm, do not duplicate).
- Events: `reply_grammar_flag` and `cloud_chat_fallback` are classification-only by design; the allowed-key check over their emission sites is what keeps a later well-meaning change from adding a content field.
- Content-hygiene precedent (B2/T-050): the provider key travels in the header only — the gate's key-material rules apply to the new request path as they do elsewhere.

## Definition of done
- [ ] New feature paths inside the gate's coverage with the stricter role applied
- [ ] Gate exits zero over the shipped sources and runs ahead of the test scopes in the build
- [ ] Seeded-violation demonstration recorded (gate red on a seeded raw print in a new path)
- [ ] Event emission sites validated against the allowed-key set; no text interpolated into fields
- [ ] Existing rule families and fixtures unchanged and passing
- [ ] Coverage audit recorded: no new content-rendering path left unscanned
