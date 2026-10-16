# T-095: `VoicePipeline.beginCapture` Extraction + Ack Seam (C05)

## Metadata
- **Group:** [TG-15 — Personalization Paths: Prompt Clause, Seed Mirror, Wake Ack](index.md)
- **Component:** C05 — `VoicePipeline` seam property, handler split, `stop()` cancel
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-096](T-096-wake-acknowledgment-service.md)
- **Requirements:** FR-PI-008, FR-PI-011 · NFR-PI-010 · AM-3 · SD-3

## Description

Pure pipeline surgery, no behavior change while the seam is nil: add `wakeAcknowledger: WakeAcknowledging?` (nil default), split `handleWakeDetected` into the unchanged detection prologue plus a new `beginCapture(generation:)` that holds today's capture-start body verbatim and in order (noise-filter bookend, recognizer branch with VAD reset and callbacks, `state = .capturingCommand`, wedge-guard asyncAfter, `startListening(timeout:)`), guard it with the existing capture-generation check plus a `state == .idle` check, and add the `wakeAcknowledger?.cancel()` call at the top of `stop()` before engine teardown. When the seam is set, the ack completion is the only caller of `beginCapture`; the Talk button (`simulateWakeWordDetection`) routes through the same handler and therefore gets the same acknowledgment. AM-3: correct the design-text claim that the wake gate closes synchronously at `begin` — the shipped `noteSpeakingStarted` hook closes it inside a main-queue async, so the begin-while-active state is reachable in a narrow window; the supersede path (T-096) handles that state and the seam tests must cover the racing detection.

## Acceptance criteria

```gherkin
Feature: Capture extraction and acknowledgement seam

  Scenario: The extracted body is today's exact capture start
    Given a pipeline with a nil wakeAcknowledger
    When a wake detection is simulated through the existing harness entry point
    Then capture starts synchronously, exactly as today, with the same call order for the noise-filter bookend, the recognizer branch, the state change, and the wedge guard
    And the existing noise-filter and turn-timing seam suites stay green unchanged (NFR-PI-010)

  Scenario: With a seam, capture starts only after the completion
    Given a stub acknowledging service that defers its completion
    When a wake detection is simulated
    Then no capture state change or recognizer start has happened yet
    When the stub calls its completion
    Then capture starts exactly once through beginCapture

  Scenario: A stale completion is inert
    Given a deferred ack whose completion is still pending
    When stop() runs and then the completion fires
    Then the generation check makes the completion a no-op
    And no capture starts and no recognizer is left listening

  Scenario: stop cancels the ack before engine teardown
    Given a pipeline with an in-flight ack
    When stop() is called
    Then wakeAcknowledger.cancel() runs before the engine teardown steps
    And the pending completion is dropped

  Scenario: The Talk button gets the same acknowledgment
    Given a pipeline with a seam
    When simulateWakeWordDetection is invoked
    Then the same handler runs and the ack is begun before capture

  Scenario: A detection racing the ack start lands in the supersede path
    Given a detection whose ack start and a second detection interleave through the asynchronous speaking hook (AM-3)
    When both pass the wake gate in the narrow window before the gate closes
    Then the second begin tears the first ack down as superseded
    And the worst observable outcome is a restarted greeting, never a corrupted capture or a doubled capture start
```

## Implementation notes

- Move code, do not rewrite it: the capture-start body moves into `beginCapture` verbatim and in order; `handleWakeDetected` keeps the prologue (state and wake-gate guard, `captureGeneration += 1`, buffer reset, event, turn-tracer begin) and then branches on the seam.
- AM-3 is a two-part obligation: the seam property's doc comment must describe the gate close as the shipped asynchronous hook (not synchronous), and the racing-detection case above must exist in the seam tests; the supersede coverage lives in T-096's suite — keep both sides of that test pair named in the PR.
- `beginCapture`'s new `state == .idle` requirement is the second half of the epoch protection; the `captureGeneration` comparison alone is the pre-existing half.
- No coordinator edits here — the wiring (`voicePipeline.wakeAcknowledger = ...`) is T-096's, so this task is testable with the existing debug harnesses alone.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (extend the seam-test group beside the noise-filter and turn-timing harnesses, using `debugEnterIdleForTesting` + `simulateWakeWordDetection`)
- [ ] No regression — the existing pipeline suites pass unchanged; the extraction is behavior-preserving while the seam is nil
- [ ] AM-3 documentation correction present on the seam property; the racing-detection test covers the begin-while-active window
- [ ] `ios/build.sh` passes
