# T-102: Step Enum Extension + Cold-Start Routing + Shell Wiring (C02, C13)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C02 — `OnboardingState.Step`; C13 — `coldStartInterviewRoute()`, `ContentView`, `HomeView`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md), [T-097](T-097-onboarding-drafts-and-bounds.md), [T-099](T-099-about-you-step.md), [T-100](T-100-emergency-contacts-step.md), [T-101](T-101-voice-fingerprint-step.md)
- **Blocks:** [T-104](../TG-17-settings-release-and-evidence/T-104-log-safety-coverage.md), [T-105](../TG-17-settings-release-and-evidence/T-105-release-evidence-and-device-validation.md)
- **Requirements:** FR-PI-001, FR-PI-013, FR-PI-015, FR-PI-016 · NFR-PI-010 · ADR-03 · SD-7 · evidence obligation 9

## Description

Lands the enum and the routing last, after the step views compile: `OnboardingState.Step` gains `aboutYou`, `emergencyContacts`, `voiceFingerprint` in the required order (doc comment gains the clarifying line that every step is skippable and About-you additionally gates Next, keeping the no-hard-gate contract and the pinned tests in agreement); the three `stepContent` cases render the T-099/T-100/T-101 views; `OnboardingStateTests`' pinned expectations are updated (the 7-case order, the three new ids pending by construction from legacy status maps, `firstPendingStep`). Then C13: `AppCoordinator.coldStartInterviewRoute()` implements the normative route rule (the earlier of `firstPendingStep` and `.aboutYou` when the mandatory fields are not recorded; otherwise `first`; nil when nothing is pending and the fields are recorded), the `AboutYouDraft.mandatoryFieldsRecorded(in:)` predicate from T-097 is reused, and the shell consumes it once per process — `ContentView` passes it as `startingAt:` on the not-finished path, `HomeView` captures it once via `didCheckStartupRoute` and presents the existing `showWizard` cover, with the reminder card capturing the same value at tap. No new persisted state; the boot guard keeps hosted unit tests on today's behaviour.

## Acceptance criteria

```gherkin
Feature: Step enum extension and cold-start routing

  Scenario: The seven steps are in the required order
    Given OnboardingState.Step.allCases
    Then the order is language, permissions, aboutYou, familyContact, emergencyContacts, voiceFingerprint, models (FR-PI-001)
    And the updated pinned tests assert exactly this order

  Scenario: Legacy status maps leave the new steps pending
    Given a persisted step map written before this feature
    When statuses are read
    Then aboutYou, emergencyContacts and voiceFingerprint read as pending by construction
    And firstPendingStep reflects the updated expectations (FR-PI-013)

  Scenario: Fresh install routes to the language step
    Given all steps pending and an absent profile
    When coldStartInterviewRoute runs
    Then the route is .language — identical to the wizard's existing start

  Scenario: A pre-finish relaunch resumes at the first pending step
    Given some completed steps
    When coldStartInterviewRoute runs
    Then the route is the first pending step (the requirement's conscious resume change)

  Scenario: A complete interview routes nowhere
    Given nothing pending and a loaded profile with trimmed non-empty name and address-as
    When coldStartInterviewRoute runs
    Then the route is nil and the app starts normally

  Scenario: Optional steps pending still route, with the soft-skip intact
    Given the first pending step is optional and the mandatory fields are recorded
    When coldStartInterviewRoute runs and the wizard presents
    Then the wizard opens at that step and the skip affordance is present, so the user is never trapped

  Scenario: Missing mandatory fields pull the route back to About-you
    Given aboutYou marked completed but the snapshot absent, empty or unreadable (e.g. a discarded corrupt payload)
    When coldStartInterviewRoute runs
    Then the route is .aboutYou, the hard route on start, and the ordinary Next-and-save gate repairs the record
    And with a corrupt status map the route is computed the same way with no crash, stall or loop (SD-7, obligation 9)

  Scenario: Hosted unit tests see no routing
    Given XCTestConfigurationFilePath is set (the existing boot guard)
    When the shell evaluates the route
    Then no routing occurs and today's behaviour holds

  Scenario: The decision is once per process
    Given a presented wizard from routing
    When the user returns to Home without finishing
    Then no re-presentation happens in the same process (cold start only; scenePhase not observed)
```

## Implementation notes

- Order of landing matters: the three step views (T-099/T-100/T-101) must exist before the exhaustive `stepContent` switch gains the cases; a partial landing does not compile.
- The route method is synchronous, main-thread, pure-read: the step-map read ignores unknown raw values (existing `status(of:)` rule); the profile read uses `currentProfileSnapshot()` and may prime the store's first read. Every failure mode in the design's edge table has a defined route; the method never throws and has no error return (E8 — no new event; the outcome is user-visible).
- Shell wiring follows the design's normative section: the reminder-card path and the one-shot path set the same `wizardStart` value consumed by the existing `fullScreenCover`; `didCheckStartupRoute` is `@State`, first `onAppear` only; the one-shot honours the boot guard.
- SD-7: status-map tampering and corrupt maps are accepted risks — the routing outcome carries no privilege or data exposure; keep it that way by never persisting anything from the check and never crashing on unreadable state.
- FR-PI-013's `pendingSteps` / `firstPendingStep` / `startingAt:` mechanics are unchanged — this task only adds the one-shot consumer.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`OnboardingStateTests` extended; new `ColdStartRoutingTests`; the UI-test group extended for the one-time presentation, with existing Home-assuming tests accounting for it)
- [ ] No regression — every existing wizard/Settings test passes with the updated pinned counts (NFR-PI-010)
- [ ] Evidence (obligation 9): corrupt step map and unreadable profile runs show no crash, stall, loop or trap, with the skip/dismiss affordances present
- [ ] SD-7 recorded: the route stores nothing and grants nothing; cold-start-only decision documented on the method
- [ ] `ios/build.sh` passes
