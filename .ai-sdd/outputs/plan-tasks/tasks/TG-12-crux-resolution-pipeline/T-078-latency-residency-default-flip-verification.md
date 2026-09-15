# T-078: Latency, Residency & Default-Flip End-to-End Verification

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The group's end-to-end verification on the shipping configuration: the Stage 1 latency, residency and cold-start conditions (1.5–1.11), the full gate set evaluated once, the canonicalizer's measured per-slice effect, and the observability sweep
- **Agent:** qa-engineer
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-076](T-076-cascade-default-implementation.md), [T-077](T-077-canonicalization-losslessness-safety-verification.md), [T-071](T-071-cascade-latency-residency-measurement.md)
- **Blocks:** —
- **Requirements:** FR-007, FR-008, FR-009, NFR-001, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §6.3 (conditions 1.5–1.11), §6.4, §6.5, §6.6, §4.6; evidence rows E-6/E-10/E-11/E-12/E-13/E-14/E-15 (gaps G-2, G-6, G-8)

## Description

This is the gate that decides whether the group's outcome is "shipped" or "measured and declined". It runs after the pieces land, on the **shipping configuration**, and it does two things that are one run: it verifies the Stage 1 conditions, and it evaluates the whole flip rule.

**Why these are one task, not two.** The brief had latency-budget verification and default-flip end-to-end verification as separate tasks; the ID budget (see the design's §12) merged them, and on the merits the merge is honest — both are post-flip verification on the same build, the same device and the same run, and the full-gate-set evaluation already contains the latency conditions. They remain **two labelled parts of the report** so a reader can see which verdict came from which, and the safety verification (T-077) stays a separate task by design.

### Part A — the Stage 1 conditions, measured on the flipped default

T-071 measured the cascade **as an option**, to decide whether to flip. Part A measures it **as the default**, and it is deliberately a different run by a different agent: a measurement that justifies a change is not the measurement that verifies the change. Three things are different from T-071's run. First, the **shipping build** with `INTENT_ENCODER` present — T-071 could switch modes because the runtime is wired in the debug path, but NFR-002 is defined against what ships. Second, a population that is not the clean corpus replay alone: the escalate rate on noised, elder-register input is a different number. Third, an **independent extraction** — recomputing T-071's numbers with T-071's invocation is a re-run, not a verification.

Conditions verified: 1.5 `L_p95(encoderFirstEscalate) ≤ L_p95(pickerBrain)`; 1.6 local leg p95 ≤ 2.0 s; 1.7 end-to-end VAD→TTS-start p95 ≤ 4.0 s; 1.8 escalation overhead ≤ 200 ms p95; 1.9 the turn-level deadline present and the worst case ≤ 4.0 s; 1.10 peak RSS ≤ the device's available-RAM floor; 1.11 cold-start first turn ≤ 2 × warm p95.

**Condition 1.9 is verified adversarially.** Do not verify the deadline by reading the code. Force the failure — a transcript that makes the encoder time out, or a stubbed encoder that does — and confirm the turn still completes inside the budget with a real answer. The failure mode being guarded against is a stand-in that starts a 10 s pass at t = 2.0 s, and the only way to know it does not is to make it want to. Design invariant 7 also applies: declining must produce an answer through the router's own policy, never silence.

**Residency is verified as a curve, not a peak.** Condition 1.10 is about the standing cost of two resident brains, and the failure mode is eviction, not a crash: if the picker is dropped between turns, every escalated turn becomes a cold load and the composite p95 degrades in a way a single peak number hides. Report whether eviction was observed, and report the escalate-turn distribution separately from the ambient one so an eviction shows up as a mode rather than an outlier.

### Part B — the whole flip rule, once, on one revision

Stage 0's eight gates on `7f71b8ae`; Stage 0b's four robustness conditions; Stage 1's eleven. The outcome is one line: **flipped**, **not flipped**, or **not evaluable** — with every failing number printed. Design D-8 makes non-flip legitimate and §6.3 forbids the alternative (retuning until it passes). The **third** outcome matters: G-1 leaves five of Stage 0's gates unmeasured, and an unmeasured gate is not a passing gate. If any Stage 0 gate is UNMEASURED, the flip is not evaluable and is not performed — that must be expressible, or a binary framing will quietly read UNMEASURED as a pass.

### Part C — does canonicalization buy anything, per dialect slice?

E-6, and the honest-measurement centrepiece of the group. Until now it has been unmeasurable because no canonicalized corpus existed; it exists now. Measure `A_canonical − A_uncanonicalized` per dialect slice on TG-11's dialect fixture, and print the number even when it is **zero or negative**. Design R-5 and open question 1 both anticipate that some slices gain nothing and that the effect may be concentrated in the orthographic rules; a slice that gains nothing is recorded as uncovered, and is explicitly **not** a reason to widen the rules. If the mechanism buys +0, this task is what says so with numbers.

### Part D — the sweeps and the call-graph assertions

**Observability (E-15).** Run a cascade session with the canonicalizer active and sweep every emitted event for content-bearing fields. The permitted vocabulary is rule id, table id, kind and counts; the forbidden content is the transcript and both surface forms — which in this pipeline are, by construction, the user's own words. This is an **assertion in a test**, not a one-off review: a sweep done by hand does not protect the next commit. T-049/T-050 are the precedent for how leaks here are treated, and NFR-016 is a hard constraint.

**Call-graph assertions, verified behaviourally.** The keyword net is called on the raw transcript before any interpreter (FR-009); the cache key is unchanged; the stand-in receives the original sanitised transcript. Each is asserted by a test that fails if the ordering moves — T-077 pins the net's *matches*, this pins the *ordering*, which is the thing a refactor actually breaks.

**The kill switch is a first-class path.** Exercise both directions on a device: false → `.standaloneEncoder`, true → `.encoderFirstEscalate`, each on the next turn with no relaunch.

**Findings are reported, not fixed here.** A failing gate or a content leak produces a report, a do-not-flip recommendation and a defect against the owning task — never a code change in the verifier's own commit, which is how a verification becomes a self-certification.

## Acceptance criteria

```gherkin
Feature: The flipped default and the canonicalizer are verified end to end on the shipping configuration

  Scenario: Part A runs on the shipping build, independently of T-071's invocation
    Given the flip landed and INTENT_ENCODER present in the shipping configuration
    When the Stage 1 latency conditions are verified
    Then the run uses the shipping build, not only the debug path
    And the measurement is extracted independently of T-071's harness invocation
    And the report states which build, device, corpus revision and transcript population produced each number

  Scenario: Each Stage 1 latency condition is reported with its number
    Given conditions 1.5, 1.6, 1.7 and 1.8
    When the run completes
    Then L_p95(encoderFirstEscalate) and L_p95(pickerBrain) are reported with their difference
    And the local-leg p95 and the end-to-end p95 are reported against 2.0 s and 4.0 s
    And the escalation overhead p95, isolated by the cascade_decision span, is reported against 200 ms
    And the escalated-turn distribution is reported separately from the all-turns distribution
    And every value is reported as pass or fail, never as an adjective

  Scenario: The turn-level deadline is verified adversarially
    Given condition 1.9 requires a turn-level deadline and a worst-case escalated turn within 4.0 s
    When the encoder is made to time out on a turn
    Then the turn completes inside the turn budget with a real user-visible answer
    And the stand-in does not begin a pass it cannot finish within the remaining budget
    And the observed worst case is reported against 4.0 s, replacing the 2 s + 10 s bound

  Scenario: Residency and cold start are measured, not assumed
    Given both brains resident for the whole session in the default mode
    When peak RSS is sampled across the session including escalated turns
    Then the peak is reported against the device's available-RAM floor
    And the report states plainly whether the picker was observed to be evicted between turns
    And cold launches are repeated enough times to report a p95, reported against that arm's warm p95
    And the case where both brains warm after a cold launch is reported explicitly

  Scenario: Part B evaluates the whole gate set once as a single decision
    Given Stage 0's eight gates on revision 7f71b8ae, Stage 0b's four robustness conditions and Stage 1's eleven conditions
    When the flip rule is evaluated on the shipping configuration
    Then the outcome is reported as flipped, not flipped, or not evaluable
    And every failing condition is printed with its measured value
    And no threshold is changed to reach a different outcome

  Scenario: An unmeasured gate is not treated as a passing gate
    Given gap G-1: gates 0.2 and 0.4 to 0.8 are unmeasured for the shipped artifact
    When the flip rule is evaluated with those gates UNMEASURED
    Then the outcome is "not evaluable" and the flip is not performed
    And the report names each unmeasured gate and what would measure it
    And it does not infer a pass from the gates that are green

  Scenario: Part C measures canonicalization's effect per dialect slice, including zeroes
    Given a canonicalized corpus now exists (T-075)
    And TG-11's dialect fixture at eval/dialect_holdout.jsonl
    When A_canonical minus A_uncanonicalized is measured per dialect slice
    Then the per-slice numbers are printed, including slices where the difference is zero or negative
    And a slice that gains nothing is recorded as uncovered rather than as a reason to widen the rules
    And the report states which half of the canonicalizer (dialect tables or orthographic rules) the measured effect is concentrated in

  Scenario: Part D sweeps observability and asserts the call graph behaviourally
    Given the permitted vocabulary is rule id, table id, kind and counts
    When a cascade session runs with the canonicalizer active
    Then zero content-bearing fields are found across every emitted event, including turn_timing_breakdown stages metadata
    And the sweep is asserted by a test that runs with the suite, not only by a manual check
    And moving the keyword net downstream, re-keying the cache, or feeding the stand-in the canonical transcript each fails a test
    And the canonicalizer is demonstrated to be unreachable from the keyword net's path

  Scenario: The kill switch is exercised in both directions
    Given IntentEncoderPreferences.setCascadeEnabled
    When the setting is toggled false and then true on a device
    Then .standaloneEncoder and .encoderFirstEscalate are each observed on the next turn with no relaunch
    And the encoder remains installable and usable for inspection while disabled

  Scenario: Findings are reported, not fixed in place
    Given a failing gate or a content leak found by this task
    When the report is written
    Then the finding is recorded with its evidence and routed to the owning task as a defect
    And no production code is changed by this task
    And the recorded outcome is not flipped, with the failing condition named
```

## Implementation notes

- Read first: design §6.3 (the full gate set), §6.4 (the budget and the per-mode sum), §6.5 (double-brain cost, residency, cold start), §6.6 (observability), §4.6 (the seams), §14 (E-6, E-10…E-15 and gaps G-2, G-6, G-8); `specs/T-038-notes.md` for harness conventions; `T-065` for the two robustness gates; TG-11's `T-064` for the dialect fixture; `specs/T-037-a-notes.md:461-503`.
- No new instrumentation. `TurnTimingBreakdown` (stages at `:50-69`, reporter at `:302-390`), `VoiceTurnLatencyTracer` (marks `vad_fired` → `asr_done` → `router_done` → `speak_queued`), and `tools/train-intent/src/measure_device.py` (p50/p95 gates at `:220-221`, cold/warm split at `:139-148`, non-zero exit at `:270-294`) already cover all three axes. A second timer produces a second set of numbers and no second opinion.
- The percentile convention is nearest-rank, as `tests/test_measure_device.py:52-61` implements it. Use the shipped `percentile()`; an interpolating percentile would quietly move every gate.
- NFR-002 is end-to-end: end-of-utterance (VAD) to TTS start. A local-leg p95 that passes while the end-to-end number fails is a failure of 1.7, and the report must not present the local leg as the answer.
- Verify on the reference device. A simulator number is not a device number. If the reference device is unavailable, record UNMEASURED with the hardware needed — do not substitute, and do not silently drop the condition.
- For 1.9, a stubbed or forced-timeout encoder is a legitimate instrument as long as the report says which rows were forced and which were natural, and the real-timeout case is exercised too.
- E-6 sequences after T-075 by construction (gap G-6 says so): the per-slice effect cannot be measured before a canonicalized corpus exists. Do not attempt an estimate earlier and do not report a proxy as the measurement.
- The observability sweep must include the canonicalizer's own event, the escalation event, the timing events and the interpreter's telemetry. The temptation is to sweep the obvious new event and miss `turn_timing_breakdown`'s `stages` metadata, which is where a stage name could smuggle content.
- Line-number citations in this group's documents were verified against source at writing time; the encoder design carries a known-stale citation for the emergency list (`1403-1408` where the list is now at `1468-1473`). Re-verify before citing in the report.
- No PII and no surface form in any artifact. The device identifier is permitted; the utterance is not (NFR-016).
- If the flip did not land because a Stage 0 gate is red, the honest outcome is **blocked**, with the blocking gate named — not a verification of a mode that is not the default.

## Definition of done
- [ ] Part A run on the shipping configuration with `INTENT_ENCODER` present, extracted independently of T-071's invocation
- [ ] Conditions 1.5, 1.6, 1.7 and 1.8 reported with numbers and pass/fail; escalated-turn distribution reported separately
- [ ] Condition 1.9 verified adversarially with a forced encoder timeout; worst case reported against 4.0 s
- [ ] Condition 1.10 reported against the device's available-RAM floor, eviction observed or not stated explicitly
- [ ] Condition 1.11 reported, including the both-brains-warming case
- [ ] Part B's whole-gate-set verdict reported as flipped / not flipped / not evaluable, every failing number printed
- [ ] UNMEASURED Stage 0 gates named individually and not counted as passes
- [ ] Part C's per-dialect-slice canonicalization effect printed, zeroes and negatives included, with the effect's concentration stated
- [ ] Part D's observability sweep asserted by a test with zero content-bearing fields, and the three call-graph orderings asserted behaviourally
- [ ] The kill switch exercised in both directions on a device, or recorded UNMEASURED with the hardware needed
- [ ] Findings routed as defects; no production code changed by this task
- [ ] Machine-readable evidence under `tools/train-intent/docs/tg12-evidence/` with a run manifest pinning build, device, corpus revision and table revision
- [ ] No PII or surface form anywhere in the evidence
