# TG-10: Continuous Learning Loop

> **Jira Epic:** Continuous Learning Loop

## Description

Closes the gap between the flywheel the app already ships and the retraining pipeline TG-08 built. Today `IntentLogStore` records what the user confirmed and corrected, the family reads it in `IntentLogReviewView`, and a `ShareLink` hands an export to whoever runs the next training batch — a manual loop with a human courier. This group designs and builds the automatic one: opt-in capture on-device, hashed-only egress, a correction/repeat-after-abstention/low-confidence miner that feeds the **existing** authoring chain (`gen_teacher.py` rephrase → `stt_noise.py` variants, leak guards and dedup unchanged), a weekly retrain proposal, and a promotion rule that must clear all eight T-038 gates **and** beat the incumbent on the corpus-revision-bound eval before any model publishes. Shadow scoring against the active brain, divergence telemetry through the existing sanitised bus, and the fail-soft ladder are the runtime healing half.

Two tasks are R&D and start immediately: T-052 measures whether the recorded signals actually predict errors, at what yield, over the shipped `IntentLogStore.Record` shape; T-053 fixes the privacy basis for a *hashed* egress path against Open Decision 12's consent precedent (`constitution.md:128-132`), including the retention window and the exact consent copy. Nothing is built until both answer.

**Reconciliation with TG-08.** The loop consumes TG-08's contracts and changes none of them. The encoder and its taxonomy stay T-034/T-035's ([T-034](../TG-08-nepali-intent-encoder/T-034-training-data-strategy.md), [T-035](../TG-08-nepali-intent-encoder/T-035-joint-intent-slot-encoder-design.md)); the training pipeline stays [T-036](../TG-08-nepali-intent-encoder/T-036-training-distillation-pipeline.md)'s; the eval harness and its gates stay [T-038](../TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md)'s. T-058 adds the incumbent comparison to the existing publish decision in `run_encoder_pipeline.py`, it does not fork the gate runner. If T-033 returns NO-GO, the loop still stands for the incumbent LLM brain: capture, mine, augment and the promotion rule are model-agnostic, and only the shadow-scoring incident is encoder-specific.

**Boundary this group does not cross.** Signal only, never content: no raw audio, no raw transcript, no slot values (contact/medication/message), no health values leave the device on any loop path. The keyword safety net, emergency dispatch, medication acknowledgement and the confirmation flow stay deterministic and upstream of every model — the loop never gates them. No model publishes without a human decision; the promotion rule can only block. The shipped `IntentLogStore` docstring's claim that the log "leaves only via the family's explicit export" is amended by T-056, in the open, rather than left false.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-052](T-052-continuous-learning-signal-quality-feasibility.md) | Continuous-Learning Signal Quality — Feasibility (R&D) | S | — | MEDIUM |
| [T-053](T-053-learning-loop-privacy-review.md) | Learning-Loop Privacy Review (R&D) | S | — | MEDIUM |
| [T-054](T-054-capture-schema-egress-contract-design.md) | Capture Schema & Egress Contract Design | M | T-052, T-053 | HIGH |
| [T-055](T-055-shadow-scoring-healing-protocol-design.md) | Shadow Scoring & Healing Protocol Design | M | T-054 | HIGH |
| [T-056](T-056-capture-egress-implementation.md) | Capture & Egress Implementation (opt-in) | L | T-054, T-053 | HIGH |
| [T-057](T-057-correction-miner-implementation.md) | Correction Miner Implementation | M | T-056, T-052 | MEDIUM |
| [T-058](T-058-promotion-gate-implementation.md) | Promotion Gate Implementation | M | T-057, T-038 | HIGH |
| [T-059](T-059-privacy-audit.md) | Privacy Audit (verification) | M | T-056 | HIGH |
| [T-060](T-060-loop-end-to-end-fixture.md) | Loop End-to-End Fixture (verification) | M | T-056, T-057, T-058 | MEDIUM |

## Group effort estimate

- Optimistic (1 iOS dev + 1 ML engineer, T-052/T-053 in parallel, design track ahead of implementation): 22–34 days
- Realistic (privacy review round-trips and the T-053 determination landing mid-stream, T-058 held by the T-038 harness): 28–45 days
- Entry gate: none hard — T-052 and T-053 can start immediately, and T-054 waits on both. T-056 waits on T-053's determination, not on TG-08; T-058 waits on the T-038 harness ([T-038](../TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md)) being wired.
- The group never extends the critical path of TG-08: the loop adds no task to `T-033 → T-034 → T-035 → T-036 → T-037 → T-038`, and T-058 consumes the harness as it exists rather than re-opening it. The design and privacy halves run on their own track while TG-08 executes.
