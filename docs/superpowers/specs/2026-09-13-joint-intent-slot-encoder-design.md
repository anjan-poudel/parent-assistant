# Joint Intent + Slot Encoder — Design

- **Task:** T-035 (`.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-035-joint-intent-slot-encoder-design.md`)
- **Branch:** `worktree-t035-encoder-design` (base `840bcd7`) — not merged, not pushed
- **Status:** design deliverable — no training run, no model download, no build
- **Machine-readable companion:** `tools/train-intent/encoder_contract.yaml`
  (`schema: encoder-contract/v1`), consumed by T-036 (training/distillation) and
  T-038 (eval/device verification).
- **Companion review document:** `docs/superpowers/specs/2026-09-13-l2-4.2-amendment.md`
  (the L2 §4.2 replacement text). `.ai-sdd/outputs/design-l2.md` is **not** edited here.
- **Inputs:** T-033 GO (`tools/train-intent/docs/T-033-encoder-bakeoff.md` §8);
  T-034 data contract (`tools/train-intent/annotation_rules.yaml`,
  `docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md`); the shipped
  schema-v2 code (§2).
- **Re-scopes:** task T-021 (`IntentClassifier` / `EntityExtractor`, TG-03), which the
  L2 text currently describes as prompt-engineering layers over `LlamaInferenceEngine`.

---

## 1. Purpose and scope

This design fixes the **local encoder fast path**: a joint intent + slot encoder that
classifies one of the twelve schema-v2 actions and emits **verbatim spans** as slot
candidates, in one shared encoder pass. It replaces the `IntentClassifier` /
`EntityExtractor` prompt-engineering layers of L2 §4.2 (T-021) with a single
conformant `CommandInterpreter`.

Three properties are load-bearing and non-negotiable:

1. **Spans, never resolved values.** The encoder copies substrings of the transcript it
   consumed. It never emits a contact id, phone number, URL, or resolved clock time.
   Resolution stays in deterministic Swift (§8).
2. **No router change.** No edit to `IntentRouter.swift` or `CommandRouter`'s keyword
   net. The encoder conforms to `CommandInterpreter` and is installed in the existing
   brain slots; the shipped 0.7 / 0.4 bands are the only thresholds.
3. **The safety net is upstream and absolute.** `routeSafetyNet` runs before any model
   (`CommandRouter.swift:651-653`), so neither a low-confidence nor an abstaining
   encoder can suppress emergency or explicit med-ack.

Out of scope by decision: the proposal's MASSIVE-derived taxonomy, its resolved-value
output style, its 0.75/0.95 confidence bands, and its SetFit option as the joint model
(§14, §15). The LLM remains the long-tail brain (FR-007) — this component is a peer of
the incumbent local GGUF, not a replacement for the cloud fallback.

## 2. Ground truth read for this design

Every claim below is grounded in a file read for this task, not recalled.

| Fact | Source (verified) |
|---|---|
| Base model, tokenizer, runtimes, size target | `tools/train-intent/docs/T-033-encoder-bakeoff.md` §3, §7, §8 |
| Training label set (12), span labels (6), BIO tags (13), offsets, mixture, edge classes, refusals | `tools/train-intent/annotation_rules.yaml`; narrative §3.2, §4, §6 |
| `CommandInterpreter` protocol (`isAvailable`, `interpret`) | `Services/Voice/LlamaCommandInterpreter.swift:34-41` |
| `InterpreterFailureReporting.lastInferenceFailureReason` | same file `:49-54` |
| `InterpretedCommand` fields + `Action` cases | same file `:65-155` (fields `:89-130`, enum `:66-88`) |
| `requestedApp` = "an app the user explicitly named … else null" | same file `:106-111` |
| `OnDeviceSampling` (temp 0, seed `20_260_907`) | same file `:261-270` |
| Router layers, `Config.default` 0.7 / 0.4, `bandChecked`, escalation | `Services/Intents/IntentRouter.swift:48-59`, `:316-330`, `:197-238` |
| `preferred` vs `standIn` local-brain chain | `Services/Intents/LocalBrainChain.swift:28-69` |
| Incumbent local brain: sanitiser call, 10 s timeout, one retry, abstain at 0.4 | `Services/Intents/LocalIntentInterpreter.swift:39-50`, `:96-115`, `:235-282` |
| Cacheable actions `{call, music, suggest_video}`; confirmation never skipped | `Services/Intents/IntentCommandCache.swift:51-65`, `:82-86` |
| Confirmation tiers per action | `Services/Intents/ConfirmationTier.swift:12-35` |
| `InputSanitiser.sanitise(_:level:)`, `.quarantine`, `maxLength = 200` | `Services/Voice/InputSanitiser.swift:16-22`, `:42-73` |
| `ContactResolver.resolve`, threshold 0.6, compound containment | `Services/Intents/ContactResolver.swift:30`, `:60-61`, `:70`, `:127-134` |
| `MethodResolver.resolve` / `explicitMethod`, phone/whatsapp/facetime matching | `Services/Intents/MethodResolver.swift:47-49`, `:87-113` |
| App-name vocabulary (two scripts) | `Services/Intents/CallLinks.swift:248-251`, `:257` |
| `NepaliTimeParser.parse` | `Services/Voice/NepaliTimeParser.swift:19`, `:35` |
| Flywheel log: on-device, `NSFileProtectionComplete`, export | `Services/Intents/IntentLogStore.swift:8-18`, `:49`, `:58-65`, `:108` |
| Emergency / med-ack safety net ordering | `Services/Voice/CommandRouter.swift:566-570`, `:651-653`, `:1429-1471` (phrases `:1403-1408`, denial `:1443-1452`, ack `:1454-1469`) |
| Interpreter fast path + nil → keyword remainder | `Services/Voice/CommandRouter.swift:1049`, `:1092`, `:1109` |
| `reply` is consumed for Reply-class answers | `Services/Voice/CommandRouter.swift:2115`, `:2143`, `:2146`, `:2271-2272`, `:2398` |
| Spike architecture (shared pass, two heads) and its 5-tag slot head | `tools/train-intent/src/bakeoff_encoder.py:38`, `:91-104`, `:141-173` |
| Spike loss (intent CE + masked slot CE, sum) | `tools/train-intent/src/bakeoff_finetune.py:151-174` |
| Harness encoder/ONNX backends, graph signature, `slot_f1` | `tools/train-intent/src/eval_golden.py:166-232`, `:269-280` |
| §10 ship gates (incl. calibration ±10) | `tools/train-intent/config.yaml:56-62`; spec `:571-584` |
| Spec principles ("LLM proposes, code disposes"; "abstention is a feature") | spec `:34-50` |
| Schema v2 + cache + tiers | spec `:274-277`, `:293-328`, `:422-428` |
| Proposal's SetFit option and 0.75/0.95 bands (not adopted) | `docs/architecture/nepali-intent-recognition-model.md:227-253`, `:715-733` |

## 3. Architecture

### 3.1 Encoder body

Fixed by T-033 §8, not re-litigated here:

| Element | Choice |
|---|---|
| Base | `cartesinus/multilingual_minilm-amazon-massive-intent` (XLM-R MiniLM, 12 layers, hidden 384) |
| Tokenizer | the XLM-R sentencepiece shipped with it, 250 037 vocab, revision `08dc4816…` |
| Encoder body | 117.5 M params → **student size target 100–120 M**, int8 118.1 MB (ONNX) / 109.1 MB (CoreML zip) |
| iOS runtime | CoreML mlprogram, int8 weight-quantized, zip containing one `<stem>-encoder.mlmodelc` |
| Android runtime | ONNX Runtime Mobile, int8 ONNX graph, opset 17 |

T-033 selected C3 because it was the only candidate that passed every kill criterion
**as a shippable artifact on both platforms**: C1 failed licence (K1), C2's int8 ONNX
graph lost the emergency gate (recall 1.000 → 0.000, K3), C4 was excluded
architecturally (no BIO decoder). Latency remains a desktop proxy — the device-class
figure is UNMEASURED (T-033 K5, T-038 owned).

### 3.2 Heads — one shared pass, two heads

The spike's architecture is the design's architecture (`bakeoff_encoder.py:91-104`):
one encoder forward pass, then two linear heads over its output.

```
sanitised transcript
        │  whitespace words → XLM-R sentencepiece → input_ids, attention_mask
        ▼
  XLM-R MiniLM encoder body (12 layers, 384 hidden)     ← the only part that ships
        │
        ├── last_hidden_state[:, 0]  ──► Linear(384, 12) ──► intent logits   (12 schema-v2 actions)
        └── last_hidden_state        ──► Linear(384, 13) ──► slot logits     (O + B/I × 6 span labels)
```

| Head | Output | Supervised by |
|---|---|---|
| Intent | 12 logits over `taxonomy.labels` (`annotation_rules.yaml`) | the row's `action` |
| Slot | 13 logits per token over `spans.bio.tags` | the row's `spans`, word-first projected (T-034 §4.3) |

**Divergences from the spike, stated.** The spike's slot head had **5 tags** (`O`,
contact, time only — `bakeoff_encoder.py:38`); this design's head has **13 tags** for
the six span labels T-034 defines. The intent head is unchanged in shape (the spike
already emitted 12-class logits) but its label set is now pinned to schema v2 rather
than whatever `data/train.jsonl` carried.

**Intent pooling.** `h[:, 0]` (position 0 = the `<s>` token for XLM-R), exactly as the
spike pooled (`bakeoff_encoder.py:103`) and as T-034's alignment rule states ("intent
supervision = the pooled [CLS] representation").

### 3.3 Tokenization and span decoding

Training and inference use the **same** mechanism, so the two cannot drift — the
discipline the incumbent model already follows for its prompt format
(`LocalIntentInterpreter.swift:16-19`):

1. Words = maximal non-whitespace runs of the exact string the encoder consumes,
   ascending, code-point intervals (T-034 §4.3 step 1).
2. Tokenize with `is_split_into_words=True`, `truncation=True`, `max_length=64`,
   `return_offsets_mapping` not required.
3. `word_ids()` maps each subword back to its word. **First-subword tagging**: a word's
   tag is the tag of its first subword (`bakeoff_encoder.py:161-165`, T-034 §4.3 step 2).
4. Decode: a run of `B-`/`I-` tags of one label becomes the union of those words' char
   intervals; the surface is `transcript[start:end]`.

Step 4 is a **deliberate divergence from the spike's decoder**, which rejoined the
*words* with spaces (`bakeoff_encoder.py:75-88`). Slicing the transcript is what makes
T-034's invariant `utterance[start:end] == text` true by construction, and it removes
the sentencepiece `▁` leak that T-034 forbids (`annotation_rules.yaml`
`spans.alignment.decoding`) by never touching decoded token strings at all.

The exported graph therefore needs only `input_ids` + `attention_mask` and returns two
tensors — the exact signature the harness already drives
(`eval_golden.py:211-213`), so no offsets tensor is added to the artifact.

### 3.4 Loss

The spike's objective (`bakeoff_finetune.py:151-174`) is the supervised floor:

```
loss_intent = CE(intent_logits, action_id)                      # unweighted
loss_slot   = masked mean CE(slot_logits, bio_tags)             # ignore_index = -100
L_sup       = loss_intent + λ_slot · loss_slot                  # λ_slot = 1.0 (spike used 1.0)
```

T-033 masked the slot loss on ~35 % of slot rows whose labels were not
verbatim-alignable. **That masking is retired**: T-034 makes alignability an authoring
invariant, so non-alignable rows are refused at build time and every surviving row
supervises slots (`annotation_rules.yaml` `spans.masking_policy`). Only special and
zero-width tokens carry `-100`.

Emergency is recall-first (spec §9.4) and the §10 gate on it is hard. The mechanism is
a **class weight on the intent CE only** — `w_emergency`, initial value 2.0, T-036 may
tune within [1.0, 4.0] — never a runtime threshold:

```
loss_intent = CE(intent_logits, action_id, weight = w[action_id])
```

Weighting deliberately trades calibration for recall, so **calibration is fitted after
weighting** (§5) and the §10 bucketed gate measures the shipped configuration. If the
sweep cannot satisfy both gates, the recorded resolution order is: emergency recall
first (hard gate), then calibration, then closed-intent accuracy.

### 3.5 What ships

Two artifacts per platform, both carrying the same metadata: the encoder graph, and a
`meta.json` with `intents[]` (ordered = logit order), `tags[]` (ordered = logit order),
`max_len`, `calibration_temperature`, and the artifact digest. The heads are part of
the shipped artifact — unlike T-033's size accounting, where `bert.pooler` and
`classifier` were excluded as "training heads" (`size_composition.json`), the intent
and slot heads **are** inference-time components here and their weights ship. They are
0.2 M params against a 117.5 M body, so the T-033 size target is unaffected.

## 4. Distillation objective

Two stages; stage 1 is the fallback if stage 2's teacher material is unavailable.

**Stage 1 — hard-label supervision** (`L_sup`, §3.4) on the T-034 dataset. This is what
T-033 measured (0.882 closed / 1.000 emergency on the 20-row corpus with the *legacy*
dataset) and it is sufficient to ship.

**Stage 2 — knowledge distillation**, added when a teacher distribution exists:

```
L_kd  = τ² · KL( softmax(teacher_logits / τ)  ‖  softmax(student_logits / τ) )
L     = L_sup + λ_kd · L_kd          τ = 2.0, λ_kd = 0.5 (initial; T-036 owns the sweep)
```

Teacher material, in preference order, with the honest caveat for each:

| Source | Availability | Caveat |
|---|---|---|
| Incumbent fine-tuned local LLM (`ModelCatalog.intentNepali1B`, `LocalIntentInterpreter.swift:82`) | **tooling not yet in the repo** — no script reads its per-class logprobs | llama.cpp can expose logprobs, but that plumb-through is T-036 tooling scope, not existing code |
| Gemini teacher rows (`gen_teacher.py`) | available (`config.yaml:gemini.model`) | rows carry a **scalar** `confidence` (`gen_teacher.py:36`, `annotation_rules.yaml` `row_format.confidence`), not a distribution |

For the Gemini source only, the soft target is a **stated construction**, not a measured
distribution: `p_teacher[gold] = confidence`, mass `(1 − confidence)` spread uniformly
over the other 11 classes. This is recorded as a construction so a later reader does
not mistake it for teacher probabilities.

**No slot distillation.** Neither teacher emits token-aligned BIO spans: the LLM teacher
emits slot *strings* and the Gemini rows carry span annotations authored on the text,
not logits. Slot supervision is hard-label from T-034's spans only. Trying to distil
slot logits from an unaligned teacher would teach the decoder noise, so it is scoped
out explicitly rather than left implicit.

**The teacher is never a runtime dependency.** Distillation is training-time only;
inference stays on-device (FR-007), and no local teacher model is introduced
(`annotation_rules.yaml` `teacher.local_teacher: forbidden`).

## 5. Calibration

**Mechanism: temperature scaling.** One scalar `T` fitted post-hoc on the held-out
valid split by minimising NLL over the intent logits. Properties that matter here:

- **Argmax-preserving.** Dividing logits by a positive scalar is monotone, so
  calibration cannot change *which* action wins — it can only move the confidence that
  the band policy reads. The emergency class-argmax recall gate is therefore unaffected
  by calibration, which is exactly why calibration can be fitted after the class
  weighting in §3.4.
- **Fitted on a split the model was selected on but not trained on** — T-034's
  `valid_fraction: 0.05`, never the golden corpus (held out,
  `annotation_rules.yaml` `governance.golden_corpus`).
- **Ships with the artifact** as `calibration_temperature` in the artifact's
  `meta.json`, alongside the ordered class and tag lists. The graph keeps emitting raw
  logits and the interpreter applies `logits / T` then softmax in code — the same
  convention the harness already uses (`eval_golden.py:213-216`,
  `bakeoff_encoder.py:156`). Keeping `T` out of the graph means the parameter is
  reviewable, diffable and recorded in the T-036 run manifest rather than buried in a
  compiled artifact.

**The gate (spec §10) is a ship requirement.** `config.yaml:56-62` carries the numeric
gates; calibration is spec `:578` ("bucketed confidence accuracy ±10%"). Pinned
precisely, because "±10%" is ambiguous:

- Ten fixed buckets `[0.0,0.1), [0.1,0.2), … [0.9,1.0]` over the calibrated confidence.
- For each bucket with **≥ 30 samples**: `| empirical accuracy − mean predicted
  confidence | ≤ 0.10`.
- Buckets below the sample floor are pooled upward with their neighbour and reported as
  pooled, not silently dropped; if pooling still leaves < 30 samples, the bucket is
  reported as UNMEASURED with its count.
- Measured by `eval_golden.py`-family tooling (T-038 owns the harness change); the
  corpus floor of 8 000 rows (`annotation_rules.yaml` `mixture.supply_caps.corpus_floor`)
  is what makes ten buckets statistically meaningful — T-033's 20-row corpus cannot
  support this gate, and the design says so rather than pretending otherwise.

**Band interaction.** The calibrated confidence is the *only* number the band policy
consumes. No new threshold is introduced anywhere in this design (§9).

## 6. Data contract (T-034, consumed — not redefined)

This design **loads** `tools/train-intent/annotation_rules.yaml` and asserts its
`taxonomy.labels` against `build_dataset.VALID_ACTIONS` and against the raw values of
`InterpretedCommand.Action` minus the runtime-only `plugin` case. It defines no
competing label set. Concretely consumed:

| Contract element | Value (from T-034) |
|---|---|
| Action labels (12) | `ack_med, call, emergency, set_reminder, health_query, music, send_message, guide, create_calendar_event, suggest_video, query, none` |
| Runtime-only action, never a class | `plugin` (`LlamaCommandInterpreter.swift:82-87`) — absent from `VALID_ACTIONS` and from every training row |
| Spec §9.1 targets | call 1500, set_reminder 1200, send_message 1000, emergency 1000 (never reduced), health_query 700, music 600, guide 600, query 1000, none 500, ack_med 800; `create_calendar_event` 600 and `suggest_video` 500 are T-034 *proposals* (no spec target) |
| Seed gaps T-036 must close | `ack_med`, `create_calendar_event`, `suggest_video` have zero seed templates today |
| Span labels (6) | `contact, time, medication, message, topic, app` |
| BIO tags (13) | `O` + `B-`/`I-` × 6, no BILUO |
| Offsets | Unicode scalars, 0-based, half-open, `utterance[start:end] == text` |
| Mixture | 60 % stt_noised / 25 % clean Devanagari / 15 % romanised + code-switched; floors `stt_noised ≥ 0.55`, per-action ≥ 0.25 × target, corpus ≥ 8 000 |
| Edge classes | abstain (< 0.4), gibberish (< 0.2), corrections (`call` + `app` span), ack positives vs refusals (`none`) — families inside the 12 labels, never new action values |
| Refusal guard | an `ack_med` row containing a refusal marker is refused; refusal must never fire ack |
| Governance | golden corpus held out with the normalized-leak refusal preserved; real utterances only via the explicit-consent `IntentLogStore` export |
| Teacher/STT pins | `gen_teacher.py` + Gemini (training-time only); `stt_noise.py` round-trip; **no local teacher** |

**Rejections inherited.** T-034 reconciles all 42 proposal/MASSIVE-derived labels: 20
are rejected outright (`alarm_remove`, `alarm_query`, `calendar_remove`, `email_query`,
`lists_*`, `audio_volume_*`, `transport_*`, `ANSWER_CALL`, `READ_MESSAGE`,
`CHECK_MISSED_CALLS`, `LIST_REMINDERS`, `CANCEL_REMINDER`, `OPEN_APP`, `REPEAT`,
`CANCEL`), the rest are recoloured onto a schema-v2 label with two caveats (`HELP` →
`emergency`, recall-first; `play_radio`/`play_podcasts` → `music` with a content-bank
supply limit). This design adopts that table wholesale and adds no label.

**The sanitised string is the encoder's input.** The encoder consumes
`InputSanitiser.sanitise(transcript, level: .quarantine)` — the same call the incumbent
makes (`LocalIntentInterpreter.swift:101`). Offsets are into **that** string, and the
sanitiser rewrites the text (control chars → spaces, whitespace collapsed, injection
markers removed, clamped to 200 chars — `InputSanitiser.swift:42-73`, `maxLength` at
`:22`). T-033 measured STT-noised p95 at ≈ 10 tokens (XLM-R), so the 200-char clamp is
far above any real utterance; the truncation case is still designed for (§12).

## 7. Field-by-field mapping to `InterpretedCommand`

Every stored property of `InterpretedCommand` (`LlamaCommandInterpreter.swift:89-130`)
is marked **(a)** encoder-emitted class/span, **(b)** template-rendered by code, or
**(c)** filled by a later layer. No field is silently empty.

| Field | Source | Reproduction rule |
|---|---|---|
| `action` | **(a)** intent head argmax, calibrated | one of the 12 schema-v2 raw values; `plugin` is unreachable by construction |
| `entryId` | **(c)** later layer — scheduler/list resolution | always `nil` from the encoder; T-034 `no_span_fields.entryId` |
| `contact` | **(a)** `contact` span → **(b)** clitic trim | surface copied verbatim, then `SpanNormalizer` (§7.2) |
| `time` | **(a)** `time` span | verbatim surface; `NepaliTimeParser.parse` resolves it in the handler (`NepaliTimeParser.swift:35`) |
| `medication` | **(a)** `medication` span | verbatim surface (see §15.1 — no shipped resolver) |
| `message` | **(a)** `message` span | verbatim dictated body — a *copied substring*, not generated text |
| `callType` | **(b)** derived from the `app` span | `"voice"` / `"video"` / `nil` by a closed table (§7.1) |
| `requestedApp` | **(b)** canonical app token from the `app` span | closed vocabulary, `nil` when the span is a generic method word (§7.1) |
| `topic` | **(a)** `topic` span | verbatim surface |
| `steps` | **(b)** template runbook, or **(c)** LLM | **the encoder cannot produce it** — see §7.3 |
| `pluginAction` / `pluginEntities` | **(c)** never emitted | runtime-only plugin path; the encoder never emits `.plugin` |
| `confidence` | **(a)** calibrated scalar from the intent head | post temperature scaling (§5) |
| `reply` | **(b)** template, or **(c)** LLM for Reply-class | **the encoder cannot produce free text** — see §7.3 |

### 7.1 The `app` span splits into `requestedApp` and `callType`

This is a **divergence from T-034's note** and is the design's most consequential
mapping decision. The two T-035 acceptance scenarios pull in different directions:

- *"maiya lai phone gara"* → `contact` "maiya", **`requestedApp` nil**
- *"छोरालाई वाट्सएपमा कल गर"* → `contact` "छोरा", **`requestedApp` "whatsapp"**, "as
  explicitly named by the user"

The phrase *"as explicitly named by the user"* is the discriminator, and it matches the
shipped schema's own documentation: `requestedApp` is "an app the user explicitly named
(`facetime`, `whatsapp`, `messenger`, `viber`), else null"
(`LlamaCommandInterpreter.swift:106-111`). A generic method word is not a named app.

| `app` span surface matches | → `requestedApp` | → `callType` |
|---|---|---|
| `whatsapp` / `वाट्सएप` / `ह्वाट्सएप` | `"whatsapp"` | `nil` |
| `facetime` / `फेसटाइम` | `"facetime"` | `nil` |
| `messenger` / `मेसेन्जर` / `म्यासेन्जर` | `"messenger"` | `nil` |
| `viber` / `भाइबर` | `"viber"` | `nil` |
| `phone` / `फोन` / `call` / `कल` | `nil` | `"voice"` |
| `video` / `भिडियो` / `भिडियो कल` | `nil` | `"video"` |
| anything else | `nil` | `nil` |

The matcher **reuses the shipped vocabulary** rather than inventing one:
`CallLinks.isWhatsAppName` and `isMessengerName` (`CallLinks.swift:248-251`, `:257`) and
`MethodResolver.explicitMethod`'s facetime / phone / कल branches
(`MethodResolver.swift:87-113`). Devanagari forms including the locative suffix are
handled by containment, which is how the shipped code already works
(`isWhatsAppName` uses `contains`, so "वाट्सएपमा" matches).

`requestedApp` receives a **canonical lowercase token from a closed vocabulary**, not
the verbatim span. This is a label projection, not a resolution: it names no target, no
id, no number and no URL, and its values are exactly the schema's documented examples.
Every span in the span set remains verbatim; only this one *field* is projected, and the
projection is marked (b) above.

**Consequence, recorded.** Because a generic method word now lands in `callType` and
leaves `requestedApp` nil, `MethodResolver.explicitMethod` cannot today distinguish
"the user said *phone*" from "the user named nothing" for a voice call: with
`requestedApp == nil` and `callType == "voice"`, `isVideo` is false and the app branch is
empty, so it returns `nil` (`MethodResolver.swift:88-90`). For the correction protocol
("होइन, फोन नै गर", spec §7.2 at `:445-447`) that matters. Two resolutions are named for
T-037, and this design does not pick one unilaterally:

1. **Family rule (encoder-side):** for the `corrections_overrides` family
   (`annotation_rules.yaml` `edge_classes.corrections_overrides`, action `call`), emit
   `requestedApp = "phone"` for a generic phone method word, matching T-034's example.
2. **Resolver rule (Swift-side):** teach `explicitMethod` to read `callType == "voice"`
   as an explicit voice amendment.

Either satisfies T-034's correction example; only the second also fixes the
non-correction "maiya lai phone gara" case against a contact whose default method is
WhatsApp. This is logged as integration item **I-1** in `specs/T-035-notes.md`.

### 7.2 `contact` slot normalisation (clitic trim)

T-034 pins **surface-exact** spans, including an affix merged into a token
(`डाक्टरलाई`, the T-034 Gherkin pin), while the T-035 scenario requires `contact` to be
"छोरा" for an utterance containing "छोरालाई". T-034 already flagged this as an
unresolved hand-off ("T-035/T-038 own that reconciliation").

Resolution: **the span stays verbatim; the slot value is clitic-trimmed by code.** The
encoder's span set is untouched (so the slot gates score surface-exact spans and the
training data needs no change), and a deterministic (b) step places the trimmed form in
`InterpretedCommand.contact`:

- Trim a trailing dative/accusative clitic from a `contact` span only — `लाई`, `ले`,
  `मा`, `बाट`, `सम्म`, `को`, `का`, `की` — and only when the remainder is non-empty.
- **`contact` only.** `time`, `medication`, `message`, `topic` and `app` keep their
  verbatim surface: genitive trimming inside "प्रेसरको औषधि" would corrupt a medication
  name, and `app` is handled by containment matching instead.
- The trimmed value is still a substring of the transcript, so it is still a span, not
  a resolution.
- Both forms resolve in shipped code anyway — `ContactResolver.relationshipAnchor`
  matches compounds by containment specifically for "मेरो छोरालाई"
  (`ContactResolver.swift:127-134`) — so the trim costs nothing in resolvability and
  buys eval parity with the golden corpus's resolver-ready values
  (`eval_golden.py:269-280` compares whitespace-token sets against those values, which
  is why T-033's contact F1 was 0.333).

This is a **runtime mapping rule**, not a change to T-034's data contract.

### 7.3 Fields a classifier cannot generate

Two schema-v2 fields are structurally outside a classification head, and the design
says so plainly rather than leaving them to drift:

- **`steps`** (guide runbooks) — an ordered list of short instruction strings. A
  softmax over 12 classes and a per-token 13-way tagger cannot produce it. Sources:
  **(b)** a deterministic runbook template keyed by the `topic` span (the app's
  appliance-helper content), or **(c)** the LLM long-tail path. The shipped schema
  already treats guide steps as *spoken, never executed*
  (`LlamaCommandInterpreter.swift:115-119`), which is what keeps a generated
  "step 3: open whatsapp://…" from becoming a device action.
- **`reply`** — free spoken text. The encoder cannot generate text and does not pretend
  to. For the **Reply class** (`query`, `none`, `health_query`) the spoken answer is the
  LLM's, delivered through the existing path (`CommandRouter.swift:2115`, `:2143`,
  `:2146`, `:2271-2272`, `:2398`, all gated by `sanitisedModelReply`). For the
  **Action class** the router already speaks L10n templates (`speak(key:)`, e.g.
  `:2204`), so `reply` is not load-bearing; the mapper sets a deterministic template or
  an empty string, and never fabricates an answer.

The one nuance worth stating: a `message` span *can* be arbitrary user text, but the
encoder is not *generating* it — it is copying a verbatim substring of the transcript it
consumed. Selecting is not generating, and the distinction is what keeps the no-free-text
rule honest.

## 8. Slot contract — spans in, resolution in code

**The rule.** Every slot in `InterpretedCommand` is either a verbatim substring of the
sanitised transcript or a closed-vocabulary projection of one. The encoder emits **no**
contact id, **no** phone number, **no** URL, **no** resolved time value — matching
`annotation_rules.yaml` `spans.forbidden_in_target`, which also forbids resolved values
in training targets so the model cannot learn them.

**Resolution stays in code**, unchanged and untouched by this design:

| Span | Resolver | Verified entry point |
|---|---|---|
| `contact` | `ContactResolver` | `resolve(_:)` — `ContactResolver.swift:70` (accept threshold 0.6 at `:60`) |
| `app` → method | `MethodResolver` | `resolve(contactId:requestedApp:callType:)` — `MethodResolver.swift:47`; `explicitMethod` at `:87` |
| `time` | `NepaliTimeParser` | `parse(_:)` — `NepaliTimeParser.swift:35` |
| `medication` | *(none shipped — see §15.1)* | `CommandRouter.swift:2200` uses the span as a reminder title |

**Confirm-before-execute is untouched.** The cache's own invariant already states it
("The cache bypasses INTERPRETATION only. Tier-1 confirmation still fires on every hit —
a cache hit can never dial without the usual 'हो'" — `IntentCommandCache.swift:10-13`),
and `IntentRouter.recordConfirmedExecution` writes the cache only after a confirmed,
executed command (`IntentRouter.swift:347-350`, `IntentCommandCache.swift:82-86`). A
resolved target is therefore **never** executed without tier-1 confirmation:
`call`, `send_message`, `set_reminder`, `create_calendar_event` are all
`ConfirmationTier.confirm` (`ConfirmationTier.swift:21-22`) and go through the
dual-channel yes/no flow with its 45 s timeout (spec §7.2). The encoder's output is
proposed, never executed.

## 9. Band reconciliation

`IntentRouter.Config.default` is `acceptThreshold 0.7`, `rephraseThreshold 0.4`
(`IntentRouter.swift:56-58`). `bandChecked` (`:316-330`) is the only place the bands are
applied. The encoder introduces **no new threshold**.

| Calibrated confidence | `ConfirmationTier.confirm` action | `ConfirmationTier.free` action | Encoder behaviour | Router behaviour (`bandChecked`) |
|---|---|---|---|---|
| `c ≥ 0.7` | dispatch | dispatch | return command | returns command (`:318`) |
| `0.4 ≤ c < 0.7` | dispatch **into the existing confirmation flow** | dropped for escalation, **or** returned as the rephrase question when local is final | return command | tier `.confirm` → returns command (`:320`, `:328`); tier `.free` → `nil` if escalating (`:325`) or return with `rephrase_band_question` when `final` (`:322-323`) |
| `c < 0.4` | **abstention** | **abstention** | return `nil` | would return `nil` at `:319`; the encoder abstains first so no sub-0.4 command is ever surfaced |

Three independent confirmations that 0.4 is the right abstain floor, all verified:
`IntentRouter.Config.default.rephraseThreshold == 0.4` (`IntentRouter.swift:57`),
`LocalIntentInterpreter.Config.default.confidenceThreshold == 0.4`
(`LocalIntentInterpreter.swift:47-49`), and `ConfirmationTier` for the dispatch branch.

**Abstention is not a failure.** When the encoder abstains it returns `nil` and leaves
`lastInferenceFailureReason` **unset**, mirroring the incumbent's explicit distinction
("Honest abstention — no retry, no failure", `LocalIntentInterpreter.swift:235-237`).
That keeps `IntentRouter`'s escalation honest: an abstention escalates as an open
question, while a genuine timeout escalates with `local_failed_fallback`
(`IntentRouter.swift:211-219`).

**Cache interaction.** `IntentCommandCache.isCacheable` allows exactly
`{call, music, suggest_video}` (`IntentCommandCache.swift:51-65`). Those three are the
only actions a cache hit can short-circuit, and the cache hit still goes through
`bandChecked` and tier-1 confirmation. `emergency` and `ack_med` are explicitly **not**
cacheable (`:55-57`), so the encoder's abstention can never be laundered through the
cache either.

## 10. Runtime integration — `CommandInterpreter` conformance

The encoder ships as a `CommandInterpreter` (`LlamaCommandInterpreter.swift:34-41`):

```swift
final class IntentEncoderInterpreter: CommandInterpreter, InterpreterFailureReporting {
    var isAvailable: Bool { /* artifact installed + graph loads */ }
    var lastInferenceFailureReason: String? { get }   // "inference_timeout", "span_invalid", …
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void)
}
```

`interpret` follows the incumbent's shape (`LocalIntentInterpreter.swift:92-115`):
clear the failure reason, guard `isAvailable`, `InputSanitiser.sanitise(_:level:
.quarantine)`, guard non-empty, run the forward pass off the main thread, map spans,
complete on the main queue. `completion` fires **exactly once on every path** — the
constraint `CommandRouter`'s turn-reply-pending token depends on
(`IntentRouter.swift:250-266`).

`InterpreterContext` is accepted for protocol conformance and **ignored**: the encoder's
input is the transcript alone. `context.pendingMedications` is display-name data the
head was not trained on, and feeding it would create a train/inference skew. Stated
rather than silently dropped.

### 10.1 Where it sits

The encoder is installed as `LocalBrainChain.preferred`, with `LlamaCommandInterpreter`
as `standIn` (`LocalBrainChain.swift:28-69`). That placement is what makes "artifact not
installed" fail soft **for free**: `isAvailable` is `preferred.isAvailable ||
standIn.isAvailable` (`:38-40`), and `standIn` is consulted only when `preferred` is
unavailable (`:55-69`). No `AppCoordinator` re-wiring beyond the existing brain
construction site, and **zero** changes to `IntentRouter.swift` or the keyword net.

The ladder, with the FR-007 long-tail peer made explicit:

```
keyword safety net (CommandRouter, before any model)
  → cache (IntentCommandCache, exact normalized match, cacheable actions only)
    → local encoder (this component, spans + calibrated confidence)
      → [on abstention only] incumbent local LLM (the long-tail brain, FR-007)
        → cloud brain (when configured)
          → re-prompt
```

Every rung the task names is present and in order. The LLM rung is engaged **only** on
abstention — which is exactly the case the encoder abstains for (an utterance outside
its twelve closed actions is precisely the long tail the LLM exists for). This is
integration item **I-2** for T-037: it requires one change in `LocalBrainChain` (an
abstention fall-through), not in `IntentRouter`. If T-037 rejects it, the required
ladder is still satisfied in the strict reading — keyword net → cache → local encoder →
cloud brain → re-prompt — at the cost that open-domain utterances the incumbent LLM
answers locally today would escalate to the cloud or re-prompt. That behaviour delta is
recorded rather than discovered later.

### 10.2 Determinism

The encoder has **no sampler**: one deterministic forward pass, then argmax. That is a
stronger guarantee than the LLM brains' greedy sampling, and the distinction is worth
stating precisely:

- `OnDeviceSampling` (`temperature 0`, `fixedSeed 20_260_907`,
  `LlamaCommandInterpreter.swift:261-270`) governs the **LLM** brains — the `standIn`
  and the long-tail rung. It is **not** applied to the encoder, because there is nothing
  to sample. The design does not claim to "use temperature 0"; it claims determinism by
  construction.
- **Pinned expectation:** the same input, on the same device, OS and artifact digest,
  produces the same argmax action and the same span set. The confidence may differ in
  low-order decimals, because CoreML fp16/int8 and ONNX int8 kernels accumulate
  differently across hardware and OS versions.
- **Tie-breaking is fixed:** equal logits resolve to the lowest class index; span
  decoding proceeds word-by-word in ascending order, first-subword tag wins
  (`bakeoff_encoder.py:161-165`). No nondeterministic ordering anywhere in the decode.
- **Calibration preserves the argmax** (§5), so `T` cannot introduce run-to-run class
  flapping.
- **Training determinism:** seed 42 (T-033 K7, `annotation_rules.yaml`
  `mixture.seed`), with the exact command line, dataset SHA-256, config SHA-256 and
  checkpoint digest recorded in the run manifest, as T-033 did.
- **T-038 verifies it:** run the golden corpus twice on-device against the same artifact
  digest and assert identical argmax actions and span sets.

## 11. Emergency and the abstain edge class

Both are first-class, counted, and gated.

| Class | T-034 target | Source |
|---|---|---|
| `emergency` | 1 000 (spec §9.1; **never reduced**) | `taxonomy.targets.emergency` |
| abstain edge family | 800, action `none` or the guessed action, confidence **< 0.4** (never a 13th value) | `edge_classes.abstain_low_confidence` |
| gibberish | 400, action `none`, confidence **< 0.2** | `edge_classes.gibberish_to_none` |

**Hard gates.** Emergency recall is measured by the harness on the golden corpus
(= 1.00) and on the adversarial near-miss set (≥ 0.98), per spec §10 and
`config.yaml:60`. The metric is defined on the **classifier's argmax** — a property of
the model plus its calibration — which is what makes it independent of the band policy
below. A second, *reported but not gated* metric, **dispatch recall**, records what
actually reaches the user after the bands.

**Why dispatch recall is only reported.** `ConfirmationTier.tier(for:)` returns
`.neverGated` for `emergency` and `ackMed` (`ConfirmationTier.swift:19-20`), and
`bandChecked`'s rephrase branch tests `== .confirm` (`IntentRouter.swift:320`). A
mid-band (0.4–0.7) emergency therefore does **not** take the confirm branch: it is
dropped for escalation, or returned as a rephrase question when local is final. This is
an **observed interaction in shipped code**, and this design does not change it — the
hard constraint forbids `IntentRouter` edits, and inventing a confidence floor for
emergency would be exactly the new threshold that bypasses `bandChecked`. It is logged
as open risk **R-1** for the design owner.

**The safety net makes it non-blocking in practice.** `routeSafetyNet(raw)` runs at
`CommandRouter.swift:651-653`, *before* the interpreter fast path at `:1049`, and the
comment at `:645-650` is explicit that a confident LLM answer is not sufficient reason
to skip it. It covers emergency (16 phrases, `:1403-1408`), explicit med-ack
(`:1454-1469`) and — critically — **denial before ack** (`:1443-1452`), because refusal
words contain ack words as substrings ("नखाए" ⊃ "खाए"). So:

- **A low-confidence encoder cannot suppress emergency or explicit med-ack.** Those
  utterances are answered by the keyword net before the encoder is consulted at all.
- **An abstaining encoder cannot suppress them either** — same reason.
- The encoder's contribution to the emergency gate is the recall-first class weight
  (§3.4), the §9.1 target, and the boundary-pair data T-034 specifies (`emergency` vs
  `health_query`, spec §9.4).

## 12. Failure modes

Each class names its detection, its fallback and its user-visible behaviour. **No path
ends in a wrong action.**

| # | Failure class | Detection | Fallback | User-visible behaviour |
|---|---|---|---|---|
| F-1 | `inference_timeout` | forward pass exceeds the local-leg budget | set `lastInferenceFailureReason = "inference_timeout"`, complete `nil`; `IntentRouter` escalates to cloud when configured (LAT-EVIDENCE path, `IntentRouter.swift:211-219`) | cloud answers, else the router's re-prompt. Never a wrong action |
| F-2 | `artifact_unavailable` | `isAvailable == false` (not installed, CoreML compile failure, runtime not linked) | `LocalBrainChain` falls through to `standIn` (`LocalBrainChain.swift:38-40`, `:63-68`) | the incumbent local brain answers, exactly as today |
| F-3 | `sanitised_empty` | `InputSanitiser.sanitise` returns empty | complete `nil` (the incumbent's own guard, `LocalIntentInterpreter.swift:102-105`) | the router's re-prompt |
| F-4 | `span_invalid` | decoded span fails `transcript[start:end] == text`, is out of range, or overlaps a different label's span | drop the offending span if non-critical; **abstain (`nil`)** if it is the action's required span (`contact` for call/send_message, `time` for set_reminder) | re-prompt or cloud answer. A call with an unresolved contact never proceeds to planning |
| F-5 | `span_severed_by_truncation` | the 200-char clamp (`InputSanitiser.swift:22`) cut a span | treat as F-4 for that span; abstain if it was required | re-prompt. (T-033 measured STT-noised p95 ≈ 10 tokens, so this is a designed-for edge, not a live risk) |
| F-6 | `abstention` | calibrated confidence < 0.4, or the action is outside the twelve | complete `nil` with **no** failure reason (`LocalIntentInterpreter.swift:235-237`) | escalates as an open question → cloud, else re-prompt. Not an error |
| F-7 | `low_confidence_band` | 0.4 ≤ c < 0.7 | return the command; `bandChecked` owns it (§9) | tier-`confirm`: the ordinary spoken confirmation. tier-`free`: escalation, or the rephrase question when local is final |
| F-8 | `out_of_vocabulary` (incl. plugin utterances) | best-case abstention; worst case a ≥ 0.7 score on a wrong closed class | none at the encoder — mitigated downstream | plugin utterances: the encoder has no `.plugin` class, so the plugin path is not reached through it (T-037 routes those). A confidently wrong closed action is caught by tier-1 confirmation for every side-effecting action (`ConfirmationTier.swift:21-22`) and bounded by the side-effect precision gate ≥ 0.97 (`config.yaml:61`) |
| F-9 | `graph_load_failure` | artifact digest mismatch, corrupt `.mlmodelc`, ONNX session error | `isAvailable` false → F-2 | incumbent local brain answers |

Every class is testable: F-1/F-3/F-6/F-7/F-9 by injecting a stub `CommandInterpreter`
into `IntentRouter` (the shipped test seam pattern — `generateOverride` on
`LocalIntentInterpreter.swift:62-63`); F-2/F-9 by removing the artifact; F-4/F-5/F-8
by corpus rows designed to trigger them. T-038 owns the harness-side verification.

**Ladder preserved.** keyword net → cache → local encoder → cloud brain → re-prompt, as
§10.1 shows, with the FR-007 long-tail LLM engaged on abstention only.

## 13. SetFit / slotless scoping statement

**A SetFit-style sentence-embedding + linear head cannot produce token-level BIO
spans.** The architecture pools one vector per utterance (the proposal's own sketch:
"Nepali text → sentence encoder → 384-dimensional embedding → linear classifier →
CALL_CONTACT", `docs/architecture/nepali-intent-recognition-model.md:235-249`). One
vector per utterance yields one label per utterance. There is no per-token
representation, so there is no token classification, so there are no span candidates and
no character offsets. It is a *slotless* architecture by construction, not by tuning.

T-033 reached the same conclusion independently and excluded it architecturally (C4,
"no BIO slot decoder", §7 of the bake-off), and it is plan risk 15.

Consequences, stated so the option cannot be re-proposed by accident:

- The **joint model is span/token-classification based** — intent head + BIO slot head
  over a shared encoder pass (§3.2), matching T-033's spike. No slotless architecture
  can be the joint model.
- A slotless model may exist **at most as a named slotless fast path**, and this design
  proposes **none** for TG-08's build. If one is ever added it must be named
  `IntentOnlyFastPath` (or equivalent), emit `action` + `confidence` only with all slot
  fields `nil`, be restricted to actions with no required span, be scored on
  closed-intent accuracy **alone**, and **never** report a slot F1 — it does not consume
  the joint model's slot gates and cannot inherit its results.
- It could not serve `call`, `send_message` or `set_reminder` at all (each has a
  required span), so it could never replace the joint model on the actions that matter
  most.
- The proposal's 91.1 % figure for SetFit is a *MASSIVE-style* number from a third-party
  study, not a Nepali measurement, and is not evidence for this project — the same
  discipline T-033 applied to the 82.34 % / 97.3 % claims.

## 14. Divergences from the proposal

Every divergence is deliberate and named, not silent.

| # | Proposal | This design | Why |
|---|---|---|---|
| D-1 | SetFit (sentence embedding + linear head) as a candidate architecture | scoped out of the joint model (§13), no slotless path proposed | cannot emit token-level spans |
| D-2 | Confidence bands `≥ 0.95` / `0.75–0.95` / `< 0.75` (`nepali-intent-recognition-model.md:715-733`) | shipped `≥ 0.7` accept / `0.4–0.7` rephrase / `< 0.4` abstain (`IntentRouter.swift:56-58`) | the shipped bands are wired into `bandChecked`, `ConfirmationTier` and the cache; the proposal's numbers are not this project's policy |
| D-3 | Mid-band handled by routing to Qwen to "verify the interpretation" (`:726-728`) | mid-band tier-`confirm` dispatches into the existing confirmation flow; tier-`free` escalates or becomes the rephrase question | the confirmation flow *is* the verification, with no extra round trip |
| D-4 | Resolved-value output style ("time = tomorrow 09:00") | verbatim spans, resolution in code (§8) | spec §2 "LLM proposes, code disposes"; a hallucinated `tel:` dialed is not recoverable |
| D-5 | MASSIVE-derived intent taxonomy (42 labels) | schema-v2 only; 20 proposal labels rejected by T-034, rest recoloured | T-034 §3.2; the shipped enum is the contract |
| D-6 | `ai4bharat/IndicBERT-v3-270M` as the #1 base | C3 MASSIVE MiniLM | C1 failed K1 (gated weights, 403, indirect MIT tag, Gemma-3 upstream terms) |
| D-7 | `jhu-clsp/mmBERT-small` as the production student | C3 | C2's int8 ONNX graph lost emergency recall 1.000 → 0.000 (K3); it remains a recorded *untested-remediation* fallback |
| D-8 | 256 K Gemma-family vocabulary for both leading candidates | XLM-R 250 037 sentencepiece | materially better Nepali fertility, including STT-noised (2.18 vs 2.93 tokens/word) |

## 15. Could not be grounded in shipped code

Recorded so a later reader does not mistake a spec promise for a shipped fact.

1. **`MedicationResolver` does not exist in the repository.** It appears only in spec
   §6.4 (`docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md:396`)
   and in task/plan text. Shipped medication handling is `CommandRouter.swift:2200`
   (`command.medication ?? L10n.str("reminder.defaultTitle")`, i.e. the span becomes the
   reminder *title*, with no lookup against a medication list) and
   `MedicationScheduler` (`MedicationScheduler.swift:6`, `medicationEntries()` at `:42`,
   `acknowledge(entryId:at:)` at `:86`). The design's slot contract is unaffected — the
   encoder still emits a `medication` **span**, which is the safe output either way — but
   the design does not claim a resolver that is not there. Whether the span should be
   matched against the scheduler's list is a T-037 decision.
2. **`ModelStore.installCoreMLEncoder(fromZip:for:)` is Whisper-shaped, not generic.**
   T-033 says the encoder zip matches "the exact shape `ModelStore` already accepts".
   That is true only at the container level: the method accepts a zip whose single
   top-level member is a `.mlmodelc` directory (`ModelStore.swift:217-239`), but its
   *destination* is derived from the Whisper ggml filename
   (`<stem>-encoder.mlmodelc`, `:200-204`, `:245-249`), and the only non-nil
   `coreMLEncoderBundledName` in the catalog is `ggml-small-encoder`
   (`ModelCatalog.swift:489`). An intent encoder cannot be installed through it as-is.
   T-037 owns a real install path plus a catalog entry; the design reuses the *zip
   convention* only.
3. **Android packaging and loading are new code.** T-033 §8 states plainly that ONNX
   Runtime Mobile is "not wired anywhere in this repo yet". T-037 scope.
4. **Device-class latency is UNMEASURED.** T-033 K5's numbers are desktop proxies
   (CoreML 20.5–178.6 ms on a loaded x86_64 Mac, ORT 3.25 ms). Spec §10's oldest-device
   budget (p50 ≤ 1.0 s, p95 ≤ 2.0 s) is a **requirement to verify**, not a measurement.
   T-038 owns it.
5. **Δ vs `GeminiCommandInterpreter` (within −3 pts) is UNMEASURED** — no
   `GEMINI_API_KEY` in the experiment environment (T-033). T-038 owns it.
6. **No script reads teacher per-class logprobs.** The stage-2 distillation teacher
   distribution from the incumbent LLM requires new T-036 tooling; the Gemini rows carry
   only a scalar `confidence` (§4). Stated as a construction, not a measurement.
7. **The golden corpus cannot support the calibration gate.** Twenty rows cannot fill
   ten buckets. The gate is a ship requirement against the T-036 corpus (floor 8 000
   rows), and is UNMEASURABLE today.

## 16. Open risks

| # | Risk | Impact | Owner |
|---|---|---|---|
| R-1 | Mid-band `emergency` / `ackMed` do not take `bandChecked`'s `.confirm` branch (tier is `.neverGated`, `IntentRouter.swift:320`), so a 0.4–0.7 emergency is dropped for escalation | recall at the *dispatch* level is lower than class-level recall; the keyword net covers the common forms | design owner (a router change is out of this task's scope by hard constraint) |
| R-2 | `MethodResolver` cannot see a generic voice-method amendment (`requestedApp == nil`, `callType == "voice"`) | the "होइन, फोन नै गर" correction may fall to the contact's default method | T-037 (integration item I-1) |
| R-3 | Encoder-as-`preferred` means an abstention currently escalates without consulting the incumbent LLM | open-domain utterances the LLM answers locally today may escalate to cloud or re-prompt | T-037 (integration item I-2, §10.1) |
| R-4 | `ack_med`, `create_calendar_event`, `suggest_video` have zero seed templates today | three of twelve classes are under-supplied; the per-action floor (≥ 0.25 × target) fails until T-036 adds seeds | T-036 |
| R-5 | Class weighting for emergency competes with the calibration gate | tuning both is a two-objective problem; the resolution order is fixed in §3.4 | T-036 |
| R-6 | Slot F1 gate (≥ 0.90) is far above T-033's measured 0.333 | the gate is met by T-034's alignable-by-construction data + the 13-tag head, neither of which T-033 had; unproven until T-036 trains | T-036, verified T-038 |
| R-7 | Android int8 quantization was the criterion that killed C2 | C3's int8 was decision-preserving under both ORT dynamic quantization and CoreML weight quantization (T-033 §4–§6), but a *retrained* head is a new graph | T-038 |

## 17. Definition-of-done mapping

| T-035 DoD item | Where |
|---|---|
| Encoder architecture, heads, loss, distillation objective, student size target, calibration, runtime format | §3, §4, §5 |
| Field-by-field mapping with span semantics and non-classifiable field sources | §7 (table + §7.1, §7.2, §7.3) |
| Band reconciliation tied to `IntentRouter.Config.default` and `ConfirmationTier` | §9 |
| Failure-mode table with the fallback ladder, each class testable | §12 |
| SetFit / slotless scoping statement | §13 |
| L2 §4.2 amendment produced for review (`design-l2.md` untouched) | `docs/superpowers/specs/2026-09-13-l2-4.2-amendment.md` |
