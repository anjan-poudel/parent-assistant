# T-073: Cascade-Default Policy & Flip-Gate Design

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The policy that makes `.encoderFirstEscalate` the default local-brain mode: the Stage 0 / Stage 0b / Stage 1 gate set, the turn-level deadline, the residency and cold-start provisions, the kill switch, and the observability vocabulary
- **Agent:** architect
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-071](T-071-cascade-latency-residency-measurement.md), [T-038](../../TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md)
- **Blocks:** [T-076](T-076-cascade-default-implementation.md), [T-078](T-078-latency-residency-default-flip-verification.md), [T-078](T-078-latency-residency-default-flip-verification.md)
- **Requirements:** FR-007, FR-008, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §6 and §6.6; `specs/T-037-a-notes.md:461-503`

## Description

The cascade mechanism is fully built and shipped as an **opt-in** third mode. `LocalBrainChain` holds a `preferred` brain and a `standIn`, and when it is constructed with a `Cascade` the preferred brain answers first while the stand-in answers **the same turn** on an abstention, a failure, or a sub-band answer (`LocalBrainChain.swift:56-56`; reasons `abstained` / `failed` / `subBandConfidence` at `:44-55`). `IntentEncoderWiring.servingMode(isEnabled:isCascadeOn:)` (`IntentEncoderFeature.swift:154-158`) selects among `.pickerBrain`, `.standaloneEncoder` and `.encoderFirstEscalate`, and `isCascadeEnabled` (`:106-109`) reads an absent key as **false**. This task designs the policy under which that default changes.

It produces a **policy specification**, not a flip. The flip is T-076, behind T-078's verification.

**1. The gate set, numeric and revision-bound.** The design's §6.3 gives three stages. This task finalises them as an executable decision:

- **Stage 0 — the encoder may ship at all.** The eight gates (`config.yaml:58-69`) on corpus revision `7f71b8ae`, any one failing withholding the artifact. Stage 0 is a precondition, not a formality: the shipped artifact's published run failed (`closed_intent_accuracy` ~0.53, `emergency_recall` ~0.9375 against a **1.00 hard gate**) — `IntentEncoderFeature.swift:6-8`.
- **Stage 0b — robustness.** TG-11's two additive gates: order-invariance `A_ctrl − A_perm ≤ 0.03` (`T-065:18`) and dialect-robustness `max over claimed slices of (A_standard_twin − A_dialect_slice) ≤ 0.05`, with per-slice `side_effect_precision ≥ 0.97` and `emergency_recall == 1.00` (`T-065:28-30`).
- **Stage 1 — the cascade leg must beat the standalone leg.** The eleven conditions of design §6.3, fed by T-071's measurements.

**2. The turn-level deadline, specified.** This is the policy's load-bearing engineering decision. The encoder times out at 2.0 s with zero retries (`IntentEncoderInterpreter.swift:168-169`); the picker brain times out at **10 s** with one retry (`LocalIntentInterpreter.swift:47-49`); `LocalBrainChain` passes no remaining-time budget to `standIn`. The worst-case escalate turn is therefore **12 s** against NFR-002's 4 s, in the mode where the user has already waited for a model to fail. This task specifies how the chain carries a turn deadline and passes `remaining` to the stand-in, and what the stand-in does when `remaining` is already short — including whether it declines rather than starting work it cannot finish. Note the encoder design already reasoned correctly about this class of problem one level down (F-1: *"a pass that exceeds the p95 budget has already missed the latency requirement and escalating is the better outcome than waiting"*); the policy is the same argument at the turn level.

**3. Residency and cold-start provisions.** Per T-071's numbers: the peak-RSS bound against the device's available-RAM floor (the `T-018-b` precedent — decline load below 2.5 GB available rather than OOM), and the cold-start provision. The speculative case worth designing for is design §6.5's third: both brains warming after a cold launch, the one turn where the cascade's ordering is strictly harmful. The task decides whether the first turn after a cold launch is served picker-first, and records the cost of that choice.

**4. The sub-band's home, decided on T-071's evidence.** If the picker brain agrees with the encoder's sub-band answer often, escalating is pure latency cost, and the alternative is the existing confirmation flow — which already handles tier-`.confirm` sub-band actions (`IntentRouter.swift:316-330`). This task decides the policy; T-071 supplies the agreement rate.

**5. Kill switch and observability, confirmed against the existing shapes.** The kill switch is already the right shape (`IntentEncoderPreferences.setCascadeEnabled(false)`, resting on `.standaloneEncoder` — a mode the internal A/B already exercises). The canonicalizer's is `Policy.enabled` with an `orthographicOnly` intermediate arm. The observability vocabulary is fixed: reason codes, counts and rule/table ids — **never** transcript or reply content, per the existing `LocalBrainChain` comment (*"Metadata only, never transcript or reply content"*, `:36-40`) and NFR-016.

**What this task must not do.** It does not change `IntentRouter`, `CommandRouter`, the band constants, the confirmation flow or the keyword net. It does not lower a gate to make a flip possible: design D-8 makes "do not flip" a legitimate, recordable outcome, and the design's own risk list says so.

## Acceptance criteria

```gherkin
Feature: The cascade's default-flip policy is specified as numeric, revision-bound gates

  Scenario: The flip decision is expressed as an executable gate set
    Given the eight gates in config.yaml:58-69 on corpus revision 7f71b8ae
    And TG-11's two additive robustness gates
    And the Stage 1 conditions fed by T-071's measurements
    When the policy is written
    Then every condition has a comparator, a threshold, and the revision it is measured on
    And no condition is phrased as a judgement or an adjective
    And the decision rule is stated as: flip if and only if Stage 0 and Stage 0b are green and every Stage 1 condition holds

  Scenario: The turn-level deadline is specified against the sum-of-timeouts bound
    Given the encoder's 2.0 s timeout with zero retries and the picker brain's 10 s timeout
    And LocalBrainChain passing no remaining-time budget to the stand-in
    When the policy is written
    Then it specifies how a turn-level deadline is carried and how "remaining" reaches the stand-in
    And it specifies the stand-in's behaviour when the remaining budget is already short
    And it states the worst-case escalate turn the policy guarantees, against NFR-002's 4 s

  Scenario: Residency and cold start have specified provisions, not assumptions
    Given T-071's measured peak RSS and cold-start numbers
    When the policy is written
    Then it states the peak-RSS bound against the device's available-RAM floor
    And it decides whether the first turn after a cold launch is served picker-first, recording that choice's cost
    And it states the observed behaviour when the picker is evicted between turns

  Scenario: The sub-band's home is decided on measured agreement, not preference
    Given T-071's sub-band agreement rate
    When the policy is written
    Then the policy states whether sub-band answers escalate or enter the existing confirmation flow
    And the decision cites the measured agreement rate
    And it notes that tier-.confirm sub-band actions already take the confirmation path today

  Scenario: A failed gate produces a recorded do-not-flip, never a relaxed threshold
    Given one or more Stage 1 conditions failing on the reference device
    When the policy is applied
    Then the recorded outcome is "not flipped" with the failing condition and its measured value
    And the policy forbids re-tuning a Stage 1 threshold without the same evidence discipline as authoring one
    And no gate in Stage 0 or Stage 0b is weakened to reach a flip

  Scenario: The safety boundary and the kill switch are restated
    Given the keyword net reads the original transcript before any model
    When the policy is written
    Then no cascade mode places a model upstream of the safety net
    And the kill switch restores .standaloneEncoder on a per-device basis without a rebuild
    And the observability vocabulary is stated as reason codes, counts and ids only, never transcript or reply content
```

## Implementation notes

- Read first: design §6 in full; `LocalBrainChain.swift:28-74` (the `Cascade` struct, `EscalationReason`, and the "cascade can only ADD a layer" property); `IntentEncoderFeature.swift:148-194` (the three modes, the slot construction, `cascadeAcceptThreshold`); `IntentRouter.swift:316-330` (`bandChecked`); `specs/T-037-a-notes.md:461-503`.
- `cascadeAcceptThreshold` is **defined as** `IntentRouter.Config.default.acceptThreshold` and pinned by `IntentEncoderWiringTests.swift:336-342`. Design D-7 rests on this: the flip changes which brain fills the slot, never the band. Any policy mechanism that would introduce a second number is out of scope by construction.
- T-071's numbers are the input. If T-071 has not run, this task specifies the *decision procedure* with the thresholds named and the values marked UNMEASURED — it does not guess the values, and it does not weaken a condition to make a decision possible.
- Design risk R-11 is relevant: the accept band exists as three independent 0.7s, one of them a hard-coded literal in `CommandRouter.swift:1139-1155`. The policy must record that the band is not uniform in code and that a future band change would need all three sites — but repairing it is a `CommandRouter` edit and therefore out of scope here.
- The cold-start decision must be honest about its own cost. Serving picker-first on the first turn after a cold launch avoids the worst double-load case at the price of that turn being as slow as today's default — which is a *better* outcome than 12 s, and the reasoning should say so explicitly.
- No PII in any policy artifact. The observability vocabulary in particular is a specification of what may be logged, so it should state the exclusions positively.

## Definition of done
- [ ] The Stage 0 / Stage 0b / Stage 1 gate set finalised with comparators, thresholds and named revisions
- [ ] The decision rule stated as a single if-and-only-if, executable without interpretation
- [ ] The turn-level deadline specified: how the budget is carried, how `remaining` reaches the stand-in, and the guaranteed worst case against NFR-002
- [ ] Residency and cold-start provisions specified against T-071's measurements, including whether the first post-cold-launch turn is served picker-first
- [ ] The sub-band's home decided with the measured agreement rate cited
- [ ] The do-not-flip path recorded as a first-class outcome, with threshold re-tuning explicitly forbidden as a remedy
- [ ] The kill switch and the observability vocabulary (codes, counts, ids only) specified
- [ ] No change to `IntentRouter`, `CommandRouter`, the band constants, the confirmation flow or the keyword net
