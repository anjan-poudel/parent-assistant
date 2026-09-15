# T-055 — Shadow Scoring & Healing Protocol: the design

**Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-055-shadow-scoring-healing-protocol-design.md`
**Worktree:** `.claude/worktrees/t055-shadow-healing` (branch `worktree-t055-shadow-healing`, base master `fa84b54`).
**Scope discipline:** documentation only. No production code changed, no build, no test run, no device access, no merge, no push. This design is a **binding input** to T-056, T-058 and the audit criterion for T-059.

**Binding inputs (read for this design, not recalled).** `specs/T-053-notes.md` rev 2 (GO-WITH-CONDITIONS; C-1…C-9) — in particular **§3.7, "Telemetry is a second, narrower boundary (binding on T-055)"**, whose five conditions and four permitted keys are treated here as **fixed constraints, not options** — and `specs/T-054-notes.md` rev 2 (C-10…C-17; §8, the channel boundary stated from its side; §11). `specs/T-052-notes.md` rev 2 supplies the capture-rate arithmetic (§5.2, §5.3, §6.2, §8.2) that §2.4 and §3.4 below depend on. The loop design (`docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md`, D-1…D-4, §4.5, §5.3, §7.1–§7.3, R-5/R-6/R-7) fixes the shape. Everything else is read from the code as it is at `fa84b54` and cited to the line numbers **as they are here**.

**Two citations in this task's own brief are stale, and this design cites the live ones rather than propagating the drift:**

1. *"`ObservabilityBus` … `DependencyProtocols.swift:23-34`"* — **correct, still at `:23-34`.** Unchanged.
2. *"the bus implementation `AppCoordinator.swift:7260-7278`"* — **stale.** `ConsoleObservabilityBus` is at **`AppCoordinator.swift:7831-7850`** at `fa84b54` (the `:7260-7278` range is now `makeWakeWordEngine`). Every citation below uses the live range.

**Status: every ruling below is a yes/no, a field name, a number, or a named owner with a date, so T-059 can check it mechanically.** Nine conditions are added to the series continuing T-054's C-17 (§8, **C-18…C-26**), seven of T-054's and T-053's adjacent rulings are refined with reasons (§9, **SR-1…SR-7**), and four items are escalated rather than decided unilaterally (§10). Ids are namespaced so a checker can cite one unambiguously: **`SH-n`** is a shadow-protocol decision, **`SF-n`** a finding, **`C-n`** a condition, **`SR-n`** a refinement, **`SD-n`** a shadow-eligibility/device rule.

---

## 0. The protocol in one line, and the decisions taken here

### 0.1 The protocol in one line

1. **Shadow scoring runs on the live turn's in-memory sanitised transcript, after the turn has ended, one candidate verdict at a time — never on the reply path, never queued, never persisted.** The incumbent answers exactly as it does today; the candidate's verdict is computed, compared, reduced to a count, and discarded.
2. **The candidate is a second interpreter instance pointed at a second catalog entry installed through the existing `ModelDownloadService`/`ModelStore` path.** No second transport, no second deployment mechanism, no new install surface.
3. **Divergence is telemetry, and telemetry is diagnostic — so it is session-scoped and printed, and nothing about it is retained across a launch.** The only durable artifact the protocol creates is the candidate's own installed file.
4. **Concordance is a guardrail; only outcome-anchored discordance is evidence.** Agreement with an incumbent that is wrong 8% of the time is not a quality claim, and the design says so rather than letting an agreement rate stand in for accuracy.
5. **One rule, two directions: the rollback trigger is the promotion rule evaluated in reverse, at the same N and the same margins.** §4 and §5.1 are the same arithmetic.

### 0.2 The decisions taken here

| # | Decision | Where |
|---|---|---|
| **SH-1** | **Same-turn, sequential, post-turn — and batching is rejected on the record.** The shadow pass reads the just-sanitised transcript in memory after `turn_end`; it never holds a transcript across a turn boundary, because holding one is a content store and a content store is a **new collection** under T-053 §3.7 r4. | §2.1 |
| **SH-2** | **The candidate is a second `LlamaCommandInterpreter` instance on a second catalog entry.** Its `preferredBaseId` is the candidate `ModelID`; its own `llmInstance` is what makes it independently loadable and independently droppable (`LlamaCommandInterpreter.swift:378`, `:418-422`). | §2.2 |
| **SH-3** | **A candidate manifest may ADD ids and may never REMAP one.** The candidate resolver mirrors `entryIncludingInternalSideload` (`IntentEncoderSideload.swift:223-241`) exactly: an id the shipped catalog already defines resolves to the shipped entry, always. A candidate may never change what an existing id means. | §2.2 |
| **SH-4** | **The candidate install pre-flight must measure candidate + incumbent.** `ModelDownloadService.start(_:)`'s disk guard measures `entry.sizeBytes` alone (`ModelDownloadService.swift:126-135`); with a 2.5 GB incumbent on disk that under-counts by the incumbent's size and can install the device into the one state where reverting is impossible. | §2.3 |
| **SH-5** | **Eligibility reuses the shipped predicates and adds no number:** `MemoryProbe.canFit(entry.minDeviceRAMBytes)` (physical-device tier, `MemoryProbe.swift:35-37`), `ModelDownloadService.diskSafetyMarginBytes` (`:54`), the OS thermal/low-power states, and the encoder's existing memory-pressure arm/disarm contract. | §2.3, §2.6 |
| **SH-6** | **Sampling is deterministic (a stride), not random** — an unpersisted RNG makes the first turn after every launch biased, and a stride is reproducible and checkable. Two modes: ambient (stride 5, cap 20/session) and evidence (stride 1, cap 140/session). | §2.4 |
| **SH-7** | **The pass is scheduled from `VoiceTurnLatencyTracer.onTurnFinalized` and cancelled from `onTurnBegan`** — the two seams that already exist and already fire at exactly the right edges (`VoiceTurnLatencyTracer.swift:57`, `:65`). Isolation is by construction: `turn_end` has already been appended when the pass starts. | §2.5 |
| **SH-8** | **Four permitted keys, two declared events, and a fifth nothing.** `shadow_turn` (per turn) carries `action_id` + `divergence_count` + `escalation_reason`; `shadow_session` (per session) carries `divergence_count` + `divergence_rate_bucket`. `duration_ms` rides both and is already allow-listed. No other key is added for the loop. | §2.7 |
| **SH-9** | **The promotion rule needs both halves of one rule:** a concordance guardrail (**N₁ = 140, Wilson-95% lower bound ≥ 0.90**, which is **≥ 133 concordant turns**), and outcome-anchored evidence (**N₂ = 20 discordant pairs with a known verdict, Clopper–Pearson 95% lower bound on the candidate-favourable share > 0.5**, whose smallest instance is **15 of 20**). | §3.1–§3.2 |
| **SH-10** | **The rollback trigger is the promotion rule in reverse**, evaluated over the regression-watch window, plus two non-shadow triggers (load failure, latency regression). Revert is a **human act on instrumented detection**; survival in the meantime is the shipped ladder, not a new mechanism. | §5.1–§5.2 |
| **SH-11** | **A promotion retains the previous artifact on disk for the regression-watch window.** Reverting to it is then a preference write and a hot-swap (`AppCoordinator.swift:1522-1524`, `:1535-1536`) — no download, effective on the next turn. Release of the retained artifact is an explicit owner act, never automatic. | §5.2, §5.3 |
| **SH-12** | **v1 shadow scoring exists only on a build that compiles it in, and only while a tester has it on.** Activation is a compile-time flag plus a runtime toggle, the `IntentEncoderFeature` pattern exactly; shipping it to field devices is **escalation 1**, not a decision this design takes. | §2.9, §10 |

### 0.3 Head-line findings

| # | Finding | Where |
|---|---|---|
| **SF-1** | **Batching shadow work across turns would convert diagnostic telemetry into a content store, and that is a new collection.** Any deferred design must hold the sanitised transcript (or both outputs) between turns. T-053 §3.7 r4 forbids a shadow event carrying the transcript; a queue holding it is the same content under a different name, and T-053 §3.7 r2 names the only sanctioned route for retention (a dedicated content-free counter store) while forbidding the route the design would naturally take (widening the bus). **Same-turn, in-memory, discard is therefore not a preference — it is the ruling.** | §2.1 |
| **SF-2** | **The existing `ModelDownloadService` disk guard under-counts a candidate install by the incumbent's size.** `requiredBytes = entry.sizeBytes` (`:126-128`) is computed for ONE entry; a 2.5 GB candidate on a device already holding a 2.5 GB incumbent passes a 2.5 GB check and lands ~5.0 GB. The failure is not "download failed" — it is **"the install succeeded and the revert target could not be re-installed"**, which is a healing-protocol hole, not a UX wrinkle. | §2.3, `SD-3` |
| **SF-3** | **Two of the four permitted keys are already dropping on the floor today, and it is not a leak — it is silence.** The allow-list is 14 keys (`LogSanitiser.swift:56-80`) and contains none of `divergence_count`, `divergence_rate_bucket`, `action_id`, `escalation_reason`. The shipped `encoder_escalated_to_picker_brain` event emits `metadata["reason"]` (`AppCoordinator.swift:1413`) and `interpreter_selected` emits `metadata["interpreter"] / ["reason"]` (`IntentRouter.swift:378-381`) — **all three keys are dropped by the sanitiser before any sink sees them.** A divergence key that is not declared does not fail to leak; it fails to exist. That is the defect the declaration obligation in T-053 §3.7 r3 exists to prevent, and it is live in the tree today. | §2.7 |
| **SF-4** | **A 4B candidate cannot be co-resident with a 4B incumbent, and the catalog says so in its own numbers.** `intentQwen4BSlotCanon` is 2.50 GB on disk and `~3.5-4 GB live` (`ModelCatalog.swift:798-803`); its `minDeviceRAMBytes` is 4 GB *physical* (`MemoryProbe.canFit` reads `physicalMemoryBytes`, not the app's ceiling). Two of them is not a configuration the device has. The protocol is therefore **strictly load → infer → drop, one at a time, never resident across a turn boundary** — which is also what keeps the ladder's availability independent of the shadow pass. | §2.3, §2.6 |
| **SF-5** | **Concordance is not accuracy, and a promotion rule built on agreement alone would be a rule for cloning the incumbent.** Shadow scoring has no ground truth for a turn the user never corrects. The only turns where "which brain was right" is decidable are the ones carrying a verdict — and T-052 §5.3 measures those at **2–6 per household-week**, which is precisely why the guardrail and the evidence need different N and different statistics. | §3.3 |
| **SF-6** | **The divergence sample N₁ = 140 is out of reach on household traffic and trivially reachable in a scripted session — and that arithmetic, not caution, is what makes v1 tester-only.** At T-052's median of ~10 records/household-week (heavy 70–400 episodic, light 0–3), a 1-in-5 stride yields ~2 shadowed turns/week at the median and ~14–80 at the heavy end: **N₁ would take ~70 weeks at the median** and never arrive for the light household. A scripted evidence session at stride 1 reaches N₁ in one sitting. The sample requirement and the eligibility ruling are the same ruling. | §2.4, §3.4 |
| **SF-7** | **The `escalation_reason` vocabulary the protocol needs already exists, is closed, and is already wired to the exact place the shadow pass hooks.** `LocalBrainChain.EscalationReason` is `abstained` / `failed` / `subBandConfidence` (`LocalBrainChain.swift:44-55`), and the `Cascade.onEscalated` hook plus the `.cascadeDecision` timing span are the two seams T-053 §3.7 names for reuse. The shadow pass adds **no** parallel availability model and **no** new reason string. | §2.7, §5.4 |
| **SF-8** | **The rollback arithmetic and the promotion arithmetic are the same arithmetic, and saying so removes a whole class of drift.** Post-promotion, the pair is (new incumbent on the reply path, previous artifact shadowed); the trigger is the promotion rule failing in that direction, at the same N₁/N₂ and the same margins. One rule to implement, one rule to test (T-060), one rule to audit (T-059). | §4.1, §5.1 |
| **SF-9** | **`Record.latencyMs` and `Record.outcome` are always-on and pre-consent, so the healing triggers need no consent surface at all.** `IntentLogStore.Record` carries `latencyMs: Int?` and `outcome: String` (`confirmed / denied / corrected / timeout`) on every write, independent of the loop's opt-in (`IntentLogStore.swift:27-66`; T-054 §2.4 — with the opt-in OFF the record is the shipped record). Healing therefore reads the shipped store, and the loop's consent never gates the user's protection. | §5.1 |
| **SF-10** | **`Record` carries no model id — only `path` (`local / cloud / keyword / cache / override`, with the observed vocabulary `model` / `override` per T-052 §3.5c).** A per-*model* denial rate is therefore not derivable, but a per-*window* rate is, and with one local brain active at a time a window comparison is sufficient and needs no new field. | §5.1 |

---

## 1. Ground truth read for this design

Every claim below is a file read at `fa84b54`, not recalled.

| Fact | Source (verified at `fa84b54`) |
|---|---|
| The bus contract is two protocols' worth of nothing: `emit(_ event: ObservabilityEvent)`, and the event is `component / eventType / durationMs / outcome / errorCode / metadata: [String: String]` | `Services/MedicationScheduler/DependencyProtocols.swift:23-34` |
| The only implementation prints; it routes every event through `LogSanitiser.sanitise` first | `AppCoordinator.swift:7831-7850` |
| The allow-list is **14 keys**, all present-or-dropped, with values still scrubbed for phone / e-mail / BP shapes | `Services/Observability/LogSanitiser.swift:56-80`, `:94-107` |
| `duration_ms` is **already allow-listed** — the cost-measurement key needs no declaration | `LogSanitiser.swift:64` |
| `error_code` is bounded to a code charset, a 32-char unbroken-run limit and 64 chars | `LogSanitiser.swift:42-53`, `:116-132` |
| The fail-soft chain: `preferred` while available, else `standIn`; `EscalationReason` is `abstained / failed / subBandConfidence`; the cascade's `onEscalated` hook and `.cascadeDecision` span are the two existing seams | `Services/Intents/LocalBrainChain.swift:28-69`, `:44-55` |
| The encoder's abstention vocabulary is content-free machine strings and its availability is `installedModelDirectory != nil && tokenizer.isReady`; it has `handleMemoryPressure()` / `rearmAfterMemoryPressure()` | `Services/Intents/IntentEncoderInterpreter.swift:16-32`, `:94-110`, `:515` |
| The compile-time gate and the default-OFF preferences pattern: `IntentEncoderFeature.isEnabled`, `IntentEncoderPreferences.enabledKey` / `.cascadeKey`, `IntentEncoderWiring.ServingMode` | `Services/Intents/IntentEncoderFeature.swift:29-40`, `:57-76` |
| The sideload precedent: unique `ModelID`, distinct installed directory, pinned `zipBytes`/`zipSHA256`, `entryIncludingInternalSideload(for:)` that can only ADD ids, decisions `.disabled/.notConfigured/.alreadyInstalled/.inFlight/.started` | `Services/Intents/IntentEncoderSideload.swift:194`, `:223-241`, `:247-257`, `:316` |
| Band policy: accept ≥ 0.7, rephrase 0.4–0.7, abstain < 0.4; `bandChecked` is the single site; tiers `free / confirm / neverGated` | `Services/Intents/IntentRouter.swift:48-59`, `:306-330`; `Services/Intents/ConfirmationTier.swift:12-34` |
| The safety net runs **before any interpreter**: emergency phrases at `:621`, the deterministic net at `:716`; an outstanding confirmation diverts the utterance at `:631` | `Services/Voice/CommandRouter.swift:602-625`, `:631`, `:707-718` |
| The confirmation window is **45 s** (`confirmationTimeoutSeconds = 45`) | `App/VoiceSessionStateMachine.swift:95`, `:131` |
| The turn tracer's two edges: `onTurnFinalized` (fires after the last speak finished, or at `endTurn` with no speech) and `onTurnBegan`; the stage list ends with `turn_end` | `Services/Voice/VoiceTurnLatencyTracer.swift:57`, `:65`, `:86-105`, `:206-235` |
| The llama interpreter's availability is `modelStore.isCached(preferredBaseId)`; `switchBaseModel(to:)` drops the loaded handle and the LoRA so the NEXT inference re-loads | `Services/Voice/LlamaCommandInterpreter.swift:380-386`, `:418-422` |
| The download pre-flight order: size cap `maxMultipartTotalBytes = 3_000_000_000` → disk (`entry.sizeBytes + diskSafetyMarginBytes`, margin `300_000_000`) → RAM tier via `MemoryProbe.canFit` → OS tier | `Services/ModelStore/ModelDownloadService.swift:65`, `:54`, `:117-146` |
| `MemoryProbe.canFit` compares **physical** memory, deliberately not `os_proc_available_memory` | `Services/ModelStore/MemoryProbe.swift:28-37` |
| `ModelStore.finalize` verifies the digest before promoting into the final area and excludes the artifact from iCloud backup | `Services/ModelStore/ModelStore.swift:401-427` |
| The brain preference and its hot-swap: `brainPreferenceKey = "brainModelPreference"`, `resolvedBrainModelID`, `llamaCommandInterpreter.switchBaseModel(to:)` | `AppCoordinator.swift:289`, `:1513-1536`, `:1186-1189` |
| The candidate entry would have to be a `.llamaBase` catalog entry; the picker list is `availableBrainEntries` and the hidden-but-resolvable entries stay in `all` | `ModelCatalog.swift:1192-1198`, `:372-1123`, `:1125-1127` |
| `IntentLogStore.Record` is always-on and carries `path`, `action`, `outcome`, `confidence`, `latencyMs` — and **no model id** | `Services/Intents/IntentLogStore.swift:27-66` |
| The only memory-warning observer today is encoder-scoped and gated on `IntentEncoderFeature.isEnabled` | `AppCoordinator.swift:6671-6700` |

---

## 2. Decisions A and B — the mechanism

### 2.1 What "shadow" means mechanically, and why batching is rejected

**The turn, in order:**

```
wake → capture → STT → sanitise → [ CommandRouter.route ]
                                     ├─ safety net        (no model: not shadowed)
                                     ├─ outstanding yes/no (no model: not shadowed)
                                     └─ IntentRouter.interpret
                                          ├─ cache hit     (no model: not shadowed)
                                          └─ preferred brain ──► band policy ──► dispatch
                                                     │
                                              reply spoken
                                                     │
                                        VoiceTurnLatencyTracer.finalize → turn_end
                                                     │
                              ┌──────────────────────┴──────────────────────┐
                              │  SHADOW PASS — after the turn, never in it  │
                              │  stride?  gate?  eligibility?  idle?        │
                              │  load candidate → infer(same transcript)    │
                              │  → compare → count → discard both outputs   │
                              │  → drop the candidate                       │
                              └─────────────────────────────────────────────┘
```

**Ruling (SH-1).** The shadow pass consumes the **same sanitised transcript string the incumbent consumed, from memory, in the same turn.** It runs after the tracer has closed the turn, and it holds nothing past its own return.

**Why batching is rejected — and it is a ruling, not a preference.** Every deferred design that keeps the comparison honest must retain at least one of: the transcript, the incumbent's `InterpretedCommand`, or the candidate's. All three are content under T-053 §3.7:

- T-053 §3.7 r4: *"No shadow event may carry the transcript, either output, a slot value, or `Record.id`."*
- T-053 §3.7 r1: *"Both interpreter outputs are discarded. Only a divergence summary may persist."*
- T-053 §3.7 r2 sanctions exactly one retention shape — *"counters in a dedicated content-free store"* — and forbids reaching it by widening the bus.

A queue is a store. A store of transcripts is the loop content store, and the loop content store is consent-gated (T-054 C-15), which would make **shadow scoring unavailable exactly where it is needed most: on a household that has not opted in.** Batching is therefore rejected on the ruling, not on cost. The only alternative that keeps a transcript across a boundary is writing it nowhere and holding it in memory across turns — which is the same retention with a shorter lifetime, and the design declines it for the same reason: a lifetime that survives a turn boundary is a lifetime nobody can bound.

**Consequence, stated so T-056 does not re-derive it:** the shadow pass is a **synchronous, self-contained function of one transcript**, and its only outputs are one integer and one enum value.

### 2.2 The candidate: a second instance on the existing install path

**Ruling (SH-2).** A candidate is:

1. a `ModelCatalogEntry` of `kind: .llamaBase` with a **unique `ModelID`** whose raw value carries the artifact digest's first 8 hex characters (`intent-cand-<class>-<sha8>`), so two candidates can never collide and a device can hold the candidate and the incumbent at once;
2. installed by the shipped path — `ModelDownloadService.start(_ entry:)` → staging → `ModelStore.finalize(_:)` strict digest verification before promotion (`ModelStore.swift:401-427`), `downloadPartURLs` when the artifact exceeds GitHub's per-asset cap (already exercised: `intentQwen4BSlotCanon` is two parts, `ModelCatalog.swift:789-798`);
3. loaded by a **second `LlamaCommandInterpreter` instance** whose `preferredBaseId` is the candidate id, constructed exactly like the shipped one (`AppCoordinator.swift:1186-1189`) so its `isAvailable` is `modelStore.isCached(candidateID)` and its `llmInstance` handle is its own;
4. **never** a member of `ModelCatalog.availableBrainEntries`, `availableSTTEntries`, `internalTestingEncoderEntries`, or any `curatedEntries(kind:)` result — so `defaultEntry(kind:language:)` (`ModelCatalog.swift:1287-1296`) and `LanguageModelResolver` (`LanguageModelResolver.swift:57-70`) can never auto-select it. It resolves through a candidate resolver, and only that resolver (C-26).

**Ruling (SH-3).** The candidate resolver **may add ids and may never remap one.** This mirrors `IntentEncoderSideload.entryIncludingInternalSideload(for:)` (`IntentEncoderSideload.swift:223-241`), whose docstring already states the invariant for the encoder ("sideload can only ADD ids, never shadow shipped entries"). The reason the rule is load-bearing here rather than merely tidy: `ModelStore.entry(for:)` and `ModelDownloadService` both resolve ids through the same provider (`ModelStore.swift:673-681`), so a candidate manifest that could redefine `intentQwen4BSlotCanon` would be able to substitute the *incumbent's own artifact* behind the id the device already trusts. That is a silent substitution, not a shadow.

**Restart-mid-shadow behaviour, enumerated because the task asks for it:**

| Interrupted at | State on disk | State on restart | Reconciliation needed |
|---|---|---|---|
| mid-download | a partial file under `stagingURL`, final path absent | `isCached(candidate)` false, `isAvailable` false, no shadow pass runs; the next `start(_:)` re-downloads | none — `finalize`'s `defer` removes staging on every path (`ModelStore.swift:404-406`) |
| mid-`finalize` | digest not yet verified, final path absent or being written | as above; a corrupt staging file can never be promoted because the digest is checked *before* the move | none — strictly fail-closed |
| after install, mid-shadow-pass | candidate installed | the in-memory comparison is gone; the candidate is still installed and the next eligible turn shadows again | **none, deliberately** — nothing about a shadow pass is durable (C-21) |
| mid-revert (owner writes the preference, app killed before the swap) | preference written | `AppCoordinator` bootstraps from the persisted value (`:2051-2056`) and `resolvedBrainModelID` resolves through it (`:1522-1524`) | none — the preference IS the revert |
| mid-promotion | the new artifact installed, the old one retained | both cached; the incumbent is whichever the preference names | none |

**What is deliberately absent:** no shadow cursor, no shadow journal, no shadow `UserDefaults` key, no shadow file of any kind. The **only** durable artifact the protocol creates is the candidate's own installed file, which is a `ModelStore` artifact like any other and is deleted by the existing model-management UI.

### 2.3 Deployment: storage, pre-flight, eligibility

**The 4B size reality, from the catalog's own numbers.** `intentQwen4BSlotCanon` is 2 497 278 784 bytes on disk and `~3.5-4 GB live` (`ModelCatalog.swift:798-803`), with `minDeviceRAMBytes: 4_000_000_000` compared against **physical** memory (`MemoryProbe.swift:35-37`). Shadowing one 4B against another is therefore:

- **~5.0 GB of disk** for the pair (candidate + incumbent), on a device class whose floor is a 4 GB-RAM phone;
- **never co-resident** — the protocol loads one at a time (§2.6, `SD-2`).

**Ruling (SH-4).** The candidate install's disk pre-flight measures **candidate + incumbent + `diskSafetyMarginBytes`**. `ModelDownloadService.start(_:)` today computes `requiredBytes = entry.sizeBytes` for the one entry being downloaded (`:126-135`), and that is correct for every shipped use — every shipped entry is installed over nothing, or replaces its own predecessor under a different id. A candidate is the first entry whose install is **additive to a peer of the same class**, so it is the first install for which the existing computation is wrong.

**Why this is a healing-protocol hole and not a UX wrinkle (SF-2).** The failure mode of an under-counted pre-flight is not "the download failed". It is: the candidate installs (2.5 GB fits), the device is now at ~5.0 GB with the incumbent, the promotion happens, the regression watch needs the **previous artifact retained on disk** (§5.3, SH-11) — and there is no room. The device is then in exactly the state where the rollback target cannot be re-installed without first deleting something the user chose to keep. The pre-flight is where that is prevented, and it is prevented by one comparison.

**Ruling (SH-5). Eligibility adds no number.** Every gate is a shipped predicate:

| Gate | Predicate | Source |
|---|---|---|
| **SD-1** RAM tier | `MemoryProbe.canFit(entry.minDeviceRAMBytes)` for the **candidate** — the same call the download service already makes (`:137-142`) | `MemoryProbe.swift:35-37` |
| **SD-2** no co-residency | the pass loads the candidate, infers, and **drops it before returning**; the incumbent is never loaded by the shadow module and the candidate is never resident across a turn boundary | §2.6 |
| **SD-3** disk | free ≥ `candidate.sizeBytes + incumbent.sizeBytes + diskSafetyMarginBytes` (SH-4) | `ModelDownloadService.swift:54`, `:126-135` |
| **SD-4** thermal / power | skip at `ProcessInfo.thermalState ∈ {.serious, .critical}` and while `isLowPowerModeEnabled` | OS state, not a design number |
| **SD-5** memory pressure | the shadow module holds a `UIApplication.didReceiveMemoryWarningNotification` observer of its own (the shipped one is encoder-gated, `AppCoordinator.swift:6671-6700`) and mirrors the encoder's arm/disarm contract: on warning, drop the candidate and mark shadow-unavailable; re-arm only on an explicit signal | `IntentEncoderInterpreter.swift:515` precedent |
| **SD-6** feature gate | `#if SHADOW_SCORING` plus a default-OFF persisted toggle | §2.9 |
| **SD-7** safety-critical turn | see §2.5 | `CommandRouter.swift:602-625`, `:707-718` |

### 2.4 Sampling: two modes, one stride, and the arithmetic that forces the ruling

**Ruling (SH-6).** Sampling is a **deterministic stride** over *eligible* turns (a turn is eligible when it reached a model at all — §2.5's skip list). Two modes:

| Mode | Stride | Cap per session | Who enters it | What it is for |
|---|---|---|---|---|
| **Ambient** (default) | every **5th** eligible turn | **20** passes | nobody — it is the resting state while the toggle is on | opportunistic concordance on whatever the device actually hears |
| **Evidence session** | every eligible turn (**stride 1**) | **140** passes (= N₁) | the tester, explicitly, by an action | the N₁/N₂ sample a promotion decision cites |

**Why deterministic rather than random.** A stride is reproducible (the same turn set is shadowed on a re-run of the same script, so a failed session is re-runnable), it needs no PRNG, and — decisively — **a random sample requires persisted PRNG state, and no shadow state may be persisted (C-21).** A non-persisted PRNG restarts from the same seed every launch, which biases the sample toward the first turns after every cold start: the turns a tester is most likely to be *not* exercising, because the app was just launched.

**Why the cap is per-session and not per-day.** A per-day cap needs a clock and a persisted counter, which is the retention C-21 forbids. A per-session cap is a live counter with the process's own lifetime, needs nothing written, and bounds the battery cost to one number the tester can reason about. The session summary event fires at the cap or at the toggle going off, whichever comes first.

**The arithmetic (SF-6), which is why v1 is tester-only.** T-052 §5.2 measures household traffic at **5–40 records/household-week, median ~10**; light households produce **0–3**; heavy episodic users **70–400**. Applying the ambient stride of 5:

| Household | Records/week | Ambient shadowed turns/week | Weeks to reach N₁ = 140 |
|---|---|---|---|
| light | 0–3 | 0–0.6 | never |
| median | ~10 | ~2 | **~70** |
| heavy | 70–400 | 14–80 | 2–10 |

A quality claim that takes 70 weeks to reach its minimum sample is not a claim the loop can make on household traffic, and the two honest consequences are: **the ambient mode is a guardrail monitor, not an evidence source**, and **the evidence mode exists so the sample is collected deliberately.** At stride 1, a 140-turn evidence session at a realistic ~30 turns/hour is one sitting of roughly five hours of device time, driven by the tester's own script — which is the same shape as the encoder spike's on-device validation, already the project's practice.

**Restated as a ruling for T-059 to check:** a promotion decision may **never** cite ambient-mode totals as its N₁ or N₂. Ambient data is a guardrail; the sample is the evidence session.

### 2.5 Scheduling, skip conditions, and reply-path isolation

**Ruling (SH-7). The two seams already exist and are the only ones used.**

- **Start:** `VoiceTurnLatencyTracer.onTurnFinalized` (`:57`). It fires once per turn, after the last queued utterance has finished speaking (or at `endTurn()` when nothing was spoken), i.e. **after the reply the user heard**, and after `turn_end` has been appended to the stage list (`:206-221`).
- **Cancel:** `VoiceTurnLatencyTracer.onTurnBegan` (`:65`). Its docstring already states the ordering guarantee the pass depends on ("AFTER any abandoned turn found at begin time was finalized and delivered"). A new turn beginning is a cancellation signal, not a lock.

**Isolation is by construction, not by discipline.** The pass starts from a callback that fires *after* the turn is already closed, so:

- it cannot add a stage to `voice_turn_timing` (the list is already finalized and emitted);
- it cannot delay `completion` (the interpreter's completion fired long before);
- it cannot delay TTS start (speech finished);
- **checkable form:** the `voice_turn_timing` stage-name set of a shadowed turn is identical to that of an unshadowed turn, and no shadow stage name exists in the tracer's vocabulary.

**What it *can* do, stated honestly:** it consumes CPU/ANE and battery, and on a 4B it re-loads a ~2.5 GB GGUF. That is why the cancellation seam matters: a shadow pass still running when the user speaks again is **abandoned**, not awaited. The abandoned pass records nothing (an abandoned sample is not a sample).

**Skip conditions — the pass does not run when any of these holds:**

| Skip | Condition | Why |
|---|---|---|
| **SD-6** feature off | `#if SHADOW_SCORING` absent, or the persisted toggle OFF | §2.9 |
| **SD-7a** safety-critical turn | the turn was resolved by the keyword safety net (`CommandRouter.routeSafetyNet`, `:716`) or matched the emergency phrase list (`:621`) | **no model ran** — there is nothing to compare, and loading a 2.5 GB model in the immediate aftermath of an emergency utterance is disqualifying on its own |
| **SD-7b** confirmation outstanding | `coordinator?.isAwaitingConfirmation == true` (`CommandRouter.swift:631`) | the 45 s window (`VoiceSessionStateMachine.swift:95`) is a **timing contract with the user**; a model load during it can push the user's "हो" past the window and lose a confirmed action. The pass is also skipped for the whole lifetime of a *pending rephrase* (`pendingRephraseCommand`) for the same reason |
| **SD-7c** cache-resolved turn | the utterance was answered by `IntentCommandCache` | no model ran |
| **SD-4/5** resources | thermal / low-power / memory pressure | §2.3 |
| **SD-2** candidate not installed | `candidateInterpreter.isAvailable == false` | nothing to run; also the honest reading after a restart mid-download |
| **SD-8** non-eligible transcript | the transcript is empty after `NepaliTextNormalizer.normalize` | the encoder's own `empty_after_sanitise` abstention (`IntentEncoderInterpreter.swift:16-32`) is the precedent for treating an empty normalisation as "not a turn" |

**Cost measurement, named.** The pass is timed with `ProcessInfo.processInfo.systemUptime` — the same monotonic clock `VoiceTurnLatencyTracer` uses (`:52`) — and reports on the `duration_ms` key of both declared events, which is **already allow-listed** (`LogSanitiser.swift:64`) and needs no declaration. The budget it must stay within is stated in the only form that is true: **the pass may not extend a turn, and may not delay the next one.** NFR-002's 4 s therefore remains a property of the reply path, not of the instrument. The pass's own ceiling is the candidate interpreter's **existing** configured inference timeout — the same bound the router already accounts for — and no new timeout is introduced.

### 2.6 The comparison, and the verdict classes

**The pair.** For a shadowed turn:

- `incumbent`: the `InterpretedCommand?` the reply path produced (the brain that actually answered — `preferred` at rung 3, or `standIn` at rung 4, per `LocalBrainChain.swift:38-69`).
- `candidate`: the `InterpretedCommand?` the candidate's own `interpret` returns for the same transcript and the same `InterpreterContext`.

**Comparison is on three axes, and only one of them crosses the bus:**

| Axis | Compared | Where it goes |
|---|---|---|
| action | `InterpretedCommand.Action` equality | `action_id` (the **incumbent's**, see §2.7) + `divergence_count` |
| band | both confidences against the **existing** `IntentRouter.Config.default` thresholds 0.7 / 0.4 (`:56-58`) — **read, never redefined** | `divergence_count` (the band pair collapses into the same integer; the *kind* of divergence is a review-time question, not a bus field — §2.7) |
| availability | whether the candidate produced a verdict at all | `escalation_reason` |

**The reduction.** One shadowed turn produces exactly one integer in `{0, 1}` and at most one reason string:

```
verdictClass(incumbent, candidate, reason) =
    incumbent == nil                              → not shadowed (a turn with no incumbent
                                                     verdict has nothing to compare against;
                                                     abstained-by-incumbent is the *ladder's*
                                                     business, not the shadow's)
    reason != nil                                 → divergence_count = 1, escalation_reason = reason
    candidate == nil                              → divergence_count = 1, (no reason: the candidate
                                                     answered nothing without a failure reason)
    candidate.action != incumbent.action          → divergence_count = 1
    band(candidate) != band(incumbent)            → divergence_count = 1
    otherwise                                     → divergence_count = 0
```

**Ruling (SF-4 / SD-2). Load, infer, drop — in that order, inside the pass.** The candidate is loaded for the pass and its handle dropped before the pass returns. This is not an optimisation; it is what keeps invariant §7.1 true: **if the candidate stayed resident, the ladder's availability on the *next* turn would depend on the shadow pass**, and the ladder's behaviour under a diverging candidate would stop being identical to its behaviour today.

`LlamaCommandInterpreter` already has the mechanism — `switchBaseModel(to:)` sets `llmInstance = nil`, dropping the loaded handle so the next inference re-loads (`:418-422`). The design records a **T-056 implementation note**: the shadow module needs a named way to drop the handle that is not `switchBaseModel(to:)` with a same-value argument (the semantics are right; the name is wrong), and it needs the memory-warning observer of §2.3 `SD-5`. An honest caveat to carry forward: dropping `llmInstance` releases the reference, but the mapped file's pages are returned to the OS on the kernel's schedule, not at the assignment — so the "dropped" claim is a claim about *our* references, and the memory claim is tested by observing the next turn's behaviour, not by asserting a byte count.

### 2.7 The telemetry contract: the four declared keys, and the fifth that does not exist

**Ruling (SH-8). Two events, both `component: "brain_shadow"`.** Nothing else in the protocol crosses the bus.

**Event `shadow_turn` — once per shadowed turn.**

| Key | Value | Declared value space | Content-freedom argument |
|---|---|---|---|
| `action_id` | the **incumbent's** action | the schema-v2 action set: `call`, `sendMessage`, `setReminder`, `createCalendarEvent`, `music`, `suggestVideo`, `guide`, `healthQuery`, `query`, `ackMed`, `emergency`, `none`, `plugin` (the closed enum of `InterpretedCommand.Action`, `ConfirmationTier.swift:17-34`) | a **closed enumeration of verbs**. Every one of the 13 values is a fixed token that names a *kind* of action, never an argument. The candidate's action is **deliberately not emitted** — emitting both would double the content surface for no analytical gain, since `divergence_count` already carries the fact of disagreement and the promotion rule needs the rate, not the pair |
| `divergence_count` | `0` = concordant, `1` = diverged | `{0, 1}` ⊂ ℤ≥0 (T-053 §3.7 r3's declared space is "integer ≥ 0"; this design narrows it to a two-value set) | an integer in `{0,1}` cannot carry content |
| `escalation_reason` | present **only** when the candidate produced no comparable verdict | `LocalBrainChain.EscalationReason` raw values: `abstained`, `failed`, `subBandConfidence` (`LocalBrainChain.swift:44-55`) | three fixed tokens from a closed enum the chain already emits; T-053 §3.7 r3's *"reuse what exists"* |
| `duration_ms` | the pass's measured cost | ℤ≥0 (**already allow-listed** at `LogSanitiser.swift:64`) | unchanged from its shipped meaning |

**Event `shadow_session` — once per session, at the cap or at the toggle going off.**

| Key | Value | Declared value space | Content-freedom argument |
|---|---|---|---|
| `divergence_count` | turns diverged this session | ℤ≥0, bounded by the session cap (≤ 140) | an integer |
| `divergence_rate_bucket` | `lt_5` / `5_10` / `10_25` / `25_50` / `gte_50` (percent of shadowed turns, boundary-lower-inclusive) | a **fixed five-value enumeration** — never a float, per T-053 §3.7 r3's explicit *"**not** a float"* | five fixed tokens; the bucketing is what makes the value space closed. The exact rate is deliberately **not** carried: a precise rate is a fingerprint of a small sample, and the three-decimal rate for an N of 4 is both a disclosure and a lie |
| `duration_ms` | total pass cost this session | ℤ≥0 | as above |

**Nothing else is added to `allowedKeys`.** Explicitly, and matching T-054 §8's row verbatim:

- **`record_dedup` is not added** — T-054 §8 forbids it by name, and the reason is T-054's: the bus **prints**, is not consent-gated, and its hashes are unsalted SHA-256 while `record_dedup` is salt-keyed precisely so opt-out destroys linkability.
- **No `Record.id`**, no day, no outcome id, no `intent-log` field, no cursor, no consent state, no payload field. T-054 §8's second direction holds from this side too.
- **No session id, no install pseudonym, no turn index, no timestamp.** A shadow event that carried a monotonically increasing index would order a console stream into a per-turn series — the pseudonym problem in a different key.
- **The four keys above are the only loop-adjacent additions T-054 §8 anticipates, and this design adds exactly those four** — the intersection with T-054's prohibition list is empty by construction, and the check is a diff of `LogSanitiser.allowedKeys`: 14 keys today (`LogSanitiser.swift:56-80`) → 18 after T-056, with the four names above and nothing else.

**Ruling (SF-3). The declaration is the mechanism; dropping is the backstop.** The task's acceptance criterion 2 requires both halves, and they are different claims:

1. **The protocol emits only declared keys.** The deployable invariant is that a shadow emitter constructs its `metadata` dictionary from a fixed literal key set — the same discipline `VoiceTurnLatencyTracer` uses for `stages` ("stage names only … never transcript/reply text").
2. **An undeclared key is dropped, not leaked** (`LogSanitiser.swift:94-97`), and **the protocol must not rely on that as its safety mechanism.** The distinction is not academic in this tree: SF-3 shows three live emitters whose metadata keys (`reason` twice, `interpreter`) are silently dropped today. Dropping kept them safe **and** made them invisible. A shadow design that leaned on dropping would ship a protocol whose telemetry does not exist, and would notice only when a promotion decision had no numbers to cite.

**Ruling (SF-7). The reason vocabulary is reused, not extended.** `escalation_reason` carries `LocalBrainChain.EscalationReason` — the same three raw values the shipped cascade emits through `Cascade.onEscalated` (`LocalBrainChain.swift:44-55`) and the same ones `AppCoordinator.emitEncoderEscalatedToPickerBrain` already forwards (`:1406-1414`). The shadow module defines **no** new reason string, and the encoder's finer-grained `IntentEncoderAbstention` vocabulary (`IntentEncoderInterpreter.swift:16-32`) is **not** put on the bus: seven values where three suffice is a wider value space for the same information, and the encoder-specific reasons are already the encoder's own events.

### 2.8 The synthetic examples (no PII — NFR-016)

Every example below uses a **synthetic, non-user utterance placeholder** (`"<utt-A>"`) or the standard golden-corpus scenario labels. No transcript, contact, medication or message content appears anywhere in this design, and no example's numbers are derived from a real household.

**A concordant turn.** The user says `<utt-A>`; the incumbent answers `setReminder` at confidence 0.82; the candidate answers `setReminder` at 0.79.

```
[HH:mm:ss.SSS][brain_shadow] shadow_turn outcome=info
    metadata=["action_id": "setReminder", "divergence_count": "0", "duration_ms": "1840"]
```

**A diverging turn where the candidate failed.**

```
[HH:mm:ss.SSS][brain_shadow] shadow_turn outcome=info
    metadata=["action_id": "call", "divergence_count": "1",
              "escalation_reason": "failed", "duration_ms": "8300"]
```

**A band divergence (the candidate is far less certain than the incumbent).** Both name `music`; the incumbent is at 0.88, the candidate at 0.31. `divergence_count` is `1` and there is no `escalation_reason` — the candidate *did* produce a verdict, it simply did not agree with the band the incumbent was in.

```
[HH:mm:ss.SSS][brain_shadow] shadow_turn outcome=info
    metadata=["action_id": "music", "divergence_count": "1", "duration_ms": "2105"]
```

**A session summary.**

```
[HH:mm:ss.SSS][brain_shadow] shadow_session outcome=info
    metadata=["divergence_count": "7", "divergence_rate_bucket": "5_10", "duration_ms": "112000"]
```

**A worked N₂ arithmetic example, in the decision record's words:** *"evidence session 3, 140 shadowed turns, stride 1, candidate `intent-cand-qwen4b-3f9a2c11`; outcome-anchored discordant pairs 22; candidate-favourable 17; Clopper–Pearson 95% lower bound on the favourable share 0.531 `> 0.5` ⇒ evidence half satisfied. Concordance 134/140 ⇒ Wilson-95% lower bound 0.906 `≥ 0.90` ⇒ guardrail half satisfied."* — computed by hand from the printed stream, per §3.4.

### 2.9 Activation: compile-time gate plus a default-OFF toggle

**Ruling (SH-12).** The shadow module exists only where it is compiled in, and runs only where a tester has switched it on. The pattern is `IntentEncoderFeature` verbatim:

- `#if SHADOW_SCORING` compiles the module; without it, `isShadowEnabled` is a `static var` returning `false` and the shadow module's types are absent, so a non-gated build has **no** shadow code and the composition site is a no-op.
- A persisted toggle (`shadow.enabled`, absent-reads-false, default **OFF**) that acts on the next eligible turn through the same hot-swap contract the encoder toggle uses (`AppCoordinator.swift:1211-1245`), so a flip needs no relaunch.
- The stride/mode constant (`shadow.mode`, default ambient) is persisted beside it.
- `IntentEncoderFeature.isEnabled` is **not** reused: a shadow candidate is a brain, not an encoder, and overloading the encoder's gate would couple two features whose eligibility rules differ (§2.3's RAM tier is the candidate's, not the encoder's 2 GB floor).

**Consequence for the off-build:** the ladder, the router, the band policy, the safety net and the confirmation flow are byte-identical in behaviour whether or not the flag is present, because nothing on the reply path reads anything the flag defines. That is C-20's checkable form.

---

## 3. The scoring math

### 3.1 The guardrail: concordance, N₁ = 140, and the 133 boundary

**What it measures.** The share of shadowed turns on which the candidate's verdict lands in the same *class* as the incumbent's — same action and same band. It needs no ground truth, so it is available on every eligible turn, which is why it can carry an N of 140.

**What it is not.** It is not accuracy (SF-5, §3.3). It is a **non-inferiority guardrail**: the candidate must not be *visibly different* from the brain the household is living with. A candidate that agrees 95% of the time may still be better on the 5%; a candidate that agrees 80% of the time is a different product, and the decision record must say so before a human publishes it.

**The interval, and why Wilson.** The observed share is a binomial proportion. The design uses the **Wilson score interval** (95%, two-sided) rather than the normal approximation because the sample is small, the proportion is near 1, and the normal interval's failure mode in exactly that corner is a lower bound that is too low — which is the direction that would let a bad candidate through. Wilson's lower bound is:

```
L = ( p̂ + z²/2n − z·√( p̂(1−p̂)/n + z²/4n² ) ) / ( 1 + z²/n )      z = 1.96
```

**Ruling (SH-9a). N₁ = 140 shadowed turns; the guardrail passes when `L ≥ 0.90`.**

**Why 140 and not a rounder number.** 140 is the smallest N at which an observed concordance of **95%** puts the Wilson lower bound at or above 0.90:

```
n = 140, p̂ = 133/140 = 0.95,  z = 1.96
  z²/n        = 0.027440      1 + z²/n = 1.027440
  z²/2n       = 0.0137200
  p̂(1−p̂)/n    = 0.0475 / 140 = 0.000339286
  z²/4n²      = 3.8416 / 78400 = 0.0000490
  √(0.0003883) = 0.019705 ;  z·(…) = 0.0386218
  L = (0.95 + 0.01372 − 0.0386218) / 1.027440 = 0.9250982 / 1.027440 = 0.900398
```

**0.9004 ≥ 0.90 — the boundary is deliberately tight.** One turn fewer fails it:

```
n = 140, 132 concordant → p̂ = 0.942857
  √(0.000384843 + 0.0000490) = 0.020829 ;  z·(…) = 0.040825
  L = (0.942857 + 0.01372 − 0.040825) / 1.027440 = 0.915752 / 1.027440 = 0.891293  < 0.90   ✗
```

So the rule a decision record cites is either *"134 or more concordant of 140"* or the interval itself — and they are the same rule. T-059 checks the arithmetic, not the intent.

**Why 0.90.** It is the design's declared non-inferiority margin, chosen to be **loose enough that a genuinely better candidate passes and tight enough that a different product does not.** A candidate that changes one turn in ten on this device is a candidate whose promotion is a change of assistant, and that is a decision for a human, not for a gate (§4.3).

### 3.2 The evidence: outcome-anchored discordance, N₂ = 20, and the 20/15 instance

**What "outcome-anchored" means.** A shadowed turn is anchored when the turn carries a **verdict**: the household confirmed it, denied it, or corrected it. `IntentLogStore.Record.outcome ∈ {confirmed, denied, corrected, timeout}` (`IntentLogStore.swift:40-42`) — the always-on store, consent-independent (SF-9). For a corrected turn, `correctedTo` names what the user amended the plan **to** (`:44-45`), which is what makes "which brain was right" decidable:

- **candidate-favourable** — the incumbent diverged from the user's outcome and the candidate agreed with it. On a correction: the incumbent's action ≠ the corrected-to action, and the candidate's action = the corrected-to action. On a denial: the candidate abstained or produced an action in a *lower* band than the incumbent's accepted one, i.e. the candidate shared the user's hesitation.
- **incumbent-favourable** — the mirror.
- **neither** — both wrong, or the correction is not expressible as an action (the user changed their mind, which is not an error at all). **Not counted.**

**The statistic, and why Clopper–Pearson.** Among the discordant pairs, the candidate-favourable count is binomial. With m discordant pairs and b favourable, the design uses the **exact (Clopper–Pearson) 95% lower bound** on the favourable share, because m is small by construction and the normal approximation is not defensible there.

**Ruling (SH-9b). N₂ = 20 outcome-anchored discordant pairs; the evidence half passes when the Clopper–Pearson 95% lower bound on the candidate-favourable share exceeds 0.5.**

**The smallest instance that satisfies it is 15 of 20**, whose exact 95% lower bound is ≈ **0.51** — just over the line, deliberately. That tightness is a feature: it means the rule cannot be satisfied by a coin flip dressed up as a majority, and it means a decision record citing "15 of 20" is citing a result that survived the strictest available interval. The boundary is checked from the binomial side too: `L > 0.5` exactly when the two-sided tail at 0.5 falls below 0.025, i.e. when `P(X ≥ b | p = 0.5) < 0.025` for `X ~ Bin(20, 0.5)` — true at `b = 15` (0.0207), false at `b = 14` (0.0577). A clean sweep is unambiguous (20 of 20 gives a lower bound = 0.025^(1/20) ≈ **0.83**), and a 14-of-20 result **fails** — which is the correct answer for a claim whose whole purpose is to justify replacing the household's assistant.

**Why 20.** T-052 §5.3 measures the correctable/deniable signal at **2–6 per household-week**, and §8.2 at ~45–55 usable rows per 100 records post-extension. Twenty discordant pairs is therefore reachable in an evidence session (§2.4, since an evidence session can drive corrections deliberately) and is not reachable in a reasonable window on ambient traffic. Twenty is also the smallest round m at which the *required proportion* falls to a level a genuine improvement can show. The requirement is set by the same tail condition at each m: `m = 10` needs **9 of 10** (90%, since `P(X ≥ 8 | p = 0.5) = 0.055 > 0.025`), while `m = 20` needs **15 of 20** (75%). Getting a real signal out of ten pairs would mean demanding a near-sweep, which is not a sample doing statistical work; at twenty the rule tolerates a genuine minority of incumbent wins and still clears the bound. The sample requirement and the decision rule are therefore chosen together rather than independently.

**Ruling: the two halves are both necessary and neither is sufficient.** A candidate that clears the guardrail and fails the evidence is *not worse* — it is *unproven*, and unproven does not publish. A candidate that clears the evidence and fails the guardrail is *different*, and different needs the human's signature, not the gate's.

### 3.3 Why agreement is not accuracy (the ruling that keeps the rule honest)

T-052's own numbers give the argument. The incumbent is the gate-passing slot-canonical 4B whose closed-intent gate is 1.000 **on the golden corpus** and whose real-traffic behaviour is unknown. Shadow concordance measures **agreement with that brain**, not agreement with the user. Three consequences the design states rather than buries:

1. **A concordance-only rule is a rule for cloning the incumbent.** It is satisfiable by shipping the same artifact under a new id. That is why the evidence half exists, and why it is anchored on the only signal in the whole loop that carries human ground truth: a correction.
2. **The guardrail's value is protective, not probative.** It catches the candidate that changes one turn in ten; it says nothing about whether the change would have been an improvement.
3. **The corpus gates (T-038) remain the only measurement of intrinsic quality.** Shadow scoring cannot substitute for them, and a candidate whose gates are `UNEVALUATED` cannot be promoted regardless of shadow numbers (§4.2). This is the split the task's brief asks for, and it is a split of *kinds of evidence*, not of convenience: the corpus measures what the model can do; the shadow measures what this device actually gets.

### 3.4 Where the sample comes from, and why no join happens on the device

**The join problem, stated plainly.** Outcome-anchoring needs two things at once: the shadow verdict (a bus line) and the user's verdict (an `IntentLogStore` record). Doing that join automatically on the device would mean the telemetry channel reading the content store — which T-054 §8 forbids in both directions ("no bus event may carry … anything read from the loop content store, the cursor or the consent record").

**Ruling: the join is the tester's, done by hand, over the printed stream.** No code joins them. In an evidence session the tester drives a **script** — a list of utterance-and-intended-action pairs the tester authored — so the intended action is known by construction, not inferred. The tester then reads the printed `shadow_turn` lines against the script and counts the discordant pairs and their direction. The decision record cites the counts and the arithmetic, and files the session's script and the `brain_shadow` lines with it.

**Why this is not a technicality.** It keeps three properties simultaneously: the device never joins two channels, no content leaves the device (the script is already the tester's own document, and the printed lines carry only the four declared keys), and the counts a human signs are counts a human can reproduce from the raw evidence. A device-side join would have been less work and would have produced an un-reproducible number — one whose provenance a reviewer could not check.

**Ambient mode produces no evidence (restating §2.4's ruling).** It produces the guardrail and it produces the *sighting* of a regression (§5.1); it does not produce N₁ or N₂.

---

## 4. Decision C — the promotion decision

### 4.1 The rule

**A candidate is promotable when all four hold, and the rule can only refuse.**

| # | Condition | Source of the number | What it refuses |
|---|---|---|---|
| **P-1** | All eight T-038 gates pass at the pinned corpus revision `@<hash8>`, fail-closed on `UNEVALUATED` | T-038 (corpus harness) | any candidate whose intrinsic quality is unmeasured or below the gates |
| **P-2** | **Guardrail:** Wilson-95% lower bound of concordance `≥ 0.90` at N₁ ≥ 140 (≥ 133 concordant in the boundary case) | §3.1 | a candidate that is a different product |
| **P-3** | **Evidence:** Clopper–Pearson 95% lower bound on the candidate-favourable share of outcome-anchored discordant pairs `> 0.5` at N₂ ≥ 20 | §3.2 | a candidate that is *unproven* against the household's own corrections |
| **P-4** | **D-4 human approval** — a named human signs the decision record | §4.3 | everything. P-4 is the only act that publishes, and no rule can substitute for it |

**The margin is the interval, not a point.** There is no "candidate must beat the incumbent by *x* points of accuracy" rule anywhere in this design, because no such point estimate is measurable from shadow data. The claim the rules license is exactly: *"not visibly different, and better than even on the disagreements the household settled."*

### 4.2 How the shadow verdicts combine with the golden-corpus gates

**They are disjoint, ordered, and non-substitutable:**

1. **Corpus first, and fail-closed.** A candidate with a failed or `UNEVALUATED` gate cannot be promoted, full stop, whatever the shadow numbers say. Shadow scoring never rescues a corpus failure.
2. **Shadow second, and it can only add a refusal.** A candidate that passes all eight gates and fails P-2 or P-3 is refused by the shadow half. This is the R-7 counter-measure: the design's own risk list names "a promotion that passes every gate and still regresses for this user", and P-2/P-3 are the only measurement in the loop taken on that user's device.
3. **Neither can promote.** Both halves are necessary conditions. Publishing is P-4.

**The ordering is also a cost ordering,** and the design says so: the corpus gates are cheap (a harness run) and the shadow sample is expensive (hours of tester time). Running the corpus first is therefore both the correct logical order and the sensible one.

### 4.3 Where D-4 plugs in

**D-4 (the human publish gate) is the decision's only actor.** Concretely, T-058 owns the decision record; T-055 supplies what it must contain. The record cites:

- the candidate's `ModelID` and its artifact `sha256`;
- the corpus revision `@<hash8>` and the eight gate values;
- the evidence session's N₁, concordant count, and Wilson lower bound (P-2);
- the session's N₂, favourable count, and Clopper–Pearson lower bound (P-3);
- the two escalation answers §10 requires before a field promotion is even in scope;
- a named human, a date, and one sentence of reasoning.

**And the rule that makes the gate real:** a record missing any of the above is **not a promotion decision**. The design states the refusal in the direction that matters — **the gate is the record's completeness plus the human's signature**, and a "yes" without the numbers is exactly the outcome D-4 exists to prevent.

---

## 5. Decision D — the healing protocol

### 5.1 Failure detection

**The three triggers, and what each reads.** None requires loop consent (SF-9).

| # | Trigger | What is read | Why it is the right signal |
|---|---|---|---|
| **H-1** | **Post-promotion divergence (the regression watch)** | the reversed shadow pair (§5.3): the new incumbent on the reply path, the **previous artifact** as the shadow | the direct measurement of promotion regret: the artifact the household's own evidence approved now disagrees with what replaced it |
| **H-2** | **Load failure / crash** | `LlamaCommandInterpreter`'s failure reasons (`model_load_failed*`, `inference_failed*` — the same closed vocabulary family as `IntentEncoderInterpreter.swift`'s) plus a relaunch-count signal | a brain that cannot load cannot answer, and the ladder is what is covering for it — a signal worth acting on even though the user is protected |
| **H-3** | **Latency regression** | `Record.latencyMs` (`IntentLogStore.swift:62`) — **always-on, written on every dispatched turn** — compared as a **median over a trailing window** against the median over the pre-promotion window | NFR-002's 4 s is the absolute backstop and already exists; the trailing-window comparison is what catches "still under 4 s, but twice as slow as it was", which is the regression a user feels without any budget being breached |

**Ruling: H-3 adds no threshold.** It compares the brain against **its own baseline**, so the design introduces no absolute number. The only absolute in the neighbourhood is NFR-002's existing 4 s, and it is a backstop, not the trigger.

**Ruling: divergence can never trigger a rollback of the incumbent by itself.** A high divergence rate says the candidate is *different*, not that the incumbent is *bad*. The only divergence measurement that warrants a rollback is **H-1**, and H-1 is not "divergence is high" — it is "the promotion rule now fails in the other direction" (§5.2), which is a specific, bounded, arithmetic claim.

**Ruling: detection is instrumented; acting is human.** Nothing in this protocol reverts a brain automatically. The reasons are specific:

- **The user is already protected without it.** The ladder falls through (`preferred.isAvailable` false → `standIn`, `LocalBrainChain.swift:38-69`), and the safety net and confirmation flow are upstream of every interpreter. An automatic revert adds no safety the chain does not already provide.
- **An automatic revert flaps.** A trigger that fires on a 140-turn window will fire again on the next one if the two brains are genuinely close, and a device that oscillates between two 2.5 GB brains is worse than one that stays on either.
- **A revert is publish-class.** Removing a brain from the fleet is the same *kind* of act as adding one, and D-4 already ruled that publishing is a human action.

### 5.2 Revert mechanics

**Ruling (SF-8 / SH-10). The rollback trigger is the promotion rule evaluated in reverse.**

Post-promotion, the pair is (new incumbent on the reply path, **previous artifact** loaded as the shadow). The trigger is **P-2 or P-3 failing in that direction**:

- the new incumbent's concordance with the previous artifact has a Wilson-95% lower bound **< 0.90** at N₁ ≥ 140, **or**
- the previous artifact's favourable share of outcome-anchored discordant pairs has a Clopper–Pearson 95% lower bound **> 0.5** at N₂ ≥ 20 (i.e. the *old* brain is winning the disagreements), **or**
- **H-2** or **H-3** fires.

One rule, two directions, the same N and the same margins. **This is the whole reason the pair is retained through the regression window** (SH-11): the reversed pair must be physically present on the device for the trigger to be measurable at all.

**Ruling (SH-11). Back to which brain.**

1. **The retained previous artifact**, by restoring `brainPreferenceKey` (`AppCoordinator.swift:289`) to the previous `ModelID`. The artifact is already on disk (that is what the retention is *for*), so the revert is a preference write plus `switchBaseModel(to:)` — **no download**.
2. **If the retention window has closed and the artifact was released**, the revert target is the `standIn` (the LLaMA/rung-4 brain), which the chain already serves whenever `preferred` cannot. The revert is then not "back to the old brain" but "down a rung", and the design says so honestly rather than promising a download the device may not have room for.

**How fast.** The mechanism is the same hot-swap the Settings picker already has (`:1535-1536`): the change takes effect **on the next turn**, with no relaunch. And the honest bound: **from the moment the owner acts to the next turn.** During the decision window the user is not unprotected — the ladder is already covering (H-1's whole point is that the regression is *visible* before it is *actionable*).

**In-flight turns.**

- A turn whose `interpret` is already in flight **completes on the instance it started with**: `switchBaseModel` drops the loaded handle for the NEXT load (`LlamaCommandInterpreter.swift:418-422`); it does not reach into a running inference. The answer the user hears stands.
- An **already-dispatched** turn is not recalled. A revert never reverses a side effect; the confirmation flow is what gates side effects, and it is upstream and untouched.
- An **outstanding confirmation is never cancelled by a revert.** The 45 s window (`VoiceSessionStateMachine.swift:95`) belongs to the user, and a rollback that silently dropped a pending "हो" would be a regression the healing protocol itself introduced.
- The **shadow pass is cancelled** by the revert (the candidate's id changed underneath it); an abandoned pass records nothing.

**Ruling: rollback reuses the existing install path and introduces no second deployment mechanism.** There is no rollback downloader, no rollback endpoint, no rollback artifact store. The revert is (a) a preference write and (b) whatever `ModelStore` already does. T-059's check: the rollback path's call graph contains no type that is not already in the shipped install path.

### 5.3 The "healed" re-promotion rule

**A reverted candidate may be re-promoted only when all four hold:**

| # | Condition | Checkable as |
|---|---|---|
| **R-1** | **A new artifact id.** The retrained/fixed artifact publishes under a **new `ModelID`**, never the reverted one | the decision record's id differs from the reverted id; a device caches by id, so reusing it makes the re-install a silent no-op — the same reason `ModelCatalog.intentQwenS43` exists as a separate id from its predecessor (`ModelCatalog.swift:231-234`) |
| **R-2** | **The root cause is named** in the decision record, with the trigger that fired (H-1/H-2/H-3) and what changed in the artifact | the record's text; a re-promotion with no named cause is refused |
| **R-3** | **A fresh sample.** The previous session's counts do not carry over — no retention (C-21), so this is automatic rather than a discipline, which is the point of choosing no retention | a new evidence session with its own N₁/N₂ |
| **R-4** | **The full promotion rule re-applied** (§4.1, P-1…P-4), with the reversed pair re-established | a new decision record |

**And the retention rule that makes the revert possible:**

- **At promotion, the previous artifact is retained on disk** for the regression-watch window; it is **not** deleted by the promotion.
- **Release is an explicit owner act**, recorded in the decision record, taken at the promotion review once the watch window has closed. It is never automatic and never time-triggered, because a time-triggered delete is a persisted timer, and the design declines to add durable shadow state.
- **The retention costs disk** (a second 2.5 GB artifact) and that cost is why SH-4's pre-flight exists: the device must not be able to reach a promotion state in which the retention does not fit.

### 5.4 The ladder, rung by rung, under a diverging candidate

The acceptance criterion asks for rung, trigger, user-visible behaviour and recording. The table below is that, and the shadow column is the part this design adds.

| Rung | Trigger | What the user hears / sees | What is recorded | What the shadow protocol does |
|---|---|---|---|---|
| **1. Keyword safety net** (`CommandRouter.swift:707-718`, emergency at `:621`) | emergency vocabulary, explicit med-ack — **before any model, always** | the emergency flow / the ack challenge, exactly as today | `command_emergency_keyword`, `gibberish_rejected` — the shipped events | **skipped** (SD-7a). No model ran; there is nothing to compare, and the pass is disqualified on its own terms |
| **2. Intent cache** (`IntentCommandCache`) | exact normalised match on a cacheable action (`:51-65`) | the cached action, then confirmation as usual — a cache hit never skips the confirmation (`:11-13`) | `cache_hit` | **skipped** (SD-7c) |
| **3. `preferred`** (`LocalBrainChain.swift:38-69`) | `preferred.isAvailable` | the brain's answer, through the band policy (`IntentRouter.swift:306-330`) | shipped events | **this is the rung that makes a turn shadowable**: `action_id` is this rung's action |
| **4. `standIn`** (LLaMA) | `preferred` unavailable, or `abstained` / `failed` / `subBandConfidence` | the stand-in's answer, or the re-prompt when it also abstains | `encoder_escalated_to_picker_brain`-style reason events (the shipped shape) | nothing new: the *candidate's* descent to this rung is recorded as `escalation_reason` on the shadow turn |
| **5. Cloud** (`IntentRouter.escalateToCloud`, `:332-343`) | `cloudEnabled` + a cloud brain + the selection policy | the cloud's answer or the re-prompt | `interpreter_selected` with its reason | **untouched**; the cloud layer is downstream of the local slot and the shadow module has no reference to it |
| **6. Re-prompt** | no layer answered | `router.reprompt` / the rephrase question (`:319-329`) | the shipped events | **not shadowed** (no incumbent verdict to compare, §2.6) |

**Ruling (the binding form):** the ladder's behaviour under a diverging candidate is **identical to its behaviour today**, because the shadow module is not on the ladder. It has no rung, holds no reference from `CommandRouter`, `IntentRouter`, `LocalBrainChain` or `VoiceSessionStateMachine`, and reads no state those types read. The proof is a call-graph check, and it is T-060's fixture.

**And the absolute statement, because the constitution's safety stages are not negotiable:**

> **No loop artifact — shadow, mining, egress, promotion rule or healing protocol — can gate, suppress, delay, replace or reorder the emergency path, the medication-acknowledgement path, or the confirmation flow.** The keyword safety net runs before every model (`CommandRouter.swift:707-718`); `ConfirmationTier.neverGated` (`ConfirmationTier.swift:19-21`) is the constitution's rule and is not a policy the loop may influence; and the shadow pass is *skipped* on any turn those stages resolved.

---

## 6. The one-page contract

| Question | Answer |
|---|---|
| **What is shadowed?** | one eligible turn, in memory, after the turn ends |
| **What is compared?** | the incumbent's `InterpretedCommand` vs the candidate's, on action and band |
| **What crosses the bus?** | `shadow_turn` (`action_id`, `divergence_count`, `escalation_reason`, `duration_ms`) and `shadow_session` (`divergence_count`, `divergence_rate_bucket`, `duration_ms`). **Two events, four keys, no fifth** |
| **What is retained?** | nothing. No counter store, no cursor, no journal, no `UserDefaults` key. The only durable artifact is the candidate's installed file and the retained previous artifact through the watch window |
| **What is the reply-path cost?** | zero, by construction: the pass starts from `onTurnFinalized`, after `turn_end`; the `voice_turn_timing` stage set is identical for shadowed and unshadowed turns |
| **How is the cost measured?** | `duration_ms` on both events, from `ProcessInfo.processInfo.systemUptime` — the tracer's own clock |
| **When does it not run?** | feature off, safety-critical turn, confirmation outstanding, cache-resolved turn, empty normalised transcript, candidate not installed, thermal/low-power, memory pressure |
| **Sampling?** | ambient stride 5, cap 20/session; evidence stride 1, cap 140/session |
| **Guardrail?** | Wilson-95% lower bound of concordance ≥ 0.90 at N₁ ≥ 140 (≥ 133/140) |
| **Evidence?** | Clopper–Pearson 95% lower bound of candidate-favourable share of outcome-anchored discordant pairs > 0.5 at N₂ ≥ 20 (smallest instance 15/20) |
| **Who decides?** | a human, always (D-4). P-1…P-3 can only refuse |
| **What triggers a rollback?** | the same rule, reversed, over the regression-watch window; plus load failure and latency regression |
| **Who reverts?** | a human, on instrumented detection. The user is covered meanwhile by the shipped ladder |
| **How fast?** | next turn after the owner acts; no download |
| **Second deployment mechanism?** | none |
| **New runtime threshold?** | none (§7) |

---

## 7. What this design deliberately does not do: no new runtime threshold

The design's §7.3 and the task's acceptance criterion 5 are binding, and the design discharges them by drawing the line where it actually falls:

**A runtime threshold is a number read on the reply path that changes what the user hears or what the app decides.** The shadow protocol adds none. Concretely:

1. **The band policy is unmodified**: 0.7 / 0.4 are read from `IntentRouter.Config.default` (`:56-58`); the shadow module *reads* them to classify a band pair and never defines, overrides or re-passes them. `IntentRouter`, `LocalBrainChain`, `CommandRouter`, `ConfirmationTier` and `VoiceSessionStateMachine` gain **no** new parameter, field or branch.
2. **Divergence is never a runtime decision.** `divergence_count` is emitted and read by no control flow. A turn's behaviour does not depend on it, and there is no `if divergence` anywhere on the reply path.
3. **The protocol's numbers are capture-policy constants, not runtime thresholds**, and the distinction is testable rather than rhetorical: **no symbol the shadow module defines is referenced from `CommandRouter`, `IntentRouter`, `LocalBrainChain` or `VoiceSessionStateMachine`** — a call-graph check, not a reading of intent. The numbers the design introduces are exactly four (stride 5 / cap 20 / N₁ 140 / N₂ 20), every one of them is fail-off (turning shadowing off removes the behaviour entirely), and none of them is consulted while a turn is being served.
4. **The healing triggers do not gate a turn.** H-1…H-3 are read by a human; the immediate rung fall-through that protects the user is `LocalBrainChain`'s existing availability check and predates this design.
5. **NFR-002's 4 s remains a property of the reply path.** The shadow pass cannot extend a turn (§2.5) and cannot delay the next one (cancellation).

---

## 8. Conditions this design adds (C-18 … C-26)

Continuing T-054's series (which ended at C-17). Each is checkable by T-059, and each names the task that owns it.

| # | Condition | Owner | What T-059 checks |
|---|---|---|---|
| **C-18** | **`LogSanitiser.allowedKeys` gains exactly the four keys** `divergence_count`, `divergence_rate_bucket`, `action_id`, `escalation_reason` and nothing else for the loop; `divergence_count` is bounded to `{0, 1}` on `shadow_turn` and to ℤ≥0 on `shadow_session`; `divergence_rate_bucket` is the fixed five-value enum `lt_5 / 5_10 / 10_25 / 25_50 / gte_50` and is **never** a float | **T-056** | a diff of `allowedKeys` (14 → 18, exact names); a test asserting a float rate is not emitted; `record_dedup` absent by name |
| **C-19** | **No shadow event carries the transcript, either output, a slot value, `Record.id`, a session id, an install pseudonym, a turn index or a timestamp.** `action_id` is a member of the closed schema-v2 action set only | **T-056** | the emitters' metadata literals (fixed key sets, no interpolation of a command's fields); a test that a slot-bearing `InterpretedCommand` produces the same event bytes as a slot-free one with the same action |
| **C-20** | **The shadow pass is off the reply path by construction and adds no stage to a turn.** It starts from `onTurnFinalized` and is cancelled from `onTurnBegan`; the `voice_turn_timing` stage-name set of a shadowed turn is identical to an unshadowed turn's; no shadow symbol is referenced from `CommandRouter`, `IntentRouter`, `LocalBrainChain` or `VoiceSessionStateMachine` | **T-056** | the two subscription sites; a stage-set equality test; a call-graph check for the four types |
| **C-21** | **No shadow state is persisted anywhere** — no counter store, no cursor, no journal, no `UserDefaults` key beyond the enable/mode toggles, no file. The only durable artifacts are `ModelStore`'s candidate install and the retained previous artifact | **T-056** | a grep of the shadow module for every persistence type in the tree; the restart test (a killed app loses its counters and shadows again with none missing) |
| **C-22** | **The candidate never stays resident across a turn boundary**, and the memory-pressure contract reaches it (its own observer, the encoder's arm/disarm shape). A shadow pass still running when a new turn begins is **abandoned and records nothing** | **T-056** | the drop call on every exit path of the pass; the memory-warning test; the abandonment test (no event emitted for an abandoned pass) |
| **C-23** | **The ladder is unchanged and the safety stages are out of reach.** Each rung's trigger, user-visible behaviour and recording is §5.4's table; the shadow pass is skipped on safety-net, emergency, confirmation-outstanding and cache-resolved turns; no loop artifact can gate, suppress, delay, replace or reorder emergency, med-ack or the confirmation flow | **T-056 / T-060** | §5.4 against the code rung by rung; a diverging-candidate fixture proving the emergency path and the 45 s confirmation window are unaffected |
| **C-24** | **Rollback reuses the existing install path and the existing preference key, and introduces no second deployment mechanism and no new runtime threshold.** The revert is `brainPreferenceKey` + `switchBaseModel(to:)`; the retained previous artifact is released only by an explicit owner act | **T-058** | the rollback path's call graph; the absence of a rollback download/endpoint/store; the decision record's release entry |
| **C-25** | **The promotion rule requires P-1…P-4, and the shadow halves can only refuse.** A candidate with an `UNEVALUATED` or failed T-038 gate is refused whatever the shadow numbers; a candidate failing P-2 or P-3 is refused whatever the gates; publishing is the human act of P-4 | **T-058** | the gate's ordering and fail-closed branch; the decision record's required fields; a fixture where shadow passes and the corpus fails, and the reverse |
| **C-26** | **The candidate is never offered.** Its `ModelID` is absent from `availableBrainEntries`, `availableSTTEntries`, `internalTestingEncoderEntries` and every `curatedEntries(kind:)` result, so neither the Settings picker nor `defaultEntry(kind:language:)` nor `LanguageModelResolver` can select it; and the candidate resolver **adds ids without remapping any** | **T-056** | the picker lists; a resolver test that an existing id still resolves to the shipped entry byte for byte (id → sha256) with a candidate manifest loaded |

**If shadow scoring is descoped to the guardrail only (no evidence half):** C-18 narrows to `divergence_count` and `divergence_rate_bucket` (the per-turn `action_id` and `escalation_reason` lose their reader), and C-25's P-3 falls away — **C-19, C-20, C-21, C-22, C-23, C-24 and C-26 survive unchanged**, because they are properties of the mechanism, not of the decision rule: the events would still be content-free, the pass would still be off the reply path and stateless, the ladder would still be untouched, the revert would still reuse the install path, and the candidate would still be unofferable.

---

## 9. Refinements to adjacent rulings (delta table)

Seven places where this design narrows or corrects something T-053 or T-054 said or left open. Each is a refinement *with a reason*, not a reversal.

| # | Prior ruling | Refinement here | Why |
|---|---|---|---|
| **SR-1** | T-053 §3.7 r2 sanctions retention as *"counters in a dedicated content-free store"* and forbids reaching it by widening the bus | **This design declines the offered retention and chooses session-scoped, print-only counters.** | The offer is real but its cost is not: a durable counter store is a new on-device artifact with a lifetime, a deletion story and a review surface — for a number whose only consumer is a human reading a decision record. The decline also removes R-3's carry-over question entirely (§5.3): with no retention, a re-promotion *cannot* reuse a stale sample, because there is none. |
| **SR-2** | T-053 §3.7 r3 declares `divergence_count` as *"integer ≥ 0"* | **Narrowed to `{0, 1}` on the per-turn event**, and the aggregate integer lives only on the session event. | An "integer ≥ 0" is a bounded space only in principle; `{0,1}` is bounded in fact, and a per-turn count of anything but 0 or 1 is a bug the declaration should make unrepresentable. |
| **SR-3** | T-054 §8's row on the telemetry direction: *"no bus event may carry … an action/outcome id from the loop's emission"* | **`action_id` is carried, and it is the schema-v2 action enum — never the loop's `Record.action` string, even though the two are the same vocabulary today.** | T-053 §3.7 r3 explicitly permits `action_id` with the schema-v2 action set as its value space, so the two documents agree; the refinement is that the *source* is the `InterpretedCommand.Action` enum, not a string read from the log store. Same tokens, different provenance — and the provenance is what keeps the channels disjoint: the shadow module holds no reference to `IntentLogStore`. |
| **SR-4** | T-055's own task brief names *"the conditions under which it is skipped (memory pressure, safety-critical turn, feature gate off)"* | **Four more skip conditions are added**: confirmation outstanding, cache-resolved turn, empty normalised transcript, candidate not installed. | The confirmation case is the load-bearing one (§2.5 SD-7b): a 2.5 GB load inside the 45 s window can lose a confirmed action, and that would be the healing protocol causing the harm it exists to prevent. |
| **SR-5** | The task brief's *"batched"* as an option for where the shadow pass runs | **Rejected on the ruling** (SF-1, §2.1). | A queue holds transcripts across turn boundaries; T-053 §3.7 r4 forbids a shadow *event* carrying the transcript and never sanctions a shadow *store* holding one. Batching is not a slower version of the same design — it is a different collection. |
| **SR-6** | The task brief's *"capped per day"* as a sampling option | **Capped per session instead.** | A per-day cap requires a clock and a persisted counter — exactly the durable shadow state C-21 forbids. A session cap bounds the same cost with the process's own lifetime and writes nothing. |
| **SR-7** | T-053 §3.7 r5 (*"shadow scoring stays off the reply path"*) stated as a constraint to satisfy | **Made constructive**: the pass is scheduled from `onTurnFinalized` and cancelled from `onTurnBegan`, so isolation follows from *which* callback starts it, not from what the pass carefully avoids doing. | A constraint that has to be honoured by discipline is a constraint that erodes. Starting from a callback that fires after `turn_end` is appended makes the isolation unrepresentable to break — the stage list is already emitted by then. |

---

## 10. Escalations

Four items are the owner's, not this design's. Each has an action and the existing review cadence (**2026-10-13**, aligned with T-053 §10, T-054 §11, OD-11 and OD-12) rather than a new one.

**Escalation 1 — does shadow scoring ever reach a field device?** Owner: **Anjan Poudel (project owner)**. This design rules v1 **tester-only** (SH-12): a compile-time flag plus a default-OFF toggle, the `IntentEncoderFeature` pattern, with the sample collected in an evidence session the tester drives. Field shadowing is a different proposition and needs a decision, not a default: it would make each household's device the instrument for a publish decision, it would put a second 2.5 GB artifact on phones whose floor is 4 GB RAM, and it would create the first always-on measurement of a household's speech that is *not* consent-gated — a shape T-053's rulings do not currently cover, because T-053 §3.7's five conditions were written about telemetry that leaves the device, and §2.1's no-content rule is what makes them hold. Action: **rule yes or no on field shadowing, and if yes, direct what consent surface it needs** — the honest framing is that it is one more collection to be justified, not an extension of an existing one. Review by **2026-10-13**.

**Escalation 2 — the candidate artifact's hosting and distribution route.** Owner: **Anjan Poudel**. A candidate is a >2 GiB GGUF. The shipped options are ordered parts on GitHub releases (`downloadPartURLs`, already exercised by `intentQwen4BSlotCanon`, and capped by `maxMultipartTotalBytes = 3_000_000_000`) or a LAN URL (`qwen4BNepali` points at `192.168.1.117:8765`). A promotion decision's evidence would then depend on an artifact delivered over a home LAN. Action: **name the candidate hosting route and whether a LAN-only route is acceptable for an artifact whose promotion decision is cited on-device evidence**, or direct that candidates be parts-hosted like the shipped default. Review by **2026-10-13**.

**Escalation 3 — the retained previous artifact's release policy.** Owner: **Anjan Poudel**. SH-11 retains the previous artifact through the regression-watch window and makes release an explicit owner act (§5.3). Two things follow that are the owner's: **how long the window is** (this design deliberately sets no duration — a duration is a persisted timer, and C-21 forbids one), and **whether the retention is acceptable on a 4 GB-floor device at all** given SH-4's arithmetic (~5.0 GB for the pair). Action: **set the release policy, or rule that the retention is best-effort and the revert target is the ladder's `standIn` rung** (§5.2 path 2). Review by **2026-10-13**.

**Escalation 4 — the evidence session's script is an unaudited artifact.** Owner: **Anjan Poudel**. §3.4 rules that the join is the tester's, done by hand against a script the tester authored, and that the script is filed with the decision record. That is honest and reproducible, and it is also **the one input to a publish decision that no automated check constrains** — a script that happens to favour a candidate produces a favourable N₂. Action: **decide whether the evidence session's script needs a review step (e.g. a second pair of eyes on the script before the session runs), or whether the decision record's named human is the whole of the control.** Review by **2026-10-13**.

---

## 11. What this design deliberately does not decide

- **The candidate's artifact provenance and training.** Who produces it, from which corpus, under which gate run — T-057's miner and T-038's gates, not this design. Shadow scoring consumes an artifact; it does not produce or judge one.
- **The decision record's schema.** T-058 owns it; §4.3 lists only what it must contain for P-4 to be a decision rather than an assertion.
- **The precise bucketing boundaries' tuning.** `lt_5 / 5_10 / 10_25 / 25_50 / gte_50` is declared here so the value space is closed and checkable; whether the bands are the most useful bands is an operational question answerable only after sessions exist, and changing them is a value-space change requiring the same declaration (C-18) rather than a tweak.
- **Any second signal on the divergence path.** Slot-level comparison (per T-054's `slot_keys` reasoning), per-entity divergence, confidence deltas — none is carried, because each is a wider value space and none has a reader in the promotion rule. A future need for one is a new design with its own declaration, not an extension of this one.
- **The regression-watch window's duration.** Escalation 3, deliberately: it needs a clock, and C-21 forbids persisting one.
- **Whether ambient mode should exist at all on a field device.** It exists here because it is free once the evidence mode exists, and because a guardrail on real traffic is the only thing that would notice a promotion going wrong between evidence sessions. Escalation 1 subsumes it.

---

## 12. PII discipline

1. **Every example in this design is synthetic.** §2.8 uses `"<utt-A>"` and golden-corpus scenario labels. No transcript, contact, medication, message or health content appears anywhere in this document, and no number in it is derived from a real household.
2. **The four declared keys are content-free by construction, and the argument is per key** (§2.7): two closed enumerations, one two-value integer, one bounded integer — and one five-value rate band. There is no free-text field, no map, no identifier of any kind, and no value whose domain is "any string".
3. **T-049/T-050's precedent holds**: content must not reach a log sink **even when it would be diagnostically convenient** (`LogSanitiser.swift:22-49`). The convenience this design declines is the candidate's action id, which would make debugging a candidate much easier and is refused anyway (§2.7's `action_id` row).
4. **The bus prints and is not consent-gated** (`ConsoleObservabilityBus` → `print`, `AppCoordinator.swift:7844-7849`). That is precisely why the values are enumerations and integers, and why nothing derived from the loop's content store, cursor or consent record may ride it (T-054 §8).
5. **`record_dedup` is not added, and the reason is stated in T-054 §8's own words**: the bus's existing hashes are unsalted SHA-256 while `record_dedup` is salt-keyed precisely so that opt-out destroys linkability; a bus-printed `record_dedup` would put an egress pseudonym into a console log with no consent and no deleter.
6. **The evidence session's script is the tester's own document and contains no household data by construction** — the tester authored the utterances, and the session runs on the tester's device. This is the property that lets §3.4's hand-join be content-free at both ends.
7. **No shadow artifact lengthens the retention of anything.** With no counters retained and nothing joined on-device (§3.4), the protocol adds **no** new data-at-rest and **no** new deletion obligation — which is what lets C-21 be a two-line check.

---

## 13. Hand-off

| Task | What it takes from this design | Where |
|---|---|---|
| **T-056** (capture egress implementation; also implements the shadow-side capture) | SH-2/SH-3 (candidate entry + resolver), SH-4 (pre-flight), SH-6 (stride/modes), SH-7 (the two seams), SH-8 (**the four `allowedKeys` additions with their value spaces**), §2.6's load-infer-drop, §2.9's gate, and C-18…C-23, C-26 | §2, §8 |
| **T-058** (promotion gate implementation) | SH-9/SH-10 (P-2/P-3 and the reversed rule), §4.3 (what the decision record must cite), §5.2–§5.3 (revert mechanics and the re-promotion rule), C-24, C-25 | §4, §5 |
| **T-060** (loop end-to-end fixture; proves the ladder holds when a candidate diverges) | §5.4's rung-by-rung table is the fixture's spine: for a diverging candidate, every rung's trigger, user-visible behaviour and recording must be identical to today's, and the emergency path and the 45 s confirmation window must be provably unaffected | §5.4, C-23 |
| **T-059** (audit) | C-18…C-26 and SR-1…SR-7; the four numbers (stride 5 / cap 20 / N₁ 140 / N₂ 20) and the two interval rules (Wilson ≥ 0.90 at 133/140; Clopper–Pearson > 0.5 at 15/20) | §3, §8, §9 |
| **T-054** (channel boundary, already landed) | This design **adds no fifth key and no payload field**; T-054 §8's two-way disjointness is preserved from this side (§2.7, SR-3) | §2.7 |
| **The owner** | Escalations 1–4, review by **2026-10-13** | §10 |

**One item escalated *to* this design's successors rather than the owner, recorded so it is not lost:** *T-056 must declare the four keys in `LogSanitiser` **before** it writes an emitter*, because SF-3 shows what the reverse order produces — three shipped emitters whose metadata is silently dropped, and a dashboard that has been reading nothing. The declaration is the mechanism; dropping is the backstop.
