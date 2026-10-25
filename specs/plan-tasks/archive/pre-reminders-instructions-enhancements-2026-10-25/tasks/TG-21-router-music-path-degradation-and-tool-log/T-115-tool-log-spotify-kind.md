# T-115: LocalToolLogStore spotify kind and tool-log view switches (C-4)

## Metadata
- **Group:** [TG-21 — Router Music Path, Degradation and Tool Log](index.md)
- **Component:** C-SP-14 `LocalToolLogStore` / `ToolLogReviewView`
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-116](T-116-router-music-path.md), [T-122](../TG-23-release-gates-security-evidence-and-device-validation/T-122-golden-corpus-supersession.md)
- **Requirements:** [FR-SP-012](../../../../define-requirements/FR/FR-SP-012-honest-outcomes-no-silent-failure.md), [NFR-SP-002](../../../../define-requirements/NFR/NFR-SP-002-log-safety.md)

## Description
Adds the Spotify kind to the local tool log and updates the review view. Review finding C-4: `ToolLogReviewView` has two exhaustive switches over `Kind` (the label mapping and the icon mapping) with no default, so the new kind fails to compile until both arms exist. Both switches get the case; the log contract (§21) keeps query and response fields empty for Spotify rows.

## Acceptance criteria

```gherkin
Feature: Spotify tool-log kind

  Scenario: A Spotify log entry renders in the review view
    Given a stored tool-log entry of the new Spotify kind
    When the review view renders it
    Then the label switch returns the Spotify label key
    And the icon switch returns the Spotify icon case
    And the rendered row shows the outcome classification

  Scenario: The new kind compiles through every exhaustive switch
    Given the tool-log view sources
    When the project builds
    Then both Kind switches handle the Spotify case
    And no default arm was added to silence exhaustiveness

  Scenario: Spotify rows respect the log contract
    Given a Spotify tool-log entry written by the router
    When the entry is inspected
    Then query and response fields are empty unless the row is the terminal honest line
    And the entry carries no query text, token or provider body
```

## Implementation notes
- Files: `ios/ElderlyAssistant/` + `Services/` + `ToolLogReviewView.swift` (label case and icon case — both switches) and `LocalToolLogStore.swift` (new kind); C-4 is the icon-switch finding; add the label case in the same edit.
- Contract §21: Spotify rows keep query `""` and response `""` except the terminal honest line; `metadata: [:]`; closed event vocabulary. Writing behaviour itself is wired in T-116 — this task provides the kind and the view.
- Extend `LocalToolLogStoreTests` with the new kind round-trip and the contract assertion; the review-view label/icon mapping gets a mapping test mirroring `SettingsTabMappingTests` style.
- No PII in logs — the kind must not carry query text (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (LocalToolLogStoreTests + view mapping test)
- [ ] Both exhaustive switches updated; no default arm added
- [ ] No PII in logs — kind and entries carry no query text
- [ ] `ios/build.sh` passes for the touched targets
