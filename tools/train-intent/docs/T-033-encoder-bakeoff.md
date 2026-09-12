# T-033 — Encoder Bake-Off + Export Feasibility (GO/NO-GO)

Task: `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-033-encoder-bake-off-export-feasibility.md`
Branch: `worktree-t033-encoder-bakeoff` (based on master `5513323`)
Status: **IN PROGRESS — pre-registration committed before any measurement result.**

The spike decides whether a local Nepali intent encoder is feasible at all.
Candidates from `docs/architecture/nepali-intent-recognition-model.md` are treated
as hypotheses. Every claim in that document (parameter counts, accuracy figures,
licence statements, Nepali strength) is an input to verify, never a fact to reuse.
The proposal's published figures (82.34% MASSIVE MiniLM, 91.1% SetFit, 97.3%
NyayaBench English) are explicitly **not** evidence of Nepali performance and are
never cited as such below.

## Candidates under test

| # | Candidate | Family | Why tested |
|---|---|---|---|
| C1 | `ai4bharat/IndicBERT-v3-270M` | bidirectional Gemma-3 270M | proposal's #1 base model |
| C2 | `jhu-clsp/mmBERT-small` | ModernBERT (RoPE, GLU, FA2) | proposal's production-student candidate |
| C3 | `cartesinus/multilingual_minilm-amazon-massive-intent` | XLM-R MiniLM (MASSIVE-fine-tuned) | proposal's teacher/baseline |
| C4 | SetFit variant: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` + linear head | sentence embedding | proposal's SetFit option |

## Pre-registered kill criteria (committed BEFORE any measurement result)

Ordering proof: this section was committed before the size, fertility, export and
golden-corpus result sections that follow in later commits. These numbers are not
adjusted after results are known; any later change requires a new section stating
that the criterion was changed and why (there are none at the time of writing).

### K1 — Licence clarity (hard)
A candidate is **NOT USABLE** for base selection unless all of:
1. its weights are obtainable by the project without reliance on a third party's
   granted access to a gated repository;
2. the repository declares an explicit licence granting redistribution of model
   weights (LICENSE file or equivalent explicit statement) that is compatible with
   shipping a commercial closed-source mobile app binary;
3. no upstream licence from the base model conflicts (e.g. Gemma Terms of Use on a
   "MIT-labelled" Gemma derivative → NOT USABLE).

A gated Hugging Face repository (contact-sharing / auto-approval gate) whose only
licence signal is a model-card metadata tag is **not sufficient evidence** of a
distributable licence → NOT USABLE. Every candidate record must carry licence
name, source URL, access conditions, date checked and revision SHA. Unverifiable
⇒ NOT USABLE, excluded from base selection.

### K2 — Tokenizer fertility ceiling (hard)
For every register — `devanagari`, `romanized`, `code_switched`,
`elder_fragmented`, `stt_noised` (the bundled-Whisper round-trip transcripts) —
tokens-per-word **mean ≤ 3.0 and p95 ≤ 6.0**. A candidate exceeding the ceiling on
any register is killed: the tokenizer cost makes the §10 latency budget
unattainable. No latency claim may appear in this report without this table.

### K3 — Export success on both target runtimes (hard)
A candidate must convert for the runtime that would ship it on each platform:
- **iOS**: CoreML via `coremltools` → compiled `.mlmodelc` (compilable by
  `xcrun coremlcompiler`), packaged as the zip-of-`.mlmodelc` that
  `ModelStore.installCoreMLEncoder(fromZip:for:)` already accepts
  (`ios/ElderlyAssistant/Services/ModelStore/ModelStore.swift`);
- **Android**: ONNX (int8) artefact that loads and infers in onnxruntime (the
  engine under ONNX Runtime Mobile), with outputs numerically consistent with
  PyTorch within tolerance.
Failure on either platform (conversion error, unsupported op, broken quantized
graph, inference mismatch) is a NO-GO for that candidate, recorded, never
silently dropped. **ModernBERT-family export (RoPE, GLU, Flash Attention 2) is
unproven and must not be assumed** — C2 is exactly that family.

### K4 — Size cap (hard)
Projected int8 size of the encoder body that would actually ship ≤ **200 MB**
(the spec's 50–150M-parameter target corresponds to ~50–150 MB int8; the cap
allows modest overhead while keeping the "small model" intent). Size composition
is measured from the real checkpoints: total params, non-embedding params, vocab
size, embedding-table share of int8 size, projected int8 body size.

### K5 — Interpret latency (hard, proxy-verified)
Spec §10 budget: on the oldest supported device class (iPhone 12-class / iOS 16),
interpret p50 ≤ **1.0 s** / p95 ≤ **2.0 s**. No device hardware is available to
this spike, so the device-class number is recorded as **UNMEASURED** (reason:
no iPhone/Android device in the test environment) — never fabricated. Closest
defensible proxies are timed in its place: CoreML prediction on the dev Mac
(x86_64 CPU) and onnxruntime CPU inference. Proxy kill: proxy p50 > 1.0 s or
proxy p95 > 2.0 s ⇒ NO-GO. Proxy within budget ⇒ GO **conditional**, with
device-in-loop verification explicitly deferred to T-038 and named as an open
verification step, not a claimed measurement.

### K6 — Golden-corpus accuracy floor (hard)
Using `tools/train-intent/src/eval_golden.py` and
`tools/train-intent/eval/golden_corpus.jsonl` exactly as pinned in this branch:
median-free, single-run, seed 42 —
- **closed-intent accuracy ≥ 0.80** on the 20-row corpus (17 closed rows); and
- **emergency recall = 1.00** (3/3 emergency rows).

This is a *base-selection floor* for the spike, not a waiver of any §10 ship
gate. §10 gates (`closed_intent_accuracy ≥ 0.95`, `slot_f1 ≥ 0.90`,
`emergency_recall = 1.00`, `side_effect_precision ≥ 0.97`) remain in force for
the model that T-035/T-036 eventually build, and are checked by T-038. The floor
is set below the ship gate because (a) the corpus has 20 rows — a stated
statistical limitation; (b) this spike trains on the existing LLM-format dataset
(`data/train.jsonl`), not the register-designed T-034 dataset; the floor tests
whether a candidate carries transferable Nepali intent signal at all.

Recorded but **not** spike kill criteria, stated now so the choice is not a
post-hoc adjustment: slot F1 (contact/time) and side-effect precision are design
inputs for T-035/T-036 (slot-head design belongs to T-035; only ~65% of slot
labels are verbatim-alignable in the current data — contact 1374/2088, time
449/709 — so low slot F1 here is expected and is not a base-model verdict).
Δ vs `GeminiCommandInterpreter` (gate: within −3 pts) is **UNMEASURED** in this
spike (no `GEMINI_API_KEY` in the experiment environment); T-038 owns enforcement
(plan risk 13).

### K7 — Reproducibility (hard)
Fixed seed 42; every training/eval run recorded with exact command line, dataset
SHA-256, config SHA-256 and checkpoint digest. Eval rows are appended to the
spike's own `eval/results.csv` — never the live `parent-assistant` file, which is
in active use by a concurrent training session on the same box. No PII (NFR-016):
seeds, synthetic teacher rows and the held-out golden corpus only.

## Measurement plan (fixed before results)

1. Licence/access probe per candidate against the HF API (gated flag, licence
   metadata, revision SHA, date checked) + attempt to fetch `config.json` with the
   project's stored token; model-card inspection for licence statements and base
   model conflicts.
2. Size composition from the real checkpoint files (safetensors/bin tensors):
   exact parameter counts, vocab size, embedding share, projected int8.
3. Tokenizer fertility per register per candidate on held-out sample rows
   (~200/register) from the pinned dataset snapshot, including the bundled-Whisper
   round-trip transcripts (`data/noised.jsonl`, `source: stt_noise`).
4. Encoder fine-tune (joint intent head + BIO slot head) per surviving candidate
   on `data/train.jsonl` (snapshot, hash recorded), 3 epochs, seed 42.
5. Golden-corpus eval via the harness encoder backend; rows appended to the spike
   `eval/results.csv` with command line, config hash, dataset hash.
6. Export spike per candidate: ONNX (int8) + onnxruntime latency proxy on the
   3090 box; CoreML conversion + compile + latency proxy on the dev Mac.
7. GO/NO-GO with exactly one named base model, tokenizer, runtime per platform and
   the student size target — or a per-candidate kill table. The GO is a
   recommendation to the lead engineer; **the lead-engineer sign-off is an
   explicit open step and is not claimed by this report** (DoD requirement before
   T-034/T-035/T-036 start).

The Ubuntu box's GPU was provably 100% occupied by a concurrent, unrelated
distillation run (pid 4022935) at the start of this spike; all CPU-only phases
ran first and the GPU phase was queued behind it. Contention is documented in the
results section with timestamps.
