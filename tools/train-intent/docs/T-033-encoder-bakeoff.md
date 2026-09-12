# T-033 — Encoder Bake-Off + Export Feasibility (GO/NO-GO)

Task: `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-033-encoder-bake-off-export-feasibility.md`
Branch: `worktree-t033-encoder-bakeoff` (based on master `5513323`)
Status: **COMPLETE — results below; GO/NO-GO in §8. Lead-engineer sign-off is an
explicit open step and is not claimed by this report.**

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

---

# RESULTS

## 0. Process and pinned inputs

- Pre-registration commit: `5bd5eb2` (report-only, before any measurement).
- Experiment host: `anjan-ubuntu` (RTX 3090 24 GB), spike dir
  `/mnt/nvme2/workspace/projects/rnd/t033-encoder-bakeoff/` — a dedicated
  directory so the concurrent `parent-assistant` session's state could not be
  touched. Its data files were **snapshotted** (mtime + SHA-256) before use
  because that session was actively rebuilding them:

  | File | SHA-256 (snapshot) | Rows |
  |---|---|---|
  | `data/train_snapshot.jsonl` | `7f42816aceaaaff6419c898a944329dfa8b10230d4d75de5ab999fb941aa9e7f` | 4307 |
  | `data/valid_snapshot.jsonl` | `d71868c533a9b949dd59c7bd37a54115e68150c437049c9bf740a9b5c524d197` | 226 |
  | `data/noised_snapshot.jsonl` (bundled-Whisper round-trip) | `cff510f31b8f2edfa83dba34efa6f14c86cc36cd490cf1e62620fd2f3ad13414` | 29304 |

- Pinned harness/corpus copied from **this branch** (source of truth), not the
  server copies: `config.yaml` `2d3bc790c3c815e204548edd5f8f23db3d9b53dc0424a7417d8034d75ca6597d`,
  `eval/golden_corpus.jsonl` `1f4c059cd9b10fe43d76ccadbe72edfa26144c8336f91a201148a227e0a06355`
  (20 rows), `seeds/prompt_template.txt` `df141760089c50b62e894aa0e1c0a72cc40c11e9c4361c3028d9a47f1936ee11`.
- Environment: Python 3.12.3, transformers 4.56.2, onnx/onnxruntime 1.22/1.30,
  seed 42, CPU-only (torch 2.5.1+cu121 for the early phases; **bumped to
  2.6.0+cu124** in the spike venv after the CVE-2025-32434 guard refused
  `torch.load` of mmBERT-small's `.bin` checkpoint — recorded because it changes
  the environment the last three phases ran in). `HF_HUB_DISABLE_XET=1` is
  required on this host (the xet download path hangs); recorded so runs are
  reproducible.
- Export host (CoreML): the dev Mac, x86_64, coremltools 9, transformers 4.56.2,
  torch 2.2.2 (last macOS-x86_64 release), `xcrun coremlcompiler`; per-run
  workarounds recorded in §6. The Mac's disk was ~99 % full, which cost one
  conversion attempt (ENOSPC inside the MIL→BNNS compile, re-run lean).
- Evidence directory `docs/t033-evidence/`: `licence_probe.json` (§1),
  `size_composition.json` (§2), `fertility.json` (§3), `results.csv` +
  `results_manifest.jsonl` (§4), `C2-onnx-report.json` / `C3-onnx-report.json`
  (§5), `C2-coreml-report.json` / `C3-coreml-report.json` (§6).
- GPU contention (observed via `nvidia-smi`, do-not-interrupt policy honoured):
  - 06:58 — pid 4022935 (distillation arm A) 20 230 MiB, 100 % util, 90 % of
    its epoch; log still being written.
  - 07:04 — arm A printed `[train] done`; GPU freed for ~3 min.
  - 07:07 — `phase2_chain.sh` launched arm B (`qwen-student-schema`, pid
    4047698): 405 steps at ~12 s/it ≈ 81 min. GPU contested again.
  - All CPU-only phases (licence, size, fertility, harness validation,
    conversion tooling) ran during both windows; GPU fine-tuning was queued
    behind arm B per the task's non-interference rule.

## 1. Licence and access evidence (K1)

Probe command (server, 2026-09-13 ~07:10 UTC):
`python3 scripts/bakeoff_candidates.py --out licence_probe.json`
(reads the project's stored HF token; the token is never printed).
Each access check is a 1-byte Range request on the revision-pinned resolve URL.

| # | Candidate | Gated? | Licence evidence | Weights fetch (project token) | Licence file | Revision SHA | Verdict |
|---|---|---|---|---|---|---|---|
| C1 | `ai4bharat/IndicBERT-v3-270M` | **gated = auto** (contact-sharing/terms gate) | model-card metadata tag `license: mit` only; base model `google/gemma-3-270m-it` (Gemma Terms apply upstream) | `config.json` **403**, weights **403** | none in repo | `0fc678697635496683188faeb582dcd741416da4` | **NOT USABLE** |
| C2 | `jhu-clsp/mmBERT-small` | no | model card front-matter `license: mit` + MIT badge + `license="mit"` in the card's model-index | `config.json` 206, `pytorch_model.bin` 206 | none (card statement) | `abc32620dd4f6ab06f5fbe905dc25f310618e09f` | USABLE |
| C3 | `cartesinus/multilingual_minilm-amazon-massive-intent` | no | model card front-matter `license: mit`; derived from `microsoft/Multilingual-MiniLM-L12-H384` (MIT) fine-tuned on MASSIVE (CC-BY-4.0 dataset — dataset terms, not weight terms) | `config.json` 206, `model.safetensors` 206 | none (card statement) | `08dc481605729de194f9139713d4eb20f4b80706` | USABLE |
| C4 | `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (SetFit base proposed by this spike) | no | model card `license: apache-2.0` | `config.json` 206, `model.safetensors` 206 | none (card statement) | `e8f8c211226b894fcb81acc59f3b34ba3efd5f42` | USABLE (as SetFit base; see arch. exclusion below) |

C1 verdict detail — exactly the situation the task called out: a **gated**
repository whose only licence signal is an **indirect MIT indication** is not
sufficient evidence; the project's token is refused on the weights (403), and
the upstream Gemma-3 base adds terms that conflict with a closed-source App
Store binary. C1 is excluded from base selection and from all further
measurement (no training on an unverified base).

## 2. Size composition, measured (K4)

Command (server): `python scripts/bakeoff_size.py --repos C2,C3,C4 --out size_composition.json`
Parameter counts read from tensor shapes only (safetensors `safe_open` /
`torch.load(mmap=True)`); projected int8 = 1 byte/parameter, the same 1-byte
projection the spec uses (50M params ≈ 50 MB int8).

| # | Total params | Encoder body (ships) | Training heads (do not ship) | Vocab | Body embedding share of int8 | Projected int8 encoder body | Checkpoint file |
|---|---|---|---|---|---|---|---|
| C1 | UNMEASURED — access denied (403), excluded | | | | | | |
| C2 mmBERT-small | 239.2 M | **140.5 M** | 98.7 M (`decoder.*`, `head.*`) | 256 000 | 70.0 % | **140.5 MB → passes K4 (≤ 200 MB)** | 563.6 MB `pytorch_model.bin` |
| C3 MASSIVE MiniLM | 117.7 M | 117.5 M | 0.2 M (`bert.pooler`, `classifier`) | 250 037 | 81.7 % | 117.5 MB | 470.7 MB `model.safetensors` |
| C4 SetFit base MiniLM | 117.7 M | 117.5 M | 0.15 M (`pooler`) | 250 037 | 81.7 % | 117.5 MB | 470.6 MB `model.safetensors` |

**Correction, recorded before any accuracy result was used.** The first pass of
this table counted *every* tensor in the checkpoint as the encoder body. That is
wrong for any checkpoint that still carries its training heads: mmBERT-small
stores its tied MLM decoder (`decoder.weight`, 98.3 M params — a second 256 k ×
384 matrix sharing storage with the embedding table) and `head.{dense,norm}`,
none of which ship. The script now classifies tensors by prefix and reports the
encoder body separately (`docs/t033-evidence/size_composition.json`). The K4
criterion text is unchanged — "projected int8 size of the encoder body that
would actually ship" — so this is a measurement fix, not a criterion change.
Cross-check: the body computed from tensor shapes (140.5 M) equals
`sum(p.numel())` of the instantiated `AutoModel` for mmBERT-small exactly, which
is the ground truth for what runs on device.

Honesty note against the proposal doc: its "≈140M" for mmBERT-small is exactly
right for the encoder body (the doc's number survived; this spike's first
measurement did not). The doc's "≈100M" for the MASSIVE MiniLM checkpoint is
close to the measured 117.5 M body. C1 stays unmeasurable (403 on weights).

Verdicts: **C2 K4 PASS (140.5 MB), C3/C4 K4 PASS (117.5 MB)**, C1 unmeasurable.
C2's fate is decided by export/quantization (§5), not size.

## 3. Tokenizer fertility per register (K2)

Command (server): `python scripts/bakeoff_fertility.py --clean data/train_snapshot.jsonl data/valid_snapshot.jsonl --noised data/noised_snapshot.jsonl --repos C2,C3,C4 --samples 200 --seed 42 --out fertility.json`
Rows sampled once with seed 42 (200/register), identical across tokenizers.
"stt_noised" is pooled from `data/noised_snapshot.jsonl` (the bundled-Whisper
round-trip, `source: stt_noise`), 200 per sub-register = 800 rows.
Pre-registered ceiling: mean ≤ 3.0 and p95 ≤ 6.0 tokens/word in every register.

tokens-per-word (mean / p95):

| Register | n | C2 mmBERT-small (256 k, Gemma-3 tokenizer) | C3 MASSIVE MiniLM (250 k, XLM-R SPM) | C4 SetFit base (250 k, XLM-R SPM) |
|---|---|---|---|---|
| devanagari | 200 | 2.737 / 3.833 | 1.784 / 2.667 | 1.784 / 2.667 |
| romanized | 200 | 2.021 / 3.000 | 1.848 / 2.667 | 1.848 / 2.667 |
| code_switched | 200 | 2.180 / 3.200 | 1.665 / 2.429 | 1.665 / 2.429 |
| elder_fragmented | 200 | 2.639 / 4.000 | 1.907 / 2.800 | 1.907 / 2.800 |
| **stt_noised (all)** | 800 | **2.925 / 4.000** | **2.180 / 3.333** | **2.180 / 3.333** |
| stt_noised:devanagari | 200 | 2.977 / 4.200 | 2.251 / 3.400 | 2.251 / 3.400 |
| stt_noised:romanized | 200 | 2.916 / 4.000 | 2.147 / 3.250 | 2.147 / 3.250 |
| stt_noised:code_switched | 200 | 2.872 / 4.000 | 2.106 / 3.200 | 2.106 / 3.200 |
| stt_noised:elder_fragmented | 200 | 2.933 / 4.000 | 2.216 / 3.333 | 2.216 / 3.333 |

All three measured tokenizers pass K2 (C1 unmeasurable). C3/C4's XLM-R
sentencepiece is materially more efficient on Nepali than C2's Gemma-3-derived
256 k tokenizer on every register, and notably on the STT-noised transcripts
(mean 2.18 vs 2.93). Utterances are short in all cases
(p95 ≈ 14 tokens for C2, ≈ 10 for C3/C4), so the latency question is dominated
by the encoder size, not sequence length. Note the proposal doc's claim that
both leading candidates use ~256 K Gemma-family vocabularies is true only for
C2; C3/C4 use XLM-R's 250 k sentencepiece (and their tokenizer is identical,
as C4's base is the same XLM-R MiniLM family).

**No latency claim in this report appears without this table** (K2's rule).

## 4. Encoder fine-tune and golden-corpus eval (K6, K7)

Joint recipe (identical for both survivors, spike code `bakeoff_finetune.py`, seed
42, CPU): shared encoder + intent head (CLS) + 5-tag BIO slot head, 3 epochs,
batch 32, AdamW + OneCycleLR. Slot loss is masked for rows whose non-null slot
strings do not align verbatim to the utterance (77.4 % of rows supervise slots;
see the K6 note — this is a dataset property, not a model property).

| # | Exact command (server spike dir) | Train rows | Best valid intent acc | Wall clock | Checkpoint SHA-256 |
|---|---|---|---|---|---|
| C2 | `scripts/bakeoff_finetune.py --repo jhu-clsp/mmBERT-small --train data/train_snapshot.jsonl --valid data/valid_snapshot.jsonl --out-dir models/C2-mmbert-small --epochs 3 --batch-size 32 --device cpu` | 4307 | **0.987** (epoch 2) | 406 s | `86f2cf2ee1e87ed73e13aa5caba0b63a72414c652758f66428d54bb0cf43fd68` |
| C3 | `scripts/bakeoff_finetune.py --repo cartesinus/multilingual_minilm-amazon-massive-intent ... --out-dir models/C3-cartesinus-minilm ...` | 4307 | **0.929** (epoch 3) | 277 s | `dc55e75c080f44151406516b09bccdbe34b3941c4c97d14705e8cf74336e47b1` |

Dataset / valid / config hashes are the pinned ones from §0
(`7f42816a…`, `d71868c5…`, `2d3bc790…`), recorded in each run's `manifest.json`.

Golden-corpus rows, scored by the harness (`eval_golden.py`; corpus
`1f4c059c…`, config `2d3bc790…`), all appended to the **spike-local**
`eval/results.csv` (schema unchanged) with a companion
`eval/results_manifest.jsonl` carrying command, hashes and metrics:

| Run label | closed intent | contact F1 | time F1 | emergency recall | side-effect precision | §10 gates failed |
|---|---|---|---|---|---|---|
| `T033-C3-minilm-s42` (torch fp32) | 0.882 | 0.333 | 1.000 | 1.000 | 1.000 | closed, contact |
| `T033-C3-minilm-int8-onnx-s42` (**Android artifact**) | 0.882 | 0.333 | 1.000 | **1.000** | 1.000 | closed, contact |
| `T033-C2-mmbert-s42` (torch fp32) | **1.000** | 0.333 | 0.833 | **1.000** | 1.000 | contact, time |
| `T033-C2-mmbert-int8-onnx-s42` (**Android artifact**) | 0.824 | 0.333 | 0.727 | **0.000** | 1.000 | closed, contact, time, **emergency** |

Reading of the numbers:

- On the 20-row corpus C2's fp32 checkpoint is the accuracy leader (17/17 closed
  intents, 3/3 emergency); C3's fp32 checkpoint passes the K6 floor
  (0.882 ≥ 0.80, emergency 3/3). The corpus size is the stated statistical
  limitation; the direction agrees with the 226-row valid split (0.987 vs 0.929).
- **C3's int8 ONNX reproduces its fp32 metrics exactly** (per-row predictions are
  identical): its quantization is decision-preserving.
- **C2's int8 ONNX does not**: all three emergency utterances are predicted
  `ack_med` at 0.52–0.65 confidence (a confident wrong answer, not a
  low-confidence hedge), and closed-intent accuracy drops 1.000 → 0.824.
- Slot F1 (contact 0.333) is low for both and was pre-registered as a
  slot-head/dataset design input for T-035, not a base-model verdict. No §10
  ship gate is met by either fp32 checkpoint on this corpus; that was the
  pre-registered expectation for a spike training on the LLM-format dataset
  (K6 floor, not gate).

## 5. Android export spike — ONNX int8 + onnxruntime (K3, K5)

`bakeoff_export_onnx.py`: `torch.onnx.export` opset 17, dynamic sequence axis →
`quantize_dynamic(QInt8)` → verification of *both* graphs against PyTorch on the
golden corpus → ORT latency (1 and 4 intra-op threads).

| # | fp32 export | int8 size | Verification vs PyTorch (fp32 / int8) | ORT latency p50 (1 / 4 threads) | K3 |
|---|---|---|---|---|---|
| C2 | 562.5 MB, 3.5 s | 141.4 MB | intent 1.000 / **0.850**; slot tags 1.000 / 0.977 | 6.70 ms / 3.95 ms (p95 10.2 / 5.4) | **FAIL** |
| C3 | 470.3 MB, 4.3 s | 118.1 MB | intent 1.000 / 1.000; slot tags 1.000 / 0.978 | 4.65 ms / 3.25 ms (p95 19.5 / 12.4) | PASS |
| C1 | not attempted (K1) | | | | n/a |
| C4 | not attempted (architectural exclusion, §7) | | | | n/a |

- **The pre-registered ModernBERT-export warning did not hold where expected,
  and held where it was not expected.** `torch.onnx.export` converted
  mmBERT-small (RoPE, GLU, alternating local/global attention) without any
  fallback — output agreement with PyTorch fp32 is 1.000/1.000. The failure is
  in *dynamic int8 weight quantization of the GLU/RoPE stack*, not in
  conversion. C2 is therefore recorded as **K3 NO-GO on Android as tested**:
  the artifact class this platform would ship loses the emergency gate
  (harness-scored emergency recall 0.000). Recorded, not dropped.
- C3's int8 artifact is 118.1 MB (SHA-256 `28093b42…`) and is scored by the
  harness in §4 — identical to its fp32 source.
- ORT latency on the 3090 box's CPU is a **proxy** (desktop x86-64, ONNX Runtime
  CPU EP): 3–7 ms p50. The oldest supported device class runs ONNX Runtime
  Mobile on a phone-class CPU, which is not this machine; T-038 owns the
  device-in-loop number (K5).

## 6. iOS export spike — CoreML mlprogram (K3, K5)

`bakeoff_export_coreml.py` on the dev Mac (x86_64, coremltools 9, iOS 16 minimum
deployment target, flexible `RangeDim(1, 64)` sequence axis): `torch.jit.trace`
→ `ct.convert(convert_to="mlprogram", FLOAT16)` → `xcrun coremlcompiler compile`
→ zip of the single `<stem>-encoder.mlmodelc` (the exact shape
`ModelStore.installCoreMLEncoder(fromZip:for:)` accepts) → int8 weight
quantization (`OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")`)
→ verification of the int8 model against PyTorch → latency proxy.

| # | Trace | fp16 mlpackage | int8 mlpackage | int8 `.mlmodelc` | int8 zip (ModelStore shape) | Verification int8 vs PyTorch | CoreML latency proxy |
|---|---|---|---|---|---|---|---|
| C2 | ok (default attention) | 281.3 MB | 141.8 MB | 141.9 MB | **130.4 MB, shape matched** (`a19b4136…`) | intent 1.000, slot 1.000 | p50 39.3 ms, p95 49.2 ms (median of 3 passes; range 38.9–39.4) |
| C3 | ok (default attention) | 235.2 MB | 118.6 MB | 118.7 MB | **109.1 MB, shape matched** (`6056ba41…`) | intent 1.000, slot 1.000 | p50 20.5 ms and 178.6 ms in two single passes of the same int8 artifact (variance note below) |

- **Both candidates convert, compile, package and verify on iOS** — including
  ModernBERT. CoreML's weight-only linear int8 quantization preserves every
  prediction on the corpus for both models, which is *not* what ORT's dynamic
  activation-aware quantization did to C2 on Android. The platform split is a
  real, measured finding, not a modelling of one.
- Compiled `.mlmodelc` layout: `coremldata.bin`, `model.mil`, `weights/weight.bin`,
  `metadata.json`, `analytics/` — no `Manifest.json` on this toolchain. Loading
  the compiled artifact on real iOS is T-038's step; the spike verified the
  `.mlpackage` directly.
- Latency variance: the same C3 int8 artifact measured p50 20.5 ms and 178.6 ms
  in two single passes on this shared dev Mac (disk was 99 % full and the box
  was in other use). Repeated-pass C2 measurement was stable to ±0.5 ms, so the
  variance is host-side, not model-side. Both C3 figures are inside the K5 proxy
  budget by a wide margin, so the verdict does not turn on which is typical. The
  device-class number stays **UNMEASURED** (no phone hardware) and is T-038's.
- Export-host quirks worth recording for reproducibility: transformers refuses
  `torch.load` of `.bin` checkpoints on torch < 2.6 (CVE-2025-32434 guard) and
  torch 2.2.2 is the last macOS-x86_64 release, so the backbone was converted to
  safetensors on the server and pointed at with `T033_BACKBONE_OVERRIDE`;
  ModernBERT applies `@torch.compile` at import time, which torch 2.2.2 cannot
  run on py3.12, so `T033_PATCH_TORCH_COMPILE=1` installs an identity decorator
  for the export host only (a traced graph is what ships either way). One C2
  conversion attempt died on `No space left on device` inside the MIL→BNNS
  compile; it was re-run in a lean mode (`--skip-fp16-package`) once ~2 GB was
  free, and the failure is recorded here rather than hidden.

## 7. Kill-criteria matrix

| Criterion | C1 IndicBERT-v3-270M | C2 mmBERT-small | C3 MASSIVE MiniLM | C4 MiniLM + linear (SetFit) |
|---|---|---|---|---|
| K1 licence | **FAIL** — gated repo, weights 403, only an indirect MIT tag, Gemma-3 upstream terms | PASS (MIT) | PASS (MIT) | PASS (Apache-2.0) |
| K2 fertility (all 5 registers) | UNMEASURED (K1) | PASS (worst mean 2.98, p95 4.2) | PASS (worst mean 2.25, p95 3.4) | PASS (same tokenizer as C3) |
| K3 iOS (CoreML mlprogram → `.mlmodelc` zip) | not attempted (K1) | PASS | PASS | not attempted — see K1-line exclusion below |
| K3 Android (ONNX int8 + ORT) | not attempted (K1) | **FAIL** — int8 graph not decision-preserving (emergency recall 0.000) | PASS | not attempted |
| K4 int8 encoder body ≤ 200 MB | UNMEASURED (403) | PASS (140.5 MB) | PASS (117.5 MB) | PASS (117.5 MB) |
| K5 latency proxy (device class UNMEASURED) | n/a | PASS (39.3 ms CoreML / 3.95 ms ORT p50) | PASS (20.5–178.6 ms CoreML / 3.25 ms ORT p50) | n/a |
| K6 golden floor (≥ 0.80 closed, emergency = 1.00) | n/a | torch fp32 PASS; **shipping artifact FAIL** (emergency 0.000) | PASS (0.882 / 1.000) | n/a |
| K7 reproducibility | n/a | PASS | PASS | n/a |

C4 is excluded on architecture, recorded here so it is not silently dropped:
licence, size and fertility were measured (tables above), but a
sentence-embedding + linear head has no token-level BIO decoder, so it cannot
produce contact/time slot spans at all — the plan's risk 15. Export was
therefore not attempted for it; that is a scope exclusion, not a pass.

## 8. GO/NO-GO

**GO — an on-device Nepali intent encoder is feasible on both target platforms.**
One base model, one tokenizer, one runtime per platform, one size target:

| Decision | Named choice | Evidence |
|---|---|---|
| Base model | `cartesinus/multilingual_minilm-amazon-massive-intent` (XLM-R MiniLM, 12 layers, 384 hidden) | only candidate that passes K1–K7 as a *shippable artifact* on both platforms |
| Tokenizer | the XLM-R sentencepiece shipped with it — 250 037 vocab | most efficient on Nepali of the three measured, including STT-noised transcripts (mean 2.18 vs 2.93 tokens/word) |
| iOS runtime | **CoreML mlprogram**, delivered as a zip containing one `<stem>-encoder.mlmodelc` | already wired: `ModelStore.installCoreMLEncoder(fromZip:for:)` accepts exactly this shape; int8 package verifies 1.000/1.000 vs PyTorch |
| Android runtime | **ONNX Runtime Mobile**, int8 ONNX graph (opset 17) | C3's int8 graph is decision-preserving and harness-scores identically to fp32. **Not wired anywhere in this repo yet — Android packaging/loading is new code and belongs to T-037** |
| Student size target (T-035/T-036) | encoder body **100–120 M parameters** (measured C3 body 117.5 M) with the XLM-R 250 k tokenizer; int8 118.1 MB (ONNX) / 109.1 MB (CoreML zip) | K4 passes with ≥ 30 % headroom; sequence p95 ≤ 14 tokens on STT-noised text |

Kills, with the failing criterion:

- **C1 `ai4bharat/IndicBERT-v3-270M` — K1 NO-GO.** Gated weights (403 with the
  project token), no licence file, only an indirect MIT metadata tag, Gemma-3
  upstream terms. Unmeasurable thereafter by rule.
- **C2 `jhu-clsp/mmBERT-small` — K3 NO-GO on Android (and K6 for that artifact).**
  It is the accuracy leader in fp32 (valid 0.987, golden closed 1.000, emergency
  3/3), its iOS path is clean, and ModernBERT conversion — not assumed, tested —
  works on both toolchains. Its int8 ONNX graph, however, is not
  decision-preserving: emergency recall 0.000 from 1.000. Since a base whose
  platform artifact loses the hard gate cannot be the named base, it is recorded
  as killed **as tested**. If T-035/T-036 wants C2's accuracy, the recorded
  remediation path is a different Android quantization scheme (QDQ /
  per-channel, or fp16 ONNX) or QAT — none of which was tested here, so none of
  it counts as evidence yet.
- **C4 SetFit variant — architectural exclusion** (no BIO slot decoder; plan
  risk 15), plus its licence/size/fertility are recorded above.

Open steps, explicitly not claimed by this report:

1. **Lead-engineer sign-off on this GO** before T-034/T-035/T-036 start (DoD
   requirement).
2. **Device-class latency and on-device emergency behaviour** (T-038): the
   K5 numbers here are desktop proxies; the iPhone-12-class p50 ≤ 1.0 s /
   p95 ≤ 2.0 s figure remains UNMEASURED. Same for the compiled `.mlmodelc`
   loading through ModelStore on a real device.
3. **Δ vs `GeminiCommandInterpreter` (within −3 pts)**: UNMEASURED — no
   `GEMINI_API_KEY` in the experiment environment. T-038 owns it.
4. **§10 ship gates are not met by either fp32 checkpoint on this corpus** and
   were never expected to be: the spike trained on the existing LLM-format rows,
   not T-034's register-designed dataset, and slot labels align verbatim for
   only ~65 % of rows. T-035/T-036 must re-measure against the new dataset.
5. **C2 as a fallback base** if the C3-based student cannot reach §10
   closed-intent accuracy — conditional on a quantization-safe Android export,
   which is untested.

Process notes: no PII was used anywhere (NFR-016) — seeds, synthetic teacher
rows and the held-out golden corpus only; no secret or token appears in this
report or any committed artefact. The GPU contention policy was honoured
throughout: the concurrent session's chain held the 3090 (arm B, pid 4047698,
11.3 GB, 100 % util, and then `phase2_chain2.sh` queued a third arm). Every
phase of this spike — licence, size, fertility, training, evaluation, ONNX
export and ORT latency — ran on CPU, which was sufficient (4.6–6.8 min per
candidate to fine-tune), so the contested GPU never affected a result and was
never interrupted.
