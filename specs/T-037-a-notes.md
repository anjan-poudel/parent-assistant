# T-037-a — IntentEncoder Runtime, iOS (CoreML + ModelStore)

Branch `worktree-t037a-ios-encoder`, commit `e293454` (base master `840bcd7`).
Milestone: an internally testable encoder path selectable behind
`CommandInterpreter`. Shipped default unchanged.

## What was built

Groundwork/scaffolding only — the encoder is wired but OFF:

- **`IntentEncoderSchema.swift`** — schema-v2 action allow-list (12 actions)
  and `IntentEncoderSlotType` (contact / time / medication / message / topic /
  app), `IntentEncoderManifest` with tag decoding, and
  `IntentEncoderManifest.t033Spike` for the T-033 C3 artifact.
- **`IntentEncoderTokenizer.swift`** — `IntentEncoderTokenizing` seam plus
  `UnavailableIntentEncoderTokenizer`, the honest gap: no Swift WordPiece vocab
  exists for the spike model yet, so the production path reports unavailable
  rather than faking tokenisation.
- **`IntentEncoderCoreMLModel.swift`** — mlprogram runner: int32
  `input_ids` / `attention_mask` shaped `[1, <=64]`, reads `intent_logits` and
  `slot_logits`; content-free errors, no force-unwraps.
- **`IntentEncoderInterpreter.swift`** — `CommandInterpreter` +
  `InterpreterFailureReporting`. Pipeline: keyword safety net upstream →
  `InputSanitiser.sanitise(_:level:.quarantine)` → tokenize → CoreML → decode.
  Span validation is strict: offsets are unicode scalars in the sanitised
  transcript, `text == sanitisedTranscript[start..<end]` verbatim, slot types
  and actions must be in schema-v2. Any violation abstains (nil), never
  fabricates a slot. Empty-after-sanitise abstains. Configurable timeout
  returns nil and sets `lastInferenceFailureReason`. Memory-pressure warning
  unloads; next use reloads from ModelStore. Observability carries model id /
  version / duration / outcome only — no transcript text.
- **`IntentEncoderFeature.swift`** — `#if INTENT_ENCODER` gate and
  `IntentEncoderWiring.preferredLocalBrain(encoder:fallback:)`, an
  identity-preserving fallback when the gate is off.
- **`ModelStore` / `ModelCatalog`** — `.intentEncoder` kind with a scoped
  destination (never next to whisper.cpp `.mlmodelc` files), zip SHA-256
  verified before unpacking; mismatch throws `ModelStoreError.checksumMismatch`
  and emits `coreml_encoder_checksum_mismatch`. Catalog entry is marked
  internal-testing only (not in `availableBrainEntries` / `availableSTTEntries`).
- **`AppCoordinator`** — lazily offers the encoder into
  `LocalBrainChain(preferred:standIn:)` only when the gate is on and the
  artifact is installed; memory-warning observer; re-arm on
  `.capturingCommand`. No shipped default changed.

## Verification

Canonical gate, run in the worktree (`ISO test derived data under /tmp`):

```
cd <worktree>/ios && IOS_TEST_DERIVED_DATA=/tmp/t037a-dd ./build.sh test:unit
```

Real counts from `xcrun xcresulttool get test-results summary`
(`/tmp/t037a-dd/Logs/Test/Test-ElderlyAssistant-2026.09.13_10-27-10-+1000.xcresult`):

```
{'result': 'Passed', 'totalTestCount': 2744, 'passedTests': 2735,
 'failedTests': 0, 'skippedTests': 9, 'expectedFailures': 0}
```

51 new cases, all passing (`xcrun xcresulttool get test-results tests`):
`IntentEncoderInterpreterTests` 24, `IntentEncoderWiringTests` 10,
`IntentEncoderDecoderTests` 9, `IntentEncoderArtifactTests` 8.

Coverage of the requirements: unavailable-without-artifact and
unavailable-tokenizer paths; Gherkin span mapping pinned verbatim to the
sanitised transcript; sanitised spans never come from stripped markers;
abstention on low confidence / unknown action / unknown slot type / misaligned
words / empty sanitise; timeout returns nil with a machine reason, is never
retried, and delivers exactly one completion; artifact-load-race retried once;
persistent load failure stops after one retry; memory-pressure unload/reload
and re-arm; observability whitelist (model id / manifest id / version /
duration / outcome, no transcript); safety net — an emergency keyword never
consults the encoder or the stand-in, and neither does an explicit medication
ack; router accepts a confident encoder command without cloud, and escalates
to cloud on encoder timeout; gate-off default pinned so this build ships the
old path; artifact delivery incl. destination scoping away from whisper,
before/after URL identity, strict checksum abort, delete, stale-sweep safety.

## The spike artifact

Kept outside the repo and outside `/tmp`, uncommitted (109 MB binary), at
`~/.local/share/elderly-ai/t033-spike/t033-encoder-int8-mlmodelc.zip` (the
tester's home directory; the path is deliberately no longer committed — see
the fix round below). The supported internal-testing route passes the zip
directly to `ModelStore.installCoreMLEncoder(fromZip:for:)`.

Verified again during this task: 109,075,268 bytes, SHA-256 prefix
`6056ba41ba37`, a single top-level `t033-encoder-int8.mlmodelc`
(`coremldata.bin`, `metadata.json`, `model.mil`, `weights/weight.bin`
118,429,760 bytes). The full digest lives only in the catalog entry, where it
is functionally required for install verification.

The spike is labelled honestly: it is the legacy LLM-format 10-intent dataset
(no schema-v2 actions such as `create_calendar_event`, contact/time tags only),
NOT the T-035 schema-v2 BIO training set. Tests pin exactly this —
`testSpikeManifestIsHonestAboutItsLabels`. The logit-index order the decoder
depends on is committed checkably at
`tools/train-intent/docs/t033-evidence/C3-label-order.json` (intents, tags,
`max_len`), so the manifest can be verified in-repo against the training run
without the external `meta.json`.

## Decisions

- **Scoped ModelStore destination** (T-035 §15.2): `ModelKind.intentEncoder`
  is the artifact's own URL space, so a spike encoder can never be
  auto-loaded by whisper.cpp. Regression pinned both ways.
- **`URL.appendingPathComponent` is filesystem-aware** on Darwin: the same
  call returned `…mlmodelc` before install and `…mlmodelc/` after. Fixed by
  passing `isDirectory:` explicitly and pinned with
  `testFinalURLIsTheSameValueBeforeAndAfterInstall`.
- **T-035 contract folded in**: `retryOnArtifactLoadRace` (one load-only
  retry), `maxRetries` 0 for timeouts/abstentions, offsets in unicode scalars
  over the sanitised transcript, `calibration_temperature` (divide-then-
  softmax, default 1.0, applied in the interpreter).
  **Known contract/artifact mismatch for T-036 to reconcile**: the contract
  specifies int64 `input_ids`/`attention_mask`; the only compiled artifact's
  `metadata.json` declares Int32 `[1, 1...64]`, so the runner uses Int32. A
  schema-v2 export must either keep Int32 (and amend the contract) or the
  runner must follow the artifact it is loading.
- **`InputSanitiser` quarantine level** before inference, and spans are always
  slices of the sanitised text (never the raw transcript).
- **No `MedicationResolver`** exists under `ios/` (T-035 §15.1); the schema
  exposes a `medication` slot type, and nothing in this task invents a
  resolver.

## Explicit contract non-conformances (must land before any schema-v2 manifest is wired)

These are NOT "deferred nice-to-haves": with a schema-v2 manifest in place
each one would silently mis-map a real span/action, so they are blockers for
enabling the encoder beyond the spike.

1. **`.app` is not projected (T-035 §7.1).** The current mapping copies the
   `app` span verbatim into `InterpretedCommand.requestedApp` and leaves
   `callType` nil. The contract requires a closed-vocabulary projection
   (`whatsapp`/`facetime`/…) plus a derived `callType` (`voice`/`video`).
   Unreachable with the spike (its tag head has no `app` tag), latent with
   any schema-v2 manifest.
2. **`contact` is not clitic-trimmed (T-035 §7.2).** The contract trims
   Nepali clitics (`छोरालाई` → `छोरा`) before resolution; the runtime passes
   the verbatim surface. Correct today only because contact resolution is
   downstream and the spike's contact spans are unmeasured.
3. **Integration item I-2 is open (T-035 §16 R-3).** `LocalBrainChain`
   passes a preferred brain's ABSTENTION through untouched, so an abstained
   open-domain utterance never reaches the long-tail LLM. Pinned by
   `testAbstentionDoesNotConsultTheStandInYet`; the fix belongs in the
   integration task, not this runtime.

## Honest gaps

- **No tokenizer**: the production path is `UnavailableIntentEncoderTokenizer`
  until a Swift vocab for the committed model exists. The interpreter is
  therefore unavailable on a real device even with the artifact installed —
  by design, not silently.
- **End-to-end on-device inference is not exercised**: the tests run the
  interpreter against stub runners; the CoreML runner itself is unit-shaped.
  A device run with the real artifact + tokenizer is the next milestone.
- **Gate is off in this build** (`#if INTENT_ENCODER` absent), so the shipped
  default and the runtime path are unchanged; the gate-off case is tested.

## Fix round (post-review, commit `d042f3d`)

Review record: `specs/T-037-a-review.md` (challenger GO, 0.87; 1 MAJOR + 6
MINOR). All seven items were fixed; none was consciously skipped. Gate after
the round, run from the worktree: `./build.sh test:unit` →
"Executed 2750 tests, with 9 tests skipped and 0 failures" /
`** TEST SUCCEEDED **`; xcresult
`/tmp/t037a-dd/Logs/Test/Test-ElderlyAssistant-2026.09.13_10-50-00-+1000.xcresult`;
summary `{'result': 'Passed', 'totalTestCount': 2750, 'passedTests': 2741,
'failedTests': 0, 'skippedTests': 9, 'expectedFailures': 0}`. 57 of those are
this task's four suites (Interpreter 26, Decoder 13, Wiring 10, Artifact 8),
all passing.

Baseline note: that run tested exactly these sources, but the fixes were
still uncommitted when it started, so `ios/build/.last-tested-sha` recorded
the review commit. The branch tip was re-gated afterwards; the recorded
baseline now names the revision that contains this file.

1. **[MAJOR] Timeout no longer covers the graph load.** `interpret()` is two
   phases: PHASE 1 resolves/loads the runner outside the timed section (load
   failures keep `model_load_failed_*`; the artifact-load-race retry is
   unchanged), PHASE 2 arms the inference timer around the forward pass only,
   so `inference_timeout` stays reserved for F-1's
   `forward_pass_exceeds_local_leg_budget`. Regressions:
   `testSlowGraphLoadIsNotChargedToTheInferenceBudget` (a load 8x the budget
   still returns a real command) and
   `testSlowPredictionStillTimesOutAfterASlowLoad`. Residual, stated
   honestly: a load that neither succeeds nor throws is no longer
   timer-bounded — it only ever appeared bounded before, spuriously. No outer
   deadline covers it either (checked in source): `CommandRouter` awaits the
   interpreter's completion with no deadline of its own
   (`CommandRouter.swift:1070`); `VoicePipeline.holdIdleForTurnReply`'s 45 s
   `turnPendingSafetySeconds` only releases the pipeline's idle hold — the
   router's turn-reply token never resolves; and the AppCoordinator's 60 s
   voice watchdog fires only in `.listening`, not while the session is
   `.understanding`. A hung load therefore leaves the turn unresolved (UI
   back to idle at 45 s) until the process restarts. Acceptable while the
   encoder is off by default; a load budget (its own config key, per the
   review's alternative) or a T-036 export that guarantees a bounded load is
   the follow-up required before enabling it. The class docs no longer claim
   the interpreter is bounded by `timeoutSeconds`.
   (Aside, pre-existing: `IntentRouter.swift:263` calls the safety bound
   35 s while the constant is 45 s — stale comment, not touched here.)
2. **[MINOR] Gate-off lazy access + the flagged test gap.** The coordinator
   now calls `IntentEncoderWiring.gatedEncoder { intentEncoderInterpreter }`:
   the closure is the only reference to the lazy var on that path and runs
   only with `INTENT_ENCODER`, so a non-gated build never constructs the
   interpreter. The selection event moved to
   `IntentEncoderWiring.selectionEventMetadata(preferred:encoder:)` (metadata
   read from the instance's own manifest identity). Tests drive those two
   real functions — the hand-copied ternary is gone —
   `testTheGateIsOffInThisBuildSoTheShippedDefaultIsUnchanged` counts closure
   invocations and
   `testSelectionEventMetadataOnlyWhenTheOfferedEncoderTakesTheSlot` covers
   gate-off / unavailable / selected.
3. **[MINOR] Personal absolute path removed.**
   `ModelCatalog.intentEncoderSpikeZipURL(environment:)` returns a
   reserved-TLD `https://invalid.invalid/…` placeholder by default and honours
   `INTENT_ENCODER_SPIKE_ZIP` (injectable environment for tests); no
   home-directory literal remains in source or in these notes. The zip on
   disk was not touched.
4. **[MINOR] Provenance pointer fixed.** The label order is committed at
   `tools/train-intent/docs/t033-evidence/C3-label-order.json` (intents, BIO
   tags, `max_len`); `IntentEncoderSchema.t033Spike` cites that file instead
   of the C3 CoreML report, which has no `intents`/`tags` keys.
5. **[MINOR] Calibration temperature implemented.**
   `IntentEncoderManifest.calibrationTemperature` (default 1.0) divides the
   intent logits before the softmax; non-finite/non-positive values fall back
   to 1.0. Tests: identity is behaviour-preserving, T = 0.5 sharpens with the
   exact expected probability, invalid values fall back, and `decode` uses
   the manifest's value. The int64-contract vs Int32-artifact mismatch is
   recorded above for T-036.
6. **[MINOR] I-1 deferrals recorded as non-conformances**, not "deferred":
   see "Explicit contract non-conformances" above — `.app` projection
   (T-035 §7.1), contact clitic trimming (§7.2) and I-2 (§16 R-3) each carry
   their clause and a blocker status.
7. **[MINOR] Parent-directory creation scoped.** `ModelStore` creates the
   install destination's parent only for `kind == .intentEncoder`; the
   Whisper-companion path keeps its pre-existing failure in the anomalous
   "encoder before its Whisper model" ordering, with the reasoning next to
   the code.

---

# [ENCODER-RUNTIME-READY] Swift tokenizer + install trigger — the device path is runnable (2026-09-13)

Worktree `.claude/worktrees/encoder-runtime-ready`, branch
`worktree-encoder-runtime-ready`, base master `e797f97a6d7d`. Commits:
`e2cdfd9` (Swift XLM-R Unigram tokenizer + committed vocabulary resource +
golden fixtures), `303461a` (companion meta + install trigger + deferred
wiring behind `INTENT_ENCODER`), `6f66d2f` (differential harness).

## What was built

- **`XlmrUnigramTokenizer`** (`Services/Intents/`): the real tokenizer where
  T-037-a had `UnavailableIntentEncoderTokenizer`, covering the whole HF
  pipeline — precompiled charmap (shortest-prefix), Replace runs of spaces,
  Metaspace, Unigram Viterbi with HF's unk/fuse/tie-break rules, `<s> A </s>`
  with both specials reserved through truncation, words + wordIndices aligned
  to the span decoder. `isReady` is false only when the resource is
  missing/unusable; a load failure falls back to the explicit UNAVAILABLE
  tokenizer, never to an approximation.
- **Committed vocabulary resource** `Resources/Intents/encoder_xlmr_unigram.dat`
  (5,690,908 bytes) built by `tools/train-intent/src/encoder_tokenizer_export.py`
  (stdlib only) from the checkpoint's `tokenizer.json`; provenance + MIT
  attribution in that script's docstring (repo
  `cartesinus/multilingual_minilm-amazon-massive-intent`, revision prefix
  `08dc4816`; the tokenizer files are XLM-R 250k, Copyright (c) Microsoft).
  Regenerate / verify:

  ```
  python3 tools/train-intent/src/encoder_tokenizer_export.py --snapshot DIR \
      --out ios/ElderlyAssistant/Resources/Intents/encoder_xlmr_unigram.dat [--verify]
  ```

- **Install trigger** `IntentEncoderSpikeInstaller`, reachable only through
  `IntentEncoderInterpreter.requestReadiness()` in `INTENT_ENCODER` builds;
  the only caller of `ModelStore.installCoreMLEncoder(fromZip:for:)` for the
  spike entry. Strict sha256 and the scoped destination are untouched.
- **Wiring**: `AppCoordinator` builds the interpreter from
  `IntentEncoderRuntime.load()` (tokenizer + manifest together) and wraps the
  slot in `IntentEncoderWiring.deferredEncoderPreference`, a `LocalBrainChain`
  that re-reads `isAvailable` per turn.
- **Tests**: `XlmrUnigramTokenizerTests` (11, the hard gate) and
  `IntentEncoderRuntimeWiringTests` (15).

## Gate (green)

The canonical gate was run **on the committed code tip** `6f66d2f`:

```
IOS_DERIVED_DATA=<main>/ios/build/DerivedData \
IOS_TEST_DERIVED_DATA=<main>/ios/build/DerivedDataTests \
  <worktree>/ios/build.sh test:unit
```

Observed: `Executed 2841 tests, with 6 tests skipped and 0 failures` /
`** TEST SUCCEEDED **`. xcresult summary:
`{'result': 'Passed', 'totalTestCount': 2841, 'passedTests': 2835,
'failedTests': 0, 'skippedTests': 6, 'expectedFailures': 0}`.
Evidence copy (the live path in shared DerivedData is pruned by later runs):
`ios/build/evidence/gate-1-6f66d2f.xcresult`. The gate was then re-run after
this section was committed, on the revision that contains it; that run's
evidence is `ios/build/evidence/gate-2-*.xcresult` and
`ios/build/.last-tested-sha` names the revision it tested. The encoder
suites: Tokenizer 11, RuntimeWiring 15, Interpreter 26, Decoder 13, Wiring
10, Artifact 8 — all passing.

Build-environment note recorded for the next worktree session: the
gate first failed with `invalid symlink at
…/ElderlyAssistant.app/tts/en_US-lessac-medium-int8` because the worktree
provisioned the two voice dirs as symlinks; the copy phase dereferences a
top-level symlink (`kws`, the whisper `.bin`) but preserves symlinks nested
**inside** a folder reference, which `installd` rejects. Fixed by replacing
those two entries with hard-linked trees (`cp -a -l`, same inodes, no extra
disk) — the main checkout was not modified.

## Tokenizer fidelity — measured evidence

**Golden fixtures.** Generated from the PYTHON tokenizer (the source of
truth) by `tools/train-intent/src/encoder_tokenizer_fixtures.py`:

```
python3 tools/train-intent/src/encoder_tokenizer_fixtures.py \
    --snapshot /tmp/t036-scratch/hf --corpus-dir /tmp/t036-scratch/data \
    --out ios/ElderlyAssistantTests/Services/Intents/Fixtures/encoder_tokenizer_golden.jsonl
```

Snapshot: a copy of the pinned training tokenizer (`tokenizer.json`
17,098,081 B, `sentencepiece.bpe.model` 5,069,051 B, `tokenizer_config.json`,
`special_tokens_map.json`, `config.json`), revision prefix `08dc4816`.
Corpus: the T-036 `teacher.jsonl` + `noised.jsonl` + `edge_cases.jsonl`.
Fixture set: **387 rows / 4,368 tokens** (`sha256
cee1bbaad598b7aab54bbd5690c78fa2675a9f2454817a74b454a4c668611246`): a
stratified sample per register, all of `edge_cases.jsonl`, digit-bearing
rows, and 70 adversarial rows (empty, whitespace-only, 62/63/64/65/80 words,
punctuation runs, literal `<s>`/`</s>`/`<mask>`, ZWJ/flags/keycap, Devanagari
conjuncts + ZWNJ + nukta, control chars incl. NUL, BOM, fullwidth, meta-space
literals, ZWSP/word-joiner/soft-hyphen, 300-char words …). Every row is
re-validated against the committed Python reference before it is written.

**Hard gate.** `XlmrUnigramTokenizerTests.testEveryGoldenFixtureRowMatchesThePythonTokenizerExactly`
runs the Swift tokenizer over every row and requires identical ids, `words`,
`wordIndices` and an all-ones mask: **0 id mismatches, 0 word mismatches,
0 wordIndex mismatches, 0 mask violations**; the pinned totals (387 / 4,368)
also guard against silent fixture edits. A second test asserts the
tokenizer's `words` equal the decoder's own segmentation
(`IntentEncoderDecoder.wordScalarOffsets`) on every row — the alignment
boundary that would otherwise abstain at runtime.

**Differential harness.** `tools/train-intent/src/encoder_tokenizer_diff_harness.py`
compares the committed reference pipeline against
`transformers.AutoTokenizer` on the FULL corpora:

```
python3 tools/train-intent/src/encoder_tokenizer_diff_harness.py \
    --snapshot /tmp/t036-scratch/hf --corpus-dir /tmp/t036-scratch/data
vocab=250002 unk=3 min_score=-20.3648 max_piece_bytes=48
teacher.jsonl: {'rows': 18006, 'ids': 0, 'wids': 0}  (15.5s)
noised.jsonl:  {'rows': 29304, 'ids': 0, 'wids': 0}  (39.2s)
edge_cases.jsonl: {'rows': 109, 'ids': 0, 'wids': 0}  (39.3s)
TOTALS: {'rows': 47419, 'ids_mismatch': 0, 'wid_mismatch': 0}
VERDICT: IDENTICAL
```

47,419 rows, **0 divergences** (ids and word ids), exit 0.

**Why the fixture words are not always `str.split()`.** The harness (and
training) split with Python `str.split()`; the device splits with Foundation
whitespace (`IntentEncoderDecoder.wordScalarOffsets`, 26 members including
U+200B ZWSP). The fixture generator reproduces the RUNTIME rule so the gate
tests what a device actually feeds the tokenizer; the two rows where the
rules differ (`adv-040`, `adv-064`) are exactly the ZWSP/control-char cases,
and the decoder-segmentation test above pins them from both sides.

## meta.json delivery decision (measured, not assumed)

The delivered `t033-encoder-int8-mlmodelc.zip` contains exactly one top-level
directory, `t033-encoder-int8.mlmodelc` — **no `meta.json`** (the T-036
export record lists the zip's single top-level entry, and the ModelStore
install shape check re-asserts it). The label sets are therefore not
recoverable from the
artifact, and `IntentEncoderSchema.t033Spike`'s legacy labels would mislabel
every schema-v2 span silently.

Decision: ship the producing run's values as a companion bundled resource,
`Resources/Intents/encoder_spike_meta.json`, decoded by
`IntentEncoderManifestResource` — intents (12, contract order), tags (13 BIO
labels), `max_len` 64, `calibration_temperature` 0.779287 (from
`clean-9af1d59-20260913-120652`, `artifact_digest` prefix `6d2989e95785`),
validated on load (`manifest_id`/version present, non-empty intents/tags,
every tag decodable by the schema, `max_len` 2…512, finite temperature > 0,
12-hex digest). Any failure degrades to the explicit UNAVAILABLE pair — never
to a default temperature or a different label order. The temperature is
applied in `IntentEncoderInterpreter` (divide the intent logits before
softmax — argmax-preserving, the graph stays raw), which matches the
artifact's own note (`graph_contains_temperature: false`).

## Install trigger — exact behaviour

- `INTENT_ENCODER_SPIKE_ZIP` names the tester's own copy of the pinned zip
  (sha256 `e0ff09231843…`, 109,086,647 bytes, pinned in
  `ModelCatalog.intentEncoderSpike`; `ModelStore` verifies it strictly before
  unpacking). Unset or blank → decision `notConfigured`, no event, no
  network, no placeholder URL.
- Artifact already installed → `alreadyInstalled` +
  `encoder_spike_install_skipped` (reason `already_installed`).
- Otherwise `started` + `encoder_spike_install_started`, then the install
  runs off the main thread; success is ModelStore's own
  `coreml_encoder_installed`, failures are `encoder_spike_install_failed`
  with `errorCode` `zip_missing` / `checksum` / `unzip` (a checksum mismatch
  also emits `coreml_encoder_checksum_mismatch`). Events only ever carry
  model id + machine reason — no paths, no content.
- Every side effect is gated: `requestReadiness()` returns `.notConfigured`
  unless `IntentEncoderFeature.isEnabled`, and on a non-gated build the
  coordinator never even constructs the interpreter (the closure is the only
  reference to the lazy var).

## Device-test flow

The paths below are the ones the tests drive; the staging command is the
standard `devicectl` route and was **not** exercised here (no device was
attached in this session).

1. **Build with the gate on.** `INTENT_ENCODER` is not defined in any shipped
   configuration. Add it to the app target's Active Compilation Conditions in
   Xcode, or build via
   `xcodebuild … SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) INTENT_ENCODER"`.
2. **Stage the zip into the app's container** (the path must be readable by
   the app process):

   ```
   xcrun devicectl device copy to --device <UDID> \
     --domain-type appDataContainer --domain-identifier com.elderlyassistant.app \
     --source ~/path/to/t033-encoder-int8-mlmodelc.zip \
     --destination Documents/t033-encoder-int8-mlmodelc.zip
   ```

3. **Set the environment variable** in the scheme (Run → Arguments →
   Environment Variables) to the container path, e.g.
   `INTENT_ENCODER_SPIKE_ZIP=/var/mobile/Containers/Data/Application/<uuid>/Documents/t033-encoder-int8-mlmodelc.zip`,
   then launch from Xcode.
4. **Install + select.** At boot the coordinator offers the encoder the local
   slot and calls `requestReadiness()`; watch the console
   (`ConsoleObservabilityBus`) for `encoder_spike_install_started` →
   `coreml_encoder_installed`, then `encoder_selected_as_local_brain`
   (component `intent_encoder_wiring`). No relaunch is needed: the deferred
   preference re-reads availability every turn, so the encoder serves from
   the first utterance after the install lands.
5. **Verify a turn.** Speak a schema-v2 utterance; on success the event trail
   shows `encoder_inference_done` (interpreter events carry model id /
   duration / outcome only). An abstention shows `encoder_abstained` with a
   machine `errorCode` (`word_alignment_mismatch` for a transcript longer
   than the 64-token graph can hold — truncation abstains by policy rather
   than decoding spans from a partially-seen sequence).
6. **Compare against the Qwen brain.** With the encoder unavailable (env
   unset, or no artifact) the local slot serves the shipped local brain —
   the picker's intent GGUF (the Qwen fine-tune entry). Run the same
   utterance set once with that baseline and once with the encoder
   installed, and compare the executed commands/replies plus the event trail
   (`encoder_*` events vs. the GGUF brain's own events). The encoder always
   takes the slot when it is available, so the baseline is the env-unset
   session, not a picker switch.
7. **Checksum failure is observable, not silent.** Point the variable at a
   stale/different zip to confirm the strict path: the turn stays on the
   baseline brain and the trail shows `coreml_encoder_checksum_mismatch` +
   `encoder_spike_install_failed` (`checksum`).

## Residual risk

- **No device was attached in this session.** Everything above is verified in
  the simulator/host: the bundled resource loads from the app bundle, the
  interpreter runs the real tokenizer and manifest against a stub runner, and
  the install trigger's events/decisions are exercised through ModelStore.
  What is NOT measured here: ARM/ANE execution of the int8 graph, real
  device latency, and the devicectl staging step.
- **The 64-token graph limits the input length.** Longer transcripts abstain
  (`word_alignment_mismatch`) rather than degrade — pinned by test. The
  router's fail-soft ladder then takes the turn to another brain.
- **Baseline quality, not quality**: the T-036 v0 artifact's own gates are
  documented in `T-036-notes.md` (closed intent ≈ 0.53, publish withheld).
  Installing it on a device tests mechanics and the runtime path, not the
  model's usefulness.
- **Load-boundedness** (from the fix round above) still applies: a graph load
  that neither succeeds nor throws is not timer-bounded; acceptable while the
  gate is off by default.
- The full 40-character model-revision hash is deliberately not repeated in
  this section; only the project's 12-character references are used.
