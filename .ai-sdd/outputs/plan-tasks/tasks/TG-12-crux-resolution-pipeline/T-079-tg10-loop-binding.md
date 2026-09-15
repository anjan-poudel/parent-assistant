# T-079: TG-10 Loop Binding — tables and calibration as continuously-updated artifacts

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The registration of the variant tables and `calibration_temperature` as promotion-gated artifacts in the continuous-learning loop, and the variant-table revision in the run manifest
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-075](T-075-canonicalizer-implementation.md), [T-058](../../TG-10-continuous-learning-loop/T-058-promotion-gate-implementation.md)
- **Blocks:** —
- **Requirements:** NFR-015, NFR-016, NFR-029
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §7 and evidence row E-16 (gap G-9); `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §6, §7

## Description

TG-10 built the loop. This task **joins** the canonicalizer and the cascade's calibration to it — it does not redesign anything. The whole task is one idea: an artifact that changes the encoder's behaviour must be a **named, revisioned, gated input** to the numbers that decide whether the encoder ships. Without the binding, a table change is an invisible input to a gated number, which is the one thing the promotion rule cannot tolerate.

**Why these artifacts are eligible at all.** Both the variant tables and `calibration_temperature` are **data files replaced without an app change** — the property `DialectBiasComposer.swift:104-105` already claims for the lexicon (*"Content, not code: the … pipeline replaces the JSON without an app change"*). The calibration temperature ships in `meta.json` and is applied in code rather than baked into the graph, precisely so it stays *"reviewable, diffable and recorded in the T-036 run manifest"* (encoder design §5). That is exactly the eligibility criterion the promotion gate operates on.

**What the loop may propose, and what it may never do.** It may propose **new variant-table entries** from corrections (a user saying the same thing twice, once mis-transcribed and once corrected, is a live variant pair; TG-10's `T-057` correction miner turns those into validated rows), **frequency corrections** to existing entries — an entry whose live `occurrences` diverges sharply from its corpus count is a retirement candidate, which is how a table stays small — and **`calibration_temperature` deltas** from a re-fit. It may never **publish without the gate**: a candidate table is promoted only through TG-10's promotion rule (*"all eight T-038 gates pass AND the candidate beats the incumbent on the corpus-revision-bound eval"*, `2026-09-13-continuous-learning-loop-design.md:404-405`), with UNEVALUATED failing closed and a human performing the publish. It may never **modify the band policy**: TG-10 invariant 3 stands — *"No new threshold. The band policy … is not modified by the loop"* — and design D-7 restates it, because the cascade's threshold *is* `IntentRouter.Config.default.acceptThreshold` and there is nothing separate to tune. The loop may re-fit `calibration_temperature`, which moves *confidence* and therefore which band an output falls into; it may never move the band itself.

**The one genuinely new privacy question, referred rather than answered.** A candidate variant pair contains the user's words. TG-10's egress is hashed-only, and *"a hash of a low-entropy utterance is a pseudonym, not anonymity"* (`:375`) — so a table entry derived from a user's utterance is a **content-bearing artifact** and must not be reconstructed from the hashed channel. Concretely: the loop may carry the *fact* that a candidate rule is warranted, and the *counts*; the surface forms are authored on-device or by the linguistic pipeline, and the egress contract is unchanged. This is gap G-3 and it is **referred to TG-10's `T-053` privacy basis and `T-059` audit** — this task implements the binding only after that referral is answered, and must not settle the question by implementing an egress path.

**Where it lands.** `run_encoder_pipeline.py`'s decision step is the registration point: the variant-table revision and the applied `calibration_temperature` become recorded inputs to a run, alongside the corpus revision. A promoted artifact then records which table revision produced its numbers.

## Acceptance criteria

```gherkin
Feature: The loop's gate covers the canonicalizer's tables and the encoder's calibration

  Scenario: The tables and the calibration are registered as promotion-gated artifacts
    Given TG-10's promotion rule: all eight T-038 gates pass AND the candidate beats the incumbent on the corpus-revision-bound eval
    When the registration lands
    Then a variant-table revision and an applied calibration_temperature are named inputs to the run's decision
    And a candidate table is refused unless every gate passes and it beats the incumbent
    And an UNEVALUATED candidate fails closed, as the incumbent rule already requires

  Scenario: A table change cannot move a gated number invisibly
    Given a run whose decision depends on the encoder's accuracy
    When the variant-table revision changes between two runs
    Then the two runs' manifests differ in a recorded field naming the table revision
    And a reader can determine which table revision produced a recorded number
    And no gated number is reported without its table revision and calibration temperature

  Scenario: The band policy is untouched by the loop
    Given TG-10 invariant 3: the band policy is not modified by the loop
    And the cascade's threshold is IntentRouter.Config.default.acceptThreshold
    When the binding lands
    Then no new threshold is introduced and no band constant is written by the loop
    And a calibration_temperature re-fit is permitted, because it moves confidence rather than the band
    And a divergence rate remains telemetry, never a runtime decision by itself

  Scenario: Derived tables remain content-bearing and the egress contract is unchanged
    Given a variant pair contains the user's utterance and the hashed egress is a pseudonym, not anonymity
    When a rule derived from live corrections is proposed
    Then only the fact that a candidate rule is warranted and the counts are carried off-device
    And no surface form is reconstructed from the hashed channel
    And the question of whether such a pair is content under the egress contract is referred to T-053 and T-059, not settled here

  Scenario: Simplicity is a maintained property, not a starting condition
    Given an entry whose live occurrences diverge sharply from its corpus count
    When the loop proposes its retirement
    Then retirement is a legitimate promotion candidate with the same gate as an addition
    And the measured effect of the retirement is recorded, so a table does not accumulate unmeasured entries

  Scenario: No content and no PII reach any manifest or event
    Given the run manifest, the promotion record and the loop's events
    When a candidate table or a calibration delta is processed
    Then rule ids, table revisions, counts and gate values appear
    And no transcript, variant surface, canonical surface or contact name appears
    And the assertion is covered by a test, not by convention
```

## Implementation notes

- Read first: the design's §7 in full, and §4.3 (the table schema, whose `evidence` block is what the loop fills); `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §5.2 (the hashed-egress reasoning), §6 (the promotion rule), §7 (boundaries and invariants); TG-10's `T-053`, `T-057`, `T-058`, `T-059`, `T-060`; `tools/train-intent/src/run_encoder_pipeline.py`.
- Do not build a second promotion gate. The registration extends the existing decision step; a parallel gate for tables would be the failure mode where two gates disagree and the weaker one wins.
- A candidate entry from the loop arrives with `evidence.source: "fixture"` and its cited examples (design §4.3.1). It is a **candidate**, not an authored rule — the same schema, the same validator, and the same refusal of an unsourced entry.
- The promotion gate is corpus-revision-bound. Because the tables change model *input* and never the corpus, a table change does not move the revision tag — which is exactly why the table revision must be recorded separately. Without that field, two runs on the same revision are not comparable and nothing says so.
- Do not implement an egress path for surface forms. Design §7's position is that the counts and the warrant may travel and the surfaces may not; if the referral comes back the other way, that is a change to TG-10's egress contract and belongs in TG-10's task, not here.
- Retirement deserves the same evidence as addition. A table that only grows accumulates entries whose effect was never measured — and in this pipeline an unmeasured entry on an emergency-adjacent row is a safety cost, not a size cost.
- T-077 and T-078 consume this binding: their evidence must name the table revision. If the binding lands after they run, their artifacts are re-issued with the revision recorded rather than left with an unnamed input.
- No PII, no content. The counts and the rule ids are the entire vocabulary (NFR-016, NFR-015 for the egress side). Safety-critical confidence threshold for this task's own implementation: NFR-029's 0.85.

## Definition of done
- [ ] Variant-table revision and `calibration_temperature` registered as named inputs to `run_encoder_pipeline.py`'s decision step
- [ ] The promotion rule applied to tables and calibration unchanged: all gates pass and the candidate beats the incumbent; UNEVALUATED fails closed
- [ ] Every gated number in a run manifest carries its table revision and calibration temperature
- [ ] No new threshold introduced and no band constant written by the loop
- [ ] Retirement implemented as a promotion candidate with the same gate, with the measured effect recorded
- [ ] Candidate entries carry the `evidence` block and pass the same `issues()` validator as authored entries
- [ ] Surface forms never reconstructed from or carried by the hashed channel; gap G-3's referral to T-053/T-059 recorded and unresolved
- [ ] T-077/T-078 evidence re-issued with the table revision named, if they ran before this landed
- [ ] A test asserts no transcript, surface form or contact name appears in the manifest, promotion record or events
