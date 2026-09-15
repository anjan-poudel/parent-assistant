# T-062: Nepali Dialect, Degradation & Accent Inventory Review (R&D)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** A validation review, not code: the proposed `dialect` value set, the per-dialect orthographic and lexical variant banks, the style set, the claimable-slice determination that [T-063](T-063-annotation-rules-amendment.md) then encodes in `annotation_rules.yaml`, and the degradation taxonomy (SNR ladder, articulation cells, what each may be called) that [T-066](T-066-accent-noise-pass-extension.md) implements
- **Agent:** ba (with a native-speaker reviewer; no ML work)
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-063](T-063-annotation-rules-amendment.md), [T-066](T-066-accent-noise-pass-extension.md)
- **Requirements:** FR-005, FR-003
- **Origin:** The dialect/accent/style requirement (Nepali is SOV; the user contrasts it with English SVO); `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §5 (the axes and the accent limit), §7.3–§7.5 (the degradation taxonomy and the gates it feeds), §7.8 (the gap register this review populates)

## Description

The design proposes a five-value `dialect` axis (`standard`, `eastern`, `central`, `western`, `terai`) and a four-value `style` axis (`neutral`, `clipped`, `honorific`, `mixed_code`). Both are written as a **working hypothesis**, and this task is where a Nepali speaker either confirms, narrows or rejects them. An engineering team must not ship a dialect atlas it invented in a design document; the value set, the variant banks and the coverage claim all come out of this review.

Five determinations, each with a written rationale:

1. **The value set.** Is Far-Western distinct enough from Western to be its own slice, or does collapsing them lose a real difference? Is the Terai belt one slice or several — the plains are a Maithili/Bhojpuri/Awadhi contact zone, and treating three language communities as one dialect of Nepali may be wrong in a way that a single "terai" label would bake in. Conversely, is a distinction the design drew (e.g. eastern vs central) one speakers actually recognise, or a geographic label with no lexical consequence for this product's vocabulary?

2. **The per-slice variant banks.** For each slice that survives determination 1: the orthographic variants (how the same word is typically written), the lexical variants (a genuinely different word for the same thing), and the morphophonemic variants that appear in the product's closed vocabulary — the entity banks the authoring path already uses (`golden_corpus_batches.py` CONTACTS / METHODS / TIMES / MEDS / QUERY_* banks, and the actions: call, remind, message, medication ack, emergency, guide, music, video, query). The review works over that vocabulary, not over the whole language, because that is what the corpus and the runtime actually have to recognise.

3. **Whether `style` is orthogonal to `register` as designed.** The design proposes `style ∈ {clipped, honorific, mixed_code}` as metadata beside the existing `register` rather than as new register values, because `register` selects the mixture bucket (`build_dataset.py:77-82`) and new values would change the 60/25/15 arithmetic. This task confirms the separation is real for the Nepali cases: is clipped elder speech a *style* dimension, or is it already what `elder_fragmented` means — in which case the value is redundant and should be dropped rather than duplicated. The same question applies to `mixed_code` against the existing `code_switched` register, and specifically whether within-Nepali mixing with a Terai language is the same phenomenon as Nepali–English switching or a different one that needs its own value (design OQ-5).

4. **The claimable-slice list.** The dialect gate is per-slice and evidence-bound: a slice is claimed only if [T-064](T-064-order-dialect-authoring.md) can author at least 300 matched twin pairs for it (design §7.2). The review names which slices are claimed, which are explicitly unclaimed, and what the product may and may not say about each. Words like "supports Eastern Nepali" must not survive the review unqualified if no bank was validated.

5. **The degradation taxonomy, including the slur class.** The design proposes a noise ladder {15, 10, 5, 3} dB for [T-066](T-066-accent-noise-pass-extension.md) to generate and the `noise_snr` gate to measure, plus two articulation cells (moderate: rate within ±20% of nominal, mild quality perturbation, SNR 10 dB; severe: rate ±40%, stronger perturbation, SNR 5 dB). The review rules on whether this taxonomy corresponds to variation a Nepali listener would recognise in elder speech, and specifically:
   - **Which parameters are real.** Whether piper's `length_scale`/`noise_scale`/`noise_w` map onto anything worth calling slowed or effortful articulation, and which of them the reviewer expects to change the STT transcript at all — a cell that produces no transcript change measures nothing and should be dropped rather than gated.
   - **The ladder's endpoints.** Whether the top level (15 dB) is a realistic mild room and the bottom (3 dB) is a plausible worst case for this product's deployment, or whether an endpoint should move. The design takes the band from the existing augmentation (`dataset.py:42-43`) because gating outside the band the project trains on measures the fixture rather than the model — if the review disagrees, that is a finding for the design, not a silent re-tune.
   - **What each class may be called.** The design's rule is that the articulation grid is a **proxy** for reduced articulation and never a dysarthria or slurred-speech result, and that the noise dimension covers **stationary additive white noise only** and never babble or room noise (GAP-1). The review confirms or corrects those names, and its answer is what appears in the harness output, the manifest and the evidence pack.
   - **The determinable gaps.** Which dimensions are shut on the current corpus and what data would open each: no real-world noise source (GAP-1, needs a licensed labelled noise corpus), no real slurred or elder speech (GAP-2, needs consented recordings and a privacy basis — explicitly not commissioned here), no Nepali voices (GAP-3, needs ≥2 licensed Nepali-capable piper voices pinned by digest).

**The accent half, answered honestly.** The design's §5.5 finding stands as the review's starting point: the noise pass is piper TTS → the bundled Whisper, the shipped voice is a **Hindi** voice chosen as nearest-to-Nepali (`config.yaml` `stt_noise.tts_voice`), and `synthesize` (`stt_noise.py:30-48`) passes only `--model` and `--output_file` — so it produces an STT-error profile, not accent modelling. This task confirms the review position on: whether the resulting STT error profile is worth calling an accent-robustness approximation at all; whether any speaker-level conditioning is available without real recordings (the multi-voice interface is a **speaker-variation proxy** even when the bank is populated, and never regional accent); and what the voice-bank requirement is in concrete terms — how many voices, which language varieties, what licence and provenance — so GAP-3 names an acquisition and not a wish. It does **not** commission recordings.

**Data discipline.** The review is a text-and-rules review. No audio is recorded from any person, and no real transcript is collected: this task must not create consent-bearing data, and the fixtures that follow it stay synthetic over the existing entity banks (NFR-015). A reviewer's own linguistic judgements are not personal data; a reviewer's recording would be, and it is out of scope.

## Acceptance criteria

```gherkin
Feature: Nepali dialect and accent inventory review

  Scenario: The dialect value set is validated or corrected by a Nepali speaker
    Given the design's working hypothesis: standard, eastern, central, western, terai (design §5.2)
    When the review is conducted
    Then each proposed value is kept, narrowed, split or dropped with a written rationale, and the Far-Western question and the Terai one-slice-or-several question are each answered explicitly
    And the review records whether the surviving distinctions have lexical or orthographic consequence for this product's vocabulary, or are geographic labels with no consequence for the entity banks

  Scenario: The variant banks are supplied per claimable slice
    Given the closed vocabulary the product must recognise: the CONTACTS / METHODS / TIMES / MEDS / QUERY_* entity banks and the taxonomy actions (annotation_rules.yaml:31-43)
    When the variant banks are written
    Then each claimed slice has orthographic variants and lexical variants over that vocabulary, plus the morphophonemic variants that appear in it
    And each variant entry states whether it is a spelling of a word the model already knows or a genuinely different word form, because the two have different expected model impact (design §5.3)
    And no variant is asserted as belonging to a slice on the basis of geography alone where the reviewer could not confirm speaker usage

  Scenario: The style axis is confirmed orthogonal to register, or corrected
    Given the existing registers devanagari, romanized, code_switched, elder_fragmented (annotation_rules.yaml:216) and register_to_bucket (:210)
    And the design's rule that register stays untouched because it selects the mixture bucket (build_dataset.py:77-82)
    When the style values neutral, clipped, honorific, mixed_code are reviewed
    Then for each value the review states whether it is a distinct dimension, whether it duplicates an existing register (clipped vs elder_fragmented; mixed_code vs code_switched), and whether within-Nepali Terai mixing needs its own value
    And if a new register is found to be genuinely required, the review says so explicitly and flags that the mixture arithmetic (annotation_rules.yaml:210-216) must then be revisited as a separate decision rather than changed silently

  Scenario: The claimable-slice list is fixed and the claim is evidence-bound
    Given that a dialect slice is gated only where at least 300 matched twin pairs can be authored (design §7.2)
    When the review closes
    Then it names the claimed slices, the explicitly unclaimed slices, and what the product may and may not say about each
    And it states that no claim of accent coverage rests on the noise pass, and what the noise pass is and is not permitted to be called in any user-facing or internal document (design §5.5)

  Scenario: The degradation taxonomy is ruled on and each class is named honestly
    Given the proposed noise ladder 15/10/5/3 dB anchored to the existing augmentation band (dataset.py:42-43)
    And the proposed articulation cells: moderate (rate within ±20% of nominal, mild quality perturbation, SNR 10 dB) and severe (rate ±40%, stronger perturbation, SNR 5 dB)
    When the review is conducted
    Then it rules on whether the ladder's endpoints are realistic for this product's deployment, and whether each proposed articulation cell corresponds to variation a Nepali listener would recognise in elder speech or produces no transcript change at all
    And it confirms or corrects the required names: the articulation grid is a proxy for reduced articulation and never a dysarthria or slurred-speech result, and the noise dimension covers stationary additive white noise only and never babble or room noise
    And it records, per dimension, what is unmeasurable on the current corpus and the data that would open it, so GAP-1 (real-world noise), GAP-2 (real slurred or elder speech) and GAP-3 (Nepali voices) each name an acquisition rather than a wish
    And the voice-bank requirement is stated concretely: how many voices, which language varieties, what licence and how provenance is pinned

  Scenario: The review creates no consent-bearing data
    Given NFR-015 and the fixture discipline in the design (§8, §12)
    When the review is conducted
    Then no audio is recorded and no real transcript is collected, and every argument rests on the reviewer's linguistic judgement and the product's existing synthetic vocabulary banks
```

## Implementation notes

- Read before reviewing: `tools/train-intent/annotation_rules.yaml:207-216` (buckets and registers), `:217-232` (caps and floors), `:267-273` (the noise pass); `tools/train-intent/src/build_dataset.py:77-82` (`BUCKET_OF_REGISTER` — why register is load-bearing); `tools/train-intent/config.yaml` `stt_noise` block (`tts_voice` is the Hindi voice, `variants_per_utterance: 2`) and `tools/train-intent/src/stt_noise.py:30-48` (only `--model`/`--output_file` are passed today), `:50-63` (the whisper.cpp transcriber), `:65-95` (`make_hf_transcriber`, the path that exposes mel features), `:121-122`; `tools/train/src/dataset.py:23-44` (`torch.randn_like` white noise, uniform 3–15 dB — the only noise the project has, and the band the ladder is anchored to); `encoder_contract.yaml:27-34` (the 250k sentencepiece vocabulary the "known word" vs "new word" distinction turns on); `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §5, §6, §7.3–§7.5 and §7.8.
- On the piper knobs: establish from the shipped model and the tool's own CLI which of `length_scale`, `noise_scale` and `noise_w` the installed version actually accepts and what each does to rate and prosody, rather than from recall. A parameter the tool ignores would make a declared cell a no-op that still reports a pass.
- The reviewer's ruling on naming is load-bearing for the evidence pack: what the review permits the articulation and noise dimensions to be called is exactly the label field [T-069](T-069-evidence-pack-gap-register.md) renders, so the answer must be a statement a document can quote, not a discussion.
- The "known word vs new word" judgement in the second scenario is the single most decision-relevant output for the model-size question: a variant sharing most subwords with a standard form is absorbable by a 117M encoder; a word the tokenizer fragments into rare pieces is not, without training mass (design §6). Where the reviewer cannot tell, the entry is marked unknown and [T-061](T-061-order-robustness-baseline.md)-style measurement decides, not guesswork.
- Keep the output machine-consumable: the banks should land as a small structured file (a `dialects:` block designed here, landed in `annotation_rules.yaml` by [T-063](T-063-annotation-rules-amendment.md)) so authoring and evaluation read one artifact rather than prose.
- The review must not invent per-slice verb paradigms from memory. If the reviewer cannot confirm a form, the entry is `unconfirmed` and the slice's claim narrows accordingly — an `unconfirmed` entry is a legitimate result, and a fabricated one is a defect that [T-068](T-068-pinned-corpus-no-disturbance.md)'s resolve-through check on authored rows will expose downstream.
- Deliverable is a determination record plus the structured banks; the decisions are transcribed into `specs/TG-11-notes.md` by the group.
- FR-005 boundary: the accent *personalisation* half (onboarding voice samples, on-device fine-tuning) is a runtime feature and is not touched here. Record the boundary so a later reader does not read this review as the whole of FR-005.

## Definition of done
- [ ] Every proposed `dialect` value kept, narrowed, split or dropped with a written rationale, including explicit answers on Far-Western and on Terai one-slice-or-several
- [ ] Variant banks supplied per claimable slice over the product's closed vocabulary, each entry marked new-spelling versus new-word, `unconfirmed` where the reviewer cannot confirm
- [ ] The `style` axis confirmed orthogonal to `register`, or corrected, with the `clipped`/`elder_fragmented` and `mixed_code`/`code_switched` overlaps answered and any genuinely new register flagged for a mixture-arithmetic decision
- [ ] Claimable-slice list fixed: claimed slices, unclaimed slices, and what the product may and may not say about each
- [ ] Degradation taxonomy ruled on: ladder endpoints, each articulation cell's realism, and which cells produce no transcript change and should be dropped rather than gated
- [ ] Naming confirmed or corrected: articulation is a proxy and never dysarthria or slurred-speech; noise is stationary additive white noise and never babble or room noise
- [ ] GAP-1, GAP-2 and GAP-3 each carry what is unmeasurable, why with its citation, and the data needed; the voice-bank requirement states count, varieties, licence and provenance-pinning
- [ ] No claim of accent coverage rests on the noise pass; the permitted vocabulary for internal and user-facing documents is stated
- [ ] Structured banks delivered as data (a `dialects:` block shape for T-063), not prose
- [ ] No audio recorded, no real transcript collected, no consent-bearing data created
- [ ] Decisions transcribed into `specs/TG-11-notes.md`; the FR-005 personalisation boundary recorded
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
