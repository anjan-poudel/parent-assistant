# T-071: Cascade Latency, Residency & Cold-Start Measurement (R&D)

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** Paired device A/B of the three serving modes (`.pickerBrain`, `.standaloneEncoder`, `.encoderFirstEscalate`) across `TurnTimingBreakdown`, `VoiceTurnLatencyTracer` and `tools/train-intent/src/measure_device.py`; RSS residency; cold/warm split
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-037-a](../../TG-08-nepali-intent-encoder/T-037-runtime-integration/T-037-a-ios.md) (the encoder runtime is wired; this measures it), [T-038](../../TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md)
- **Blocks:** [T-073](T-073-cascade-default-policy-design.md), [T-078](T-078-latency-residency-default-flip-verification.md)
- **Requirements:** NFR-001, NFR-002, FR-007
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §6.4 and §6.5; design evidence rows E-9/E-10/E-11/E-13/E-14 (gap G-2)

## Description

The cascade is built and its per-stage timers already exist. What has never been done is the **paired measurement** that would decide whether it may become the default. This task produces those numbers, and it is explicitly capable of producing a "do not flip" recommendation.

**The measurement is a paired A/B, not a single run.** For the same transcript set on the same device, three arms:

| Arm | Serving mode | What it costs |
|---|---|---|
| A | `.pickerBrain` | today's default — the baseline to beat |
| B | `.standaloneEncoder` | the encoder alone; an abstention falls through to the router's own policy |
| C | `.encoderFirstEscalate` | the cascade: the encoder first, the picker on abstain / failure / sub-band, **same turn** |

Mode switching is instant and needs no relaunch (`AppCoordinator.swift:1211-1245`, `:1265-1270`), so the pairing is genuinely same-device and same-session rather than a comparison across builds.

**What is measured, per arm:**

1. **Latency**, from the two existing instruments — no new instrumentation is in scope:
   - per-stage: `encoder_tokenizer`, `encoder_inference`, `encoder_decode`, `cascade_decision`, `picker_prompt_build`, `picker_inference` (`TurnTimingBreakdown.swift:50-69`);
   - end-to-end: VAD → `router_done` → `speak_queued` (`VoiceTurnLatencyTracer.swift:223-235`, marks at `VoicePipeline.swift:338`, `:827`, `:852`) — this is the NFR-002 number;
   - off-device, through `tools/train-intent/src/measure_device.py`, whose **defaults are the budget**: `--p50-gate-ms 1000.0` / `--p95-gate-ms 2000.0` (`:220-221`), nearest-rank percentile (`tests/test_measure_device.py:52-61`), cold/warm split (`:139-148`). Run it; do not write a second one.
2. **Escalation rate and its reason breakdown** — `abstained` / `failed` / `subBandConfidence` (`LocalBrainChain.swift:44-55`), surfaced by `encoder_escalated_to_picker_brain` (`AppCoordinator.swift:1406-1415`). The breakdown matters more than the total: a `failed`-heavy rate means the encoder is timing out, a `subBandConfidence`-heavy one means the calibration is off, and they have different fixes.
3. **Escalation overhead** — the delta between an escalated turn in arm C and the same turn in arm A, isolated by the `cascade_decision` span. This is the price of the decision and the hand-off, separated from the price of the encoder pass.
4. **Peak RSS with both brains resident** — arm C holds the encoder and the picker simultaneously for the whole session, not only on escalated turns. The `T-018-b` precedent applies (decline load below 2.5 GB available rather than OOM), and the failure to design against is eviction: the OS dropping the picker between turns, turning every escalated turn into a cold load.
5. **Cold start** — first-turn latency after a cold launch, per arm, against the warm p95. Three cases matter (`§6.5`): the encoder artifact still loading on first use (already handled by `retryOnArtifactLoadRace`), the artifact absent (already handled — the chain's availability rule selects the stand-in), and **both brains warming** — the case where the cascade's ordering is strictly harmful and nothing handles it today.
6. **The sub-band agreement rate (§6.5's fourth case).** On `subBandConfidence` escalations, how often does the picker brain return the *same* action the encoder did? A high agreement rate means the user waited for two brains to agree — and the honest alternative is serving the sub-band answer into the existing confirmation flow, which is what `bandChecked` already does for tier-`.confirm` actions (`IntentRouter.swift:316-330`), rather than escalating.

**The structural finding this task must either confirm or refute.** The encoder's timeout is 2.0 s with zero retries (`IntentEncoderInterpreter.swift:168-169`) and the picker brain's is **10 s** with one retry (`LocalIntentInterpreter.swift:47-49`). `LocalBrainChain` passes no remaining-time budget to `standIn`. The worst-case escalate turn is therefore 2.0 s + 10 s = 12 s against NFR-002's 4 s — in the mode where the user has already waited for one model to fail. The measurement records the observed worst case and the p95, and if they confirm the bound, that is the finding, not a footnote.

**This task does not fix anything.** It measures and reports. The turn-level deadline is T-073's to specify and T-076's to implement.

## Acceptance criteria

```gherkin
Feature: The cascade's cost is measured before its default is changed

  Scenario: The three serving modes are measured as a same-device paired A/B
    Given the encoder runtime wired and its artifact installed (T-037-a)
    And the three modes .pickerBrain, .standaloneEncoder, .encoderFirstEscalate switchable without relaunch
    When the same transcript set is run through all three arms on the reference device
    Then each arm reports per-stage timings, end-to-end latency, and the p50/p95 of the local leg
    And the report states the arm-to-arm deltas, not only the absolute numbers

  Scenario: The escalation rate is reported with its reason breakdown
    Given the three escalation reasons abstained, failed, subBandConfidence
    When arm C escalates
    Then the report gives the escalation rate over the transcript set
    And it breaks that rate down by reason
    And it reports, for subBandConfidence escalations, the rate at which the picker brain returns the same action the encoder did

  Scenario: Peak RSS and cold start are measured, not assumed
    Given both brains resident for the whole of arm C
    When the run completes
    Then the report gives peak RSS for each arm against the device's available-RAM floor
    And it reports first-turn-after-cold-launch latency per arm against that arm's warm p95
    And it states plainly whether the picker was observed to be evicted between turns

  Scenario: The worst-case escalate turn is measured against the 4 s budget
    Given the encoder's 2.0 s timeout with zero retries and the picker brain's 10 s timeout
    And LocalBrainChain passing no remaining-time budget to the stand-in
    When the escalated-turn latency distribution is reported
    Then the observed worst case and p95 are stated against NFR-002's 4 s
    And the report says explicitly whether the sum-of-timeouts bound was observed

  Scenario: The measurement can recommend against the flip
    Given a reference device whose numbers miss one or more Stage 1 conditions
    When the report is written
    Then it states "do not flip" with the failing condition named and its measured value
    And it does not propose a lowered threshold as the remedy
    And no default is changed by this task
```

## Implementation notes

- Read first: `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §6.3 (the Stage 1 conditions this feeds), §6.4 (the budget) and §6.5 (the failure modes); `specs/T-037-a-notes.md:461-503` (the cascade's design rationale and the evidence events already built for it).
- The instrumentation exists. `TurnTimingRecorder` is wired at `AppCoordinator.swift:1689-1694` and gated on `IntentEncoderFeature.isEnabled`; `TurnLatencyReporter` emits one `turn_timing_breakdown` event per turn with `stages` metadata (`TurnTimingBreakdown.swift:302-390`); the settings readout is `lastTurnTimingBreakdown` (`SettingsView.swift:3461-3480`). Building a second timer would produce a second set of numbers and no second opinion.
- `measure_device.py` is the off-device harness for the encoder leg and already fails non-zero below its gates (`:270-294`, *"LATENCY GATES FAILED — this build must not ship"*). Use its flags; do not re-implement percentile or the cold/warm split.
- Pair the arms on the **same** transcript set and the same device, and report deltas. An arm-to-arm comparison across two devices or two corpus revisions is not evidence about the cascade.
- Cold start must be measured, not simulated: a genuine cold launch per arm, repeated enough times for a p95.
- RSS sampling must cover the whole session including the escalated turns; a peak sampled only at turn boundaries will miss the moment both models' working sets are live.
- No PII in the report. Timings, counts and reason codes only — never the transcript (NFR-016; T-049/T-050 are the precedent).
- If a Stage 1 condition cannot be measured on the available hardware, record it as UNMEASURED with what hardware would be needed. Do not substitute a simulator number for a device number; the budget is defined on the reference device (NFR-001/NFR-002).

## Definition of done
- [ ] Paired same-device A/B across all three serving modes on one transcript set
- [ ] Per-stage and end-to-end p50/p95 per arm, with arm-to-arm deltas
- [ ] Escalation rate broken down by the three escalation reasons, plus the sub-band agreement rate
- [ ] Escalation overhead isolated from the encoder pass cost
- [ ] Peak RSS per arm against the device's available-RAM floor, and whether picker eviction was observed
- [ ] Cold-start first-turn latency per arm against that arm's warm p95
- [ ] The worst-case escalate turn stated against NFR-002's 4 s, confirming or refuting the 2 s + 10 s bound
- [ ] An explicit flip / do-not-flip recommendation with the failing Stage 1 condition named when applicable
- [ ] Machine-readable evidence under `tools/train-intent/docs/tg12-evidence/` with a re-runnable run manifest
- [ ] No PII in the report; timings and counts only
