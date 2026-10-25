# T-096: `WakeAcknowledgmentService` + Coordinator Wiring (C05)

## Metadata
- **Group:** [TG-15 — Personalization Paths: Prompt Clause, Seed Mirror, Wake Ack](index.md)
- **Component:** C05 — `WakeAcknowledging`, `WakeAcknowledgmentService`; `AppCoordinator.start()` wiring
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md), [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md), [T-095](T-095-capture-extraction-and-ack-seam.md)
- **Blocks:** [T-105](../TG-17-settings-release-and-evidence/T-105-release-evidence-and-device-validation.md)
- **Requirements:** FR-PI-008, FR-PI-010, FR-PI-011 · NFR-PI-001, NFR-PI-008, NFR-PI-010 · ADR-06, ADR-09 · AM-3 · SD-3 · SD-5 · evidence obligations 5 (WAV half), 8

## Description

The two-state ack machine (`idle` / `active`, fields `completion`, `maxHoldWorkItem`, `speakTask`, `speakingOutstanding`, `startedAt`) with its single `settle` exit: `begin` resolves the template through `L10n.str` and speaks the stored term verbatim (never guard-processed, ADR-09), pending completion due within `wakeAckMaxHoldSeconds` (default 2.5); every failure path — no term, phrase unavailable, supersede — completes synchronously or drops as the state machine defines, and the timeout path cancels playback with a content-free event. The service receives the base `PiperVoiceSpeaker` plus the coordinator's note closures — never the `SpeechNoteForwarder`-wrapped instance — so each ack balances the speaking count exactly once. Coordinator `start()` constructs the service (term from the personalization seam's verbatim accessor, locale from the active language), passes the base speaker, and sets `voicePipeline.wakeAcknowledger`.

## Acceptance criteria

```gherkin
Feature: Wake acknowledgment service

  Scenario: A recorded term is acknowledged within the bound and capture follows
    Given a phrase that resolves and a fake speaker whose playback completes
    When begin is called
    Then the spoken text is the localized template with the stored term verbatim
    And speaking-started fired once before playback and speaking-ended once at settle
    And the completion is called exactly once on the main queue, within wakeAckMaxHoldSeconds

  Scenario: No term means today's silent start
    Given a nil or empty term
    When begin is called
    Then the completion is called synchronously and no audio plays and no event is emitted

  Scenario: An unresolvable template is never spoken
    Given a template key that resolves to itself, a template without %@, or a term absent from the formatted result
    When begin is called
    Then nothing is spoken and wake_ack_failed with error_code template_missing is emitted
    And the completion is called synchronously

  Scenario: A slow synthesis is cut at the bound with balanced bookkeeping
    Given a fake speaker that never finishes and wakeAckMaxHoldSeconds of 0.01
    When begin is called and the timer fires
    Then playback is cancelled and wake_ack_timeout with error_code hold_exceeded and duration_ms set to the hold is emitted
    And the completion is called exactly once

  Scenario: cancel drops the pending completion without an event
    Given an in-flight ack
    When cancel is called
    Then playback is stopped, the speaking balance is restored exactly once, the pending completion is dropped, and no event is emitted

  Scenario: A superseding begin tears the old ack down first
    Given an active ack reached through the racing window the seam tests exercise (AM-3)
    When begin is called again
    Then the old ack is torn down as superseded with no event and its completion is dropped
    And the new ack proceeds normally

  Scenario: The speaker is the base instance, not the forwarder
    Given the coordinator wiring
    When the service is constructed
    Then it receives the base PiperVoiceSpeaker plus the coordinator's note closures
    And each ack balances the speaking count exactly once (no double count from a second forwarder)
```

## Implementation notes

- Hold to the state machine table in `specs/design-l2.md` §7.1 verbatim; `Speaker.speak` is non-throwing, so phrase-resolution failure is the only "failed" state and a silent synthesis death surfaces as the timeout path. The completion contract ("exactly once, within the bound") holds for every path except `cancel()`, which is only called when the pending completion is stale by definition.
- Main-thread-only by contract: `dispatchPrecondition(.onQueue(.main))` at the entry points; at most one in-flight ack; all state transitions go through `settle`.
- AM-3 / SD-3: do not document a synchronous gate close — the gate closes through the coordinator's speaking hook on the main-queue async; the supersede scenario is this service's half of the racing-detection pair started in T-095.
- SD-5 / obligation 5 (WAV half): the ack rides the existing `PiperVoiceSpeaker` path whose temp WAV is deleted after playback — cite the existing behaviour in the DoD evidence note and pin the deletion expectation in T-105's device run; no personalized audio is ever cached (ADR-06).
- Wiring in `start()` follows §5.6: construct with the seam's verbatim accessor as `termProvider`, the active-language locale as `localeProvider`, the coordinator's existing note closures, and the default `wakeAckMaxHoldSeconds` / `templateKey`. The pipeline seam is assigned there too.
- Obligation 8's failure-injection matrix is authored here as tests; the device-side re-run for the release evidence lands in T-105.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`WakeAcknowledgmentServiceTests` with a controllable fake speaker and `wakeAckMaxHoldSeconds: 0.01`)
- [ ] No PII in logs — events carry `outcome` / `error_code` / `duration_ms` only, never the term
- [ ] Evidence (obligation 8): the three failure injections (unresolved template, timeout, cancel) each show silent start behaviour, completion exactly once outside cancel, and balanced speaking bookkeeping
- [ ] Evidence (obligation 5, WAV half): the ack's temp WAV deletion after playback is asserted on the existing speaker path and flagged for the T-105 device run
- [ ] AM-3: doc comment matches the shipped asynchronous gate close; the supersede path is covered by the racing pair with T-095
- [ ] `ios/build.sh` passes
