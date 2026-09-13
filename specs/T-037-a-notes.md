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
   timer-bounded — it only ever appeared bounded before, spuriously — and the
   class docs no longer claim the interpreter is bounded by `timeoutSeconds`.
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
