# T-105: Release Evidence Bundle + Device Validation (Obligations 4, 5, 7; OD-A1)

## Metadata
- **Group:** [TG-17 — Settings, Log Safety and Release Evidence](index.md)
- **Component:** Release evidence (no production code; device + Release-build validation)
- **Agent:** dev (evidence run; coordinator role per the evidence bundle)
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-094](../TG-15-personalization-paths/T-094-prompt-clause-and-seed-mirror-gate.md), [T-096](../TG-15-personalization-paths/T-096-wake-acknowledgment-service.md), [T-102](../TG-16-interview-wizard-and-startup-routing/T-102-step-enum-and-cold-start-routing.md), [T-103](T-103-profile-settings-editor.md), [T-104](T-104-log-safety-coverage.md)
- **Blocks:** —
- **Requirements:** NFR-PI-001, NFR-PI-002, NFR-PI-003, NFR-PI-008, NFR-PI-011 · AM-3 (exit-0 checklist), AM-4 · SD-5, SD-6 · evidence obligations 4, 5, 7 · OD-A1, OD-A2

## Description

The end-to-end evidence run on a Release build and a physical device, producing the bundle the security and release gates cite. It runs the obligations that cannot be proven by reading code: the personalized-session inspection (console, log files, telemetry — zero profile values; extended log-safety gate exits 0), the container inspection (no plaintext profile value anywhere; the ack's temp WAV gone after playback; the payload unreadable without the app's key material), the offline full journey (interview, wizard close, wake ack, on-device replies, Settings edit — zero feature-attributable network), and the OD-A1 device measurement of detection-to-first-audio against the ≤ 1 s activation budget. It also records the AM-4 gate exit-0 checklist item, the OD-A2 owner copy confirmation, and the OD-PI-5 / SD-6 accepted residual. Nothing in this task changes production behavior; a failed obligation is reported as failed or not-run with its reason — never asserted as passed.

## Acceptance criteria

```gherkin
Feature: Release evidence

  Scenario: A personalized Release session leaks no profile value
    Given a Release build with recorded profile data and a spoken session
    When console, log files and telemetry are inspected with the extended log-safety gate
    Then zero occurrences of any profile value appear anywhere and the gate exits 0 (obligation 4, AM-4 checklist item)

  Scenario: The container holds no plaintext and no leftover audio
    Given the same session on a physical device
    When the container is inspected (store area, temp files, debug artifacts)
    Then no plaintext profile value exists anywhere, the ack's WAV is gone after playback, and the payload is unreadable without the app's key material (obligation 5, SD-5)

  Scenario: The offline journey makes no feature-attributable request
    Given airplane mode or a network capture
    When the full journey runs — interview, wizard close, wake ack, on-device replies, Settings edit
    Then zero network requests attributable to the feature are observed (obligation 7, NFR-PI-003)

  Scenario: The acknowledgement latency is measured against the budget
    Given the injectable wakeAckMaxHoldSeconds and a physical device
    When detection-to-first-audio is measured across repeated wakes
    Then the measurement is recorded with device, OS and build identifiers and compared against the ≤ 1 s activation budget (OD-A1)
    And if the budget is missed the outcome is recorded with the fallback ladder named as the lever — no default change without a recorded decision

  Scenario: Unrunnable obligations are reported honestly
    Given an obligation that cannot be executed in this environment
    When the bundle is assembled
    Then it is listed as not-run with the reason, never as passed
```

## Implementation notes

- Evidence bundle lives in the PR description (or a linked artifact): counts, excerpts, screenshots and the measured latency table. No profile value appears in the evidence itself — use synthetic fixture values for any excerpt.
- OD-A2: the owner confirms the English ack copy (`Yes, %@`) during review of this PR; the term is never translated or reformatted. Record the confirmation; the owner action is also tracked in `plan.md`.
- SD-6 / OD-PI-5: the accepted residual (plain Settings editor, no biometric gate) is referenced here as recorded, owner-accepted 2026-10-05 — not re-litigated.
- NFR-PI-011 item 2 (App Store privacy disclosure for the new fields) remains an owner/compliance action in the 2026-10-13 window; this bundle names it so it is not lost.
- End-to-end integration: one uninterrupted run of interview → wake ack → personalized reply → Settings edit on the device build.

## Definition of done
- [ ] All prior tasks completed and merged
- [ ] End-to-end integration test passing (interview, wake ack, personalized reply, Settings edit on a Release device build)
- [ ] Evidence (obligation 4): Release-session inspection counts + gate exit 0 recorded
- [ ] Evidence (obligation 5): container, WAV and keystore findings recorded
- [ ] Evidence (obligation 7): offline journey capture recorded
- [ ] OD-A1 measurement recorded against the budget, with the fallback ladder named if missed
- [ ] OD-A2 owner confirmation and the NFR-PI-011 disclosure item recorded
- [ ] Any not-run obligation listed honestly with its reason
