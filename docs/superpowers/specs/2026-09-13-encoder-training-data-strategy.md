# Encoder Training-Data Strategy — Schema-v2 Taxonomy + BIO Spans

- **Task:** T-034 (`.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-034-training-data-strategy.md`)
- **Branch:** `worktree-t034-training-data` (base `840bcd7`)
- **Status:** design deliverable — no training run, no model download; the strategy is
  ready for T-035/T-036 consumption.
- **Companion (machine-readable):** `tools/train-intent/annotation_rules.yaml`
  (`schema: annotation-rules/v1`). The two artifacts are the same contract; where a
  number appears in both, it is identical.
- **Inputs:** T-033 GO (`tools/train-intent/docs/T-033-encoder-bakeoff.md` §8 — base
  `cartesinus/multilingual_minilm-amazon-massive-intent`, XLM-R 250,037-vocab
  tokenizer, revision `08dc4816…`, student 100–120 M params); T-009 bundled
  Whisper (`config.yaml:stt_noise`); spec §9.1–§9.5, §10, §11
  (`docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md`); the
  shipped schema-v2 code (see §2).
- **Consumers:** T-035 (joint encoder design — span→`InterpretedCommand` mapping),
  T-036 (training & distillation pipeline — dataset builder, mixture enforcement,
  gates).

---

## 1. Purpose and scope

The encoder replaces nothing about the app's contract: it is a joint intent + slot
model whose slot output is **candidate spans**, never resolved values. This document
fixes three things the rest of TG-08 depends on:

1. which labels exist (schema v2 only — never the proposal's taxonomy),
2. how slot supervision is represented (BIO spans with character offsets, aligned to
   the T-033 tokenizer),
3. what data is admissible, in which mixture, and how coverage is measured and
   capped when supply runs short.

Out of scope by decision: the proposal's MASSIVE-derived intent list and any
"resolved value" output style. The proposal contributes **methodology only** (joint
intent+slot framing, augmentation discipline); §3.2 records the reconciliation.

## 2. Ground truth read for this strategy

| Fact | Source |
|---|---|
| 12 valid training actions | `tools/train-intent/src/build_dataset.py:69-71` (`VALID_ACTIONS`) |
| 13 `InterpretedCommand.Action` cases (12 + runtime-only `plugin`) | `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift:66-88` |
| Schema-v2 field list | spec §5 (`…intent-engine-finetuned-llm-design.md:298-303`) |
| Seed targets/templates | `tools/train-intent/seeds/intents.yaml` |
| Teacher generation | `tools/train-intent/src/gen_teacher.py` |
| STT-noise round-trip | `tools/train-intent/src/stt_noise.py` |
| Mixture keys | `tools/train-intent/config.yaml:30-36` |
| Golden corpus (held out, 20 rows) | `tools/train-intent/eval/golden_corpus.jsonl` |
| Measured supply + ack gap | `docs/OPEN-ITEMS.md:120-141`; `src/build_dataset.py:44-48` |
| T-033 tokenizer/GO | `tools/train-intent/docs/T-033-encoder-bakeoff.md` §3, §8 |
| Flywheel export | `ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift:108-123`; `IntentLogReviewView.swift:23-27` |

## 3. Taxonomy reconciliation — schema v2 wins

### 3.1 The 12 schema-v2 labels (the only legal training labels)

`schema-v2 labels == VALID_ACTIONS == InterpretedCommand.Action − {plugin}` — the
13th Swift case is a runtime-only escape hatch: core never learns plugin action
names; they travel in `pluginAction` (`LlamaCommandInterpreter.swift:82-87`, plan
risk 17). It must stay absent from every training row, prompt and tag set.

| Label | Spec §9.1 target | Seeds target today | Seeds templates? | Notes |
|---|---|---|---|---|
| `call` | 1,500 | 1,500 | yes | includes method mentions and corrections |
| `set_reminder` | 1,200 | 1,200 | yes | time-expression zoo (साढे, digits, भोलि) |
| `send_message` | 1,000 | 1,000 | yes | dictated bodies |
| `emergency` | 1,000 | 1,000 | yes | first-class; never reduced; boundary pairs vs `health_query` |
| `health_query` | 700 | 700 | yes | calm questions |
| `music` | 600 | 600 | yes | भजन/गीत only (no radio/podcast content banks) |
| `guide` | 600 | 600 | yes | topic + steps; steps are spoken, never executed |
| `query` | (1,500 with `none`) | 1,000 | yes | open-domain reply-only |
| `none` | (with `query`) | 500 | yes | chit-chat/particles; abstain and refusals add to this class |
| `ack_med` | 800 | **absent** | **no** | measured gap — §6.2 |
| `create_calendar_event` | not listed | absent | **no** | shipped action (honest stub, `CommandRouter.swift:2135-2142`); target 600 proposed here |
| `suggest_video` | not listed | absent | **no** | shipped action (same stub); cacheable (`IntentCommandCache.swift:53`); target 500 proposed here |

Edge classes are **not** extra action values — they are labelled rows inside the 12
(§6). Seed totals: 9,700 + ack_med 800 + calendar 600 + video 500 = **11,600** rows,
the same order as the spec's "~11k". Targets are teacher-expansion targets; measured
supply is a different number (§5.4).

### 3.2 Reconciliation table — every proposal borrowing, and its decision

Left column: labels appearing in the proposal material
(`docs/architecture/nepali-intent-recognition-model.md:174-210` MASSIVE examples;
`:397-425` its own smaller taxonomy sketch). None of them is ever a training label.
The column "decision" is one of **recoloured** (behaviour lives under a schema-v2
label), **rejected** (no schema-v2 home — must not be forced onto a label), or
**not-a-label** (runtime/internal). These names must not appear in any training
file, span tag set or generator prompt.

| Proposal label | Decision | Schema-v2 home / reason |
|---|---|---|
| `alarm_set` | recoloured | `set_reminder` — the only time-based reminder action; no alarm UI exists |
| `alarm_remove`, `alarm_query` | rejected | no cancel/query-reminders action; cancellation is the confirmation flow's tier-1 denial, not an intent |
| `calendar_set` | recoloured | `create_calendar_event` |
| `calendar_query` | recoloured | `query` (reply-only; no calendar-read action) |
| `calendar_remove` | rejected | no calendar-cancel action |
| `email_sendemail` | recoloured | `send_message` — single message channel (native compose sheet / WhatsApp pre-fill); no email channel |
| `email_query` | rejected | no email-read path |
| `weather_query`, `news_query`, `datetime_query` | recoloured | `query` |
| `lists_createoradd`, `lists_query`, `lists_remove` | rejected | no list feature in schema v2 |
| `audio_volume_up`, `audio_volume_down`, `audio_volume_mute` | rejected | no media-control action; `music` opens an agreed playback target only |
| `play_music` | recoloured | `music` |
| `play_radio`, `play_podcasts` | recoloured with supply limit | `music`, but **no content banks exist** for radio/podcasts — do not fabricate content names; only भजन/गीत/bhajan banks are legal until T-036 adds one |
| `transport_taxi`, `transport_query` | rejected | out of product scope |
| `CALL_CONTACT` | recoloured | `call` |
| `CALL_BACK` | recoloured | `call` (contact resolution from history is a resolver concern, not a class) |
| `ANSWER_CALL` | rejected | no call-answering capability |
| `SEND_MESSAGE` | recoloured | `send_message` |
| `READ_MESSAGE` | rejected | no read-aloud action in schema v2 |
| `REPLY_MESSAGE` | recoloured | `send_message` |
| `CHECK_MISSED_CALLS` | rejected | no missed-call surface |
| `SET_REMINDER` | recoloured | `set_reminder` |
| `LIST_REMINDERS` | rejected | no read-reminders action (`entryId` is a later-layer field, not a class) |
| `CANCEL_REMINDER` | rejected | cancellation = confirmation-flow denial |
| `CHECK_TIME`, `CHECK_DATE`, `CHECK_WEATHER` | recoloured | `query` |
| `OPEN_APP` | rejected | no app-launch action; `guide` covers how-to; plugins are runtime-only |
| `GENERAL_QUESTION` | recoloured | `query` |
| `CASUAL_CHAT` | recoloured | `query` (reply-only); empty backchannel ("हँ", "अहो") is `none` |
| `HELP` | recoloured | **`emergency`** — recall-first: any plea for help is emergency (spec §9.4; the shipped cloud prompt's rule) |
| `REPEAT` | rejected | no repeat action; the two-speech pattern and confirmation flow re-prompt |
| `CANCEL` | rejected | confirmation-flow denial, not an intent |
| `UNKNOWN` | recoloured | `none` (the abstain edge family, §6.1) |
| `plugin` (Swift case) | not-a-label | runtime-only; absent from `VALID_ACTIONS` and from all training data |

**Labels that could not map cleanly (20):** `alarm_remove`, `alarm_query`,
`calendar_remove`, `email_query`, `lists_createoradd`, `lists_query`, `lists_remove`,
`audio_volume_up/down/mute`, `transport_taxi`, `transport_query`, `ANSWER_CALL`,
`READ_MESSAGE`, `CHECK_MISSED_CALLS`, `LIST_REMINDERS`, `CANCEL_REMINDER`,
`OPEN_APP`, `REPEAT`, `CANCEL`. **Decision taken for each:** rejected as training
labels; the utterances stay in scope for the cloud/LLM long-tail path, and none is
forced onto a schema-v2 label. Two recolourings carry a caveat: `HELP`→`emergency`
(safety-first; see below) and `play_radio/play_podcasts`→`music` with a content-bank
supply limit.

Two hidden gaps surfaced during reconciliation and are fixed by this strategy:
`create_calendar_event` and `suggest_video` are shipped actions (honest "not yet"
stubs) with **zero seed templates**, and `ack_med` — spec §9.1 target 800 — has
**zero seeds and zero generated rows** (measured: `build_dataset.py:44-48`). All
three get targets and must be added to `seeds/intents.yaml` before the first T-036
build (or explicitly waived in a recorded decision).

## 4. Slot supervision — BIO spans, never resolved values

### 4.1 Span label set (every slot schema v2 can carry)

| Span label | Schema-v2 field(s) | Surface examples |
|---|---|---|
| `contact` | `contact` | माइया, छोरा, didi, सुनितालाई (merged affix — §4.4) |
| `time` | `time` | भोलि बिहान नौ बजे, साढे ८, बिहान ८ बजे |
| `medication` | `medication` | औषधि, प्रेसरको औषधि |
| `message` | `message` | आज भेट्नुहोस् (dictated body) |
| `topic` | `topic` | माइक्रोवेभ, टिभी रिमोट |
| `app` | `requestedApp` + `callType` | वाट्सएप, फेसटाइम, फोन, भिडियो कल |

Fields with **no span** and their stated source (T-035 completes the field map):
`entryId` (later layer — scheduler/list resolution), `steps` and `reply` (template or
LLM fallback), `confidence` (calibrated scalar head), `callType` (derived from the
`app` span by T-035's mapping, e.g. भिडियो → video), `pluginAction`/`pluginEntities`
(runtime-only). The encoder cannot generate free text and does not pretend to.

BIO tag set: `O` + `B-`/`I-` for each of the 6 labels = **13 tags**
(`annotation_rules.yaml` `spans.bio.tags`). The target of a row is exactly
`{action, spans, confidence}`; nothing else is supervised.

### 4.2 Offset convention

- Unit: **Unicode scalar (code point) offsets**, zero-based, half-open `[start, end)`.
  Invariant: `utterance[start:end] == text`.
- Offsets are into the exact string the encoder consumes — for STT-noised rows, the
  noised transcript, not the clean one.
- Swift-side note (pinned regression): offsets must be converted via
  `unicodeScalars`, never `Character` counts or `String.Index(utf16Offset:)` —
  Devanagari clusters make grapheme arithmetic wrong for span math.

### 4.3 Tokenizer alignment rule (matches T-033's C3 tokenizer)

Tokenizer: the XLM-R sentencepiece shipped with
`cartesinus/multilingual_minilm-amazon-massive-intent` — **250,037 vocab**,
revision `08dc481605729de194f9139713d4eb20f4b80706` (T-033 §8). The rule is
**word-first annotation, offset-mapped to subword tokens** (not "tag whatever
substring of a subword happens to match"):

1. Words = maximal non-whitespace runs of the exact utterance, code-point intervals
   `[a_i, b_i)`, ascending.
2. Word tag: the **first word intersecting** a span gets `B-<label>`; every later
   word intersecting it gets `I-<label>`; all other words are `O`. This mirrors the
   spike's `bakeoff_encoder.bio_tags` (word-level, char-interval overlap).
3. Tokenize the exact utterance with the T-033 tokenizer:
   `add_special_tokens=true`, `return_offsets_mapping=true`.
4. Assign each subword token with offset `[p, q)`, `q > p`, to the word it
   intersects. Special/zero-width tokens get `label_id = -100` and are excluded from
   the slot loss.
5. Project: first subword of a `B`-word → `B-<label>`; its remaining subwords →
   `I-<label>`; every subword of an `I`-word → `I-<label>`; subwords of an `O`-word
   → `O`.
6. Decode: a run of `B`/`I` tags of one label becomes the char interval
   `[start(first token), end(last token))` from the offset mapping, surface
   `utterance[start:end]`. Never concatenate decoded token strings — the
   sentencepiece `▁` marker must not leak into a span.

**Masking policy change from T-033.** The spike masked the slot loss for the ~35% of
rows whose slot strings were not verbatim-alignable (contact 1,374/2,088, time
449/709 — T-033 §4 K6 note), which is why its contact F1 was 0.333. T-034 makes
alignability an **authoring invariant**: spans are substrings of the row's own
utterance by construction; non-alignable rows are refused at build time and counted,
never silently masked (special tokens excepted).

### 4.4 Whole-word merges and particle boundaries

Whisper merges words ("माइया लाई" → "माइयालाई") and sometimes separates affixes. The
rule is token-aligned and surface-exact:

- an affix merged into the same token **stays inside the span** (`डाक्टरलाई` — the
  T-034 Gherkin pin);
- a case particle the STT emitted as its **own token is excluded** ("माइया लाई" →
  span `माइया`);
- a span that cannot be recovered as a contiguous run of tokens is a data error →
  refuse the row.

This is consistent with resolution in code: `ContactResolver` normalizes and matches
by containment specifically for compounds like "मेरो छोरालाई ... with the dative
suffix attached" (`ContactResolver.swift:127-134`); the encoder never splits merged
tokens and never resolves.

### 4.5 Under STT noise: re-annotate, never inherit

`stt_noise.py` copies the parent row's label **and slot strings** onto the noisy
transcript (`stt_noise.py:138-145`). That copy is auxiliary provenance only. For
encoder training:

1. Run the annotation pass **on the noised transcript itself** (offsets into that
   string).
2. A clean entity whose surface survives — merged, split, or script-drifted — is
   re-spanned at its noised offsets.
3. If the noised text no longer supports the action's trigger (call: method/contact
   word; set_reminder: time or medication; send_message: message verb or dictated
   body; ack_med: med word or ack verb), **drop or teacher-relabel** the row and
   count it (`relabel_or_drop`).
4. If only a non-critical span's material is gone, omit that span and keep the
   action when a trigger survives.
5. **Emergency is never dropped for surface loss** — recall-first.
6. Register-specific behaviour: merged word → the span is authored over the merged
   token (`माइयालाई`); dropped particle → the span is shorter; wrong script → the
   span surface follows the noised script, the label does not change.

The T-033 spike already measured why this matters: `noised.jsonl` holds 29,304 rows
but only 2,458 distinct utterances, and 703 distinct texts carry contradictory
labels across their copies — the build drops those rather than teaching an arbitrary
label (`docs/OPEN-ITEMS.md:136-141`, `build_dataset.py:173-198`).

### 4.6 Row format (encoder BIO) + validation

```jsonc
{
  "id": "…", "utterance": "…", "action": "call", "register": "devanagari",
  "source": "teacher:devanagari", "confidence": 0.92,
  "spans": [{"label": "contact", "text": "माइया", "start": 0, "end": 5},
            {"label": "app", "text": "फोन", "start": 10, "end": 13}],
  "slots": {"contact": "माइया", "requestedApp": "फोन", "time": null, "medication": null,
            "message": null, "topic": null, "callType": null}
}
```

Required checks (T-036 extends `build_dataset.py`'s row guard to this format; each
failure increments a named counter in the build report):

- `utterance[start:end] == text`; `0 <= start < end <= len(utterance)`;
- spans of different labels never overlap; same-label adjacent spans merged at
  authoring;
- every non-null slot string equals one of the row's span texts (slots are derived
  from spans — a free-floating string is a resolved value and is refused);
- no resolved value in the target: URLs, phone-number digit runs, contact ids/UUIDs,
  or clock times ("09:00") that do not appear verbatim in the utterance;
- `action in VALID_ACTIONS`; every tag in the 13-tag set;
- `ack_med` rows containing a refusal marker (छैन, होइन, नाइँ, खाइनँ, पछि) are
  refused — refusal must never fire ack (§6.2);
- the golden-corpus leak guard is preserved for the BIO row format (normalized
  membership refusal, refusal count reported — §7).

### 4.7 Worked examples

Offsets below are computed on the exact strings (code points). The noised strings are
illustrative re-annotations of the measured noise classes; T-036 derives them from
`data/noised.jsonl` and re-runs the same rules.

**`call` — clean / romanised / noised (whole-word merge):**

| Form | Utterance | Spans (label, text, start–end) |
|---|---|---|
| clean Devanagari | `माइया लाई फोन गर` | `contact` "माइया" 0–5; `app` "फोन" 10–13 |
| romanised | `maiya lai phone gara` | `contact` "maiya" 0–5; `app` "phone" 10–15 |
| noised (merge) | `माइयालाई फोन गर` | `contact` "माइयालाई" 0–8; `app` "फोन" 9–12 |

**`set_reminder` — clean / romanised / noised (digit substitution + name misspelling):**

| Form | Utterance | Spans |
|---|---|---|
| clean Devanagari | `भोलि बिहान नौ बजे डाक्टरलाई फोन गर्न सम्झाइदिनु` | `time` "भोलि बिहान नौ बजे" 0–17; `contact` "डाक्टरलाई" 18–27 |
| romanised | `bholi bihana nau baje doctor lai phone garna samjhaidinu` | `time` "bholi bihana nau baje" 0–21; `contact` "doctor" 22–28 |
| noised | `भोलि बिहान ९ बजे डाक्टरलई फोन गर्न सम्झाइदिनु` | `time` "भोलि बिहान ९ बजे" 0–16; `contact` "डाक्टरलई" 17–25 |

The clean row is the Gherkin pin. The embedded method "फोन" is deliberately **not**
spanned: v1 rule — non-method actions do not supervise `app` spans, so the encoder is
never taught to hand a `requestedApp` to an action the schema cannot carry.

**`emergency` — clean / romanised / noised (spanless, never dropped):**

| Form | Utterance | Spans |
|---|---|---|
| clean | `मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ` | none |
| romanised | `madat garnus, malai mirgaula dukheko chha` | none |
| noised | `मदत गर्नुस मलाई मिर्गौला दुख्यो` | none |

**One row per remaining span label** (from the golden corpus's own utterances, so the
annotation rule and the eval fixture can be checked against each other):

| Label | Utterance | Span |
|---|---|---|
| `medication` (+`time`) | `बिहान ८ बजे औषधि खान सम्झाउनु` | `time` "बिहान ८ बजे" 0–11; `medication` "औषधि" 12–16 |
| `message` (+`contact`) | `सुनितालाई आज भेट्नुहोस् भनेर मेसेज पठाउ` | `contact` "सुनितालाई" 0–9; `message` "आज भेट्नुहोस्" 10–23 |
| `topic` | `माइक्रोवेभमा चिया कसरी तताउने` | `topic` "माइक्रोवेभमा" 0–12 |
| `app` (correction) | `होइन, फोन नै गर` | `app` "फोन" 6–9 → `requestedApp` "phone" via T-035 |

**Eval-contract note.** `eval_golden.py` scores slot F1 on whitespace-token sets
(`eval_golden.py:269-279`) against the golden corpus's **resolver-ready** slot values
(e.g. contact "माइया" for the utterance "माइयालाई फोन गर", gc-call-001). Surface-exact
spans therefore need span→slot normalization before comparison; T-033 pre-registered
low contact F1 as a T-035 design input (`docs/T-033-encoder-bakeoff.md` K6 note). This
is a cross-task requirement, not a defect of the data rules.

## 5. Register + STT-noise coverage

### 5.1 Mixture and register map

The 60/25/15 targets already exist as `config.yaml:mixture` keys
(`stt_noised: 0.60`, `clean_devanagari: 0.25`, `romanized_codeswitched: 0.15`; plus
`valid_fraction: 0.05`, `seed: 42`). Registers are the teacher's
(`gen_teacher.py:287-288`: devanagari, romanized, code_switched, elder_fragmented);
the bucket map is `build_dataset.py:77-82` (elder_fragmented counts as clean
Devanagari-script). Ratio is measured at row level over the kept train+valid pool;
edge rows are counted in their register bucket but exempt from sampling (§5.3).

### 5.2 Measurement plan

Reported by the build (`build_dataset.py:245-265`, extended by T-036) and recorded in
the T-036 run manifest — counters and hashes only, **no utterance content (NFR-016)**:

- achieved share per bucket vs target, with Δ and `SUPPLY-CAPPED` flags;
- per-register breakdown **inside** `stt_noised` (Whisper's parent register, as
  T-033's fertility table did);
- supply and cap per bucket; per-action counts vs `taxonomy.targets`;
- edge-class counts per family (abstain / gibberish / corrections / ack positives /
  refusals);
- span-bearing rows per span label and per register;
- leak refusals, schema refusals, label-conflict drops, `dup_clean` drops (existing
  counters, preserved);
- distinct noised utterances vs raw noised rows (the convergence measure).

### 5.3 Supply caps and floors

`stt_noised` anchors the total (it is the scarce, runtime-critical bucket,
`build_dataset.py:216-231`); the clean buckets are sampled toward their shares and
capped by supply. Policy:

- **Never pad.** A capped bucket is reported, not duplicated into.
- **Never renormalise silently.** If a clean bucket runs short, the shortfall is
  reported and top-up is preferred (more teacher paraphrase / more piper noise
  variants); the ratio is only ever allowed to drift *up* for `stt_noised`.
- **Edge rows are never sampled away** — `edge_cases:*` **and**
  `teacher:<edge_class>:*` sources are priority-kept in every bucket; ≥ 90% stay in
  train, valid keeps ≥ 1 per family where supply allows.
- **Floors** (T-036 hold rules): `stt_noised` share ≥ 0.55 — below this, regenerate
  noised data before training; per action ≥ 0.25 × target after sampling — an action
  at zero rows must be topped up or waived in a recorded decision; corpus floor
  8,000 rows (round 2 ran at 2,827 and was under-trained per `docs/OPEN-ITEMS.md`).
- Emergency is never a bucket-slack absorber: ≥ 1,000 emergency rows including the
  adversarial near-miss pairs, and the §10 recall gate is the real gate.

### 5.4 Measured supply today (honesty note)

From `docs/OPEN-ITEMS.md:120-141` (round-2 build, 2026-09-07): 2,827 kept rows =
1,696 stt_noised (60.0%) + 707 clean Devanagari (25.0%) + 424 romanized/CS (15.0%);
the noised file had 29,304 rows but only 2,458 distinct utterances (≈ 12 copies per
text; 703 conflicting-label keys dropped); `teacher.jsonl` had ~14.3k distinct rows
and **0 ack_med**. Targets in §3.1 are therefore *topping-up targets*: T-036 must
grow the noised axis (more teacher rows, `variants_per_utterance` > 2, the v5
Whisper noted in OPEN-ITEMS) before it can reach ~11.6k rows.

## 6. Edge classes and the ack_med gap

### 6.1 Abstention, gibberish, corrections

| Family | Label rule | Target | Sources |
|---|---|---|---|
| abstain_low_confidence | action `none` **or the guessed action**, confidence **< 0.4**; never a 13th action value | 800 | `seeds/intents.yaml:87-97` + `gen_teacher.py` EDGE_PROMPTS |
| gibberish_to_none | action `none`, confidence **< 0.2** | 400 | teacher-from-scratch (`gen_teacher.py:202-218`) + noisy transcripts |
| corrections_overrides | action `call`, confidence 0.8–0.95, amended method spanned as `app` | 400 | `seeds/intents.yaml:103-113`; "होइन, फोन नै गर" → `app` "फोन" 6–9 → `requestedApp` "phone" (T-035 mapping) |

Required fixes found while writing this strategy (T-036 scope, exact locations):

- `gen_teacher.edge_ok` accepts abstain at `conf < 0.5` (`gen_teacher.py:255-256`)
  while the seeds and this strategy pin **< 0.4**; and gibberish at `conf < 0.3`
  (`:257-258`) while both pin **< 0.2**. Tighten the validator to the pinned bands.
- `build_dataset.py`'s edge-priority match only covers `edge_cases:*`
  (`:222-231`); the teacher-generated edge families
  (`teacher:abstain_low_confidence:*` etc.) fall into the clean buckets and **can be
  sampled away**, violating "edge rows are never sampled away". Extend the priority
  match to the edge-class source prefixes.

Both families are training mixture rows, not new classes: the 12-value action space
is unchanged, and the shipped bands (accept ≥ 0.7 / rephrase 0.4–0.7 / abstain < 0.4,
`IntentRouter.Config.default`) stay the only thresholds.

### 6.2 The ack_med gap (measured, closed here)

`build_dataset.py:44-48` records the measurement: **`teacher.jsonl` produced 0
ack_med rows because the seed taxonomy never defined the intent**, and the round-1
ack gates failed because ack was never taught. `docs/OPEN-ITEMS.md:127-133`
independently records the same finding plus `data/edge_cases.jsonl` (server-only, 57
rows, always kept) as the stopgap. The strategy closes it:

- **Sources.** (1) Add an `ack_med` intent to `seeds/intents.yaml` with positive
  templates (औषधि खाएँ / खाइसकें / लिएँ …) so `gen_teacher.py` expands it across all
  four registers; (2) a refusal family inside the same seed block ("औषधि खाएको छैन",
  "खाइनँ", "पछि खान्छु") labelled `none`; (3) continue admitting
  `data/edge_cases.jsonl` until the seeds carry the family (it is priority-kept
  today).
- **Targets.** 800 rows total (spec §9.1): ≥ 500 ack positives (`action: ack_med`) +
  ≥ 300 refusals (`action: none`).
- **"Refusal must not fire ack."** Refusal text contains ack substrings ("खाए" inside
  "खाएको छैन") — the golden corpus pins exactly this (gc-ack-002, "REFUSAL — खाए sits
  inside खाएको छैन; must never parse as ack_med"). The build refuses any `ack_med`
  row containing a refusal marker (छैन/होइन/नाइँ/खाइनँ/पछि) and counts the refusal.
  Refusals are adversarially close by design, not noise.
- **Corrections keep their schema-v2 meaning.** "होइन, फोन नै गर" is `call` with the
  amended method span — never a rejection class; T-035 maps the span to
  `requestedApp` ("फोन" → phone).

## 7. Corpus governance

- **Golden corpus is held out.** `eval/golden_corpus.jsonl` (20 rows) is never
  trained on; `build_dataset.py` refuses any row whose *normalized* utterance
  (NFC, digits folded, punctuation stripped, lowercased — mirroring the app's
  `NepaliTextNormalizer`) appears in it, counts the refusal and prints a NOTE
  (`build_dataset.py:120-124, 159-160, 264-265`). The guard is preserved for the BIO
  row format, and T-036's DoD additionally fails any run that passes the corpus as a
  training input.
- **Real user utterances only via explicit-consent export.** The flywheel path is
  `IntentLogStore` (encrypted, on-device) → family review screen → deliberate export
  (`IntentLogReviewView.swift:23-27` ShareLink on `IntentLogStore.exportURL()`,
  `IntentLogStore.swift:108-123`) → next training batch (spec §11). Admission rules:
  no pipeline stage reads on-device log content except the exported bundle
  (NFR-015); the run manifest records the bundle's **opaque export reference**, never
  its content; the bundle is used only for consented correction/gold sampling.
  **Divergence recorded, not hidden:** spec §11 calls the bundle *encrypted*, while
  the shipped `exportURL()` writes plaintext JSONL into the app's tmp directory and
  hands it to the share sheet — encryption is a producer-side gap. T-036 must refuse
  a bundle with no consent/export record and flag the encryption gap rather than
  silently ingesting; flipping the export to an encrypted container is a
  device-side follow-up outside this task.
- **PII (NFR-016).** Seeds and synthetic rows only; no utterance content, contact
  names, message bodies, health values or bundle content in logs, build reports,
  manifests or eval fixtures. Counters and hashes only.

## 8. Teacher and STT-noise pins (unchanged patterns)

- **Teacher stays `src/gen_teacher.py`** with Gemini as the training-time teacher —
  `config.yaml:gemini.model` (currently `gemini-2.5-flash-lite`; the README's
  "Gemini 2.5 Flash" wording is stale, the config value is the source of truth).
  Training-time cloud teacher + inference-time on-device-only is the approved split
  (FR-007). **No local Qwen teacher is introduced.**
- **STT noise stays `src/stt_noise.py`**: piper TTS (`stt_noise.tts_voice`,
  hi_IN-pratham — nearest to ne) → the app's actual bundled Whisper (T-009;
  `whisper-medium-ne-q5_1.bin`, HF twin under `stt_noise.hf_model`) → noisy
  transcript. Rows keep `source: stt_noise:<parent_register>`, id
  `<parent_id>:noise<n>`, `clean_utterance`; labels stay the parent's action while
  spans and slot strings are recomputed on the noised text (§4.5) — the inherited
  copies are provenance only.

## 9. Requirements handed to T-035 / T-036

- **T-035:** treat `spans` as the slot contract; map span → `InterpretedCommand`
  fields per action (`app` → `requestedApp`/`callType`), with resolution staying in
  `ContactResolver` / `MethodResolver` / `NepaliTimeParser` / `MedicationResolver`;
  normalize surface-exact spans before comparison with the golden corpus's
  resolver-ready slot values (§4.7 note); confirm the field map for `entryId`/`steps`.
- **T-036:** load `tools/train-intent/annotation_rules.yaml`; extend
  `build_dataset.py` to the BIO row format and its validation rules; tighten the
  `edge_ok` bands; extend edge priority-keeping; add `ack_med`,
  `create_calendar_event` and `suggest_video` to `seeds/intents.yaml`; enforce the
  mixture floors/caps and record the measurement block; keep the leak guard and
  NFR-015/NFR-016 discipline.

## 10. Contradictions found between the task's assumptions and the real code

1. **`ack_med` is absent from `seeds/intents.yaml`** — not just "under-supplied": the
   intent does not exist in the seed taxonomy, so the teacher never generates it
   (measured in `build_dataset.py:44-48`; OPEN-ITEMS:127-133). Handled in §6.2.
2. **`create_calendar_event` and `suggest_video` have no seeds and no spec §9.1
   target** even though they are shipped actions with honest stubs. This strategy
   proposes 600/500 targets; T-036 must implement or waive.
3. **Edge rows are not all protected from sampling.** "Edge rows are never sampled
   away" is only true for `edge_cases:*` today; teacher-born edge rows are sampled
   like ordinary clean rows. T-036 fix named in §6.1.
4. **The abstain/gibberish confidence bands disagree between the seed notes (< 0.4 /
   < 0.2) and `gen_teacher.edge_ok` (< 0.5 / < 0.3)** — and the abstain *prompt*
   text says "< 0.4" while its validator accepts < 0.5. T-036 fix named in §6.1.
5. **T-033's slot supervision was lossy** (masked ~35% of slot rows because slot
   strings were not verbatim-alignable), which is why its contact F1 was 0.333; the
   BIO row format makes that impossible by construction (authoring invariant + build
   refusal), but the *eval* still compares resolver-ready golden values against
   surface spans — a T-035/T-038 normalization step, recorded in §4.7.
6. **Spec §11 says "encrypted bundle"; `IntentLogStore.exportURL()` writes plaintext
   JSONL to tmp.** Recorded in §7 with the T-036 refusal rule.
7. **`README.md:8` says the teacher is "Gemini 2.5 Flash" while `config.yaml:7` is
   `gemini-2.5-flash-lite`.** Config is the source of truth; recorded here so the
   stale README is not cargo-culted into T-036 configs.
8. **`noised.jsonl`'s slot strings are inherited from the clean row** — using them as
   supervision would teach resolved/wrong surfaces on the noisy transcript. §4.5
   forbids that use.

## 11. Definition-of-done mapping

| DoD item | Where |
|---|---|
| Taxonomy mapping table; every label resolves to schema v2; emergency + abstain counted | §3.1, §3.2 (YAML `taxonomy`, `edge_classes`) |
| BIO scheme, tokenizer alignment, offsets, under-noise policy | §4 (YAML `spans`) |
| Register + STT-noise targets, measurement plan, supply caps | §5 (YAML `mixture`) |
| ack_med/refusal + corrections rules with sources and targets | §6 (YAML `edge_classes`) |
| Governance: golden corpus held out; consented export only | §7 (YAML `governance`) |
| Worked span examples for call/set_reminder/emergency across clean, romanised, noised | §4.7 (YAML `examples`) |
| No PII in logs | §7 (NFR-016); all examples are seed/synthetic rows |
