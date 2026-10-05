# FR-PI-016: App-start interview-status routing (resume where the user left off)

## Metadata
- **Area:** Onboarding Wizard / App Start
- **Priority:** MUST
- **Source:** Owner amendment 2026-10-05 (owner sign-off); specs/profile-interview/constitution.md Feature Constraint 8

## Description
On app start the app **must** check the onboarding interview's completion status (the per-step status in `OnboardingState`, including the mandatory fields of FR-PI-002) and route accordingly:

- **Mandatory fields missing** (name or address-as — FR-PI-002): the user **must** be routed to the interview screen (the wizard) at the first pending step — About-you — resuming where the user left off. This is a hard route on app start.
- **Optional interview steps pending** (FR-PI-004): the user **must** also be routed to the wizard, at the first pending optional step, with the OD-F3 soft-skip affordance preserved — the user can still skip and is never trapped.
- **Interview complete:** the app starts normally, with no routing to the interview screen.

The resume mechanism **must** be the existing `OnboardingState.pendingSteps` / `firstPendingStep` computation plus the wizard's `startingAt:` reopen path (FR-PI-013) — no new resume state is introduced. The first pending step follows the configured order (FR-PI-001).

Cold start is the minimum trigger for this requirement. Whether a background-to-foreground transition also re-checks is a design decision for the architect (design-l1 / design-l2), not a requirement of this set.

Relationship to FR-PI-013: this owner amendment (2026-10-05) supersedes FR-PI-013's "No force-migration" scenario for the app-start path — pending steps are now surfaced on start — while preserving its non-blocking intent through the skippable steps (FR-PI-004 / OD-F3). FR-PI-013's `pendingSteps` / `firstPendingStep` / `startingAt:` mechanics are unchanged and are the resume mechanism used here.

A failure to read the interview completion status **must not** crash or stall app start and **must not** trap the user (FR-PI-015; FR-PI-004).

## Acceptance criteria

```gherkin
Feature: App-start interview-status routing

  Scenario: Mandatory fields missing on cold start — hard route to About-you
    Given the app cold-starts with name or address-as not recorded
    And the first pending step is About-you
    When the app starts
    Then the user is routed to the interview screen (the wizard)
    And the wizard opens at About-you, so the interview resumes where the user left off

  Scenario: Optional steps pending on cold start — routed but never trapped
    Given the app cold-starts with name and address-as recorded
    And at least one optional interview step is pending
    When the app starts
    Then the user is routed to the interview screen (the wizard)
    And the wizard opens at the first pending optional step
    And the OD-F3 soft-skip affordance is available, so the user can skip and is never trapped

  Scenario: Interview complete — no routing on cold start
    Given the app cold-starts with the interview complete
    When the app starts
    Then the app starts normally with no routing to the interview screen

  Scenario: A status read failure does not crash or trap
    Given the interview completion status cannot be read (corrupt or unreadable state)
    When the app starts
    Then the app starts without crashing, stalling or looping on the status check
    And the user is never trapped in the wizard
```

## Related
- FR: FR-PI-002 (mandatory gate), FR-PI-004 (optional skippable pattern), FR-PI-013 (reopen path; its "No force-migration" scenario is superseded for the app-start path by this amendment), FR-PI-015 (no crash or trap on read failure)
- NFR: NFR-PI-010 (no regression)
- Depends on: FR-PI-001 (step order), FR-PI-013 (resume mechanism)
