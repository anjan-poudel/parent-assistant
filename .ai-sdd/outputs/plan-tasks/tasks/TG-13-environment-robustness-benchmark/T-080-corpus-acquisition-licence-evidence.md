# T-080: Noise/RIR Corpus Acquisition & Licence Evidence (R&D)

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/env/corpora.jsonl` (new: the pinned source manifest), `tools/train-intent/eval/env/MANIFEST.md` (new: licence evidence), downloads staged outside the repo (the corpora are gigabytes and are not committed)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-081](T-081-condition-matrix-protocol-design.md), [T-082](T-082-acoustic-transport-harness.md)
- **Requirements:** NFR-015, NFR-016, NFR-030
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §4 (data sources) and §5 (licence table); the gaps it inherits are TG-11's GAP-1 (babble/real-environment noise) and GAP-2 (telephone channel) — `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §7.3, §7.4

## Description

Acquire and *verify* the noise and room-impulse-response material the benchmark's condition matrix needs, and produce the licence evidence that decides whether each source may be used at all. This is the group's entry gate: a corpus whose licence does not permit the intended use is not a slow path, it is a cell that does not exist, so the matrix in [T-081](T-081-condition-matrix-protocol-design.md) cannot be finalised first.

**Two distinct uses, and they have different licence bars.** The manifest must record the distinction per corpus, because conflating them is the classic error:

1. **Use (a) — measurement input.** The corpus is downloaded at build time, mixed with synthesized speech, decoded, and *not* re-hosted. This is the benchmark's normal case and the least restrictive: it needs no redistribution right.
2. **Use (b) — committed derivative.** A small, fixed sample (e.g. a 10-second noise excerpt or one impulse response) is committed to the repository so the CI tier is reproducible without a multi-gigabyte download. This is redistribution, and **it needs the corpus licence to permit it.** If it does not, the CI tier downloads the source instead (with the digest pin) and the tier reports `SKIPPED — corpus absent` rather than silently scoring a different fixture.

**What to produce.** For every candidate source: the canonical URL, the exact licence string as the maintainer states it (verbatim, one line), whether commercial use is permitted, whether redistribution of derivatives is permitted, the access requirement (direct / registration / signed agreement), the size in hours, and the pin (sha256 of the downloaded archive, and the file list for a multi-file corpus). Then a verdict per source per use — `USE (a)`, `USE (a+b)`, or **`NOT USABLE`** with the reason — in the style TG-08's T-033 set for base-model licences (`plan.md` Risk 8: *"No training on an unverified base — T-033 records licence/access evidence per candidate and marks unverifiable candidates NOT USABLE"*). An unverifiable licence is `NOT USABLE` here too; "probably fine" is not a verdict this ledger accepts.

**The known hazard, to be resolved by evidence rather than by assumption.** Popular reverberant-speech corpora are built on top of a *licensed speech corpus* whose terms propagate to the mix. The check the task must perform per source is therefore not only "what does this repo say" but "what does it say about the speech underneath" — and where a source's usability depends on a base corpus with a research-only or agreement-gated licence, the entry is `NOT USABLE` for the mix and the *simulation recipe* (the impulse responses alone, which carry their own terms) is recorded as the usable part. Sources whose only obstacles are size or access are recorded with the download procedure instead.

**Privacy is a non-issue by construction and must be recorded as such.** Nothing here is user data: every source is a public corpus or a synthetic rendering, no device audio is collected, and NFR-015 is not engaged. The one place it could be engaged — a future real-recording tier — is explicitly out of scope, and the manifest says so, so that a later reader cannot mistake this benchmark for a consent-bearing acquisition (`docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` GAP-2).

**The TTS voice's licence is part of this ledger, and it is not a formality.** The benchmark renders every fixture through the shipped voice, `voices/hi_IN-pratham-medium.onnx` (`config.yaml:23`) — and per-voice licence files in the piper voice repository attribute the `hi_IN` voices to **CC BY-NC-SA 4.0** (non-commercial), while the voice repository's own README carries a repo-level `license: mit` tag that does not govern the individual voices. Two consequences must be evidenced rather than assumed: (a) whether the benchmark may render and ship fixtures with the current voice at all, and (b) whether a licence-clean Nepali voice exists, because that is the **enabling condition for the accent cells** TG-11's GAP-3 leaves open and for the matrix's voice axis. The pass verifies both against the primary per-voice licence files (the model card in the voice repository, and the dataset licence the voice was trained on), records the verdict per voice, and — if a `CC0`/`CC BY` Nepali voice verifies — states it as the matrix's recommended benchmark voice with its evidence. This group does not vendor or ship a voice (that is a product decision with a training-side consequence, TG-11's [T-066](../../TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md)); it determines what the benchmark may render with and reports the finding.

**Out of scope.** No acquisition of speech corpora for training (that is TG-08/TG-11's supply), no accent recordings, no voice vendored or shipped (the licence determination above is a ledger entry, not an adoption), no download performed by CI, and no corpus content committed to the repository.

## Acceptance criteria

```gherkin
Feature: Noise and RIR corpus acquisition with licence evidence

  Scenario: Every candidate source carries a verifiable licence verdict
    Given the candidate sources named in the design doc §4 (additive noise, room impulse responses, background speech)
    When the acquisition pass reads each source's own licence statement
    Then eval/env/MANIFEST.md carries one row per source with the canonical URL, the verbatim licence line, the commercial-use and redistribution-rights answers, the access requirement and the size
    And each row ends in exactly one verdict: USE (a) measurement input, USE (a+b) measurement input and committed derivative, or NOT USABLE with the reason
    And a source whose licence cannot be established from a primary source is NOT USABLE, never "probably fine"

  Scenario: The base-corpus constraint is checked, not assumed
    Given that at least one reverberant-speech corpus is built on a separately licensed speech corpus
    When the licence check reads what the source says about the speech underneath the noise or the impulse response
    Then the manifest states per source whether the base corpus's terms propagate to the mix used here
    And any mix whose base corpus is research-only or agreement-gated is NOT USABLE for that mix, with the usable remainder (e.g. the impulse responses alone) recorded separately

  Scenario: Use (b) is granted only where redistribution is permitted
    Given the CI tier is required to run without a multi-gigabyte download
    When a source is proposed for a committed derivative under use (b)
    Then the manifest states the licence basis for committing that derivative, and a source without a redistribution right is marked USE (a) only
    And for every USE (a)-only source the CI tier reports SKIPPED — corpus absent rather than substituting a different fixture, and the run's exit code says the tier did not score

  Scenario: Pins are recorded so a cell re-derives on a different host
    Given a condition cell must mean the same thing on every host
    When the acquisition pass records each downloaded archive
    Then eval/env/corpora.jsonl carries the source id, the sha256 of the downloaded artifact, the file list and the licence verdict id from MANIFEST.md
    And a re-run with a mismatched digest fails loudly rather than rendering a cell nobody else can reproduce

  Scenario: The rendering voice's licence is determined, not assumed
    Given the benchmark renders every fixture through config.yaml:23's voice, and the piper voice repository carries a repo-level license: mit tag that does not govern individual voices
    When the licence pass reads the per-voice model cards
    Then each candidate voice carries its own verdict with the licence string quoted, the dataset it was trained on named, and the commercial-use and derivative answers
    And the ledger states which voice the benchmark may render with, and whether any licence-clean Nepali-capable voice exists — the condition that would make the matrix's voice axis real (TG-11 GAP-3)

  Scenario: No user data is involved and the ledger says so
    Given NFR-015 (no personal data to cloud for AI processing) and NFR-016 (no PII in logs or artifacts)
    When the manifest and the corpus ledger are written
    Then they contain counts, durations, hashes and licence strings only — no utterance content, no speaker identity, no recording that was not already public
    And the manifest states that a real-recording tier would be a separate consent-bearing acquisition and is out of scope for this group
```

## Implementation notes

- Read the licence at the source, not from memory and not from a package index: the corpus README/LICENSE file, the OpenSLR page, the Hugging Face dataset card, or the paper's data section. Quote one line verbatim per source — the quote is the evidence, the paraphrase is not.
- Check for a *base corpus* constraint before granting any verdict, and record what the check read (file or URL) beside the verdict. A source that aggregates others' data inherits their terms; the mix is only as usable as the strictest input.
- Pin by sha256 of the downloaded artifact, 12 hex characters in any document that quotes it (the project's convention — `src/measure_device.py:75-78` explains why), full digest in `corpora.jsonl`.
- The manifest is a ledger, not a vendor list: it does not go stale silently. Each entry records the date the licence was read, so a later reader knows how old the check is.
- Sizes drive T-082's render budget: report hours (noise) and impulse-response counts (RIR) per source, because T-081's cell arithmetic consumes them.
- Cross-reference, do not duplicate: TG-08's T-033 licence discipline for base models and TG-10's T-053 privacy review are the project's existing patterns for "evidence or NOT USABLE".
- No download is performed by CI, no corpus is committed, no model is run. This task's deliverable is a ledger plus the staged download procedure.

## Definition of done
- [ ] `eval/env/MANIFEST.md` committed: one row per candidate source with URL, verbatim licence line, commercial/redistribution answers, access requirement, size, date read, and a single verdict
- [ ] Every `NOT USABLE` entry names the specific clause or agreement that disqualifies it
- [ ] Every `USE (a)`-only entry is paired with the CI tier's `SKIPPED — corpus absent` behaviour
- [ ] `eval/env/corpora.jsonl` committed with source id, sha256 pin, file list and verdict id per source
- [ ] The base-corpus propagation check is answered per source, with the file or URL the check read named
- [ ] Per-voice licence verdicts recorded for the rendering voice and for every licence-clean Nepali-capable voice found, with the model card quoted and the training dataset named; the voice the benchmark may render with is named
- [ ] The manifest states that no user data is involved and that real recordings are out of scope for this group
- [ ] Design doc §5's licence table is reconciled against this ledger — any divergence is corrected in the doc, not left in two places
