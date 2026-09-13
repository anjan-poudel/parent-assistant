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

A second, separate defect is coverage, not correctness: the synthesized
emergency frames are dominated by pain templates. Against the corpus mix,
falls are 16 vs 1 and chest pain 16 vs 1, while pain-dominant rows are 7 vs
49 (7x) -- and the one emergency row the canonical-order distilled arm
missed is exactly the fall plea (म लडेँ, उठ्न सकिन -> none).
INTENT_TARGETS balances the COUNT per intent but nothing balances the
trigger phrasing WITHIN an intent, so the frame pool decides the
sub-class prior. Fix on the generator side (sample frames to the corpus
trigger mix): dropping the pain surplus cannot restore the falls and
chest phrasings it starved. It is a LATENT defect, not the cause of the
arm-A emergency miss: the schema-order arm passed emergency 1.000 on
the same skewed frames, so the decode-order fix was sufficient there.

**Eval-label inconsistency, not a model error (2026-09-13):** the
corpus fills `time` on 41/98 (42%) of `query` rows, four of them
near-identical weather questions labelled `भोलि`; the golden corpus
expects `time: null` for `भोलि मौसम कस्तो हुन्छ`. A model that follows
the training convention is scored as a time false positive.

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

**Gate headroom on the 20-row golden set (2026-09-13, phase 2):** the gates
are computed by `eval_golden.py` over `eval/golden_corpus.jsonl` (20 rows),
and their headroom is far tighter than the thresholds suggest:

- `closed_intent_accuracy >= 0.95` is measured only over `CLOSED_INTENTS`
  (10 intents). The golden set's denominator is **17**: `query` (1 row) and
  `none` (2 rows) are excluded. `>= 0.95` of 17 requires **17/17** — a single
  wrong intent fails the gate (16/17 = 0.941). So the abstention boundary —
  including `gc-ack-002` (`औषधि खाएको छैन`, gold `none`) — is invisible to
  every gate: a model can answer an abstention row with an action intent and
  no gate moves, unless the predicted intent is `call`/`send_message`
  (side-effect precision).
- `slot_f1 >= 0.90` is a whitespace-token F1 over present slots. `time` has
  only **2 gold rows / 6 gold tokens**: with all 6 matched, one stray token
  passes (12/13 = 0.923) but a single spurious multi-token time fails
  (12/16 = 0.750, which is what the schema arm scored). `contact` has 6 gold
  rows / 6 tokens: one stray token passes (0.923), two fail (0.857).
- The corpus/`eval` time convention differs (see above), but it is NOT the
  decisive defect. Recomputing the schema arm's `time_f1` from its own
  predictions (token F1, verified against the measured 0.750 = tp 6 / fp 4):
  as measured 0.750 (fail); with `gc-query-001`'s gold time set to `भोलि`
  to match the corpus convention, 0.824 (still fail — the fix adds a true
  positive, not just removes a false one); only after removing the
  multi-token hallucinated `दिउँसो ८ बजे` on `gc-health-002`, 0.923 (PASS).
  So the gate's real blocker is the health-row hallucination; the eval-label
  inconsistency costs one of the six tokens of tolerance the gate has, which
  makes every convention-conformant one-token time (`भोलि`) a gate-risking
  false positive. Aligning `eval/golden_corpus.jsonl` with the corpus
  convention (or the corpus with the golden row) is still the right fix —
  a gate that a correct answer can fail is not measuring the model.

**Grammar-mirror verification (2026-09-13):** the training box's iOS tree is a
2026-09-02 snapshot that predates the grammar wiring, so every server-side
`--grammar gbnf` run logs `[command_grammar] WARNING: ... carries no
commandJSONSchema literal ... grading the checked-in schema 9432361c7bc3aa86
unverified against Swift`. That is a checkout-age fact, not drift. The check
itself passes in the dev checkout, which does carry the literal:

    INTENT_SCHEMA_STRICT=1 INTENT_SWIFT_PATH=<dev checkout>/ios/.../LlamaCommandInterpreter.swift \
      python3 -c "from command_grammar import load_schema; load_schema()"   # no exception

Result: `seeds/command_schema.json` is byte-identical to the `commandJSONSchema`
literal (fingerprint `9432361c7bc3aa86`, 16 required keys in schema order with
`response` second and `pluginAction`/`pluginEntities` last, 2730 chars of GBNF
from llama.cpp's own converter).

**Contact-slot convention is not uniform (2026-09-13):** the corpus's contact
labels are bare names 78.1% of the time and keep the utterance's case suffix
21.9% of the time (324/1481 rows), while all six golden contact rows strip it
(`माइयालाई फोन गर` -> `माइया`, `didi lai facetime ma call gara na` -> `didi`)
and score the label, not the surface form. `slot_f1` is token-level, so
copying the utterance's `-लाई` is a one-token false positive on a slot whose
entire golden budget is six tokens: arm C answered `छोरालाई` for `छोरा` and
arm D answered `म्यासिन` for `maiya`, and either single slip nearly halves the
gate's margin. Same family as the query/`time` finding above — the fix is
annotation, not model: normalize contact labels (or accept the inflected form
in the scorer) before reading a contact_f1 miss as a model defect.
