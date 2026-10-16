# NFR-MTC-001: Probe and answer turns stay within the existing turn envelope

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feasibility study §6.5 ("Latency budget: one probe adds exactly one full turn's latency (seconds), within the existing 22 s capture / 45 s hold / 60 s watchdog envelope"); worktree surfaces verified: `VoicePipeline.captureTimeoutSeconds = 22` (`VoicePipeline.swift:130`), `turnPendingSafetySeconds = 45` (`:275`), `voiceWatchdogSeconds = 60` (`AppCoordinator.swift` ~`:4867`).

## Description
A probe dialogue **must** fit the existing voice-turn time budgets; it adds no new waiting mechanism:

- **One extra turn, no extra round trip**: the probe adds exactly one full turn's latency (the question turn); the probe itself is decided and spoken within that turn — it waits on no model and no network (template text, on-device catalog). The answer turn then behaves like a normal turn.
- **Existing envelope preserved**: the coupled timers are not changed or exceeded — 22 s capture (`captureTimeoutSeconds`), 45 s pending-turn hold (`turnPendingSafetySeconds`), 60 s voice watchdog (`voiceWatchdogSeconds = 60` = 47 s worst legitimate turn + margin). The frame deadline (45 s, FR-MTC-013) sits inside the envelope; a dialogue timeout must never be able to trip the 60 s watchdog.
- **Measurable target**: with no network and no models loaded, probe speech begins on the same turn as the probe decision (no cross-turn hop added beyond today's reply lane); the full probe→answer→execute sequence completes within the watchdog envelope with margin.

## Acceptance criteria

```gherkin
Feature: Probe latency envelope

  Scenario: The probe is spoken without any model or network wait
    Given a degenerate music request triggers the probe
    When the probe turn runs with no network and no brain loaded
    Then the probe line is spoken on that same turn
    And no additional round trip beyond the normal reply lane occurs

  Scenario: The dialogue fits inside the existing time budget
    Given a probe is outstanding
    When the user answers before the 45 s deadline
    Then the merged execution starts on the answer turn exactly like a normally spoken command
    And the 60 s voice watchdog is never reached by the dialogue

  Scenario: The timeout couplings stay unchanged
    Given the feature is built
    When the capture / pending-hold / watchdog values are inspected
    Then they remain 22 s / 45 s / 60 s respectively
    And the frame deadline uses the existing 45 s confirmation timer value
```

## Related
- FR: FR-MTC-013 (the 45 s deadline), FR-MTC-014 (timer reuse), FR-MTC-003 (template probe)
- NFR: NFR-MTC-011 (prefix reuse keeps later turns cheap)
