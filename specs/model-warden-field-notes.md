# Model Warden — Step 0/1 field notes

Numbers for `docs/superpowers/specs/2026-09-18-model-memory-manager-proposal.md`
(increments 0 and 1), collected 2026-09-18 on the development host and the iOS
simulator. Every figure is labelled with how it was obtained, because the
proposal's inventory table mixes the three and the distinction is what makes
the next capture comparable.

| Label | Meaning |
|---|---|
| **MEASURED** | bytes read off the artifact on disk on this host (`stat`/`du`), 2026-09-18 |
| **DECLARED** | the catalog's `ModelCatalogEntry.sizeBytes` — itself an artifact measurement, recorded when the file was first installed |
| **DERIVED** | `ModelLifecycleInventory` arithmetic: `liveBytes = weights + KV + runtimeOverhead`, `hardBytes` = the non-pageable part |

## 1. The three residents Step 0 brings into the ledger

These are the rows the proposal calls "invisible": they were allocated by the
app and counted by nobody, so the ledger's total could disagree with
`phys_footprint` with no way to tell which was wrong.

| Resident | Artifact | On disk (MEASURED) | Catalog (DECLARED) | Ledger row (DERIVED) |
|---|---|---|---|---|
| Piper voice `ne_NP-google-medium-int8` | `Resources/Models/tts/ne_NP-google-medium-int8` | 41.2 MB | 23.6 MB (the `.zip`) | — |
| Piper voice `en_US-lessac-medium-int8` | `Resources/Models/tts/en_US-lessac-medium-int8` | 37.7 MB | 21.0 MB (the `.zip`) | — |
| Piper voice `ne_NP-…-chitwan` (catalog only, not unpacked here) | — | — | 21.2 MB | — |
| `.ttsVoices` (all three voices, worst case) | the three above | — | — | **83,753,577 B ≈ 83.8 MB** (65.8 weights + 18.0 session overhead) |
| KWS zipformer 3.3M | `Resources/Models/kws/sherpa-onnx-kws-…-3.3M-2024-01-01` | 5.4 MB | 17.6 MB | **17,626,723 B ≈ 17.6 MB** (declared) |
| `.vad` (Silero ONNX) | not compiled in this build | — | 0.9 MB | 885,098 B ≈ 0.9 MB (fallback) |

The three rows together are ~102 MB — 3.2 % of the standard (6 GB) class
budget, so none of them can change an admission decision. That is the point:
they are registered so the ledger's total is a number a field capture can be
reconciled against `phys_footprint`, not so they can be evicted.

**Finding (TTS):** the on-disk unpacked voice sets are ~1.7× the catalog's
declared `.zip` sizes (41.2 vs 23.6 MB, 37.7 vs 21.0 MB for the two that are
unpacked here). The inventory's per-voice fallback (21 MB + 6 MB session) is
therefore low by roughly 15 MB per voice relative to an unpacked cache; the
`.ttsVoices` row is also a deliberate worst case (all three catalog voices,
even when one is loaded — `SherpaTTSEngine.engines` is not inspectable from the
ledger and the release path flushes all of it). Over-counting in the direction
that never admits too much is the safe half of the two, so this is recorded
rather than "fixed".

**Finding (KWS):** the catalog declares 17.6 MB; the unpacked model set is
5.4 MB. The ledger resolves the declared value (a size bump in the catalog then
moves the ledger with it — `ModelLifecycleInventory.artifactBytes`). Recorded
because the two disagree and the reason is legitimate rather than a stale
constant: 12 MB of a 3.2 GB budget, on the conservative side.

**Finding (VAD):** the shipped `EnergyVAD` holds no model at all, so nothing is
registered for `.vad` in this build. `SileroONNXVAD` registers its own row
inside `#if canImport(onnxruntime_objc)`. The proposal's "0.9 MB resident" is
only true on a build that links onnxruntime.

## 2. Heavy models, by class — the numbers the budgets are sized against

`liveBytes` = weights + KV + runtime overhead, where the overhead is the
brain-class/slot overhead the inventory declares (`brainClasses`: 500/700/800/900 MB
by file size; whisper.cpp 320 MB; WhisperKit `max(200 MB, weights/4)`).

| Model | Slot | Artifact (DECLARED) | `liveBytes` (DERIVED) | Class it is legal on |
|---|---|---|---|---|
| whisper.cpp medium Nepali (`whisper-medium-ne-q5_1.bin`) | `.speechToText` | 586,572,036 B (MEASURED: identical on disk) | **906,572,036 B ≈ 0.91 GB** (hard 320 MB — pageable) | any |
| WhisperKit medium v6 (ANE) | `.speechToText` | 800 MB | **1,000,000,000 B ≈ 1.00 GB**, all non-pageable | any, but it is the load that costs 77 s cold |
| 4B brain slot-canon (`intent-ne-qwen4b-slotcanon-q4km`) | `.brain` | 2,497,278,784 B | **3,397,278,784 B ≈ 3.40 GB** | `roomy` only (solo escape hatch elsewhere) |
| 4B brain seed-43 (superseded, still shipped) | `.brain` | 2,075,616,032 B | **2,975,616,032 B ≈ 2.98 GB** | `roomy` |
| 3B (`llama3_2_3B`) | `.brain` | 2,019,377,696 B | **2,819,377,696 B ≈ 2.82 GB** | **`roomy` (≥ 7 GB) — owner decision, finding 2** |
| 1.7B (`qwen3-1.7b-instruct-q4km`) | `.brain` | 1,282,439,360 B | **1,982,439,360 B ≈ 1.98 GB** | `standard` and up |
| 1B intent (`intentNepali1B`) | `.intentBrain` | 1,107,408,576 B | **1,807,408,576 B ≈ 1.81 GB** | `standard` and up |
| CoreML intent encoder (int8) | `.intentEncoder` | 118 MB body + 5.7 MB unigram table | **143,690,908 B ≈ 0.14 GB**, all non-pageable | any |
| STT corrector lexicon | `.sttCorrector` | 2,627,973 B | 2,627,973 B, process-wide | any |

The 4B slot-canon row is the one that makes the standard class interesting: at
3.40 GB alone it exceeds the 3.2 GB budget, which is why `soloOverBudget` exists
and why the pairing "STT + 4B" is an eviction rather than a co-residency.

## 3. Budgets and the device classes (unchanged by Steps 0/1)

| Class | Physical RAM | Budget | 3B? | 4B? |
|---|---|---|---|---|
| `compact` | < 5 GB | 2.0 GB | no | no |
| `standard` | 5–7 GB (the 6 GB phones) | 3.2 GB | no | solo escape hatch only |
| `roomy` | ≥ 7 GB | 5.0 GB | **yes** | yes |

Recorded so the owner's finding-2 decision ("3B belongs to the ≥ 7 GB class") is
visible in one place next to its consequence: on a 6 GB phone the picker must
not offer the 3B. That gate is Step 3's (`ModelBudgetPolicy.largestAllowedBrainBytes`);
Steps 0/1 only record the class boundaries that make it expressible.

## 4. Owner-accepted defaults, as configurable defaults

All four are *defaults on a configurable surface*, not constants in a branch —
which is what makes them revisable after the first capture without a
behavioural rewrite.

| Decision | Default as implemented | Where |
|---|---|---|
| Budget numbers per class | 2.0 / 3.2 / 5.0 GB, `safetyMarginBytes` 128 MB | `ModelLifecycleBudget` (`ModelLifecycle.swift`) |
| 3B → ≥ 7 GB class | class boundaries 5 GB / 7 GB | `ModelLifecycleBudget.deviceClass(physicalMemoryBytes:)` |
| KWS load-on-demand, **not** resident | registered, `evictable: false`, written reason, never preloaded, never evicted | `SherpaKWSWakeWordEngine.registerSpotterWithLedger` |
| TTS preload = current behaviour | `.ttsVoices` registered as one worst-case row, evictable, release = `unloadCachedVoices()` | `PiperVoiceSpeaker.registerVoiceCacheWithLedger` |

Load bounds (Step 1): `maxConcurrentLargeLoads = 1`,
`largeLoadThresholdBytes = 256 MB`, `maxConcurrentSmallLoads = 2`,
`reservationTTLSeconds = 30`, `loadWatchdogSeconds = 120` —
`ModelWardenConfig` (`ModelLoadReservation.swift`), all mutable at runtime on
`ModelLifecycleManager.wardenConfig`.

## 5. What is NOT measured here (and what the next capture must contain)

- **No on-device `phys_footprint` sample yet.** Step 0 wires
  `MemoryProbe.physFootprintBytes` (`task_info(TASK_VM_INFO)`) and the
  `footprintSample` event (`phys_footprint`, `ceiling_bytes`, `liveBytes`,
  `transientLiveBytes`); there is no device in this worktree to capture from.
  The proposal's own framing applies: *the next field capture contains the
  numbers this proposal currently estimates.*
- **Simulator numbers are not device numbers.** The simulator in this worktree
  is x86_64: no ANE, CoreML on CPU, `EnergyVAD` rather than Silero, and no
  jetsam ceiling that resembles a phone's. Anything measured there is a
  *relationship* (does the ledger's total track the footprint's direction of
  travel), never a device figure.
- **The 77 s ANE cold load** is device evidence quoted from
  `WhisperPostTurnPolicy`'s header, not re-measured here.
- **`whisper.cpp` wedged contexts** are bounded at 2 × 500 MB by
  `whisperCPPWedgedReserveBytes`; the bound is a declared reserve, not a
  measurement.

## 6. Deferred, with the reason

- **The proposal's §7.4 accepted default on ANE STT eviction** is deliberately
  not implemented in Steps 0/1. It contradicts the "STT and the 4B never
  co-reside" invariant the existing suite encodes, and eviction *policy* is
  Step 3's `ModelBudgetPolicy`. Steps 0/1 record the numbers and the events the
  policy will need; they do not change who gets evicted.
- **`IntentEncoderInterpreter.runnerForPrediction` is not migrated** to
  reserve/commit in this increment even though the proposal's Step 1 lists it.
  It is not gated by the lifecycle manager today at all (it registers nothing
  and asks nothing), its artifact is ~118 MB — below `largeLoadThresholdBytes`,
  so the serial queue would not act on it — and its retry-on-artifact-load-race
  loop is a CoreML concern the encoder owns. Migrating it means first giving it
  a slot the ledger can see; that is a behaviour change with its own test
  surface, and it belongs with Step 3's policy work rather than with the
  reservation kernel.
