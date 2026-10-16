# T-138: Release log gate — feature roots and fixtures

## Metadata
- **Group:** [TG-27 — Observability, Release Gate and Security Evidence](../index.md)
- **Component:** C-MTC-10 — `ios/tools/` + `check-release-log-safety.py`; fixture trees under `ios/tools/` + `log-safety-fixtures/`
- **Agent:** dev
- **Effort:** S (1 day)
- **Risk:** HIGH
- **Depends on:** [T-125](../TG-24-dialogue-frame-foundations/T-125-dialogue-manager-frame-core.md), [T-126](../TG-24-dialogue-frame-foundations/T-126-dialogue-option-catalog.md), [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md), [T-132](../TG-25-answer-classification-and-merge/T-132-dialogue-candidate-builder.md)
- **Blocks:** [T-140](T-140-cache-bypass-log-and-egress-suites.md), [T-143](../TG-28-acceptance-evidence-and-device-protocol/T-143-device-validation-protocol.md)
- **Requirements:** [NFR-MTC-004](../../../../define-requirements/NFR/NFR-MTC-004-log-safety.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Extend the release log-safety gate so the four new dialogue source files are
inside its scan scope and proven to be guarded: add the four roots to
`FEATURE_ROOTS` in `check-release-log-safety.py` and add per-root fixture cases
(planted violations plus `expect` tokens naming them) so each new root's
coverage is mechanically evidenced, not assumed.

## Acceptance criteria

```gherkin
Feature: Feature-scoped log-safety gate

  Scenario: The four new roots are scanned
    Given the extended feature-root list
    When the gate runs over the real tree
    Then the four new dialogue files are within the scanned set
    And a planted violation inside any of them fails the gate

  Scenario: Every new root has a positive fixture that is caught
    Given the fixture tree with one planted violation per new root
    When the fixtures suite runs
    Then each planted file is caught and named by its expect token

  Scenario: Existing negative fixtures stay green
    Given the unchanged negative fixture tree
    When the fixtures suite runs
    Then all negative cases pass and no existing rule is relaxed

  Scenario: The full gate exits zero on the clean tree
    Given the real tree with no planted violation
    When the gate runs as wired into the build
    Then the engine pass and the fixtures pass both complete with exit code zero
```

## Implementation notes
- Follow the shipped precedents exactly: `FEATURE_ROOTS` at
  `check-release-log-safety.py:141` already lists `Services/Spotify` and
  `Services/Plugins/SpotifyPlugin.swift`; add the dialogue roots in the same
  form: the dialogue manager, catalog, answer-path and candidate-builder files
  under their real directories.
- Fixture mechanics: per-rule trees under
  `ios/tools/log-safety-fixtures/<rule>/{positive,negative}/...`; the `expect`
  file names the planted file the gate must catch (mirror the spotify fixture
  cases).
- `check-release-log-safety.sh` runs the engine and the fixtures suite; both
  must exit 0. The gate is already invoked by the build after `xcodegen
  generate` — no `build.sh` edit is needed.
- **E4 producer line.** This task's evidence is the gate exit 0 including the
  fixtures suite over the four new roots; T-140 adds the runtime log-capture
  half of E4.
- Do not widen any existing rule or allow-list here; this task only scopes the
  scan and plants fixtures.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (fixtures suite cases)
- [ ] E4 DoD line: the gate exits 0 including its fixtures suite over the four new roots
- [ ] No existing rule relaxed; negative fixtures unchanged and green
- [ ] Focused gate run green locally; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
