# Model lifecycle — one owner, budgets, LRU, proactive

**Status:** implemented (branch `models/model-lifecycle`).
**Code:** `ios/ElderlyAssistant/Services/ModelStore/ModelLifecycle.swift` (inventory +
budget arithmetic), `ios/ElderlyAssistant/Services/ModelStore/ModelLifecycleManager.swift`
(the manager), `ios/ElderlyAssistantTests/Services/ModelStore/ModelLifecycleManagerTests.swift`.

## The problem

On a 6 GB iPhone the app dies by jetsam when STT, the intent encoder, the STT
corrector and the command brain are all resident. Each subsystem loaded its own
model at the moment it needed it and never gave the memory back: nothing in the
app knew the sum of what it was holding, so nothing could refuse a load or
release something before taking more.

The fix is a single owner of residency. `ModelLifecycleManager` is the only path
through which a heavy model becomes resident. It tracks each model's *live*
footprint, enforces a **hard budget** re-derived from `os_proc_available_memory`
at every load, and **evicts the least-recently-used heavy model before** a load
that would cross the budget — a real unload, not just bookkeeping.

## Inventory (measured or derived, 6 GB class)

`liveBytes` = weights + KV + runtime overhead — the amount the model costs while
resident. `hardBytes` = the part that cannot be reclaimed by the OS under pressure
(see below). Sizes come from `ModelCatalog` (`entryIncludingInternalSideload(for:)`),
so a size bump in the catalog moves the budget automatically.

| Slot | Artifact | Weights | KV / activations | Runtime overhead | `liveBytes` | `hardBytes` | Residency | Release contract |
|---|---|---|---|---|---|---|---|---|
| `speechToText` (ANC) | `whisperkit-ne-medium-v6-q6` (800 MB) | 800 MB | — | 200 MB (CoreML graph dup + 30 s encoder activations + 448×51,865 logits) | **1.00 GB** | 1.00 GB | resident weights | synchronous drop |
| `speechToText` (whisper.cpp) | `whisper-medium-ne-q5_1.bin` (586 MB) | 586 MB | — | 320 MB (cross-attn KV + mel/audio) | **0.91 GB** | 320 MB | pageable (mmap) | per-attempt context |
| `brain` 1.7B | `Qwen3-1.7B-Q4_K_M.gguf` (1.28 GB) | 1.28 GB | in overhead | 700 MB (output/logits buffer at 1024 ctx) | **1.98 GB** | 700 MB | pageable (mmap) | actor-deferred free |
| `brain` 4B **(default)** | `intent-ne-qwen4b-slotcanon-q4km` (2.50 GB) | 2.50 GB | in overhead | 900 MB | **3.40 GB** | 900 MB | pageable (mmap) | actor-deferred free |
| `intentEncoder` | CoreML int8 body (118 MB) + XLM-R unigram (5.7 MB) | 124 MB | — | 20 MB (activations, [1,128]) | **0.14 GB** | 0.14 GB | resident | synchronous drop |
| `sttCorrector` | `canonical-stt-reductions.json` + `phonetic-key.json` | 2.6 MB | — | — | **2.6 MB** | 2.6 MB | process-wide | process lifetime |

Overheads are derived, not guessed. WhisperKit's is measured at ~25 % of the
artifact, floored at 200 MB because the activation floor does not shrink with a
smaller artifact. whisper.cpp's is the 1500-frame cross-attention KV plus the
448-token decoder self-attention (24 layers × ~1500 × 1024 × 2 × 2 B ≈ 190 MB) and
~130 MB of mel/audio buffers. The brain rows are calibrated against the catalog's
own recorded measurements ("1.3 GB file, live footprint ~2 GB" → +0.7 GB; the 4B
class "2.5 GB file, ~3.5–4 GB live" at the older 2048-token context → +0.9 GB at
the shipped 1024). All brains run at `n_ctx = 1024`.

### Why `hardBytes` exists

The manager checks the *budget* against `liveBytes` but the *probe* against
`hardBytes`. llama.cpp runs with `use_mmap = true`: a GGUF's weight pages are the
kernel's to reclaim, and refusing to load a 4B brain for bytes the OS would have
paged out is how you brick a device that can in fact run it. ANE/CoreML weights
are wired down and are not reclaimable, so for those `hardBytes == liveBytes`.

`whisperCPPWedgedReserveBytes` (1 GB = 2 × 500 MB) is added to the whisper.cpp
path's headroom check only. `WhisperSpeechRecognizer` deliberately never frees a
context whose `whisper_full` was killed by the watchdog (`whisper_free` under a
running `whisper_full` crashes), bounding the damage at
`maxWedgedContexts = 2`. Those bytes are unreclaimable **and** unmanaged: they are
counted against headroom so the manager stops stacking loads on top of a leak, but
not against the class budget, so the ordinary whisper.cpp path keeps its current
co-residency behaviour.

## Budgets

| Device class | Physical RAM | Model budget |
|---|---|---|
| `compact` | < 5 GB | 2.0 GB |
| `standard` | 5–7 GB (the 6 GB phones) | **3.2 GB** |
| `roomy` | ≥ 7 GB | 5.0 GB |

The 6 GB number is derived, not chosen for comfort. A 6 GB iPhone gives a
foreground app a jetsam ceiling in the region of 3.5–4 GB (the catalog records
"~3–4 GB available mid-session" at the 6 GB-gated 4B entry; `MemoryProbe`'s older-OS
fallback assumes 55 % of physical = 3.3 GB). Take 3.5 GB and subtract a ~300 MB app
working set — UIKit, the audio session, the Swift runtime — which does not shrink
when a model is evicted: **3.2 GB**.

The budget is a cap on the sum of `liveBytes` across resident slots. It is a *model*
budget, not a fraction of RAM, because the app's own working set is what the safety
margin protects and it is not ours to reclaim.

`effectiveBudgetBytes` takes the **minimum** of the class constant and what the probe
allows right now:

```
ceilingEstimate = available + residentLive      // what the OS would give us in total
fromProbe       = ceilingEstimate - 128 MB      // safety margin
effective       = min(classBudget, fromProbe)
```

Reconstructing the ceiling from `available + resident` (rather than using `available`
directly) is what keeps the budget from ratcheting down as our own models load. Both
the class cap and the margin are re-read on every `prepareLoad` — never cached.

## Invariants

| Pairing | Live total | Verdict |
|---|---|---|
| q8-ANE STT (1.00) + 1.7B brain (1.98) | 2.98 GB | **admit** — the pairing the budget was sized around |
| q8-ANE STT (1.00) + 4B brain (3.40) | 4.40 GB | **evict** — never co-reside on a 6 GB device |
| full fp16 medium ANE STT (2.00) + 1.7B (1.98) | 3.98 GB | **evict** |
| whisper.cpp medium (0.91) + 4B (3.40) | 4.31 GB | **evict** |
| encoder (0.14) + corrector (0.003) + one heavy | ≤ 3.55 GB | **admit** — light models co-reside with one heavy |
| 4B brain alone | 3.40 GB | **solo escape hatch** (see below) |

The invariant is enforced by *eviction*, not by refusal: "STT and the 4B brain never
co-reside" is implemented as "loading the second one really unloads the first."

## Eviction order

`lruEvictionOrderLocked` sorts **heavy models first**, then least-recently-used,
then larger-first within a recency tier. Plain LRU over all slots would be a
mistake: the budget is dominated by heavy models (one 3.4 GB brain outweighs every
light model combined), so evicting an idle 140 MB encoder because it happened to be
touched longest ago frees almost nothing while costing a CoreML specialization on the
next turn.

Within a load, all other heavy models go first, and light models are taken **only if
evicting them can actually close the gap** — if the incoming model is over budget on
its own, nothing light can help and the encoder is not sacrificed for zero bytes.

## Triggers

1. **Pre-load gate.** `prepareLoad(of:modelID:)` is called by every loader at its
   single construction site, before the model is built. Deciding under a lock, it
   projects `residentLive + incoming` against the budget, picks victims until it
   fits, marks them non-resident, **releases the lock**, then calls the owners'
   release closures (owner code never runs under the manager's lock). Finally it
   re-probes and refuses only if the incoming model's non-pageable bytes exceed the
   headroom that now remains.
2. **Memory warning.** `AppCoordinator` observes `didReceiveMemoryWarningNotification`
   unconditionally and calls `handleMemoryPressure()`, which squeezes to **half the
   class budget**, evicting LRU heavy models until the resident total is under it.
3. **Idle timer.** A `DispatchSourceTimer` sweeps every `idleEvictionSeconds / 2`
   (default `idleEvictionSeconds = 120`); heavy models unused for longer than the
   threshold are unloaded. `noteUse(of:)` is called on every real use (a transcript,
   an interpreted command) so idleness is measured, not admission order.
4. **Owner-initiated unload.** `didUnload(_:owner:)` records a release the owner did
   itself (post-turn release, model swap, teardown) — without it the ledger would keep
   counting bytes that are already back and would refuse a later load for room it has.

## Unload semantics per runtime

| Runtime | What eviction does | When the bytes actually return |
|---|---|---|
| llama.cpp GGUF (brains) | `unloadModel()` drops the `LLM` handle → `llama_free` + `llama_model_free` | On the LLM actor, i.e. slightly after the accounting marks the slot non-resident (`actorDeferredFree`) |
| whisper.cpp GGUF | The context is per-attempt and released after each attempt; eviction is a no-op for the ordinary path | Synchronously, except watchdog-killed contexts which are never freed (see the wedged reserve) |
| WhisperKit / CoreML (ANC) | `releaseModel()` drops the WhisperKit instance and its `MLModel`s | Synchronously; ANE weights are wired and must be freed explicitly (`synchronousDrop`) |
| Corrector | Nothing — it is a process-wide `static let` lexicon | Never (`processLifetime`); it is never a victim |

## Adapters and escape hatches (flagged, deliberate)

- **Solo over-budget admission.** The shipped default 4B brain is ~3.40 GB live —
  over the 3.2 GB budget *on its own*. Refusing it would make the app's own default
  brain unloadable, and evicting light models for it would free nothing. The manager
  admits it and announces `soloOverBudget(slot:liveBytes:budgetBytes:)`; the event is
  the honest signal that the class budget was exceeded. This is a deviation from a
  literal "everything must fit in ~3.2 GB" reading, and it is the only one.
- **The STT corrector is not a neural model.** It is a ~2.6 MB JSON lexicon decoded
  once into a `static let` (0.08 % of the budget). It is registered so the ledger is
  complete, not because it is a threat.
- **The encoder is registered only once it exists.** `intentEncoderInterpreter` is a
  `lazy var` behind the internal-testing encoder gate, so the coordinator declares
  the `.intentEncoder` row at the moment `gatedEncoder` actually resolves it — never
  at launch. Registering it upfront would have constructed the object in every build,
  which is a behavior change this work is explicitly not allowed to make.
- **`LocalBrainChain` needs no slot.** It is a router over interpreters that do their
  own loading; it never holds a model of its own.
- **`LocalIntentInterpreter` holds a second llama handle** on its own slot
  (`.intentBrain`, registered since the 2026-09-17 [TRUNCATION-FIX]). Before that
  registration it was invisible to every budget — the "दशैँ कहिले हो" escalation
  admitted the 4B picker brain on top of the resident 1B and the pair got jetsam'd.
  The slot closes the gap: the gate can refuse, evictions can reach it, and the
  cascade unloads it before a heavier stand-in takes the turn.
- **Two engines, one slot.** `.speechToText` can be backed by either the ANC
  (WhisperKit) or whisper.cpp engine. Whichever registers last owns the slot, and
  residency updates from the other are ignored, so a stale engine's release cannot
  clear the live engine's state.
- **Eviction order is heavy-first, not pure LRU** — see above. This is what makes
  "light models survive every heavy eviction" true rather than aspirational.

## Tests

`ModelLifecycleManagerTests` drives a scripted `MemoryProbing` and an injected clock,
with `budgetOverrideBytes` pinning the class budget, so no case depends on the host's
RAM or on wall-clock time. Covered: device-class boundaries, the effective-budget
formula (including ceiling recovery from resident bytes), the inventory rows and their
residencies, the no-two-heavy invariant in both directions, heavy-before-light
eviction order, LRU ordering vs admission order, idle eviction at/under the threshold,
pins blocking every eviction path, reload after eviction, the solo escape hatch, both
denial reasons, owner-scoped updates, dead-owner pruning, and the process-wide
corrector's exemption from pruning.
