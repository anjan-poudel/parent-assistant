# Making Sahayak self-learning — research summary

Date: 2026-09-15. Companion to the TG-10 design
(`docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md`).
This document summarizes how the app can learn from BOTH its mistakes and its
correct intent processing, what exists today, what is designed but unbuilt,
and a phased path.

## How the app already captures learning signal — the "flywheel"

Sahayak already records its own report card, manually. Every voice command that
reaches the confirmation tier can end in one of four outcomes, and
`ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift` (encrypted,
on-device, capped at 500 records) stores them with the action, slots, and —
when the user corrects it — what the correction was (`correctedTo`).

Concretely: the elder says "भोलि डाक्टरलाई फोन गर" and the brain mishears the
intent as `send_message`. The confirmation asks "send a message?" — the elder
says no, and the correction path writes `outcome: corrected, correctedTo: call`.
**That record is a training example** — a (transcript → correct action) pair the
app got wrong. Similarly, every confirmed action is a positive example.

Gaps found by research: only two append sites exist today (call corrections +
confirmed calls — `AppCoordinator.swift` ~5402 and ~5540), `denied`/`timeout`
are declared but never written, `latencyMs` is never populated, and there is no
confidence field. The flywheel exists, but only a sliver of signal is captured.

## The loop as designed — TG-10

Five stages from the TG-10 design doc, with four pre-made decisions:

1. **CAPTURE** — opt-in recording of corrections/confirmations with
   hashed-only content. D-1: the household must explicitly turn it on
   (revocable; opt-out deletes un-egressed data). D-2: only hashes — never
   transcripts or names — leave the device.
2. **MINE** — a weekly (D-3) job turns raw records into labelled training
   rows: a correction becomes a (transcript, corrected action) pair;
   near-misses get mined too.
3. **AUGMENT** — those rows enter the EXISTING training authoring chain:
   `tools/train-intent/src/gen_teacher.py` rephrases them →
   `stt_noise.py` adds speech-noise variants → leak guards + dedup — the
   exact pipeline that produced the v3 topup (2026-09-14).
4. **RETRAIN** — the candidate must pass the 8 absolute eval gates
   (`tools/train-intent/src/eval_golden.py`) on the held-out 8,000-row
   golden corpus.
5. **SHADOW/HEAL** — the candidate must BEAT THE INCUMBENT on the golden set
   (promotion gate), runs in shadow after promotion, and heals back to the
   previous brain if live error regresses. A human approves publication
   (D-4). Delivery uses the same pinned-catalog path as the v16 download
   (`Services/ModelStore/ModelCatalog.swift` + GitHub releases).

## What "learning from mistakes" looks like day-to-day, once built

- Week 1: the elder corrects "send message" → "call" twice; confirms 40 commands.
- Sunday night: the miner turns those into ~300 augmented rows (rephrases +
  noise variants).
- The training pipeline retrains a candidate; the golden gates verify no
  regression.
- The candidate is shadow-scored against the incumbent on live traffic
  (hashed transcripts only); if it wins, the family gets a "new brain ready"
  notice and it publishes after approval.
- The elder's next weekly retrain starts from a better brain.

## Risks

1. **Privacy is the make-or-break**: this is the app's first content-adjacent
   egress channel. The design's answer is hashed-only + opt-in + revocable —
   but slot values (names, meds) must never ride along, not even salted
   hashes of low-entropy names.
2. **Signal sparsity**: corrections are rare (elders mostly accept), and the
   500-cap trims old signal. Teacher rephrasing mitigates, but "is a
   correction really a label?" is a research question in itself (T-052).
3. **Self-distillation collapse**: training on the brain's own confirmations
   is a feedback loop that can amplify its biases. Mitigations: the golden
   corpus is never a training input, beat-the-incumbent, shadow scoring, the
   human publish gate. The design should name collapse explicitly (R-7 is
   closest today).

## Status table

| Piece | Status |
|---|---|
| Flywheel log (corrections/confirmations) | Built, under-used (2 append sites) |
| On-device cache learning (`IntentCommandCache`, `ConfirmedMethodHistoryStore`) | Built |
| Training topup pipeline + eval gates | Built (used for the v3 topup) |
| Brain delivery + pinned catalog (multipart v16) | Built |
| Opt-in capture + hashed egress | Designed — T-054/T-056 |
| Correction miner | Designed — T-057 |
| Promotion gate + shadow/heal | Designed — T-058 |

## Recommended first steps

1. **Cheap precursor (inside T-054/T-056):** widen the two append sites to
   all confirm-tier actions, write denied/timeout, add a confidence field —
   every later stage consumes exactly this signal.
2. **Phase 0:** T-052 (signal-quality feasibility) + T-053 (privacy review)
   in parallel — nothing is built until both answer.
3. **Phase 1:** T-054 capture schema + egress contract, T-055 shadow/healing
   protocol.
4. **Phase 2:** T-056 opt-in capture/egress, T-057 miner feeding the existing
   topup chain.
5. **Phase 3:** T-058 promotion gate, T-059 privacy audit, T-060 end-to-end
   fixture.
6. **Landing:** publish artifact → GitHub release → re-pin the catalog → app
   release.

Effort: 22–34 days optimistic, 28–45 realistic (TG-10 group estimate).
