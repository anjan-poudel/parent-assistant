# T-033 — Encoder Bake-Off + Export Feasibility: implementation notes

Task: `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-033-encoder-bake-off-export-feasibility.md`
Branch: `worktree-t033-encoder-bakeoff` (worktree `.claude/worktrees/t033-encoder-bakeoff`, based on master `5513323`) — **not merged**
Outcome: **GO** for an on-device Nepali intent encoder, naming `cartesinus/multilingual_minilm-amazon-massive-intent` (XLM-R MiniLM) + XLM-R 250k tokenizer + CoreML mlprogram (iOS) / ONNX Runtime Mobile int8 (Android), student target 100–120M params.
Status of the GO: a recommendation; **lead-engineer sign-off is an explicit open step and is not claimed**.

## What was built (spike code, all on the branch)

- `tools/train-intent/src/bakeoff_candidates.py` — HF licence/access probe (gated flag, licence tag, revision SHA, 1-byte Range access checks; token never printed).
- `tools/train-intent/src/bakeoff_size.py` — measured size composition from tensor shapes; classifies encoder body vs training heads; projected int8.
- `tools/train-intent/src/bakeoff_fertility.py` — tokens-per-word mean/p95 per register (devanagari, romanized, code_switched, elder_fragmented, stt_noised from the bundled Whisper round-trip).
- `tools/train-intent/src/bakeoff_encoder.py` — joint encoder (shared pass, intent head + BIO slot head), word_ids decode, save/load with backbone path recorded.
- `tools/train-intent/src/bakeoff_finetune.py` — seed-42 training with manifest (command, dataset/valid/config/checkpoint hashes).
- `tools/train-intent/src/bakeoff_export_onnx.py` — opset-17 export, dynamic int8, fp32/int8 verification vs PyTorch, ORT latency.
- `tools/train-intent/src/bakeoff_export_coreml.py` — mlprogram FLOAT16 → `xcrun coremlcompiler` → int8 weight quantization → ModelStore-shape zip → verification + latency passes.
- `tools/train-intent/src/bakeoff_coreml_latency.py` — repeated-pass CoreML latency (single passes varied on the shared Mac).
- `tools/train-intent/src/eval_golden.py` — **modified, harness stays T-038-owned**: `--backend encoder` and `--backend onnx` (so the shipping int8 artifact is scored by the pinned metric code), `--manifest-out` JSONL sidecar; `results.csv` schema unchanged.
- Report: `tools/train-intent/docs/T-033-encoder-bakeoff.md` (pre-registered K1–K7 committed at `5bd5eb2` before any measurement; results sections appended after).
- Evidence: `tools/train-intent/docs/t033-evidence/` — `licence_probe.json`, `size_composition.json`, `fertility.json`, `results.csv`, `results_manifest.jsonl`, `C2-onnx-report.json`, `C3-onnx-report.json`, `C2-coreml-report.json`, `C3-coreml-report.json`.

## Results (measured, not cited from the proposal doc)

- Licence: C1 `ai4bharat/IndicBERT-v3-270M` **NOT USABLE** (gated, weights 403, only an indirect MIT tag, Gemma-3 upstream terms); C2 MIT, C3 MIT, C4 Apache-2.0 (revision SHAs in the report).
- Size (int8 encoder body, the thing that ships): C2 140.5MB (239.2M checkpoint of which 98.7M is the tied MLM decoder/head), C3 117.5MB, C4 117.5MB — all ≤ the 200MB K4 cap. A first-pass counting bug (heads included) briefly recorded C2 as failing K4; corrected before any accuracy result, criterion text untouched.
- Fertility (K2, all tokens/word): C2 worst register mean 2.98 / p95 4.2 (Gemma-3 256k tokenizer); C3/C4 worst 2.25 / 3.4 (XLM-R 250k) — XLM-R is materially better on Nepali, including STT-noised transcripts (2.18 vs 2.93 mean).
- Fine-tune (seed 42, CPU, legacy LLM-format dataset snapshot): C2 valid intent acc 0.987 (406s), C3 0.929 (277s).
- Golden corpus (20 rows, harness-scored): C3 fp32 closed 0.882 / emergency 1.000 / timeF1 1.000; C2 fp32 closed 1.000 / emergency 1.000. §10 ship gates are not met by either fp32 checkpoint — expected (legacy dataset, spike floor = K6, slot F1 pre-registered as a T-035 design input).
- Exports: C3 int8 ONNX 118.1MB and int8 CoreML zip 109.1MB **both reproduce fp32 metrics exactly** (harness row identical). C2 exports on both toolchains too (ModernBERT conversion was tested, not assumed) but ORT dynamic int8 drops intent agreement to 0.85 and **emergency recall from 1.000 to 0.000** (all three emergency utterances → `ack_med` at 0.52–0.65 confidence) → **K3 NO-GO on Android as tested**. CoreML weight-only int8 keeps C2's predictions at 1.000/1.000.
- Latency (desktop proxies only; the K5 device-class figure is UNMEASURED — no phone hardware, T-038's): C3 ORT p50 3.25ms, CoreML int8 p50 20.5–178.6ms across two single passes; C2 ORT p50 3.95ms, CoreML int8 p50 39.3ms (median of 3 stable passes).

## Decisions and deviations made during implementation

1. **Corrected the size measurement** rather than the criterion: encoder body excludes checkpoint training heads (`decoder.*`, `head.*`, `cls.*`, `pooler.*`); cross-checked against the instantiated model's parameter count (exact match for mmBERT-small).
2. **C2 killed as tested (K3, Android)** even though it is the fp32 accuracy leader; remediation (QDQ/per-channel int8 or QAT, or fp16 ONNX) is recorded as untested, so it is not evidence.
3. **C4 excluded architecturally**: a sentence-embedding + linear head cannot emit token-level BIO slot spans (plan risk 15); its licence/size/fertility were still measured and recorded so it is not silently dropped. No export was attempted for it.
4. **GPU policy honoured**: the concurrent session's chain held the 3090 throughout (arm B pid 4047698 then `phase2_chain2.sh` queued a third arm). Every phase ran CPU-only and finished in minutes, so the contested card never affected a result and was never interrupted. No GPU job was ever queued.
5. Environment quirks recorded for reproducibility: `HF_HUB_DISABLE_XET=1` required on the experiment host; torch bumped 2.5.1 → 2.6.0+cu124 in the spike venv (CVE-2025-32434 guard refuses `.bin` checkpoints below 2.6); on the Intel export Mac (torch 2.2.2 max) the backbone was converted to safetensors (`T033_BACKBONE_OVERRIDE`) and `@torch.compile` at ModernBERT import time was neutralised (`T033_PATCH_TORCH_COMPILE=1`); one CoreML conversion died on `No space left on device` (Mac disk ~99% full) and was re-run lean (`--skip-fp16-package`) — recorded in the report, not hidden.
6. No PII (NFR-016): seeds, synthetic teacher rows and the held-out golden corpus only. No token or secret appears in any committed file.

## Verification performed

- Smoke end-to-end run (train → harness eval → ONNX → CoreML → ModelStore-shape zip) before the real runs, to prove the wiring.
- `python -m py_compile` on all nine scripts; harness `--backend echo` smoke after the edits.
- Per-export numerical verification against PyTorch on the golden corpus (ONNX fp32 + int8; CoreML int8), plus harness-scored int8 rows with config/corpus/checkpoint hashes.
- Unit-style checks inside the scripts (manifest hashes, zip top-level shape == `<stem>-encoder.mlmodelc`).

## Could not be measured (recorded, with reasons)

- Device-class interpret latency and on-device emergency behaviour — no phone hardware (T-038).
- Δ vs `GeminiCommandInterpreter` (within −3 pts) — no `GEMINI_API_KEY` in the experiment environment (T-038).
- C1 size/fertility/export — weights 403 (K1), excluded by rule.
- C2's Android quantization remediations — untested, explicitly not evidence.
- Load-on-device of the compiled `.mlmodelc` through ModelStore — proxy-verified on the Mac only (T-038).

## Commits on `worktree-t033-encoder-bakeoff` (never merged to master)

- `5bd5eb2` pre-registration of K1–K7 (before any measurement)
- `a13f830` spike scripts
- `4e295be` measured evidence: licence/access, size composition, fertility
- `a835b52` results, GO/NO-GO, kill-criteria matrix, export evidence
- `ed151f6` spike golden-corpus rows appended to `eval/results.csv` + hash manifests

## Open step

Lead-engineer sign-off on the GO (DoD requirement before T-034/T-035/T-036 start). This file and the report do not claim it.
