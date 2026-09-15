# Linguistic Robustness — Word Order, Dialect, Accent, Style, Degradation

**Task group:** TG-11 (T-061–T-069) · **Status:** design, doc-only · **Date:** 2026-09-15
**Base:** `master` @ `41daeb6`, worktree `.claude/worktrees/tg11-robustness` (branch `worktree-tg11-robustness`)
**Consumes:** the T-034 annotation rules (`tools/train-intent/annotation_rules.yaml`, schema `annotation-rules/v1`), the T-035 contract (`tools/train-intent/encoder_contract.yaml`, schema `encoder-contract/v1`), the T-038 harness (`tools/train-intent/src/eval_golden.py`), the T-036 data build (`tools/train-intent/src/build_encoder_dataset.py`)
**Changes no label, no gate number and no pinned corpus row.** The 189 hand rows and the 7,811 generated rows of `eval/golden_corpus.jsonl` stay byte-identical; everything this group adds is a new file with its own revision tag.

---

## 1. Purpose and scope

The intent encoder recognises intent from token spans over a Nepali transcript. It was trained — and today it is only measured — on utterances whose word order is the one the authoring templates emit: **content words first, grammatical tail last**, which is the unmarked SOV order of Nepali. Two requirements say that is not enough:

1. **Order insensitivity where the semantics ride on content words.** "भोलिको मौसम कस्तो छ" must classify as a weather question with `भोलि` recognised as the time material, because the content words carry the meaning and the tail ("कस्तो छ") is decoration. The same must hold when the tail is not final.
2. **Disambiguation of accents, dialects and speaking styles.** Nepali is SOV; the user contrasts it explicitly with English SVO. A speaker of Eastern or Terai Nepali, or an elder who speaks telegraphically, must not lose the intent the standard-form speaker gets.

This design answers both with machinery that already exists and is already guarded: a deterministic permutation scheme over the pinned corpus, an orthogonal `dialect`/`style` axis for the annotation rules, and a **family of five measured robustness gates** in the T-038 harness — word order, dialect, additive noise (an SNR ladder), reduced articulation (clipped tail and a slur proxy), and accent (multi-voice, conditional). Every one of them is a *measured* property with a named fixture revision, a justified threshold, and a failing fixture proving the gate trips in isolation; anything that cannot be measured on the current corpus is recorded as a gap with the data it needs, never as a claim (§7.8).

**What this group is not.** It is not a new taxonomy (the 12 labels are closed — `annotation_rules.yaml:31-43`, and no label outside them may appear anywhere, `:9-11`). It is not a dialect classifier (no new head, no new logit, and the logit order stays a contract — `encoder_contract.yaml:58-98`). It is not a user-facing dialect selector (no new setting, so NFR-023/NFR-024's externalisation duty is untouched). And it does not retrain anything as part of this document: T-061 measures the current artifact, and whether the group's augmentation is worth a retrain is a recorded decision, not an assumption.

---

## 2. Ground truth read for this design

Every claim below was read in this worktree before being written. The load-bearing citations:

| Artifact | What it pins |
|---|---|
| `tools/train-intent/annotation_rules.yaml:31-43` | the closed 12-label taxonomy; `:9-11` forbids any label outside it |
| `annotation_rules.yaml:82-88` | the six span labels — the *only* supervised content notion |
| `annotation_rules.yaml:105-109` | BIO, 13 tags, no BILUO — the per-token supervision shape |
| `annotation_rules.yaml:117-145` | word-first alignment; `:131-134` "a span that is not recoverable as a contiguous run of tokens is a data error → refuse the row"; `:135-139` whole-word merges |
| `annotation_rules.yaml:146-158` | `under_noise`: re-annotate on the noised text, never inherit |
| `annotation_rules.yaml:159-165` | the row format, and `target: {action, spans, confidence}` — the only supervised fields |
| `annotation_rules.yaml:170-180` | the validation list a row must satisfy |
| `annotation_rules.yaml:207-216` | the mixture buckets and the four registers: `devanagari, romanized, code_switched, elder_fragmented` (no dialect axis exists) |
| `annotation_rules.yaml:217-232` | edge exemptions, supply caps, `hard_floor_stt_noised: 0.55`, `per_action_floor`, `corpus_floor: 8000` |
| `annotation_rules.yaml:267-273` | the noise pass: piper TTS → the shipped Whisper, `variants_per_utterance: 2`, one voice |
| `encoder_contract.yaml:27-49` | the base, the tokenizer revision, the 100–120M student, 117,506,432 encoder-body params |
| `encoder_contract.yaml:51-98` | the logit orders are a contract; reordering requires retraining, not a metadata edit |
| `encoder_contract.yaml:136-145` | slot `offsets.unit: unicode_scalar`, `invariant: transcript[start:end] == text` |
| `encoder_contract.yaml:226-243` | contact clitic trim; `span_set_unchanged: true` |
| `encoder_contract.yaml:296-301` | graph inputs `[1, "<=64"]` — `max_len` 64 is a hard truncation window |
| `encoder_contract.yaml:363-408` | the nine failure modes, incl. F-4 `span_invalid` and F-5 `span_severed_by_truncation` |
| `encoder_contract.yaml:433-454` | the eight gates, `gate_passed: false`, and the unmeasured list |
| `tools/train-intent/config.yaml:56-69` | the gate values the harness reads |
| `tools/train-intent/src/eval_golden.py:101-110` | `CLOSED_INTENTS`, `SPAN_LABELS`, `SCRIPT_MARKERS`, `NEARMISS_KINDS` |
| `eval_golden.py:345-410` | `load_rows` / `validate_rows` — the structural gate every fixture passes |
| `eval_golden.py:476-502` | `nearmiss_stats` — the shape a new paired metric should follow |
| `eval_golden.py:505-537` | `read_gemini_baseline` — the `@<hash8>` corpus-revision binding |
| `eval_golden.py:606` | `corpus_tag = sha256(corpus)[:8]` — the tag moves if the corpus file changes |
| `eval_golden.py:573-587` | the CLI defaults (`--corpus`, `--nearmiss`) a new fixture must mirror |
| `eval_golden.py:821-839, 895-898` | the gate dict and the non-zero exit |
| `eval_golden.py:848-893` | the run manifest — additive, so new metrics fit |
| `tools/train-intent/src/build_dataset.py:88-106` | `normalize` — the leak key, never re-implemented |
| `build_dataset.py:120-134` | `load_golden_keys(*paths)` — the leak guard takes **explicit file paths** |
| `build_dataset.py:77-82` | `BUCKET_OF_REGISTER` — register decides the mixture bucket |
| `tools/train-intent/src/pipeline_guards.py` | `assert_not_golden_input` (by construction) and `golden_keys` (row level); `GOLDEN_CORPUS` is a single hardcoded path |
| `tools/train-intent/src/encoder_rules.py:45-54` | `TRIGGER_SPANS` and `NEVER_DROPPED` — the existing per-action "what must survive" table |
| `build_encoder_dataset.py:600-613` | **measured**: teacher 67 exact leak hits / 25 keys, noised 32 / 2 **plus 118 rows whose `clean_utterance` parent is a golden utterance (22 keys)** — invisible to both guards |
| `tools/train-intent/eval/author_golden_corpus.py:79-127` | `_locate` and `row()` — offsets are located, never counted; overlap/adjacency refused |
| `author_golden_corpus.py:752-776` | `HAND_ROWS = 189`; `del CORPUS[HAND_ROWS:]` — the hand section is emitted first and never rewritten |
| `tools/train-intent/eval/golden_corpus_batches.py:87-127` | quotas, `N_BATCHES = 12`, the register cycle |
| `golden_corpus_batches.py:1128-1140` | `test_fixture_keys()` — a fourth held-out key holder, currently a *source* of refusals only |
| `tools/train-intent/src/stt_noise.py:30-48` | `synthesize` passes only `--model`/`--output_file`; **no** rate, prosody, speaker or seed parameter |
| `stt_noise.py:65-95` | the HF GPU transcriber; `:121-122` `variants_per_utterance` |
| `stt_noise.py:138-145` | the round-trip row: same labels, `clean_utterance` copied, `source: stt_noise:<register>` |
| `requirements.md:29-31` | **FR-005** — accent and regional dialect personalisation, on-device |
| `requirements.md:43-45` | **FR-008** — intent classification and entity extraction |
| `requirements.md:211-212` | **NFR-002** — NLU result within 4 s of the transcription |
| `requirements.md:252-253` | **NFR-013** — quarantine sanitisation before any business logic |
| `requirements.md:262-266` | **NFR-015/NFR-016** — nothing to the cloud; no PII in logs |

**Measured facts about the pinned corpus** (this worktree, `eval/golden_corpus.jsonl`): 8,000 rows, 189 hand + 7,811 generated; scripts `devanagari` 5,508 / `latin` 1,678 / `code_switched` 814; 4,563 rows carry spans. The corpus has **no** dialect axis, **no** style axis, and no word-order variation other than the handful of hand-authored shapes (`golden_corpus_batches.py:276-286`, `:352-365`).

---

## 3. The linguistic premise, stated precisely

### 3.1 Nepali is verb-final, and the taxonomy is content-anchored

Nepali is SOV: the verb closes the clause, and modality, tense, honorific level and the interrogative force live in that closing material. The information that decides *which action the user wants* is almost always earlier and nominal: a person (`contact`), a clock expression (`time`), a medicine (`medication`), a sentence to be delivered (`message`), a device (`topic`), a method (`app`).

That is why the engine can be order-insensitive for most of the taxonomy: the intent is recoverable from the content words, and the tail decides *mood*, not *action*.

### 3.2 The tail is not always decoration — the tail-critical families

Honesty requires naming the exceptions, because a design that claims blanket order-invariance would be wrong about them:

| Family | Why order (and tail) is load-bearing | Consequence |
|---|---|---|
| `ack_med` vs refusal `none` | The discrimination is a polarity particle inside the tail: "औषधि खाएँ" (`ack_med`) vs "औषधि खाएको **छैन**" (`none`) — pinned by `gc-ack-002` and `annotation_rules.yaml:178`, `:200-205` | Permutation must never reorder a negation particle across a verb root; a scheme that produced "छैन औषधि खाएको" would be teaching the model that the refusal marker is optional |
| `emergency` vs `health_query` | Both mention pain; the difference is a plea/person deixis (`मद्दत गर्नुहोस्`) vs a calm question form. `gc-emergency-002` is the historical live failure (`author_golden_corpus.py:197-198`) | Emergency rows are **never dropped** (`encoder_rules.NEVER_DROPPED`, `annotation_rules.yaml:154`) and the emergency clause is absolute in every one of the new gates |
| `query` vs `none` | "भोलि पानी पर्छ" (statement, `none`-ish chit-chat) vs "भोलि पानी पर्छ?" — interrogative force is entirely tail | The gate must report this family separately, not let it hide in the aggregate |
| `guide` vs `query` | Both can be questions; `topic` + a how-to verb is the discriminator | Content word present in both; the tail decides |
| `music` vs `suggest_video` | "भजन बजाउ" vs "भजनको भिडियो देखाउ" — the discriminator is a verb pair, not a shiftable noun | Tail-adjacent; permutation of the verb pair changes the label |

The consequence for the scheme (§4): **the tail may be redistributed but never internally reversed**, and the polarity/negation and verb-pair material is frozen. That is the "defined limits" of the brief, made machine-checkable.

### 3.3 The user's example, mapped onto the closed taxonomy

"भोलिको मौसम कस्तो छ" → the weather question family → action **`query`** (there is no `weather` label and there must not be: `annotation_rules.yaml:9-11`). This is already the corpus's `gc-query-001` family ("भोलि मौसम कस्तो हुन्छ") and the generated `QUERY_MISC` bank (`golden_corpus_batches.py:662-672`).

**But the brief's second half does not hold today, and this design will not pretend it does.** The requirement says the row has "slot `भोलि`". Under T-034's span policy, `query` rows carry **no spans at all** — every `query` shape in `golden_corpus_batches.py:917-948` declares `{}` slots and no `[label:…]` group, and the hand rows `gc-query-001…016` have empty span lists. The same policy, stated explicitly, excludes the embedded method word from a reminder span (`annotation_rules.yaml:291-294`: "the embedded method mention 'फोन' is not spanned — v1 rule: non-method actions do not supervise app spans").

So one half of the requirement is a **span-policy amendment**, not a robustness fix: either `query` rows start supervising a `time` span for relative-day expressions (`भोलि/आज/पर्सि/अस्ति`), or the requirement is read as "the engine must still *classify* correctly when `भोलि` is present" without a span. This design recommends the amendment — it is cheap, it is exactly the class the user named, and it is a *policy* change to `annotation_rules.spans`, so it belongs to T-063 and is recorded as **OQ-1**, not smuggled in under robustness. It cannot be done by TG-11 alone because it changes what `eval_golden.py`'s slot F1 compares and what the `spans.validation` list accepts.

---

## 4. Order robustness

### 4.1 The content core and the tail — machine-derivable, not hand-annotated

A row's words partition into:

- **content core (C)** — every word intersecting a span, **plus** the action's trigger material that is not itself a span. The non-span triggers are already tabulated in the codebase: `encoder_rules.TRIGGER_SPANS` (`:45-51`) names the span-side triggers, and the non-span ones are the ack verb (`खाएँ/खाइसकें/…`) and the query/imperative verb — the same material `stt_noise`'s re-annotation rule already treats as load-bearing (`annotation_rules.yaml:152`).
- **tail (T)** — everything else: postpositions that are their own word, verb morphology, honorifics, question words, particles, fillers.

This partition is derived from the row's own `spans` plus a small closed per-action trigger lexicon. It is **not** a new annotation: no human tags C or T, so the scheme cannot drift from the annotation rules and adding a span label automatically moves words into C.

Rendering back to a string and re-locating offsets must go through the existing `author_golden_corpus.row()` / `_locate` path (`:79-127`), so every derived row is validated by the same code that validates the pinned ones — "offsets located, never counted".

### 4.2 The operator family (closed, deterministic, indexed)

Given a row with content sequence `c₁…c_k` and tail sequence `t₁…t_m`, the scheme may emit **any sequence that preserves the relative order of the `c`'s and preserves the relative order of the `t`'s**, drawn from this closed list:

| Op | Name | Transformation | Tier |
|---|---|---|---|
| `O0` | identity | the pinned row, unchanged | control |
| `O1` | tail-postpose | `c₁…c_k t₁…t_m` — the canonical SOV form (identity for most of the corpus) | A |
| `O2` | tail-prepose | `t₁…t_m c₁…c_k` — verb-first, the SVO-like order the user contrasts with | B |
| `O3` | tail-split-bracket | `t₁…t_⌊m/2⌋ c₁…c_k t_⌊m/2⌋+1…t_m` — tail material on both sides of the content core | A |
| `O4` | interrogative-fronting | move the **first interrogative lexeme** (closed list: कस्तो, कहाँ, कति, के, कहिले, कसरी, कुन, किन) to position 0, everything else in order | B |
| `O5` | content-postpose (afterthought) | `c₁…c_{k-1} t₁…t_m c_k` — the last content word (with its span) trails as an afterthought | A |
| `O6` | tail-internal-swap-of-adjacent-segments | swap two **non-frozen** adjacent tail segments | A (if the row has ≥2 non-frozen tail segments; else recorded `identity_by_absence`) |

**Tier A** (`O1`, `O3`, `O5`, `O6`) are redistributions attested in ordinary Nepali speech and are the operators the corpus *trains* on. **Tier B** (`O2`, `O4`) are attested-but-marked (verb-first is emphatic/child-directed; interrogative-fronting is a real question strategy) and are the operators the **gate measures but the corpus does not train on** — see §7.1 for why that asymmetry is deliberate.

**Frozen material the scheme never moves** (the §3.2 exceptions, made mechanical):

- any word containing a negation/polarity marker from the closed list छैन, होइन, नाइँ, खाइनँ, न, मा (the `annotation_rules.yaml:178` refusal markers) stays in place relative to its verb root;
- an `emergency` row's words keep their order entirely (`O0` only) — recall-first, `annotation_rules.yaml:154`;
- adjacent words that form a single verb pair distinguishing `music` from `suggest_video` (बजाउ / देखाउ / लगाउ family) are a single frozen segment;
- a span is **never** split, and no word of a span is ever separated from another word of the same span. If an operator would do so, the operator is refused for that row and the row records `refused:<op>` — counted, never silently dropped.

### 4.3 What the scheme must never violate (the row stays legal)

For every derived row, all of these must hold or the row is refused and counted:

1. `utterance[start:end] == span.text` for every span (`annotation_rules.yaml:173`);
2. spans are whole-token runs (`:131-134`) — guaranteed because C-words move as units and spans never split;
3. no overlap, no adjacent same-label spans (`:174`) — guaranteed because C-order is preserved, so a label's runs stay disjoint and non-adjacent;
4. every non-null slot string is still a substring of the utterance (`:175`) — preserved because slots are span surfaces;
5. the normalized utterance is not already used by any held-out holder (§8);
6. `len(utterance.split()) <= 20` and the utterance still renders with no template artefact (`golden_corpus_batches.py:1234-1248`);
7. the token count under the T-033 tokenizer is recorded, and a row whose tokenization exceeds `max_len: 64` (`encoder_contract.yaml:322`) is **marked**, because truncation changes which tokens survive and F-5 (`span_severed_by_truncation`) is a known failure mode — a gate that silently compared truncated and untruncated rows would be measuring the wrong thing.

### 4.4 Why BIO spans already encode salience

This is the mechanism that makes the whole approach work, and it is worth stating because it is the reason the encoder does not need an order-aware architecture:

The intent head reads one pooled `[CLS]` vector (`encoder_contract.yaml:59-61`), which is order-sensitive by construction (XLM-R position embeddings are absolute). **But the slot head supervises every token**: first-subword tagging gives each content word's first subword a `B-<label>` target and each continuation an `I-<label>`, and every other word gets `O` (`annotation_rules.yaml:117-125`). That is a per-token gradient saying "this token **is** the thing" and, for tail tokens, "this token is **not** the thing".

Three consequences the design leans on:

1. **The encoder is already trained to attend to content words by name**, not merely to classify a bag of words. A permutation that leaves the content words intact leaves both the span supervision and the intent-relevant evidence intact; only the `[CLS]` summary moves.
2. **The span decode is a second, independent check.** If a permuted row is classified correctly but its spans shift or vanish, the row's *downstream* behaviour (resolution in code, `encoder_contract.yaml:136-145`) fails. So the order gate must be span-aware (§7.1) — intent-only scoring would pass a model that has learned to guess the label from one salient word while losing the offsets.
3. **Because salience is explicit, span-anchored augmentation is safe in a way generic text augmentation is not.** We are not perturbing tokens and hoping; we are relocating whole, supervised units. That is why the scheme can be deterministic and offline — no paraphrase model, no teacher, no GPU.

### 4.5 Training-side effect, and why permutation runs *upstream* of the noise pass

Order-derived training rows are produced **before** `stt_noise.py`'s round trip, not after. The pipeline is `teacher.jsonl → [permute] → TTS → Whisper → noised.jsonl` and the noised bucket is 60% of the mixture (`annotation_rules.yaml:209`, anchored by `hard_floor_stt_noised: 0.55` at `:230`). Permuting upstream means:

- order variance lands inside the runtime-critical 60% bucket **for free** — the same number of round trips buys both axes;
- the clean bucket keeps its pinned meaning (the pinned rows themselves remain the clean examples);
- **one extra parent hop**: a noised row's `clean_utterance` becomes the *permuted* string, so the parent chain is `noised → permuted → original`. This is exactly the chain the existing leak guard cannot follow (§8), which is why §8 is not optional.

Clean-only order rows (no round trip) are the fallback if the noise pass is unavailable; they land in `clean_devanagari` and change that bucket's composition, so the mixture report must count them by source.

---

## 5. Dialect, accent and style

### 5.1 Three orthogonal axes, not one longer register list

Today `register` carries two different ideas at once — *script* (`devanagari`, `romanized`) and *speaker style* (`code_switched`, `elder_fragmented`) — and it is **load-bearing for the mixture**, because it decides the bucket (`build_dataset.py:77-82`, `annotation_rules.yaml:210-216`). Adding dialect values to `register` would change the mixture arithmetic and the 60/25/15 ratios for everyone.

So the proposal adds two **orthogonal, additive axes** on the row, leaving `register` exactly as it is:

| Axis | Values | Where it lives | What it changes |
|---|---|---|---|
| `register` (existing, unchanged) | `devanagari`, `romanized`, `code_switched`, `elder_fragmented` | row field, bucket selector | nothing — untouched |
| **`dialect`** (new) | `standard` (default), `eastern`, `central`, `western`, `terai` | row field + eval slicing | mixture counters report per dialect; the eval fixture slices by it |
| **`style`** (new) | `neutral` (default), `clipped`, `honorific`, `mixed_code` | row field + eval slicing | same |

Neither axis is a model label. The intent head stays 12-wide and the slot head 13-wide (`encoder_contract.yaml:65-98`); `meta.json:intents` and `meta.json:tags` are unchanged, so **no retrain is required to adopt the axes** — only re-authoring. That is the whole point of making them metadata.

### 5.2 The dialect inventory — a proposal, subject to native-speaker validation

The five-value inventory is the standard geographic division used in Nepali dialectology (Eastern / Central / Western / Far-Western, with the Terai belt as a distinct contact zone). It is written here as the **working hypothesis for T-062**, not as a settled fact: an engineering team must not invent a dialect atlas, and this document deliberately does not enumerate per-dialect verb paradigms from memory. T-062 is the task that has a Nepali speaker validate:

- the value set (is Far-Western distinct enough from Western to be its own slice? is Terai one slice or three, given Maithili/Bhojpuri/Awadhi substrates?);
- the per-dialect **lexical variant banks** (word-level alternates that speakers actually use);
- the per-dialect **orthographic variants** (how the same word is typically written);
- which slices the app claims to support — a slice we cannot author ≥300 paired rows for (§7.3) is not claimable.

**The axis ships with whatever value list T-062 validates**, and `standard` is always the comparison anchor.

### 5.3 Orthographic and lexical variants

Two distinct noise axes, and the design keeps them apart because their expected model impact differs:

- **Orthographic variants** (`भोलि / भोली`, `औषधि / औषधी`, `गर्नुहोस् / गर्नुहोस`, digit scripts `८ / 8`, spacing inside a merged token) are *surface* variation over the same subword material. XLM-R's 250k sentencepiece vocabulary (`encoder_contract.yaml:30-34`) is trained mostly on standard written Nepali, so a variant usually shares most subwords with the standard form. **Expectation: absorbable**, and the existing corpus already shows it (the hand rows include `व्हाट्सएपमा` beside `वाट्सएपमा`, `माइक्रोवेभ` beside `माइक्रोवेभमा`; `annotation_rules.yaml:299` pins digit substitution).
- **Lexical variants** (a genuinely different word for the same thing) are *different subword material*. A word the tokenizer fragments into rare pieces and the model has never seen in a span position produces `O` or a broken span. **Expectation: absorbable only with training mass** — the 117M-parameter budget buys a few hundred new word forms, not a second lexicon (§6).

**The resolver constraint, which is the part that is easy to miss.** The encoder emits *surfaces*, and resolution happens in code (`encoder_contract.yaml:136-145`; `contact_normalisation` at `:226-231`; `app_span_projection.matching: containment` at `:217`). A dialect row that trains the encoder to emit a surface the next layer cannot consume is **not** a robustness win — it converts a recognition failure into a silent resolution failure one layer later, inside confirm-before-execute. Therefore every authored dialect row carrying a span must pass a **resolve-through check** against the shipped resolvers' stated tolerance (containment / clitic-trim rules); a row whose surface the resolver would reject is marked `resolver_blocked`, excluded from the gate's shippable claim, and reported. That is a T-064 implementation requirement, not an aspiration.

### 5.4 Style variants

- **`clipped`** — telegraphic elder speech with the tail elided ("औषधि… बिहान", "भोलि… डाक्टर"). This is the *reduction* of the tail, the mirror image of order permutation, and it is the style the existing `elder_fragmented` register gestures at (`annotation_rules.yaml:216`) without pinning a scheme. Clipped rows stress the same content-core hypothesis as §4: if the tail is decoration, deleting it should not change the intent — and where it does (the §3.2 families), that is a finding to report, not to hide.
- **`honorific`** — high-honorific address (`हजुर`, `हजुरलाई`, `गर्नुहोस्`/`गरिदिनुहोस्` alternations). Lexically close to standard; the risk is verb-form drift, not vocabulary.
- **`mixed_code`** — the existing `code_switched` register already covers Nepali–English mixing; the `style` value exists to mark *within-Nepali* mixing with a regional language (Terai Maithili/Bhojpuri function words), which is a different phenomenon and belongs with the Terai dialect slice.

### 5.5 What the noise pass can and cannot produce — the accent question, answered honestly

The round trip is `text → piper TTS → audio → the app's bundled Whisper → noisy text` (`stt_noise.py:1-17`, `annotation_rules.yaml:267-273`). Read `stt_noise.py:30-48` and the limit is visible: **synthesize passes only `--model` and `--output_file`.** There is no rate, no prosody, no speaker and no seed parameter in the call, and the voice is `voices/hi_IN-pratham-medium.onnx` — a **Hindi** voice chosen as "nearest to ne" (`config.yaml:23`). `variants_per_utterance: 2` (`stt_noise.py:121-122`).

So, plainly:

**The noise pass does not produce accent variance today, and piper cannot be made to speak Eastern Nepali.** What it produces is *the STT error profile that a non-native-voice rendering of the text induces*, plus script drift and lexical substitution. A design that claimed "the noise pass produces accents" would be overclaiming, and the corpus-level evidence would not support the claim.

What it **can** be made to produce, deterministically, and what T-066 scopes:

1. **Speaking-rate, tempo and quality variance** — `--length_scale` (slow speech is the classic elder profile and a real recognition-stress variable), tempo variance and quality perturbation, combined with additive noise. These are synthesis and mixing parameters of the model actually in use, not new data. They are what gate 4 (reduced articulation, §7.4b) measures.
2. **Additive noise at controlled SNR** — white noise mixed to a target SNR before the STT decode, at a ladder anchored to the band the project already trains with (`dataset.py:42-43`, 3–15 dB). This is what gate 3 (§7.3) measures, and it is a capability the pipeline does **not** have today: `synthesize` mixes nothing (`stt_noise.py:30-48`).
3. **Deterministic parameter tuples and cells** — the variant index `n` (`id: "<parent>:noise<n>"`, `stt_noise.py:126`) selects a fixed `(voice, length_scale, noise_scale, noise_w, snr_db)` tuple from a declared table or cell grid, so `:noise0` and `:noise1` mean the same thing on every host and the noised set re-derives byte-for-byte. **The determinism requirement is absolute**: the corpus revision tag is a content hash (`eval_golden.py:606`), so a nondeterministic pass silently invalidates every recorded baseline.
4. **A voice bank, when one exists** — if Nepali-capable voices with regional data become available they enter the table as further tuple sources, and gate 5 (§7.5) becomes measurable. At this base the bank holds **one** voice and it is Hindi, so the dimension is a gap (GAP-3), not a result. The *Hindi* voice's mispronunciation of Nepali is itself an accent-like perturbation (a non-native reader), which is worth having and is not worth mislabelling as regional.
5. **The honest label on the output** — rows produced this way keep `source: stt_noise:<register>`, gain `style`/`dialect` tags only where an author asserts them, and the run manifest records that accent coverage is *approximated by STT error profile*, not modelled.

The genuinely accent-robust path (real recordings, or per-speaker TTS conditioning) is **out of scope** and named as such in §12; FR-005's on-device personalisation is a *runtime* adaptation (enrolment samples → the STT model), and TG-11 does not touch it.

---

## 6. What a 117M encoder can and cannot absorb

The student is 117,506,432 encoder-body parameters plus 9,625 head parameters (`encoder_contract.yaml:40-49`) — a 12-layer, 384-hidden MiniLM over a 250k XLM-R sentencepiece vocabulary. Statements calibrated to that budget:

**Can absorb** (evidence: already in the corpus, or a bounded number of new surface forms):

- tail redistribution across the operator set of §4.2, *provided each operator appears in training with mass*. A small encoder does not generalise an order it has never seen; it generalises an order it has seen in a few hundred contexts. This is why the corpus trains on Tier A and the gate measures Tier B — the asymmetry is a statement about model capacity, not about linguistic validity.
- orthographic variant families over frequent words (spelling drift, digit script, spacing).
- romanisation and Nepali–English code-switching: already 15% bucket + ~31% of the corpus's script markers.
- clipped/dropped tails, when the content core is intact and the action is content-anchored.

**Cannot absorb** (and the design says so rather than setting a gate it will fail):

- **a second lexicon.** A few hundred new word forms, yes; a dialect's full vocabulary, no. Expectation to record: dialect slices will be carried by *variant forms of words the model already knows*, plus a bounded set of new high-frequency words seen in training.
- **resolution.** The encoder emits spans; it does not normalise. A dialect surface the model recognises is still handed to the resolver verbatim (`encoder_contract.yaml:136-145`). Coverage therefore ends where the resolvers' tolerance ends (§5.3).
- **order invariance by architecture.** Position embeddings are absolute and the intent head pools one position-sensitive vector. Any claim of invariance has to be *measured*, which is precisely what §7 does.
- **free/unattested word orders.** Tier B is a *diagnostic*: if the model does poorly on `O2`/`O4` we report it and decide, rather than training on strings no speaker produces to make a number go green.

---

## 7. The gates

**Five dimensions, one framework.** Every robustness claim this design makes is a *measured* property, and each dimension has its own gate, its own fixture, its own revision tag and its own failing fixture. Prose is not evidence; a dimension that cannot be measured is recorded as a gap with the data it needs (§7.8), never as a claim.

| # | Dimension | Perturbation class | Section |
|---|---|---|---|
| 1 | **Word-order permutation** | grammatical tail redistributed around an intact content core | §7.1 |
| 2 | **Dialect** (Eastern / Central / Western / Terai tagged rows) | lexical + orthographic substitution, matched to a standard twin | §7.2 |
| 3 | **Additive noise** (SNR ladder) | white noise mixed at a target SNR through the round trip | §7.3 |
| 4 | **Reduced articulation** — clipped tail (text) and slur proxy (rate / tempo / quality through the round trip) | tail elision; TTS rate, tempo and quality perturbation | §7.4 |
| 5 | **Accent** (multi-voice TTS) | the same text rendered by different voices | §7.5 — **conditional**, see the gap register |

**Two-layer fixtures, because a gate has two different jobs.** The house discipline is already established by T-038: `tools/train-intent/eval/fixtures/` holds a control plus one failing fixture per gate, driven by `run_fixture_sweep.sh`, and *"each failing fixture must exit 1 with **exactly the one** gate it targets, so a future harness change cannot quietly stop enforcing a gate"* (`run_fixture_sweep.sh:5-7`). TG-11 adopts both layers:

- **Sweep fixtures** (small, synthetic prediction files replayed through `--backend fixture`, `eval_golden.py:298-304`) prove that **each gate trips in isolation**. They need no model, no GPU and no corpus: they are recorded predictions keyed by row id, and a missing id is a hard error (`:301-304`), so a fixture cannot silently degrade to a pass. This is what makes the gates refutable.
- **Measurement fixtures** (full size, real predictions from the named artifact) produce **the number**. They are what the evidence pack records.

**Every result is bound to a named revision.** The project's existing binding is `label@<sha256(corpus)[:8]>` with `read_gemini_baseline` refusing anything else and failing closed (`eval_golden.py:505-537`, `:606`, `:749-759`). Each new fixture carries the same style of tag — `fixture_id@<sha256(fixture)[:8]>` — recorded in the manifest and in the gate's output line, so a gate result is always attributable to the exact bytes that produced it and a fixture edit invalidates its own prior numbers rather than silently re-scoring them.

**All five gates are paired, in-run comparisons**: the fixture row and its control are scored by the same artifact in the same invocation, so none depends on a stale `results.csv` baseline and none can pass by comparing two different populations. All reuse `validate_rows` (`eval_golden.py:350-410`) so a malformed fixture fails the run with exit 2 instead of quietly skewing a metric.

**Three clauses recur in every gate, and they are the safety spine**: `emergency_recall == 1.00`, `side_effect_precision >= 0.97`, and a **fail-safe direction** clause — when the input degrades past what the model can handle, the model must abstain rather than act. A robustness gate that lets a degraded input produce a *confident wrong side-effecting action* has made the product worse, not better.

### 7.1 Gate 1 — order-invariance robustness: **X = 3 percentage points**

**Definition.** Let `A_perm` be closed-intent accuracy over the order fixture's rows and `A_ctrl` the closed-intent accuracy over their `parent_id`s **in the same run**:

```
order_invariance_gap = A_ctrl − A_perm
PASS  iff  A_ctrl − A_perm <= 0.03
      and emergency_recall on the fixture's emergency rows == 1.00
      and (abstention_rate on fixture rows) − (abstention_rate on their parents) <= 0.03
      and span F1 on fixture rows >= (span F1 on parents) − 0.03
```

**Why 3 points — three independent justifications:**

1. **It reuses an already-argued number rather than inventing one.** `max_gap_vs_gemini: 0.03` (`config.yaml:63`, `encoder_contract.yaml:441`) is the project's existing statement that three points is the width of the band inside which two systems must be *treated as equivalent* for a closed-intent decision. Order is a weaker perturbation than a different model, so a band no wider than that is defensible a priori.
2. **It is resolvable at the fixture size the corpus can support.** The comparison is paired, so the standard error of the difference depends on the discordant-pair rate: `SE ≈ sqrt(π_d / n)`. With a plausible `π_d ≈ 0.10` and `n = 800`, `SE ≈ 0.011` and the 95% half-width is ≈ 2.2 points — a 3-point gate sits outside the noise. At `n = 400` the half-width is ≈ 3.2 points, *wider than the gate*, so **the fixture must carry ≥ 800 permuted rows** or the gate is not decidable. (This is the reason the fixture size is a design parameter and not a "we'll add some rows" afterthought.)
3. **It is tight enough to catch the failure mode.** Tail redistribution that a content-anchored model handles well moves accuracy by ~0–2 points; a model that has learned position rather than content collapses by 10–30 points on the same rows. Nothing plausible lands at 4 points by accident.

**Anti-gaming clauses, and why each exists.** A gate that can be passed by getting *worse in a different way* is not a gate:

- **the abstention clamp** — otherwise a model that abstains on every permuted row scores a perfect `abstention_precision` (`eval_golden.py:433-451`) while losing the turn; the gate would read as a pass;
- **the emergency clause** — `emergency_recall` is a hard gate with no compromise (`config.yaml:60`), and permutation must never become a quiet path around it; emergency rows are order-frozen in training (§4.2) and are still measured on the fixture;
- **the span clause** — the whole argument of §4.4 is that spans are the salience mechanism; an intent-only gate would pass a model that lost the offsets (`span_severed_by_truncation`, F-5).

**Tier B is reported, with a stated expectation of ≤ 6 points**, and fails the run at > 10 points (a collapse). Tier B is not trained on (§4.2), so holding it to the Tier A number would set a gate the model has no data to meet. Reporting it keeps the product honest about the difference between "robust to the orders we trained" and "robust to any order".

**Per-family reporting is mandatory.** The aggregate can hide a single collapse — the same argument `annotation_rules.yaml:231` makes for `per_action_floor`. The gate prints the per-intent delta, and the §3.2 tail-critical families (`ack_med` vs refusal, `emergency` vs `health_query`, `query` vs `none`) are printed separately with their own delta.

### 7.2 Gate 2 — dialect robustness: **D = 5 percentage points**

**Definition.** The dialect fixture is authored as **matched twins**: each row carries its standard-form counterpart (`standard_utterance`, `standard_intent`, and the standard spans) or a `twin_id` naming a pinned corpus row. Then:

```
dialect_max_gap = max over dialect slices of ( A_standard_twin − A_dialect_slice )
PASS  iff  dialect_max_gap <= 0.05
      and every dialect slice's side_effect_precision >= 0.97
      and every dialect slice's emergency_recall == 1.00
```

**Why 5 points, and why not 3:**

- **The perturbation is categorically larger.** Order leaves every sound and every word in place; a dialect row changes the *words themselves*, which is a lexical distribution shift and not a reordering. A band equal to the order band would assert an equivalence the mechanism does not support.
- **It still catches the real failure mode.** Slices the model cannot read collapse by 15–30 points; the gap between "slightly worse" and "does not work" is nowhere near 5.
- **It matches the fixture resolution.** With matched twins and `n = 300` pairs at `π_d ≈ 0.10`, `SE ≈ 0.018` and the 95% half-width is ≈ 3.6 points — the gate sits inside the resolvable band. With independent (unpaired) rows, resolving 5 points needs ≈ 400 rows **per slice** (`SE_diff = sqrt(2p(1−p)/n)`, ≈ 2.1 points at `n = 400`, `p = 0.9`), and a 150-row slice cannot resolve anything finer than ≈ 7 points. Hence **≥ 300 matched twin pairs, or ≥ 400 independent rows per claimed slice.**
- **The absolute clauses carry the safety weight, not the delta.** `side_effect_precision ≥ 0.97` and `emergency_recall == 1.00` per slice are existing hard gates (`config.yaml:60-62`) applied at slice granularity. This is the answer to "what if all slices are equally bad?" — a model that is uniformly mediocre on dialect input fails the absolute clauses even though the delta looks fine.

**Slice coverage is bounded and must be stated as such.** The gate proves **non-collapse on the slices we could author**; it cannot prove coverage of a dialect nobody authored rows for. The honest claim is per-slice and evidence-bound, and the group's notes record which dialects are claimed and which are explicitly unclaimed (T-062 decides).

### 7.3 Gate 3 — additive noise, an SNR ladder: **Δ ≤ 3 points at 15 dB, ≤ 5 points at 10 and 5 dB**

**The measurement the project already owes itself.** Noise robustness is *trained* and never *measured*. `tools/train/src/dataset.py:23-33` adds white noise at a random SNR uniform in **[3, 15] dB** to half the batch, exposed as `--noise-aug` (`tools/train/src/train_finetune.py:53-55`), and its own docstring calls it *"the right robustness for real-room mics"* and — decisively — *"Training-only: evals and distillation leave it off."* The project decided this augmentation matters for deployment and then never checked what it bought. This gate is that check.

**Mechanism.** White noise mixed at a target SNR before the STT decode, at a fixed ladder anchored to the band the model was already trained on: **{clean, 15, 10, 5, 3} dB**. The endpoints are not invented — they are the existing augmentation band's own endpoints; 10 and 5 are interior points. Nothing below 3 dB is gated, because that is outside the band the project chose to train for, and gating outside the training distribution measures the fixture, not the model.

Two mixing domains are available and the choice must be **declared, not implicit**: the waveform (the whisper.cpp path, `stt_noise.py:50-63`) or the mel features (the HF path, `make_hf_transcriber`, `stt_noise.py:65-95`), the latter matching the existing augmentation's domain (`dataset.py:38-44` mixes on `input_features`). The two give different effective SNRs for the same nominal value, so a run states which it used or its dB numbers are not comparable across runs. Noise is generated from a pinned seed, so a level re-derives byte-for-byte.

**Definition.** Paired by parent, per level ℓ:

```
PASS  iff  A(15) >= A(clean) − 0.03
      and  A(10) >= A(clean) − 0.05  and  A(5) >= A(clean) − 0.05
      and  at EVERY level (including 3 dB): side_effect_precision >= 0.97 and emergency_recall == 1.00
      and  at 3 dB (the band floor), the fail-safe clause binds instead of an accuracy number:
           confident errors must not exceed abstentions, i.e. the model degrades toward re-prompting
      and  monotonicity: A(ℓ) is non-increasing in noise within a 3-point tolerance
```

**Why these numbers.** The 3-point clause at 15 dB reuses the project's equivalence band (`max_gap_vs_gemini: 0.03`) at the *top* of the augmentation band, where almost no degradation is defensible. The 5-point clause at 10 and 5 dB uses the categorical-perturbation band (the same reasoning as dialect, §7.2): a channel that substitutes and deletes transcript tokens is a larger change than a reordering. The 3 dB level is the augmentation band's floor — asking for an accuracy number there would be asking the model to be robust outside what it was trained on, so the honest requirement is **fail-safe behaviour** (abstain, do not act). The monotonicity clause is an anti-artefact check: a ladder that gets *better* with more noise means the fixture or the scoring is broken, and the design refuses to report such a ladder as a robustness result.

**Fixture size.** ≥800 pairs at 15 dB (the 3-point clause needs the tighter interval, §7.1) and ≥300 pairs at each of 10, 5 and 3 dB (≈3.6-point half-width at π_d≈0.10, inside the 5-point band). Fixture: `eval/noise_snr_holdout.jsonl`, tag `noise_snr_holdout@<sha8>`.

**Gap — what cannot be measured.** The codebase has white noise only (`torch.randn_like`, `dataset.py:42-43`). **Babble and real-environment noise** (a television, a market, a street, a crowded room) is the noise that actually reaches an elderly user's microphone, and there is no source for it in this project. Generating it would need a licensed noise corpus with per-scene labels and a stated mixing policy. Recorded as **GAP-1** in §7.8; until it is closed, the noise gate's claim is limited to *stationary additive white noise*, and any summary of it must say so.

### 7.4 Gate 4 — reduced articulation: **Δ ≤ 5 points**, with the frozen material structurally undroppable

Two distinct perturbations share one dimension, and they are kept apart because one is text and one is audio.

**(a) Clipped tail — text-level, deterministic.** The grammatical tail is *elided* rather than moved, using the same content-core partition and the same frozen-material list as §4.2. This is the reduction mirror of permutation: if the tail is decoration, deleting it should not change the intent — and where it does change the intent, that is a finding to report, not to hide.

```
PASS  iff  A_clip >= A_intact − 0.05
      and  frozen material is never elided (structurally, not by luck)
      and  tail-critical families are reported separately with their own delta
      and  side_effect_precision >= 0.97, emergency_recall == 1.00
```

The frozen-material rule is the safety spine of this dimension and is **structural**: the polarity markers (`छैन`, `होइन`, `नाइँ`, `खाइनँ`, `न`, `मा` — the refusal markers pinned at `annotation_rules.yaml:178`), emergency rows, and the `music`/`suggest_video` verb pair can never be elided, so it is *impossible* for the generator to produce a row where "औषधि खाएँ" loses its way to a refusal or an acknowledgement loses its polarity. A scheme that dropped those would be manufacturing a label error and then measuring the model's failure to reproduce it. The tail-critical families (§3.2) still legitimately change under elision where the elided material was not frozen, so they are reported with their own delta rather than folded into the aggregate.

Fixture: `eval/clipped_holdout.jsonl`, ≥800 pairs, tag `clipped_holdout@<sha8>`.

**(b) Slur proxy — audio-level, through the round trip.** A declared **cell grid** of synthesis perturbations: speaking rate (`--length_scale`), tempo variance, quality perturbation, and additive noise, combined. Named exactly what it is: a **reduced-articulation proxy**. A synthetic voice is not dysarthric and this is not a model of slurred speech; it is a stress test of the recogniser against *reduced and degraded articulation*, which is the mechanism by which any of it could reach the intent encoder at all.

```
moderate cell (rate within ±20% of nominal, mild quality perturbation, SNR 10 dB):
    PASS iff A >= A_clean − 0.05, plus the absolute clauses
severe cell (rate ±40%, stronger perturbation, SNR 5 dB):
    PASS iff the fail-safe clause binds — abstention rises, confident errors do not —
    plus side_effect_precision >= 0.97 and emergency_recall == 1.00 at EVERY cell
```

Cells are declared in config, so a cell means the same thing on every host and every run (T-066). Fixture: `eval/reduced_articulation_holdout.jsonl`, ≥800 pairs at the moderate cell and ≥300 per other cell, tag `reduced_articulation_holdout@<sha8>`.

**Gap — what cannot be measured.** Real slurred or dysarthric speech, real hearing-aid and telephone-channel effects, and the actual elder-speech distribution need **real recordings of the target population**. That is consent-bearing data; FR-005 keeps accent tuning on-device; and collecting it is a separate acquisition project with its own privacy basis, not a corpus-augmentation step. Recorded as **GAP-2** in §7.8. Any statement about slurred speech coverage must carry that qualification.

### 7.5 Gate 5 — accent (multi-voice TTS): **conditional — the mechanism is specified, the dimension is a gap today**

**Definition, when it is measurable.** The same text rendered by multiple TTS voices, scored per voice against a reference voice, in the shape of the dialect gate:

```
per voice v:  A(v) >= A(reference) − 0.05, with >= 300 matched pairs per voice
              and side_effect_precision >= 0.97 and emergency_recall == 1.00 per voice
```

**Status at this base: not measurable, and the design does not pretend otherwise.** The shipped voice bank contains **exactly one voice** — `voices/hi_IN-pratham-medium.onnx` (`config.yaml:23`) — and it is a **Hindi** voice chosen as "nearest to ne". There is no Nepali voice and no second voice: no `*.onnx` exists anywhere in the tree at this base. A per-voice gate over a single voice is a vacuous measurement. The condition that would make it real is stated rather than assumed: the bank must hold **≥2 Nepali-capable voices** with compatible licences, fetched and pinned by digest, with the voice's provenance recorded.

**And even then it is a proxy.** Multi-voice synthesis measures *speaker variation*; it does not measure regional accent, because a synthetic voice is not a speaker from Eastern or Terai Nepal. The genuinely accent-robust path is real regional speech — which is FR-005's territory (on-device personalisation from enrolment samples, `requirements.md:29-31`) and a data-acquisition project, not a corpus asset. Recorded as **GAP-3** in §7.8.



### 7.6 Fixture sizing — the numbers this design commits to

Every fixture is a **held-out file of its own** (see §8), each with its own revision tag, and each sized by the resolution its gate needs rather than by convenience:

| Dimension | Fixture | Rows | Why that size |
|---|---|---|---|
| Word order | `eval/order_permutation.jsonl` | **≥ 800** paired rows | 3-point paired gate needs ≈ 800 for a 2.2-point CI half-width (§7.1) |
| Dialect | `eval/dialect_holdout.jsonl` | **≥ 300 pairs per claimed slice**, `standard` twin included | 5-point paired gate needs ≈ 300 for a 3.6-point CI half-width (§7.2) |
| Additive noise | `eval/noise_snr_holdout.jsonl` | **≥ 800** at 15 dB; **≥ 300** at each of 10, 5, 3 dB | the 3-point clause needs the tighter interval; the 5-point clauses do not (§7.3) |
| Clipped tail | `eval/clipped_holdout.jsonl` | **≥ 800** paired rows | same interval as order, same 5-point band as dialect (§7.4a) |
| Slur proxy | `eval/reduced_articulation_holdout.jsonl` | **≥ 800** at the moderate cell; **≥ 300** per other cell | same split rationale as the noise ladder (§7.4b) |
| Accent | — | — | **not authored**: the dimension is GAP-3 (§7.5) |

All of them are **held-out fixtures, not training data**, and all are **separate files** — see §8.

Rows are selected by a **deterministic rule**, not by hand: for each of the 12 actions, take the next unused pinned-corpus rows in file order until the target count is met, replacing any row that refuses all operators with the next candidate. The rule and the resulting **exact ids** are enumerated in the fixture manifest, so the fixtures are reproducible and auditable rather than a free parameter (T-064's manifest, T-069's evidence pack).

### 7.7 How the gates are wired into the harness

Mirroring the existing `--nearmiss` plumbing exactly (`eval_golden.py:573-587`, `:592-627`):

- `eval_golden.py` gains one flag per dimension (`--order-fixture`, `--dialect-fixture`, `--noise-fixture`, `--clip-fixture`, `--articulation-fixture`) with defaults beside the existing fixture paths, so a bare invocation scores every dimension that is measurable;
- every fixture goes through `load_rows` + `validate_rows`, and `validate_rows` is **extended** to validate the new keys (`order_op`, `perm_of`, `dialect`, `style`, `standard_*`, `snr_db`, `clip_op`, `cell`, `voice_id`, `parent_id`, `revision`) — an unvalidated fixture key would let a malformed fixture pass silently, which is the failure `validate_rows` exists to prevent;
- one metric function per dimension beside `nearmiss_stats` (`:476-502`), same return shape (counts, offenders, per-slice breakdown);
- one gate key per dimension in `config.yaml:gates` (`order_invariance_delta`, `dialect_max_gap`, `noise_snr_delta`, `clipped_tail_delta`, `reduced_articulation_delta`, and an `accent_voice_delta` that stays **unwired** until GAP-3 closes), read with `cfg[...]` like every other gate;
- every gate joins the `gates` dict (`:821-829`), so a failure exits non-zero through the existing path (`:830`, `:895-898`) with no new control flow;
- the run manifest (`:848-893`) gains each **fixture id with its revision tag**, the fixture hashes, the per-operator / per-slice / per-level / per-cell tables, and the paired and discordant counts — **additive**, so the append-only `results.csv` schema (`:840-846`) is unchanged;
- **every gate output line carries `fixture_id@<sha8>`**, in the same spirit as the existing `label@<corpus sha8>` binding, so a number can always be traced to the exact bytes that produced it;
- **fail-closed on a missing, stale or unevaluatable fixture**: a gate that cannot be evaluated is a failed gate, exactly as the Gemini baseline is (`:749-759`, `:814-815`), never a silent pass;
- **a dimension that is a declared gap is not wired as a passing gate.** A gate with no fixture is omitted from the gate dict and appears in the manifest as `GAP-<n>` with the data it needs. Rendering an unmeasurable dimension green is the one outcome this design rules out explicitly.

### 7.8 The evidence pack — dimension → mechanism → gate → threshold → fixture → rows

This table is the design's contract with the harness: every robustness claim in this document maps to a row here, and any claim that does not is a gap or a defect. T-069 maintains it as a machine-checked artifact (`eval/evidence_pack.json` plus a rendered view), so a gate that is added, renamed, re-thresholded or removed without the table moving is a test failure rather than silent drift.

| Dimension | Mechanism | Gate id | Threshold | Fixture id | Rows | Revision | Failing fixture (trips in isolation) | Measurable |
|---|---|---|---|---|---|---|---|---|
| **Word-order permutation** | operator family `O0`…`O6` over pinned rows, content core intact (§4.2) | `order_invariance` | Δ ≤ **0.03** (Tier A); Tier B reported ≤0.06, fails >0.10 | `order_permutation` | ≥800 pairs | `order_permutation@<sha8>` | `preds_order_invariance_fail.jsonl` | after T-064; T-061 measures provisionally |
| **Dialect** (Eastern / Central / Western / Terai) | T-062 variant banks, matched twins, `dialect` tag per slice | `dialect_robustness` | per-slice Δ ≤ **0.05** + absolute clauses | `dialect_holdout` | ≥300 pairs per claimed slice | `dialect_holdout@<sha8>` | `preds_dialect_robustness_fail.jsonl` | after T-064 — **zero dialect rows exist today** |
| **Additive noise** (SNR ladder) | white noise mixed to a target SNR before the STT decode; ladder {15, 10, 5, 3} dB (§7.3) | `noise_snr` | Δ ≤ **0.03** @15 dB; ≤ **0.05** @10/5 dB; fail-safe @3 dB; absolute clauses at every level | `noise_snr_holdout` | ≥800 @15 dB; ≥300 per other level | `noise_snr_holdout@<sha8>` | `preds_noise_snr_fail.jsonl` | after T-066 — **no mixing step exists today** |
| **Clipped tail** | non-frozen tail segments elided; frozen material structurally undroppable (§7.4a) | `clipped_tail` | Δ ≤ **0.05** + absolute clauses | `clipped_holdout` | ≥800 pairs | `clipped_holdout@<sha8>` | `preds_clipped_tail_fail.jsonl` | after T-064 |
| **Slur proxy** (reduced articulation) | declared cell grid: rate, tempo, quality, noise (§7.4b) | `reduced_articulation` | Δ ≤ **0.05** @moderate; fail-safe @severe; absolute clauses per cell | `reduced_articulation_holdout` | ≥800 @moderate; ≥300 per other cell | `reduced_articulation_holdout@<sha8>` | `preds_reduced_articulation_fail.jsonl` | after T-066 — **no rate/tempo parameter is passed today** |
| **Accent** (multi-voice) | the same text rendered by multiple TTS voices, paired per voice | `accent_voices` *(unwired)* | per-voice Δ ≤ 0.05, ≥300 pairs | — | — | — | — | **GAP-3** — one voice in the bank, and it is a Hindi voice |

**The gap register — dimensions that cannot be measured on the current corpus, with the data needed.** A gap is a first-class result: it bounds every claim above it, and it is recorded with what would close it rather than left implicit.

| Gap | Dimension affected | Why it cannot be measured today | Data needed to close it |
|---|---|---|---|
| **GAP-1** | Additive noise, real-world | Only white noise exists (`dataset.py:42-43`); babble, television, market, street and room noise are absent from the project | A licensed noise corpus with per-scene labels, a stated mixing policy (which scenes at which SNRs), and a decision on waveform vs mel mixing |
| **GAP-2** | Slurred / dysarthric / real elder speech | A synthetic voice cannot be dysarthric; the slur cell grid is a stress test, not a model | Consented recordings of the target population, a privacy basis compatible with FR-005's on-device rule, and an acquisition protocol — a separate project, not an augmentation step |
| **GAP-3** | Accent | The voice bank holds exactly one voice and it is Hindi (`config.yaml:23`); no `*.onnx` exists in the tree at this base | ≥2 Nepali-capable piper voices with compatible licences, fetched and pinned by digest with provenance recorded — and for real accent rather than speaker variation, real regional speakers, which is GAP-2's problem again |
| **GAP-4** | Dialect slices | The pinned corpus contains **zero** dialect-tagged rows; the axis does not exist until T-063 lands it and T-064 authors into it | T-063's amendment plus T-064's authored twin pairs at ≥300 per claimed slice; any slice T-062 cannot author for stays **unclaimed**, not silently unmeasured |

**What the evidence pack must never become.** A gate measures a dimension; it does not certify the product for it. Two failure modes are named here so no future reader slides into them: a **sweep fixture passing proves the gate works, not that the model is robust** — the number comes from the measurement fixture and nowhere else; and **an unwired gate must never be rendered as green** — a gap is displayed as a gap, with its data requirement, even when that is the less comfortable answer.

---

## 8. Corpus growth and the leak guard — the parent-key hazard

**Decision: the new rows go in new files, and `eval/golden_corpus.jsonl` is not touched.**

The pinned corpus is 189 hand rows + 7,811 generated rows (`author_golden_corpus.py:752-776`). Its revision tag is `sha256(corpus)[:8]` (`eval_golden.py:606`) and every recorded baseline is bound to it (`read_gemini_baseline`, `:505-537`). Appending rows to that file would move the tag, invalidate the recorded Gemini baseline, and force every comparison to be re-measured — for no benefit, since the new fixtures are *derived* rows that would also muddy the corpus's meaning as "the pinned §9.1 coverage set". New files keep:

- the 189 hand rows and the 7,811 generated rows **byte-identical** (`author_golden_corpus.py --check` stays green);
- the corpus revision tag **unmoved**, so existing results stay comparable;
- the near-miss generator's reserved-key logic (`golden_corpus_batches.py:1155-1161`) unaffected.

**The hazard this creates, stated plainly.** The leak guard is a *normalized-utterance membership test* against a fixed file list: `load_golden_keys(*paths)` (`build_dataset.py:120-134`) is called with `eval/golden_corpus.jsonl` and `eval/emergency_nearmiss.jsonl`, and the encoder build calls `golden_keys(GOLDEN_CORPUS)` against the single hardcoded `pipeline_guards.GOLDEN_CORPUS` path (`build_encoder_dataset.py:432`). A permuted row is by construction **not** byte- or normalize-equal to its parent, so it is invisible to that test. And a permuted row that goes through the noise pass is *doubly* invisible, because its `clean_utterance` is the permuted string, not the golden one.

This is not hypothetical. The build already reports the measured size of the same blind spot for the *existing* noised rows: **118 rows whose `clean_utterance` parent is a golden utterance (22 keys)** (`build_encoder_dataset.py:609-611`). TG-11 would open a second, larger channel of exactly that shape.

**Required controls** (T-064, verified by T-068):

1. **Register every new fixture in the leak guard.** All three fixture files are passed to `load_golden_keys` at every call site, and `pipeline_guards.GOLDEN_CORPUS` becomes a tuple/list of guarded paths — one place, so a future fixture cannot be forgotten. New fixture rows are then refused as training input by exactness.
2. **A parent-key guard, which is the new mechanism.** Every derived row (permuted, dialect, or noised-from-either) carries `parent_id`, and the builder refuses any row whose `parent_id` is a held-out id **transitively** (the chain `noised → permuted → golden` is followed, not just one hop). Refusals are counted in a new counter (`parent_leak`) and reported **separately** from the exactness counter, so a waiver of one never implies the other — the same discipline the existing `leak_waiver` note demands (`build_encoder_dataset.py:596-604`).
3. **Make the derivations structurally incapable of leaking.** The order/dialect *training* generators draw from `data/teacher.jsonl` (training supply), and the *fixtures* are generated from the pinned corpus. The two generators are separate entry points over separate inputs; a shared code path takes the input list as a parameter and never a default that could point at the corpus.

**Where the training rows enter the mixture.** `data/order.jsonl` and `data/dialect.jsonl` are new sources beside `teacher.jsonl`/`noised.jsonl`/`edge_cases.jsonl` (`build_encoder_dataset.py:60`), tagged `source: order:<op>` / `source: dialect:<value>`, and they are subject to the *unchanged* floors: `corpus_floor: 8000`, `hard_floor_stt_noised: 0.55`, `per_action_floor` (`annotation_rules.yaml:230-232`). The mixture report (`annotation_rules.yaml:233-242`) gains per-dialect and per-operator row counts. **No floor is lowered for this work** — if order/dialect supply cannot clear the floors, that is a supply finding to report, not a reason to re-normalise.

---

## 9. Requirements traceability

| Requirement | How TG-11 serves it |
|---|---|
| **FR-005** — accent and regional dialect personalisation | T-062 validates the dialect inventory and rules on the accent proxy; T-063/T-064 give the corpus the `dialect`/`style` axes and the variant banks; gate 2 (§7.2) measures the dialect dimension; T-066 specifies the multi-voice interface and records GAP-3 for the voices the bank does not have. The on-device enrolment half of FR-005 is untouched (§12) |
| **FR-008** — intent classification and entity extraction | The whole point: intent and spans must survive order, dialect, style, noise and reduced articulation (T-061, T-064, T-065, T-066, T-067); T-069 makes the claim auditable — every dimension traces to a gate, a fixture, a revision and a failing fixture, and anything that cannot be measured is a gap rather than a claim |
| **FR-009** — safety-critical paths never depend on the model | Emergency rows are order-frozen (`O0` only) and never dropped; the frozen-material rule makes polarity markers structurally undroppable under clipping (§7.4a); every gate carries `emergency_recall == 1.00` and `side_effect_precision >= 0.97` (§7.1–§7.5) |
| **NFR-002** — NLU result within 4 s | No runtime change; the permutation fixture records token counts against `max_len: 64` so a gate cannot pass by measuring truncated rows (§4.3 item 7) |
| **NFR-013** — quarantine sanitisation | Fixtures and augmentation rows are authored from sanitised transcripts; no new ingress path is created |
| **NFR-015 / NFR-016** — no cloud, no PII | All fixtures synthetic (existing entity banks, `author_golden_corpus.py:57`); the degradation passes re-render existing synthetic text and add no new data source; the manifest records counts and hashes only; the dialect axis is dataset metadata, never egressed. Real recordings are excluded from scope precisely so this stays true, and their absence is recorded as GAP-2/GAP-3 while real-world noise is GAP-1 — recorded rather than worked around |
| **NFR-023 / NFR-024** — externalised strings, Nepali + English | **Not engaged**: TG-11 adds no user-facing setting and no string (§12). Recorded here so the omission is deliberate |

---

## 10. Task mapping

| ID | Title | Effort | Risk | Depends on |
|---|---|---|---|---|
| [T-061](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-061-order-robustness-baseline.md) | Order-Robustness Baseline (R&D) | S | MEDIUM | — |
| [T-062](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-062-dialect-inventory-review.md) | Nepali Dialect, Degradation & Accent Inventory Review (R&D) | S | MEDIUM | — |
| [T-063](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-063-annotation-rules-amendment.md) | Annotation-Rules Amendment (dialect × style axes, permutation + degradation spec) | M | HIGH | T-061, T-062 |
| [T-064](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-064-order-dialect-authoring.md) | Order, Dialect & Clipped-Tail Authoring Extension | L | HIGH | T-063 |
| [T-065](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-065-harness-robustness-gates.md) | Harness Robustness Gates (all five dimensions, one framework) | L | HIGH | T-064 |
| [T-066](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md) | Degradation Round-Trip Extension (SNR mixing, rate/tempo/quality cells, voice bank) | L | HIGH | T-062, T-063 |
| [T-067](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-067-gate-failure-verification.md) | Gate-Failure Verification (every gate trips in isolation) | M | MEDIUM | T-065, T-066 |
| [T-068](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-068-pinned-corpus-no-disturbance.md) | Pinned-Corpus No-Disturbance & Leak-Guard Verification | M | MEDIUM | T-064, T-065 |
| [T-069](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-069-evidence-pack-gap-register.md) | Evidence Pack & Gap Register (machine-checked) | M | HIGH | T-065, T-066, T-067 |

**Off the critical path.** TG-11 adds nothing to `T-033 → T-034 → T-035 → T-036 → T-037 → T-038`. T-061 measures the artifact that exists; T-065 *extends* the T-038 harness rather than forking it; a required harness output is a T-038/T-065 change, not a second runner. Most of the group runs on the CPU/authoring side. The two steps that need the training box are bounded: T-061's fixture scoring (a forward pass over ~800 short utterances on the existing artifact) and T-066's extended round trip, whose cost is stated as a parameter (`variants_per_utterance` × the cell grid × the row count) rather than discovered in a run.

---

## 11. Options weighed

| Option | Verdict |
|---|---|
| **Leave order handling to the LLM fallback** (the encoder abstains on non-canonical order; the long-tail brain answers) | **Rejected.** The encoder is the fast, on-device, deterministic path (`encoder_contract.yaml:340-356`); routing every reordered utterance to the slow path converts an untested claim into a latency regression against NFR-002, and the ladder's fall-through is already an integration item (I-2) that does not exist yet |
| **Architecture change** — relative position encodings, or mean-pooling instead of `[CLS]` | **Rejected for TG-11.** Both would invalidate the T-033 bake-off result and the T-035 contract's `pooling: "[CLS]"` (`:60`), force a full retrain plus a re-export, and neither is *known* to be the binding constraint before T-061 measures the gap. If T-061 shows a collapse that augmentation cannot fix, that finding routes to a **new** design task with a retrain, not to a silent contract edit |
| **Train on all operators including Tier B** | **Rejected.** It spends the 117M budget on strings no speaker produces, to move a number that the product does not need to be green. Tier B stays a diagnostic until T-061 shows the model handles it (§6) |
| **Add dialects as new `register` values** | **Rejected.** `register` selects the mixture bucket (`build_dataset.py:77-82`); new values would change the 60/25/15 arithmetic for the whole corpus. Orthogonal tags cost nothing (§5.1) |
| **Append robustness rows to `golden_corpus.jsonl`** | **Rejected.** Moves the revision tag and invalidates every recorded baseline, for derived rows that would dilute the pinned §9.1 coverage set (§8) |
| **A dialect classification head** | **Rejected.** The taxonomy is closed and the logit order is a contract (`encoder_contract.yaml:58-98`); a dialect head is a different product decision with its own data and privacy story |
| **Claim accent coverage from the piper round trip** | **Rejected as dishonest.** The pass produces STT-error robustness, not accent modelling (§5.5) |

---

## 12. Out of scope

- **Any runtime code.** No interpreter change, no `IntentEncoderInterpreter` change, no settings UI, no new user-facing string (so NFR-023/NFR-024 are untouched).
- **Any taxonomy or logit-order change.** 12 intents, 13 BIO tags, unchanged.
- **Any gate-number change to the existing eight.** The new gates are additive; `max_gap_vs_gemini: 0.03` is *cited* as precedent, never re-tuned.
- **Retraining.** T-061 measures; whether to retrain with the new augmentation is a recorded decision at the end of the group.
- **Real user audio, real recordings, or any consent-bearing data.** Fixtures are synthetic over the existing entity banks; FR-005's on-device enrolment path is untouched. **This is a scope line, not a claim of coverage**: it is exactly why GAP-2 (real slurred/elder speech) and GAP-3 (real regional accent) are recorded as gaps rather than closed here (§7.8).
- **Collecting real-world noise.** GAP-1 names the licensed noise corpus that would be needed; acquiring it is a separate procurement with its own licensing terms, not part of this group.
- **Vendoring or commissioning a new TTS voice.** T-066 adds synthesis *parameters* and a multi-voice *interface* over whatever bank exists; acquiring and licensing Nepali voices is a data-acquisition project (GAP-3).
- **Resolvers.** The resolve-through check (§5.3) *tests* the shipped resolvers' tolerance; changing them is a different task's work.

---

## 13. Risks and mitigations

- **R-1 — Contamination via the parent chain (HIGH).** A permuted or dialect row derived from a golden row is invisible to the exactness leak guard, and the blind spot is already measured at 118 rows for the existing noise pass. *Mitigation:* the transitive `parent_leak` counter and the separate-fixture discipline (§8, T-064), verified by T-068 with a fixture that must be refused.
- **R-2 — A gate that cannot be resolved statistically (HIGH).** A 3-point gate on a 200-row fixture is noise; the team would then either waive it or chase it. *Mitigation:* the fixture sizes are design parameters (§7.6) and the CI arithmetic is written into each gate definition so the size cannot be quietly reduced.
- **R-3 — Gates pass by abstention (MEDIUM).** Closed-intent accuracy and abstention precision can move in opposite directions. *Mitigation:* the abstention-delta clamp and the span-F1 clause in §7.1.
- **R-4 — Permutation corrupts a boundary case (HIGH).** `ack_med` vs refusal, `emergency` vs `health_query` are polarity-sensitive. *Mitigation:* the frozen-material list (§4.2) is machine-checked at authoring, emergency rows are `O0`-only, and the gate prints those families separately.
- **R-5 — An unauthored dialect is mistaken for a covered one (MEDIUM).** A five-value axis invites the reading that all five are supported. *Mitigation:* T-062 decides which slices are claimed; the design states the evidence-bound claim explicitly (§7.2) and the unclaimed list goes in the group notes.
- **R-6 — Order rows distort the mixture (MEDIUM).** Permuting upstream of the noise pass changes noised-bucket composition. *Mitigation:* per-source counters in the mixture report and the unchanged floors (§8); the supply-capping rule (`annotation_rules.yaml:224-230`) is never relaxed for this supply.
- **R-7 — Determinism lost in the noise pass (HIGH).** A seed/parameter change makes the noised set irreproducible and the corpus tag meaningless. *Mitigation:* the declared parameter-tuple table and byte-for-byte re-derivation check in T-066.
- **R-8 — Scope creep into a retrain or an architecture change (MEDIUM).** *Mitigation:* §11 records the rejection with reasons; a collapse found by T-061 routes to a new design task rather than an in-place contract edit.
- **R-9 — A dialect row the resolver cannot consume (MEDIUM).** Training the encoder to emit an unconsumable surface moves the failure one layer later, inside confirm-before-execute. *Mitigation:* the resolve-through check and the `resolver_blocked` marking (§5.3).
- **R-10 — The `query`-`time` span question is decided by accident (LOW).** §3.3 shows one half of the brief's example is a span-policy question. *Mitigation:* it is recorded as OQ-1 and owned by T-063, not by the robustness implementation.
- **R-11 — A gate is rendered green for a dimension nobody measured (HIGH).** The most damaging outcome available to this group is not a failing gate; it is a *passing* one whose fixture was thin, whose dimension was a proxy, or which was never wired at all. *Mitigation:* the evidence pack is machine-checked (§7.8, T-069) so a gate cannot exist without a table row and a table row cannot exist without a fixture and a failing fixture; gaps are rendered as gaps; and no dimension is claimed from a sweep fixture alone.
- **R-12 — A proxy is reported as the thing it proxies (HIGH).** The slur cell grid is not dysarthric speech, multi-voice synthesis is not regional accent, and the piper round trip is not accent modelling at all. Each of the three is named as a proxy in the design (§5.5, §7.4b, §7.5) and each carries a gap entry with the data that would make it real. *Mitigation:* T-069's pack carries the proxy/gap status per row, and T-062's determination governs the wording.
- **R-13 — The noise ladder is measured in the wrong domain (MEDIUM).** Mixing white noise on the waveform and on the mel features give different effective SNRs at the same nominal dB, so two runs' numbers are not comparable unless the domain is declared. *Mitigation:* the domain is a required, recorded parameter of the noise fixture (§7.3) and appears in the evidence pack's mechanism column.
- **R-14 — The degradation supply is unaffordable (MEDIUM).** The noise ladder and the articulation cell grid multiply the round-trip cost by (levels × cells) over the row count, against a GPU host that is shared with training. *Mitigation:* the passes are idempotent and resumable, the cost is stated as an explicit parameter (`variants_per_utterance` × grid × rows) before the run rather than discovered inside it, and a reduced grid is a recorded decision with its resolution loss stated — never a silent shrink.

---

## 14. Open questions

- **OQ-1 — Do `query` rows supervise a `time` span?** Today they supervise none (§3.3). The brief's example expects `भोलि` to be a slot. Recommendation: yes for the relative-day family (`भोलि/आज/पर्सि` + weather/date), which is a small, bounded amendment to `annotation_rules.spans`; it changes what the harness's slot F1 compares, so T-063 owns it and T-065 wires any consequent metric change.
- **OQ-2 — Which dialect slices does the product claim?** Answered by T-062. The design's five-value inventory is a working hypothesis, not a finding.
- **OQ-3 — Is Tier B promoted to a gate?** Only if T-061 measures the model already within 6 points on `O2`/`O4`; otherwise Tier B stays a reported diagnostic indefinitely and the group notes say so.
- **OQ-4 — Does the augmentation justify a retrain?** A group-end decision from T-061's measured gap and T-064's supply numbers; no retrain is budgeted in this group.
- **OQ-5 — Does the Terai slice need a within-Nepali code-mixing register** (Maithili/Bhojpuri function words), or does the existing `code_switched` register already capture it? T-062 rules; if a new *register* is needed, the mixture arithmetic (`annotation_rules.yaml:210-216`) must be revisited explicitly.
- **OQ-6 — The artifact named "v4" in the brief.** At `master` `41daeb6` the pinned encoder is the T-036 **v3** 8k-topup export (`ModelCatalog.intentEncoderSpike`, run `t036-full-0.1.0-internal-noised6b-topup-*`, artifact sha256 prefix `d8f549ec…`, 109,079,441 B — `ModelCatalog.swift:1117`, `IntentEncoderSideload.swift:79`). T-061 names its artifact by **digest and run id**, never by a version word, so a v4 landing mid-flight changes which digest is measured and nothing else.
- **OQ-7 — Which domain does the SNR ladder mix in?** The waveform (whisper.cpp path) or the mel features (HF path, matching `dataset.py:38-44`)? The two are not numerically comparable, so this is a decision, not a detail — T-066 makes it and records it, and the evidence pack's mechanism column carries it (R-13).
- **OQ-8 — Is the noise ladder's 3 dB floor the right floor?** The design takes it from the existing augmentation band (`dataset.py:42-43`) rather than from a product requirement. If the deployment reality is a louder room than the band anticipates, the floor — not the threshold — is what needs revisiting, and the answer is a data-acquisition question (GAP-1), not a threshold tweak.
- **OQ-9 — Does the project procure the GAP-1 noise corpus and the GAP-3 voices?** Both are procurement decisions with licence and cost consequences, outside a task group's authority. The design records what each would buy and what claim it would unblock; a "no" leaves the corresponding gate permanently unwired and permanently visible as a gap.

---

## 15. Definition-of-done mapping (for the group)

- [ ] Every dimension in §7.8 that is measurable has a gate in `eval_golden.py`, readable from `config.yaml:gates`, failing closed on a missing or stale fixture, exiting non-zero through the existing path (§7.7)
- [ ] **Every gate trips in isolation**: a sweep fixture per dimension, exiting 1 with exactly the one gate it targets, registered in `run_fixture_sweep.sh` (T-067)
- [ ] Every fixture carries a revision tag, and every gate output line carries `fixture_id@<sha8>`; the manifest records the fixture hashes and the paired/discordant counts (§7.7)
- [ ] Fixture sizes meet §7.6, the exact row ids are enumerated in the fixture manifest, and the paired statistics are printed with each gate result
- [ ] The evidence pack (§7.8) is a machine-checked artifact: no gate without a table row, no table row without a fixture and a failing fixture, and a test fails when a gate is added, renamed, re-thresholded or removed without it (T-069)
- [ ] **Unmeasurable dimensions are rendered as gaps, never as green gates**: GAP-1…GAP-4 each carry what they cannot measure, why, and the data needed to close them (§7.8)
- [ ] Proxies are labelled as proxies wherever they appear: the piper round trip is not accent modelling (§5.5), the articulation grid is not dysarthric speech (§7.4b), multi-voice synthesis is not regional accent (§7.5), and the noise ladder covers white noise only (§7.3)
- [ ] The pinned corpus is byte-identical (`--check` green, `sha256(golden_corpus.jsonl)` unchanged) and the revision tag has not moved (§8)
- [ ] Every new fixture is registered in the leak guard, and the transitive `parent_leak` counter refuses a derived row whose ancestor is held out — proven by a fixture that must be refused (§8, T-068)
- [ ] `annotation_rules.yaml` carries the `dialect` and `style` axes, the operator/frozen-material spec and the degradation classes; no label, tag or logit order changed (§5.1)
- [ ] The honest limits are recorded: dialect claims are evidence-bound and slice-scoped (§7.2); the 117M absorbable/not-absorbable table is in the notes (§6)
- [ ] No PII, no secret, no full 40-character hash in any deliverable (NFR-016)
