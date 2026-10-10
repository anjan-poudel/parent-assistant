# T-114: Query-free logging variant for reused YouTube helpers (M-1)

## Metadata
- **Group:** [TG-21 — Router Music Path, Degradation and Tool Log](index.md)
- **Component:** C-SP-06 helpers: `fireYouTubePlay` / `deliverYouTubeFailure` (log surface)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-116](T-116-router-music-path.md), [T-121](../TG-23-release-gates-security-evidence-and-device-validation/T-121-release-log-safety-gate.md)
- **Requirements:** [FR-SP-004](../../../../define-requirements/FR/FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md), [FR-SP-005](../../../../define-requirements/FR/FR-SP-005-explicit-youtube-requests-unchanged.md), [NFR-SP-002](../../../../define-requirements/NFR/NFR-SP-002-log-safety.md), [NFR-SP-006](../../../../define-requirements/NFR/NFR-SP-006-no-regression.md)

## Description
Resolves security finding M-1: the YouTube fallback path reuses `fireYouTubePlay` and `deliverYouTubeFailure`, which log the raw query text. On music turns (fallback rows 4, 6, 7 and 8 of the §13 matrix) the music query must never reach logs, so those helpers gain a query-free logging variant; the default behaviour for explicit-YouTube turns stays byte-identical.

## Acceptance criteria

```gherkin
Feature: Query-free logging for the reused YouTube fallback helpers

  Scenario: A music fallback turn logs no query text
    Given a music turn whose fallback reaches the reused YouTube helpers (matrix rows 4, 6, 7, 8)
    When the helper logs through the query-free variant
    Then no fragment of the music query appears in the console, log or tool-log entries
    And the log entry still classifies the outcome for support purposes

  Scenario: Explicit YouTube turns are byte-identical
    Given the shipped explicit-YouTube fixtures
    When those turns run through the unchanged default logging path
    Then their console and log output is byte-identical to the baseline capture

  Scenario: Every entry of a music turn is covered
    Given a full music turn that falls back to YouTube
    When the tool-log test walks every entry the turn produces
    Then each entry carries the query-free values required by the contract
    And no entry carries music query or provider-body text
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Voice/CommandRouter.swift`: add the query-free variant with a default that preserves the current call sites exactly (no signature churn for existing callers).
- M-1 reference: helper sites at the current `fireYouTubePlay` and `deliverYouTubeFailure` regions; the raw query logging there is acceptable only for the explicit-YouTube path, which is the baseline being preserved.
- Byte-identical proof: capture baseline output for the explicit-YouTube fixtures before the change and assert equality after; this is the FR-SP-005 no-regression evidence.
- Extend the tool-log test to walk every entry of a music turn, not only the terminal one (carried into T-116's pin set).
- Log discipline: query text is the sensitive value here; outcome classifications stay (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests, including the byte-identical baseline assertion for explicit-YouTube turns
- [ ] Music-turn tool-log walk covers every entry of the turn
- [ ] No PII in logs — no music query text on any music-turn path
- [ ] `ios/build.sh` passes for the touched targets
