# Semantic correction layer (correction-revive + calibration campaign)

**Date:** 2026-10-12 · **Status:** shipped in part (PR #162, merged `0d9e256`); calibration campaign in flight
**Owner demand:** "a Nepali keyboard autocorrects better than what I am seeing" — correction must use lexicographical AND semantic signals, and Pip must clarify via multi-turn when unsure.

## Endorsed architecture (two-pass, owner-specified)

```
STT → Autocorrector (lexical pass, word-at-a-time) → LLM corrector (whole-sentence context per word) → corrected text
```

Safety invariants unchanged throughout: corrected text feeds ONLY the intent models; the keyword safety net / emergency / med-ack read the ORIGINAL transcript (`IntentTranscriptPair.safetyNetInput`, re-route `safetyNetText`); frozen-set vetoes run LAST on every silent and judge-accepted correction; egress stays count-only.

## What shipped (PR #162)

- **Default-ON corrector** — `STTCorrector.Policy.runtime` reads an absent toggle as the apply arm (`isCorrectorToggleSet` distinguishes a written false = user pin-off). Voice-settings switch `voiceSettings.correction.*`.
- **Banded gate** — silent apply stays byte-identical to the v3 measured operating point; below it, judge-eligible tokens carry their top readings (`CorrectionResult.judgeItems`) — never applied silently.
- **Clarification** — `ProbeKind.correctionChoice`: honest Nepali question with numbered readings, index-word/echo capture, splice + re-route with the safety net on the original; one question per turn.
- **Pluggable judge** — `SemanticJudge` protocol + `LlamaSemanticJudge` (resident-4B only; never loads a second model — the VOICE-OOM invariant), grammar-constrained batched pick, 1.5 s cap, `STTCorrector.reRank` with vetoes-last.
- **Pipeline** — `tools/train-intent/src/stt_ngram_prior.py` (CPU-only): expanded lexicon + bigram/trigram priors + SymSpell symmetric-delete index + pinned bands; bank `stt-ngram-prior.json`.

## The calibration campaign (what the corpus said)

The corpus: `data/noised.jsonl` carries `clean_utterance` beside every noised row — **29,304 real (noised → clean) utterance pairs** from the shipped noise injector, plus a Wikipedia-Nepali expansion (97k clean lines).

Measured (2026-10-12, all numbers over correctly character-aligned error instances):

| Ranker | Top-1 exact |
|---|---|
| Surface scorer (edit/prefix/phonetic + weak ngram prior) | **2.1%** (below chance in its own pool) |
| Sentence-LM ranking (bigram product over the 57k bank) | **17.3%** |
| **4B brain as judge** (choice mode, readings reachable) | **79.5%** |
| 4B brain as judge (propose mode, few-shot) | **0.5%** — echoes; the intent fine-tune was never trained to generate corrections |

Consequences, each a recorded decision:
1. **No threshold re-fit can save the lexicographical scorer** — its rankings are worse than random on the real error stream. The v3 gate's recall 0.0005 was the mechanism's honest capability.
2. **Pool coverage is the binding constraint on the choice path** — real errors sit 3–8 edits from the true word (plus Latin↔Devanagari drift and merges), so bounded-edit generation reaches ~0.1% of them; tier-balanced caps (prefix 6 / edit 8 / key 6 / symspell 8) fixed prefix-flooding but not the distance bound.
3. **The LLM corrector must be a purpose-trained model** — the 4B cannot serve that layer, and the sentence-LM ranking alone is not keyboard-grade.

## Shipped defects found and fixed during the campaign

- **Bank separator mismatch (PR #162, shipped broken)**: the pipeline wrote `||`-joined ngram keys; the Swift loader looks up with `\u{1}` — the priors silently zeroed on device. Pipeline now emits `\u{1}` and the invariant REFUSES any `||` key.
- **SymSpell key case**: pipeline emits `symspell` (lowercase); the Swift field is `symSpell` — pinned via `RawNgramPrior.CodingKeys`.
- **Pool prefix-flood**: one global cap let prefix completions starve the edit/key tiers (the true word never reached the judge's input). Fixed with per-tier caps in Swift and Python.

## What is on Anzaan now (2026-10-12 device build)

Judge-pre-interpret wiring (`LocalBrainChain.semanticJudge` — the 4B re-ranks BEFORE interpretation), tier-balanced pool, 57,009-word bank (`correction-banks/v4#103272ee`, corpus `24c4b040a15e6280`), judge band widened to `judgeMin 0.25` (conversational band — precision-safe by construction; the `bajan`/`bhajan` field-report fix). DV items: bhajan silent fix, correction question, emergency untouchable.

## In flight: the propose model (keyboard-grade pass 2)

- Dataset: `stt_correction_dataset.py` — propose form (sentence + marked token → true word), 30,435 correctly-paired rows.
- Trainer: `stt_train_correction_judge.py` — BERT-small (6L/384) masked-span fill over a 16k BPE (`<mask>`/`<eow>` symbols), GPU on the 3090.
- **Attempt 1 verdict: valid exact 0.3%** — below bar. Iteration 2 scoped: autoregressive decode head, init from the repo's Nepali-pretrained MiniLM (T-036), error-corpus augmentation via the existing injector.

## Worktrees and gate

- `correction-revive` (branch `worktree-correction-revive`) — merged PR #162.
- `correction-calibrate` (branch `worktree-correction-calibrate`) — judge-pre-interpret + pool caps + bank v2; scoped gates green (161/161 DialectIdentifierTests + judge/dialogue/sanitiser suites; `LocalBrainChainJudgeTests`).

## Server state notes

anjan-ubuntu (192.168.1.117): GPU clean after two cold boots (`595.99.02`, torch CUDA verified); corpus and calibration artifacts live under `tools/train-intent/build/` (never `/tmp` — it clears on reboot); `reload-gpu.sh` must never be run over ssh (it wedges the box).
