# Crux-Resolution Pipeline — Design

**Status:** design (doc-only). No code, no training, no model artifact is produced by this document.
**Task group:** TG-12 (`T-070`–`T-079`).
**Consumes:** TG-08 (encoder + harness), TG-10 (continuous learning loop), TG-11 (linguistic robustness).
**Baseline revision read for this design:** `41daeb68e0edffc99e4a61086c5bc36796afce13` (`master`, 2026-09-15).
**Corpus revision referred to throughout:** `7f71b8ae` (`sha256(eval/golden_corpus.jsonl)[:8]`, 8 000 rows).

---

## 1. Purpose and scope

The product goal is an intent engine that reads *through* bad STT, dialects and regional speaking styles to the **crux** of a request — Nepali, SOV, frequently spoken telegraphically by an elder. Three things stand between the user's utterance and a correct dispatch:

1. **Surface variance.** The decoder emits a form that is not the form the model was trained on: a dialectal perfective (`गइछ` for `गएछ`), an orthographic variant (halanta dropped, anusvara written as a conjunct), a mis-segmentation, or a clipped elder register (`elder_fragmented`, an existing `register` value at `annotation_rules.yaml:216`).
2. **Brain selection.** A small encoder can answer most closed-action turns; a large LLM must answer the long tail. Which one answers, and what happens when the small one is unsure, is a policy — and the policy's default is currently "neither, use the incumbent alone".
3. **Threshold drift.** Both the variant surface and the confidence at which "sure" is declared are empirical quantities that change as the household's traffic changes. Freezing them at design time guarantees they are wrong later.

This document designs the fix for all three:

- **§4 — the canonicalization layer.** A dialect-aware pre-intent normalizer, `DialectCanonicalizer`, that rewrites attested variant surface forms onto canonical forms *before* tokenization and encoding, and returns the canonicalized transcript **plus per-application provenance** (which rule fired, over which original range).
- **§6 — cascade as default.** The policy that makes encoder-first-with-picker-brain-fallback the default local-brain mode, with the flip gated on **numeric** conditions measured on a named revision.
- **§7 — TG-10 as the glue.** The variant tables and the cascade's confidence/threshold artifacts are data files, which is precisely what makes them eligible to ride the continuous-learning loop — under its promotion gate, never around it.

**Scope boundary.** This is a *runtime* design. It adds no intent label, no BIO tag, no model head, no training run and no eval gate of its own — it consumes the eight existing gates (`config.yaml:58-69`) and the two additive robustness gates TG-11 designs. It does not modify `IntentRouter`, `CommandRouter`, the keyword safety net, `TranscriptSanityGuard`, `IntentCommandCache` or the confirmation flow.

**The one constraint that outranks everything else in this document.** Canonicalization is **lossless for safety**. The emergency path and the keyword net read the **original** transcript, first, exactly as they do today (§4.7). Canonicalization output is *only ever* the intent model's input, and can never gate, suppress, rewrite or delay what the keyword net sees. §4.7 states the checkable invariant that makes this enforceable rather than aspirational.

---

## 2. Recorded decisions

### D-1 — Canonicalization is lossless for safety: the keyword net reads the original, always

The keyword safety net runs at `CommandRouter.routeSafetyNet(raw)` (`CommandRouter.swift:1494`), invoked from `route(transcript:)` at `:716` — **before** the interpreter fast path. Its emergency list is 17 phrases (7 English + 10 Nepali, `:1468-1473`), matched by `containsPhrase` (substring, `:1439`) against a lowercased, whitespace-collapsed copy of the raw transcript (`:617-620`). Medication acknowledgement and — critically — **denial before ack** are matched with `containsToken` (`:1448`, denial guard `:1508-1517`), whose doc comment states the hazard verbatim: *"Nepali "खाए" sits inside "नखाए" (not eaten) … a containment match turns a refusal into a medication acknowledgement."*

Canonicalization therefore **must not** be inserted upstream of that net, and **must not** be reusable by it. The net's input is frozen as the original transcript. This is recorded as a decision rather than an implementation detail because the tempting refactor — "canonicalize once at the top of `route()` and let every stage share it" — is exactly the change that would break it.

### D-2 — Rules are data, authored and tested, never a black box

There is no learned component in this design. Every rewrite is a lookup in a variant table or a deterministic orthographic rule. No seq2seq "normalizer" model, no LLM rewriter, no fuzzy matching. Rationale, grounded in shipped precedent: `NepaliTextNormalizer` (`Services/Intents/NepaliTextNormalizer.swift`) already refuses transliteration for exactly this reason — its header comment records that folding `माइया` and `maiya` onto one key is *"the exact hazard spec §4.2 calls out for fuzzy matching"*, and that a lossy transliterator *"turns "maiya" and "maya" (different people) into the same key"*.

The same hazard applies with more force here: canonicalizing a `contact` span is one step away from calling the wrong person. A deterministic, auditable, per-rule table is reviewable by a native speaker; a black box is not.

### D-3 — Tables follow the shipped `DialectLexicon` / `DialectCentroidTable` shape

The repo already ships two externally-replaceable, structurally-validated data resources for exactly this domain: `Resources/DialectLexicon.json` and `Resources/DialectCentroids.json`, both `Decodable` with a `formatVersion`, a `generation` block (`status`, `path`, `date`) and an `issues()` structural validator (`DialectBiasComposer.swift:113-170`, `DialectIdentifier.swift:189-239`). `DialectBiasComposer.swift:104-105` states the intent: *"Content, not code: the calibration/linguist pipeline replaces the JSON without an app change (same shape as `DialectCentroidTable`)."*

The canonicalizer's tables adopt this shape unchanged. This is not stylistic alignment — it is what makes §7 (TG-10 integration) possible without new machinery, and it gives the variant tables a fail-closed validator on day one.

### D-4 — The fail-closed rule transfers: a structurally corrupt table must not canonicalize at all

`DialectBiasComposer.swift:111-112` records the honesty rule for the lexicon: *"a **structurally corrupt** lexicon must not bias at all"*. The same rule governs variant tables. A table that fails `issues()` canonicalizes **nothing** — the transcript passes through byte-identical — and the reason is reported once per session. Partial application of a corrupt table is the one outcome that is worse than no canonicalization, because it produces a transcript that is neither the original nor a known canonical form.

### D-5 — Provenance is mandatory, and spans map back to the original

The encoder's slot contract is *"spans in, resolution in code"* (`docs/superpowers/specs/2026-09-13-joint-intent-slot-encoder-design.md` §8), and its failure mode F-4 requires `transcript[start:end] == text` to hold for every decoded span (§12, `:714`). §7.2 of that design states the invariant directly: *"The trimmed value is still a substring of the transcript, so it is still a span, not a resolution."*

If the encoder consumes a canonicalized transcript, its spans are canonical-relative and that invariant no longer holds against the original. `DialectCanonicalizer` therefore returns an explicit offset map, and §4.5 defines how a span that crosses a rewritten region is remapped — and when it must instead **abstain**.

### D-6 — The cascade default flip is a two-stage gate, and Stage 0 is currently RED

The cascade mechanism exists in full (§6.1) but is doubly gated:

- **Compile-time:** the encoder path is behind `#if INTENT_ENCODER` (`IntentEncoderFeature.swift:54-60`), *"compiled-out on a non-gated build, so no test can flip it at runtime"*, and its doc states the purpose plainly: *"It must therefore be impossible for the encoder to become the local brain in a release build by accident."*
- **Runtime:** `IntentEncoderPreferences.isCascadeEnabled` (`:106-109`) reads an absent key as **false**.

Stage 0 is a precondition, not a formality: the shipped encoder artifact is the T-036 v0 export whose gates **failed** — `IntentEncoderFeature.swift:6-8` records *"closed-intent accuracy ~0.53, emergency recall ~0.9375, publication withheld"*. `emergency_recall` is a **1.00 hard gate** (`config.yaml:60`, "no compromise"). No default flip discussion is meaningful until that number is 1.00. Stage 1 (the flip itself) is designed in §6.3 and is separately gated on latency and residency.

### D-7 — The flip does not touch the band constants

`IntentRouter.Config.default` is `acceptThreshold 0.7`, `rephraseThreshold 0.4` (`IntentRouter.swift:56-58`), and `IntentEncoderWiring.cascadeAcceptThreshold` (`IntentEncoderFeature.swift:163`) is **defined as** `IntentRouter.Config.default.acceptThreshold` — *"one number, not two"*. The flip changes *which brain fills the local slot*, not the bands that judge it. This keeps faith with TG-10's invariant 3 (*"No new threshold. The band policy … is not modified by the loop"*, `2026-09-13-continuous-learning-loop-design.md:438-440`) and with encoder design §9 (*"the encoder introduces no new threshold"*, `:513`).

### D-8 — Evidence-gated: the honest outcome may be "do not flip", and "no effect" must be printable

Every claim in this design is either measured or marked `UNMEASURED — gap` in the §14 evidence pack. The flip conditions in §6.3 are numeric. If canonicalization buys **+0** points on a dialect slice, the design's job is to print the zero and let the flip condition fail on it — not to argue that the mechanism is sound in principle. §2.1 records what this costs us in admitted weakness.

### D-9 — The dialect taxonomy is TG-11's to settle, not ours to assume

The brief names Eastern/Central/Western/Terai. The **shipped** vocabulary is two values — `DialectLabel` is `eastern | doteli | default` (`DialectIdentifier.swift:43-53`) and `DialectLexicon.json` carries exactly `eastern` and `doteli` entries. TG-11's `T-062` works a five-value hypothesis (`standard, eastern, central, western, terai`, `T-062:16`) pending native-speaker validation, and `docs/research-sections/accent-adaptation.md:545-546` records the taxonomy itself as an open question (*"Which clusters actually ship (Doteli complex? Eastern? Madhesi?)"*).

A canonicalizer keyed on a dialect vocabulary that does not match the shipped one cannot select a table at runtime. **TG-12 consumes `T-062`'s resolution; it does not pre-empt it.** §4.3 defines the runtime fallback that makes this safe in the meantime.

---

## 3. Ground truth read for this design

Every row was read against the worktree at `41daeb6` before writing. Only facts that shape the design are listed.

| Fact | Where |
|---|---|
| Safety net runs before every model, on the raw transcript | `CommandRouter.swift:716`, `:1494` |
| Emergency list: 17 phrases (7 EN + 10 NE), substring match | `CommandRouter.swift:1468-1473`, `:1439` |
| Whitespace/lowercase canonicalization already applied to the *net's* copy | `CommandRouter.swift:607-620` |
| Med-ack uses whole-token match because `खाए` ⊂ `नखाए` | `CommandRouter.swift:1443-1452` |
| Denial-before-ack check | `CommandRouter.swift:1443-1452` |
| `InputSanitiser.sanitise(_:level:)`, `.quarantine`, `maxLength = 200` | `InputSanitiser.swift:22`, `:42-44` |
| `NepaliTextNormalizer`: NFC, digit fold, punctuation+danda strip, whitespace collapse | `NepaliTextNormalizer.swift:34-50` |
| …and its explicit refusal to transliterate, with the `maiya`/`maya` hazard | `NepaliTextNormalizer.swift:17-23` |
| Honorific stripping is a second, match-time step, never storage-time | `NepaliTextNormalizer.swift:52-58` |
| Band constants: accept 0.7, rephrase 0.4 | `IntentRouter.swift:56-58` |
| `bandChecked` is the only in-router band application | `IntentRouter.swift:316-330` |
| Local-ladder escalation today targets the **cloud**, not a local LLM | `IntentRouter.swift:197-238` |
| Cascade exists as `LocalBrainChain.Cascade`, opt-in, `cascade: nil` is the shipped default | `LocalBrainChain.swift:28-56` |
| Escalation reasons: `abstained` / `failed` / `subBandConfidence` | `LocalBrainChain.swift:33-43` |
| Cascade accepted threshold is defined as the router's accept band | `IntentEncoderFeature.swift:160-163` |
| Serving modes: `.pickerBrain` / `.standaloneEncoder` / `.encoderFirstEscalate` | `IntentEncoderFeature.swift:148-158` |
| Cascade switch persisted, **absent key reads false** | `IntentEncoderFeature.swift:84`, `:106-109` |
| Encoder path behind `#if INTENT_ENCODER` | `IntentEncoderFeature.swift:54-60` |
| Shipped encoder artifact's gates FAILED (~0.53 acc, ~0.9375 emergency recall) | `IntentEncoderFeature.swift:6-8` |
| Encoder timeout 2.0 s, 0 retries, abstain at 0.4 | `IntentEncoderInterpreter.swift:168-169`, `:535` |
| Picker brain timeout **10 s**, abstain at 0.4 | `LocalIntentInterpreter.swift:47-49`, `:235` |
| Per-stage turn timing incl. `cascade_decision`, `picker_prompt_build`, `picker_inference` | `TurnTimingBreakdown.swift:50-69` |
| Coarse per-turn tracer: `vad_fired`, `asr_done`, `router_done`, `llm_start/done`, `speak_queued/finished` | `VoiceTurnLatencyTracer.swift:223-235`; marks `VoicePipeline.swift:338`, `:729`, `:827`, `:852`; `CommandRouter.swift:1134`, `:1138` |
| Device latency harness with **hard p50/p95 gates** (nearest-rank percentile, cold/warm split, exit 1) | `tools/train-intent/src/measure_device.py:220-221`, `:270-294` |
| The p50 ≤ 1.0 s / p95 ≤ 2.0 s budget origin | `tools/train-intent/docs/T-033-encoder-bakeoff.md:78` |
| Cascade A/B design rationale and evidence events | `specs/T-037-a-notes.md:461-503` |
| Cascade escalation event `encoder_escalated_to_picker_brain` (reason metadata) | `AppCoordinator.swift:1406-1415` |
| The cascade **default (non-cascade) chain passes the sub-band through** — pinned by test | `LocalBrainChainTests.swift:196-207` |
| A **third** 0.7 literal, hard-coded and not derived from the constant | `CommandRouter.swift:1139-1155` |
| `defaultBrainModelID` names `intentQwen4BS43` while the catalog's slot-canonical entry claims to replace it | `AppCoordinator.swift:1516`; `ModelCatalog.swift:242-248`, `:1254-1257` |
| Dialect label vocabulary: `eastern`, `doteli`, `default` | `DialectIdentifier.swift:43-53`, `:64-79` |
| Centroid table: cosine, dim 1024, `confidenceGate 0.6`, status `SEED-CENTROIDS`, **empty `promptTokenIds`** | `Resources/DialectCentroids.json` |
| Lexicon: SEED-LEXICON, 2 entries, attested variant phrases + tag lines | `Resources/DialectLexicon.json` |
| Lexicon shape: `formatVersion` + `generation{status,path,date}` + `issues()` | `DialectBiasComposer.swift:113-170` |
| "Content, not code: the … pipeline replaces the JSON without an app change" | `DialectBiasComposer.swift:104-105` |
| "A structurally corrupt lexicon must not bias at all" | `DialectBiasComposer.swift:111-112` |
| `routeSafetyNet` body: emergency, denial guard, ack phrases + tokens | `CommandRouter.swift:1493-1536`, `:1499-1503`, `:1508-1517`, `:1519-1534` |
| `handleEmergency()` is a spoken ack + local notification — **no emergency-call module** | `CommandRouter.swift:2377-2381`; OD-11 B4/B6 (`constitution.md:123`) |
| `ConfirmationTier`: `emergency`/`ackMed` `.neverGated`; `call`/`sendMessage`/`setReminder`/`createCalendarEvent` `.confirm` | `ConfirmationTier.swift:19-22` |
| FR-005 is the dialect requirement — onboarding voice samples, accent tuning on-device | `requirements.md:30-31` |
| No `SPEED`/`ACCURACY` toggle exists; nearest hosts are `voiceEngineStack` (default `.gemini`) and `brainModelPreference` | `SettingsView.swift:1083-1141`; `AppCoordinator.swift:299-305`, `:282-289`, `:1516` |
| The eight gates, literal values | `config.yaml:58-69` |
| `emergency_recall: 1.00` — "hard gate, no compromise" | `config.yaml:60` |
| Corpus revision tag computed per run | `eval_golden.py:606` |
| Baseline binds to `@<corpus_tag>`; unbound baselines never selected | `eval_golden.py:529` |
| Hazard: hash of low-entropy utterance is a pseudonym | `constitution.md` Privacy bullet; TG-10 §5.2 |
| `register` values today: `devanagari, romanized, code_switched, elder_fragmented` | `annotation_rules.yaml:216` |
| Corpus floors: `corpus_floor 8000`, `hard_floor_stt_noised 0.55` | `annotation_rules.yaml:230-232` |
| 8 000 rows = 189 hand + 7 811 generated; devanagari 5 508 / latin 1 678 / code_switched 814 | `eval/golden_corpus.jsonl`; TG-11 index `:11`; batch manifest |
| TG-11 freeze list: "polarity/negation markers, emergency rows, and the music/suggest_video verb pair" | `T-061-order-robustness-baseline.md:37` |
| TG-11 order gate: `A_ctrl − A_perm <= 0.03` | `T-065-harness-robustness-gates.md:18` |
| TG-11 dialect gate: `max over claimed slices of (A_standard_twin − A_dialect_slice) <= 0.05` | `T-065-harness-robustness-gates.md:28` |
| TG-11 declares `dialect × style` row metadata, **never model labels** | `T-063-annotation-rules-amendment.md:20` |
| T-033 evidence-pack precedent (machine-readable evidence dir) | `tools/train-intent/docs/t033-evidence/` |

**A stale citation, corrected here.** The encoder design cites the emergency list as `CommandRouter.swift:1403-1408` (`§11, :692`). At `41daeb6` the list is at **`:1468-1473`** — the file has grown since that spec was written. This design uses the current numbers. The encoder spec's *substantive* claim (17 phrases, 7 English + 10 Nepali) is correct and was verified by reading the list. Recorded because a design that inherits a stale citation inherits the assumption that its ground truth was re-read.

**Correction to a brief assumption.** The brief places TG-11's docs under `tools/train-intent/`. They are not there: `tools/train-intent/docs/` holds only T-033-era material (`T-033-encoder-bakeoff.md`, `T-033-notes.md`, `export-gguf-plan.md`, `t033-evidence/`). TG-11's task documents live in the **TG-11 worktree**, `.claude/worktrees/tg11-robustness/.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/`, and are **unmerged** — they are absent from the main checkout's task tree today, so every link this group makes into them resolves only once TG-11 lands. TG-11 does touch `tools/train-intent/` — it amends `annotation_rules.yaml` and adds `eval/order_permutation.jsonl`, `eval/dialect_holdout.jsonl` — but its *documents* are in the task tree. This design cites the actual paths.

**A ground-truth finding that limits this design's reach, read from the code.** The dialect label the canonicalizer would select tables by is read from `DialectPreference.persisted()` (UserDefaults `dialectLabel`), and its only writer, `WhisperKitSpeechRecognizer.applyDialectLabel(_:)`, **has no production callers** — the embedding/classification bridge beside it (`extractDialectEmbedding(from:)`) is documented as *"the future enrolment flow"*. So in production today the persisted label is `.default`, and the shipped `SEED-CENTROIDS` table could not clear its own 0.6 gate anyway (a test asserts *"A seed table must never classify anything"*). Two consequences the design accepts rather than papers over: the **orthographic and pan-regional tables are the half that can act today**, and the per-dialect tables are inert until the enrolment flow and a calibrated centroid table land. §4.3's fallback is written for exactly this state, and the honest expectation for §14's E-6 is correspondingly modest.

**A second ID-set correction, made after the first draft.** When this design was first written, TG-11 occupied `T-061`–`T-068`; while it was being drafted, TG-11 added a ninth task (`T-069`, its evidence pack) and TG-13 was allocated `T-080`–`T-089` — with TG-13's index already linking into this group. The group therefore moved from `T-069`–`T-079` to `T-070`–`T-079`, which fits ten IDs, so the brief's eleven tasks became ten. §12 records the shift and the merge. Task IDs are allocated against *every* worktree on disk, not only the main checkout, and the check must be re-run immediately before allocation because a parallel group can grow.

---

## 4. The canonicalization layer

### 4.1 Where it sits

Canonicalization is inserted **inside the intent interpreter, after sanitisation and before the encoder's tokenizer**. It is not a router stage and not a transcript-level concern.

```
CommandRouter.route(transcript: raw)                          CommandRouter.swift:582
  ├─ emergency phrases       ← RAW, first, always             :716 → :1494
  ├─ med-ack / denial-before-ack ← RAW, whole-token           :1443-1452
  ├─ confirmation follow-up paths ← RAW                       :629+
  ├─ cache (IntentCommandCache) ← NepaliTextNormalizer key
  └─ interpreters
       └─ LocalBrainChain
            ├─ preferred: IntentEncoderInterpreter
            │    └─ InputSanitiser.sanitise(.quarantine)      InputSanitiser.swift:42
            │         └─ DialectCanonicalizer.canonicalize    ◀── NEW (this design)
            │              └─ tokenizer → encoder forward pass
            └─ standIn: picker brain (4B / LocalIntentInterpreter)
                 └─ InputSanitiser.sanitise(.quarantine) → prompt
```

Three properties follow, and each is deliberate:

1. **The net is untouched.** D-1.
2. **The cache is untouched.** `IntentCommandCache` keys on `NepaliTextNormalizer.normalize` output (`NepaliTextNormalizer.swift:3-6`, *"the single normalization used by the intent cache (key generation) and the contact resolver (both sides of a match)"*). If the cache key changed, every recorded cache entry would be orphaned and the cache's write-after-confirmation discipline — the thing that makes a cache hit safe without `bandChecked` (encoder design §9, `:534-545`) — would be re-keyed without evidence. Canonicalization does **not** change the cache key. It is a model-input transform, and nothing else.
3. **The 4B long tail is a separate decision.** When the cascade escalates (§6), the stand-in receives whichever transcript the chain passes it. §4.6 defines which, and why the answer is *not* "always canonical".

### 4.2 The `DialectCanonicalizer` contract

```swift
/// A single applied rewrite. Every application is recorded; there is no
/// silent rewrite path.
struct CanonicalVariantApplication: Equatable, Sendable {
    /// The rule that fired — table id + entry id, so a log line names a
    /// reviewable row rather than "normalizer".
    let ruleID: String
    /// Which table contributed it (per-region or dialect-agnostic).
    let tableID: String
    /// The dialect the table was selected for; nil for a pan-regional rule.
    let dialect: DialectLabel?
    let kind: Kind
    /// Half-open UTF-16-offset ranges, matching the contract the encoder's
    /// span decoder already uses (`annotation_rules.yaml:96-104`).
    let originalRange: Range<Int>
    let canonicalRange: Range<Int>
    /// The exact surface forms, for the sweep log and the fixture diff.
    let original: String
    let canonical: String

    enum Kind: String, Sendable {
        case lexicalVariant      // dialect word → standard word
        case orthographic        // halanta / anusvara / diacritic
        case misSegmentation     // STT word-boundary error
        case clippedForm         // elder telegraphic register
    }
}

struct CanonicalizationResult: Sendable {
    /// The model-input transcript. Byte-identical to the input when no
    /// rule fired, and byte-identical to the input when the tables are
    /// structurally corrupt (D-4).
    let canonical: String
    /// Empty iff `canonical == original`. Order is by `canonicalRange`.
    let applications: [CanonicalVariantApplication]
    /// Which table set produced this, and its revision — the anchor for
    /// the §14 evidence pack and the §7 loop.
    let tableRevision: String
    /// True when a structurally corrupt or absent table forced passthrough.
    let degraded: Bool
}

enum DialectCanonicalizer {
    static func canonicalize(
        _ transcript: String,
        dialect: DialectLabel,
        tables: VariantTableSet,
        policy: Policy
    ) -> CanonicalizationResult

    struct Policy {
        /// Whether any rule may fire at all. Default true; false is the
        /// kill switch (§6.6) and the A/B control arm.
        var enabled: Bool = true
        /// When true, only `orthographic` rules run — the conservative arm
        /// used before per-dialect tables clear review.
        var orthographicOnly: Bool = false
    }
}
```

**Signature rationale, against the constitution's design principles.** Error return type is explicit (no `any`/`unknown`): the function never throws, and every failure is a *value* — `degraded: true` with empty `applications` — which is what makes the fail-soft behaviour testable. The operation is synchronous, pure and non-retryable by construction: it is a table lookup over a bounded string, with no I/O, no allocation of a model, and no async boundary. `InputSanitiser.sanitise` is likewise synchronous and non-throwing, so the composition adds no new failure mode to the interpreter's completion contract (*"`completion` fires exactly once on every path"*, encoder design §10, `:564`).

**Ordering is fixed and declared**, because two orderings can give different results:

1. `orthographic` (NFC-anchored, §4.4) — surface form first, so lexical lookup sees a stabilised string.
2. `misSegmentation` — boundary repair, which needs stable scalars.
3. `lexicalVariant` (dialect table, then pan-regional table) — word-level lookup on stable, correctly-bounded tokens.
4. `clippedForm` — register-driven, last, because it may depend on lexical context.
5. Paren/quote/whitespace re-collapse to a single-spaced form.

Each stage's applications are appended in canonical-offset order and the recorded offsets are translated forward through later stages, so a stage-1 application remains addressable after stage-3 rewrites shift its position.

### 4.3 Variant-table schema

Adopting the shipped resource shape (D-3). One file per dialect region plus one pan-regional file:

```
ios/ElderlyAssistant/Resources/VariantTables/
  canonical-orthographic.json      # pan-regional, dialect: null
  canonical-panregional.json       # dialect: null
  canonical-eastern.json
  canonical-doteli.json
  canonical-<region>.json          # per T-062's validated inventory
```

```json
{
  "formatVersion": 1,
  "generation": {
    "status": "SEED-CANONICAL",
    "path": "<provenance of authoring>",
    "date": null
  },
  "dialect": "eastern",
  "entries": [
    {
      "id": "eastern-perfective-ichha",
      "kind": "lexicalVariant",
      "variant": "गइछ",
      "canonical": "गएछ",
      "evidence": {
        "source": "corpus",
        "corpusRevision": "7f71b8ae",
        "rowIDs": ["gc-…"],
        "occurrences": 0,
        "fixtureExamples": []
      }
    }
  ]
}
```

**Required fields and what they are for:**

| Field | Purpose | Enforced |
|---|---|---|
| `id` | Stable, greppable rule identity. Appears in `applications[].ruleID` and every log line. | unique per file |
| `kind` | Which stage the rule runs in (§4.2). | in the closed 4-value set |
| `variant` / `canonical` | The rewrite. | both non-empty |
| `evidence.source` | `corpus` \| `fixture` \| `authored` — §4.3.1. | closed set |
| `evidence.corpusRevision` | The corpus revision the frequency was measured on. | required when `source == corpus` |
| `evidence.occurrences` | Frequency evidence — the gate in §4.3.1. | required ≥ 1 when `source == corpus` |
| `evidence.fixtureExamples` | The cited example set that justifies a non-corpus rule. | required ≥ 2 when `source != corpus` |

**`issues()` structural validation** (fail-closed, D-4), mirroring `DialectLexicon.Issue` (`DialectBiasComposer.swift:162-170`):

```
unsupportedFormatVersion(Int)
emptyEntries
duplicateEntryID(String)
unknownKind(String)
emptyVariantOrCanonical(entry: String)
evidenceMissing(entry: String)
evidenceContradictsSource(entry: String)   // occurrences < 1 with source == corpus
variantEqualsCanonical(entry: String)      // a no-op rule is a data error, not a rule
negationMarkerTouched(entry: String)       // §4.7 — the hard safety check
```

The last two are the ones that earn their keep. `variantEqualsCanonical` catches copy-paste table rows that would otherwise inflate coverage numbers in the §14 evidence pack. `negationMarkerTouched` is the machine-checkable form of D-1: a table entry whose `variant` or `canonical` contains a member of the frozen negation set (§4.7) is a **structural error**, not a warning, and the whole table is refused.

#### 4.3.1 Every rule is sourced, or it is not authored

Per D-8, a rule enters a table only with one of:

- **Frequency evidence.** `source: "corpus"`, with `occurrences` counted over the pinned 8 000-row corpus and the affected `rowIDs` recorded. [T-070](T-070-variant-coverage-measurement.md) produces these counts per `script` slice (devanagari 5 508 / latin 1 678 / code_switched 814) — a variant that occurs only in the generated rows and never in the 189 hand rows is recorded as such.
- **Authored fixture with a cited example set.** `source: "fixture"` or `"authored"`, with ≥ 2 attested examples (`fixtureExamples`) that a native speaker has reviewed under TG-11's `T-062`.

A rule with neither is **not authored**, and its absence is reported in the coverage gap table rather than filled with a plausible guess. This is the concrete meaning of the design's refusal to guess: the corpus tells us which variants actually occur, so a rule we cannot source is a rule for a variant that is not in front of us.

**The dialect-selection fallback.** Because the shipped `DialectLabel` vocabulary is `eastern | doteli | default` (`DialectIdentifier.swift:43-53`) while TG-11's validated inventory may be wider (D-9), selection is defined as:

```
dialect == .default            → orthographic + pan-regional only
dialect has a table            → orthographic + pan-regional + that dialect's table
dialect has no table           → orthographic + pan-regional; degraded = false,
                                 selection reason emitted once
centroid table degraded/empty  → dialogs above, plus the dialect selection is
                                 marked low-confidence in provenance
```

Selection never blocks and never falls back to *another region's* table. Applying an eastern table to a Doteli speaker would introduce errors that were not in the input — the one direction a canonicalizer must never move.

**A shipped-state gap, stated now.** `DialectCentroids.json` is `SEED-CENTROIDS` with **empty `promptTokenIds` and empty `promptText`** for both clusters, and `confidenceGate 0.6`. So even the two existing labels are not yet acoustically selected with a calibrated table; the label in practice comes from `DialectPreference` (UserDefaults `dialectLabel`, `DialectIdentifier.swift:64-79`), which is enrolment-configured. The canonicalizer must therefore work with an enrolment-set label and tolerate it being wrong — hence the rule that a wrong label can only ever *fail to fire a rule*, never fire another region's rule.

### 4.4 Orthographic normalization rules

Ordered, deterministic, and **deliberately overlapping with `NepaliTextNormalizer` only where the purposes coincide**. `NepaliTextNormalizer` is the cache/resolver key normalizer (lossy by design: it strips punctuation and folds digits, because the key must match two spellings). The canonicalizer is a model-input normalizer (must preserve a readable transcript). They are different functions with different contracts, and the design keeps them separate rather than merging them — merging would either make the cache key lossy in new ways or leave punctuation in the model input.

| # | Rule | Example | Notes |
|---|---|---|---|
| O-1 | NFC precomposition | `क़` variants | Identical to `NepaliTextNormalizer.swift:35`. Cheap, idempotent, no semantic risk. |
| O-2 | Halanta normalisation | `क्` + `क` → `क्क` | Table-driven pairs only. |
| O-3 | Anusvara / chandrabindu variants | `ं` ↔ `ँ` where attested | Both directions only with `evidence`. |
| O-4 | Diacritic folding | `ऱ`, `ऴ` → nearest standard | Only forms with `evidence`. |
| O-5 | Devanagari digit folding | `८` → `8` | Same mapping as `NepaliTextNormalizer.swift:26-29` — but applied here for the *model's* benefit, not the key's. |
| O-6 | Mis-segmentation repair | STT joins/splits words | The `CommandRouter.swift:607-620` whitespace case generalised. Requires a token-boundary table; **never** joins across a frozen negation marker (§4.7). |
| O-7 | Clipped-form expansion | elder telegraphic forms | `Kind.clippedForm`. Flagged, never silent. |

**O-6 is the highest-risk rule in the set** and is scoped accordingly. WhisperKit's per-segment join behaviour (`CommandRouter.swift:607-620`, pinned rev `ea872ffd`) produces interior whitespace runs, and a mis-segmentation table that "repairs" `ना खाए` into `नखाए` changes a two-token refusal into one token — or the reverse. The freeze rule in §4.7 is what makes this safe: O-6 may not produce or consume a token that intersects the safety-keyword set, and any candidate repair that would is a structural error.

### 4.5 Provenance and the span invariant

This is the load-bearing section. If it is wrong, the canonicalizer breaks slot resolution — which for `contact` means the wrong person is called.

**The invariant.** The encoder consumes `canonical` and emits spans that satisfy `canonical[start:end] == spanText` (encoder design F-4, `:714`). Downstream, `ContactResolver`, `NepaliTimeParser` and `MedicationResolver` resolve those surfaces in code (encoder design §8). The value that reaches `InterpretedCommand.contact` must be a surface the resolver can match — and the resolver matches against the transcript, whose authoritative form is the **original**.

**The mechanism.** Every `application` carries `originalRange` and `canonicalRange`. A decoded span is mapped:

```
map(span) -> originalRange:
  if span lies entirely in regions untouched by any application:
      identity (offsets are equal by construction)
  if span is entirely CONTAINED in one application's canonicalRange:
      return that application's originalRange          // exact, substitution
  if span STRADDLES application boundaries:
      return min(originals) ..< max(originals)          // conservative widening
  if span overlaps a DELETION (canonical shorter):
      widen to the union of the affected applications
```

**Widening is always safe for a substring match and always unsafe for a resolution.** A widened `contact` span may contain extra words; `ContactResolver.relationshipAnchor` matches compounds by containment (`ContactResolver.swift:127-134`), so a wider span usually still resolves — but "usually" is not a standard for a phone call.

**Therefore the abstain rule, stated as policy:** when a span that is *required for a side-effecting action* (`contact` for `call`/`send_message`, `time` for `set_reminder` — the set encoder design F-4 already names, `:714`) maps with widening, the canonicalizer's provenance is **insufficient** and the interpreter **abstains** (`nil`, no failure reason), exactly as F-4 does for an invalid span. The alternative — resolving a widened contact — is precisely the "calls the wrong person" hazard `NepaliTextNormalizer` refuses transliteration to avoid (`NepaliTextNormalizer.swift:17-23`).

Two consequences the design accepts:

- **Substitutions are preferred over deletions/insertions in table authoring**, because a same-length substitution yields an exact span map and never triggers the abstain rule. Where a rule must change length, it is allowed — but the coverage evidence in §14 records how often that rule fires on corpus rows containing a `contact`/`time` span, so the abstain cost is visible rather than discovered in production.
- **`applications` is never empty when `canonical != original`.** If a rewrite cannot be attributed to a rule, that is a bug in the implementation, not a licence to pass the text through.

### 4.6 Composition with `InputSanitiser`, `NepaliTextNormalizer`, and the picker brain

**With `InputSanitiser`.** Composition, not replacement. The interpreter's existing order is preserved: `InputSanitiser.sanitise(_:level: .quarantine)` runs **first** (NFR-013; the constitution's Standards require `quarantine` level), and the canonicalizer runs on the sanitised string. Rationale: the sanitiser is the injection boundary and the 200-character clamp (`InputSanitiser.swift:22`); canonicalizing before it would let a table rewrite resurrect text the clamp had removed, and would put a table lookup upstream of the injection defence. The encoder's existing F-5 (`span_severed_by_truncation`) already models the clamp's consequences, so keeping the order preserves it.

**With `NepaliTextNormalizer`.** No call. The canonicalizer does **not** route its output through `NepaliTextNormalizer.normalize`, because that function strips punctuation and danda (`:31-32`) — fine for a cache key, wrong for a model input that must stay a faithful transcript, and destructive of the word-boundary information O-6 needs. The two share the NFC and digit-fold logic as *concepts* (O-1, O-5) and there is no shared-code requirement; a future refactor may extract the shared scalars, but the contracts stay distinct.

**With the keyword net.** Nothing. D-1.

**With the picker brain (on escalation).** The stand-in gets the **original sanitised** transcript, not the canonical one. Three reasons:

1. The picker brain is the long-tail rung — the utterances it sees are the ones the encoder could not classify, which are disproportionately the ones where a variant table was most likely to be guessing.
2. The picker brain is a general-purpose LLM with no canonical-form training; a variant table is evidence about *this* encoder's inputs, not about Qwen's. Feeding it canonicalized text is an unmeasured intervention on the one rung that currently works.
3. It keeps the escalation path's behaviour **identical to today's**, which is what makes §6's latency and quality comparison a comparison of one change rather than two.

This is recorded as a decision because the opposite choice ("canonicalize once, share it downstream") is superficially tidier and measurably riskier. If a later task wants canonical input on the picker rung, that is its own A/B — with its own evidence row in §14.

### 4.7 Losslessness for safety — the checkable invariant

The design's central safety claim is D-1: the net reads the original. That is a property of *the current call graph*, and call graphs change. The invariant below is what makes the claim survive refactoring, and it is directly testable.

**Frozen material — never touched by any rule.** Following TG-11's freeze list (`T-061-order-robustness-baseline.md:37`: *"polarity/negation markers, emergency rows, and the music/suggest_video verb pair"*), and extending it with the net's own vocabulary:

- **Negation and polarity markers:** `न`, `न-` prefixed forms, `नखाए`, `होइन`, `भएन`, `छैन`, `पर्दैन`, and the whole negative-verb class. The `खाए` ⊂ `नखाए` hazard (`CommandRouter.swift:1443-1452`) is the canonical example.
- **Every token in the emergency list** (`CommandRouter.swift:1468-1473`, 17 phrases) — as a *token to be rewritten*: no rule may map a form onto one of these, or away from one of these.
- **Every med-ack and denial token** (`:1519-1534`, `:1448`, denial guard `:1508-1517`).

**The invariant (the gate T-077 enforces):**

> For every row in the pinned losslessness fixture set, and for each of the net's own matchers (`containsPhrase` over the 17 emergency phrases, `containsToken` over the med-ack and denial token lists), applied identically to `original` and to `canonical`:
>
> **(a)** `matches(canonical) ⊇ matches(original)` — canonicalization may never **remove** a match the net would have found; and
> **(b)** `matches(canonical) ⊆ matches(original)` — canonicalization may never **introduce** a match the net would not have found.
>
> Together: `matches(canonical) == matches(original)`, **exactly**, on 100 % of fixture rows.

Clause (b) is the one that catches the `नखाए` → `खाए` class of defect. Clause (a) is the one that catches a rule that quietly eats a distress phrase. Both are computed by calling the *shipped* matchers — not a re-implementation — so the gate cannot drift from the net it protects.

**Why this gate exists even though the net reads the original.** Three reasons, each sufficient:

1. **It pins the property that makes D-1 refactor-safe.** A future task that moves the net downstream, or reuses the canonicalizer inside it, hits this gate first.
2. **It catches model-level intent errors that D-1 does not cover.** A model that reads `खाए` for an utterance that said `नखाए` classifies `ack_med` for a refusal — a wrong medication acknowledgement, which the taxonomy already models as `none` (denial-before-ack, `CommandRouter.swift:1443-1452`). Clause (a)/(b) equality is the checkable proxy for "polarity survives canonicalization".
3. **A failing fixture must trip the run.** [T-077](T-077-canonicalization-losslessness-safety-verification.md) is required to demonstrate the gate failing on a deliberately unsafe rule, before it is trusted to pass.

**`negationMarkerTouched` closes the loop at authoring time.** §4.3's `issues()` refuses any table containing such an entry, so the failure mode is caught when a table is written, not when a table runs.

---

## 5. What canonicalization is not

Recorded explicitly, because each is a plausible over-reach:

- **Not a spell-checker.** It rewrites forms that are *attested variants*, not forms that are *misspellings*. An unattested token passes through unchanged, byte-identical. There is no edit-distance, no fuzzy match, no dictionary nearest-neighbour.
- **Not a transliterator.** Devanagari↔Latin folding is refused for the reason `NepaliTextNormalizer.swift:17-23` already records — `maiya` and `maya` are different people.
- **Not a translation.** No Nepali→English. The taxonomy is the same twelve actions; the language is the same language.
- **Not a repair for a wrong STT word.** If the decoder heard the wrong word, a variant table that "corrects" it is guessing. Rules fire on attested variants only.
- **Not a safety control.** It explicitly is not. See D-1 and §4.7.
- **Not a learned component.** D-2. There is no runtime model in this layer.

---

## 6. Cascade as default

### 6.1 The ladder as it ships

The cascade is **already built**; what is missing is its default. `LocalBrainChain` (`LocalBrainChain.swift:28-56`) holds a `preferred` brain and a `standIn`, with two rules:

- **Availability rule** (`cascade: nil`, *"the default, and every shipped call site"*): `preferred` is the brain while available; `standIn` is consulted only when `preferred` is *unavailable*.
- **Cascade rule** (`cascade: LocalBrainChain.Cascade`): *"the preferred brain answers FIRST and the stand-in answers the SAME turn whenever the preferred brain abstained or came back below the router's ACCEPT band."*

The escalation reason is a fixed three-value vocabulary — `abstained`, `failed`, `subBandConfidence` (`:33-43`) — surfaced through an `onEscalated` callback, so every escalated turn is attributable from day one.

`IntentEncoderWiring.servingMode(isEnabled:isCascadeOn:)` (`IntentEncoderFeature.swift:154-158`) selects among exactly three modes:

| Mode | Local slot | Encoder abstains / sub-band |
|---|---|---|
| `.pickerBrain` | picker brain | n/a — encoder not in play |
| `.standaloneEncoder` | encoder alone | falls through to the router's own policy (band → escalation → re-prompt) |
| `.encoderFirstEscalate` | encoder first, picker as stand-in | **picker answers the same turn** |

And `localBrainSlot(...)` (`:174-194`) builds the chain, attaching a `Cascade` **only** for `.encoderFirstEscalate`, with `cascadeAcceptThreshold` defined as `IntentRouter.Config.default.acceptThreshold` (D-7).

**The flip is therefore exactly this:** `IntentEncoderPreferences.isCascadeEnabled` (`:106-109`) starts returning `true` on an untouched device. That is a one-line semantic change with a large blast radius, which is why §6.3 gates it.

### 6.2 What "default" has to mean, given the compile-time gate

The cascade cannot merely be defaulted at runtime: `#if INTENT_ENCODER` (`:54-60`) compiles the entire path out of a release build, and the file states its purpose — *"impossible for the encoder to become the local brain in a release build by accident."* So "encoder-first is the default" requires **both**:

1. `INTENT_ENCODER` becomes a condition on the shipping configuration, and
2. `isCascadeEnabled` defaults to `true`.

(1) is not a config edit — it is the decision that the encoder brain ships to users. It is gated by Stage 0 (§6.3). Recording this here matters because a reader could otherwise believe the flip is a UserDefaults default, when it also requires the release build to start constructing the interpreter.

**The runtime is wired, not design-only.** `IntentEncoderInterpreter` is constructed lazily behind `gatedEncoder` (`AppCoordinator.swift:1274-1306`), its artifact is `ModelCatalog.intentEncoderSpike` (`ModelCatalog.swift:266-285`, installed via `IntentEncoderSpikeInstaller`), and the tokenizer + `encoder_spike_meta.json` load through `IntentEncoderRuntime.load()` with an explicit UNAVAILABLE pair rather than an approximation on failure. The path is guarded by **four** independent gates: the compile condition, `intentEncoder.enabled`, `intentEncoder.cascade`, and artifact availability. Switching either persisted toggle reinstalls the chain on the **next turn, with no relaunch** (`AppCoordinator.swift:1211-1245`, `:1265-1270`) — which is what makes the A/B in §6.3 runnable and the kill switch in §6.6 real.

**What does *not* change.** `IntentRouter` (its band policy, its cloud escalation), `CommandRouter` (the net, the stage order), the confirmation flow, `TranscriptSanityGuard`, `IntentCommandCache` and the stand-in's own configuration are all untouched. The chain selects between two brains the router would consult anyway.

### 6.3 Flip gate conditions — numeric, on a named revision

**Stage 0 — the encoder may ship at all.** All eight gates, on corpus revision `7f71b8ae`, measured by the T-038 harness. Any one failing withholds the artifact and stops the discussion.

| # | Gate | Threshold | Source | Current | Status |
|---|---|---|---|---|---|
| 0.1 | `closed_intent_accuracy` | `≥ 0.95` | `config.yaml:58` | ~0.53 | **RED** |
| 0.2 | `slot_f1` (contact, time) | `≥ 0.90` | `config.yaml:59` | — | UNMEASURED — gap G-1 |
| 0.3 | `emergency_recall` | `== 1.00` | `config.yaml:60` | ~0.9375 | **RED** |
| 0.4 | `side_effect_precision` (call, send_message) | `≥ 0.97` | `config.yaml:61` | — | UNMEASURED — gap G-1 |
| 0.5 | `max_gap_vs_gemini` | `≥ −0.03` | `config.yaml:62` | — | UNMEASURED — gap G-1 |
| 0.6 | `abstention_precision` | `≥ 0.90` | `config.yaml:65` | — | UNMEASURED — gap G-1 |
| 0.7 | `calibration_tolerance` | `≤ 0.10` per bucket, `n ≥ 5`, underfloor `≤ 0.20` | `config.yaml:66-68` | — | UNMEASURED — gap G-1 |
| 0.8 | `emergency_recall_nearmiss` | `≥ 0.98` | `config.yaml:69` | — | UNMEASURED — gap G-1 |

**Stage 0b — robustness.** Both additive TG-11 gates, on the same revision.

| # | Gate | Threshold | Source |
|---|---|---|---|
| 0b.1 | order-invariance `A_ctrl − A_perm` | `≤ 0.03` | `T-065:18` |
| 0b.2 | dialect-robustness `max over claimed slices of (A_standard_twin − A_dialect_slice)` | `≤ 0.05` | `T-065:28` |
| 0b.3 | per-slice `side_effect_precision` | `≥ 0.97` | `T-065:30` |
| 0b.4 | per-slice `emergency_recall` | `== 1.00` | `T-065:30` |

**Stage 1 — the cascade leg must beat the standalone leg.** Paired A/B on the same device and revision; `.encoderFirstEscalate` versus `.standaloneEncoder`, and versus `.pickerBrain` (today's default). Every number below is produced by [T-071](T-071-cascade-latency-residency-measurement.md) and re-verified by [T-078](T-078-latency-residency-default-flip-verification.md) using the existing stage timers (`TurnTimingBreakdown.swift:50-69`).

| # | Condition | Threshold | Rationale |
|---|---|---|---|
| 1.1 | `A(encoderFirstEscalate) − A(pickerBrain)` | `≥ 0` on `closed_intent_accuracy` | The cascade may not be a quality regression against the brain it replaces. |
| 1.2 | `emergency_recall(encoderFirstEscalate)` | `== 1.00` | Unchanged hard gate; the cascade must not dilute it. |
| 1.3 | `abstention_precision(encoderFirstEscalate)` | `≥ 0.90` | The cascade escalates on abstention; a cascade that escalates on *everything* is a latency regression wearing a quality costume. |
| 1.4 | `escalation_rate` on the golden corpus | `≤ 0.35` | If more than a third of turns pay double-brain cost, the cascade is a net loss regardless of quality. **No shipped measurement today — gap G-2.** |
| 1.5 | `L_p95(encoderFirstEscalate) ≤ L_p95(pickerBrain)` | `≤` | The default must not be slower at p95 than what it replaces (NFR-002). |
| 1.6 | `L_p95(local leg)` | `≤ 2.0 s` | Encoder spec §10 local-leg budget (`IntentEncoderInterpreter.Config.timeoutSeconds`). |
| 1.7 | `L_p95(end-to-end: end-of-utterance → TTS start)` | `≤ 4.0 s` | NFR-002. |
| 1.8 | `escalation overhead = L(turn) − L(picker-direct turn)` on escalated turns | `≤ 200 ms` p95 | The cost of the decision + hand-off, isolated by the `cascade_decision` timer. |
| 1.9 | **Turn-level deadline enforced** | present, `≤ 4.0 s` | See §6.4 — the cascade as built has **no shared deadline**. This is a precondition, not a nice-to-have. |
| 1.10 | `peak RSS` with both brains resident | `≤` device avail-RAM floor | The `T-018-b` precedent: decline load below 2.5 GB available rather than OOM. |
| 1.11 | cold-start first-turn penalty | `≤ 2 ×` warm p95 | §6.5. |

**Flip rule.** Flip if and only if Stage 0 and Stage 0b are fully green **and** every Stage 1 condition holds. If any fails, the recorded outcome is **"not flipped"**, with the failing numbers written into the §14 evidence pack. Per D-8, a Stage 1 failure is a legitimate, reportable result — not a reason to re-tune a threshold until it passes. Re-tuning a Stage 1 threshold requires the same evidence discipline as authoring one.

### 6.4 Latency budget

The instrumentation is already built and already cascade-aware: `TurnTimingBreakdown` carries `stt_total`, `encoder_tokenizer`, `encoder_inference`, `encoder_decode`, **`cascade_decision`**, `picker_prompt_build`, `picker_inference`, `tts_start` (`TurnTimingBreakdown.swift:50-69`), and the coordinator records the cascade's decision span (`AppCoordinator.swift:1392`). The analysis below needs no new instrumentation — that is the point of using these numbers.

Three existing instruments cover the three measurement axes, and none of them needs to be built:

- **Per-stage, in-process:** `TurnTimingRecorder` / `TurnLatencyReporter` (`TurnTimingBreakdown.swift:142-240`, `:302-390`, component `turn_latency`, single event `turn_timing_breakdown` with `stages` metadata), wired at `AppCoordinator.swift:1689-1694` and gated on `IntentEncoderFeature.isEnabled`.
- **End-to-end, per turn:** `VoiceTurnLatencyTracer` (`component`/`event` `voice_turn_timing`, monotonic `ProcessInfo.systemUptime`), with marks `vad_fired` → `asr_done` → `router_done` → `speak_queued`/`speak_finished` (`VoicePipeline.swift:338`, `:827`, `:852`). This is the NFR-002 measurement: end-of-utterance (VAD) to TTS start.
- **Off-device, with the gates already in it:** `tools/train-intent/src/measure_device.py`, whose **defaults are the budget** — `--p50-gate-ms 1000.0`, `--p95-gate-ms 2000.0` (`:220-221`), nearest-rank `percentile()` (`tests/test_measure_device.py:52-61`), a cold/warm split (`:139-148`), and a non-zero exit with *"this build must not ship"* (`:270-294`). Condition 1.6 is that flag, unchanged; T-078 runs the harness rather than writing a new one. The budget's origin is `docs/T-033-encoder-bakeoff.md:78` (*"interpret p50 ≤ 1.0 s / p95 ≤ 2.0 s"*), carried into `IntentEncoderInterpreter.Config.timeoutSeconds = 2.0`.

**Per-mode budget, from the stage timers:**

| Mode | Local leg = | Notes |
|---|---|---|
| `.pickerBrain` (today) | `stt_total + picker_prompt_build + picker_inference` | the baseline to beat |
| `.standaloneEncoder` (encoder serves) | `stt_total + encoder_tokenizer + encoder_inference + encoder_decode` | the fast path, when it serves |
| `.encoderFirstEscalate` (escalates) | `stt_total + encoder_tokenizer + encoder_inference + encoder_decode + cascade_decision + picker_prompt_build + picker_inference` | the fast path **plus the entire baseline** |

**The structural finding: the escalate turn costs the encoder pass *plus* the picker pass — sequentially.** This is the double-brain cost, and it is inherent to a same-turn cascade: the chain cannot know the encoder will abstain until the encoder has run.

**The finding that makes it a gate: there is no shared deadline.** The encoder's timeout is 2.0 s with 0 retries (`IntentEncoderInterpreter.swift:168-169`), and the picker brain's is **10 s** with one retry (`LocalIntentInterpreter.swift:47-49`, encoder design §10 `:587-596`). `LocalBrainChain` passes no remaining-time budget to `standIn`. So the worst-case escalate turn is

```
2.0 s (encoder times out) + 10 s (picker times out) = 12 s
```

against NFR-002's 4 s — and against the intent-engine spec's *"Local … ≤ 3 s target"* (`2026-09-05-intent-engine-finetuned-llm-design.md:642`). In the mode where the user has already waited for one model to fail.

The encoder design already reasoned about exactly this class of problem and got it right for the encoder alone (F-1: *"a pass that exceeds the p95 budget has already missed the latency requirement and escalating is the better outcome than waiting"*, `:598-602`). The cascade reintroduces it at the turn level. **Condition 1.9 is therefore a precondition of the flip:** the chain must carry a turn-level deadline and pass `remaining` to the stand-in, so the escalate turn is bounded by the turn budget rather than by the sum of two independent timeouts. T-073 specifies it; T-076 implements it; T-078 verifies it.

**Why not just lower the picker's timeout?** Because `LocalIntentInterpreter`'s 10 s serves the `.pickerBrain` default too, where it is the only brain and a slow answer beats no answer. The fix belongs in the chain (a per-turn budget), not in the brain's own config.

### 6.5 Failure modes

**Double-brain cost per turn.** Bounded by condition 1.4 (`escalation_rate ≤ 0.35`). The cost is not only latency: two forward passes per escalated turn is two memory-touching passes, and on the oldest supported device the second pass is what competes with TTS for the CPU. `TurnTimingBreakdown` makes the per-turn numbers attributable, and `onEscalated` makes the *rate* attributable by reason (`abstained` vs `failed` vs `subBandConfidence`) — which matters, because a `failed`-heavy escalation rate is a different problem (the encoder is timing out) from a `subBandConfidence`-heavy one (the calibration is off).

**Memory residency.** Both brains resident simultaneously is the cascade's standing cost, paid on every turn, not only escalated ones. The `preferred` encoder is a ~100 MB-class int8 artifact (T-033's C3 int8 zip is 109 079 441 B per the T-036 record), and the picker is a multi-GB 4B model. Condition 1.10 requires the measured peak to stay under the device's available-RAM floor, following the shipped `T-018-b` rule (*"decline load if < 2.5 GB available with user-visible notice"*, `plan.md` risk 2). The failure mode to design against is not a crash but the OS evicting the picker between turns, turning every escalated turn into a cold load. T-071 measures the residency curve; T-073 specifies the corrective.

**Cold start.** Three distinct cases, and only the first is benign:

1. *Encoder artifact still loading on first use* — already handled: `retryOnArtifactLoadRace` allows exactly one retry (`IntentEncoderInterpreter` Config, encoder design §10 `:583`).
2. *Artifact not installed* — already handled: `isAvailable` is false, the chain's availability rule selects the stand-in, and no escalation is attempted. This is the "fail soft for free" property the encoder design calls out (`§10.1:608-613`).
3. *Both brains warming after a cold launch* — **not** handled, and it is the case where the cascade is worst: the encoder's first pass pays model load, then the picker's first pass pays its own. Condition 1.11 bounds it at `≤ 2 ×` the warm p95, and T-073 must specify whether the first turn after a cold launch is served picker-first (a one-turn opt-out), because that is the only turn where the cascade's ordering is strictly harmful.

**A fourth case the design names but does not solve.** A `subBandConfidence` escalation hands the turn to a picker brain that may return the *same* action — in which case the user waited for the encoder and the picker to agree. This is not a defect, but it is a measurable waste, and T-071 records the agreement rate as part of the Stage 1 evidence rather than leaving it as an argument. If the agreement rate is high and the latency cost is real, the honest conclusion is to serve the sub-band answer into the existing confirmation flow — which is what `bandChecked` already does for tier-`.confirm` actions (`IntentRouter.swift:316-330`) — rather than escalate.

### 6.6 Kill switch and observability

**The kill switch already exists and is the right shape.** `DialectBiasSettings` is the precedent (`DialectBiasComposer.swift:75-94`): a UserDefaults toggle, default enabled, described as *"an inspection/escape hatch, not an opt-in gate"*, with the property that *"when disabled, the recognizers behave exactly as they did before adaptation existed, and say so once per session."*

The cascade's kill switch is `IntentEncoderPreferences.setCascadeEnabled(false)` (`IntentEncoderFeature.swift:111-113`) — flipping the default does **not** remove the ability to turn it off per device, and turning it off restores `.standaloneEncoder`, which is a mode that has already been exercised by the internal A/B. The canonicalizer's is `Policy.enabled` (§4.2), with `orthographicOnly` as the intermediate conservative arm.

**Observability, fixed vocabulary, no content.** `onEscalated` already reports the three `EscalationReason` values as metadata (`LocalBrainChain.swift:36-40`: *"Metadata only, never transcript or reply content (C9 policy)"*). The canonicalizer adds its own event, and it must obey the same rule: **rule id, table id, kind, and counts — never the original or canonical surface forms.** This matters more here than anywhere else in the pipeline, because the strings being rewritten are, by construction, the user's own words. NFR-016 is a hard constraint, and T-049/T-050 are the binding precedent for how leaks in this area are treated (the `security-test` re-run after their remediation returned `SECURITY-GO`, `constitution.md:126`).

---

## 7. TG-10 integration — the glue

TG-10 built the loop; this group *joins* it. Nothing in this section redesigns the loop.

**Why these artifacts are eligible.** Both the variant tables and the encoder's calibration are **data files replaced without an app change** — the property `DialectBiasComposer.swift:104-105` already claims for the lexicon and the centroid table. The calibration temperature ships in the artifact's `meta.json` as `calibration_temperature` and is applied in code rather than baked into the graph, precisely so it stays *"reviewable, diffable and recorded in the T-036 run manifest"* (encoder design §5, `:283-288`). That is exactly the eligibility criterion the promotion gate operates on.

**What the loop may propose:**

1. **New variant-table entries** from corrections. A user saying the same thing twice — once mis-transcribed, once corrected — is a live variant pair. TG-10's `T-057` correction miner turns those into validated rows; a rule derived from them enters a table as a **candidate entry** with `evidence.source: "fixture"` and its cited examples.
2. **Frequency corrections to existing entries** — an entry whose `occurrences` on live traffic diverges sharply from its corpus count is a candidate for retirement, which is how a table stays small.
3. **`calibration_temperature` deltas** — a re-fit on new data.

**What the loop may never do:**

- **Publish without the gate.** A candidate table is promoted only through TG-10's promotion rule — *"all eight T-038 gates pass AND the candidate beats the incumbent on the corpus-revision-bound eval"* (`2026-09-13-continuous-learning-loop-design.md:404-405`), with UNEVALUATED failing closed (`eval_golden.py:814-815`) and a human performing the publish (D-4 of that design). A variant table that makes the encoder worse is caught by the same gate that catches a worse encoder.
- **Modify the band policy.** TG-10 invariant 3 stands unchanged: *"No new threshold. The band policy … is not modified by the loop; divergence is telemetry, and a divergence rate never becomes a runtime decision by itself"* (`:438-440`). This design honours it and D-7 restates it: the cascade's threshold *is* `IntentRouter.Config.default.acceptThreshold`, so there is nothing separate to tune. The loop may re-fit `calibration_temperature` — which moves *confidence*, and therefore which band a given output falls into — and it may never move the band itself.
- **Carry content off-device.** A candidate variant pair contains the user's words. TG-10's egress is hashed-only (D-2 of that design) and *"a hash of a low-entropy utterance is a pseudonym, not anonymity"* (`:375`). A table entry derived from a user's utterance is therefore a **content-bearing artifact** and must not be reconstructed from the hashed channel. Concretely: the loop may carry the *fact* that a candidate rule is warranted and the *counts*; the surface forms are authored on-device or by the linguistic pipeline, and the egress contract is unchanged. **This is the one genuinely new privacy question this design raises and it is marked as gap G-3** rather than answered here — it belongs to TG-10's `T-053` privacy basis and its `T-059` audit.

**Where it lands.** `T-079` binds the two: registers the variant tables and `calibration_temperature` as promotion-gated artifacts in the loop, and adds the variant-table revision to the run manifest alongside the corpus revision, so a promoted artifact records which table revision produced its numbers. Without that binding, a table change would be an invisible input to a gated number — the one thing the promotion rule cannot tolerate.

---

## 8. Boundaries and invariants

1. **The safety net reads the original, forever.** D-1, enforced by §4.7 and by `negationMarkerTouched` at authoring time.
2. **No new intent label, BIO tag, head or gate.** 12 labels and 13 tags are closed (`annotation_rules.yaml:28-49`, `:106-109`). TG-11's two robustness gates are the only additive gates, and they are TG-11's.
3. **No threshold is introduced or moved.** D-7. `acceptThreshold 0.7` / `rephraseThreshold 0.4` are read, never written.
4. **The corpus does not move.** 8 000 rows and revision `7f71b8ae` stay byte-identical; canonicalization changes model *input*, never the corpus.
5. **No PII, no content, in any event, log or manifest.** NFR-016; rule ids and counts only, never surface forms. T-049/T-050 are the standard.
6. **One normalizer per purpose.** The cache/resolver key keeps `NepaliTextNormalizer`; the model input gets the canonicalizer. They are not merged (§4.6).
7. **Fail-soft everywhere.** A corrupt table canonicalizes nothing; a missing encoder serves the picker; a missing dialect table uses the pan-regional set; a failed escalation is today's behaviour. There is no path where a canonicalizer or cascade defect produces *no* answer.
8. **Evidence or gap.** D-8. §14 is the ledger, and `UNMEASURED — gap` is a legitimate entry.
9. **Android is out of scope.** iOS MVP; the encoder's Android runtime (`T-037-b`) is unaffected.

---

## 9. Options weighed

### 9.1 Where canonicalization runs

| Option | Verdict |
|---|---|
| **Inside the encoder interpreter, post-sanitiser** (chosen) | Keeps the net and the cache on the original by construction; one seam to test; the 4B rung is untouched (§4.6). |
| At the top of `CommandRouter.route`, shared by every stage | **Rejected.** Puts a table lookup upstream of the keyword net and the injection sanitiser, and re-keys the intent cache. This is D-1's motivating counter-example. |
| Inside `WhisperKitSpeechRecognizer`, post-decode, pre-`route` | Rejected. Rewrites the transcript the *net* sees, and makes the canonical form the value `IntentLogStore` records — turning a model-input transform into a transcript-of-record. |
| As a separate router stage before the interpreters | Rejected. A new stage in a safety-critical ordering, for a transform that only one consumer needs. |

### 9.2 Table granularity

| Option | Verdict |
|---|---|
| Per validated dialect region + pan-regional + orthographic (chosen) | Matches the shipped one-file-per-concern resource pattern; a region can be added without touching another. |
| One merged table with a `dialect` field per entry | Simpler loading; but a corrupt entry in one region's block fails the whole table, against D-4's fail-closed-per-table intent. |
| A single pan-regional table with no dialect axis | Rejected: loses the ability to *not* apply an eastern rule to a Doteli speaker, which is the one direction that must never move (§4.3). |

### 9.3 Where the cascade's fallback lands

| Option | Verdict |
|---|---|
| Encoder → picker brain, same turn (chosen) | Already built; `escalation_rate` and latency gates bound the cost. |
| Encoder → confirmation flow for the sub-band, picker only on abstention | **Measured alternative**, not a decision: §6.5's fourth case. If the agreement rate is high, this is strictly better and T-071's numbers decide it. |
| Encoder → cloud | Rejected as the *default*: it is today's `.standaloneEncoder` behaviour, and it makes a local quality problem into a privacy-path decision (Open Decision 12 / Arch. Constraint 1). |
| Encoder alone, no fallback | Rejected: an abstention then reaches the user as a re-prompt, which is the behaviour the incumbent silently avoids today. |

---

## 10. Deliberately out of scope

- **Retraining the encoder.** No T-036 chain entry. Whether canonicalization justifies a retrain is a group-end decision on evidence, not an assumption — and the encoder's own gates are red, so there is nothing to retrain onto yet.
- **A learned normalizer.** D-2.
- **Per-user canonicalization profiles.** Attractive (a household's own dialect) and refused here: it would make a safety-adjacent transform household-specific, and the evidence to justify it does not exist.
- **Extending the dialect inventory.** TG-11's `T-062`.
- **Changing `DialectCentroids.json` or `DialectLexicon.json` content.** Consumed as-is; their prompts are empty and their status is SEED (§4.3) — populating them is the accent-adaptation pipeline's work, not this group's.
- **`IntentRouter` or `CommandRouter` edits of any kind.**
- **Android.**

---

## 11. Requirements traceability

| Task | Requirements |
|---|---|
| T-070 | FR-005, FR-008, NFR-002 |
| T-071 | NFR-001, NFR-002, FR-007 |
| T-072 | FR-005, FR-007, FR-008, NFR-013 |
| T-073 | FR-007, FR-008, NFR-002 |
| T-074 | FR-005, FR-008, NFR-002 |
| T-075 | FR-005, FR-007, FR-008, NFR-013 |
| T-076 | FR-007, FR-008, FR-009, NFR-002 |
| T-077 | FR-009, NFR-013, NFR-016 |
| T-078 | FR-007, FR-008, FR-009, NFR-001, NFR-002 |
| T-079 | NFR-015, NFR-016, NFR-029 |

FR-009 (safety paths not dependent on the LLM) is carried by T-076/T-077/T-078: no cascade mode and no canonicalizer rule may gate the emergency path, and T-077's gate is the enforced form of that. NFR-016 is carried by T-077 and T-079: rule ids and counts may be logged, surface forms may not.

**FR-005 is the closest-matching product requirement** — *"The system must support accent and regional dialect personalisation for Nepali speakers. During onboarding the user provides voice samples; the STT model fine-tunes to the individual's accent. Accent tuning data is stored on-device only."* (`requirements.md:30-31`). The shipped answer to FR-005 is the dialect-ID-plus-decode-biasing path (`DialectIdentifier` + `DialectBiasProfile` + the seed lexicon/centroid tables, `docs/research-sections/accent-adaptation.md` §6 P0), because the per-user on-device fine-tune was re-scoped as not implementable (*"no whisper.cpp/WhisperKit runtime LoRA; MLUpdateTask impractical"*, `docs/voice-personalisation-research.md:16`). The canonicalizer is the **downstream half** of that answer: the recognizer is biased toward the user's dialect, and the canonicalizer maps what it emits onto the forms the intent model knows. Both are on-device, both are data-driven, and neither transmits accent data — FR-005's on-device-only clause holds.

**Not claimed.** This group does not improve the emergency path's *execution*. `handleEmergency()` is a spoken acknowledgement plus a local notification; the emergency-call module does not exist and B4/B6 were descoped by human decision (`constitution.md:123`). Canonicalization and the cascade change nothing about that either way, and no claim in this document should be read as strengthening emergency dispatch.

---

## 12. Task mapping

| ID | Title | Phase | Effort | Risk |
|----|-------|-------|--------|------|
| T-070 | Dialectal-Variant Coverage Measurement | R&D | S | MEDIUM |
| T-071 | Cascade Latency, Residency & Cold-Start Measurement | R&D | M | HIGH |
| T-072 | Canonicalizer Rules Schema & Composition Design | design | M | HIGH |
| T-073 | Cascade-Default Policy & Flip-Gate Design | design | M | HIGH |
| T-074 | Variant-Table Authoring & Native-Speaker Validation | implementation | L | HIGH |
| T-075 | DialectCanonicalizer Implementation & Pipeline Composition | implementation | L | HIGH |
| T-076 | Cascade-Default Implementation (flip + kill switch) | implementation | M | HIGH |
| T-077 | Canonicalization-Losslessness & Safety-Regression Verification | verification | M | HIGH (SAFETY) |
| T-078 | Latency, Residency & Default-Flip End-to-End Verification | verification | L | HIGH |
| T-079 | TG-10 Loop Binding | glue | M | MEDIUM |

**Task IDs are T-070 onward, not T-062 onward — and the group is ten tasks, not eleven.** The brief assumed `T-062` was free; it is not. `T-061`–`T-069` are TG-11's, drafted in parallel (`.claude/worktrees/tg11-robustness/.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/`, unmerged; its ninth task, the evidence pack, is `T-069`). `T-080`–`T-089` are TG-13's, also drafted in parallel (`.claude/worktrees/tg13-benchmark/…`), and TG-13 already links into this group from its own index. That leaves exactly `T-070`–`T-079` free, ten contiguous IDs.

Two consequences, both recorded rather than absorbed silently:

1. **The whole group shifts by one**, keeping the brief's phase order and titles. This mirrors the precedent TG-10 recorded when `T-051` was already taken (`specs/TG-10-notes.md`: *"the whole group shifted by one, keeping the brief's phase order and titles exactly"*).
2. **Two verification tasks merged into one.** The brief's list had latency-budget verification and default-flip end-to-end verification separate; with ten IDs and eleven tasks, they are one task (T-078) with two labelled scenario groups. The merge is defensible on its merits — both are post-flip verification on the shipping configuration, sharing one run and one measurement set, and T-078's full-gate-set evaluation already contains the latency conditions. It is recorded here because it is a real loss: T-077 (safety) and T-078 (latency + end-to-end) are now the group's only two verifications, so the safety verification must not be folded further.

The safe-verification separation that mattered most is preserved: measurement (T-070, T-071) is still independent of the decisions it feeds (T-072, T-073), and verification (T-077, T-078) is still independent of implementation (T-075, T-076).

---

## 13. Risks and mitigations

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R-1 | A cascade escalate turn can reach **12 s** (2 s encoder timeout + 10 s picker timeout) against NFR-002's 4 s, because `LocalBrainChain` passes no shared deadline. | **HIGH** | Stage 1 condition 1.9 makes a turn-level deadline a **precondition of the flip**. T-073 specifies, T-076 implements, T-078 verifies. Not a fix in this document. |
| R-2 | The shipped encoder's gates are red (`emergency_recall` ~0.9375 against a 1.00 hard gate). | **HIGH** | Stage 0 is a precondition, not a formality (D-6). The cascade's flip is unreachable while any gate is red, and `#if INTENT_ENCODER` keeps the path out of release builds meanwhile. |
| R-3 | A variant rule collapses a negated form onto its positive (`नखाए` → `खाए`), producing a wrong medication acknowledgement. | **HIGH (SAFETY)** | §4.7's frozen set + `negationMarkerTouched` at authoring time + T-077's two-clause equality gate, with a failing fixture required before it is trusted to pass. |
| R-4 | A `contact` span crossing a rewritten region maps ambiguously and resolves to the wrong person. | **HIGH (SAFETY)** | §4.5: substitutions preferred in authoring; widened **required** spans abstain rather than resolve. |
| R-5 | Canonicalization measures **+0** on some dialect slices. | MEDIUM | D-8: the zero is printed, the slice is recorded as uncovered, and the flip condition is allowed to fail on it. Not a reason to widen the rules. |
| R-6 | Variant tables derived from user corrections become a content-bearing artifact riding a hashed egress channel. | MEDIUM | §7: counts and rule-warranted facts may egress, surface forms may not. **Gap G-3** — referred to TG-10's T-053/T-059, not answered here. |
| R-7 | The dialect taxonomy is unsettled (shipped: `eastern`, `doteli`; TG-11 hypothesis: five values). | MEDIUM | D-9: TG-12 consumes T-062's resolution; §4.3's fallback (pan-regional + orthographic) is safe with an unsettled taxonomy, and a wrong label can only fail to fire a rule — never fire another region's. |
| R-8 | Both brains resident evicts the picker between turns; escalate turns become cold loads. | MEDIUM | Stage 1 condition 1.10 (peak RSS ≤ device floor) and 1.11 (cold-start ≤ 2× warm). T-071 measures the curve. |
| R-9 | Observability leaks a surface form, which here *is* the user's utterance. | MEDIUM | §6.6: rule ids, table ids, kinds and counts only. T-049/T-050 are the precedent, and T-077/T-078 assert the absence. |
| R-10 | Canonicalization is applied to the picker rung later, silently, and invalidates §6's measured baseline. | LOW | §4.6 records the decision; a change there requires its own A/B and its own evidence row. |
| R-11 | **The accept band exists as three independent 0.7s, not one.** `IntentRouter.Config.default.acceptThreshold` (`:56-58`), `IntentEncoderWiring.cascadeAcceptThreshold` (derived, `:163`, and pinned by `IntentEncoderWiringTests.swift:336-342`), and a **hard-coded literal** in `CommandRouter.swift:1139-1155` (`if command.confidence < 0.7`), which is not derived from the constant. D-7's "one number, not two" is true of the cascade and the router, and not true of the rephrase-question site. | MEDIUM | The flip does not touch the band, so this is not a flip blocker. It is recorded because "the encoder serves at exactly what the router bands at" is a claim the design leans on (D-7, §6.1), and a future band change would need to reach all three sites. T-073 records the disposition; the repair is out of this group's scope (a `CommandRouter` edit). |
| R-12 | The **picker brain's** default is itself inconsistent: `AppCoordinator.defaultBrainModelID` names `intentQwen4BS43` (`:1516`) while the catalog's slot-canonical entry documents that it *"replaces `intentQwen4BS43` as the default"* and is the Nepali language default (`ModelCatalog.swift:242-248`, `:1254-1257`). | LOW | Out of scope — this is the picker's default, not the cascade's, and the two must not be conflated when the word "default" is used. Recorded so that a reader of §6 does not mistake the cascade flip for the brain-catalogue default, and so whichever task reconciles the catalogue (TG-03's `T-048` territory) sees it. |

---

## 14. Evidence pack

The ledger. `claim → measurement → threshold → fixture id → corpus evidence`. Any row without a measurement is `UNMEASURED — gap`, with the gap's requirements named. Following the T-033 precedent (`tools/train-intent/docs/t033-evidence/`), this ships as machine-readable evidence under `tools/train-intent/docs/tg12-evidence/` so the numbers are re-runnable rather than transcribed.

| # | Claim | Measurement | Threshold | Fixture / id | Corpus evidence | Status |
|---|---|---|---|---|---|---|
| E-1 | Variant coverage is known before authoring | count of variant occurrences, per `script` slice, per candidate rule | every authored `source: corpus` rule has `occurrences ≥ 1` | T-070 report | `eval/golden_corpus.jsonl` @ `7f71b8ae` (8 000 rows; dev 5 508 / latin 1 678 / cs 814) | **UNMEASURED — gap G-4** |
| E-2 | Each authored rule is sourced | per-entry `evidence` block validated by `issues()` | `source` ∈ {corpus, fixture, authored}; corpus ⇒ `occurrences ≥ 1`; else ⇒ `fixtureExamples ≥ 2` | `VariantTables/*.json` | as E-1 | **UNMEASURED — gap G-4** |
| E-3 | Canonicalization is safety-lossless | `matches(canonical) == matches(original)` over the net's own matchers | **100 %** of rows, both clauses | `losslessness_fixture.jsonl` (new, T-077) | emergency 17 phrases (`CommandRouter.swift:1468-1473`) + med-ack and denial token lists (`:1508-1534`), matched via `containsPhrase` `:1439` / `containsToken` `:1448` | **UNMEASURED — gap G-5** |
| E-4 | The E-3 gate can fail | a deliberately unsafe rule (`नखाए` → `खाए`) trips it | run exits non-zero and names the row | same fixture, negative arm | — | **UNMEASURED — gap G-5** |
| E-5 | Canonicalization does not move the corpus | `sha256(golden_corpus.jsonl)[:8] == 7f71b8ae` after all changes | byte-identical | — | `eval_golden.py:606` | **HOLDS** (design constraint; verified each run) |
| E-6 | Canonicalization buys accuracy on dialect slices | `A_canonical − A_uncanonicalized`, per dialect slice | `≥ 0` per slice, else the slice is reported uncovered | TG-11 dialect fixture (`eval/dialect_holdout.jsonl`, TG-11 `T-064`) | `dialect`/`style` row metadata, TG-11 `T-063` | **UNMEASURED — gap G-6** (no canonicalized corpus exists yet) |
| E-7 | Encoder artifact clears the eight gates | harness run on `7f71b8ae` | `config.yaml:58-69` | T-038 harness | — | **RED** (`closed_intent_accuracy` ~0.53, `emergency_recall` ~0.9375; `IntentEncoderFeature.swift:6-8`) |
| E-8 | Robustness gates pass | order-invariance and dialect-robustness | `≤ 0.03` / `≤ 0.05` | TG-11 `T-065` | — | **UNMEASURED — gap G-7** (gates not wired) |
| E-9 | Cascade escalation rate is bounded | escalated turns / total turns, by `EscalationReason` | `≤ 0.35` | T-071 harness run | golden corpus, replay | **UNMEASURED — gap G-2** (never measured) |
| E-10 | Cascade p95 is no worse than picker-direct | `L_p95` both modes, `TurnTimingBreakdown` | `≤` | T-071/T-078 | device run | **UNMEASURED — gap G-2** |
| E-11 | End-to-end latency meets NFR-002 | end-of-utterance → TTS start, p95 | `≤ 4.0 s` | T-078 | device run | **UNMEASURED — gap G-2** |
| E-12 | Escalate turns are bounded by a turn deadline | presence of a turn-level deadline; worst-case escalate turn | `≤ 4.0 s` | T-078 | — | **FAILS BY INSPECTION** (§6.4: 2 s + 10 s, no shared deadline) |
| E-13 | Peak RSS with both brains resident stays under the device floor | peak RSS during a cascade run | `≤` available-RAM floor (`T-018-b` precedent: 2.5 GB) | T-071 | device run | **UNMEASURED — gap G-2** |
| E-14 | Cold start is bounded | first-turn p95 after cold launch / warm p95 | `≤ 2 ×` | T-071 | device run | **UNMEASURED — gap G-2** |
| E-15 | No surface form reaches the log | sweep of emitted events under a cascade run | zero content-bearing fields | T-078 sweep | NFR-016; T-049/T-050 precedent | **UNMEASURED — gap G-8** |
| E-16 | Tables and calibration ride the loop's gate | table revision recorded in the run manifest; promotion refuses on any gate | all gates + beats incumbent | T-079 | `run_encoder_pipeline.py` decision | **UNMEASURED — gap G-9** |
| E-17 | Picker rung is unchanged by canonicalization | stand-in receives the original sanitised transcript | identity | T-075 test | §4.6 | **HOLDS BY DESIGN** |

| Gap | What is needed to close it | Owner |
|---|---|---|
| G-2 | Device runs of the paired A/B on the reference device. **No new instrumentation**: `measure_device.py` already carries the p50/p95 gates (`:220-221`) and the cold/warm split (`:139-148`), `TurnTimingBreakdown` the per-stage spans, `VoiceTurnLatencyTracer` the end-to-end turn. The gap is that nobody has run the comparison, not that the tools are missing. | T-071 |
| G-4 | T-070's coverage measurement over the pinned corpus; no authoring before it. | T-070 |
| G-5 | The losslessness fixture does not exist. Needs: the net's own matcher list extracted as data, plus synthetic rows covering each frozen marker and each emergency phrase, plus a negative arm. | T-077 |
| G-6 | Cannot be measured until a canonicalized corpus exists — i.e. after T-075. Sequences after implementation by construction. | T-078 |
| G-7 | TG-11's two gates must be wired first. | TG-11 `T-065` |
| G-8 | The observability sweep is a new assertion; the bus exists. | T-078 |
| G-9 | Registration of the tables + `calibration_temperature` as promotion-gated artifacts in `run_encoder_pipeline.py`. | T-079 |
| G-1 | Stage 0 gates 0.2/0.4–0.8 are unmeasured for the shipped artifact; the reported failures are partial. A full harness run on `7f71b8ae` closes it. | T-038 / TG-08 |
| G-3 | The privacy question §7 raises: whether a variant pair derived on-device is content under TG-10's D-2 egress contract. | TG-10 `T-053`/`T-059` |

**Gaps G-1, G-2, G-4 and G-7 must close before the flip can be evaluated at all.** G-5 must close before canonicalization ships in any debug path, because R-3 is a safety failure, not an accuracy one.

---

## 15. Open questions

1. **Does canonicalization pay for itself on this encoder?** E-6 is unmeasurable until a canonicalized corpus exists, and the honest prior is that a 117M-parameter student trained on the standard forms in `annotation_rules.yaml:216` may generalise to some attested variants without help. The design is built so that a "+0" answer is a legitimate, printable outcome (D-8) — but a reader should know that the *expected* effect size is unmeasured, and that the mechanism's value may turn out to be concentrated in the orthographic rules (O-1/O-5/O-6) rather than the dialect tables.
2. **Is `escalation_rate ≤ 0.35` the right bound?** It is a chosen number, not a measured one. It exists so the flip condition is numeric, and T-071's first run should be treated as evidence *about the threshold*, not only about the artifact.
3. **Does the sub-band belong in the confirmation flow rather than the cascade?** §6.5's fourth case. `bandChecked` already routes tier-`.confirm` sub-band actions into the confirmation flow (`IntentRouter.swift:316-330`); doing the same for tier-`.free` actions would avoid the double-brain cost entirely, at the price of a spoken confirmation. T-071's agreement rate decides it.
4. **What happens when the enrolment dialect label is wrong?** §4.3 guarantees a wrong label can only fail to fire a rule. Whether the *silent* failure is acceptable, or whether the provenance's low-confidence marking should surface, is a UX decision for T-072.
5. **Does the picker rung eventually want canonical input?** §4.6 says no today, on measurement grounds. If dialect-corrupted utterances are disproportionately the *long tail*, the encoder never sees them and the picker always does — which would invert the argument. This is a real possibility and T-071's reason breakdown (`subBandConfidence` vs `abstained`) is what would reveal it.
