# T-101: Voice Fingerprint Step (C12)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C12 — `VoiceFingerprintStep` in `App/ProfileInterviewSteps.swift`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md)
- **Blocks:** [T-102](T-102-step-enum-and-cold-start-routing.md)
- **Requirements:** FR-PI-007 · NFR-PI-009, NFR-PI-010 · AM-4 · evidence obligation 10

## Description

Hosts the existing voice-enrollment session inside the interview as an optional, skippable step — a call site only: the `@StateObject` session is constructed exactly as `VoiceSettingsView` constructs it (same service, recorder via `coordinator.makeEnrollmentSampleRecorder()`, coordinator as `VoicePipelineSuspending`); the mechanism, its storage and its permissions are unchanged (NFR-PI-009). The minimal UI is driven by `session.phase` / `session.collectedCount`: idle shows "Record sample n of 3", recording offers stop, ready shows done, failed shows the session's existing honest copy plus `dismissFailure()`. Next is always available; a failure or a skip still advances and enrollment stays available later in Settings. Pre-`start()` safety rests on the shipped behaviour that `suspendForSampleCapture()` returns true when no live pipeline exists (the wizard's context).

## Acceptance criteria

```gherkin
Feature: Voice fingerprint step

  Scenario: The session is the canonical construction
    Given the step is rendered
    When the session is inspected
    Then it was built with the same service, the coordinator's sample recorder, and the coordinator as suspender, exactly as VoiceSettingsView builds it (FR-PI-007)

  Scenario: Phases drive the copy
    Given collectedCount of 1 with the idle phase, a recording phase, a ready phase, and a failed phase
    When the step renders in each
    Then it shows the sample-of-3 prompt, the stop affordance, the done state, and the session's failure copy with a working dismissFailure() respectively

  Scenario: Skipping and failure never block the interview
    Given a failed session, then a skipped step
    When Next is tapped in both states
    Then the step advances without enrollment and Settings still offers enrollment later (FR-PI-004)

  Scenario: The pre-start context is safe
    Given the wizard running before coordinator.start()
    When a sample capture suspends the pipeline
    Then the shipped suspendForSampleCapture() returns true with no live pipeline and the capture proceeds without touching a nil pipeline (NFR-PI-010)

  Scenario: Nothing about the mechanism changed
    Given a diff of this change
    When the enrollment mechanism, its stored artifact and the permission set are inspected
    Then only the hosting call site was added: no mechanism, storage or permission change, and no biometric value in the profile store, logs or payloads (NFR-PI-009, obligation 10)
```

## Implementation notes

- The step view lands in `App/ProfileInterviewSteps.swift` (created by T-099); copy keys come from C09 (T-093).
- Do not modify `VoiceEnrollmentSession`, its recorder, or the suspension protocol — deviations from the canonical construction are the review trigger for obligation 10.
- The step must not gate Next on phase; it is optional by contract.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (construction/phase-rendering tests over the existing session fakes; the pre-start suspension path exercised where the existing harness reaches it)
- [ ] No PII in logs — no audio, sample or embedding value is logged; no biometric value enters the profile store (obligation 10)
- [ ] Safety-critical: `[ ] Integration test against stubbed platform health API (adapted: the sample-capture path is exercised against the existing stubbed recorder/service, never live hardware in tests)`
- [ ] Safety-critical: `[ ] Verified LLM process crash does not affect this path (enrollment is independent of every model process)`
- [ ] `ios/build.sh` passes
