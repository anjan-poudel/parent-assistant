# Voice-Turn OOM Hardening — Task Brief (2026-10-10)

## Diagnosis (device evidence, do not re-litigate)

Anzaan (iPhone 14 Pro Max, 6 GB, iOS 26.6.2 beta 23G90, uptime since Oct 6) was jetsam-killed
twice on 2026-10-10 (08:57:38, 08:59:08), both `vm-pageshortage`, both while the user talked and
the app acknowledged. Two layers:

1. **System layer (dominant):** wired memory leaked from the healthy 1.0–1.6 GB baseline (Sep 17 –
   Oct 7 events) to 4.69/4.78 GB; free ~30 MB; jetsam killed 93/105 processes per event. The app's
   own IOKit/wired contribution was ≤153 MB and its rpages peak (527–741 MB) matches weeks where it
   was never killed. The app is the largest process → prime victim. Mitigation = reboot + get off
   the beta; NOT app code.
2. **App layer (our lever):** the device runs an explicit **4B brain pick**
   (`brainModelPreference = intent-ne-qwen4b-slotcanon-q4km`, ~3.4 GB live, admitted
   `soloOverBudget`) with encoder cascade ON. Per turn the ledger evicts STT (1.0 GB v6 ANE) to
   page in the 4B, then `WhisperPostTurnPolicy` holds + background re-warms STT after each turn,
   which evicts the brain again. ~4.4 GB of model churn per conversation, spiking exactly at the
   pre-ack moment (brain page-in while ack WAV plays). The kill lands mid-page-in (lifetimeMax
   741 MB vs 2.33 GB file).

## Changes (in this worktree only)

All paths relative to `ios/ElderlyAssistant/`. Verify each anchor before editing; the line numbers
below come from a code map — re-check with grep.

### A. Stop the per-turn 4B↔STT eviction ping-pong (highest value)
- `Services/Voice/WhisperPostTurnPolicy.swift` (~:114-127): the post-turn hold of STT must NOT
  fire when the active brain is over-class-budget (4B `soloOverBudget`). In that case release STT
  after the turn and do not re-warm it in the background (the brain stays resident; STT reloads
  per turn at ~1.0 GB instead of the brain reloading at ~3.4 GB).
- `App/AppCoordinator.swift` (~:5939-5978 applyPostTranscriptWhisperPolicy, ~:5983-6023 TTL
  re-warm): honor the same rule for the re-warm arm.
- Generalize: holds/re-warms must also check real headroom — `os_proc_available_memory()`
  ≥ footprint + active brain live bytes + margin (≥ 512 MB), not just ≥ footprint.

### B. Turn-start admission guard (prevents death on a sick system)
- `Services/Voice/LlamaCommandInterpreter.swift` `loadLLMHandle` (~:1075-1189): before reserving
  `.brain`, if kernel pressure is warn/critical (manager already tracks it) or
  `os_proc_available_memory()` < model live bytes + margin, refuse with a typed error; the router
  should fall back to the deterministic/lightweight reply path (and the pre-ack already played).
  Do not let `soloOverBudget` admission run on a critical system.

### C. Boot warm gating
- `Services/Voice/WarmStart.swift` (~:160-182, ~:223-258): consult
  `os_proc_available_memory()` before warming STT and the brain; skip a warm when it would leave
  < 1 GB free after the warm. Re-arm on next turn if skipped (existing first-use prewarm covers
  STT; brain loads on first inference anyway).

### D. Encoder hygiene
- Encoder slot registered `evictable: false` (AppCoordinator ~:8995-9004): make it evictable so
  critical pressure can drop the 144 MB; the level-2 handler already re-arms it per turn.
- Confirm the encoder installer (`installLocalBrainSlot` / `requestReadiness`) cannot run
  mid-turn; if it can, defer to boot/idle with a pressure gate.

### E. STT default repoint (small, prevents the trap on other devices)
- `Services/Voice/WhisperKitSpeechRecognizer.swift` (~:150-152): default `preferredModelID` from
  `whisperKitNepaliMedium` (2.0 GB fp16 v3) to `whisperKitMediumV6` (the language default).

## Verification (scoped, per repo convention)

- Typecheck: the worktree's build script or `xcodebuild build` is NOT required; run focused unit
  suites for the touched types via the repo's test harness (scoped `-only-testing` where the full
  bundle has a known red baseline). Suites: WhisperPostTurnPolicy tests, ModelLifecycleManager
  tests, interpreter tests, WarmStart tests if present.
- Add/adjust focused tests for: (A) post-turn policy with over-budget brain → release+no-rewarm;
  (B) turn-start refusal under critical pressure → router falls back; (C) warm skipped under low
  headroom.
- No full-suite runs. No commits to master. Push the branch when done; PR against master with the
  device-checklist merge gate (device smoke on Anzaan: conversation → no jetsam, pull JetsamEvent
  logs after).

---

## HANDOFF NOTE (2026-10-10 — workstream stopped, owner redirected via ai-sdd)

Branch `worktree-voice-oom-hardening` (worktree `.claude/worktrees/voice-oom-hardening`) stopped
mid-flight per the redirect. No push, no PR. This doc was untracked; it is committed with this
note.

**Commits on this branch (`git log --oneline master..HEAD`):**

```
22103bc Stop the per-turn 4B-STT eviction ping-pong in the post-turn policy   → change A
30514b2 Make the encoder slot evictable so critical pressure can drop it      → change D
56073e8 Repoint ANE recognizer default to whisperKitMediumV6                  → change E
```

**Done (committed, committed-state code — but see "Tests: none executed" below):**

- **E** (56073e8) — `WhisperKitSpeechRecognizer` init `preferredModelID` default →
  `ModelCatalog.whisperKitMediumV6` (+ doc comment). `AppCoordinator.whisperKitSpeechRecognizer`
  factory fallback (`sttModelPreference ?? …`) also repointed — it SHADOWS the init default at
  the only production construction site, so both had to move. 4 test pins updated in
  `WhisperKitSpeechRecognizerTests`.
- **D** (30514b2) — encoder slot registered `evictable: true` (was `false`) with a corrected
  rationale comment in `registerEncoderSlotIfNeeded`; new manager test
  `testCriticalPressureEvictsTheLightEncoder` in `ModelLifecycleManagerTests`. Installer half
  confirmed (installLocalBrainSlot runs at composition / Settings-toggle didSets only;
  `requestReadiness` is a background disk install, not a load) — recorded in the commit body, no
  code change needed.
- **A** (22103bc) — `WhisperPostTurnPolicy`: new `ActiveBrain`, `ReleaseReason`
  (brain_over_budget / ram_headroom / ram_critical), `headroomMarginBytes` = 512 MB, 3-tier
  `decide` (over-budget brain short-circuits FIRST → then critical floor → then
  weights + resident brain live bytes + margin); `AppCoordinator.activeBrainResidency` (ledger
  `isResident`/`footprint`/`snapshot().classBudgetBytes`), reason tokens emitted on
  `post_transcript`/`rewarm`; `runBackgroundWhisperReWarm` re-probes the same generalized gate.
  Policy tests reshaped + new: over-budget short-circuit, resident-brain arithmetic, marginal
  headroom, full `transcriptAction` path.

**In-flight (UNCOMMITTED, left in the working tree as-is):**

- **C — HALF DONE.** `ios/ElderlyAssistant/Services/Voice/WarmStart.swift` has +52 uncommitted
  lines: `WarmStartConfig.availableProcessMemoryBytes / sttWarmFootprintBytes /
  brainWarmFootprintBytes` (all `= nil` → ungated by construction, so existing call sites compile
  unchanged), `WarmStartPlanner.warmHeadroomFloorBytes` (1 GB), private `lowHeadroomReason` gate
  wired into `sttStep` and `llamaStep` (skip reason `"low_headroom"`). REMAINING to finish C:
  1. Wire `AppCoordinator.startBootWarmPhase` (~:4221) — supply
     `availableProcessMemoryBytes: MemoryProbe.availableProcessMemoryBytes`,
     `sttWarmFootprintBytes: whisperFootprintBytes` (the existing post-turn property),
     `brainWarmFootprintBytes: ModelLifecycleInventory.footprint(for: .brain, modelID:
     llamaCommandInterpreter.baseModelID).liveBytes`.
  2. WarmStartTests cases: low-headroom skips STT / brain; generous headroom = default plan;
     partial headroom warms STT while the brain steps aside; ungated when memory inputs absent.
  Until wired, the new gate is inert (never receives memory inputs).

**Not started:**

- **B'** (owner amendment, REPLACES brief B — the typed-refusal design is superseded): per-turn
  pressure-tiered brain pick before the brain load, consulting the manager's kernel-pressure
  level + `os_proc_available_memory()`. normal → remembered/explicit pick unchanged.
  warn/critical → step down to the largest INSTALLED curated brain for the active language whose
  live bytes fit `available − safetyMargin` (margin ≥ 768 MB suggested, covering page-in
  headroom); candidates ordered largest live-bytes first; INSTALLED ONLY, never trigger a
  download under pressure. On the device: 4B → Qwen3-1.7B (~1.98 GB live) → 1B (~1.8 GB live).
  Nothing fits (the sick device's ~30 MB free) → nil pick → the router's EXISTING
  lightweight/deterministic reply fallback (pre-ack already played) — that is the terminal case
  where the original B refusal survives. Pick ≠ interpreter's current model → existing
  `switchBaseModel` seam (`LlamaCommandInterpreter` ~:585-592). Prefer a new small injectable
  `PressureBrainPickResolver` (pure function signature); reuse `LanguageModelResolver
  .resolvedAutomaticPick` (LanguageModelResolver.swift:235-302) walk shape and
  `ModelBudgetPolicy.availability` (:370-406), fit-computed against real free memory instead of
  class budget. Tests: tier walk (warn + 2.0 GB free → 1.7B; warn + 1.0 GB → 1B; critical + tiny
  → nil), installed-only filtering, no-download guarantee, normal pressure keeps explicit pick.
- **F** (owner amendment, added DURING this task): degraded-mode status indicator. When a turn
  resolves to a degraded brain (any pick ≠ remembered/explicit) or the lightweight canned path:
  small unobtrusive status pill on the main screen, visible during the degraded turn and while
  pressure keeps the tier active; auto-hide when the next turn resolves back to the remembered
  pick. Placement near header / just above dock, matching the app's visual language; must NOT
  block the mic/voice UI; check for an existing transient-status pattern (pre-ack /
  live-translate) to reuse rather than a new UI subsystem. State plumbing: publish per-turn
  outcome (normal / smallerBrain / lightweight) from the resolver decision through the existing
  `@Observable` state the Home/voice screen watches; keep it tiny. Copy (centralized, localized
  ne/en): ne smaller-brain "सरल मोड — कम मेमोरी", en "Simple mode — low memory"; ne lightweight
  "सरल जवाफ — कम मेमोरी", en "Simple answer — low memory" (first pass, owner will tune). Visual:
  subtle low-contrast pill, small caption size, informative — never error-looking; no sound,
  haptics, or interruption. Tests: pure state transitions (normal → smallerBrain → normal
  recovery; smallerBrain → lightweight); the view renders the current state only.

**Tests: NONE EXECUTED in this worktree.** No scoped suite has been run; no `DerivedDataTests`
has been built. Every test listed above is written in the committed sources but its pass/fail is
UNVERIFIED on this branch — do not report them as passing. When resuming, run focused scoped
suites with the same xcodebuild invocation shape as `ios/test-impacted.sh` (lines 140-160 —
project/scheme/destination there), passing explicit flags instead of the harness selection
(`AppCoordinator.swift`/`CommandRouter.swift` are harness "hub" files and would fall back to the
FULL unit target, which has a known red baseline):
`-only-testing:ElderlyAssistantTests/WhisperPostTurnPolicyTests`,
`-only-testing:ElderlyAssistantTests/WhisperKitSpeechRecognizerTests`,
`-only-testing:ElderlyAssistantTests/ModelLifecycleManagerTests`,
`-only-testing:ElderlyAssistantTests/WarmStartTests` (+ whatever B'/F tests get added).

**Hazards carried from project memory:** worktree DerivedData ≈ 4.5 GB each — prune before/after;
first scoped run in this worktree pays a full cold build.
