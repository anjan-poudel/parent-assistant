# T-001: Repository and CI/CD Scaffolding

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../index.md)
- **Component:** CI/CD Pipeline, Project Repositories
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on:** —
- **Blocks:** [T-002](T-002-encrypted-local-storage/index.md), [T-004](T-004-observability-bus-log-sanitiser.md)
- **Requirements:** (baseline infrastructure)

## Description

Set up the iOS (Xcode / Swift Package Manager) and Android (Gradle / Kotlin) project repositories. Configure CI/CD pipelines. Establish shared project structure for cross-platform components (llama.cpp, whisper.cpp, openWakeWord, libsignal via C/C++ or Kotlin Multiplatform). Define code style and linting rules.

## Acceptance criteria

```gherkin
Feature: Repository and CI/CD Scaffolding

  Scenario: iOS project builds on CI without warnings
    Given the iOS project is pushed to CI
    When the build pipeline runs in strict mode
    Then the build completes with zero warnings
    And the build status is reported as passed

  Scenario: Android project builds on CI without warnings
    Given the Android project is pushed to CI
    When the build pipeline runs
    Then ktlint passes with zero violations
    And the build completes with zero warnings

  Scenario: Unit tests gate CI
    Given either project contains unit tests
    When CI runs the test suite
    Then all tests must pass before the pipeline reports success
    And any test failure blocks the merge

  Scenario: Pre-commit hooks enforce style
    Given a developer commits code with style violations
    When the pre-commit hook runs
    Then swiftformat rejects the iOS commit
    And ktlint rejects the Android commit

  Scenario: README documents local build steps
    Given the repository README is present
    When a new developer follows the build instructions
    Then they can build and run each project locally without additional guidance

  Scenario: CI secret scanning blocks committed secrets
    Given secret scanning is enabled on CI
    When a commit containing a hardcoded secret is pushed
    Then CI flags and blocks the commit
    And no secrets are present in the first merged PR
```

## Implementation notes

- CI pipeline must gate: build (zero warnings), unit tests, lint.
- Pre-commit hooks: `swiftformat` (iOS), `ktlint` (Android).
- Secret scanning enabled from day one.
- Shared native code (llama.cpp, whisper.cpp, openWakeWord, libsignal) integrated via C/C++ or Kotlin Multiplatform.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] iOS project builds clean on CI
- [ ] Android project builds clean on CI
- [ ] Pre-commit hooks active on both platforms
- [ ] Secret scanning enabled and verified
