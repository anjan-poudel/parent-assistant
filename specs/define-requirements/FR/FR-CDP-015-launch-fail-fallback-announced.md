# FR-CDP-015: Launch-fail fallback (best-effort), announced via the existing spoken-outcome lane

## Metadata
- **Area:** Launch / Recovery
- **Priority:** MUST
- **Source:** Frozen design §6 ("If the resolved channel's open itself fails (iOS reports failure, or `CallLinks` returns a failure outcome), attempt the fallback, then `phone`, announcing via the existing spoken-outcome lane. Never silent.") and Decision 1 ("Fallback trigger = pre-flight feasibility + launch-failure"); feature constitution "In scope" bullet 6 and Feature Constraint 8; DV-3.

## Description
If the resolved channel's open itself fails — iOS reports the open failed, or `CallLinks` returns a failure outcome (e.g. `FaceTimeOutcome.unavailable`, an open refused) — the app **must** attempt the next channel down the chain (the remaining fallback step, then `.phone` as the floor), announcing the outcome via the existing spoken-outcome lane (new key `call.announce.launchFailedFallback`, ne/en).

Binding rules:
- The hop is **best-effort** (an extra attempt is made); the binding guarantees are: it is attempted **automatically** (no ask — FR-CDP-016), and a launch failure is **never silent** — the final outcome is always spoken through the existing lane.
- This covers the accepted `canOpenURL` staleness residual (FR-CDP-005): even a stale probe whose channel then fails to open lands on an announced fallback.
- The failure announcement **must not** leak raw error detail beyond the existing log policy (NFR-CDP-003); it names the channel outcome in the user's language, not internal error content.
- Emergency paths are untouched (FR-CDP-018): this hop applies to ordinary call initiation, never to emergency escalation.

## Acceptance criteria

```gherkin
Feature: Launch-fail fallback

  Scenario: A failed open attempts the next chain step and is announced
    Given the resolved channel's open fails
    And a fallback step remains
    When the call is initiated
    Then the next channel is attempted automatically
    And the outcome (the fallback routing/failure) is announced via the existing spoken-outcome lane

  Scenario: A failed open with no fallback left attempts GSM
    Given the resolved channel's open fails
    And the fallback step was already used or deduped
    When the call is initiated
    Then phone (tel:) is attempted as the floor
    And the outcome is announced — never silent

  Scenario: A launch failure is never a silent failure
    Given any open fails at launch time
    When the chain exhausts
    Then a spoken-outcome line is always produced
    And no failure detail beyond the existing policy reaches logs
```

## Related
- FR: FR-CDP-005 (probe staleness residual), FR-CDP-006 (floor), FR-CDP-007 (chain), FR-CDP-016 (automatic announced routing), FR-CDP-018 (emergency untouched)
- NFR: NFR-CDP-003 (log safety), NFR-CDP-001 (never dead-ends)
