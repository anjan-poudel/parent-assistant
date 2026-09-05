# Plan: intent-model GGUF export (`src/export_gguf.py`)

**Status:** plan for later implementation — written 2026-09-06, not yet built.
**Blocks:** the bake-off eval (`eval_golden.py --backend gguf`) and shipping the
model to the app. Everything else in the pipeline is already in place.

## 1. Why this stage exists

`train_qlora.py` produces a **LoRA adapter + 4-bit base** in
`checkpoints/<tag>-final/` — not a loadable single-file model. Two downstream
consumers need one file:

- `eval_golden.py --backend gguf --model-path <file>.gguf` (the ship gates run
  against the exact artifact that ships — never against the fp16 merge, because
  quantization moves behavior; §6)
- the app, which downloads a GGUF via `ModelStore` into
  `LocalIntentInterpreter` (llama.cpp).

## 2. Inputs → outputs

| | |
|---|---|
| **In** | `checkpoints/<tag>-final/` (adapter), base model id from `config.yaml:training.base_models` |
| **Out** | `models/intent-ne-<tag>-q4_k_m.gguf` + `models/intent-ne-<tag>-q4_k_m.gguf.sha256` |
| | `eval/results.csv` row proving the artifact passed the gates (run separately) |

Conventions follow `tools/train/src/export_ggml.py`: skip-if-output-exists,
sha256 sidecar, resumable, no partial artifacts (write to `.tmp` then rename).

## 3. Steps the script performs

1. **Merge adapter into base** (fp16) — `peft` merge or
   `llama.cpp`'s `convert_lora_to_gguf.py` is NOT what we want here; merging in
   HF space (`AutoModelForCausalLM.from_pretrained(base)` +
   `PeftModel.from_pretrained(...).merge_and_unload()`) then saving a merged HF
   dir is simpler and keeps tokenizer/config intact. Output:
   `checkpoints/<tag>-merged/` (skip-if-exists).
2. **Convert HF → GGUF (f16)** — `~/llama.cpp/convert_hf_to_gguf.py
   --outfile <tmp>.f16.gguf --outtype f16 <merged-dir>`. (Pin: use the same
   llama.cpp checkout as the whisper export, `WHISPER_CPP_DIR`-style env
   `LLAMA_CPP_DIR`, default `~/llama.cpp`; clone+build if missing, mirroring
   tools/train README's whisper.cpp bootstrap.)
3. **Quantize → Q4_K_M** — `~/llama.cpp/build/bin/llama-quantize
   <tmp>.f16.gguf models/intent-ne-<tag>-q4_k_m.gguf Q4_K_M`. Delete the f16
   intermediate on success (it's ~2 GB of dead weight).
4. **sha256 sidecar** — `shasum -a 256` into `<file>.sha256` (matches
   ModelStore's strict checksum policy).

## 4. Script interface (suite conventions)

```bash
.venv/bin/python src/export_gguf.py --model checkpoints/qwen-final --tag qwen
# idempotent: skips merge/convert/quantize steps whose outputs exist
```

`config.yaml` additions:

```yaml
export:
  llama_cpp_dir: ~/llama.cpp
  quant: Q4_K_M        # already present
  out_dir: models      # already present
```

## 5. Then: eval the artifact (the gate order matters)

```bash
.venv/bin/python src/eval_golden.py --backend gguf \
  --model-path models/intent-ne-qwen-q4_k_m.gguf --label qwen3-1.7b-q4_k_m
```

- Eval the **quantized Q4_K_M artifact**, not the fp16 merge — the quantized
  file is what users run; a model that passes fp16 but fails Q4_K_M does not
  ship.
- Gates enforced by the script (exit non-zero): closed-intent accuracy ≥ .95,
  slot F1 ≥ .90, **emergency recall = 1.00**, side-effect precision ≥ .97,
  within −3 pts of the Gemini baseline row.

## 6. Publish path (after a winner exists)

1. Create a GitHub release on the models repo (same place the whisper
   `models release v3` lives) with the GGUF attached.
2. Fill the real values into `ModelCatalog.intentNepali1B`
   (`ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift`):
   `downloadURL` (release asset URL), `sizeBytes`, `sha256` (from the
   sidecar), and adjust `displayName` if the winner's base matters
   ("Intent engine (Nepali, Qwen 1.7B)").
3. On next app launch, ModelStore downloads it; `LocalIntentInterpreter.
   isAvailable` flips true; `IntentRouter.localBrain` wakes up. Closed-vocab
   intents go fully on-device from that point.

## 7. Verification checklist (before the release is published)

- [ ] `llama-cli -m models/intent-ne-<tag>-q4_k_m.gguf` loads and answers a
      raw `IntentPrompt.build`-format prompt with schema-valid JSON
- [ ] The app's `LlamaCommandInterpreter.parse(json:)` accepts the output
      (the eval harness covers this implicitly via its JSON decode)
- [ ] `eval_golden.py` row exists with all gates passed
- [ ] File size within ±15% of the `ModelCatalog` estimate (~900 MB) and the
      recorded sha256 matches the artifact byte-for-byte
- [ ] Constrained-decoding smoke on device: `LLM.respond(to:as:)` with
      `LocalIntentInterpreter.intentSchema` produces parseable output for
      "माइयालाई फोन गर" (first on-device proof)

## 8. Open items

- **Base-model tokenizer chat template**: export must preserve the tokenizer
  config the training used; verify `convert_hf_to_gguf.py` carries it (Qwen
  and Gemma differ here — check per winner).
- **`convert_hf_to_gguf.py` version pin**: llama.cpp moves fast; record the
  checkout SHA used for the winning export in `eval/results.csv`-adjacent
  notes (reproducibility).
- **eval set growth**: the golden corpus is 20 rows; gates get meaningfully
  stricter once it grows to the planned 15–25 per intent. Ship decision for
  the first GGUF may note the small-n caveat explicitly.
