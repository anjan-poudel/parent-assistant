# T-062 — Nepali Dialect, Degradation & Accent Inventory Review: determination record

**Task:** [T-062](../.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/T-062-dialect-inventory-review.md) (TG-11)
**Worktree:** `.claude/worktrees/t062-dialect-review` (branch `worktree-t062-dialect-review`, base `master` @ `b7f0455`)
**Date:** 2026-09-15 · **Status:** determination record + structured banks; reviewer sign-off **pending**
**Scope discipline:** documentation and data only. No production code, no training run, no GPU, no `xcodebuild`, no audio recording, no real transcript collected, no merge. Every claim below is either (a) read in this worktree at the cited `file:line`, or (b) a published source cited inline, or (c) explicitly marked `unconfirmed`.
**Companion data file:** [`specs/T-062-dialect-banks.yaml`](T-062-dialect-banks.yaml) — the machine-consumable banks T-063 lands into `annotation_rules.yaml`.
**Access note (disclosure):** this review was conducted by an engineer with no native-speaker competence in Nepali. That is not a defect to hide: it is the reason Part G exists. No linguistic judgement below is asserted as a native speaker's; the questions that need one are compiled, not answered. The three engineering determinations (Part E) are the exceptions — they are about the tool and the corpus, not about the language.

---

## 0. Summary of determinations

| # | Question (from the task) | Determination |
|---|---|---|
| D-1 | The `dialect` value set `standard, eastern, central, western, terai` | **Narrowed to three labels: `standard`, `eastern`, `doteli`** — the values the shipped `DialectLabel` already carries. `central` **dropped** (ambiguous: published "Central" = Jumli/Khasani, and the value collides with `standard`); `western` **dropped as a label, folded into `doteli`** for the far-west slice and otherwise unclaimed; `terai` **dropped** (it is not a Nepali dialect region) |
| D-2 | Far-Western distinct from Western? | **Yes — distinct to the point of language status** (ISO `dty`, ~790k speakers). Answer: the axis carries **`doteli`**, not `western`, and the claim is a *language-level* claim, worded as such |
| D-3 | Terai one slice or several? | **Neither: not a Nepali dialect slice at all.** The Terai's languages are Maithili/Bhojpuri/Bajjika/Awadhi/Tharu/Urdu — distinct mother tongues. **Explicitly unclaimed**, with a forbidden-claim list |
| D-4 | Do the surviving distinctions have lexical/orthographic consequence for *this product's* vocabulary? | **Mostly no, and that is the finding.** Over the closed banks: METHODS and app names are dialect-invariant English loans; CONTACTS/MEDS candidates are pan-regional synonyms already in or adjacent to the banks; the only attested **region-exclusive** material is verb morphology that sits in third-person positions **outside** the span vocabulary. The `eastern` bank is therefore mostly *spelling*, which is not dialect evidence (Part C.4) |
| D-5 | `style` orthogonal to `register`? | **Confirmed orthogonal for `clipped` and `honorific`; `mixed_code` dropped.** `clipped`/`elder_fragmented` overlap answered (D-5b): `clipped` is the scheme, `elder_fragmented` is an undefined register the pinned corpus does not populate. `mixed_code` is a *different phenomenon* from `code_switched` but has **no data** → not authored, not claimed (design OQ-5 answered). **No new register is required → the mixture arithmetic (60/25/15) is unchanged** |
| D-6 | Claimable slices | **Claimed: `standard` only.** `eastern`/`doteli`: *conditionally claimable* — gated on the review pack (Part G) **and** ≥300 matched twin pairs (T-064) **and** the dialect gate passing (T-065). Everything else: unclaimed. Permitted wording fixed in Part D.3 |
| D-7 | Noise ladder endpoints {15, 10, 5, 3} dB | **Kept**, with one correctness note: the band is the **STT model's** training band (`tools/train/src`), not the encoder's — the encoder is gated on the *pipeline*, so the ladder's anchor statement must name the STT, and the mixing **domain** must be declared (design OQ-7) or the dB numbers are not comparable |
| D-8 | The piper knobs | **All three exist in piper and are CLI-settable, but the flag spelling is version-dependent** (`--length_scale`/`--noise_scale`/`--noise_w` in archived `rhasspy/piper`; `--length-scale`/`--noise-scale`/`--noise-w-scale` in `piper1-gpl`) and `synthesize` passes neither today (`stt_noise.py:49`). Ruled: T-066 must **declare the flag set it verified, fail loudly on an unsupported flag, and record a measured transcript-change precondition per cell/level** |
| D-9 | The articulation cells | **Reshaped, not adopted as written.** Rate is a **two-sided** perturbation: *slowed* speech is elder-realism and tends to *help* ASR; *fast* speech is the degrading direction. A cell that mixes an improving axis with degrading ones, or that changes no transcript, measures the fixture. Recommended cell reshaping in Part E.3 |
| D-10 | Naming contract | **Confirmed and tightened** (Part E.4). Quotable strings; the round trip is never "accent coverage" |
| D-11 | GAP-1/2/3 | Each names an acquisition. **GAP-3 is materially closer than the design assumed**: two licence-clean Nepali piper voices are already named, licensed and (one) digest-pinned in the tree (Part E.5) |
| D-12 | Accent coverage | **No claim rests on the noise pass.** The permitted vocabulary is fixed in Part F |

---

## Part A — The dialect axis as it actually is (code + data evidence)

### A.1 What ships

| Fact | Evidence |
|---|---|
| The shipped dialect vocabulary is **three values**: `eastern`, `doteli`, `default` | `ios/ElderlyAssistant/Services/Voice/DialectIdentifier.swift:43-53` |
| `DialectLabel`'s raw values are **persistence keys** — "never rename (add cases instead)" | `DialectIdentifier.swift:41-42` |
| The centroid table ships **SEED-CENTROIDS**: "unit vectors of random direction, so cosine similarity to any real embedding is ≈ 0 and classification honestly falls back to `.default` (margin confidence ≈ 0.5 < 0.6 gate)" | `DialectIdentifier.swift:16-20`; table at `ios/ElderlyAssistant/Resources/DialectCentroids.json` (`generation.status = "SEED-CENTROIDS"`, `confidenceGate = 0.6`, clusters `eastern` + `doteli`, `promptTokenIds: []`) |
| The seed table cannot classify by construction, and a test pins that | `DialectIdentifierTests.swift:393-406` ("A seed table must never classify anything") |
| The lexicon ships **SEED-LEXICON** with the phrase sets explicitly "**pending linguist review**" | `ios/ElderlyAssistant/Resources/DialectLexicon.json` (`generation.path`); entries `eastern` (`गइछ`, `भइछ`, `खाइछ`) and `doteli` (`भया`, `रह्याको`, `भण्याको`) |
| The lexicon's own generation note records the **standard forms the seeds substitute for** (`गइछ→गएछ`, `भया→भयो`, `रह्याको→रहेको`, `भण्याको→भनेको`) | same file, `generation.path` |
| Per-user profile biasing exists and is wired: contact/medication/app terms compose with the dialect tag line under a ≤100-token cap | `DialectBiasComposer.swift:51-71` (`DialectBiasProfile`), `:60-66` (`standardSupportedAppNames`), `AppCoordinator.swift:995`, `:1030`, `:1647-1656` |
| **The dialect label is inert in production.** Its only writer, `applyDialectLabel(_:)`, has **no production callers**; the embedding/classification bridge is documented as "the future enrolment flow" → the persisted label is `.default` in the field | `WhisperKitSpeechRecognizer.swift:762`, `:864`; recorded as `plan.md:109` risk 35 and `specs/TG-12-notes.md:46` |
| Consequence: the **only** dialect material that can act today is the pan-regional half (script-consistency + profile-term biasing); the per-dialect half waits on enrolment + a calibrated centroid table | `DialectBiasComposer.swift:29-40`, `:279-284` |

### A.2 What the corpus carries

Read from `tools/train-intent/eval/golden_corpus.jsonl` in this worktree:

- 8,000 rows; keys are `id, utterance, script, intent, slots, spans, notes`.
- **Zero rows carry a `dialect` key. Zero rows carry a `style` key** (measured: `dialect`/`style`-tagged rows = 0). Design §7.8's GAP-4 is confirmed as stated.
- `script` ∈ {`devanagari` 5,508, `latin` 1,678, `code_switched` 814}.
- **All 800 `query` rows are span-less** — confirming design §3.3 and OQ-1: the requirement's own example ("slot भोलि") does not hold today, and `query` supervises no `time` span.

### A.3 What the rules carry

- Four registers, unchanged: `devanagari, romanized, code_switched, elder_fragmented` (`annotation_rules.yaml:216`); the bucket map `register_to_bucket` at `:210-215` mirrors `BUCKET_OF_REGISTER` (`build_dataset.py:77-82`).
- **`elder_fragmented` is a declared register with a bucket mapping and no pinned meaning or population in the pinned corpus.** The golden-corpus generator's own register cycle is `("devanagari",)*7 + ("latin",)*2 + ("code_switched",)` (`golden_corpus_batches.py:117-118`); `elder_fragmented` appears only as a teacher-side default (`gen_teacher.py:288`) and in the round-2 weighting plan. Its semantic content is not defined anywhere — which is precisely the duplication question D-5b answers.
- Mixture targets 0.60/0.25/0.15 with `hard_floor_stt_noised: 0.55` (`annotation_rules.yaml:209`, `:230`); register is load-bearing because it selects the bucket.

### A.4 The axis today, stated plainly

The proposed `dialect` axis is **additive metadata with zero population, zero gate, and no consumer**: nothing in the corpus, the rules or the runtime reads it. Adopting it costs nothing (design §5.1 is right that it changes no model label). The risk it carries is not technical but rhetorical — a five-value axis reads as five supported varieties (design R-5, `plan.md` risk 35). Everything in Parts C–D exists to keep that reading from happening.

---

## Part B — The published Nepali dialectology baseline

**B.1 The mainstream classification is three dialect areas, not four or five.** The standard reference division is **Western / Central / Eastern** (C. M. Bandhu, 1968–69), with the far-west treated as the most divergent area:

- **Western** — far-western Nepal (Mahakali zone and the western half of Seti zone); described as so different from the Kathmandu-based Eastern dialect that mutual intelligibility is difficult; preserves Old Nepali features such as grammatical gender.
- **Central** — eastern Seti, most of Karnali, part of western Bheri; also called **Jumli** or **Khasani**; many subdialects.
- **Eastern** — the rest of the mid-mountain belt plus Darjeeling/Assam/Bhutan; **standard Nepali (media, radio, textbooks) is based on this dialect**. Subdialect differences within it are described as not large.
- Crucially for D-3: the Eastern area is described as **excluding the southern Tarai plains**, and the source itself notes that Nepali dialectology "is still in its early stages" and that the sound-change tendencies it lists "have not reached the level of established regular rules".

**B.2 The far-west is a distinct *language*, not a dialect.** Doteli/Dotyali (डोटेली) has ISO 639-3 **`dty`** (Glottolog `doty1234`); it was recognised as a distinct language by Ethnologue in 2012 (its name set includes Baitadeli, Dadeldhuri, Darchuleli, Bajhangi); the 2011 Nepal census recorded ≈ **790,000** speakers; it has official status under the Constitution of Nepal 2072 (2015) Part 1 §6 and is recommended as an official language of Sudurpashchim Province. Its four dialects (Baitadeli, Bajhangi, Darchuli, Doteli) are mutually intelligible.

**B.3 The Terai is a *language contact zone*, not a Nepali dialect region.** In the 2021 census, the Terai/Madhesh mother tongues are distinct languages: Maithili 3,222,389 (11.05%), Bhojpuri 1,820,795 (6.24%), Tharu 1,714,091 (5.88%), Bajjika 1,133,764 (3.89%), Awadhi 864,276 (2.96%), Urdu 413,785 (1.42%). Nepali is the official language and is spoken as a **second** language by 46.2% of the population; in Madhesh Province Nepali-as-L1+L2 is 76.5% (the lowest of any province) with the highest bilingualism rate (56%). The Language Commission of Nepal (2021) recommended Maithili, Bhojpuri and Bajjika as official languages of Madhesh Province.

**B.4 What the literature does *not* provide** — and this bounds every claim this project can make:

- **No published per-dialect speech corpus and no per-dialect WER for any Nepali variety** (the nearest asset is a gated research corpus). The project's own research states the conversational/elderly/regional regime at 40–60% WER "is essentially unmeasured" (`docs/research-sections/accent-adaptation.md:191-196`).
- **No region-exclusive lexical attestation** for the product's closed vocabulary. The published material is sound-change *tendencies* (gemination, aspiration, consonant loss) plus the Doteli language forms — not a per-region word list over contacts, medicines, times or methods.
- The project's own research already reached the same conclusion in its own words: the ASR-relevant taxonomy is "Central/Eastern/Western, with the far-west Doteli complex … the most distinct group" (`accent-adaptation.md:189-190`), and the taxonomy question is recorded as **open** ("Which clusters actually ship (Doteli complex? Eastern? Madhesi?)", `accent-adaptation.md:545-546`).

**Sources:** Bandhu's Western/Central/Eastern division and its feature lists are summarised at the *Nepali language* dialectology entry (English Wikipedia, citing Bandhu 1968–69); Doteli at *Doteli language* / ISO 639 `dty` / Glottolog `doty1234`; 2021 census figures at *Languages of Nepal* / Nepal National Population and Housing Census 2021; census language count and Commission recommendations as reported there. This project's own secondary baseline: `docs/research-sections/accent-adaptation.md:187-196`, `:545-546`; `docs/nepali-voice-stt-research.md:80`.

---

## Part C — Validating the proposed value set, value by value

### C.1 The table

| Proposed value | Ruling | Rationale (evidence) |
|---|---|---|
| `standard` | **KEEP — and define it as a *register*, not a geography** | `standard` must mean "the authored standard Devanagari register the corpus pins" (`golden_corpus.jsonl`, 5,508 `devanagari` rows), because the published account makes **standard Nepali *based on* the Eastern dialect** (Part B.1) — so `standard` and `eastern` are not disjoint *geographic* slices on the literature's own terms. Defining `standard` geographically would make the axis incoherent |
| `eastern` | **KEEP — matches both shipped code and the literature** | `DialectLabel.eastern` (`DialectIdentifier.swift:44-46`); the literature's Eastern area; the shipped SEED-LEXICON's attested perfectives. But see C.4: the *authored* material for this slice is thin and mostly spelling |
| `central` | **DROP** | Two independent reasons: (a) the published "Central" is **Jumli/Khasani** (Karnali), not a Kathmandu-centric middle — an engineer reading "central" means the latter, and a Nepali speaker reading it means the former, so the label is ambiguous in a way a corpus cannot afford; (b) its only evidence-based content overlaps `standard` (the standard is Kathmandu-based Eastern, and the design's own "central" was the unmarked middle). If a Karnali slice is ever wanted, it must be named `jumli` and it starts **unclaimed** |
| `western` | **DROP as a label; content folded into `doteli`** | "Western" in the literature means the far-western area whose distinct variety is **Doteli (ISO `dty`)**, which is the label shipped code and the SEED-LEXICON already use. Two labels for one slice is exactly the drift T-062 exists to prevent. The mid-hills between Doteli and standard (Gandaki/Karnali) have **no evidence in the tree and no attested vocabulary** → unclaimed, unnamed |
| `terai` | **DROP — explicitly, and record the forbidden claim** | Part B.3: the Terai's mother tongues are separate languages (Maithili/Bhojpuri/Bajjika/Awadhi/Tharu/Urdu), counted separately in the census and recommended separately for official status. One `terai` value would (a) assert that these are one dialect of Nepali, which is wrong, and (b) author Nepali rows for speakers whose speech is not Nepali. See C.3 |

### C.2 The Far-Western question, answered explicitly

**Question (task item 1):** is Far-Western distinct enough from Western to be its own slice, or does collapsing them lose a real difference?

**Answer:** the premise does not survive contact with the literature. There is no evidenced "Western" slice to collapse *into*: the far-west variety is **Doteli, a distinct language (ISO `dty`)**. The determination is therefore not "separate or collapsed" but **"named correctly"**: the axis carries `doteli` (matching `DialectLabel.doteli`, `DialectIdentifier.swift:46-48`, and the SEED-LEXICON entry), and the concept the label carries must be stated as **language-level**, not dialect-level:

- Consequence for authoring (T-064): a `doteli` row is written in Doteli, and its standard twin is the Nepali row saying the same thing. That is a **translation pair**, not a spelling pair — the two rows differ in words the tokenizer will fragment (design §5.3, "absorbable only with training mass").
- Consequence for the claim (T-069): "the model does not collapse on Doteli-language input relative to its standard twin" is a **narrower and different** claim from "supports Nepali dialects", and it is the only one the mechanism can support.
- Consequence for resolvers (design §5.3, R-9): a Doteli surface the encoder emits still goes to the shipped resolvers verbatim. Every authored `doteli` span must pass the resolve-through check or be marked `resolver_blocked`.

### C.3 The Terai question, answered explicitly

**Question (task item 1):** is the Terai belt one slice or several?

**Answer: neither — it is not a slice of a Nepali dialect axis.** The three-language framing in the question (Maithili/Bhojpuri/Awadhi) understates it: the census separates at least six Terai mother tongues, and none of them is a dialect of Nepali. Treating them as one slice would be wrong in exactly the way the task anticipated (baking three-plus language communities into one label), and splitting them would not fix it — they are not varieties of the target language.

What is *real* and is being declined: a **Terai-accented Nepali** (L2 speakers with Maithili/Bhojpuri phonology) is a genuine recognition-stress population for this product. But that is an **accent** phenomenon — an STT/audio problem — and the corpus `dialect` axis is a *text* axis. The axis cannot express it, and the noise pass cannot produce it (Part F). Recorded as a gap (GAP-5, Part H) with its data requirement, **not** as a dialect slice.

**Also dropped with it:** the design's `style.mixed_code` (see C.6), whose only purpose was Terai-language mixing.

### C.4 Do the surviving distinctions have lexical or orthographic consequence for *this product's* vocabulary?

This is the determination the model-size question turns on, and the honest answer is **mostly no** — over the closed banks, the dialect signal is thin and what exists is spelling. The review walked the banks (`golden_corpus_batches.py:240` CONTACTS, `:251` METHODS, `:444` MEDS, `:481-488` TIMES, `:609-672` QUERY_\*; `annotation_rules.yaml:31-43` actions).

| Bank | Dialect consequence over the closed vocabulary | Why |
|---|---|---|
| **METHODS** (`फोन`, `भिडियो कल`, `वाट्सएपमा`, `ह्वाट्सएपमा`, `फेसटाइममा`, `भाइबरमा`, `मेसेन्जरमा`) | **None.** Dialect-invariant | Every entry is an English loan or a brand name. The two spellings of WhatsApp (`वाट्सएपमा`/`ह्वाट्सएपमा`) are **pan-regional spelling drift already in the bank** — they are not eastern or Doteli evidence, and must not be filed as such |
| **App/profile names** (`DialectBiasProfile.standardSupportedAppNames`) | **None.** Brand names | `DialectBiasComposer.swift:60-66`. Same reason; also subject to the Devanagari script gate (`:29-40`, `:359-371`) |
| **CONTACTS** (24 kin names + given names) | **Candidate variants only, all `unconfirmed`** | Kin terms are the most likely place for real regional words (`बुबा`/`बा`, `आमा`/`अम्मा`, `दिदी`/`दी`) but the tree holds **no attestation** for any of them. Questions N4 resolves the bank |
| **MEDS** (`औषधि`, `दवाई`, `प्रेसरको औषधि`, …) | **Already contains a synonym pair, and it is not dialect evidence** | `दवाई` beside `औषधि` is the Hindi-contact everyday synonym; it is **already in the emitted bank** today, so treating it as a `terai`/dialect marker would mis-file material the corpus already has. `औषधि`/`औषधी` is spelling drift |
| **TIMES** (`बिहान`, `दिउँसो`, `बेलुका`, `राति`, `साँझ`; `साढे/सवा/पौने`; `भोलि/आज/पर्सि`; `बजे`) | **Candidate variants only, all `unconfirmed`**; most are plausibly pan-regional spelling/fast-speech reduction | `दिउँसो/दिउसो`, `बेलुका/बेल्का`, `साँझ/साझ`, `राति/रात`, `भोलि/भोली`. The clock system (`साढे/सवा/पौने`) is shared standard. Question N5 decides whether any of these is region-marked or all are drift — and a `गर्नुहोस्→गर्नुस्`-shaped reduction must be filed as **STT/articulation**, not dialect: the noise pass already produces it |
| **QUERY_\*** (facts, days, festivals, places) | **Culture-specific items are already present and must not be re-filed as dialect** | `छठ` (a Terai/Madhesh festival) and `लोसार` are already in `QUERY_FESTS` (`:644-646`). Their presence is *coverage*, not a dialect slice |
| **Action/verb material** (ack `खाएँ/खाइसकें/लिएँ`; requests `गर/गर्नुहोस्/गरिदिनुहोस्`; reminder verbs `सम्झाउनु/सम्झाइदिनु`) | **This is where the only region-exclusive material lives — and it sits outside the supervised spans** | The attested SEED-LEXICON markers are (i) the eastern **-इछ perfective** (`गइछ/भइछ/खाइछ` for `गएछ/भएछ/खाएछ`) and (ii) Doteli **past forms** (`भया/रह्याको/भण्याको`). Structurally: the ack_med bank is **first-person** (`खाएँ`, `खाइसकें`), and `-इछ` is a **third-person** perfective — so the attested eastern marker does not occur in an ack row at all. Third-person material occurs in `query`/`none` rows, **which supervise no spans** (`golden_corpus.jsonl`, measured). Net effect: a dialect variant here changes the **intent head** only, and produces **no span material for the slot head**. *The person analysis is read off the SEED-LEXICON's own glosses (`खाइछ → खाएछ`, i.e. the third-person past) rather than asserted — N8/N10 are where the native speaker confirms it, and a contrary answer overturns this row* |

**The structural conclusion (and it is the most decision-relevant output of this review):**

> Over the product's closed vocabulary, the dialect axis carries almost no *lexical* signal for the two named slices. What it can carry is (i) a small number of third-person verb forms outside the span vocabulary, and (ii) spelling drift that is pan-regional and therefore not dialect evidence. A 117M encoder absorbs (i) and (ii) — which means **the dialect gate, as scoped to these banks, will mostly measure spelling robustness under a new label.** T-064's authoring supply and T-065's first measurement must be read with that expectation on the table, not discovered after the fact.

The `unconfirmed` discipline applies throughout: no variant is filed into a slice on geographic reasoning alone. Entries marked `unconfirmed` in `specs/T-062-dialect-banks.yaml` are questions for the native speaker (Part G), and an unanswered question narrows the slice's claim rather than being filled by inference (task DoD; design §5.2).

### C.5 The `known word` vs `new word` marking

Every bank entry carries `model_impact: known_word | new_word | unknown` per design §5.3:

- `known_word` = a **spelling of a word the model already knows** (share most subwords with the standard form). Expected impact: absorbable → this is where the corpus's mass already is.
- `new_word` = a **genuinely different word form**. Expected impact: absorbable only with training mass; a form the tokenizer fragments into rare pieces will not be learned by a 117M encoder without it.
- `unknown` = the reviewer could not tell → **T-061-style measurement decides, not guesswork** (task Implementation notes).

In the delivered banks, the Doteli forms (`भया`, `रह्याको`, `भण्याको`) are marked `unknown`, not `new_word`: they are plausibly frequent light verbs whose subwords overlap with standard material, and the tokenizer's verdict is a measurement (`encoder_contract.yaml:30-34`, 250,037-token XLM-R sentencepiece). Asserting `new_word` from memory would be exactly the fabrication the task forbids.

### C.6 The `style` axis: orthogonal, corrected

| Proposed value | Ruling | Rationale |
|---|---|---|
| `neutral` (default) | **KEEP** | Already the corpus's unmarked state |
| `clipped` | **KEEP — orthogonal to `register`; distinct from `elder_fragmented`** | `clipped` is a **scheme** (the grammatical tail elided under the same content-core partition as permutation, design §7.4a) and it **co-occurs with any register**: a clipped row can be Devanagari, romanized or code-switched. `elder_fragmented` is a single register value that *cannot* express "clipped **and** romanized" — it conflates script with style, which is precisely the §5.1 critique. **They are not duplicates: `elder_fragmented` names a speaker population, `clipped` names a text operation.** Determination: keep `style.clipped` as the carrier of tail elision; pin `elder_fragmented`'s meaning (if it is ever used) to *lexical/prosodic elder register*, **never** as the carrier of elision. No gate is wired for `elder_fragmented` and none is proposed here |
| `honorific` | **KEEP as metadata only; do NOT gate it** | High-honorific address (`हजुर`, `गर्नुहोस्`/`गरिदिनुहोस्`) is a politeness dimension, not a degradation: the corpus already varies verb forms (CALL_VERBS) and the risk named in the design is verb-form drift, not robustness. Slicing metadata is cheap and useful; a "gate" over politeness would set a threshold the product does not need |
| `mixed_code` | **DROP** | The design proposed it for *within-Nepali* mixing with a Terai language. Determination on OQ-5: it is **a different phenomenon from `code_switched`** (different source languages, different contact direction, different frequency profile — Maithili/Bhojpuri function words are not English loans), **but dropping the label is still correct**, because (a) there is **no data** for it — authoring it means authoring in languages the project has no corpus for, and any row would be engineer-typed rather than attested; (b) it was only meaningful paired with the `terai` slice, which is dropped (C.3); (c) the product's closed vocabulary contains no Maithili/Bhojpuri material to vary. Recorded as **GAP-5**, not as a value |

**Mixture-arithmetic statement (task requirement).** The review finds **no new register is required**, so `annotation_rules.yaml:210-216`'s arithmetic and the 60/25/15 targets stay untouched. `clipped`, `honorific` and `dialect` are **row metadata** that select no bucket, exactly as the design proposed. If a later task finds a genuinely new register is needed, the mixture arithmetic must be revisited as an explicit decision — **flagged here as the trigger, not changed here.**

---

## Part D — Claimable slices and permitted wording

### D.1 The gate's bound (restated from design §7.2 / §7.6)

A slice is claimed only if (a) T-064 can author **≥300 matched twin pairs** for it, and (b) the per-slice clauses hold (`dialect_max_gap ≤ 0.05`, `side_effect_precision ≥ 0.97`, `emergency_recall == 1.00`). The gate proves **non-collapse on the slices authored**; it can never prove coverage of a variety nobody authored rows for.

### D.2 The list

| Slice | Status after this review | Condition |
|---|---|---|
| `standard` | **CLAIMED** (it is the corpus; the comparison anchor) | — |
| `eastern` | **CONDITIONALLY CLAIMABLE — not claimed today** | (1) review-pack questions **N1, N2, N5, N9, N10** answered by a native speaker; (2) ≥300 matched twin pairs authored (T-064); (3) `dialects.eastern.status` set to `claimed` in the rules **in the same commit** as the first authored bank (T-063/T-064) |
| `doteli` | **CONDITIONALLY CLAIMABLE — not claimed today** | (1) questions **N1, N4, N6, N8, N11** answered; (2) ≥300 pairs; (3) same status-flip discipline. **Worded as a language-level claim** (C.2) |
| `central` / `jumli` | **UNCLAIMED** (label dropped) | Would need its own evidence and its own task |
| `western` (mid-hills) | **UNCLAIMED** (label dropped; folded into `doteli` for the far west) | — |
| `terai` | **UNCLAIMED, and explicitly excluded from the axis** | See D.3 forbidden claims |
| Maithili / Bhojpuri / Bajjika / Awadhi / Tharu / Urdu | **OUT OF SCOPE — never part of a Nepali dialect claim** | Different languages (Part B.3) |

### D.3 What the product may and may not say

**May say** (each string is bounded by the fixture, the revision tag and the slice):

- "On the authored `eastern` / `doteli` holdout (⟨fixture⟩@⟨sha8⟩, ⟨n⟩ matched twin pairs), closed-intent accuracy did not fall more than 5 points below the matched standard twin, with side-effect precision ≥ 0.97 and emergency recall 1.00."
- "The encoder was measured on ⟨slice⟩ input produced over the product's own entity banks; this is a non-collapse statement about authored material, not a coverage statement about the variety."
- "Nepali standard + eastern + doteli-tagged rows were authored and gated; other varieties were not authored and are not measured."

**May NOT say** (each is a defect if it appears in a manifest, evidence pack, release note or user-facing string):

- ❌ "supports Eastern Nepali" / "supports Terai Nepali" / "supports Nepali dialects" (unbounded)
- ❌ any coverage wording for `central`, `western`, `terai`, or for any Terai language
- ❌ "dialect-aware", "dialect-robust" as an unqualified product adjective while the dialect label is inert in production (A.1) and zero dialect rows exist (A.2)
- ❌ any statement that the noise pass produces accent coverage (Part F)
- ❌ "speaks/understands Doteli" — the claim is limited to *recognition of authored Doteli rows over the closed vocabulary*, and the resolver boundary (C.2, design §5.3) is part of the sentence or the sentence is not permitted

**Status field requirement (recommendation to T-063).** The `dialects:` block must carry, per slice, `status ∈ {claimed, conditional, unclaimed}` **and** a `claim_wording` string. Rationale, in the design's own terms (R-5, R-11, §7.7): a label that exists in the rules while nothing is claimed is read as a claim unless the file itself says otherwise. Making the status a field makes T-069's evidence pack able to check "no gate without a table row, no claim without a status".

---

## Part E — The degradation taxonomy, ruled on

### E.1 The noise ladder {clean, 15, 10, 5, 3} dB

**Kept, with one correctness fix and one precondition.**

- **The anchor statement must name the STT, not "the project".** The band 3–15 dB is the augmentation band of the **Whisper fine-tune** (`tools/train/src/dataset.py:32`, `:39-43`; `--noise-aug`, training-only). The encoder under test never sees noise. So the correct sentence is: *"the ladder is bounded by the band the shipped STT model was trained with"* — which is the same argument the design makes, stated about the right model.
- **Endpoints kept as proposed.** 15 dB as the mildest rung and 3 dB as the floor are the band's own endpoints; the design's reason for not gating below 3 dB ("gating outside the training distribution measures the fixture") is correct and is the review's reason too. Moving the floor is a **data-acquisition question (GAP-1)**, not a threshold tweak — the design's OQ-8 stands.
- **The mixing domain must be declared or the numbers are not comparable** (design OQ-7, R-13): waveform (whisper.cpp) and mel (HF) give different effective SNRs at the same nominal dB. Not a review finding to resolve — a requirement to record.
- **Precondition (new, and the review's own contribution).** Every level must **produce a measured transcript change** on a reference subset before it is gated. A level that changes no transcript is `no_effect`: it is dropped, not counted as a pass. This is the same rule E.3 applies to cells, and it is what stops "a cell that produces no transcript change" from reporting green. T-066 measures it; T-062 fixes the rule.

### E.2 The piper knobs — established from the tool, not from recall

`stt_noise.py:33-50` (`synthesize`) invokes `piper --model <voice> --output_file <wav>` and **passes nothing else** — design §5.5 is confirmed at the line level.

What the tool accepts (established from piper's own CLI, not memory):

| Knob | Archived `rhasspy/piper` (C++, CLI) | `piper1-gpl` (Python, `python -m piper`) | What it does | Relevance to "articulation" |
|---|---|---|---|---|
| length scale | `--length_scale` | `--length-scale` | **Duration multiplier**: >1 slows the voice down, <1 speeds it up. Scales the VITS duration predictor's per-phoneme durations (`∝ 1/rate`) | **Real and load-bearing.** This is the only knob that changes *rate*, the classic elder-speech parameter |
| noise scale | `--noise_scale` | `--noise-scale` | **Generator noise level** — variability of the generated speech (waveform sampling) | Real, but it is a *synthesis-quality* knob, not articulation. Low → flat/robotic; high → unstable/artifacts |
| noise w | `--noise_w` | `--noise-w-scale` | **Phoneme-width (duration) noise** — variability of phoneme *durations* | Real; changes timing jitter, not articulation |

**The finding that matters for the "no-op cell" hazard:** the **flag spelling is version-dependent** (`_` vs `-`), the installed version is **not pinned anywhere in the repo** (no piper version in `tools/train/requirements.txt` or any lockfile; the binary path is a config value, `config.yaml:26`), and the round trip currently runs whichever binary is on the training box. A declared cell that passes a flag the installed build does not understand is a cell that measures nothing while reporting a pass — exactly the failure the task names.

**Ruling (T-066 requirement):**

1. Pin the piper version and the voice model **by digest** in config, and record both in the run manifest.
2. Declare the **exact flag set** the tuple uses, and **assert the tool accepts it** — a version probe or an explicit `--help` capability check at stage start, so an unsupported knob is a loud failure, not a silent default.
3. A `(voice, length_scale, noise_scale, noise_w, snr_db)` tuple is only a *cell* once it has passed the transcript-change precondition (E.1/E.3).

### E.3 The articulation cells

**Ruled: reshaped, not adopted as written.** The proposed cells are

- moderate: rate within ±20% of nominal, mild quality perturbation, SNR 10 dB
- severe: rate ±40%, stronger perturbation, SNR 5 dB.

Three problems, in order of severity:

1. **Rate is a two-sided perturbation, and only one side degrades.** Slower speech is the classic elder profile and it generally **helps** recognition (longer, cleaner durations); the *degrading* direction is **faster** speech. A cell labelled "rate ±20%" therefore contains an improving direction and a degrading one. Gating it either averages them into a number that means nothing, or measures whichever the fixture happened to draw. **Recommendation:** split the axis — `slow` cells are the **elder-realism** cells (their pass condition is *no collapse*: `A ≥ A_clean − 0.05`), and `fast` cells are the **degradation** cells (their pass condition is the fail-safe clause). One cell must not carry both.
2. **`noise_scale`/`noise_w` are not articulation.** Per E.2 they perturb sampling variability and duration jitter. Calling their output "reduced articulation" is a naming error with a measurable consequence: nothing in the VITS generator weakens consonants or slurs segments, so a cell built only from them may change **no transcript at all** — which by E.1's precondition makes it `no_effect`, to be **dropped rather than gated**.
3. **The "severe" cell stacks three perturbations with no attribution.** With rate + quality + SNR 5 dB moved together, a failure cannot be attributed to articulation rather than to noise (SNR 5 dB is already a ladder rung). **Recommendation:** the articulation cells move exactly **one** non-noise parameter (rate), with the noise level declared as a *held* background, so a cell result is attributable.

**What the review expects to be recognisable, and what it refuses to certify.** The published description of elder speech (slow rate, breathy voice, jitter/shimmer, reduced articulation — `accent-adaptation.md` §2, sub-problem B) is the *target*, but a synthetic VITS voice is not an elder and cannot be made dysarthric. Determination:

- The grid stays **named and gated as a proxy** (E.4), never as elder-speech or dysarthria coverage.
- A cell that produces no transcript change is **dropped from the gate** and reported as `no_effect` — it is a legitimate, expected result of this review that some of the four proposed cells will not survive T-066's precondition measurement.
- Whether a *Nepali listener* would recognise the surviving cells as elder-like is a **judgement the review compiles** (question **N12**) rather than asserts; the gate does not depend on the answer, only the wording does.

### E.4 The naming contract (quotable — T-069 renders these strings)

Confirmed and tightened. These are **field values and rules**, not commentary (per `specs/TG-11-notes.md`):

| Dimension | Permitted | **Forbidden** |
|---|---|---|
| Articulation grid | **"reduced-articulation proxy"** — a synthesis-parameter grid over rate and quality, through piper→Whisper, measuring recognition stress | "dysarthria", "dysarthric", "slurred speech", "stuttering", "elder-speech coverage", "parkinsonian" |
| Noise dimension | **"stationary additive white noise"** at a declared SNR, mixed in a declared domain (waveform or mel) | "babble", "room noise", "market/street/TV noise", "real-world noise", "crowd noise" |
| Piper round trip | **"synthetic STT-error profile induced by a non-native (Hindi) TTS rendering of Nepali text"** | "accent modelling", "accent robustness", "accent coverage", "regional accent measurement" |
| Multi-voice (when a bank exists) | **"speaker-variation proxy"** — the same text in different voices | "regional accent", "dialect coverage", "Eastern/Doteli accent" |
| Dialect slices | "non-collapse on authored ⟨slice⟩ rows vs their matched standard twins" | any unbounded coverage phrasing (D.3) |

### E.5 GAP-1 / GAP-2 / GAP-3 — each an acquisition

| Gap | Unmeasurable | Why (citation) | Data needed to close it |
|---|---|---|---|
| **GAP-1** | Real-world noise: babble, television, market, street, room, telephone channel | Only white noise exists (`dataset.py:42-43`); `synthesize` mixes nothing at all (`stt_noise.py:33-50`); the ladder is white-noise-only by construction (E.4) | A **licensed noise corpus with per-scene labels** and a stated mixing policy (which scenes at which SNRs), plus the declared mixing domain (waveform vs mel, OQ-7). Candidate assets of the right class exist and are licence-clean for commercial use — e.g. **MUSAN** (OpenSLR SLR17, **CC BY 4.0**, ~6 h of noise, per-file licences and an `ANNOTATIONS` file; note babble/street are **not** guaranteed scene labels) — so the acquisition is a *selection + mixing-policy* decision, not a research project. Procurement decision, outside this task group (design OQ-9) |
| **GAP-2** | Real slurred / dysarthric / genuine elder speech; hearing-aid and telephone-channel effects; the actual elder-speech distribution | A synthetic VITS voice cannot be dysarthric; the grid is a stress test (`stt_noise.py:68-95` is a plain TTS→Whisper path); FR-005 keeps accent tuning on-device (`requirements.md:29-31`) | **Consented recordings of the target population** + a privacy basis compatible with FR-005 (NFR-015/NFR-016), an acquisition protocol, and a retention/deletion policy — a separate project. **Explicitly not commissioned here**: no audio was recorded and no real transcript collected for this review (Part J) |
| **GAP-3** | Accent: the bank holds **one voice and it is Hindi** (`config.yaml:23`, `hi_IN-pratham-medium.onnx`), so gate 5 is vacuous | Design §7.5; measured: `synthesize` passes no `--speaker` and the voice bank is a single file path | **Concretely: ≥2 Nepali-capable piper voices** (the design's condition, now satisfiable by named assets — see below), each with **licence, source, digest and size pinned**, plus the "reference voice" that the per-voice gate compares against. Note the requirement is **voice count for a speaker-variation proxy**; it does **not** close real regional accent, which is GAP-2 again |

**GAP-3's concrete voice-bank requirement (count, varieties, licence, provenance).** The review found the design's "no `*.onnx` exists anywhere in the tree" to be **out of date at this base**, which materially improves the acquisition story:

| Voice | Variety / type | Licence (as recorded in-repo) | Provenance pin |
|---|---|---|---|
| `ne_NP-google-medium` (int8) | **Nepali**, standard read speech (OpenSLR SLR43) | **CC BY-SA 4.0** — use with attribution + share-alike | Already bundled in the app (`ios/ElderlyAssistant/Resources/Models/tts/ne_NP-google-medium-int8/`, with `MODEL_CARD`, `.onnx.json`, `tokens.txt`, `espeak-ng-data/`); fetched by `tools/fetch-tts-voices.sh:28` (**sha256 currently empty** — legacy tier, not verified) |
| `ne_NP-chitwan-medium` (int8) | **Nepali**, second source/dataset (`OHF-Voice/voice-datasets`) | **CC0** | **Already digest-pinned**: `tools/fetch-tts-voices.sh:30` carries sha256 prefix `deb1592e`… and size 21,165,758 B, REQUIRED-VERIFY at fetch time (`ModelCatalog.piperNepaliChitwan`) |
| `hi_IN-pratham-medium` (today's round-trip voice) | **Hindi** — non-native rendering of Nepali text | recorded for the training box only | `config.yaml:23` |

Evidence for the licence/variety rows: `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md:215-216`, `:227` (which records the same two voices as licence-clean and calls the CC0 one "the enabling condition for the accent axis TG-11's GAP-3 leaves open"); `tools/fetch-tts-voices.sh:27-31`; `docs/research-sections/accent-adaptation.md:187`; `docs/nepali-model-finetuning-guide.md:19`, `:159`.

**Two caveats the acquisition must carry, not paper over:**

1. **Both Nepali voices are *standard* read speech.** Neither is Eastern nor Doteli. Adding them makes the accent gate *non-vacuous as a speaker-variation measurement* and still **not** a regional-accent measurement (Part F). That is the design's §7.5 position, unchanged — only the "obtainable" line moves.
2. **Format and licence gates.** The two in-tree assets are **sherpa-onnx int8 layouts** (`model.onnx` + `tokens.txt` + `espeak-ng-data/`), built for the iOS TTS engine — the round trip needs a **piper-CLI-loadable** `.onnx` **with its `.onnx.json`** (the rhasspy/piper-voices layout, which is where `piper --model` reads its defaults). And piper's phonemization uses **espeak-ng (GPL)** — the gate already recorded in the project (`accent-adaptation.md:572`, TTS-engine notes) applies to any server-side use of these voices.**Required count: ≥2 Nepali voices (3 desirable, so the gate can hold one reference and score two); varieties: standard Nepali read speech, ≥2 independent sources; licence: CC0 preferred, CC BY-SA acceptable with attribution/share-alike recorded in the model catalogue; provenance: sha256 + byte size pinned in the fetch script and the catalogue entry, verified at fetch time (the chitwan pattern, which google-medium should be backfilled into).**

---

## Part F — The accent half, answered honestly

**The starting point is confirmed at the line level.** The round trip is `text → piper TTS → audio → the bundled Whisper → noisy text` (`stt_noise.py:1-17`, `annotation_rules.yaml:267-273`); `synthesize` passes only `--model`/`--output_file` (`stt_noise.py:49`); the voice is **Hindi**, chosen as nearest-to-Nepali (`config.yaml:23`); `variants_per_utterance: 2` (`:28`, `stt_noise.py:133`).

**Determinations:**

1. **Is the resulting STT error profile worth calling an accent-robustness approximation at all?** **No — not an approximation of accent.** It is worth having and worth measuring as what it is: an **error profile induced by a non-native rendering** (a Hindi voice reading Nepali text), which exercises mispronunciation, script drift and lexical substitution. Accent is a property of *speakers*; this pass has no speaker, no region and no accent variable. The honest label is the E.4 string. Calling it accent robustness would be the R-12 proxy-as-thing failure.
2. **Is speaker-level conditioning available without real recordings?** **A multi-voice interface is a *speaker-variation proxy*, even when the bank is populated — and never regional accent.** Two synthetic Nepali voices differ in timbre and prosody, not in region; a synthetic voice is not a person from Eastern or Terai Nepal (design §7.5, confirmed). The genuinely accent-robust path is real regional speech → FR-005 / GAP-2.
3. **What is the voice-bank requirement?** E.5 (GAP-3): count, varieties, licence, provenance — stated as an acquisition with named, licence-checked assets and the two caveats.
4. **No claim of accent coverage rests on the noise pass.** Nothing in this review, and nothing the review permits a later document to write, ties accent coverage to it. The `accent_voices` gate stays **unwired** and rendered as GAP-3 until a bank exists (design §7.7: an unwired gate is never rendered green).

**FR-005 boundary (recorded so a later reader does not mistake this review for the whole of FR-005).** FR-005 (`requirements.md:29-31`) is *accent and regional dialect personalisation, on-device*. This review covers only the **corpus and evaluation** half: which dialect labels the annotation rules carry, which slices may be claimed, and what the degradation/accent fixtures may be called. The **personalisation** half — enrolment voice samples, on-device adaptation, per-user pack selection, the enrolment flow that would make the label non-inert — is a **runtime feature** (TG-02/TG-09 territory, `plan.md` risk 35) and is **not touched here**. A reader who wants the whole of FR-005 must read that work too; this document neither delivers nor blocks it.

---

## Part G — Native-speaker review pack

### G.1 Protocol

- **Input:** the question list below and the candidate strings in `specs/T-062-dialect-banks.yaml`, nothing else. No audio is played and none is recorded.
- **Reviewer:** one native Nepali speaker, ideally with exposure to more than one region. If more than one reviewer is available, record answers **per reviewer** — disagreement is a finding, not a tie to break.
- **Answer vocabulary, per candidate:** `yes_region_marked` (I would say it, and it marks a region) · `yes_common` (I would say it, but it is not regional) · `yes_other_region` (it belongs to a different region than filed) · `no` (I would not say it) · `unconfirmed` (I cannot say). **"Unconfirmed" is a legitimate and expected answer**; a slice's claim narrows accordingly, and inferring an answer is a defect (task DoD).
- **Self-reported usage only.** No recording, no transcript of the reviewer's own speech, no personal data written down. A reviewer's *judgements* are not personal data; a reviewer's *recording* would be, and it is out of scope (NFR-015).
- **Sign-off artefact:** the answered YAML (`specs/T-062-dialect-banks.yaml` with each `unconfirmed` resolved) is what T-063 consumes; this document's determinations stand unchanged except where an answer overturns one, in which case the change is recorded here as a dated amendment.

### G.2 The questions (each names the decision it gates)

| # | Question (ask in Nepali) | Candidate material to show | Decision it gates |
|---|---|---|---|
| **N1** | Is the far-west (Doteli) way of speaking a *dialect of Nepali* or a *separate language* to you? Would a Doteli speaker be poorly served by standard Nepali? | — | `doteli` filed as language-level (C.2) vs dialect-level; whether any `western` label is needed |
| **N2** | Do you notice a difference between "Eastern" and "Central" Nepali in everyday speech, and in which words? | — | Whether `central` is a real slice (currently dropped). **Expected answer is "no consequence for these words"** |
| **N3** | In the Terai, is the Nepali spoken there its own variety of Nepali, or is it Maithili/Bhojpuri/Awadhi with Nepali as a second language? Would you call it a dialect of Nepali? | — | Confirms the `terai` drop (C.3) |
| **N4** | For each of these, is there a **regionally-marked** alternative you would actually use for a family member? | `आमा, बुबा, दिदी, दाइ, बहिनी, भाइ, छोरा, छोरी, नाति, नातिनी, बुहारी, ज्वाइँ` and candidates `बा, अम्मा, दी, भाई` | Whether CONTACTS carries dialect variants at all |
| **N5** | Which of these are just spelling/quick-speech differences (everyone) and which actually mark a region? | `दिउँसो/दिउसो`, `बेलुका/बेल्का`, `साँझ/साझ`, `राति/रात`, `भोलि/भोली`, `गर्नुहोस्/गर्नुस्` | Files each into **pan-regional spelling** vs a dialect slice vs the **STT/articulation** axis (C.4). This is the single most decision-relevant answer for the `eastern` bank's content |
| **N6** | Is `दवाई` a regional form or an everyday synonym everyone uses beside `औषधि`? Is `औषधी` a spelling variant? | `औषधि, दवाई, औषधी, प्रेसरको औषधि, सुगरको गोली` | Whether MEDS carries dialect variants (expected: no) |
| **N7** | Is there a regionally-marked form of any of these? | `फोन, भिडियो कल, वाट्सएप, ह्वाट्सएप, फेसटाइम, भाइबर, मेसेन्जर` | Confirms METHODS is dialect-invariant (expected: yes, invariant) |
| **N8** | Would you actually say a first-person medicine-acknowledgement in an eastern/Doteli form? Which? | `खाएँ, खाइसकें, लिएँ, खाएको छु` vs candidates `खाइछु, खाएँ नि` | Whether the ack_med family has dialect variants — **note the structural finding**: the attested eastern `-इछ` perfective is third-person and does not fit a first-person ack (C.4) |
| **N9** | Which of these differences is *politeness* and which is *region*? | `गर, गर्नुहोस्, गरिदिनुहोस्, सम्झाउनु, सम्झाइदिनु, हजुर` | Splits `style.honorific` (politeness) from dialect (region) |
| **N10** | Would you say `गइछ / भइछ / खाइछ`? In which person, and in which region? | `गइछ, भइछ, खाइछ` (vs `गएछ, भएछ, खाएछ`) | Whether the SEED-LEXICON eastern marker enters any bank, and at which person |
| **N11** | Would you say `भया / रह्याको / भण्याको`? Are they Doteli specifically, or also used in Western/Karnali speech? | `भया, रह्याको, भण्याको` (vs `भयो, रहेको, भनेको`) | Confirms the `doteli` filing, and re-checks the Far-Western determination **on the actual fixture strings** (N1's abstract answer is not enough) |
| **N12** | Do elders you know speak like the clipped examples (content words only, tail dropped)? Would a listener still understand? | `औषधि… बिहान`, `भोलि… डाक्टर` | Whether `style.clipped` is a real elder-speech style (gate wording depends on it, the gate itself does not) |
| **N13** | Would a Maithili/Bhojpuri speaker mix those languages' function words into Nepali the way the code-switched rows mix English? | one `code_switched` row | Confirms the `mixed_code` drop (C.6) and the OQ-5 answer |
| **N14** | Would you describe the slowed/perturbed synthetic speech as "reduced articulation"? Does it sound like an older speaker to you? | (played by T-066, not by this review) | Wording only (E.4); gates nothing |

**Fixture candidates needing human judgement are exactly the strings in the last two columns of the table above and in `specs/T-062-dialect-banks.yaml`** — no candidate exists outside those lists, and no candidate is asserted into a slice before an answer.

---

## Part H — What data is missing (the acquisition list)

| Gap | Data needed | Closes |
|---|---|---|
| **GAP-1** | Licensed noise corpus, per-scene labels (babble/TV/market/street/room/telephone), mixing policy per scene × SNR, declared mixing domain | Real-world noise dimension; moves the noise gate beyond white noise |
| **GAP-2** | Consented recordings of the target population (elderly + regional), privacy basis compatible with FR-005, acquisition protocol, retention/deletion policy | Real elder/slurred speech; the genuine accent axis |
| **GAP-3** | ≥2 (ideally 3) Nepali piper voices, **piper-CLI format** (`.onnx` + `.onnx.json`), licences recorded (CC0 preferred; CC BY-SA acceptable with attribution/share-alike), digest + size pinned and verified at fetch; espeak-GPL gate cleared for server use | Multi-voice speaker-variation gate §7.5; makes GAP-3 *conditionally closable* — but **not** regional accent (GAP-2) |
| **GAP-4** | T-063's axis amendment + T-064's authored twin pairs (≥300 per claimed slice) | The dialect gate's existence |
| **GAP-5 (new, this review)** | Attested **Terai-accented Nepali** speech (L2 speakers of Maithili/Bhojpuri/Awadhi/Tharu speaking Nepali), and any attested within-Nepali contact mixing — with native-speaker validation | The dropped `terai` slice and `mixed_code` style. **Not** authorable from the current corpus, and not a `dialect` value even if data later arrives |

---

## Part I — Deliverables

1. **This determination record** (`specs/T-062-notes.md`).
2. **The structured banks** — [`specs/T-062-dialect-banks.yaml`](T-062-dialect-banks.yaml): a `dialects:` block (value set, per-slice status + `claim_wording`, per-slice variant banks with `kind: orthographic|lexical|morphophonemic`, `model_impact: known_word|new_word|unknown`, `status: confirmed|unconfirmed`, and the question id that resolves each), a `pan_regional_orthographic:` table (spelling drift that is **not** dialect evidence), an `unclaimed:` list with the forbidden claims, and a `degradation:` block carrying the naming contract (E.4) and the cell/level rules (E.1, E.3) as **fields**, so T-069 renders one string rather than transcribing prose (per `specs/TG-11-notes.md`).
3. **Transcription:** the decisions above are for the TG-11 group to transcribe into `specs/TG-11-notes.md` (task deliverable note); this file is the source record.

---

## Part J — Data discipline and compliance (task DoD)

- **No audio was recorded. No real transcript was collected. No consent-bearing data was created.** Every argument rests on the reviewer's (pending) linguistic judgement, the published sources cited in Part B, and the product's existing **synthetic** entity banks (`golden_corpus_batches.py:236-690`) — the NFR-015 / design §8–§12 discipline, honoured by construction.
- **No PII, no secret, no full 40-character hash** appears anywhere in this deliverable or its companion file (NFR-016). Every digest is an 8-character prefix (`deb1592e`, fixture tags), matching the project's existing convention.
- **No file outside `specs/` was written.** `eval/golden_corpus.jsonl`, `annotation_rules.yaml`, `config.yaml`, the Swift sources and the bundled JSON resources were **read, never modified** — verified in this worktree.

---

## Verification performed

- **Every engine claim was read, not recalled.** `DialectIdentifier.swift`, `DialectBiasComposer.swift`, `DialectCentroids.json`, `DialectLexicon.json`, `WhisperKitSpeechRecognizer.swift:762/864`, `annotation_rules.yaml`, `config.yaml`, `build_dataset.py:77-82`, `stt_noise.py:33-50/54-95/133/138`, `tools/train/src/dataset.py:32-43`, `encoder_contract.yaml:30-34`, `golden_corpus_batches.py:117-118/240/251/444/481-488/609-672`, `fetch-tts-voices.sh:27-31` — each cited line was opened in this worktree before being written.
- **Corpus claims are measured, not asserted.** 8,000 rows; `dialect`/`style`-tagged rows = **0**; scripts 5,508/1,678/814; all **800** `query` rows span-less (script run in this worktree, output quoted in A.2).
- **`Terai` audit.** A tracked-tree search finds "Terai"/"तराई" **only** in planning and design documents (`plan.md:97`, the design doc, the task files, TG-12 docs) and **never** in a Swift source, a resource JSON, a Python module or a YAML config. The shipped vocabulary is `eastern | doteli | default` — the four-region hypothesis exists only in prose, which is why this review could reject parts of it without touching code.
- **`applyDialectLabel` audit.** Its only definition is `WhisperKitSpeechRecognizer.swift:864`; a tracked-tree search finds **no production caller** — consistent with `plan.md:109` risk 35 and `specs/TG-12-notes.md:46`.
- **Piper claim sourced, not recalled.** Flag names and semantics were taken from piper's own CLI documentation (archived `rhasspy/piper` C++ CLI vs `piper1-gpl` Python CLI) rather than from memory; the version-dependence is stated as a finding precisely because the installed version is **not pinned in the repo** (checked: no piper entry in `tools/train/requirements.txt`, no lockfile, no vendored binary).
- **No build, training run, GPU job, simulator or model fetch was run** — out of scope for this task, and the constraint was explicit.

### Sources (Part B / E.5 / G external references)

- Nepali dialect division Western/Central/Eastern (Bandhu 1968–69), feature lists and the Tarai exclusion — [Nepali language, dialectology](https://en.wikipedia.org/wiki/Nepali_language)
- Doteli: ISO 639-3 `dty`, Glottolog `doty1234`, ~790,000 speakers (2011 census), four dialects, 2012 Ethnologue recognition, constitutional status — [Doteli language](https://en.wikipedia.org/wiki/Doteli_language), [ISO 639 dty](https://en.wikipedia.org/wiki/ISO_639:dty)
- Terai/Madhesh languages and 2021 census figures; Nepali as L2; Language Commission recommendations — [Languages of Nepal](https://en.wikipedia.org/wiki/Languages_of_Nepal)
- Piper CLI options (`--length_scale`/`--noise_scale`/`--noise_w` semantics; `piper1-gpl` spelling) — [piper1-gpl CLI reference](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/CLI.md), [piper-tts manual](https://linuxcommandlibrary.com/man/piper-tts)
- Nepali piper voices and licences — [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices); in-repo evidence at `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md:215-216` and `tools/fetch-tts-voices.sh:27-31`
- Noise-corpus candidate class and licensing (MUSAN, OpenSLR SLR17, CC BY 4.0) — [OpenSLR 17](https://openslr.org/17/), [MUSAN corpus](https://www.emergentmind.com/papers/1510.08484)
