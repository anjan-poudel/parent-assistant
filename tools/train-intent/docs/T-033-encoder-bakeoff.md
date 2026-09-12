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
- Environment: Python 3.12.3, torch 2.5.1+cu121, transformers 4.56.2,
  onnx/onnxruntime 1.22/1.30, seed 42. `HF_HUB_DISABLE_XET=1` is required on
  this host (the xet download path hangs); recorded so runs are reproducible.
- Licence probe evidence: `docs/t033-evidence/licence_probe.json`;
  size: `docs/t033-evidence/size_composition.json`;
  fertility: `docs/t033-evidence/fertility.json`.
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

| # | Total params | Non-embedding | Vocab | Embedding share of int8 | Projected int8 (whole model) | Checkpoint file |
|---|---|---|---|---|---|---|
| C1 | UNMEASURED — access denied (403), excluded | | | | | |
| C2 mmBERT-small | **239.2 M** | 140.9 M | 256 000 | 41.1 % | **239.2 MB → fails K4 cap (≤ 200 MB)** | 563.6 MB `pytorch_model.bin` |
| C3 MASSIVE MiniLM | 117.7 M | 21.7 M | 250 037 | 81.6 % | 117.7 MB | 470.7 MB `model.safetensors` |
| C4 SetFit base MiniLM | 117.7 M | 21.6 M | 250 037 | 81.6 % | 117.7 MB | 470.6 MB `model.safetensors` |

Honesty note against the proposal doc: its "≈140M" for mmBERT-small is the
**non-embedding** count; the checkpoint totals **239.2 M parameters** and its
embedding table alone is 98.3 M params (256 k vocab × 384). The doc's "≈100M"
for the MASSIVE MiniLM checkpoint is close to the measured 117.7 M. Because the
embedding table ships with the model, C2's projected int8 artifact (239.2 MB)
exceeds the pre-registered 200 MB cap — **K4 FAIL for C2**, independent of any
accuracy question.

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
