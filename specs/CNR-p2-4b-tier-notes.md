# T-190 — owner-descope record (2026-10-15)

**Status: DESCoped by the owner — not implemented in this run.** This record exists because
plan risk 10 requires descoping to never be silent: the leg completes with an explicit
owner-descope record instead of an artifact.

**Decision.** Owner decision of 2026-10-15 (relayed via the main session): P2 conversation
polish is separated from the CNR run as its own initiative — home
`docs/features/2026-10-15-p2-conversation-polish-initiative.md` (main checkout). The four P2
legs — T-188 (DPO on judge preferences), T-189 (romanized Nepali chat), T-190 (this leg: the
4B tier candidate and its admission verdict, FR-CNR-028), T-191 (consent-based real
transcripts) — are descoped from this run.

**Umbrella record.** `specs/plan-tasks/amendments/amendment-6-p2-descoped-2026-10-15.md`.

**Declared files.** Not produced by this run. This file (`specs/CNR-p2-4b-tier-notes.md`)
exists only as this descope record.

**Accounting (T-192).** T-192 (feasibility honesty statement) stays in this run and reports
this leg as owner-descoped, citing this record — no measured outcome is claimed here; the
leg's feasibility evidence (including the 4B-tier jetsam/latency admission question, plan
risk 6) is owned by the successor initiative.

---

# T-190 — RE-OPENED by owner (2026-10-17) — executing

**Status: RE-OPENED and executing — the owner wants the 4B chat variant for the iPhone 17
Pro Max.** Owner decision 2026-10-17, relayed via the main session and recorded with owner
provenance (a relayed owner-level decision, not an in-session agent approval). Umbrella
record: `specs/plan-tasks/amendments/amendment-7-t190-4b-reopened-2026-10-17.md`. The descope
record above is retained verbatim (descoping must never be silent — nor un-descoping); this
section supersedes it for T-190 only. T-188/T-189/T-191 remain descoped.

## Execution record at launch

**Base (recorded with rationale — "record the exact configuration used", T-190 impl notes).**
`checkpoints/qwen4b-s43-merged` (parent training tree,
`/mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent/`) — the 4B seed-43 lineage
merged checkpoint: the structural mirror of `qwen-s43-merged`, the local shipped-brain
checkpoint the 1.7B v17 run trained on. The 4B side has the same shape (the slim seed-43
line; v15's export) and the app's 4B entries descend from this lineage (`intentQwen4BS43`,
then the slot-canon seed-42 default built on the same rebuilt-corpus retrain batch).
Recorded alternative, not taken: `qwen4b-slotcanon-s43-merged` (slot-canonical seed 43; its
k=3 sweep passed all five gates, per `eval/krun_state_qwen4b-slotcanon.json`) — not chosen
because it is a lineage deviation from the 1.7B comparison the T-190 spec binds ("same data,
same recipe, bigger base"; "any recipe or mixture deviation makes the comparison
meaningless"). The v17 corpus's L4 claw-back (30% of the ship mix; intent data —
`data/teacher.jsonl`, `noised.jsonl`, `edge_cases.jsonl`) is what re-teaches intent/slot
behaviour during chat training; evidence this works on a slim seed-43 base exists: the 1.7B
v17 run passed its scoped hard gates from the same corpus over `qwen-s43-merged`.

**Corpus.** Unchanged v17 corpus: `data/train-v17.jsonl` (17,235 rows) + `data/valid-v17.jsonl`
(500 rows) — line counts verified on disk at launch.

**Recipe.** Unchanged pinned recipe — the identical trainer invocation to the 1.7B chain
minus the base: `v17-trainer/train_chat_lora.py --base qwen4b`, trainer defaults r=16 /
alpha=32 / lr 1.5e-4 / 3 epochs / seq 1024 / bs 4 × ga 4. The trainer's own launch line
printed the step count: **~3,234 steps** (same as the 1.7B run's). In-run floor guard
DISABLED per the ratified restart-#2 discipline (`--floor-step 0`; the 0.90 floors are
recorded): no mid-run veto — readings are recorded as evidence at the end-of-run probe.
`--save-steps 40`, `--save-total-limit 30`. The trainer's resume path is broken (recorded
2026-10-16): an abort costs a fresh restart with preserved checkpoints.

**Launch.** 2026-10-17T04:37 box-local, box-side detached (`nohup setsid`), chain
`/mnt/nvme1/cnr-v17/chain-train-4b.sh`, run id **cnr-v17-4b-20261017-0437**, log
`/mnt/nvme1/cnr-v17/logs/train-cnr-v17-4b.log`. Chain stages: train → end-of-run probe
(`end_probe_final.py` — readings recorded, value whatever it is) → Q4_K_M export
(`src/export_gguf.py --tag qwen4b-s43-chat-v17 --base-id <base>`; CPU-only by design) →
sha256. Executed in parallel with the in-flight v17 full-gate decode: the GPU was verified
idle before launch (0 compute processes; CUDA smoke green) and the decode is CPU-bound
(gate pid 85884, all cores) — zero GPU conflict. Measured after launch: GPU 100% util /
~13.9 GB / 83 °C, ~10 s/it early → **ETA ~9-10 h** (dispatch estimate; 1.7B empirical anchor:
0.186 steps/s for the same 3,234 steps in 4.82 h; 4B compute ≈ 2×). A bounded caffeinated
Mac-side waiter watches the chain-done marker and reports with the probe JSON, artifact
sha256, and GPU state.

## Outstanding (T-190's own definition of done — none of these is claimed yet)

- Full-harness report over the candidate's own artifact identity (its own `--full-gates` run
  + judge leg) — box stages after the export.
- Catalog entry — prepared, lands when the real sha256/size exist
  (`intent-ne-qwen4b-s43-chat-v17-q4_k_m.gguf`; non-default; resolver-only; promotion record
  shipped blocked until the report lands, mirroring the v17 entry's pattern).
- Tier admission measurement (memory + latency, the 1.7B method named) — device-side on the
  iPhone 17 Pro Max after training; the design's recorded expectation (LIKELY NOT ADMISSIBLE
  on the reference 6 GB tier) is confirmed or overturned by that measurement only.
- The explicit verdict notes (confirming or overturning), written with the measurements.

The candidate is never a default on any tier and no tier selects it before admission.
