# T-104: Log-Safety Coverage — Redacted Keys + Feature Roots (C10)

## Metadata
- **Group:** [TG-17 — Settings, Log Safety and Release Evidence](index.md)
- **Component:** C10 — `Services/Observability/LogSanitiser.swift`, `ios/tools/check-release-log-safety.py`
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-102](../TG-16-interview-wizard-and-startup-routing/T-102-step-enum-and-cold-start-routing.md), [T-103](T-103-profile-settings-editor.md)
- **Blocks:** [T-105](T-105-release-evidence-and-device-validation.md)
- **Requirements:** NFR-PI-002 · NFR-PI-011 (gate obligation) · AM-4 · SD-4 · evidence obligation 4 (gate half)

## Description

Two fail-closed defence layers plus the scan coverage that makes them enforceable over the feature's own code. `LogSanitiser.redactedKeys` gains `profile_name`, `address_as`, `date_of_birth`, `emergency_doctor`, `local_hospital` — deliberately not added to `allowedKeys`, so redaction replaces the value with `[redacted]` first and the allow-list filter then drops the key. `check-release-log-safety.py`'s `FEATURE_ROOTS` gains every new feature source — `Services/Storage/UserProfileStore.swift`, `Services/Voice/WakeAcknowledgment.swift`, `Services/Voice/ProfilePromptTextGuard.swift`, `Services/Voice/ProfilePersonalization.swift`, `App/Components/AddressAsField.swift`, `App/ProfileSettingsView.swift`, `App/ProfileSettingsModel.swift`, `App/OnboardingDrafts.swift`, and the dedicated `App/ProfileInterviewSteps.swift` — so a Release console write or an unlisted metadata key in the step views (AM-4's gap; SD-4) fails the gate. Coordinator additions stay best-effort per SD-4: the runtime choke point already contains the event channel there.

## Acceptance criteria

```gherkin
Feature: Log-safety coverage

  Scenario: The profile field names are redacted before the allow-list filter
    Given a diagnostic that emits any of the five profile field-name keys
    When the sanitizer processes it
    Then the value is replaced by [redacted] and the key is then dropped because it is not allow-listed (fail-closed, NFR-PI-002)

  Scenario: The feature's own sources are inside the strict rules
    Given the extended FEATURE_ROOTS
    When the gate scans them
    Then every listed file is scanned under the strict console-write and metadata rules
    And the dedicated step-view file is among them so wizard code cannot bypass the gate (AM-4, SD-4)

  Scenario: A planted violation in a new root fails the gate
    Given a temporary Release console write in one of the new roots
    When the gate runs
    Then it exits non-zero with the offending file named
    And removing the violation returns the gate to exit 0

  Scenario: All event metadata keys stay allow-listed
    Given the events the feature emits
    When the gate's metadata-key rule runs
    Then only outcome, error_code and duration_ms appear, and all three are already in the shipped allow-list
    And no event field carries interpolated text
```

## Implementation notes

- Sets-only change in `LogSanitiser` plus the roots list in the Python gate — the gate wiring into `ios/build.sh` already exists and needs no edit.
- The five redacted keys mirror the store's field names (snake_case) so a future diagnostic using a field name lands in the redaction set; reference SD-4's reasoning in the code comment.
- AM-4's "keep the gate exit-0 obligation in the release checklist" half is recorded as a DoD hand-off to T-105, not re-implemented here.
- Evidence half: this task proves the gate half of obligation 4 (exit 0, roots scanned); the live Release-session inspection is T-105's.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (sanitizer unit tests for the five keys; a gate-run test with the planted violation)
- [ ] Evidence (obligation 4, gate half): the extended gate exits 0 on the merged tree, with the negative run recorded
- [ ] AM-4: the dedicated step-view file is in FEATURE_ROOTS; the exit-0 checklist obligation handed to T-105
- [ ] `ios/build.sh` passes
