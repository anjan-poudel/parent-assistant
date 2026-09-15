# STT Error Correction — Design Addendum to TG-12

**Status:** design (doc-only). No code, no training, no GPU, no `xcodebuild`, no model artifact is produced by this document.
**Amends:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` (merged, `f4836ae`). This addendum **adds a layer** and **re-scopes an exclusion**; it does not edit the merged original.
**Task group:** TG-12 (`T-070`–`T-079`) — **no new task IDs** (§9).
**Delivery model:** **two phases** (§6.5–§6.8). Phase 1 applies, logs and observes, and **no brain behaviour depends on the signal**. Phase 2 is behind numeric activation conditions and is independently removable.
**Baseline revision read for this design:** `bbfb88e373e66e1821fc4e93659fcf3a6564338b` (`master`, 2026-09-15).
**Corpus revision referred to throughout:** `7f71b8ae` (`sha256(eval/golden_corpus.jsonl)[:8]`, 8 000 rows) — unchanged by this design.

---

## 1. What this addendum changes, and why

### 1.1 The requirement

STT transcribes **content words** with typos and truncations. The worked example, from the user: the decoder emits **भोलि + मौस** where the utterance was **भोलि + मौसम**. The intent is unambiguous from the surviving key words, but the typo reaches the intent model as a word the model was never trained on. The requirement is a correction layer that repairs the typo **before** the intent model reads it.

### 1.2 The ruling this design preserves

The correction is a **deterministic layer between STT and the intent model**. It is **never inside the brain's prompt.** Three reasons were ruled, and they are the right ones:

1. **The encoder cannot autocorrect.** It is a 117M-parameter classifier with a slot head, not a generative model. There is no mechanism by which an instruction to it would repair a token.
2. **Two-step prompting on the 4B costs the 4 s NFR budget and is unverifiable.** NFR-002 budgets 4.0 s end-to-end; the picker brain has a 10 s timeout with one retry (`LocalIntentInterpreter.swift:47-49`). A second pass over the picker is a second model call on the hot path, and a prompt-driven correction produces a *different transcript on every run* — nothing about it is reproducible, so nothing about it can be gated.
3. **Safety boundaries blur inside prompts.** A prompt that says "fix the typos" is a prompt that can rewrite `नखाए` (not eaten) into `खाए` (eaten). TG-12's D-1 exists precisely to keep a rewrite away from the medication-acknowledgement path; a generative rewriter inside the brain undoes that decision.

**This addendum adds no instruction to any prompt, in either phase, and it is not a model.** It is a table lookup with a bounded search, a calibrated confidence gate, and a decision log.

### 1.3 The conflict with the merged design — stated, not absorbed

The merged TG-12 design is explicit, twice, that this layer must not exist:

> **D-2** (`:41`): *"There is no learned component in this design. Every rewrite is a lookup in a variant table or a deterministic orthographic rule. No seq2seq "normalizer" model, no LLM rewriter, **no fuzzy matching**."*
>
> **§5** (`:448`, `:451`): *"**Not a spell-checker.** It rewrites forms that are attested variants, not forms that are misspellings. An unattested token passes through unchanged, byte-identical. There is **no edit-distance, no fuzzy match, no dictionary nearest-neighbour**." … "**Not a repair for a wrong STT word.** If the decoder heard the wrong word, a variant table that "corrects" it is guessing. Rules fire on attested variants only."*

Those sentences are about the **canonicalizer**, and they remain true of it. The corrector is a **different layer with a different contract**, and the boundary is re-drawn rather than deleted:

| Layer | Keyed on | Rewrite licence | Failure mode it guards |
|---|---|---|---|
| `DialectCanonicalizer` (TG-12 §4) | **attested dialectal/orthographic variants** | a table entry, sourced from corpus frequency | applying a region's rule to the wrong region |
| `STTCorrector` (this addendum) | **errors the decoder demonstrably makes** | a measured error class + a calibrated confidence gate + a margin | repairing a token that was not a mistake |

**The reason D-2 banned fuzzy matching does not evaporate — it transfers, and it is harder here.** D-2's motivating hazard is `NepaliTextNormalizer`'s (`NepaliTextNormalizer.swift:18-21`): folding `माइया` and `maiya` onto one key, where *"maiya" and "maya" (different people)* become the same key. A corrector that fuzzy-matches a `contact` token can call the wrong person. That is why §5.7's entity veto and prefix-only rule are non-negotiable parts of this design, and why **pass-through is the default** (A-4).

### 1.4 What does *not* change, in either phase

- **The safety net still reads the ORIGINAL transcript, first, always** (TG-12 D-1). Unchanged and restated in §6.3.
- **The encoder's routing is untouched in Phase 1** — the same bands, the same `acceptThreshold`, the same escalation logic, the same abstention reasons. Phase 2(a) is the only thing that would touch it, and only behind its own flag and its own numeric gate.
- **The cache key is still `NepaliTextNormalizer.normalize`.**
- **`IntentCommandCache`, `IntentRouter`, `CommandRouter`, the confirmation flow, the band constants** — untouched.
- **The picker's `{transcript}` stays the original sanitised transcript, byte-identical to today** (§6.2, E-17 preserved).
- **No new intent label, BIO tag, head, gate constant or training run.** The 12 labels and 13 tags are closed (`annotation_rules.yaml:28-49`, `:106-109`).
- **The corpus does not move.** `sha256(eval/golden_corpus.jsonl)[:8] == 7f71b8ae` after every change in this design.

---

## 2. Recorded decisions

### A-1 — Deterministic, between STT and the intent model, never inside a prompt

Restating the ruling in the shape of the design. The corrector is a pure function: no model, no sampling, no network, no clock, no randomness. Same input, same output, byte-for-byte, on any host. A prompt-driven correction cannot satisfy that sentence, which is why it is not the design.

### A-2 — Correction ≠ canonicalization: the §5 exclusion is re-scoped, not repealed

The merged design's "no edit-distance, no fuzzy match" applies to the canonicalizer, where it stays true. The corrector is the pattern it refused. Both layers now exist and the boundary between them is the table in §1.3, with the ordering fixed in §6.1. A reader of the merged document needs this addendum to know the boundary moved; a reader of this addendum needs §5 of the merged document to know why the canonicalizer is still strict.

### A-3 — The dictionary and the phonetic key come from a measurement, never from intuition

This is the design's first task, not a preliminary to it (§4). Every error class the corrector recognises, every fold in the phonetic key, and every entry in the correction lexicon is traceable to a count over the piper→whisper round-trip pairs. **A fold with a measured count of zero is not in the key.** A class with no measured instances is not in the class set. This is the same discipline as TG-12 §4.3.1's sourcing rule, applied to a different question.

### A-4 — Pass-through is the default; a wrong correction is worse than none

The corrector's job is not to correct. It is to correct **when it is sure**, and to leave the transcript alone otherwise. A wrong correction feeds the model a word the user did not say, and — unlike an uncorrected typo — it produces a confident, well-formed, wrong input. The gate set therefore leads with precision (§7 C-1a) and with a pass-through gate (§7 C-3), and the honest headline metric is not "accuracy on what it corrected" but "**how much it left alone, and why**".

### A-5 — Confidence is a threshold **and** a margin

A score above τ is not enough. The corrector applies a correction only when `score ≥ τ_correct` **and** `score − runnerUp ≥ δ`. The margin is what protects the measured ambiguous cases: `मौस` has exactly two corpus continuations, `मौसम` and `मौसमको` (§4.7), and a threshold alone would let both clear τ. A near-tie is a pass-through, by rule.

### A-6 — The corrected transcript is a model input, never a transcript of record

Same property TG-12 §4.1 assigns to canonicalization, for the same reason. The corrected string is the encoder's input and nothing else. It is not the cache key, not the value the resolvers search, not the value `IntentLogStore` records, not what the safety net sees. The original is the transcript of record; the correction is a transform applied to one model's input.

### A-7 — The safety net and the emergency/med-ack paths read the ORIGINAL

Non-negotiable, and identical to TG-12 D-1 — with one addition the merged design did not need. Because the corrector runs **upstream of** the canonicalizer, TG-12 §4.7's losslessness equality is now computed over the **composed** transform `correct ∘ canonicalize`. Left unamended, T-077's gate would compute an equality over a transform that is no longer the whole transform, and the corrector would be a hole inside a gate that believes it is covered (§7 C-4, §9).

### A-8 — Span-safe by construction: prefix-only inside required spans

The corrector is **more dangerous than the canonicalizer for span mapping**, because a correction is *usually* length-changing and always in the extending direction: `मौस` → `मौसम` adds a scalar. Where a correction lands inside a **required span** (`contact` for `call`/`send_message`, `time` for `set_reminder` — the set TG-12 §4.5 already names), the corrector applies **prefix completions only**: the noisy token must be a strict prefix of the corrected token, so the correction is a pure extension with an exact anchor, and a substitution or a multi-token repair inside a required span is **refused by the corrector** rather than resolved. §5.7 states the rule and its one asymmetry (the resolved surface is the *corrected* one, which is the whole point of the layer — whereas the canonicalizer's map exists to keep resolution on the original).

### A-9 — Evidence or gap; chosen numbers are labelled chosen

Every threshold in §7 is either measured or marked as **chosen**, and a chosen number is an open question, not a finding. This follows TG-12 D-8 and open question 2 (`escalation_rate ≤ 0.35` *"is a chosen number, not a measured one"*). A-12 is the strongest application of this rule in the design: the corrector's **primary** threshold is not chosen at all — it is calibrated from the measurement.

### A-10 — No new task IDs; the work lands inside T-070/T-072/T-074/T-075/T-076/T-077/T-078/T-079

The requirement is explicit and the structural check agrees (§9). Every piece of this design is an extension of an existing task's stated scope. §9 records the check, including the two near-misses that could have justified a new ID.

### A-11 — None of the user's corrections are exported from the device

A correction pair is *the user's own words, twice*. TG-12 §7 already records that a variant pair is a content-bearing artifact and must not be reconstructed from TG-10's hashed egress channel (gap G-3, referred to TG-10's `T-053`/`T-059`). This addendum does not narrow that referral and does not answer G-3; the corrector's on-device provenance may be counted and its rule ids may egress, the surface forms may not. A-16 owns the distinction between the debugger-facing card/log and the egressing event.

### A-12 — The confidence threshold is **calibrated**, not authored

The default `correctThreshold` is **derived from the measured error distribution at the precision/recall knee**, subject to a non-negotiable precision floor. It ships as **data with the run id that produced it**, never as a Swift literal. It is **configurable on the internal testing card**, and the range the control offers is itself measurement-derived: the **lower bound is the conservative end** and the **upper bound is the loosest threshold at which the never-flips-intent gate still holds** — a debugger may make the corrector more conservative without limit, and may make it less conservative only as far as the invariant permits, because a threshold is an operating point and **not a licence to break an invariant**. §5.5.1 is the procedure; §7 C-9 gates its provenance.

### A-13 — Two phases, and Phase 1 is independently shippable

**Phase 1** (§6.6) applies corrections, logs every decision with a closed-vocabulary reason, adds the "Last correction" line to the internal testing card, emits structured observability events, and passes a non-compelling correction note into the 4B's escalation context. **No brain behaviour depends on the signal.**

**Phase 2** (§6.7) contains exactly two candidate consumers — an encoder-side **routing** discount and a 4B-side structured reasoning context — each behind its own flag, each with its **own numeric activation condition measured from Phase-1 logs**. Phase 2's code paths are additive and flag-defaulted-off: deleting them leaves Phase 1 fully functional. **This is a hard structural requirement, not a packaging preference**: Phase 1 is the MVP and ships alone.

### A-14 — The signal is passed, never compelled

In Phase 1 nothing reads the correction signal to make a decision. The correction **transforms the transcript** — that is the layer's function and it is what the requirement asked for — but the **signal about the correction** (the note, the confidence, the class, the log) is inert with respect to behaviour: it cannot change a band, an escalation, an intent, a slot, a reply, or a routing decision. The picker brain may read the note in its context and may use or ignore it; that is the model's business, and §6.2 gates the cost of putting it there.

**Precision on one phrase, because it is the one place this design could be misread.** "The encoder's input and routing stay untouched" means: *the signal* touches neither. The corrected **transcript** is the encoder's input — that is the layer's whole purpose — and A-15 is what keeps that from breaking the encoder's training identity. What is forbidden is any correction *metadata* entering the encoder's input (it would break the tokenizer and span contract, and the input has no prompt to carry it) and any correction signal entering the routing decision (Phase 2(a) is the only thing that would, and only behind a flag and a measured gate).

### A-15 — The encoder's training corpus must be corrected identically, or the identity invariant breaks

The correction is a **transform on the encoder's input**, so the encoder's training distribution has to match it. The round-trip pass already emits aligned pairs (`clean_utterance`, `utterance` — `stt_noise.py:154-155`), so the corrected-noisy bucket is produced by running **the same corrector, with the same frozen lexicon and the same calibrated threshold**, over the `utterance` side. Two consequences, both gated:

- **Train/inference identity holds** only if the corpus build uses the shipped corrector revision. A dataset built with an older lexicon is a silent distribution mismatch, so T-079 records the lexicon revision in the corpus manifest and the promotion gate refuses on a mismatch.
- **The corrected bucket must retain a measured residual corruption.** If the corrector is *too* good, the 60 % noise bucket collapses toward clean and the encoder loses exactly the robustness the bucket exists to train (`hard_floor_stt_noised 0.55`, `annotation_rules.yaml:229-230`). §7 C-10 gates the residual corruption share, and the honest possibility is that **a stronger corrector requires a noisier round trip** — a real coupling between this layer and the mixture, recorded rather than discovered.

### A-16 — The decision log and the observability event are different artifacts with different privacy rules

The requirement's log line (`corrected X→Y (conf 0.93)`) names the user's own words, and a human debugger needs exactly that. So there are two outputs with two contracts:

| | Decision log / card | Observability event |
|---|---|---|
| Audience | the human debugger, on the device | the structured pipeline (counts, T-049/T-050 precedent) |
| Carries | the pair, the confidence, the class, the entry id, the reason | `applied`, `reason` (enum), `errorClass`, `entryID`, `lexiconRevision`, **binned** confidence/margin, counts |
| Surfaces | yes — on-device, debug surfaces only | **never** (§7 C-6, NFR-016) |
| Persistence | the card is in-memory, last-turn only, never persisted, never logged — the `Last turn` precedent | retained per the existing observability retention rules |

**The reason vocabulary is closed** — an enum, not free text — because it is the substrate Phase 2's activation statistics are computed from. A free-text reason would make Phase 2 unmeasurable, which is why this is a design decision and not a logging style.

---

## 3. Ground truth read for this addendum

Every row read against the worktree at `bbfb88e` before writing. Only facts that shape this design are listed.

| Fact | Where |
|---|---|
| The corrector's insertion point: `InputSanitiser.sanitise(transcript, level: .quarantine)` inside `interpret` | `IntentEncoderInterpreter.swift:298` |
| Span offsets are **Unicode scalars** into the **sanitised** transcript, base 0, end-exclusive | `IntentEncoderInterpreter.swift:41-57`; `:818-841` (`wordScalarOffsets`, `scalarSlice`); `annotation_rules.yaml:96-104` |
| `IntentEncoderSpan.text == sanitisedTranscript[start..<end]`, reconstructed by slicing, never by joining tokens | `IntentEncoderInterpreter.swift:41-44`, `:835-845` |
| The contract's own warning: UTF-16 offsets and `Character` counting are **wrong** for Devanagari clusters | `annotation_rules.yaml:101-104` |
| Abstention reasons are a closed, machine-readable, content-free set | `IntentEncoderInterpreter.swift:16-33` |
| **The picker's prompt is a fine-tune artifact**: `IntentPrompt.build` is the source of truth, mirrored byte-for-byte by `tools/train-intent/seeds/prompt_template.txt`, which `train_qlora.py` and `eval_golden.py` tokenize raw | `IntentPrompt.swift:44-55`, `:60-69` |
| **Its size budget**: the on-device brain runs a **1,024-token** context; the template measures **696 qwen3 / 677 gemma tokens**, leaving ~300 for utterance + JSON; a 2,361-token revision returned EMPTY completions; a **53-token trim collapsed emergency recognition 5/7 → 0/7** | `IntentPrompt.swift:29-42`, `:76-79` |
| `IntentPromptTests` pins a character ceiling calibrated against the real tokenizer, so a silent size regression cannot return | `IntentPrompt.swift:40-42` |
| The three placeholders are the only interpolations; the seed renders them as `{language_hint}`, `{medications}`, `{transcript}` | `IntentPrompt.swift:49-51`, `:44-55`; `tools/train-intent/src/intent_prompt.py:13-17` |
| A missing placeholder raises, because a renderer filling only some would train on a prompt containing literal placeholder text | `intent_prompt.py:23-38`, `:1-6` |
| The prompt is built identically by the cloud and on-device paths, sanitisation running **before** the prompt string | `GeminiCommandInterpreter.swift:74-75`; `LlamaCommandInterpreter.swift:452`, `:466-468` |
| `picker_prompt_build` is measured separately from sanitisation, which is deliberately outside the span | `LlamaCommandInterpreter.swift:466-468` |
| The round trip is `text → piper TTS → audio → bundled Whisper → noisy text` | `tools/train-intent/src/stt_noise.py:1-21` |
| The pass writes **aligned pairs**: `clean_utterance` (parent) + `utterance` (noisy), id `{parent}:noise{n}` | `stt_noise.py:150-159` |
| A round trip that returns the parent unchanged is **discarded** ("teaches nothing") | `stt_noise.py:150-151` |
| `synthesize` passes only `--model` and `--output_file` — no rate, prosody, speaker or seed | `stt_noise.py:30-48` |
| `variants_per_utterance: 2` today (round-1 LLM path used 6) | `config.yaml:28`; `2026-09-15-round2-quality-campaign-plan.md:391-392` |
| The round trip is the **60 % anchor bucket**; below 0.55 the trainer holds | `annotation_rules.yaml:209`, `:229-230` |
| The mixer already reports `span_omitted_under_noise` and `stt_noised_by_parent_register` | `build_encoder_dataset.py:266-272`, `:582` |
| The round-trip pass must never overlap another GPU stage | `config.yaml:97-101` (`allow_overlap: false`) |
| Stage exit-code vocabulary: `0` ok, `1` stage failed, `2` usage, `3` guard-refused, `4` floor unmet | `pipeline_guards.py:33-38` |
| Fixture-sweep precedent: each failing fixture exits with **exactly the one gate it targets** | `eval/fixtures/run_fixture_sweep.sh`; `specs/T-038-notes.md:50-64` |
| A fixture-backend prediction file with a missing id is a hard error, never a silent skip | `specs/T-038-notes.md:83` |
| **The "Last turn" readout precedent**: a `Divider` + label + `ForEach(timing.readout)` block inside the encoder card, monospaced `label`/`value` rows, in-memory on the coordinator, **never persisted, never logged**, unlocalized diagnostic tokens ("the card is an internal-testing surface whose vocabulary must match the device logs it is read against") | `SettingsView.swift:3461-3494`; `TurnTimingBreakdown.swift:71`, `:99`, `:116` |
| `TurnTimingStage` is *"a schema change, so the set is deliberately small and closed"*; `cascade_decision` was added *"so the breakdown shows the decision was taken"* | `TurnTimingBreakdown.swift:45-47`, `:61-67` |
| **The kill-switch precedent**: `DialectBiasSettings` — a UserDefaults toggle whose absent key reads **true** (*"an inspection/escape hatch, not an opt-in gate"*), with `isEnabled`/`setEnabled`/`reset` | `DialectBiasComposer.swift:79-97` |
| **The A/B-arm precedent**: `IntentEncoderPreferences.isCascadeEnabled` — absent key reads **false**, so the behaviour is never in play on a device whose switch was untouched — surfaced as a toggle in the encoder card | `IntentEncoderFeature.swift:102-113`; `AppCoordinator.swift:1239`; `SettingsView.swift:3431-3443` |
| Entity banks: 9 contacts + 10 relationships (+ latin twins), 5 medications, 6 times, 2 apps, 5 appliances, 5 bhajans | `tools/train-intent/seeds/intents.yaml:10-19` |
| Slot labels: `contact, time, medication, message, topic, app` — 6, closed | `annotation_rules.yaml:77-84` |
| The 12 labels / 13 BIO tags are closed | `annotation_rules.yaml:28-49`, `:106-109` |
| The safety net reads the raw transcript before every model | `CommandRouter.swift:716`, `:1494` |
| Emergency list: 17 phrases, substring match | `CommandRouter.swift:1468-1473`, `:1439` |
| Med-ack/denial use whole-token match because `खाए` ⊂ `नखाए` | `CommandRouter.swift:1443-1452` |
| Encoder path behind `#if INTENT_ENCODER`; shipped artifact's gates are RED | `IntentEncoderFeature.swift:52-60`, `:6-8` |
| Gate constants: `closed_intent_accuracy 0.95`, `side_effect_precision 0.97`, `emergency_recall 1.00`, `abstention_precision 0.90` | `config.yaml:58-69` |
| The evidence-pack precedent: machine-readable, re-runnable, per-dimension rows | `tools/train-intent/docs/t033-evidence/`; TG-11 `T-069` |

**Measured for this addendum** (the extraction run's design is grounded in these; all computed over the pinned corpus at `7f71b8ae`, read-only):

| Measurement | Value |
|---|---|
| Rows / whitespace-token instances / distinct tokens | 8 000 / 40 570 / 1 100 |
| Distinct tokens after punctuation strip (the realistic lexicon size) | **1 050** |
| Tokens occurring ≥ 2 / ≥ 5 / exactly once | 877 / 765 / 173 |
| Average tokens per row | 5.07 |
| Rows carrying any span / carrying a `contact` span / a `time` span | 4 563 (57 %) / 1 936 (24 %) / 1 440 (18 %) |
| Script slices (devanagari / latin / code_switched) | 5 508 / 1 678 / 814 — **31 % of rows are not devanagari** |
| Rows containing `मौसम` (the worked example's content word) | 24 — intents `query` 14, `suggest_video` 8, `none` 2; **all 24 carry no spans** |
| Rows containing `भोलि` | 134 |
| Rows containing **both** `भोलि` and `मौसम` | **1** (`gc-query-001`, `query`, script `devanagari`, no spans) |
| Corpus tokens (occurring ≥ 2) that are a strict prefix of another token | 121 — **64 have exactly one continuation, the other 57 have ≥ 2** |
| Continuations of `मौस` | **`मौसम` and `मौसमको` — the worked example is one of the ambiguous 57** |

*Method, so the numbers are re-runnable: NFC-normalize, split on whitespace, strip characters outside `\w` and the Devanagari block, drop empties. The prefix rows are computed over the types occurring **≥ 2 times** (877 types), because a lexicon built from hapax types is a lexicon built from the generator; over all 1 050 types the prefix relation has 164 members (122 unique, 78 ambiguous), and the worked example is ambiguous under either restriction.*

**The three findings that shape the design more than anything else in this table:**

1. **The lexicon is small.** 1 050 types, 765 of them occurring ≥ 5 times. A corrector lexicon built from the corpus's own vocabulary is a data file of about a thousand entries — not a model, not an embedding index, not a neural spell-checker. That is the arithmetic that makes the "deterministic table" ruling feasible rather than aspirational.
2. **The worked example is ambiguous under the strongest naive rule.** `मौस` completes to `मौसम` *or* `मौसमको`. A unique-continuation rule would **refuse the user's own example**, and a shortest-continuation rule would get it right by accident. The paired-keyword prior is therefore not a refinement — it is the mechanism that resolves the motivating case (§5.4).
3. **43 % of rows carry no span at all, and the worked example is one of them.** `gc-query-001` has `slots: {}`, `spans: []`. Correction is riskiest where it touches a side-effecting span and cheapest where it does not; the corpus says the cheap case is nearly half the traffic.

**Four corrections, recorded rather than inherited.**

- **A unit error in the merged design, load-bearing for this addendum.** TG-12 §4.2 declares `CanonicalVariantApplication.originalRange/canonicalRange` to be *"Half-open **UTF-16**-offset ranges, matching the contract the encoder's span decoder already uses (`annotation_rules.yaml:96-104`)"*. The cited block says the opposite: `slots.offsets.unit: unicode_scalar`, with a `swift_note` stating that UTF-16 offsets *"are wrong for Devanagari clusters — a known regression class for this project"*. The shipped runtime agrees with the contract (`IntentEncoderInterpreter.swift:818-841`, `:41-57`). **The corrector's offset map is defined in Unicode scalars**, and T-075 should correct the canonicalizer's doc comment while it is in that file. This is not pedantry here: the corrector's entire job is changing string length, so an off-by-a-cluster unit error in its map is a wrong-span bug, and a wrong `contact` span is a wrong phone call.
- **The round-trip variant count is 2, not 6.** `config.yaml:28` says `variants_per_utterance: 2`; the round-1 LLM path used 6 (`2026-09-15-round2-quality-campaign-plan.md:391-392`), and TG-11's `T-066` is the task that raises it and adds the noise/articulation cell grid. Any statement of "the round trip produces N corrupted pairs" must read the value from config at run time, not from a spec.
- **"Confusion" already means something else in this repo.** The round-2 campaign's `confusion_pair` classes (`cp1a`…`cp5b`) are **intent** confusions — `create_calendar_event~set_reminder`, `guide~query`, `health_query~emergency` (`gen_round2_requests.py:231-393`). This addendum's subject is **STT error classes**. The two must not share a word in any artifact, gate name or fixture name, or a future reader will read the intent-confusion report as the error distribution. This design uses **error class** for its own concept and reserves *confusion pair* for the round-2 sense.
- **The picker's prompt is a fine-tune artifact with a measured 1,024-token ceiling and a documented emergency-recognition cliff.** The consequence is in §6.2: putting a correction note into that prompt is not a free addition, it is a change to a trained artifact's input distribution inside a budget with ~300 tokens of headroom, and the project has already measured a 53-token change that took emergency recognition from 5/7 draws to 0/7. Any prompt change this design proposes is gated accordingly (§7 C-8), and the fallback that costs no prompt tokens is specified.

---

## 4. The error-distribution measurement (T-070 scope extension)

This is the first task the requirement names, and it is data collection before it is code. It extends [T-070](../../../.ai-sdd/outputs/plan-tasks/tasks/TG-12-crux-resolution-pipeline/T-070-variant-coverage-measurement.md), whose scope already contains the clause this widens (*"Any claim that a variant is 'an STT corruption' must be checked against what the noise pass actually produces"*) — from a per-candidate reproduction check into a full distribution.

### 4.1 The source corpus — aligned pairs that already exist

The pass at `tools/train-intent/src/stt_noise.py` emits one row per successful round trip carrying **both** strings:

```jsonc
{ "id": "<parent>:noise<n>", "clean_utterance": "<parent text>",   // stt_noise.py:154
  "utterance": "<decoder output>",                                  // stt_noise.py:155
  "source": "stt_noise:<parent register>", ... }
```

So the error corpus is a **parallel text**: `(clean, noisy)` pairs, already aligned at the row level, already tagged with the parent register, and **already discarded when identical** (`stt_noise.py:150-151`) — every surviving row is a row where the decoder got something different. Nothing needs to be re-rendered, no GPU is needed, and the pass that produced it deliberately never overlaps another GPU stage (`config.yaml:97-101`). The extraction is a **CPU-only text job over an existing file**, and that is the whole reason it is the first step rather than a data-collection project.

Two consequences the design accepts and states:

- **The pairs live on the training box, not in the repo.** `data/noised.jsonl` (or `data/round2/round2_noised.jsonl`) is a large, generated, gitignored artifact. The extraction's run manifest records the input path, its digest and its row count, so the report is re-runnable on the box that holds the data and auditable everywhere.
- **T-066 will widen the source.** When `variants_per_utterance` rises and the noise/articulation cells land, the same extraction must be re-run **sliced by variant index and by cell**, and the corrector's evidence base — and therefore its calibrated threshold — changes with it. §9 binds that to T-079.

### 4.2 The alignment

Word-level, deterministic, and deliberately the *same* edit model the corrector uses:

1. Tokenize both sides on whitespace (NFC first; punctuation **retained** through alignment and stripped only from lexicon keys — the corpus's tokens carry trailing commas, which inflate the vocabulary by 49 types and create fake "prefix ambiguity" pairs like `aaunus` → `aaunus,`).
2. Align with a bounded Levenshtein over tokens, cost 1 per substitution / insertion / deletion.
3. **Tie-break toward substitution.** At equal cost, a substitution is preferred over a delete-plus-insert pair. This is the same preference TG-12 §4.5 states for table authoring, and it keeps the alignment from reporting one substitution as two events.
4. Unaligned spans beyond the bound are recorded as `unaligned` and counted, never silently attached to the nearest pair. The `unaligned` share is a reported number and its size is evidence about the alignment, not a defect to hide.

### 4.3 The error classes

Each aligned event is classified. The class set is **closed** and derived from the requirement's own list, then validated against what the data actually contains:

| Class | Definition | The requirement's name for it |
|---|---|---|
| `truncation` | the noisy token is a strict **prefix** of the clean token (the decoder stopped early) | truncation — *the worked example* |
| `prefix_extension` | the clean token is a strict prefix of the noisy token (the decoder ran on) | truncation, other direction |
| `phonetic_confusion` | equal-length substitution whose scalars differ within a **measured** confusion group | स/श/ष, vowel length, halanta drop, nasal substitution |
| `substitution_other` | equal-length substitution outside every measured group | — |
| `insertion` / `deletion` | length-changing, not a prefix relation | insertions/deletions |
| `merger` | one clean token ↔ two-or-more noisy tokens | mis-segmentation |
| `split` | two-or-more clean tokens ↔ one noisy token | mis-segmentation |
| `script_drift` | devanagari ↔ latin on the same token position | (the round trip can romanize) |
| `numeral_fold` | digit form changes (`८` ↔ `8`, `8` ↔ `८`) | — |

**`phonetic_confusion` is a container, not a class.** Each event in it is assigned a **confusion group** from a closed list — `sibilant` (स/श/ष), `vowel_length`, `halanta`, `nasal`, `voicing`, `retroflex_dental`, `aspiration`, `semivowel` — **and a group is only reported if the measurement puts events in it.** A group with zero events is printed as zero and is **not** a fold in the phonetic key (§5.3). This is A-3 made mechanical.

### 4.4 The report

Per class, and per confusion group within `phonetic_confusion`:

1. **Event count and share** of all aligned events, and of all *corrupted rows* (a row can carry several events — the two denominators differ and both are printed).
2. **Frequency per parent register** (`stt_noised_by_parent_register` is already a mixer concept, `build_encoder_dataset.py`), per `script` slice (devanagari / latin / code_switched — and the corpus is **31 % non-devanagari**, §3, so this slice is a real axis and not a formality), and per parent-length band (1–3 / 4–6 / 7+ tokens).
3. **Top-K word lists** — the K most frequent `(clean → noisy)` pairs per class, and the K most frequent clean tokens affected per class, with counts. K = 20, and the list is a **count table, not prose**. This is the table the correction lexicon is authored from.
4. **The hand/generated split** wherever the parent can be traced to a golden row, on the same reasoning as T-070's existing rule: a class that exists only in templated rows is evidence about the generator.
5. **The `unaligned` and unchanged-row counters**, printed, never omitted.
6. **The variant-index and cell breakdown**, so the report survives T-066.
7. **The false-positive population** — the count and the token list of positions where the decoder was *correct*, because §5.5.1's threshold calibration is a precision/recall problem and precision is computed over the correct tokens, not over the errors. A report that omits this makes the calibration impossible.

**Output shape:** machine-readable JSON plus a run manifest carrying the exact command, the input file digest, the segmenter revision, and the corpus revision — under `tools/train-intent/docs/tg12-evidence/stt-error-distribution/`, following the T-033 evidence-pack precedent and TG-11's T-069 row shape. A prose description alone is not evidence and does not close this row.

### 4.5 The sample, and why it is a sample at all

The extraction itself is cheap enough to run over the **full population** of pairs — it is a text alignment, no model, no GPU. So:

- **Full population for every count in §4.4.** No sampling error in the frequency tables.
- **A stratified verification sample of 200 aligned events**, hand-checked by a native speaker, drawn as: 20 per class (or all events, where a class has fewer), stratified by register. Its purpose is **not** to estimate frequencies — the full population does that — but to answer *"is the classifier right about what it called a truncation?"*. The sample's agreement rate is reported; below 0.90 the class definitions are revised and the run repeats, and the disagreement cases are listed by type.
- **A floor.** The run refuses to emit a lexicon-feeding report below **500 aligned error events in total** or below **25 events in the `truncation` class** — `EXIT_FLOOR` (4). Below that, the corrector would be authored from noise, and the house's rule for the same situation is a non-zero hold (`corpus_floor 8000`, `hard_floor_stt_noised 0.55`). The floors are chosen, and are open questions (§12).

### 4.6 The derived phonetic key

Output of the measurement, and an input to the corrector:

- A **fold table**: for each confusion group with measured support, the scalars folded onto one key, each fold carrying the count that justifies it.
- The key is a **function of scalars, not of words**: `key(token) = tuple(fold(scalar) for scalar in token)`. Two tokens collide under the key iff their folded scalar sequences are equal.
- **A fold is admitted only with measured support** (A-3). A linguistically obvious fold with zero measured events is recorded in the report as `proposed, unsupported` and is **not** in the key. This is what keeps the key a description of this decoder rather than a description of Nepali phonology.
- The key's precision cost is measured, not assumed: the report prints the **collision rate** — how many distinct lexicon entries collide under the key — because a key that collides half the vocabulary is a key that produces candidate lists the scorer cannot separate. Collisions are also the corrector's ambiguity source (§5.4), so this number feeds the margin policy.

### 4.7 The worked example, carried through the measurement

Stated because it is the case the requirement is about, and because it is the case that breaks the naive rule:

- **Clean:** `भोलि मौसम कस्तो हुन्छ` — corpus row `gc-query-001`, intent `query`, **no spans**, present at `7f71b8ae`.
- **Expected noisy form under `truncation`:** the decoder stops early inside the content word → `मौस`.
- **The measurement's contribution.** It reports the `truncation` class's frequency and its top-K pairs (the `मौस → मौसम` family among them), and it reports the **continuation ambiguity** measured in §3: `मौस` completes to two corpus entries.
- **The consequence for the corrector.** `मौसम` and `मौसमको` are both `truncation`-completions, both attested, and both reachable from `मौस`. **The prefix rule alone cannot choose.** What chooses is the paired-keyword prior (§5.4): in the corpus, `मौसम` is the bare noun of a weather frame (`X मौसम कस्तो हुन्छ` — 14 rows) while `मौसमको` is the possessor of a news frame (`मौसमको समाचार …` — 8 rows, all `suggest_video`). `भोलि` + a bare-noun frame + no news cue selects `मौसम`, with a margin.
- **And the honest note.** That margin is *thin*, because `भोलि`+`मौसम` co-occurs in exactly **1** golden row. §5.4's backoff exists because of this number, and §12's first open question is whether the prior is strong enough to be worth its complexity.

### 4.8 Honesty: what this measurement is and is not

- **It is** the error profile of one specific pair: a **Hindi** piper voice (`voices/hi_IN-pratham-medium.onnx`, `config.yaml:23`) reading synthetic Nepali text, decoded by the app's bundled Whisper fine-tune (`config.yaml:19`). That is exactly the profile the corrector is calibrated against, and it is the profile the corpus bucket the encoder trains on is drawn from — so it is the *right* profile for this purpose.
- **It is not** the error profile of elder Nepali speech. TG-11 records the same limit for the same pipeline (`2026-09-15-linguistic-robustness-design.md:226`, GAP-2/GAP-3) and this addendum inherits both gaps rather than restating them as covered.
- **And it has a circularity hazard that must be printed with every number.** The corrector's threshold is calibrated on synthetic round-trip noise and gated on synthetic round-trip noise. A number measured that way is evidence about the **fixture**, not about the world; it is the same class of error as training and evaluating on the same split. It cannot be designed away today — there is no real-noise corpus (TG-11 GAP-1) — so it is **recorded as gap G-A5** and every gate result in §7 and every calibrated number in §5.5 carries it. This is the single largest threat to this design's value and it is stated here rather than discovered later.

---

## 5. The corrector

### 5.1 Where it sits

Inside the intent interpreter, on the sanitiser's output, **immediately before** the canonicalizer:

```
CommandRouter.route(transcript: raw)                        CommandRouter.swift:582
  ├─ emergency phrases        ← RAW, first, always          :716 → :1494   (A-7, unchanged)
  ├─ med-ack / denial         ← RAW, whole-token            :1443-1452     (A-7, unchanged)
  ├─ cache key ← NepaliTextNormalizer.normalize             (unchanged — A-6)
  └─ interpreters
       └─ LocalBrainChain
            ├─ IntentEncoderInterpreter
            │    └─ InputSanitiser.sanitise(.quarantine)     IntentEncoderInterpreter.swift:298
            │         └─ STTCorrector.correct                ◀── NEW (this addendum)
            │              └─ DialectCanonicalizer.canonicalize   ◀── TG-12 §4
            │                   └─ tokenizer → encoder forward pass
            │                        └─ routing: UNTOUCHED in Phase 1 (A-14);
            │                           Phase 2(a) is the only thing that would (§6.7)
            └─ picker brain: original sanitised transcript (§6.2)
                 + a non-compelling correction note (Phase 1)
```

Three properties, each deliberate:

1. **The corrector is upstream of the canonicalizer**, as ruled. Correction restores the token the canonicalizer's table is *keyed on*: `गइछ` truncated to `गइ` is in no table, and no canonicalizer rule can fire on it; corrected first, the canonical rule applies to the restored surface. The reverse order would have the canonicalizer's mis-segmentation rule (O-6) shift the token boundary before the corrector sees it — a different input to the same function, and a different output.
2. **It is inside the interpreter, not at `route`.** Identical reasoning to TG-12 §4.1: a transform at the top of `route` sits upstream of the safety net and the injection sanitiser and re-keys the cache.
3. **It is after the sanitiser**, so the 200-scalar clamp and the injection defence both run first, and a correction can never resurrect clamped text.

### 5.2 The contract

```swift
/// One applied correction. Every application is recorded; there is no
/// silent repair path and no partial application.
struct STTCorrectionApplication: Equatable, Sendable {
    /// Opaque, stable entry identity — `<class>-<n>`, NEVER a surface form.
    /// A lexicon id that contains the corrected word leaks the user's
    /// utterance through an id (A-16, §7 C-6).
    let entryID: String
    let lexiconID: String          // which lexicon file contributed it
    let lexiconRevision: String
    /// The measured error class this entry was authored from (§4.3).
    let errorClass: STTErrorClass
    /// Half-open ranges in **Unicode scalar** units, base 0, end-exclusive —
    /// the contract's `slots.offsets.unit` (annotation_rules.yaml:96-104).
    /// NOT UTF-16: see §3, correction to TG-12 §4.2.
    let originalRange: Range<Int>
    let correctedRange: Range<Int>
    /// Scores are numbers, not content: they may be counted and binned.
    let score: Double
    let margin: Double             // score − runner-up (§5.5)
    let evidence: CorrectionEvidence   // which signals fired, as enum cases
}

/// Why a token was left alone. CLOSED vocabulary — it is the substrate
/// Phase 2's activation statistics are computed from (A-16).
enum CorrectionDecision: Equatable, Sendable {
    case corrected(STTCorrectionApplication)
    case noCandidate                       // generation found nothing
    case belowThreshold(best: Double)      // best candidate under τ
    case ambiguous(margin: Double)         // best − runnerUp under δ
    case safetyVeto(rule: SafetyVetoRule)  // §5.8
    case requiredSpan(spanClass: SpanClass)// not a prefix completion (§5.7)
    case degraded                          // absent/corrupt lexicon — fail closed
    case disabled                          // the A/B control arm
}

enum STTCorrector {
    /// PHASE 1: applies corrections and returns a decision for EVERY token
    /// considered. Pure, synchronous, non-throwing, no I/O (A-1).
    static func correct(
        _ transcript: String,
        lexicon: CorrectionLexicon,
        context: CorrectionContext,      // intent frames + co-occurrence tables
        policy: Policy
    ) -> CorrectionResult

    struct Policy {
        /// A/B arm (§6.4). `.apply` is the MVP default; `.shadow` generates
        /// and logs but applies nothing; `.off` is the control arm.
        var mode: Mode = .apply
        /// CALIBRATED, not authored — the precision/recall knee subject to
        /// the precision floor, frozen into the manifest by the calibration
        /// run and loaded as DATA (A-12, §5.5.1). The literal is the
        /// fail-closed fallback when the manifest is unreadable.
        var correctThreshold: Double = .calibratedFallback
        /// …and only with at least this margin over the runner-up.
        var marginThreshold: Double = 0.15       // CHOSEN — §5.5, §12 OQ-2
        /// The range the internal card may select from. The upper bound is
        /// NOT a taste limit: it is the loosest threshold at which C-2 still
        /// holds on the corrupted slice, derived by the calibration run
        /// (A-12). A threshold is an operating point, not a licence.
        var thresholdRange: ClosedRange<Double> = .calibratedRange
        /// Hard cap on candidates generated per token. A bound, not a tuning.
        var maxCandidates: Int = 8
        /// Refuse every correction that lands inside a required span unless
        /// it is a strict prefix completion (§5.7, A-8). Default true.
        var prefixOnlyInRequiredSpans: Bool = true
        var emitApplications: Bool = true
    }
}

struct CorrectionResult: Sendable {
    /// The model-input transcript. Byte-identical to the input when
    /// nothing applied, and byte-identical when the lexicon is structurally
    /// corrupt (fail-closed — TG-12 D-4 transfers verbatim).
    let corrected: String
    /// Empty iff `corrected == original`. Ordered by `correctedRange`.
    let applications: [STTCorrectionApplication]
    /// One entry per token considered, including the pass-throughs. This is
    /// the Phase-1 log's source and the Phase-2 evidence substrate (A-16).
    let decisions: [TokenDecision]
    /// Which lexicon produced this, and its revision.
    let lexiconRevision: String
    /// The threshold actually used, so a log line can name it.
    let thresholdUsed: Double
    /// True when an absent or structurally corrupt lexicon forced passthrough.
    let degraded: Bool
}
```

**Signature rationale, against the constitution's design principles.** The function never throws; every failure is a *value* (`degraded: true`, `decisions` full of reasons), so fail-soft is testable rather than asserted. It is synchronous, pure, non-retryable and has no async boundary, so it composes with `InputSanitiser.sanitise` (also synchronous and non-throwing) without adding a failure mode to `completion`. There is no I/O on the hot path: the lexicon is decoded once at wiring time, exactly as `DialectLexicon.bundled(in:)` already does (`DialectBiasComposer.swift:139`, `:173`).

**`decisions` is not optional and not a debug extra.** It is what makes Phase 1's primary deliverable (the log and the card) possible and what makes Phase 2's activation conditions measurable at all. A corrector that returns only the corrected string cannot satisfy this design.

### 5.3 Stage C1 — candidate generation

For each **content token** in the sanitised transcript, three independent generators, each bounded, each deterministic, unioned and deduplicated:

1. **Prefix completion against the lexicon.** Every lexicon entry having the token as a strict prefix. This is the generator the requirement names first, and the generator that covers the worked example. **It is deliberately not a unique-continuation rule**: 57 of the 121 prefix-related corpus tokens have ≥ 2 continuations (§3), and `मौस` is one of them. Ambiguity is **scored** (§5.4), not vetoed.
2. **Bounded fuzzy edit distance against the lexicon.** Restricted to entries whose length is within ±2 scalars, cost ≤ 2, and cost ≤ ⌊len/3⌋. The bound is what keeps the generator a lookup rather than a search: with 1 050 lexical entries, a per-token candidate set is at most a few dozen entries before scoring, and scoring prunes to `maxCandidates`.
3. **Phonetic-key lookup.** `key(token)` where the key is the **measured** fold table from §4.6. This is the generator that reaches confusions spelling-distance cannot: a dropped halanta or a स→श substitution is a large edit-distance change in scalars and a zero-distance change in the key.

**Entity-bank generation is not a fourth generator — it is a constraint on the second and third.** The entity banks (`seeds/intents.yaml:10-19`) supply candidate *targets* for `contact`/`medication`/`time`/`app`/`topic` positions, but a fuzzy match onto an entity name is the `maiya`/`maya` hazard in its purest form. §5.8's entity veto governs it.

**Determinism.** Candidates are ordered by `(score desc, lexiconID asc, entryID asc)`, so a tie is broken by data, never by iteration order. The corrector runs identically on two hosts or it is not a corrector.

**Bound.** Generation is `O(tokens × |lexicon|)` worst case, but the length filter and the prefix index make it `O(tokens × candidates)`. `maxCandidates` is enforced at generation, and a test asserts the bound on an adversarial input (§7 C-5).

### 5.4 Stage C2 — scoring, and the paired-keyword prior

```
score(t → c) =  w₁ · similarity(t, c)                 // 1 − editcost/max(len)
              + w₂ · keyMatch(t, c) · classWeight     // measured class support
              + w₃ · prefixEvidence(t, c)             // len(c) − len(t) is small
              + w₄ · frameFit(c, intentFrame)         // slot-type compatibility
              + λ  · pairedKeywordPrior(c | context)  // ◀── the requirement's key idea
```

**The paired-keyword prior, and why it is not a single MI table.** The requirement's formulation is exactly right and the corpus says it needs a backoff:

> *भोलि + मौस makes भोलि + मौसम overwhelmingly likely because भोलि + मौसम co-occur as an intent pair.*

The intended signal is co-occurrence. The measured problem is sparsity: `भोलि`+`मौसम` occurs in **1** row of 8 000 (§3). A raw pointwise-mutual-information table over content-word pairs would assign that pair either zero or a wildly over-fitted weight. So the prior is a **three-level backoff**, each level reported with its coverage so the backoff's work is visible:

- **L1 — exact pair MI.** `PMI(c, w)` over content-word pairs measured **within a row**, from the co-occurrence tables built at authoring time, with a count floor (a pair seen fewer than *n* times does not contribute at L1; *n* is chosen and is open question 3). This is the level the user's example names, and it is the level that fires least often.
- **L2 — frame affinity.** `P(c | frame(w))`, where `frame` is the *class* of the neighbouring content word rather than the word: a time word, a media noun, a medication noun, a relationship term. `आज मौसम कस्तो छ` and `भोलि मौसम कस्तो हुन्छ` share a frame even though `आज` ≠ `भोलि`. This is the level that actually resolves the worked example, because the frame `time-word + <truncated> + कस्तो हुन्छ` is attested **14 times** with `मौसम` and **0 times** with `मौसमको` (which occurs only before `समाचार`). **The corpus's own statistics select `मौसम` on the frame, not on the pair** — and that is a finding, not a convenience.
- **L3 — intent-conditional unigram.** `P(c | intent)` backoff, used when neither L1 nor L2 has evidence. Weakest, and reported separately.

**Where the co-occurrence tables come from.** Built over the **training corpus** (`data/teacher.jsonl` and the round-2 rows), not the 8 000-row golden corpus. The golden corpus is the **eval** corpus: it is the thing that must not be tuned against (and the pipeline's own guards refuse it as training input, `pipeline_guards.assert_not_golden_input`). Using it to build the prior would also be self-referential — the prior would be fitted to the fixture. **The 8 000-row corpus is used for measurement and for gating, never for fitting.** The measured sparsity above (`भोलि`+`मौसम` = 1 row) is a golden-corpus number and is *not* the prior's training base; it is quoted to show why the backoff is needed even where the traffic is dense.

**The honest limit of the prior.** Both corpora are synthetic and template-generated. Co-occurrence in them partly encodes the *template design* rather than the language: `X मौसम कस्तो हुन्छ` is a template, so its co-occurrence is a generator artifact. The prior is therefore a **weak** signal, its coverage is reported per level, and a correction that depends on L1 alone with no L2/L3 support is held to a higher bar, not a lower one. Recorded as gap G-A6.

**Weights.** `w₁…w₄` and `λ` are **authored constants in a data file**, versioned with the lexicon, not code constants. They are fitted on the training corpus and **frozen before the gates run** — a weight re-fit after seeing a gate result is the same class of error as re-tuning a flip threshold until it passes (TG-12 D-8).

### 5.5 Stage C3 — the confidence gate, and the calibrated threshold

A correction applies iff **all** of:

1. `score ≥ policy.correctThreshold`.
2. `score − runnerUp ≥ policy.marginThreshold`, where `runnerUp` is the best competing candidate **for the same token**.
3. `applications` for this token would not exceed one — **one correction per token, never a chain.** A corrector that applies `a → b → c` has no bounded argument for where it stops.
4. No veto fired (§5.8).

**Below any of these: PASS-THROUGH UNTOUCHED.** The token is byte-identical in the output, the decision is recorded with its reason, and the reason travels into the result and into the Phase-1 log (A-4, §7 C-3).

The margin is not decoration — it is the mechanism that handles the measured ambiguity. `मौस` with a bare-noun frame and no news cue: `मौसम` scores above `मौसमको`, and the margin clears δ. `मौस` alone with no context at all: the two candidates tie on similarity, prefix evidence and key, so the margin collapses and the corrector **passes the token through**. That is the designed behaviour, and §7 C-3's fixture is built from exactly this case.

#### 5.5.1 How the default threshold is derived (A-12)

**The default is not authored, and it is not a constant in a Swift file.** It is produced by a calibration run and shipped as data:

1. **Build the calibration set** from the §4 measurement: every aligned error event paired with its true correction (the *positive* population), **and** a large sample of positions where the decoder was **correct** (the *negative* population). The negatives are the point — precision is what the threshold buys, and precision is only defined against tokens that were already right. §4.4.7 makes this population a required report section for exactly this reason.
2. **Sweep** `τ` over the score range, and for each `τ` compute precision and recall of the **applied** corrections against the calibration set.
3. **Find the knee** — the point of maximum curvature on the precision/recall curve, i.e. where lowering `τ` further buys less recall per unit of precision surrendered.
4. **Constrain by the floor.** `precision ≥ 0.95` (C-1a) is non-negotiable, so the shipped default is `argmax recall s.t. precision ≥ 0.95`. The knee is recorded **next to** the chosen point so a later revision can see which of the two bound the operating point — a knee *below* the floor means the floor is doing the work and the corrector is precision-limited; a knee *above* it means recall is being left on the table for no reason and the lexicon, not the threshold, is the problem.
5. **Derive the range, not just the point.** The calibration run also emits:
   - `thresholdRange.lowerBound` — the **most conservative** setting the card may offer (a value at which the corrector is nearly inert; useful for isolating the layer's effect without disabling it), and
   - `thresholdRange.upperBound` — the **loosest** threshold at which **C-2a still holds** on the corrupted intent-stability slice. This is the rule that matters: **the never-flips-intent gate is the absolute floor regardless of threshold**, so the card cannot be slid past it. A debugger may explore the conservative region freely and the aggressive region only as far as the invariant permits.
6. **Freeze and ship.** `correctThresholdDefault` and `thresholdRange` are written into the lexicon manifest with the **run id that produced them**, and loaded as data. An absent or unreadable manifest falls back to `calibratedFallback`, which is deliberately the conservative end — fail-closed, like every other lexicon path in this codebase (TG-12 D-4).
7. **Re-calibrate on change.** The calibration is bound to the lexicon revision **and** the noise source. When T-066 widens the round-trip variants/cells, or when the lexicon is re-authored, the threshold is **stale** and the manifest says so; a stage that loads a stale calibration is refused (§7 C-9). This is the same discipline as `calibration_temperature` in T-079.

**Why the knee *and* the floor, stated plainly.** The requirement is that the default be data-derived rather than arbitrary, and the knee is the data-derived quantity. But the knee is a *shape* property of the curve and the floor is a *safety* property of the system, and when they disagree the floor wins and the disagreement is reported. A design that obeyed the knee alone would let a 0.93-precision operating point ship because the curve bent there.

**Configurability.** The internal testing card exposes `correctThreshold` over `thresholdRange` (§6.6.3), persisted through a `STTCorrectionSettings` enum mirroring `DialectBiasSettings` (`DialectBiasComposer.swift:79-97`) — absent key reads the calibrated default, `reset()` restores it. The card shows the calibrated default **beside** the current value, so a debugger can always see when they have moved off it.

### 5.6 The correction lexicon schema

A new data resource, adopting the shipped `DialectLexicon` / `DialectCentroidTable` shape unchanged (TG-12 D-3), same `formatVersion` + `generation` + `issues()` structure:

```
ios/ElderlyAssistant/Resources/CorrectionLexicon/
  correction-manifest.json        # formatVersion, generation, calibrated threshold + range + run id, weight ids
  correction-truncation.json
  correction-phonetic.json
  correction-boundary.json
  correction-frames.json          # the L2 frame-affinity table
  correction-cooccurrence.json    # the L1 pair table (authored, versioned)
```

```jsonc
{
  "formatVersion": 1,
  "generation": { "status": "AUTHORED-FROM-MEASUREMENT", "path": "<evidence run id>", "date": null },
  "errorClass": "truncation",
  "entries": [
    {
      "id": "trunc-0042",                 // opaque — NEVER a surface form (§7 C-6)
      "noisy": "मौस",                      // the measured decoder output
      "corrected": "मौसम",                 // the parent's content word
      "confusableWith": ["trunc-0043"],   // the other measured continuation (मौसमको)
      "spanClasses": ["topic", "none"],   // which span positions it was measured in
      "evidence": {
        "runRevision": "<stt-error-distribution run id + input digest>",
        "errorClass": "truncation",
        "occurrences": 0,                 // measured; required ≥ 1
        "registers": { "elder_fragmented": 0, "devanagari": 0 },
        "rowIDs": []
      }
    }
  ]
}
```

**Required fields and what they are for:**

| Field | Purpose | Enforced |
|---|---|---|
| `id` | Stable, greppable, **content-free** entry identity. | unique per file; must not contain either surface |
| `noisy` / `corrected` | The repair. | both non-empty; `noisy != corrected` (a no-op entry is a data error) |
| `confusableWith` | The measured competing continuations. Authoring this field is what makes the margin policy auditable rather than emergent. | ids must resolve in the same set |
| `spanClasses` | Which span positions this repair was measured in. Drives §5.7's required-span rule. | subset of the closed 6-label span set (`annotation_rules.yaml:77-84`) |
| `evidence.runRevision` | The extraction run that produced it. | required |
| `evidence.occurrences` | Frequency evidence. | required ≥ 1 |
| `evidence.registers` | Per-register split, so a templated-only entry is visible. | required |

`correction-manifest.json` additionally carries `calibration: { correctThresholdDefault, thresholdRange, kneeThreshold, precisionAtDefault, recallAtDefault, precisionFloor, runRevision, stale: Bool }` — the §5.5.1 output, as data.

**`issues()` structural validation (fail-closed, TG-12 D-4 transfers):**

```
unsupportedFormatVersion(Int)
emptyEntries
duplicateEntryID(String)
emptyNoisyOrCorrected(entry: String)
noisyEqualsCorrected(entry: String)
evidenceMissing(entry: String)
evidenceContradictsRun(entry: String)      // occurrences < 1, or a run id that does not resolve
unknownSpanClass(entry: String)
danglingConfusable(entry: String)
unknownErrorClass(String)
safetySetTouched(entry: String)            // §5.8 — refuses the WHOLE file
identityLeak(entry: String)                // id contains `noisy` or `corrected` — §7 C-6
calibrationMissing(run: String)            // manifest carries no calibrated threshold
calibrationStale(run: String, reason: String)  // bound to an older lexicon/noise revision (§5.5.1)
thresholdRangeInvalid(Range<Double>)       // lower ≥ upper, or default outside the range
```

`identityLeak` is new and is this addendum's own contribution to the validator family. The canonicalizer's entry ids are human-readable and encode surfaces (`eastern-perfective-ichha`); that is fine there because a *dialect variant* is public language. A **correction entry's surface is the user's utterance**, so the id must be opaque, and the validator is what makes that structural rather than a convention a future author forgets. `calibrationMissing` / `calibrationStale` are what make A-12 enforceable: a lexicon without a fresh calibration does not load.

### 5.7 Span safety, and composition with TG-12 §4.5's map

Corrected text feeds the canonicalizer; the canonicalizer's map feeds the encoder's spans. The composition is therefore **two maps**, and the design defines it in one direction only:

```
raw ──sanitise──▶ sanitised ──correct──▶ corrected ──canonicalise──▶ canonical
        (identity)             (map C)                (map K, TG-12 §4.5)
```

`map C` and `map K` compose into one map from a canonical span back to the original. **The abstain rule fires if either stage widens a required span** — not only if the composite widens, because a widening at `C` followed by a shrinking at `K` can return an exact-looking range that is not the user's range. The gate (§7 C-4) tests the composite; the conservative rule governs the intermediate.

**The rule for required spans (A-8).** A required span — `contact` for `call`/`send_message`, `time` for `set_reminder`, the set TG-12 §4.5 already names — is corrected **only by a strict prefix completion**: `noisy` must be a strict prefix of `corrected`, so `originalRange ⊆ correctedRange` with an exact anchor at the start and a single insertion at the end. Any other correction shape inside a required span is **refused by the corrector**, the token passes through, and the encoder sees today's input. Consequences:

- **The resolved surface is the CORRECTED one.** This is the one place the corrector knowingly inverts the canonicalizer's orientation, and it is the *point* of the layer: the contact resolver must search for the repaired form, not for the truncated fragment, or the correction has bought nothing. The corrector's provenance retains the original range for the record, the safety sweep, and the "what did the user actually say" question.
- **The wrong-person hazard is contained structurally, not by a score.** A `contact` token is never *substituted* by the corrector. Where the fragment-to-name completion is ambiguous (`सु` → `सुनिता`? `सरस्वती`? `सिमा`), the margin will usually refuse; where it does not, the correction is still a completion of what the user started saying, which is the property that makes it defensible.
- **Only 24 % of corpus rows carry a `contact` span, 18 % a `time` span, and 43 % carry no span at all.** The rule is expensive on a minority of traffic and free on the rest — including on the worked example, whose row has no spans.

### 5.8 Safety vetoes — the frozen set, inherited and extended

The corrector inherits TG-12 §4.7's frozen set in full and adds three rules of its own:

1. **Inherited.** No entry may map a form **onto** or **away from** any member of: the negation/polarity class (`न`, `न-` prefixed forms, `नखाए`, `होइन`, `भएन`, `छैन`, `पर्दैन`), the 17 emergency phrases (`CommandRouter.swift:1468-1473`), the med-ack and denial token lists (`:1519-1534`, guard `:1508-1517`). Enforced by `safetySetTouched` at authoring time, refusing the **whole file**.
2. **New — the completion hazard.** The canonicalizer's hazard is *collapsing* a negated form onto its positive (`नखाए` → `खाए`). The corrector's is the mirror image and it is **not** covered by the inherited rule: a *fragment* completed **into** a marker. `नखा` → `नखाए` looks like a textbook prefix completion and it **manufactures a medication acknowledgement out of a fragment of one**. The same shape reaches `न` → `नखाए`, `मद्द` → `मद्दत गर्नुहोस्`. So the veto is two-sided: entry surfaces may not intersect the frozen set **and** no correction may *create* a token that does. This is the negative arm of §7 C-4, and it is the reason the corrector's gate cannot simply reuse the canonicalizer's fixture.
3. **New — the entity veto.** A token that is, or is directly adjacent to, a lexicon entry carrying a `contact` or `medication` span class is corrected only when (a) the correction is a strict prefix completion, (b) exactly one entity-bank or corpus entity entry has that prefix, and (c) no second entry shares the token's phonetic key. Otherwise pass through. `माइया`/`मैया`, `दिल`/`दिलीप`, and every similarly short name pair are what this rule exists for.

### 5.9 What the corrector is not

- **Not a learned component.** No model, no embedding index, no language-model rescoring. The prior is a count table in a JSON file.
- **Not a transliterator.** Devanagari↔Latin folding of *tokens* is refused, for the reason `NepaliTextNormalizer.swift:18-21` already records. Script drift measured in §4.3 is reported as a class; repairing it is not in this design.
- **Not a grammar or word-order repair.** TG-11's order-invariance work is a different dimension; the corrector is token-local plus a pairwise prior.
- **Not a sentence rewriter.** One token per correction, at most one correction per token, no chaining.
- **Not a safety control and not a safety path.** It reads nothing the net reads and gates nothing the net does.
- **Not a canonicalizer.** Attested dialectal variants are the canonicalizer's business, and after this layer runs, they are still there (the two layers act on disjoint evidence: measured *errors* vs attested *variants*).
- **Not a decision-maker, in Phase 1.** It produces a transcript and a log. Nothing downstream branches on the log (A-14).

---

## 6. Composition and phased delivery

### 6.1 Order, and why it is fixed

`sanitise → correct → canonicalize → tokenize → forward pass`. Correction first, because a truncated token is keyed in no variant table and no canonical rule can fire on it (§5.1). Canonicalization second, per TG-12 §4.2's declared intra-layer order. Tokenization third, unchanged.

The two layers have **independent kill switches** (`STTCorrector.Policy.mode`, `DialectCanonicalizer.Policy.enabled`) and independent A/B arms, so either can be measured with the other off. Four combinations exist and all four are testable; the shipping default is both on.

### 6.2 The escalation path — the correction note, its cost, and its gate

The requirement asks that on cascade escalation **the corrected transcript accompanies the original as context**, and the directive is that this happens **from day one, in Phase 1**. The design honours it. It also states its cost precisely, because this is the one place Phase 1 touches a **fine-tuned artifact's input**, and the repo has already measured how sharp that edge is.

**What the note is.** A delimited, additive context block, rendered through a new `{corrections}` placeholder in the shared template, naming each correction as a pair plus its class and confidence, and rendering as `(none)` when there are none — the shape `{medications}` already uses. It is **not an instruction**: the template gains a field, not a command. Nothing in the code reads the model's output differently because the note was present, and no branch, band or threshold depends on it (A-14). The picker may use it or ignore it; that is the model's call, and the phase-2 gate exists to find out which it does.

**`{transcript}` is unchanged.** The picker's transcript field remains the **original sanitised transcript, byte-identical to today**. TG-12 §4.6's decision (*"the stand-in gets the original sanitised transcript"*) and §14's **E-17 — HOLDS BY DESIGN** are preserved exactly: the value the parser sees, and the transcript of record, are untouched. The note is *additional context*, not a substitution.

#### The cost, measured against the real budget

| Fact | Value | Source |
|---|---|---|
| The on-device brain's context window | **1 024 tokens** | `IntentPrompt.swift:29-31` |
| The template's measured size | **696 qwen3 / 677 gemma** | `IntentPrompt.swift:38-39` |
| Headroom for utterance + JSON | **~300 tokens** | `IntentPrompt.swift:39` |
| A previous revision's size, and its consequence | **2 361 tokens → EMPTY completions, every utterance fell through to a generic re-prompt** | `IntentPrompt.swift:33-36` |
| A previous *trim* of 53 tokens, and its consequence | **emergency recognition collapsed 5/7 → 0/7 draws on the base model** | `IntentPrompt.swift:76-79` |
| The regression guard | `IntentPromptTests` pins a character ceiling calibrated against the real tokenizer | `IntentPrompt.swift:40-42` |
| The template is a **fine-tune artifact** | mirrored byte-for-byte by `seeds/prompt_template.txt`, tokenized raw by `train_qlora.py` and `eval_golden.py`; a missing placeholder raises | `IntentPrompt.swift:44-55`; `intent_prompt.py:1-6`, `:23-38` |

**Three consequences, and they are the reason this is a gate rather than a footnote.**

1. **The note competes with the utterance for ~300 tokens.** Devanagari is token-expensive; a note naming a pair plus a class is not free, and `(none)` on the common path is cheap but not zero. The note must be **bounded by construction** (at most one line, at most K pairs, truncated with an explicit marker) and its size measured on the real tokenizer, not estimated.
2. **It is a four-renderer change.** The template is the source of truth and its seed mirror is tokenized raw by training and eval; adding a placeholder means `IntentPrompt.build`, `seeds/prompt_template.txt`, `intent_prompt.py`'s `PLACEHOLDERS`, and both eval backends move **together**, or the fine-tune is trained and gated on a prompt containing literal placeholder text (`intent_prompt.py:1-6`). This is the real cost of the directive and it is larger than the token count.
3. **Emergency recognition is measurably sensitive to prompt size in this exact template.** The 53-token trim that took emergency recognition to 0/7 is the precedent, and `emergency_recall` is a **1.00 hard gate** (`config.yaml:59`).

**Therefore §7 C-8 gates the note**, and it has four parts: (a) re-measure the prompt on the real qwen3/gemma tokenizers and re-pin `IntentPromptTests`' ceiling; (b) confirm the headroom left for the utterance is still at least the measured worst-case utterance length; (c) re-run the emergency-recognition draw check at the new size, requiring it to hold at its pre-change level; (d) update all four renderers in the same change. **If (a)–(d) cannot all hold, the fallback is specified and costs zero prompt tokens:** the note is carried in the interpreter's context object and rendered **only on the internal card and in the decision log**, and the prompt rendering waits for a template revision that buys back the tokens. On that path the card is the debugger's whole window into the signal — which is exactly the MVP's stated purpose (§6.6).

**And if the note ships enabled, the note-carrying prompt is itself measured.** The A/B (note rendered vs not) is a Phase-1 evidence row (§8 D-20), because "it may ignore it" is a claim about a 4B model that has never been tested, and the 0/7 precedent is the reason not to assume it.

### 6.3 The safety net, the cache, and the transcript of record

- **The net reads the original.** `routeSafetyNet(raw)` at `CommandRouter.swift:716`/`:1494` runs before every interpreter, and the corrector is inside `IntentEncoderInterpreter`. The corrector cannot gate, delay, suppress or rewrite what the net sees. A-7.
- **The cache key is unchanged.** `IntentCommandCache` keeps `NepaliTextNormalizer.normalize`. Re-keying would orphan every recorded entry and silently undo the write-after-confirmation discipline — the thing that makes a cache hit safe without `bandChecked`. The corrector changes a *model input* and nothing else.
- **The transcript of record is the original.** `IntentLogStore`, transcripts, and any user-facing replay keep the original. The corrected string exists for the duration of one interpreter call. A-6.
- **The confirmation flow is untouched.** It reads the interpreter's output, not the transcript, and the corrector changes neither.

### 6.4 Kill switches and the A/B arms

```swift
/// Mirrors `DialectBiasSettings` (DialectBiasComposer.swift:79-97): absent
/// key reads the CALIBRATED DEFAULT, and the toggle is an inspection/escape
/// hatch rather than an opt-in gate — because the threshold, not the switch,
/// is what prevents a bad correction (A-4).
enum STTCorrectionSettings {
    static let modeKey = "sttCorrectionMode"
    static let thresholdKey = "sttCorrectionThreshold"
    static func mode(defaults: UserDefaults = .standard) -> STTCorrectionMode
    static func setMode(_ mode: STTCorrectionMode, defaults: UserDefaults = .standard)
    static func threshold(defaults: UserDefaults = .standard) -> Double
    static func setThreshold(_ value: Double, defaults: UserDefaults = .standard)
    static func reset(defaults: UserDefaults = .standard)   // restores the calibrated defaults
}
```

| Arm | Meaning | What it measures |
|---|---|---|
| `.off` | byte-identical passthrough, `decisions` recorded as `.disabled` | **the control arm** — today's behaviour exactly |
| `.shadow` | candidates generated, decisions and confidences logged, **nothing applied** | the **counterfactual**: what *would* have been corrected on turns where the transcript was left alone. This is the arm Phase 2(a)'s activation statistics are cleanest from, because it changes no behaviour while it measures |
| `.apply` | the MVP default: corrections apply above threshold | the layer's actual effect, measured against `.off` |

`.shadow` is a design contribution rather than a directive item: Phase 2(a) needs `P(escalation-worthy | would-have-been-corrected)`, and only `.shadow` produces that without simultaneously changing the thing being measured. The sequencing question — whether the shipped default is `.apply` from day one (the directive's MVP) or `.shadow` for an evidence window first — is open question 6, and it is a design decision to take before T-076 wires the default.

### 6.5 Phase boundaries

| | **Phase 1 — MVP** | **Phase 2 — gated** |
|---|---|---|
| **Ships** | correction applied to the encoder's input; decision log; "Last correction" card line; observability events; non-compelling note in the escalation context (subject to §7 C-8) | exactly two optional consumers, each behind its own flag |
| **Brain behaviour that depends on the signal** | **none** (A-14) | the consumer's own flag, and only after its numeric activation condition is met |
| **Encoder input** | the corrected transcript (the layer's function); no correction *metadata* ever | unchanged |
| **Encoder routing** | **untouched** | consumer (a) only: a confidence **discount** at the routing layer |
| **Picker prompt** | the note added, bounded, non-instructional, gated by C-8 | consumer (b): the note becomes a structured reasoning block |
| **Evidence basis** | §7 C-1…C-3, C-6…C-10 | §7 C-11, computed **from Phase-1 logs** |
| **Ships alone?** | **yes** — this is the MVP | no: additive, flag-defaulted-off, deletable |

### 6.6 Phase 1 — the MVP, in full

**The primary consumer is the human debugger.** Everything else in Phase 1 exists to serve that, and to make Phase 2 measurable if it is ever attempted.

**6.6.1 — Corrections apply.** Above the calibrated threshold, in a bounded candidate space, with the §5.8 vetoes and the §5.7 span rule. Below it: pass-through, byte-identical.

**6.6.2 — Every decision is logged, with its reason.** The reason vocabulary is the closed `CorrectionDecision` enum (§5.2), and every considered token produces exactly one entry. On-device debug output, one line per token:

```
[STT-CORRECT] corrected मौस→मौसम (conf 0.93, margin 0.41, class truncation, entry trunc-0042, lex r7)
[STT-CORRECT] no correction (no candidate) — ट्रेन
[STT-CORRECT] no correction (below threshold, best मौस→मौसमको conf 0.61 < 0.80, lex r7)
[STT-CORRECT] no correction (ambiguous, margin 0.04 < 0.15) — मौस
[STT-CORRECT] no correction (required span time, not a prefix completion) — बिहा
[STT-CORRECT] no correction (safety veto: completion into negation marker)
[STT-CORRECT] no correction (degraded lexicon r7 — calibration stale)
```

The line carries the **threshold in force**, because a debugger reading "below threshold" needs to know *which* threshold, and because it makes A-12's calibrated value visible in the field rather than only in the manifest.

**6.6.3 — A "Last correction" line on the internal testing card.** The exact shape of the `Last turn` readout (`SettingsView.swift:3461-3494`), in the same encoder card, immediately below it:

```swift
// [STT-CORRECTION-READOUT] Mirrors the Last turn block above: in-memory on
// the coordinator, last turn only, never persisted, never logged. The
// labels are DIAGNOSTIC TOKENS like the timing rows and stay unlocalized,
// for the same reason — this is an internal-testing surface whose
// vocabulary must match the device logs it is read against.
Divider()
VStack(alignment: .leading, spacing: 6) {
    Text("settings.encoder.lastCorrection")
    if let correction = coordinator.lastCorrectionReadout, !correction.isEmpty {
        ForEach(correction.readout) { row in
            HStack(spacing: 8) { Text(row.label); Spacer(minLength: 8); Text(row.value) }
                .font(.system(size: DesignTokens.minCaptionPointSize, design: .monospaced))
                .foregroundStyle(DesignTokens.textSecondary)
        }
    } else {
        Text("settings.encoder.lastCorrection.empty")
    }
}
```

Rendering, by case:

| Case | Card reads |
|---|---|
| corrected | `corrected  मौस→मौसम` / `conf  0.93 (τ 0.80)` / `class  truncation  entry trunc-0042` |
| no candidate | `no correction  (no candidate)` / `tokens  4 considered` |
| below threshold | `no correction  (below threshold)` / `best  मौस→मौसमको  0.61 < 0.80` |
| ambiguous | `no correction  (ambiguous)` / `margin  0.04 < 0.15` |
| veto / required span | `no correction  (safety veto)` / `no correction  (required span: time)` |

The same block also carries the **threshold control** (§5.5.1, A-12): a stepper over `thresholdRange`, with the calibrated default shown beside the current value and a `reset` that restores it. The control is clamped; the clamp is the C-2-derived bound and a test asserts it (§7 C-9d).

**This surface shows the user's own words, and that is correct.** It is the user's device, the debugger is looking at their own turn, and the pair is the entire diagnostic value. What it must never do is **persist or egress**: the block is in-memory, last-turn, released like the timing breakdown, never written to `IntentLogStore`, never printed to a persisted log, never in an event. That is the `Last turn` precedent verbatim, and §7 C-6 enforces it.

**6.6.4 — Structured observability events.** The egressing counterpart, count-only (A-16): `{ applied: Bool, reason: CorrectionDecision, errorClass?, entryID?, lexiconRevision, confidenceBucket?, marginBucket?, tokensConsidered, correctionsApplied }`. **Binned, not raw** — a raw score in telemetry is a fingerprint of an utterance shape, and the buckets are what the Phase-2 statistics actually need.

**6.6.5 — The non-compelling escalation note.** §6.2. Bounded, delimited, `(none)` when empty, gated by C-8, never read by any branch.

**6.6.6 — What Phase 1 explicitly does not do.** No routing change. No confidence discount. No band or `acceptThreshold` change. No cache-key change. No change to `LlamaCommandInterpreter.parse`, `InterpretedCommand`, or any decode path. No change to the picker's `{transcript}`. No use of the signal anywhere in a decision.

**6.6.7 — Phase 1 is independently shippable.** Nothing in Phase 1 references a Phase-2 flag, type or artifact. Deleting every Phase-2 code path leaves Phase 1 compiling, running and gated. This is a structural requirement (A-13), checked by §7 C-11c.

### 6.7 Phase 2 — the two gated consumers

Phase 2 is entered only by measurement. Each consumer has its own flag, its own gate and its own numeric activation record, and **either can be activated, deferred or abandoned independently of the other.**

#### (a) Encoder-side — a confidence discount at the routing layer

**What it is.** When a correction was applied on this turn, the encoder's reported confidence is discounted by a factor before the band comparison, so the turn leans toward escalation. The rationale, preserved from the directive: a transcript the corrector had to repair is **more likely to be wrong somewhere the corrector did not repair**, so a confidence the encoder reports on a repaired transcript deserves less trust. The action is conservative by construction — escalation, not suppression.

**What it is not.** **Never an input change.** The encoder's input, tokenizer contract, span semantics and training identity are untouched. The discount is a routing-layer scalar applied after the forward pass and before band comparison. It cannot change an intent, a slot or a resolved entity; it can only move a turn across a band boundary toward the more careful path.

**Numeric activation conditions** (all four, all computed from Phase-1 logs, none negotiable):

| # | Condition | Threshold |
|---|---|---|
| a1 | `Δ_esc = P(escalation-worthy \| ≥1 correction applied) − P(escalation-worthy \| 0 applied)` | **≥ 5 pp**, with **N ≥ 2 000** corrected turns and the 95 % CI excluding zero |
| a2 | Encoder **over-confidence** on corrected turns: `mean(reported confidence) − observed accuracy` | **≥ 0.05** — i.e. the discount must be aimed at a *measured* miscalibration, not a hypothesis about one |
| a3 | The discount's own A/B on the corrected slice | **≥ +1 pp** task success |
| a4 | No-regression arms: uncorrected slice **≥ −0.5 pp**; **emergency recall unchanged at 1.00** | as stated |

`Δ_esc` is measured with the `.shadow` arm (§6.4) so the statistic exists on turns the layer did not change. **The 5 pp / 2 000 / 0.05 / +1 pp numbers are chosen and are labelled chosen (A-9)**; what matters structurally is that a1 and a2 must be **measured** before a3 can even be run, because a3 without a1/a2 would be tuning a discount until it helps.

#### (b) 4B-side — the correction trail as structured reasoning context

**What it is.** The §6.2 note graduates from a passive field to a **structured block** — the corrected span(s), the error class, the confidence — that the prompt asks the model to weigh when the transcript looks repaired. Still not an instruction, and still never a transcript substitution.

**Numeric activation conditions:**

| # | Condition | Threshold |
|---|---|---|
| b1 | Phase-1 A/B (note rendered vs not) task success on the **escalated slice** | **≥ +2 pp**, with **N ≥ 500** escalated turns |
| b2 | p95 latency regression | **≤ +20 ms** on the escalated leg |
| b3 | Prompt-budget re-check at the new note size | C-8 (a)–(c) must still hold |
| b4 | Safety sweep on the A/B: **emergency recall identical** with and without the note | exact equality |

The honest expectation, stated because it is a real possibility: **b1 may measure +0**, in which case the recorded outcome is *"the picker rung is unchanged and E-17 stands; the note graduates to a debugger surface only"* — a legitimate, printable result (TG-12 D-8), and the same reasoning TG-12 OQ-5 applies to the canonicalizer.

#### The Phase-2 activation record

One document per consumer, produced **from Phase-1 logs, before the consumer is enabled**, carrying: the log window and the row counts, a1–a4 or b1–b4 with their measured values, the threshold in force, the lexicon revision, and an explicit `ACTIVATE` / `DEFER` / `ABANDON` decision. A Phase-2 flag flipped without such a record is a defect, and §7 C-11a refuses it.

### 6.8 What neither phase does

- No model is trained, fine-tuned, distilled or exported.
- No new intent, slot, BIO tag, head or gate constant.
- No change to the safety net, the emergency path, the med-ack path, the cache key, the confirmation flow, the band policy or the corpus.
- No surface form leaves the device through an event, a log or a manifest (A-11, A-16, §7 C-6).
- No behaviour in either phase depends on the model *choosing* to use the note.

---

## 7. Gates

House discipline throughout: **each gate has a named fixture, is bound to a revision, has an exit code, and has a negative arm proving it can fail.** A gate never observed failing is not known to be a gate (TG-12 §4.7, T-038 notes `:64-65`). Exit codes use the pipeline vocabulary (`pipeline_guards.py:33-38`): **0** pass, **1** gate failed, **2** usage/malformed fixture, **3** guard refusal, **4** floor unmet. The fixture sweep mirrors `eval/fixtures/run_fixture_sweep.sh`: each failing fixture must exit with **exactly the one gate it targets**.

### C-0 — the measurement is real (precondition for every other gate)

| | |
|---|---|
| **What** | The extraction run's floors, refusing a report the lexicon could be mis-authored from. |
| **Fixture** | `tools/train-intent/eval/fixtures/correction_pairs_min.jsonl` — a small committed pair file exercising every class, so the extractor is testable without the multi-GB real pair corpus. |
| **Threshold** | ≥ 500 aligned error events **and** ≥ 25 `truncation` events over the real population, else `EXIT_FLOOR` (4). The committed min fixture runs at a scaled floor (`--min-events 20`) so CI can run it. |
| **Revision** | input digest + `sha256(golden_corpus.jsonl)[:8]` recorded in the manifest; the corpus revision must read `7f71b8ae`. |
| **Negative arm** | `correction_pairs_floorfail.jsonl` — 19 events — must exit **4**, not 0. |

### C-1 — correction accuracy

| | |
|---|---|
| **Fixture** | `tools/train-intent/eval/fixtures/correction_min.jsonl` (~120 rows: every error class × every span context: no-span / `topic` / `contact` / `time` / `medication`), plus `correction_precision_fail.jsonl` and `correction_recall_fail.jsonl` as negative arms. |
| **C-1a (hard)** | **applied-correction precision ≥ 0.95** — every correction the corrector applies must equal the fixture's expected correction. |
| **C-1b (hard, per class, reported)** | **repair recall ≥ 0.80** on the correctable subset — rows whose class is measured, whose target is in the lexicon, and whose span context permits the repair. Classes are scored **individually**; a class at 0 is a coverage gap and is printed as one, never averaged away. |
| **Justification** | Precision is the tight number and recall is the loose one, because **a wrong correction is worse than none** (A-4). 0.95 matches the strictest existing non-safety gate (`closed_intent_accuracy 0.95`, `config.yaml:58`) — the corrector is upstream of that number, so it may not be sloppier than it. 0.80 is **chosen** and is deliberately loose; it exists so an unhandled class fails loudly rather than hiding in an aggregate. **C-1a is also §5.5.1's calibration floor**: it is the constraint that bounds the shipped threshold, so the gate and the default are the same number by construction. |
| **Exit** | 1 on either gate; each fixture exits with exactly its own gate. |
| **Revision** | `correction_min.jsonl` is bound to a lexicon revision and a corpus revision; a result without both is `UNEVALUATED` and fails closed, following `eval_golden.py`'s baseline-binding rule (`specs/T-038-notes.md:113`). |

### C-2 — never flips intent

| | |
|---|---|
| **Fixture** | `tools/train-intent/eval/fixtures/correction_intent_stability.jsonl` — a frozen slice of the golden corpus, each row corrupted by the **measured** classes applied only to tokens that are not in the frozen safety set, in three arms: (1) no-span content words (the worked example's arm), (2) `topic`/`medication` tokens, (3) `contact`/`time` tokens (required spans). |
| **C-2a (runs today, no artifact)** | **For 100 % of rows: `correct(corrupted)` is either byte-identical to the gold utterance, or leaves the corrupted token byte-identical.** No third form. This is the text-level statement of "never flips intent": the only way a corrector can change a label the corruption did not change is by producing a *different word from the gold one* — and this asserts it produced no such word. |
| **C-2b (needs the encoder artifact — GAP)** | `A_corrected == A_gold` on the same slice through the T-038 harness; **100 % agreement, zero flips**. **Cannot run today**: the encoder path is behind `#if INTENT_ENCODER` and the shipped artifact fails Stage 0 (`emergency_recall` ≈ 0.9375 against a 1.00 hard gate). Recorded as **gap G-A2**, owned by T-078 once Stage 0 is green. |
| **The absolute floor (A-12)** | **C-2a is evaluated at the shipping threshold AND at `thresholdRange.upperBound`** — the loosest value the internal card can select. The calibration run **derives that bound from this gate** (§5.5.1 step 5), so the gate is not merely checked at one operating point: it *defines* the range the corrector is permitted to operate in. A threshold is an operating point; the invariant bounds it. |
| **Negative arm** | `correction_intent_flip.jsonl` — a lexicon whose `मौस` entry maps to `मौसमको` (a real corpus word, the wrong one). Must trip C-2a and exit **1**. This is the arm that proves the gate bites, and the specific wrong answer it encodes is the plausible one. |
| **Exit** | 1 on C-2a failure; 3 (`EXIT_GUARD`) if the slice's corruption plan intersects the frozen safety set (a fixture-authoring refusal, checked by construction). |

### C-3 — pass-through is honest

| | |
|---|---|
| **Fixtures** | `correction_lowconf.jsonl` (rows where the candidate set is a near-tie or the evidence is absent: bare `मौस` with no frame, hapax targets, entity tokens with ≥ 2 phonetic-key collisions, unattested tokens) + the **full clean corpus** `eval/golden_corpus.jsonl`. |
| **C-3a (hard)** | **Pass-through rate == 1.00 on `correction_lowconf.jsonl`.** Zero forced corrections. |
| **C-3b (hard, and the cheapest strong check in the set)** | **No-op rate == 1.00 over all 8 000 clean rows.** Any correction applied to clean text is by definition a false positive, and the golden corpus is the largest clean sample the project has, already pinned at `7f71b8ae`. |
| **C-3c (reporting, enforced)** | The pass-through share on the corrupted fixture is **printed, per decision reason, with counts**. A run that reports an accuracy figure without its pass-through denominator is refused with **3** (`EXIT_GUARD`) — the same discipline as T-038's refusal to let a one-row file pass vacuously (`specs/T-038-notes.md:76`). |
| **Exit** | 1 on any forced correction; 3 on a denominator-free report. |
| **Negative arm** | `correction_lowconf_force.jsonl` + a policy with `marginThreshold: 0.0` — the over-eager arm — must apply a correction to a low-confidence row and exit **1**. |

### C-4 — the composed transform is lossless for safety (SAFETY)

| | |
|---|---|
| **What** | TG-12 §4.7's two-clause equality — `matches(canonical) ⊇ matches(original)` and `matches(canonical) ⊆ matches(original)`, computed with the **shipped matchers** — re-scoped to the **composed** transform `correct ∘ canonicalize`, over the net's own matcher set. |
| **Fixture** | TG-12's `losslessness_fixture.jsonl` (T-077), **extended** with the corrector's own frozen material: rows containing each negation marker, each emergency phrase, each med-ack/denial token, and — new — the **fragments** of each (`नखा`, `मद्द`, `न`). |
| **Threshold** | **100 % of rows, both clauses.** |
| **Negative arms (two, and the second one is new)** | (a) TG-12's `नखाए` → `खाए` canonical rule. (b) **A corrector entry `नखा` → `नखाए`** — a plausible prefix completion that *manufactures* a medication acknowledgement. (b) is the arm that proves the corrector is inside the gate; without it, the gate would keep passing while the new layer sits upstream of it. |
| **Exit** | 1, naming the offending row; 3 if the matcher list could not be loaded from the shipped source (a gate that cannot call the real matcher is not the gate). |
| **Why this gate exists at all, given the net reads the original** | Three reasons: it pins the property that makes A-7 refactor-safe; it catches the **model-level** error (an encoder reading a fragment-completed `नखाए` classifies `ack_med` for a refusal); and it is the only place the two layers' safety properties are checked *together*, which is the property that changed. |
| **Owner** | T-077, whose scope this extends. **Gate-coverage note: until this lands, T-077's PASS is a statement about a transform that is no longer the whole transform.** |

### C-5 — latency

| | |
|---|---|
| **Threshold** | **≤ 5 ms p95 incremental** on the local leg, and **≤ 1 %** of the 2.0 s local budget (`IntentEncoderInterpreter.Config.timeoutSeconds`). |
| **Justification** | **Chosen.** Structural rather than empirical: a pre-model transform that costs more than 0.25 % of the budget it precedes is a design error, not a tuning problem. The corpus's arithmetic (§3) says the work is tiny — 1 050 lexicon entries, ~5 tokens per row, a bounded candidate set — so the threshold guards against a pathological implementation, not a performance target. |
| **Instrument** | Off-device: a CPU text harness (the corrector has **no device dependency** — no model, no CoreML, no audio), run over the golden corpus with wall-clock percentiles using `measure_device.py`'s nearest-rank `percentile()` (`:66-72`) so the two harnesses share percentile semantics. On-device: a new **`stt_correction`** stage in `TurnTimingStage`. |
| **The schema cost, stated** | `TurnTimingStage` is `CaseIterable` and documented as *"a schema change, so the set is deliberately small and closed"* (`TurnTimingBreakdown.swift:45-47`). Adding a stage opens that closed set, and everything that enumerates it — the Settings readout, any test asserting the stage set, the event schema — must move with it. The precedent that justifies it is `cascade_decision` itself, added *"so the breakdown shows the decision was taken"* (`:61-67`). The alternative — folding the corrector's time into `encoder_tokenizer` — is rejected because it would make one number mean two things, which is the failure mode the closed set exists to prevent. |
| **Structural bound, asserted** | `maxCandidates` is enforced at generation and a unit test asserts the bound on an adversarial input (a 200-scalar utterance of maximally ambiguous prefixes against the full lexicon). A corrector that is fast on the fixture and unbounded in the worst case is a hang on the oldest device. |
| **Negative arm** | A deliberately unbounded generator (`maxCandidates: 100_000`) must exceed the threshold in the CPU harness, proving the harness measures the right thing. |

### C-6 — no surface form leaves the layer (privacy)

| | |
|---|---|
| **Rule** | The egressing artifact — the observability event, any persisted log, any manifest — carries **entry ids, lexicon id, error class, reason, binned scores and counts — never a surface form** (A-16). The **internal card is not an egressing artifact**: it is in-memory, last-turn, on the user's own device, and it shows the pair because that is its entire diagnostic value. The rule the card must satisfy is the `Last turn` block's: never persisted, never logged. |
| **Fixture / check** | An event sweep over a corrector run asserting zero content-bearing fields, following T-078's observability sweep (E-15) — **extended to the lexicon file** (`identityLeak`, §5.6) and to the card's lifecycle (a test asserting the readout is released with the turn and never reaches `IntentLogStore`). |
| **Precedent** | NFR-016; T-049/T-050 (`constitution.md:126`). |
| **Exit** | 1 on any leak found by the sweep or the lifecycle test. |

### C-7 — Phase 1 is complete and inert (the MVP gate)

| | |
|---|---|
| **What** | Phase 1's deliverables exist and nothing depends on them. Three assertions. |
| **C-7a (logging)** | Every considered token produces exactly one `CorrectionDecision`, the vocabulary is the closed enum, and the log line names the **threshold in force**. Fixture: `correction_min.jsonl`; asserted by a decision-table test over the fixture. |
| **C-7b (the card)** | The "Last correction" readout renders for every decision case, matches the decision log's vocabulary, is released at the start of the next turn, and **never reaches `IntentLogStore` or the event channel**. Fixture: a view-model test + a lifecycle test. |
| **C-7c (non-compulsion)** | **No branch, band, threshold, escalation or reply depends on the correction signal.** Asserted structurally: the Phase-1 diff introduces no read of `CorrectionResult` outside `IntentEncoderInterpreter`'s input path and the two observability surfaces, enforced by a build-level check plus a review item. |
| **Exit** | 1 on any of the three; the check names which. |
| **Negative arm** | A deliberately planted `if result.applications.isEmpty { lowerConfidenceBy(0.1) }` in the interpreter must trip C-7c. Phase 2(a) is exactly that line — which is why C-7c must be able to see it. |

### C-8 — the escalation note is affordable (PHASE 1 BLOCKER)

| | |
|---|---|
| **What** | The §6.2 note's cost, measured against the real budget rather than estimated. |
| **C-8a (size)** | Re-measure the template against the **real qwen3 and gemma tokenizers** at the new size and re-pin `IntentPromptTests`' character ceiling. |
| **C-8b (headroom)** | The tokens remaining for the utterance + JSON after the note must still be **≥ the measured worst-case utterance length** (measured, not assumed — the `2 361-token → EMPTY completion` precedent is what a headroom failure looks like). |
| **C-8c (emergency recognition)** | Re-run the draw check at the new size. **Emergency recognition must hold at its pre-change level.** `emergency_recall` is a 1.00 hard gate (`config.yaml:59`) and the template's own history records a **53-token** change taking it 5/7 → 0/7 — this is the one part of the change that can move a safety number. |
| **C-8d (identity)** | The template, `seeds/prompt_template.txt`, `intent_prompt.py`'s `PLACEHOLDERS` and both eval backends are updated in the **same** change; a renderer that fills only some placeholders must fail loudly (`intent_prompt.py:23-38`). |
| **Threshold** | C-8a–d must all hold. Any failure → the documented fallback: the note goes on the card and in the decision log only, and the prompt rendering waits. **The note is not shipped at the cost of a safety number.** |
| **Negative arm** | A synthetic template revision inflated by 120 tokens must trip C-8b, and the emergency draw check must detect a deliberate trim past the measured cliff. |
| **Exit** | 1 on a sizing failure; 3 if the tokenizers could not be loaded (an unmeasured size claim is not evidence). |

### C-9 — the threshold is calibrated, fresh, and bounded (A-12)

| | |
|---|---|
| **What** | The shipped default is data-derived, its provenance is intact, and the range the card offers cannot break C-2. |
| **C-9a (provenance)** | `correction-manifest.json` carries `calibration.runRevision`, a non-null `correctThresholdDefault`, the knee, and the precision/recall at the default. A manifest without them fails closed at load (`calibrationMissing`). |
| **C-9b (the floor binds)** | The shipped default satisfies `precision ≥ 0.95` on the calibration set, **and the run reports the knee beside it**, so the binding constraint is visible. A default that is looser than the knee without reporting why is a defect. |
| **C-9c (freshness)** | The calibration is bound to the lexicon revision **and** the noise source revision. A lexicon loaded against a stale calibration is refused (`calibrationStale`) — the T-066 re-run (§9) is what makes it fresh again. |
| **C-9d (the range is enforced)** | `thresholdRange.upperBound` is derived as the loosest threshold at which **C-2a** holds; a card selection outside the range is clamped, and a unit test asserts the clamp. **The never-flips-intent gate is the absolute floor regardless of threshold.** |
| **Exit** | 1 on any failure; 3 if the range could not be derived (a range without its C-2 derivation is not the range). |
| **Negative arm** | A manifest carrying a threshold **above** the C-2-derived bound must be refused at load, not merely warned about. |

### C-10 — the corrected training bucket keeps its corruption (A-15)

| | |
|---|---|
| **What** | The encoder's train/inference identity and the training bucket's purpose. |
| **Fixture / mechanism** | Run the shipped corrector over the `utterance` side of the round-trip pair corpus; compare the corrected bucket against the clean parents. |
| **C-10a (identity)** | The corpus build records the **lexicon revision and threshold** it used, and the promotion gate refuses a corpus whose corrector revision does not match the shipped one. |
| **C-10b (residual corruption floor)** | The corrected-noisy bucket must retain a measured share of corrupted rows — **≥ 55 %**, the existing `hard_floor_stt_noised` (`annotation_rules.yaml:229-230`), because that floor already encodes the trainer's requirement. A corrector strong enough to collapse the bucket below it is a signal to **widen the round trip**, not to lower the floor, and the design says so explicitly. |
| **Exit** | 1 on C-10a; 4 (`EXIT_FLOOR`) on C-10b — a floor, by the existing vocabulary. |
| **Negative arm** | A corrector configured to repair every round-trip pair must trip C-10b, proving the floor is measured and not assumed. |

### C-11 — Phase 2 cannot start without its numbers (A-13)

| | |
|---|---|
| **What** | Each Phase-2 consumer's activation is a **measurement**, not a decision. |
| **C-11a (activation record)** | Enabling either Phase-2 flag requires a record (§6.7) carrying the log window, the row counts, and **a1–a4** or **b1–b4** with measured values. A flag flipped without one is a defect; the check is a review item plus a test that the flag cannot be set in the debug build without a recorded decision. |
| **C-11b (the threshold is met)** | Every numeric condition in the consumer's table must be met **at the stated N**, computed from Phase-1 logs, with the 95 % CI excluding zero where stated. |
| **C-11c (independence)** | With both Phase-2 flags off, the Phase-1 test suite passes unchanged. **This is the structural assertion that Phase 1 ships alone** (A-13). |
| **Exit** | 1 on C-11b; 3 on C-11a (a guard refusal, because enabling without a record is the thing being refused); 1 on C-11c. |
| **Negative arm** | Enabling the routing discount **without** a record must be refused (3); enabling it with a fabricated a1 below the 5 pp threshold must fail (1). |

---

## 8. Evidence pack

Dimension → mechanism → gate → threshold → fixture → rows → revision. Every row is measured, or `UNMEASURED — gap` with a named owner. Shipped machine-readable under `tools/train-intent/docs/tg12-evidence/stt-error-correction/`, following the T-033 precedent.

| # | Dimension | Mechanism | Gate | Threshold | Fixture / path | Rows | Revision |
|---|---|---|---|---|---|---|---|
| D-1 | Error classes are measured, not assumed | word alignment over the round-trip pairs | C-0 | ≥ 500 events, ≥ 25 truncations | `tg12-evidence/stt-error-distribution/` | full pair population | input digest + `7f71b8ae` |
| D-2 | The lexicon is sourced from the measurement | per-entry `evidence` block | validator (`issues()`) | every entry cites a run id and `occurrences ≥ 1` | `CorrectionLexicon/*.json` | ~1 050 candidate types | lexicon revision + run id |
| D-3 | Corrections are precise | scored, margin-gated application | C-1a | **≥ 0.95** | `correction_min.jsonl` | ~120 | lexicon + corpus revision |
| D-4 | Corrections are complete enough to matter | per-class recall | C-1b | **≥ 0.80 per class** | `correction_min.jsonl` | ~120 | as D-3 |
| D-5 | Intent is never flipped — text level | third-form prohibition, at the default **and** at the range bound | C-2a | **100 %** | `correction_intent_stability.jsonl` | frozen slice | corpus revision |
| D-6 | Intent is never flipped — model level | encoder agreement | C-2b | 100 %, zero flips | same, via T-038 harness | frozen slice | **UNMEASURED — gap G-A2** (Stage 0 RED) |
| D-7 | Low-confidence inputs pass through | forced-correction count | C-3a | **1.00 pass-through** | `correction_lowconf.jsonl` | ~40 | lexicon revision |
| D-8 | Clean text is not touched | no-op over the pinned corpus | C-3b | **1.00 no-op** | `eval/golden_corpus.jsonl` | **8 000** | `7f71b8ae` |
| D-9 | Pass-through is reported, not hidden | denominator + reason counts printed | C-3c | present, else `EXIT_GUARD` | the run's report | — | run manifest |
| D-10 | The **composed** transform is safety-lossless | shipped matchers, both clauses | C-4 | **100 %** | `losslessness_fixture.jsonl` (extended) | T-077's set + fragments | matcher list revision |
| D-11 | C-4 can fail | two negative arms, one corrector-specific | C-4 negative | exit 1, row named | same fixture, negative arm | 2 | — |
| D-12 | The layer is cheap | stage timer + CPU harness | C-5 | **≤ 5 ms p95, ≤ 1 %** | `TurnTimingStage.stt_correction` | corpus replay | device/build id |
| D-13 | No surface form egresses | event sweep + `identityLeak` + card lifecycle | C-6 | zero content-bearing fields outside the in-memory card | sweep over a corrector run | — | NFR-016 |
| D-14 | The picker's `{transcript}` is unchanged | render diff | T-075 test | byte-identity | `IntentPrompt` render catch | — | **HOLDS BY DESIGN** (E-17) |
| D-15 | **Every decision is logged with its reason** | decision-table over the fixture | C-7a | one decision per token, closed vocabulary, threshold named | `correction_min.jsonl` | ~120 | lexicon revision |
| D-16 | **The internal card renders every case and never persists** | view-model + lifecycle test | C-7b | all cases render; released with the turn; absent from `IntentLogStore` and the event channel | `SettingsView` encoder card | — | build id |
| D-17 | **No brain behaviour depends on the signal (Phase 1)** | structural assertion | C-7c | no read of `CorrectionResult` outside the input path and the two observability surfaces | planted-violation arm | — | Phase-1 diff |
| D-18 | **The escalation note is affordable** | tokenizer re-measure + headroom + emergency draw check | C-8a/b/c | headroom ≥ worst-case utterance; emergency recognition holds | template revision + draw check | — | tokenizer + model ids |
| D-19 | **Prompt identity survives the note** | four-renderer same-change assertion | C-8d | seed and Swift render identical; a missing placeholder raises | `intent_prompt.py`, seed, both backends | — | template revision |
| D-20 | The note's effect is measured, not assumed | A/B: note rendered vs not | Phase-1 evidence row | reported; **no activation** (that is b1) | escalated-turn replay | — | run manifest |
| D-21 | **The threshold is calibrated and fresh** | manifest provenance + floor + staleness | C-9a/b/c | default satisfies precision ≥ 0.95; knee reported; stale refused | `correction-manifest.json` | calibration set | calibration run id |
| D-22 | **The threshold range cannot break C-2** | clamp assertion | C-9d | upper bound = C-2-derived; out-of-range refused at load | same | — | calibration run id |
| D-23 | **The corrected training bucket keeps its corruption** | corrector over the pair corpus | C-10a/b | ≥ 55 % residual, lexicon revision recorded | `data/noised.jsonl` corrected | pair population | **UNMEASURED — gap G-A10** |
| D-24 | **Phase 2 cannot start without its numbers** | activation record + independence | C-11a/b/c | a1–a4 / b1–b4 met at stated N; Phase-1 suite passes with both flags off | activation record | — | **UNMEASURED — gap G-A7** |
| D-25 | Phase 2(a) routing discount | A/B, discount on vs off | a3/a4 | ≥ +1 pp corrected; ≥ −0.5 pp uncorrected; emergency recall 1.00 | escalated replay | — | **UNMEASURED — gap G-A12** |
| D-26 | Phase 2(b) structured context | A/B on the note | b1/b2/b4 | ≥ +2 pp at N ≥ 500; ≤ +20 ms; emergency recall identical | escalated replay | — | **UNMEASURED — gap G-A7** |
| D-27 | The corrector's effect is attributed | count per class + pass-through share | report | present | run report | — | run manifest |
| D-28 | The lexicon rides the loop's gate | lexicon + calibration revision in the run manifest | T-079 binding | promotion refuses on any gate | `run_encoder_pipeline.py` | — | **UNMEASURED — gap G-A8** |
| D-29 | The extraction survives T-066 | re-run sliced by variant index and cell | C-0 re-run | report present per variant/cell | `tg12-evidence/stt-error-distribution/` | — | **UNMEASURED — gap G-A3** (T-066 unmerged) |

| Gap | What is needed to close it | Owner |
|---|---|---|
| **G-A1** | **The pairs are a proxy.** One Hindi piper voice through one Whisper fine-tune is the *pipeline's* error profile, not elder Nepali speech. Inherits TG-11 GAP-1/GAP-2/GAP-3. | TG-11 `T-062`/`T-066`; TG-13 for the noise dimension |
| **G-A2** | **C-2b cannot run.** The encoder artifact fails Stage 0 (`emergency_recall` ≈ 0.9375 vs a 1.00 hard gate) and the path is behind `#if INTENT_ENCODER`. The model-level intent-stability gate is designed and unreachable. | T-078, after Stage 0 |
| **G-A3** | **The source will widen.** `variants_per_utterance` is 2 today (`config.yaml:28`); T-066 raises it and adds the noise/articulation cells. The extraction and the **threshold calibration** must re-run per variant index and per cell. | T-070 re-run; T-066 upstream |
| **G-A4** | **No real noise, no real speech.** TG-11's GAP-1 and GAP-2 transfer unchanged: real-room noise and dysarthric/elder speech are not in the pipeline's reach. | TG-13; TG-11 GAP-2 |
| **G-A5** | **Circularity.** The corrector is calibrated on synthetic round-trip noise and gated on synthetic round-trip noise — and A-12 makes the calibrated default a *fixture-derived* number. This is the largest threat to the design's value and it cannot be closed today. | Recorded; T-079 must carry it into any promoted artifact's notes |
| **G-A6** | **The prior is fitted to synthetic text.** L1/L2 co-occurrence partly encodes template design. The prior's per-level coverage is reported so the dependence is visible. | T-070's extraction reports the frames' generator provenance |
| **G-A7** | **Phase 2 is unmeasured.** Both consumers' activation conditions depend on a Phase-1 log window that does not exist yet; b1's honest expectation is +0. | T-078, after the Phase-1 evidence window |
| **G-A8** | **The lexicon is not yet a promotion-gated artifact.** T-079 registers the variant tables and `calibration_temperature`; the correction lexicon, the calibrated threshold, the range and the weight/prior tables must join that list, and their revisions must appear in the run and corpus manifests. | T-079 |
| **G-A9** | **G-3 is untouched.** Whether a correction pair derived on-device is content under TG-10's hashed-egress contract remains referred to TG-10's `T-053`/`T-059`. A-11 and A-16 do not answer it and T-079 may not settle it by implementing an egress path. | TG-10 `T-053`/`T-059` |
| **G-A10** | **The corrected bucket is not built.** C-10's residual-corruption floor is designed and unmeasured until the corpus build runs the corrector over the pair corpus. | T-079 |
| **G-A11** | **The card's L10n keys do not exist.** `settings.encoder.lastCorrection` and its `.empty` counterpart need adding in every locale; the diagnostic *values* stay unlocalized, per the `Last turn` precedent. | T-076 |
| **G-A12** | **The routing discount is designed and unmeasured.** a1/a2 require the Phase-1 evidence window; a3/a4 require a build with the discount. | T-078 |

**What must close before the layer ships in any path: C-3b, C-4 and D-8.** C-3b and C-4 are cheap, artifact-free and safety-bearing; D-8 is one run. C-1's thresholds can be re-derived from the first real measurement, but C-3b and C-4 are not tuning, they are invariants. **For Phase 1, C-8 joins that list** — the note cannot ship at the cost of prompt headroom or emergency recognition.

---

## 9. Task integration

**No new task IDs.** `T-070`–`T-079` stay fixed. The structural check follows the table.

| Task | Scope note |
|---|---|
| **T-070** — Dialectal-Variant Coverage Measurement | **Extended.** Its existing clause *"What is measured about the STT pass specifically … reports, for each candidate, whether the noise pass reproduces it, and at what rate"* becomes a full §4 distribution run: alignment over the pair corpus, the closed error-class + confusion-group taxonomy, per-class frequencies with register/script/length splits, top-K word lists, the `unaligned` and unchanged counters, **the false-positive population** (§4.4.7 — without which §5.5.1's calibration is impossible), the stratified 200-event native-speaker verification, and the `EXIT_FLOOR` floors. Its deliverable widens from per-candidate counts to per-candidate counts **plus** the error distribution, the derived phonetic key with its collision rate, and the calibration set the threshold is fitted on. Its "negative result is a first-class outcome" clause extends: a class with zero events is printed as zero and is not a fold. |
| **T-072** — Canonicalizer Rules Schema & Composition Design | **Extended.** The schema acquires the **correction-lexicon variant** plus the calibration manifest (§5.6). Required new `issues()` cases: `safetySetTouched` (refusing the whole file), `identityLeak`, `calibrationMissing`, `calibrationStale`, `thresholdRangeInvalid`. T-072 also owns the fix for the **offset-unit error** in the merged design's §4.2 (`unicode_scalar`, not UTF-16 — §3), because that doc comment lives in the file T-075 implements. |
| **T-074** — Variant-Table Authoring & Native-Speaker Validation | **Extended.** Authors the correction lexicon, the frame/co-occurrence tables, and the calibration set, from T-070's measured distribution and never from intuition (A-3): every entry cites its class, its run revision and its `occurrences`; the `confusableWith` sets are authored from the measured continuation ambiguity (57 of 121 prefix-related tokens — §3), not discovered at runtime; the scoring weights, the L1 count floor and λ are authored constants in the versioned data file and **frozen before any gate runs**. T-074 runs §5.5.1's calibration and writes the manifest. The safety review extends to the **completion hazard** (§5.8.2): a candidate that manufactures a negation or emergency token from a fragment is not authored. |
| **T-075** — DialectCanonicalizer Implementation & Pipeline Composition | **Extended.** Implements `STTCorrector` (§5.2–§5.5), the composition ordering `sanitise → correct → canonicalize → tokenize` (§6.1), the **composition of the corrector's offset map with the canonicalizer's** with the abstain firing if **either** widens a required span (§5.7), the prefix-only rule inside required spans, the entity veto, and the `degraded`/fail-closed path. Its "four composition seams" scenario gains a fifth assertion: the corrector's output is **not** routed through `NepaliTextNormalizer` and the cache key is unchanged by it. **Phase 1 only**: this task does not touch routing, and C-7c's structural assertion is part of its Definition of done. |
| **T-076** — Cascade-Default Implementation (flip + kill switch) | **Extended — this is Phase 1's surface task.** Owns the **"Last correction" card line** in the encoder card (`SettingsView.swift:3461-3494` shape, in-memory, released with the turn, never persisted, never logged), the `STTCorrectionSettings` toggle and the **threshold control** (clamped to `thresholdRange`, calibrated default shown beside the current value, `reset` restoring it), the L10n keys (G-A11), the `stt_correction` `TurnTimingStage`, the `.off`/`.shadow`/`.apply` arms, and the A/B plumbing that makes the Phase-1 arms selectable on a debug build. **Its `isCascadeEnabled` treatment is the precedent for the arm selector** (`IntentEncoderFeature.swift:102-113`): a behaviour that must not be in play on a device whose switch was never touched. |
| **T-077** — Canonicalization-Losslessness & Safety-Regression Verification | **Re-scoped, and this is the load-bearing one.** Its gate is computed over the **composed** transform `correct ∘ canonicalize` (§7 C-4), its fixture gains the corrector's frozen fragments, and it gains a second negative arm (`नखा` → `नखाए`). Its scope grows; its ID does not. **Until this lands, T-077's PASS is a statement about a transform that is no longer the whole transform.** |
| **T-078** — Latency, Residency & Default-Flip End-to-End Verification | **Extended.** Runs C-1/C-2/C-3, **C-7a/b/c (the Phase-1 MVP gate)** and C-9 as the corrector's harness (mirroring `run_fixture_sweep.sh`'s shape and exit discipline); runs C-5's CPU harness with `measure_device.py`'s percentile semantics; runs the **Phase-1 A/B arms** (`.off` vs `.shadow` vs `.apply`) and the note-rendered vs not comparison (D-20); and owns the **Phase-2 activation records** (C-11) once the evidence window exists, plus C-2b's encoder-agreement arm once Stage 0 is green. Its device run must show the new `stt_correction` stage in the breakdown; a turn breakdown without it is a verification defect. |
| **T-079** — TG-10 Loop Binding | **Extended.** Registers the correction lexicon, the **calibrated threshold and its range**, the frame/co-occurrence tables and the scoring weights as **promotion-gated artifacts** alongside the variant tables and `calibration_temperature`; records the lexicon revision **and the calibration revision** in the run and **corpus** manifests (A-15/C-10a); owns C-10's corrected-bucket build and the residual-corruption floor; and carries A-11 unchanged: counts and rule ids may egress, surface forms may not, and G-3 stays referred. |

### 9.1 The structural-gap check — and why no new ID is required

Every piece of this design is an extension of a task whose stated scope already contains the seam:

- The measurement extends T-070's existing "check the STT-corruption claim against the noise pass" clause from a per-candidate check to a distribution **plus the calibration set**.
- The schema, including the calibration manifest, extends T-072's schema.
- The authoring **and the calibration run** extend T-074's authoring.
- The engine, the composition and Phase 1's non-compulsion guarantee extend T-075.
- Phase 1's card, toggle, threshold control, timing stage and A/B plumbing extend **T-076**, whose existing subject is exactly the kill switch and the Settings surface.
- The safety verification **re-scopes** T-077, which is a change to what the gate is computed over, not a new gate.
- The harness, the Phase-1 arms and the Phase-2 activation records extend **T-078**.
- The artifact registration, the corpus binding and the residual-corruption floor extend **T-079**.

**The near-misses, stated rather than buried.**

1. **C-2's model-level arm (C-2b)** is a verification that cannot run today and is not T-077's subject (T-077 is safety, C-2b is intent stability). It is recorded as **gap G-A2 with T-078 as owner** rather than as a task, because a task that cannot be started is not a task — it is a gap, and the gap register is where TG-12 already puts things like it. **If a future revision wants C-2b to be independently owned** (a different agent from T-078's, on TG-12 §12's "verification is independent of implementation" principle), that is the moment a new ID is warranted, and the honest move is to take it from outside `T-070`–`T-079` rather than to renumber.
2. **Phase 2's two consumers** are, structurally, two new behaviours (a routing change and a prompt change) that a future revision might reasonably want as their own tasks with their own owners. This design keeps them **inside T-075 (mechanism) and T-078 (measurement)** behind flags, because **they are not being built now**: Phase 2 is documentation of *what would have to be proven*, and the proof obligation is what lives in T-078. **If Phase 2 is ever activated, the activation record is the trigger to allocate real IDs outside this group** — which is the correct moment, and the addendum says so rather than pre-allocating them.

Nothing here structurally requires a new ID *today*. Two estimates move and are recorded rather than absorbed: **T-070 `S → M`** (§4 roughly doubles its work) and **T-075/T-076 `L`/`M → L+`/`M+`** (the corrector plus Phase 1's surfaces). Nothing is renumbered.

---

## 10. Risks

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| A-R1 | **A wrong correction feeds the model a confident wrong word** — worse than the typo it repaired. | **HIGH** | A-4 + A-5: precision is the tight gate (C-1a ≥ 0.95), a **calibrated** threshold rather than an authored one (A-12), the margin rule (§5.5), and C-3b's no-op over 8 000 clean rows. |
| A-R2 | **A correction manufactures a negation or emergency token from a fragment** (`नखा` → `नखाए`). | **HIGH (SAFETY)** | §5.8.2's two-sided veto + `safetySetTouched` refusing the whole file + C-4's second negative arm. Not covered by the canonicalizer's existing rule — this is a new hazard the layer introduces. |
| A-R3 | **T-077's gate silently stops covering the pipeline** because the corrector is upstream of the transform it verifies. | **HIGH** | C-4 re-scopes the gate to the composed transform (§9, T-077 row). Recorded as a **gate-coverage hole**, not a test addition. |
| A-R4 | **A `contact` token is fuzzy-corrected to the wrong person.** | **HIGH (SAFETY)** | §5.7's prefix-only rule inside required spans + §5.8.3's entity veto + the margin. Structurally contained rather than score-gated. |
| A-R5 | **The escalation note costs prompt headroom and moves emergency recognition.** The template has ~300 tokens of headroom, a documented EMPTY-completion overflow, and a measured 53-token change that took emergency recognition 5/7 → 0/7. | **HIGH (SAFETY)** | §7 C-8: re-measure on the real tokenizers, re-pin the ceiling, re-run the emergency draw check, and **do not ship the note at the cost of a safety number**. The zero-token fallback (card + log only) is specified and the MVP still works with it. |
| A-R6 | **The threshold is calibrated on a proxy** and is stale the moment T-066 widens the noise source. | **HIGH** | A-12's manifest binding + `calibrationStale` refusing the load (C-9c) + G-A5 printed with every calibrated number. |
| A-R7 | **Phase 2 gets enabled on a hunch** — "the discount obviously helps" — instead of on its numbers. | **HIGH** | C-11a/b: an activation record is required to flip the flag, the numbers are a1–a4/b1–b4, and enabling without a record is **refused** (exit 3), not warned about. |
| A-R8 | **The corrector collapses the noisy training bucket**, destroying the noise robustness the 60 % anchor exists to train. | **MEDIUM-HIGH** | A-15 + C-10b's residual floor, with the honest conclusion stated: a corrector strong enough to break the floor means **widen the round trip**, not lower the floor. |
| A-R9 | **The extraction is a proxy for a proxy.** Calibrated and gated on synthetic round-trip noise. | **MEDIUM** | G-A5, printed with every result; G-A1/G-A4 name the data that would make it real. |
| A-R10 | **The paired-keyword prior is too thin to earn its keep** — the worked example's pair occurs once in 8 000 rows. | **MEDIUM** | §5.4's three-level backoff with per-level coverage reported; §12 OQ-1 makes "the prior measures +0, ship the prefix+fuzzy tiers alone" a printable outcome. |
| A-R11 | **The prior is fitted to template design**, not language (G-A6). | **MEDIUM** | Per-level coverage + generator provenance in T-070's report; L1-only corrections held to a **higher**, not lower, bar. |
| A-R12 | An entry `id` encodes a surface and leaks the user's utterance through the logs. | **MEDIUM** | §5.6's opaque-id rule + `identityLeak` + C-6's sweep. The merged design's own `id` convention would have done exactly this. |
| A-R13 | **The `{corrections}` placeholder breaks train/inference prompt identity.** | **MEDIUM** | C-8d: four renderers in one change; `intent_prompt.py` raises on a missing placeholder, so the failure is loud. |
| A-R14 | **The "Last correction" card line persists or egresses a surface form.** | **MEDIUM** | §6.6.3 + C-7b's lifecycle test: in-memory, last-turn, released, absent from `IntentLogStore` and the event channel — the `Last turn` precedent verbatim. |
| A-R15 | The corrector's cost is hidden by folding it into `encoder_tokenizer`, so nobody can see it. | LOW | The `stt_correction` stage (§7 C-5), with the closed-set schema change stated and justified. |
| A-R16 | **The lexicon grows into a spell-checker** — entries added because they seem right rather than because the decoder makes them. | MEDIUM | A-3 + T-074's sourcing rule: an entry without a run revision and `occurrences ≥ 1` cannot load. |
| A-R17 | A debugger slides the threshold to the floor and ships an intent flip. | MEDIUM | C-9d: the card's range **is** the C-2-derived range, clamped, with a test asserting the clamp. The invariant bounds the operating point. |

---

## 11. Requirements traceability

| Behaviour | Requirement |
|---|---|
| A typo/truncation is repaired before the intent model reads it | **FR-008** (accurate intent interpretation), **NFR-001** (task success) |
| Correction runs on-device, no cloud, no user data off-device | **NFR-015** |
| No surface form in any event, log or manifest | **NFR-016** |
| The safety net, the emergency path and the med-ack/denial paths are unaffected | **FR-009** (safety paths not dependent on the model) |
| The correction sits inside the interpreter's existing sanitised input path | **NFR-013** (injection defence; `quarantine` level) |
| The layer is a bounded, deterministic table lookup | **NFR-002** (latency), **NFR-029** (determinism/reproducibility) |
| The lexicon, the threshold and its range are replaceable data, not code | **FR-005** (on-device personalisation, data-driven) |
| The measurement precedes the authoring and the calibration | **FR-005**, TG-12 §4.3.1's sourcing discipline |
| Phase 2 is gated on measured evidence, not judgement | **NFR-029**, TG-12 D-8's evidence discipline |

---

## 12. Open questions

1. **Does the paired-keyword prior earn its complexity?** The worked example's exact pair occurs **once** in 8 000 rows; the frame-level signal (L2) is what actually resolves it. If a first measurement shows L1 contributes nothing beyond L2 and L3, the honest design is a two-level backoff and a simpler scorer. **The prior must be ablated, not assumed** — that ablation is a gate row, not an argument.
2. **Where does the precision/recall knee actually fall, and is the 0.95 floor the binding constraint or the knee?** §5.5.1 records both so the answer is visible, but the values are unknown until the calibration set exists. If the knee falls *below* the floor, the corrector is precision-limited and better lexical evidence — not a different threshold — is what would help. This is the empirical core of A-12 and the number the whole design turns on.
3. **What is the L1 count floor?** A pair seen twice is not evidence; a pair seen twenty times may be a template artifact. If the floor is too high, the prior never fires; too low, it fires on the generator. Chosen, and unresolved.
4. **Does the correction help the encoder at all, or only the pipeline's telemetry?** The same honest prior as TG-12 OQ-1: a student trained on the noised bucket may already read `मौस` in context. C-2b is the measurement and it is unreachable today (G-A2). **The expected effect size is unmeasured and may be zero.**
5. **Does the prompt note measure positive or negative?** The template's history says a small size change can move emergency recognition a long way in this exact model; it says nothing about whether a correctly-formatted correction field helps. D-20 measures it in Phase 1, b1 gates it in Phase 2, and `+0` is a legitimate printable outcome.
6. **Is `.shadow` the right Phase-1 default instead of `.apply`?** The directive's MVP applies. The counterfactual for Phase 2(a) is cleanest from `.shadow`. Running `.shadow` for the evidence window and then switching the default collects both — but it delays the user-visible benefit, and the honest cost of each ordering is unmeasured. **Design decision required before T-076 wires the default.**
7. **Should the corrector run on the clean corpus's own vocabulary as a lexicon, or only on the measured pairs?** The 1 050-type vocabulary is the obvious candidate source, but a lexicon entry the decoder never produced is an entry authored from intuition (A-3). The tension is real and the resolution is a rule, not a preference.
8. **Does the picker rung want any of this?** §6.2 designs the note and specifies the zero-token fallback unless C-8 passes. If typo-corrupted utterances are disproportionately the long tail, the argument inverts — the same possibility TG-12 OQ-5 records for the canonicalizer.
9. **Is `prefixOnlyInRequiredSpans` too strict to buy anything?** It is the safest rule and it will refuse some correct corrections. Measuring how often it refuses, on the rows where the correction mattered, is what would justify relaxing it — and relaxing it needs a safety argument, not an accuracy one.
