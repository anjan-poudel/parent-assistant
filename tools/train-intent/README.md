# Intent model training suite — fine-tuned on-device intent LLM

Trains the **small (~1B) multilingual intent model** for the intent engine
(spec: `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md`
§8–§10). The model maps STT transcripts → `intent/v2` JSON (intent + response
+ slots + calibrated confidence — the app's canonical wire names) and runs
on-device as `IntentRouter`'s local brain.

Teacher = **Gemini 2.5 Flash** (the same behavior the cloud path already
has — the local model distills the interpreter we trust). Base candidates:
**Gemma 3 1B** / **Qwen 3 1.7B** (Nepali capability varies more by family
than size — bake off, spec §9.5).

**Everything here is durable and resumable**, same discipline as
`tools/train/`: kill anything at any time; re-running the same command
picks up where it left off (append/dedupe manifests, skip-if-done).

## The pipeline

| Stage | Command | Output | Resume behaviour |
|---|---|---|---|
| 1. Teacher generation | `python src/gen_teacher.py` | `data/teacher.jsonl` | appends; ids already generated are skipped |
| 2. STT-noise injection | `python src/stt_noise.py` | `data/noised.jsonl` | appends; utterances already noised are skipped |
| 3. Dataset build | `python src/build_dataset.py` | `data/train.jsonl`, `data/valid.jsonl` | full rebuild, deterministic (fast) |
| 4. Train (QLoRA) | external — see §Training below | `checkpoints/` | resume from latest checkpoint |
| 5. Eval | `python src/eval_golden.py --backend ...` | `eval/results.csv` | append-only; (model, set) pairs skipped |
| 6. Export GGUF | external (llama.cpp convert + quantize) | `models/*.gguf` | skip-if-exists |

Stages 1–3 and 5–6 are this suite. Stage 4 (QLoRA training) is intentionally
**not re-implemented here**: use axolotl/unsloth/llama-factory with
`config.yaml`'s `training` section as the recipe — see "Training" below.

## Data philosophy (spec §9.2 — realism is the whole game)

The model consumes **STT output at runtime**, not clean text. Training on
clean text guarantees a distribution mismatch. So:

- **60%** of the mixture is STT-noised: teacher utterances synthesized by
  TTS, then transcribed by the *actual bundled Whisper* (the same model
  the app ships), keeping both transcripts.
- **25%** clean Devanagari, **15%** romanized + code-switched
  ("maiya lai WhatsApp ma call gara" is how people actually speak).
- **Edge classes** (spec §9.1): gibberish → `none`; emergency near-misses
  → `emergency` (recall-first); ambiguous → low-confidence abstain.
  **An overconfident small model is worse than no model.**
- **The golden corpus (`eval/golden_corpus.jsonl`) is HELD OUT — never
  trained on.** `build_dataset.py` refuses any row whose normalized
  utterance appears in the corpus.

## Ship gates (spec §10 — eval enforces these)

| Metric | Gate |
|---|---|
| Closed-intent accuracy | ≥ 95% |
| Slot F1 (contact, time) | ≥ 0.90 |
| **Emergency recall** | **= 100% on corpus** |
| Call/message precision | ≥ 97% |
| Δ vs Gemini interpreter | within −3 pts on closed intents |

`eval_golden.py` exits non-zero when any gate fails, so a bad checkpoint
can't be shipped by accident.

**Decode fidelity (2026-09-13, resolved):** the GGUF backend now decodes
under the SAME grammar the app uses — `LlamaGrammar.commandJSONSchema`,
extracted from the Swift source into `seeds/command_schema.json` and
converted by llama.cpp's own JSON-Schema→GBNF converter
(`src/command_grammar.py`). Every run prints the schema fingerprint it
graded against, and every row of `eval/results.csv` records its decode
mode; rows written before 2026-09-13 are `off` (unconstrained).

The mirror matters because unconstrained sampling can emit JSON the app
can never produce: qwen4b-s42 wrote `"confidence": .9` (invalid JSON) on
5/20 rows, which the strict parser scores as no-JSON → `none`, collapsing
that seed's contact F1 to 0.286. Those numbers were eval artifacts.

**Gate-fidelity caveat (still true):** the mirror is faithful, not
cost-free. `commandJSONSchema` compiles to a GBNF whose property ORDER is
the schema's — `response` second, and four keys the golden corpus never
contained (`actionType`, `actionUrl`, `pluginAction`, `pluginEntities`) —
while every checkpoint trained before 2026-09-13 learned the canonical
order with `response` last and no app-only keys. Decoding forces the
trained keys to be re-emitted in an untrained order, and the checkpoint
pays for it in real slot F1 (qwen4b-s43: contact 1.000 → 0.800, time
1.000 → 0.833). Treat gbnf scores as production truth and use
`train_qlora.py --label-order schema` to teach the grammar's shape.

**Three-way shape disagreement (2026-09-13, phase 2):** the caveat above
is not only about the grammar. The prompt the app actually sends — the
one-shot example in `IntentPrompt.build`, mirrored byte-for-byte in
`seeds/prompt_template.txt` — is ITSELF a schema-order, five-key object
(`intent`, `response`, `confidence`, `actionType`, `actionUrl`) that
stops at `actionUrl`, while the decode grammar REQUIRES all sixteen keys
and the canonical labels teach twelve with `response` last. A 1.7B
student resolves that disagreement by copying the prompt: the
canonical-order distilled arm emitted exactly those five keys and
stopped (unconstrained decode), which is the prompt's example shape, not
a base-model artifact. Train in the grammar's shape (`--label-order
schema`) so the target the model is graded on is the target the prompt
asks for.

**Distillation add-on (phase 2):** `gen_distill.py` labels synthesized
frames with the passing 4B teacher and adds them ON TOP of the mixture
(`mixture.distill_target`, cap 2600; §9.2 conformance is checked over the
non-distill portion, which keeps its exact 60/25/15). The delivered
overall mix is 37.4/41.7/20.9 instead — the add-on's 1706 clean rows
dilute STT-noised exposure from 60% to 37%, so an arm that adds them is
not comparable to a baseline on the noisy axis. The teacher's labels are
audited before use (`audit_distill_labels.py`): 105/1706 time labels
contradicted the utterance's own qualifier (`सवा ५` labelled `साढे ५
बजे`) and 11 contacts were mislabels. `gen_distill.py --revalidate`
repairs only those rows offline (no teacher, no GPU), keeps the raw
teacher rows in `data/distill_teacher_raw.jsonl` for audit, and re-audits
to 0. Note that `draw_key` hashes the FULL row JSON, so a repaired label
re-draws that row's key: the repaired rebuild has the same 4307 rows but
a new file order, and 5 repaired rows cross the 5% train/valid boundary.

## Training (stage 4, external)

Recommended: unsloth or axolotl QLoRA on the 4090 box (same machine as
`tools/train/`). Recipe (from `config.yaml:training`): r=16, alpha=32,
lr 1.5e-4, 3 epochs, bf16, all-linear targets, seq len 1024.

Chat format: the training prompt mirrors `IntentPrompt.build` (see
`seeds/prompt_template.txt`) — **training and inference must use the
identical prompt**, or the fine-tune teaches a distribution the app never
sends. The template's three placeholders (`{language_hint}`,
`{medications}`, `{transcript}`) are filled by `src/intent_prompt.py`
(`render_prompt`), which training and BOTH eval backends share; labels use
the app's canonical `intent`/`response` keys (not the legacy
`action`/`reply` names).

## Smoke test

```bash
python src/build_dataset.py --smoke    # validates + splits data/sample.jsonl only
python src/eval_golden.py --backend echo   # dry-runs the harness (echo backend = utterance in, none out)
```
