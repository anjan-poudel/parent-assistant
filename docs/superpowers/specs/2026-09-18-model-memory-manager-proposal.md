# Model Warden — a global model memory/lifecycle manager for the on-device zoo

**Date:** 2026-09-18
**Status:** Proposal — options and a recommendation. No implementation; the owner picks.
**Scope:** `ios/ElderlyAssistant/Services/ModelStore/` (the warden), plus registration edits at
every existing load site (`Services/Voice/`, `Services/Intents/`, `Services/LiveTranslate/`).
**Builds on:** `docs/architecture/model-lifecycle.md` — the V1 ledger (`[MODEL-LIFECYCLE]`,
commit `0a817fb`), whose inventory, budget arithmetic and eviction order this proposal keeps.

---

## 0. Executive summary

The app hosts nine on-device artifacts across four runtimes (llama.cpp, WhisperKit/CoreML,
sherpa-onnx, CoreML). V1 of the residency ledger shipped on 2026-09-17 and is real: one
`ModelLifecycleManager`, per-slot footprints derived from the catalog, per-device-class budgets,
heavy-first LRU eviction, a pre-load admission gate, a memory-warning squeeze and an idle sweep,
all bridged to the observability bus. It works for the problem it was built for — *"STT and the
4B brain must never co-reside on a 6 GB phone"* — and it is enforced by eviction, not by refusal.

It is not yet the thing the owner is asking for, for five structural reasons (§2.3):

1. **The load itself is unreserved.** `prepareLoad` decides, then the caller loads asynchronously.
   The ledger only counts a slot after `didLoad`, so two admitted loads can allocate together and
   a 2.5 GB GGUF's page-in is charged to nobody. The 128 MB `safetyMarginBytes` is a fixed
   allowance, not a function of the incoming model.
2. **Loads are not serialized.** Nothing stops a background ANE re-warm and a foreground brain
   load from spiking together; the only precedent for serialization in the tree is
   `WarmStartRunner` ("serializing them bounds the boot's memory spike"), which is exactly the
   rule that should be global.
3. **Three residents are invisible**: the live-translate tier's llama handle (deliberately no
   slot — `LocalBrainTranslationTier` header, lines 79-90), the Piper voice cache
   (`SherpaTTSEngine.engines`, never emptied, no release API) and the always-on KWS spotter
   (`SherpaKWSWakeWordEngine.spotter`, loaded in `init`, released never).
4. **No priority and no preemption.** Eviction order is LRU; a live-translate batch and a voice
   turn are peers. The one priority-like rule is voluntary (`brainTranslationDefersToResidentBrain`).
5. **Two working-set fictions.** The budget was derived with a ~300 MB app working set
   (`model-lifecycle.md` §Budgets); the camera feature's own measured live footprint is
   **1.18–1.41 GB** (`LiveTranslateConfig.swift:383`). And the STT footprint appears as **1.0 GB**
   (ledger), **1.5 GB** (`WhisperKitSpeechRecognizer` comments) and **1.6 GB**
   (`AppCoordinator.whisperFootprintBytes`, from a superseded catalog entry) depending on who asks.

**Recommendation: Option D — the reservation-ledger warden (Option C) plus a per-class policy
layer and a measured cost model — delivered in four increments starting with a bookkeeping step
that costs one PR and closes the honesty gaps immediately.** Options A (harden the slot manager in
place) and D differ only in how far the policy layer reaches; Option B (a shared handle pool with
refcounts) is recommended *against*, and §5.1 gives the four code-level blockers.

Two things this proposal refuses to promise (§6): iOS gives an app **no swap and no readable
ceiling**, and `os_proc_available_memory()` is advisory, racy, and blind to reclaimable
`mmap`'d weights. And the app's *observed* device kill was a **CPU** watchdog kill, not jetsam —
so a warden that only counts bytes can trade one watchdog for the other. The design therefore
meters load CPU as well as bytes.

The owner must decide four things before any of this is implemented (§7): the class → largest
brain mapping, whether the 4B stays the default on the 6 GB class, whether the camera session
gets its own (smaller) model budget, and whether the ANE STT may ever be evicted mid-conversation
given its measured 77-second cold reload.

---

## 1. The model zoo, from the code

Footprints are the ledger's own arithmetic (`ModelLifecycle.swift:248-337`): `liveBytes = weights
+ KV + runtime overhead`, `hardBytes` = the part the kernel cannot reclaim on our behalf.
"Sizes come from `ModelCatalog` (`entryIncludingInternalSideload(for:)`), so a size bump in the
catalog moves the budget automatically."

### 1.1 Heavy models (the ones that can get the app killed)

| Artifact (catalog id) | Slot | Loaded/owned by | Disk | `liveBytes` | `hardBytes` | Residency | Release contract | In ledger |
|---|---|---|---|---|---|---|---|---|
| `whisperkit-ne-medium-v6-q6` (shipping ANE STT) | `.speechToText` | `WhisperKitSpeechRecognizer.kitInstance` | 800 MB | **1.00 GB** | 1.00 GB | resident | synchronous drop | yes |
| `whisper-medium-ne-v5/v6-q5_1` (CPU path) | `.speechToText` | `WhisperSpeechRecognizer` | 587 MB | **0.91 GB** | 0.32 GB | pageable (mmap) | per-attempt context | yes |
| `intent-ne-qwen4b-slotcanon` (**default brain**) | `.brain` | `LlamaCommandInterpreter.llmInstance` | 2.50 GB | **3.40 GB** | 0.90 GB | pageable (mmap) | actor-deferred free | yes |
| `intent-ne-qwen-s43-q4_k_m` (1.7B) | `.brain` (alt) | `LlamaCommandInterpreter` | 1.11 GB | **1.81 GB** | 0.70 GB | pageable | actor-deferred | yes |
| `intentNepali1B` / `intentQwenS43` | `.intentBrain` | `LocalIntentInterpreter.llmInstance` | 0.81–1.11 GB | **1.31–1.81 GB** | 0.50–0.70 GB | pageable | actor-deferred | yes |
| `llama-3.2-3b-instruct-q4km` (catalog only, unoffered) | — | — | 2.02 GB | **2.82 GB** | 0.80 GB | pageable | actor-deferred | n/a |
| **translate tier's handle** (4B or 1.7B) | **none** | `LlamaBrainTextGenerator.handle` (actor) | 2.50/1.11 GB | 3.40/1.81 GB | 0.90/0.70 GB | pageable | actor-deferred, idle 5 s | **no** |

### 1.2 Light and process-wide residents

| Artifact | Slot | Held by | `liveBytes` | Evictable | In ledger |
|---|---|---|---|---|---|
| CoreML intent encoder (`t033-encoder-int8.mlmodelc`) | `.intentEncoder` | `IntentEncoderInterpreter.loadedRunner` → `CoreMLIntentEncoderModel.model` | 0.14 GB (118 MB body + 5.7 MB tokenizer + 20 MB activations) | registered `evictable: false`; it has its own level-2 observer | yes (lazily) |
| STT corrector (JSON lexicon, process-wide `static let`) | `.sttCorrector` | nobody (never freed) | 2.6 MB | no | yes |
| **Piper voices** (`piperNepali`, `piperNepaliChitwan`, `piperEnglishUS`) | **none** | `SherpaTTSEngine.engines: [URL: SherpaOnnxOfflineTtsWrapper]` — one per voice directory, cached for the process lifetime, **no TTL, no unload, no release API on `TTSEngine`** | 21–24 MB each on disk; runtime overhead unmeasured | no | **no** |
| **KWS wake word** (`sherpa-kws-zipformer-gigaspeech-3.3m`) | **none** | `SherpaKWSWakeWordEngine.spotter`, built in `init` ("once per launch"), `stop()` only clears `active` and `reset()`s | ~5 MB int8 | no | **no** |
| Silero VAD (`ggml-silero-v5.1.2.bin`) | — | `SileroVAD` | 0.9 MB | no | no |

### 1.3 Non-model memory (the working set the budget assumes away)

- **Camera + Vision** (`Services/LiveTranslate/`): `sessionPreset = .vga640x480`, 32BGRA output,
  `alwaysDiscardsLateVideoFrames`, an `AsyncStream(bufferingPolicy: .bufferingNewest(1))`, one
  serial `visionQueue` with a `passesInFlight` backpressure counter, and frames released after
  the pass. The buffering discipline is good; the *resident* cost is not small:
  `LiveTranslateConfig.swift:383` records a measured live camera footprint of **1.18–1.41 GB**
  on a 5.5 GB device, and Vision `.accurate` with `automaticallyDetectsLanguage` plus up to six
  `VNTrackRectangleRequest`s per pass is called "the feature's dominant CPU term".
- **Audio**: always-on `.playAndRecord`/`.measurement` session (`AudioSessionManager`), always-on
  mic tap for KWS.
- **App**: UIKit, SwiftUI, the Swift runtime, network stacks, image decode — the "~300 MB" of
  `model-lifecycle.md` when nothing heavy is on screen.

---

## 2. How the app actually dies today

### 2.1 The observed kill is a CPU kill

Owner-reported device evidence, 2026-09-16: `ElderlyAssistant.cpu_resource_fatal` ×2 —
**footprint 1.2–1.4 GB, 99 % / 97 % CPU over 49 s**. Two things follow, and both matter for the
design:

1. `cpu_resource_fatal` is the **CPU resource watchdog**, not jetsam. The reported footprint
   (1.2–1.4 GB) is *the same number* the camera pipeline measured for itself
   (`LiveTranslateConfig.swift:383`), which is a strong hint this kill was a live-camera session
   burning a core in Vision, not a memory exhaustion. A memory manager cannot fix that directly.
2. But it *couples* to the memory manager: every load and every swap burns CPU (GGUF page-in,
   ANE/CoreML specialization, context allocation). The translate config already knows this —
   `brainTranslationIdleUnloadSeconds` was retuned 30 s → 5 s with the reasoning "a 4B GGUF costs
   a full file page-in to re-load, and paying that per batch is the CPU burn the watchdog kills
   for". **Aggressive swapping trades jetsam risk for CPU-watchdog risk**, and the warden must
   meter both.

### 2.2 Jetsam history (the memory deaths)

- `model-lifecycle.md`: "On a 6 GB iPhone the app dies by jetsam when STT, the intent encoder, the
  STT corrector and the command brain are all resident… nothing in the app knew the sum."
- The `[TRUNCATION-FIX]` escalation: "admitted the 4B picker brain on top of the resident 1B and
  the pair got jetsam'd" — now closed by the `.intentBrain` slot.
- `whisperCPPWedgedReserveBytes` (2 × 500 MB): contexts whose `whisper_full` was killed by the
  watchdog are never freed (`whisper_free` under a running `whisper_full` crashes), so 1 GB of
  unreclaimable, *unmanaged* bytes can accumulate. Counted against headroom, not the class budget.

### 2.3 The five structural holes that remain

**H1 — an admitted load is not a reservation.** `prepareLoad` (`ModelLifecycleManager.swift:247`)
marks victims non-resident and returns `.allowed`, but the incoming slot is only marked resident at
`didLoad` (`:358`) — i.e. *after* the model is in memory. Between admission and `didLoad` (seconds
for an ANE specialization, tens of seconds for a 2.5 GB page-in) the ledger counts nothing for it.
Two callers on different slots are therefore both admitted against the same budget and both
allocate. The transient cost of loading (page-in staging, ANE specialization buffers, llama
context/batch) is also not modelled: `safetyMarginBytes = 128 MB` (`ModelLifecycle.swift:397`) is a
fixed allowance for whatever lands after the check.

**H2 — loads are not serialized.** Nothing in the warden orders load *execution*. Today's parallel
paths: the boot warm (`WarmStartRunner`, serial within itself), the post-turn ANE re-warm
(`runBackgroundWhisperReWarm`), the voice brain load (`LlamaCommandInterpreter.loadLLMHandle` on
`inferenceQueue`), the intent brain load (`LocalIntentInterpreter`, own queue), and the translate
generator's actor. Two of these can overlap; the ANE re-warm racing a voice-turn brain load is the
realistic pair.

**H3 — three residents are outside the ledger.** (a) The translate tier takes no slot *by design*
— the file header explains why: registering `.brain` or `.intentBrain` from there would replace the
voice interpreter's release closure, "so an eviction would free the wrong handle and this tier's
resident would go on being invisible to the budget". Its mitigation is an idle release (5 s) and a
one-way yield (`isResident` read-only). (b) The Piper engine cache has **no release path at all**
(`TTSEngine` has no unload; `engines` is never emptied). (c) The KWS spotter is built once per
launch and never freed.

**H4 — no priority, no preemption.** `lruEvictionOrderLocked` sorts by (heavy, recency, size) and
`pinCount` blocks eviction outright. There is no notion that a medication/emergency turn outranks a
sign-translation batch, no way for a foreground reservation to *take* bytes from a background
resident that is not yet idle, and no protection against preemption *thrash* (see H2's CPU
coupling).

**H5 — the numbers disagree with each other.** The same STT model is 1.00 GB (ledger,
`WhisperKitSpeechRecognizer` registers the real id), 1.5 GB (three comments in
`WhisperKitSpeechRecognizer.swift:19,212,407`) and 1.6 GB (`AppCoordinator.whisperFootprintBytes`
= `whisperKitNepaliMedium.sizeBytes`, i.e. the *superseded fp16 v3* entry, not the shipping v6 q8).
And the camera's 1.18–1.41 GB measured working set is nowhere in the budget, which was derived
with ~300 MB.

### 2.4 A new failure mode the reservation design must close: the abandoned load

`LiveTranslationPipeline.waiting(for:upTo:)` (lines ~838-855) races the brain stage against its
deadline and deliberately does **not** cancel the loser — "stop waiting, let the loser finish into
nothing". So when the 28 s stage deadline wins, the tier's `translate` task keeps running: a
2.5 GB load can proceed to completion with no caller, no lease, and no ledger entry, while the next
cycle's reservation is evaluated against a probe that is still moving. Any reservation design must
therefore reap loads nobody is waiting for (`reservationTTLSeconds`, §4.3).

---

## 3. The invariant, made precise

### 3.1 The equation

```
peak_footprint(t) = M(t) + T(t) + W(t)

  M(t)  Σ liveBytes of committed residents (what the ledger's budget bounds)
  T(t)  in-flight transient bytes: reservation taken, model not yet committed
        (page-in staging + CoreML/ANE specialization + context/batch allocation)
  W(t)  the app's own working set — UIKit, audio, camera/Vision, Swift runtime
  C     the jetsam ceiling estimate the probe reconstructs: available + residentLive

ADMIT a reservation iff   M + T + incoming.liveBytes + W(session) + safetyMargin  ≤  C
```

Two corrections to V1: `T` exists at all (H1), and `W` is a *function of the session*, not a
constant (H5). `C` stays the conservative reconstruction V1 uses; `hardBytes` stays the quantity
compared against the raw probe, because pageable GGUF weights are the kernel's to reclaim.

### 3.2 The owner's rule, per class, with numbers

"Peak ≈ the largest resident model + a fixed working-set allowance" becomes, at steady state
(`T = 0`), with the *warm* STT included because a voice turn that pays a 77 s cold load (§5.5)
is not a working product. A 6 GB iPhone's ceiling is ~3.5 GB (`model-lifecycle.md`); the
`increased-memory-limit` entitlement, if adopted, would raise it (§6.1).

| Class | Physical | Ceiling est. | `W` idle | `W` camera live | Model budget today | Largest brain that fits **with a warm ANE STT** | Largest brain solo |
|---|---|---|---|---|---|---|---|
| `compact` | 4 GB | ~2.8 GB | 0.3 GB | — (Vision on a 4 GB device is the owner's call) | 2.0 GB | **1B** (0.81 GB file → 1.31 GB live) + whisper.cpp small q5 (0.65 GB) = **1.96 GB** ✓ | 1.7B (1.81 GB) ≤ 2.0 GB, but then no ANE STT |
| `standard` | 6 GB (the shipping phones) | ~3.5 GB | 0.3 GB | **1.4 GB** | 3.2 GB | **1.7B** (1.81) + ANE STT (1.00) = **2.81 GB** ✓ | 4B = 3.40 GB (solo escape hatch today); **3B (2.82) does not fit next to STT** (3.82 > 3.2) |
| `roomy` | ≥ 7 GB | ~5.5 GB | 0.4 GB | 1.4 GB | 5.0 GB | **3B** (2.82) + ANE STT (1.00) = 3.82 ✓; **4B + STT = 4.40 ✓** | 4B alone |

Two consequences the owner should read carefully, because they contradict the intuitive mapping
"3B for 6 GB+":

1. **On a 6 GB device a 3B brain and a warm ANE STT cannot co-reside** under V1's own numbers
   (3.82 GB > 3.2 GB budget). Adopting a 3B tier on the 6 GB class therefore means *every voice
   turn pays a cold ANE load or falls back to whisper.cpp* — a latency regression, not a memory
   one. 3B belongs to the `roomy` class unless the owner accepts per-turn STT swaps (§7 Q1).
2. **The binding constraint is the STT, not the brain.** The ANE STT's 1.00 GB is *non-pageable*
   (`hardBytes == liveBytes`), while the brain's 0.9 GB is pageable — so the model that must be
   budgeted most carefully is the one the latency contract also insists stays warm.

### 3.3 The camera session changes the budget, not just the model

With the camera live, `W` goes from ~0.3 GB to ~1.4 GB — a 1.1 GB swing, larger than the gap
between the 1.7B and 4B brains. A translation session that also wants the brain must therefore
either (a) lower the model budget for its duration (`ModelBudgetPolicy.sessionWorkingSetBytes`,
recommended), or (b) forbid brain + camera co-residency outright. Today neither is enforced: the
only guard is the translate tier's own headroom gate (`brainTranslationHeadroomFactor = 1.0`
against `hardBytes`), which is much weaker than the ledger's arithmetic and invisible to the voice
turn that may arrive during the session.

### 3.4 Honest statement of the invariant

`M` can be bounded. `T` can be *bounded and serialized* but not zeroed: llama's free is deferred
to the LLM actor (`actorDeferredFree`), whisper.cpp contexts cannot be freed while
`whisper_full` runs, and a CoreML graph's specialization buffers land between the gate and the
model being usable. So the achievable claim is:

> **At most one large model is committed at a time unless the class budget explicitly allows the
> pairing, and at most one large *load* is in flight at a time.**

Not: "peak equals the largest model". The gap is exactly `T + W`, and the design's job is to make
both visible and bounded.

---

## 4. Options

All four keep `ModelSlot` / `ModelFootprint` / `ModelLifecycleBudget` as the vocabulary and keep
V1's eviction-by-real-unload semantics. They differ in *who owns the handles* and *how much the
warden may force*.

### 4.1 Option A — harden the slot manager in place

**Components.** `ModelLifecycleManager` (as today) + `ModelLoadReservation` (two-phase:
`reserve` → `commit`/`abandon`) + a serial `LoadExecutor` + a `priority` field that orders
eviction and the load queue + a scene-phase hook.

**Interfaces (new only).**

```swift
enum ModelPriority: Int, Comparable, Codable { case background, preemptible, foreground, safety }

struct ModelLoadRequest: Sendable {
    let slot: ModelSlot
    let modelID: ModelID
    let priority: ModelPriority
    let deadline: Date?
}

enum ModelLoadDenial: Error, Equatable {          // explicit per-op error type
    case unregisteredSlot(ModelSlot)
    case insufficientHeadroom(requiredBytes: UInt64, availableBytes: UInt64)
    case budgetExhausted(by: ModelSlot)
    case deadlineExceeded(waitingSeconds: TimeInterval)
}

extension ModelLifecycleManager {
    func reserve(_ request: ModelLoadRequest) async throws -> ModelReservation
    func commit(_ reservation: ModelReservation)
    func abandon(_ reservation: ModelReservation, reason: ReservationAbandonReason)
}
```

**Sequence — voice turn.** `reserve(.speechToText, .foreground)` → (queue) → granted → load on the
executor → `commit` → transcript → `reserve(.brain, .foreground)` → budget evicts STT if the class
forbids co-residency → load → `commit` → decode → reply → leases downgraded, idle TTL arms.

**Sequence — live-translate session.** Camera starts → `reserve(.brain, .preemptible)` → if the
voice brain is resident, **refused** (`budgetExhausted`) → strings to the cloud, deferral recorded;
if granted → batch → idle release at 5 s.

**Failure modes.**

| Op | Failure | Behaviour |
|---|---|---|
| `reserve` | queued behind a large load | bounded by `deadline`; caller falls back to its existing degraded path (cloud STT/brain) |
| `reserve` | owner dies before commit | `reservationTTLSeconds` (30 s) + owner identity; swept by the idle timer |
| `commit` after abandon | stale reservation id | no-op, `wardenEvent(.staleCommit)` |
| load | throws after reservation | caller `abandon`s in `defer`; a load that neither commits nor abandons is reclaimed by `loadWatchdogSeconds` (120 s) |

**Trade-offs.** Smallest delta (the existing tests extend directly), lowest risk, and it closes
H1/H2. It does **not** close H3 (the translate tier still has no slot; TTS/KWS still invisible) and
only softens H4 — priority orders the queue and the victim list but cannot take bytes from a
non-idle resident that nobody has asked to yield.

### 4.2 Option B — shared handle pool with refcounted leases

**Idea.** The warden constructs and owns every handle; consumers acquire a `ModelLease` with a
refcount; the warden loads on first acquire and unloads on the last release; identical
`(modelID, configHash)` handles are shared.

**Components.** `ModelWarden` (owns handles) + `ModelPool` + `ModelLease` (refcount + priority) +
per-runtime adapters (`LlamaModelAdapter`, `WhisperKitAdapter`, `SherpaTTSAdapter`,
`CoreMLAdapter`).

**Interfaces.**

```swift
protocol ModelHandle: AnyObject, Sendable { var footprint: ModelFootprint { get } }
func acquire(_ id: ModelID, config: ModelConfig, priority: ModelPriority) async throws -> ModelLease
func release(_ lease: ModelLease) async
```

**Trade-offs, and why this is not the recommendation.**

1. **`LLM.stop()` becomes cross-tenant.** Today each owner's timeout calls `stop()` on its *own*
   handle (`LlamaCommandInterpreter` line ~1035, `LlamaBrainTextGenerator.run`). With a shared
   handle, one consumer's deadline kills another's in-flight decode.
2. **Configs do not match, so sharing mostly does not happen.** The voice brain runs
   `maxTokenCount: 1024` with a per-model chat template and a GBNF grammar; the translate tier runs
   the same context budget with a different JSON schema and no chat wrap; the intent brain pins
   `LocalIntentInterpreter.contextTokenBudget`. A shared handle must fix one configuration, which
   is a behaviour change to at least two features.
3. **`perAttemptContext` cannot be owned by anyone but the attempt.** whisper.cpp's context is
   created and freed per utterance by design (`no_context = true`); a pool contract cannot hold it.
4. **The warden becomes a runtime layer.** It would have to know how to build four runtimes and
   their failure paths — including the sherpa VITS session creation that *segfaults off-main on
   the x86_64 simulator* (crash `204647`, "seven crash reports from one morning"): the load is a
   crash surface, and centralizing it centralizes the blast radius.

The one genuine win — never two handle *copies* of the same model — is achievable more cheaply by
Option C's "one slot per pipeline position plus a reservation", because V1's slots already enforce
it for the llama brains.

### 4.3 Option C — reservation-ledger warden + cooperative eviction + preemption

Handles stay where they are (that is what keeps `stop()`, templates, grammars and per-attempt
contexts safe). The warden owns **permission, the queue, the priority ladder, and the record** —
and every resident is registered, including the three that are invisible today.

**Components.**

| Component | Responsibility |
|---|---|
| `ModelWarden` (actor) | the only path to residency: `reserve` / `commit` / `abandon` / `evict` / `lease` |
| `ReservationLedger` | committed residents *and* in-flight reservations; TTL, owner identity, GC |
| `LoadExecutor` | serializes large loads (`maxConcurrentLargeLoads = 1`); priority-ordered queue |
| `PriorityLadder` | `safety > foreground > preemptible > background`; victim selection; thrash guard |
| `EvictionCoordinator` | asks owners to yield (ack deadline), falls back to the registered release closure |
| `ResidencyRegistry` | `ModelSlot → ModelResident` (owner + release closure), incl. the new slots |
| `MemoryTelemetry` | `phys_footprint` sampling, working-set estimate, `oom_risk` projection |

**Interfaces.**

```swift
// A slot's owner adopts this to be evictable. Release MUST be idempotent and queue-agnostic
// (the property every registered closure already documents).
protocol ModelResident: AnyObject, Sendable {
    func releaseForWarden(_ reason: EvictionReason) async -> UnloadAck
}
enum UnloadAck: Equatable {
    case released
    case refused(reason: String)                 // e.g. a decode in flight
    case deferred(until: Date)
}

enum WardenDenial: Error, Equatable {            // explicit error type per async op
    case unregisteredSlot(ModelSlot)
    case insufficientHeadroom(requiredBytes: UInt64, availableBytes: UInt64, projectedPeakBytes: UInt64)
    case budgetExhausted(by: ModelSlot, priority: ModelPriority)
    case preempted(by: ModelSlot, priority: ModelPriority)
    case deadlineExceeded(waitingSeconds: TimeInterval)
    case loadRateLimited(loadsInWindow: Int)
}

actor ModelWarden {
    func reserve(_ request: ModelLoadRequest) async throws -> ModelReservation
    func commit(_ reservation: ModelReservation)                 // model is in memory
    func abandon(_ reservation: ModelReservation, reason: ReservationAbandonReason)
    func lease(_ slot: ModelSlot, purpose: LeasePurpose) async throws -> ModelLease   // pin + priority
    func residency(of slot: ModelSlot) -> ModelResidencyState    // the read-only query the tier uses today
    func handleScenePhase(_ phase: ScenePhase) async
    func handleMemoryPressure(_ level: MemoryPressureLevel) async
}
```

**Slot set grows** (additive; `ModelSlot` is a `String` enum used for `rawValue` sorting and event
metadata, so new cases are safe but touch the lifecycle tests):

| New slot | Backs | Evictable | Notes |
|---|---|---|---|
| `.translateBrain` | the live-translate tier's handle | yes, `.preemptible` | closes the "cannot register" blocker named in the tier's header; not a second `.brain` |
| `.ttsVoices` | the sherpa voice cache (aggregate) | yes | release = flush `engines`; footprint = `voiceCount × 24 MB` + measured overhead |
| `.wakeWord` | the KWS spotter | `evictable: false` (documented: needs an audio-graph restart) | registered for ledger honesty |
| `.vad` | Silero VAD (0.9 MB) | yes | optional; light |

**Sequence — a voice turn (with preemption).**

1. Wake word / talk tap → KWS already resident (`.wakeWord`). Capture → VAD → STT.
2. `reserve(.speechToText, modelID: activeSTT, priority: .foreground)`.
   - The ledger projects `M + T + W(session) + margin ≤ C`. If the camera session holds a
     `.preemptible` `.translateBrain` lease, the warden **revokes it first**: the tier's next
     batch is refused (`WardenDenial.preempted`) and falls to the cloud, and the handle is
     released — a deferral, which the tier already models (`LocalBrainDeferral`).
   - Thrash guard: if `.translateBrain` was preempted twice inside
     `preemptionCooldownSeconds`, it is not re-admitted for `preemptionQuarantineSeconds`
     (this is the CPU-watchdog protection — see §2.1).
3. Load (or hold — the ANE TTL path is unchanged) → `commit` → transcript.
4. `reserve(.brain, .foreground)` → if the class forbids STT co-residency (standard + 4B), the
   STT is evicted *here* — and the warden records `warden_evicted(slot: .speechToText, reason:
   .budget, priority: .foreground)` so the next turn's 77 s cold load is attributable.
5. Decode under a pinned lease (`lease(.brain, .decode)`) → reply → TTS (Piper, resident).
6. Turn ends: leases released, `.brain` downgraded to `.preemptible`, idle TTL arms.

**Sequence — a live-translate session.**

1. Camera starts → the session publishes a `SessionProfile` (`workingSetBytes = cameraWorkingSetBytes`,
   measured 1.2–1.4 GB) → the effective model budget drops for the session's duration (§3.3).
2. Vision engine resident (light, non-pageable, registered).
3. Per cycle: tier asks `reserve(.translateBrain, .preemptible)`. Refused if (a) the voice brain or
   intent brain is resident (`budgetExhausted` — today's `residentBrain` deferral, now structural),
   (b) headroom is short, (c) a voice turn preempted it. Either way the strings go to the cloud and
   the deferral is recorded with its reason — the tier's existing contract is unchanged.
4. Granted: load → `commit` → one batched generation under a decode lease →
   `brainTranslationIdleUnloadSeconds` (5 s) → release → `abandon`/`evict` recorded.
5. Session closes → `cancelResolutionTasks` semantics stay; the warden drops the session profile
   and the budget returns to the class value.

**Failure modes (per async op).**

| Op | Failure | Behaviour |
|---|---|---|
| `reserve` | queued behind a large load | FIFO within priority; `deadline` bounds it; expiry → `deadlineExceeded` |
| `reserve` | in-flight load never commits | `reservationTTLSeconds` (30 s) → reclaimed, `warden_reservation_expired` |
| `reserve` | projected peak over ceiling | `insufficientHeadroom` with `projectedPeakBytes` (the honest number) |
| load | runtime crash (sherpa/simulator) | reservation released by `loadWatchdogSeconds`; slot marked `wedged` (mirrors `whisperCPPWedgedReserveBytes`) |
| `evict` | owner refuses (decode in flight) | ack deadline 2 s → retry once → force only where the release contract allows (`synchronousDrop`); **never** force `perAttemptContext` |
| `evict` | owner ignores the yield entirely | `unload_refused` event; the reservation that needed the bytes is downgraded to `budgetExhausted` rather than silently over-committing |
| preemption | victim re-reserves immediately | thrash guard: cooldown + quarantine; the warden records `warden_thrash_guard` |
| background | a load in flight at `didEnterBackground` | new reservations refused; the in-flight load lands (llama load is not cancellable mid-construction), then everything evictable is evicted |
| memory `.critical` | dispatch source fires | evict all `.preemptible` + `.background`, cancel pending reservations, keep `.foreground` pinned only if a turn is live |

**Trade-offs.** Closes H1–H4 with the smallest behavioural surface that can: owners keep their
handles, so `stop()`, templates, grammars, per-attempt contexts and the four existing release
contracts are untouched. Costs: a new actor on the load path (one hop), a reservation protocol all
five load sites must adopt, and the honest requirement that owners honour `releaseForWarden` —
enforceable because every release path is already queue-agnostic and idempotent.

### 4.4 Option D — C plus class-legal model policy and a measured cost model (hybrid)

Everything in C, plus two layers that make the warden stop being a runtime-only guard:

**D1 — the class policy decides what may be *chosen*, not just what may be *loaded*.** Today a
model over the class budget gets in through `soloOverBudget` (the escape hatch that keeps the 4B
default loadable). A `ModelBudgetPolicy` per class states the intent once:

```swift
struct ModelBudgetPolicy: Sendable {
    let deviceClass: ModelLifecycleBudget.DeviceClass
    let workingSetIdleBytes: UInt64            // compact 0.30, standard 0.30, roomy 0.40 GB
    let workingSetCameraBytes: UInt64          // 1.40 GB (measured, LiveTranslateConfig.swift:383)
    let largestAllowedBrainBytes: UInt64       // compact 1B, standard 1.7B, roomy 4B  (§3.2)
    let requiresWarmSTTCoResidency: Bool       // true: the picker refuses brains that evict STT
    let maxTransientReserveBytes: UInt64       // per-class transient cap for one load
    let maxLoadsPerMinute: Int                 // CPU-watchdog rate limit
}
```

The Settings/picker gate then shows a household model as **unavailable with a reason** ("this phone
cannot run this alongside voice") instead of admitting it and evicting the STT per turn. The
`soloOverBudget` event remains as the safety valve for stale preferences, not as the normal path.

**D2 — a measured cost model, fed by events the app already emits.** `model_loaded` already carries
`load_ms` (`WhisperKitSpeechRecognizer` marks `asr_loaded` on the turn tracer; the ledger emits
`admitted`). The warden keeps `ModelCostModel: (slot, modelID, deviceClass) → LoadCost { p50Ms,
p95Ms, samples }` and uses it to answer the question V1 cannot: **is swapping worth it?**

```
hold if  expectedIdleGapSeconds × idleEvictionPenalty  <  cost.p95Ms / 1000
load-rate limit if  Σ load_ms over the last 60 s > maxLoadCpuMsPerMinute
```

This is what turns `defaultIdleEvictionSeconds = 120` and `brainTranslationIdleUnloadSeconds = 5`
from taste into arithmetic, and it is the only mechanism in any option that can see the CPU
watchdog coming.

**Trade-offs.** The policy layer changes product behaviour (a model can be *unavailable*) and the
cost model needs a measurement pass on a real device (the events exist; the numbers do not yet).
Both are separable from C and can ship later — which is why the recommendation stages them.

### 4.5 Comparison

| | A: hardened slot manager | B: shared handle pool | C: reservation warden | D: C + policy + cost model |
|---|---|---|---|---|
| Single arbiter of residency | yes | yes | yes | yes |
| Owner of the *handles* | subsystem | warden | subsystem | subsystem |
| In-flight reservation (H1) | yes | yes | yes | yes |
| Serialized large loads (H2) | yes | yes | yes | yes |
| All residents registered (H3) | no | yes | yes | yes |
| Priority + preemption (H4) | ordering only | yes | yes | yes |
| Priority ladder semantics | advisory | lease preemption | revocable leases + thrash guard | same |
| One footprint source (H5) | yes | yes | yes | yes |
| Class-legal model choice | no | no | no | yes |
| CPU/load-cost awareness | no | no | partial (rate limit) | yes |
| Behaviour change to features | minimal | large | moderate | moderate + picker UX |
| Risk | low | high (`stop()`, configs, per-attempt contexts) | medium | medium |
| Effort | M | XL | L | L + M |

---

## 5. Recommendation

**Adopt Option D, implemented as Option C's kernel first (Steps 1–2), with Step 0 taken
immediately and independently of the rest.** Rationale, in the owner's own terms:

- **"One owner of all handles"** is achievable and worth it, but *ownership of the object* is not
  the property that prevents the kill — *arbitration of residency* is. Every failure in §2 is a
  failure of arbitration (nobody knew the total, nobody reserved, nobody could preempt), and each
  one is closed by C without moving a single handle. Moving the handles (B) buys one dedup win and
  imports four new hazards (§4.2).
- **"Peak ≈ largest model + allowance"** is enforceable as written in §3.1 only if `T` and `W` are
  modelled; C does the first, D the second.
- **The device that died did so on CPU, not bytes** (§2.1). Any design that ignores load cost while
  making swapping *easier* is a net regression. D's cost model is the only part of any option that
  addresses this.

### 5.1 Why not Option B (recorded so the decision is not re-litigated)

Cross-tenant `LLM.stop()`; per-owner configs (template, grammar, `n_ctx`, sampling) that cannot be
unified without changing behaviour; whisper.cpp's `perAttemptContext` release contract that no pool
can own; and centralizing four runtimes' load paths — including one that segfaults on the simulator
— into a single crash surface. Any two of these are disqualifying for this codebase.

### 5.2 Migration path (four increments, each independently shippable)

**Step 0 — bookkeeping and honesty (1 PR, no architecture).**
Delete the two stale STT footprint constants; make `ModelLifecycleInventory.footprint` the single
source for `WhisperPostTurnPolicy`'s hold gate and `AppCoordinator.whisperFootprintBytes` (the
ledger already resolves the *real* model id at registration — the hold gate should ask it).
Register `.ttsVoices`, `.wakeWord`, `.vad` (owners get release closures where they exist; KWS is
`evictable: false` with a written reason). Add `phys_footprint` telemetry via `task_info(TASK_VM_INFO)`
and the `LogSanitiser.allowedKeys` additions (`priority`, `load_ms`, `freed_bytes`,
`phys_footprint`, `ceiling_bytes`, `working_set_bytes`, `projected_peak_bytes`). Add the
scene-phase hook. Publish the cost-model table (§5.5) in `docs/architecture/model-lifecycle.md`.
*Value: H5 closed, two of three invisible residents become visible, and the next field capture
contains the numbers this proposal currently estimates.*

**Step 1 — the reservation (the actual fix for the OOM hole).**
`ModelLoadRequest` / `ModelReservation` / `reserve` / `commit` / `abandon`; the in-flight ledger;
the serial `LoadExecutor` (`maxConcurrentLargeLoads = 1`, `largeLoadThresholdBytes = 256 MB`);
reservation TTL + owner identity + GC; the load watchdog. Migrate the five load sites
(`WhisperKitSpeechRecognizer.createKit`, `WhisperSpeechRecognizer`'s per-attempt path,
`LlamaCommandInterpreter.loadLLMHandle`, `LocalIntentInterpreter.runAttempt`,
`IntentEncoderInterpreter.runnerForPrediction`, plus the translate generator). `prepareLoad` stays
as the synchronous fast path for tests, expressed in terms of `reserve`+`commit`.
*Value: H1, H2 closed; two large loads can no longer spike together.*

**Step 2 — priority, preemption, and the missing slots.**
`ModelPriority`, revocable leases, the thrash guard, `.translateBrain`, the `releaseForWarden` ack
protocol with the force path (never for `perAttemptContext`), the re-warm and boot-warm demoted to
`.background`. The translate tier's voluntary deferral becomes structural.
*Value: H3, H4 closed; a voice turn can take bytes from a translation session, and the session
degrades by design rather than by luck.*

**Step 3 — policy and cost model.**
`ModelBudgetPolicy` per class (`largestAllowedBrainBytes`, session working sets, load rate limit);
the picker's "unavailable with a reason" gate; `ModelCostModel` populated from `model_loaded`;
idle-eviction thresholds derived from measured reload cost rather than taste; the camera session's
reduced budget.
*Value: the invariant becomes a property of the product's configuration, not only of its runtime.*

### 5.3 Test strategy

The existing `ModelLifecycleManagerTests` harness — a scripted `MemoryProbing`, an injected clock,
`budgetOverrideBytes` — extends directly. New deterministic cases: reservation arithmetic with
`T > 0`; two concurrent `reserve` calls cannot both be granted a large pair; TTL expiry reaps an
abandoned reservation; a load that never commits trips the watchdog; priority ordering of the
queue; preemption revokes a `.preemptible` lease and the victim's next `reserve` is refused;
thrash guard quarantines a twice-preempted slot; `.critical` pressure cancels pending reservations;
backgrounding refuses new reservations. Scripted `ModelResident` doubles assert the ack/force
protocol, including "refuse → ack deadline → force" and "never force `perAttemptContext`".

### 5.4 Configurable parameters (defaults, all on the warden)

| Parameter | Default | Meaning |
|---|---|---|
| `maxConcurrentLargeLoads` | 1 | loads at or above `largeLoadThresholdBytes` serialize |
| `largeLoadThresholdBytes` | 256 MB | below this, small loads may coalesce |
| `maxConcurrentSmallLoads` | 2 | bounds the light-load spike too |
| `reservationTTLSeconds` | 30 | an uncommitted reservation is reclaimed |
| `loadWatchdogSeconds` | 120 | a load that never commits/abandons is reclaimed and the slot marked wedged |
| `unloadAckDeadlineSeconds` | 2 | owner's window to honour `releaseForWarden` before the force path |
| `preemptionCooldownSeconds` | 20 | minimum gap between two preemptions of the same slot |
| `preemptionQuarantineSeconds` | 120 | a twice-preempted slot is not re-admitted for this long |
| `maxLoadsPerMinute` | 4 | CPU-watchdog load rate limit |
| `workingSetCameraBytes` | 1.4 GB | session override (measured, `LiveTranslateConfig.swift:383`) |
| `safetyMarginBytes` | 128 MB (keep) | post-check allocation allowance |

### 5.5 The cost model (what a load actually costs — evidence in the tree)

| Transition | Measured/derived cost | Evidence |
|---|---|---|
| ANE STT cold load (WhisperKit medium), incl. CoreML specialization | **~77 s** on device; **135 s** on a reload after `MILCompilerForANE error: failed to compile ANE model` | `WhisperPostTurnPolicy` header (device evidence 2026-09-16, "क्यामेरा खोल" turn: 72 s inter-turn gap → 77 s cold load) |
| ANE STT warm utterance | ~1.3 s per utterance (iPhone 14 Pro Max) | `ModelCatalog.whisperKitNepaliMedium` comment |
| ANE STT hold window today | 180 s TTL, then release **and a required background re-warm** | `WhisperPostTurnPolicy.ttlSeconds`, `WhisperResidencyCycle` |
| llama 4B (2.5 GB, mmap) re-load | "a full file page-in"; per-batch reloads called "the CPU burn the watchdog kills for" | `LiveTranslateConfig.brainTranslationIdleUnloadSeconds` comment (30 s → 5 s retune) |
| llama free | deferred to the LLM actor (`llama_model_free`), not instant | `ModelReleaseContract.actorDeferredFree` |
| whisper.cpp context | per attempt, freed on settle; **watchdog-killed contexts are never freed** (bounded at 2 × 500 MB) | `ModelReleaseContract.perAttemptContext`, `whisperCPPWedgedReserveBytes` |
| Piper voice (21–24 MB int8) | cheap in bytes; session creation **segfaults off-main on the x86_64 simulator** (crash 204647) | `Speaker.swift:537-556` |
| CoreML encoder (118 MB int8) | fast to load, **non-pageable** once resident (ANE/GPU allocation) | `ModelLifecycleInventory.intentEncoderBodyBytes` |

The load-cost asymmetry is the design's central tension: the model whose bytes we most want back
under pressure (the ANE STT, 1.0 GB of non-pageable weights) is the one whose reload costs 77 s.
The warden resolves it the way `WhisperPostTurnPolicy.decide` already does — *hold while the probe
says the bytes fit; release the moment it does not* — generalised to every slot, with the cost
model supplying the idle-eviction prior instead of a fixed 120 s.

---

## 6. What is provably not solvable on iOS, and the honest mitigations

1. **No app-controlled swap.** iOS has no swap file; anonymous dirty pages (llama KV/output
   buffers, CoreML activations) cannot be paged out, only freed. A model cannot be "parked"; every
   eviction is a full unload.
   *Mitigation:* make the resident set a plan (§4.3 step 2 of the voice-turn sequence), not a
   reaction; prefer deny-early (the translate tier's headroom gate) over load-then-evict.
2. **Jetsam is external and silent.** There is no notification before the kill, no callback, and
   the app cannot read its own limit. `MemoryProbe.availableProcessMemoryBytes` is
   `os_proc_available_memory()`, documented as a snapshot for *large* allocations; V1 already
   compensates by comparing `hardBytes` (not `liveBytes`) against it.
   *Mitigation:* treat `C` as an estimate with a margin; never admit against the raw number; and
   keep the `insufficientHeadroom` refusal path honest.
3. **The probe under-counts what can be reclaimed and over-counts what is available.**
   `mmap`'d GGUF weight pages are file-backed and evictable; `os_proc_available_memory()` does not
   know which of the app's bytes are ours to lose. This is why V1's split (`liveBytes` for the
   budget, `hardBytes` for the probe) must survive into any warden.
   *Mitigation:* keep that split; add `phys_footprint` sampling so the *actual* footprint is
   visible in field captures instead of inferred.
4. **"Release, then load" cannot be atomic.** llama's free is actor-deferred; whisper.cpp's context
   cannot be freed while `whisper_full` runs; ANE specialization buffers land after the gate. There
   is always a window where the outgoing model's bytes and the incoming model's allocation overlap.
   *Mitigation:* the reservation's transient term and the serial load queue bound the window; the
   invariant is stated as "at most one large **commit** and one large **load** at a time" (§3.4),
   not as an exact peak.
5. **A second, independent watchdog: CPU.** The observed kill is `cpu_resource_fatal` with a
   1.2–1.4 GB footprint — i.e. not memory at all. Every load, specialization and page-in burns CPU,
   and the app cannot read its CPU budget either.
   *Mitigation:* the load rate limit, the thrash guard and D2's cost model; and do not treat
   "evict more" as free.
6. **Memory-pressure signals are partial.** `didReceiveMemoryWarning` is UIKit's own level-2
   notification and may never arrive before a kill; the dispatch memory-pressure source
   (`.warning` / `.critical`) is the closer-to-the-kernel signal and is currently **not used
   anywhere in the tree**.
   *Mitigation:* add `DispatchSource.makeMemoryPressureSource` alongside the existing observers
   (Step 0), with `.critical` handling all evictable residents and pending reservations.
7. **No simulator proof.** ANE behaviour and jetsam do not exist in the simulator; the ANE path is
   CPU-only there and the sherpa VITS load segfaults off-main. Every claim in §3.2 needs a device
   run.
   *Mitigation:* the `[LCT-device-validation-protocol]` style protocol — instrument a release
   build and capture `footprint_sample` + `warden_*` events on the 6 GB device.

**One mitigatable limit, worth a decision:** `com.apple.developer.kernel.increased-memory-limit`
(iOS 15+, "Increased Memory Limit" capability) raises the jetsam ceiling on supported devices —
reported gains range from ~+500 MB to much larger, and it must be authorized by the provisioning
profile (it cannot be added to the entitlements file alone). Given that §3.2's `standard` class
budget is the binding constraint on the whole product ladder, this is the highest-leverage
non-code change available; it also has a real cost (it takes memory from other processes and can
increase background kills).

---

## 7. Open decisions for the owner

1. **Class → largest brain.** Adopt §3.2's mapping (1B compact / 1.7B standard / 4B roomy), which
   means accepting that **a 3B tier on the 6 GB class cannot keep a warm ANE STT** (3.82 GB >
   3.2 GB) — so 3B either waits for `roomy` (7 GB+) or the 6 GB class accepts per-turn STT swaps.
   *Default if unanswered: keep today's mapping and add no 3B picker row for the standard class.*
2. **Does the 4B stay the default on the 6 GB class?** Today it is, via `soloOverBudget` — a silent,
   announced-but-tolerated budget breach. Making 1.7B the default with the 4B as an explicit
   "voice-only mode" choice would remove the escape hatch from the normal path.
   *Default: keep the 4B as the default (product decision, not a memory one) and keep the event.*
3. **Is the camera session allowed to hold the brain at all?** It costs the voice STT its
   co-residency (§3.3). Options: no brain during a camera session (cloud/dictionary only), or brain
   allowed with the session budget cut to ~2.1 GB.
   *Default: allow the brain, cut the session budget (the tier already degrades gracefully).*
4. **May the ANE STT ever be evicted mid-conversation?** Its reload is 77 s. Today the ledger will
   evict it for a 4B load. Options: never (refuse the 4B instead) or only under `.critical`
   pressure.
   *Default: only under pressure or an explicit swap; never for an LRU sweep.*
5. **TTS residency.** Boot-warm one voice, lazily load others, flush on background? Or keep the
   cache for the process lifetime (today)? Voices are 21–24 MB, but the cache has no release path
   and the load is a crash surface on the simulator.
   *Default: register `.ttsVoices`, keep the cache, flush it on `.critical` + background.*
6. **KWS residency.** Always-on is the product; ~5 MB is negligible; but it is a resident with no
   release path. Register it `evictable: false`, or make it evictable behind a wake-word restart?
   *Default: register, non-evictable, with the reason written down.*
7. **`.translateBrain` slot vs a shared brain handle.** C recommends a distinct slot (cheap, and it
   unblocks the tier's registration). B would share one handle across the voice and translate
   brains (rejected, §5.1) — confirm the owner is not relying on the shared-handle model.
8. **Adopt `increased-memory-limit`?** It changes the ceiling the whole §3.2 table is built on, and
   requires a provisioning-profile change plus an App Store review posture. *Default: measure first
   (Step 0 telemetry) and decide with the 6 GB device's real ceiling in hand.*
9. **What may the app refuse in Settings?** Option D1's "unavailable with a reason" is a UX change:
   a household can no longer select a model their phone cannot run. Confirm.
10. **Instrumentation scope.** Which `warden_*` events ship in production builds, and the
    `LogSanitiser.allowedKeys` additions (all count/byte/duration-shaped, no content). *Default:
    all of §5.2 Step 0's list; they are the evidence the next field capture needs.*
11. **Disk, not memory.** `ModelStore` accumulates every model ever downloaded (`cachedBytes()`,
    `delete(_:)`); a "model manager" in the owner's words may also mean disk pressure and a single
    screen for both. This proposal deliberately scopes to RAM; say if disk should be folded in.

---

## Appendix A — load sites and release paths (the surfaces any option must migrate)

| Load site | Constructs | Slot | Release path |
|---|---|---|---|
| `WhisperKitSpeechRecognizer.createKit` (~line 558) | `WhisperKit(config)` | `.speechToText` | `releaseModel()` (`:412`) → `kitInstance = nil` |
| `WhisperSpeechRecognizer` per attempt (~line 757) | whisper.cpp context | `.speechToText` | `releaseModel()` (`:270`); contexts per attempt; wedged ones never freed |
| `LlamaCommandInterpreter.loadLLMHandle` (~line 838) | `LLM(from:)` | `.brain` | `unloadModel()` (`:470`) |
| `LocalIntentInterpreter.runAttempt` (~line 199) | `LLM(from:)` | `.intentBrain` | `unload()` |
| `IntentEncoderInterpreter.runnerForPrediction` (~line 705) | `CoreMLIntentEncoderModel` → `MLModel` | `.intentEncoder` | `handleMemoryPressure()` (`:753`), `unload()` (`CoreMLIntentEncoderModel:70`) |
| `LlamaBrainTextGenerator.loadHandle` (~line 761) | `LLM(from:)` | **none today** | `release()` / idle timer (5 s) |
| `SherpaTTSEngine.engine(for:)` (~line 520) | `SherpaOnnxOfflineTtsWrapper` | **none today** | **none exists** |
| `SherpaKWSWakeWordEngine.init` (~line 161) | `SherpaOnnxKeywordSpotterWrapper` | **none today** | none (only `stop()` + `reset()`) |
