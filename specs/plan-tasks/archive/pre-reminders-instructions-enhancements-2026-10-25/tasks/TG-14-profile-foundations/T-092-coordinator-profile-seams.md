# T-092: Coordinator Profile Seams — Writer, Snapshot, Personalization (C01)

## Metadata
- **Group:** [TG-14 — Profile Foundations: Store, Guard, Seams, Strings](index.md)
- **Component:** C01 writer + read snapshots (`AppCoordinator`, §5.6)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-090](T-090-user-profile-store.md), [T-091](T-091-profile-prompt-guard-and-personalization.md)
- **Blocks:** [T-094](../TG-15-personalization-paths/T-094-prompt-clause-and-seed-mirror-gate.md), [T-096](../TG-15-personalization-paths/T-096-wake-acknowledgment-service.md), [T-099](../TG-16-interview-wizard-and-startup-routing/T-099-about-you-step.md), [T-100](../TG-16-interview-wizard-and-startup-routing/T-100-emergency-contacts-step.md), [T-102](../TG-16-interview-wizard-and-startup-routing/T-102-step-enum-and-cold-start-routing.md), [T-103](../TG-17-settings-release-and-evidence/T-103-profile-settings-editor.md)
- **Requirements:** FR-PI-002, FR-PI-003, FR-PI-012, FR-PI-015 · NFR-PI-010 · ADR-01

## Description

The coordinator additions that make the store reachable to the wizard and Settings: `saveProfile(name:addressAs:dateOfBirth:emergencyDoctor:localHospital:) -> Result<Void, ProfileStoreError>` as the only writer, `currentProfileSnapshot() -> ProfileLoadResult` (cached, any queue), and `profilePersonalization: ProfilePersonalizationReading?` constructed in `init()` — the wizard runs before `start()`, so the store, guard and seam are composed next to the existing storage composition; only the ack service is built in `start()` (T-096). The nil seam is consumed nil-safe (tests, partial wiring).

## Acceptance criteria

```gherkin
Feature: Coordinator profile seams

  Scenario: The coordinator is the only writer
    Given a coordinator with the store wired
    When saveProfile is called with a complete record
    Then the result is success
    And the next currentProfileSnapshot() reflects the saved record
    And wizard and Settings code never touch the store directly (single writer by contract)

  Scenario: The personalization seam exists before start()
    Given a coordinator whose init() completed
    When profilePersonalization is read before start() is called
    Then it is non-nil when storage is available
    And the interpreters consume its guarded accessor through InterpreterContext

  Scenario: A nil seam is consumed nil-safe
    Given a test-configured coordinator with no personalization wiring
    When an interpreter context is built
    Then the guard accessor resolves to nil and the no-term clause is used
    And nothing crashes or blocks

  Scenario: A failed save surfaces explicitly and changes nothing
    Given a store whose write fails
    When saveProfile is called
    Then the result is .failure(.writeFailed)
    And the cached snapshot still reflects the record as stored
    And the caller can show an inline message with nothing claimed (E3)
```

## Implementation notes

- Additions only inside `App/AppCoordinator.swift` — no change to the existing start sequence, storage composition order, or any existing method. The construction site order follows §5.6: store → guard → personalization in `init()`; the ack service and the pipeline seam wiring in `start()` (deferred to T-096 so this task stays independently testable).
- `saveProfile` writes the complete record; callers merge by reading `currentProfileSnapshot()` first (the merge helpers live in T-097). Empty strings are legal (clearing returns to the un-personalized path, FR-PI-011).
- `currentProfileSnapshot()` performs no disk I/O after the first read; the cold-start route (T-102) may prime it with the same first read.
- No new events here beyond the store's own (§7.3).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] No regression — the existing coordinator test suite stays green (NFR-PI-010)
- [ ] The single-writer invariant is documented on `saveProfile` and exercised by a test that a snapshot round-trips through it
- [ ] `ios/build.sh` passes
