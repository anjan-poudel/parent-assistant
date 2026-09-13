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

Kept outside the repo and outside `/tmp`, uncommitted (109 MB binary):

```
/Users/anjan/.local/share/elderly-ai/t033-spike/t033-encoder-int8-mlmodelc.zip
```

Verified again during this task: 109,075,268 bytes, SHA-256 prefix
`6056ba41ba37`, a single top-level `t033-encoder-int8.mlmodelc`
(`coremldata.bin`, `metadata.json`, `model.mil`, `weights/weight.bin`
118,429,760 bytes). The full digest lives only in the catalog entry, where it
is functionally required for install verification.

The spike is labelled honestly: it is the legacy LLM-format 10-intent dataset
(no schema-v2 actions such as `create_calendar_event`, contact/time tags only),
NOT the T-035 schema-v2 BIO training set. Tests pin exactly this —
`testSpikeManifestIsHonestAboutItsLabels`.

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
  over the sanitised transcript. Note the contract's inputs are int64 while
  the spike artifact accepts int32 — the runner matches the artifact.
- **`InputSanitiser` quarantine level** before inference, and spans are always
  slices of the sanitised text (never the raw transcript).
- **No `MedicationResolver`** exists under `ios/` (T-035 §15.1); the schema
  exposes a `medication` slot type, and nothing in this task invents a
  resolver. T-035 integration items I-1 (app span projection) and I-2
  (abstention fall-through to the long-tail peer) are deliberately NOT
  implemented; a wiring test pins the current I-2 behaviour so a later change
  is visible.

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
