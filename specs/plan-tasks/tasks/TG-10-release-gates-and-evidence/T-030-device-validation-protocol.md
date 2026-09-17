# T-030: Device Validation Protocol

## Metadata
- **Group:** [TG-10 — Release Gates and Evidence](index.md)
- **Component:** on-device validation protocol, fixture-image OCR checks and the results record
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-028](T-028-release-log-safety-gate-extension.md), [T-029](T-029-security-evidence-suite.md)
- **Blocks:** — (feeds the owner's `final-sign-off`)
- **Requirements:** NFR-LCT-001, NFR-LCT-002, NFR-LCT-005, NFR-LCT-011, NFR-LCT-012 · **OD1, OD2, OD5** · R10 · OD3 (owner confirmation)

## Description

Settle on hardware what no simulator can: the OCR cadence and thermal behaviour behind OD1, the
in-place-versus-callout default behind OD2, the declutter thresholds and the clamped-callout corner case
behind OD5, and the audio-session contention behind R10. Run the design's manual-device scenarios —
appliance panel, packaging, a real menu page in poor light — plus the fixture-image OCR pass on the
simulator (including a dense menu-like page for the decluttering path), and record every result,
including the checks that failed or were not run.

Source: the feature's validation record under `specs/` and the design's test-strategy section. No
product source changes except fixes for defects the protocol finds.

## Acceptance criteria

```gherkin
Feature: Device validation

  Scenario: The protocol names every device-only check
    Given the design's resource, manual-device and open-decision items
    When the protocol is read
    Then it names checks for OCR cadence and sustained-session thermal behaviour (OD1), in-place versus callout selection and the "always show original" default (OD2), declutter legibility and the clamped-callout corner case (OD5), microphone/speech mutual exclusion (R10), battery drain, frame pacing on the oldest supported device, peak memory under a dense scene, and offline behaviour
    And each check states its pass condition, its measurement method and a recording slot
    And each check names the design parameter a failure would edit (OD1, OD2, OD5)

  Scenario: The fixture-image OCR pass runs on the simulator
    Given the fixture images, including a dense menu-like page
    When the OCR and decluttering paths run over them
    Then text is detected and stabilised as the fixtures expect
    And the dense page exercises merging and the region cap without unreadable output

  Scenario: The manual device scenarios are run as written
    Given the protocol's device scenarios
    When they are run on the target hardware
    Then an appliance panel, a package and a real menu page in poor light are each validated end to end
    And stabiliser behaviour, declutter legibility, in-place versus callout selection, and tap-to-hear plus read-all are each recorded

  Scenario: Sustained use does not degrade into an unusable state
    Given a continuous session at the configured cadence on the target device
    When the session runs for the protocol's stated duration
    Then the OCR cadence is measured against the nominal value and any thermal factor is observed
    And the frame rate degrades predictably rather than stalling, and the session stays usable without crashing (NFR-LCT-002, OD1)

  Scenario: Memory stays under the ceiling in a dense scene
    Given a dense scene at the configured caps
    When the session runs continuously
    Then peak memory stays under the recorded ceiling
    And no growth trend appears over the run (NFR-LCT-005)

  Scenario: Everything that works online works offline
    Given a genuine airplane-mode run, plus a Wi-Fi-off variant
    When the elder uses the feature
    Then dictionary resolution, the cache, the overlay and speech all work (NFR-LCT-001)
    And the unavailable indication appears only for strings that genuinely need the cloud tier

  Scenario: The microphone path is validated with audio in use
    Given the session running with the microphone active and other audio playing
    When commands are spoken and the feature speaks
    Then commands are recognised without self-triggering and the elder's audio is not disrupted (NFR-LCT-011, R10)

  Scenario: Results are recorded honestly, including gaps
    Given the protocol has been run
    When the results record is read
    Then each check records its outcome, its measurement, and its device and build identifiers
    And any check not run or failed is recorded as such, with its reason, not omitted (NFR-LCT-012)

  Scenario: A defect found by the protocol becomes a traced fix
    Given a check that fails
    When the results are recorded
    Then the failure links to the task that owns the fix
    And the protocol is re-run for that check after the fix

  Scenario: The record separates measurements from owner decisions
    Given the completed record
    When it is read at final-sign-off
    Then measured results are stated as measurements, with no recommendation presented as a decision
    And the remaining owner actions are listed as such (OD1 cadence value, OD2 default, OD3 copy review, OD5 thresholds)
```

## Implementation notes

- Checklist discipline: each check records device model, OS version, build identifier, measurement,
  pass condition and outcome. A check without a measurement is an opinion, not evidence.
- The OD1 check is a **spike, not a pass/fail**: it measures the real OCR cadence and thermal behaviour
  so the owner can decide whether the nominal `ocrSampleInterval` value is frozen or edited. Report the
  measurement; do not silently change the parameter.
- The OD5 check includes the corner case where every callout anchor violates the never-cover-its-own-
  region constraint on a genuinely full screen and the pill is clamped inside the safe area: record
  whether the clamp is legible and reachable, and whether the thresholds should move. This is the
  manual item that T-020 defers here rather than accepting silently.
- The thermal and battery checks need a duration long enough to see a trend; state the duration in the
  protocol so a future run is comparable.
- Offline validation must be a genuine airplane-mode run plus a Wi-Fi-off variant, not a mocked client —
  the point is the real network stack and the real cache at rest.
- The dictionary, cache, overlay and speech paths must all be exercised offline, since that is the
  feature's core offline claim.
- **Owner actions, not agent work**: the device-demo confirmations behind OD1, OD2 and OD5, and the
  consent and disclosure copy review behind OD3, are owner decisions recorded at `final-sign-off`. This
  task supplies the protocol and the results; it does not close those decisions.
- Record gaps explicitly: a check that could not be run is recorded as not run with the reason. The
  `final-sign-off` gate reads this record, and an incomplete record presented as complete would
  mislead that decision.

## Definition of done
- [ ] Protocol and results record reviewed and merged
- [ ] All Gherkin scenarios covered by the recorded checks
- [ ] Every device-only check records device, build, measurement and outcome
- [ ] The fixture-image OCR pass, including the dense menu-like page, runs in the standard test invocation
- [ ] Checks not run or failed are recorded with their reason, not omitted
- [ ] Defects found are linked to the owning task and re-checked after the fix
- [ ] The record states which confirmations remain owner decisions at `final-sign-off`
- [ ] `ios/build.sh` passes
