# Voice-Turn OOM Hardening — implement-fix summary (2026-10-10)

Workflow: `quickfix-voice-turn-oom-hardening` · Task: `implement-fix`
Branch: `worktree-voice-oom-hardening` @ base `688f980` (seeds 56073e8 E,
30514b2 D, 22103bc A, 870d186 brief, 688f980 WIP C)
Worktree: `.claude/worktrees/voice-oom-hardening`
New commits on this branch (not pushed, no PR):

| Commit | Contents |
| --- | --- |
| `a927fc1` | Fix the preference-change test pin for the v6 default repoint (seed-A/E follow-up, test-only) |
| `2621b3b` | Finish change C — wire the boot warm's headroom-gate inputs + WarmStartTests |
| `ffbe6ae` | Change B′ — `PressureBrainPickResolver` + per-turn pick + terminal load refusal + tests |
| `18c33c5` | Change F — degraded-mode status pill (ne/en) + tests |

Left uncommitted on purpose: `.ai-sdd/**` run scaffolding, `build/`
(untracked build products), and a pre-existing unrelated local edit to
`ios/TimerAlarmWidget/Info.plist` (CFBundleVersion 10→1, present before
this task; not touched by it).

---

## 1. Compile-check + scoped baseline on the SEED state (deliverable 1)

Command (the HANDOFF NOTE's `-only-testing:` shape, `xcodebuild test` — NOT
`build` — with the explicit simulator UDID; a bare "latest" destination
does not resolve on this Intel host):

```
xcodebuild test -project ios/seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination 'platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2' \
  -derivedDataPath build/DerivedDataTests \
  -only-testing:ElderlyAssistantTests/WhisperPostTurnPolicyTests \
  -only-testing:ElderlyAssistantTests/WhisperKitSpeechRecognizerTests \
  -only-testing:ElderlyAssistantTests/ModelLifecycleManagerTests \
  -only-testing:ElderlyAssistantTests/WarmStartTests
```

**MUST-CHECK outcome: PASS.** The whole app + test target compiled (first
run = full cold build, 2283 SwiftCompile lines; the only "error:" strings
in the log are the word `error` inside whisper.cpp C++ sources). Change A's
`WhisperPostTurnPolicy.ResidencyConfig: Equatable` conforms and its tests
run — `VoiceEngineStack` is a `String` raw-value enum, so the synthesized
conformance holds. No fix was needed.

Observed seed-state suite results (log `build/logs/seed-scoped2.log`):

| Suite | Result |
| --- | --- |
| ModelLifecycleManagerTests | 81 tests, 0 failures |
| WarmStartTests | 27 tests, 0 failures |
| WhisperPostTurnPolicyTests | 19 tests, 0 failures (change A green) |
| WhisperKitSpeechRecognizerTests | 14 tests, **3 failures — 1 test** |
| Total | **141 tests, 3 failures** |

The one seed failure is a genuine regression introduced by seed change E
(56073e8): `testPreferenceChangeEmitsOneContentFreeEvent` assumed the
recognizer's default artifact was NOT v6, but E repointed the init default
to `whisperKitMediumV6`, making the test's first `setPreferredModel(v6)` a
deliberate same-value no-op — zero events, three assertion failures
(`WhisperKitSpeechRecognizerTests.swift:195/196/198`). Fixed in `a927fc1`
(move the recognizer off the default first; the test's intent is
unchanged). The suite passes 14/14 in the final run.

*(First run attempt, `build/logs/seed-scoped.log`, failed at simulator
INSTALL — `MIInstallerErrorDomain invalid symlink … Payload/ElderlyAssistant.app/tts/…`
— because the worktree carried the gitignored model artifacts as symlinks
into the main checkout and iOS validates that no bundle symlink escapes.
Resolved by materializing real copies (640 MB total: whisper bin, kws, 2
TTS voice dirs) in the worktree. Environment note only — no product
impact.)*

## 2. Per-change status after this task

| Change | Status |
| --- | --- |
| A — post-turn 4B↔STT eviction policy | Seeded (22103bc); **verified green on this tree** (19 tests). Unchanged. |
| D — encoder slot evictable | Seeded (30514b2); verified green (ModelLifecycleManagerTests 81 tests, incl. `testCriticalPressureEvictsTheLightEncoder`). |
| E — STT default repoint to v6 | Seeded (56073e8); verified green after the `a927fc1` pin fix (14/14). |
| C — boot warm headroom gate | **COMPLETED.** `AppCoordinator.startBootWarmPhase` (config build at ~:4235) now supplies `availableProcessMemoryBytes: MemoryProbe.availableProcessMemoryBytes`, `sttWarmFootprintBytes: whisperFootprintBytes`, `brainWarmFootprintBytes: ModelLifecycleInventory.footprint(for: .brain, modelID: llamaCommandInterpreter.baseModelID).liveBytes`. The planner gate (seeded) skips a warm that would leave < 1 GB free, reason `low_headroom`; TTS is exempt by design. |
| B′ — pressure-tiered brain pick (owner amendment) | **IMPLEMENTED** (see §3). |
| F — degraded-mode status pill (owner amendment) | **IMPLEMENTED** (see §3). |

## 3. What was built

### B′ — pressure-tiered brain pick, before the load

New `ios/ElderlyAssistant/Services/Voice/PressureBrainPick.swift`:

- `PressureBrainPick` — `.keep` / `.stepDown(ModelID)` / `.lightweight`.
- `PressureBrainPickResolver` — pure, IO-free; `liveBytes` is an injected
  closure (production default reads `ModelLifecycleInventory`).
  - Freshness: delegates to `LocalBrainTranslationTier.pressureDeferral`
    (the existing latch doctrine: stale warning/critical ages out on a 30 s
    window — mirroring `LiveTranslateConfig.brainTranslationCriticalPressureWindowSeconds` —
    a recent critical counts even after the level reads normal, a
    hand-built reading with no ages is treated as fresh). Added: if
    `available < 768 MB` the arithmetic engages even with no kernel signal
    (the sick-device ~30 MB case with a latched/normal level).
  - Fit: `available ≥ liveBytes + 768 MB` (`safetyMarginBytes`, the same
    constant the load site uses).
  - Rules: candidates = the remembered pick (leads, bypasses the language
    gate, caps the size — never up) + curated ∩ installed ∩
    language-compatible; largest live-bytes wins (`max(by:)` keeps the
    first of equal sizes); nothing fits → `.lightweight`; normal pressure
    (not engaged) → `.keep` with no arithmetic at all.
- Applied per turn in `AppCoordinator.recordTranscript` → new
  `applyPressureBrainPickForTurn()`: `.stepDown` swaps via the existing
  `llamaCommandInterpreter.switchBaseModel(to:)` seam; `.keep` swaps BACK
  when an earlier turn stepped down (recovery); `.lightweight` drops any
  resident handle (`unloadModel()`) so the refusal is real. The stored
  preference is never touched — Settings keeps showing the household's
  pick. Gated on `llamaCommandInterpreter.isAvailable` only: wherever the
  local brain can load, the pick protects that load (both stacks — the
  `.gemini` stack is local-first hybrid and its first tier is the same
  load).
- Terminal refusal at the load site: `LlamaCommandInterpreter.loadLLMHandle`
  refuses, before registering/reserving anything, when
  `PressureBrainPickResolver.pressureRefusesLoad(...)` holds — the SAME
  shared predicate, so pick and gate can never disagree. Emits
  `model_load_denied:pressure_low_headroom`; the caller sees the existing
  `.insufficientHeadroom` → router's deterministic-reply fallback.
- Observability: one content-free `pressure_brain_pick` event per
  non-`.keep` pick (`step_down` with `from`/`to` catalog ids, or
  `lightweight`); the healthy path stays silent.

### F — degraded-mode status pill

- `DegradedVoiceMode` (`.normal` / `.smallerBrain` / `.lightweight`) with
  the pure `resolved(from:)` mapping, published per turn on the
  coordinator as `@Published private(set) var degradedVoiceMode`
  (`publishDegradedVoiceMode` main-hops defensively).
- `DegradedModeStatusPill` (RedesignComponents.swift) rendered in
  `HomeView` directly below the top bar, outside the scroll: caption-sized
  `warmFont` text in secondary ink on the standard card surface —
  low-contrast, no glyphs, no accent colour, non-interactive, no sound or
  haptics. Renders NOTHING for `.normal` (auto-hides on recovery), opacity
  transition respecting reduce-motion.
- Copy centralized + localized ne/en in `Localizable.xcstrings`:
  `home.degradedMode.smallerBrain` = ne "सरल मोड — कम मेमोरी" /
  en "Simple mode — low memory"; `home.degradedMode.lightweight` =
  ne "सरल जवाफ — कम मेमोरी" / en "Simple answer — low memory"
  (first pass — owner will tune).

## 4. Verification (final, after all changes)

Same command as §1 plus
`-only-testing:ElderlyAssistantTests/PressureBrainPickTests`
(log `build/logs/impl-scoped2.log`; one earlier iteration,
`impl-scoped1.log`, caught and fixed a wrong-type reference —
`pressureDeferral` lives on `LocalBrainTranslationTier`, not
`LocalBrainDeferral`):

| Suite | Result |
| --- | --- |
| ModelLifecycleManagerTests | 81 tests, 0 failures |
| PressureBrainPickTests (new) | 22 tests, 0 failures |
| WarmStartTests (+5 cases) | 32 tests, 0 failures |
| WhisperKitSpeechRecognizerTests | 14 tests, 0 failures |
| WhisperPostTurnPolicyTests | 19 tests, 0 failures |
| **Selected tests** | **168 tests, 0 failures — TEST SUCCEEDED (exit 0)** |

New coverage highlights: the tier walk (warn + 4.5 GB → keep; warn +
3.0 GB → 1.7B; warn + 2.0 GB → lightweight; critical + 30 MB →
lightweight), freshness doctrine (stale warning ages out; recent critical
under normal level still tiers), installed-only / no-download / never-up /
curated-pool guarantees, the language gate (ne-only brain invisible to an
en household; explicit remembered pick bypasses it), the shared
load-refusal matrix, production inventory wiring, and the F state
transitions (`normal → smallerBrain → normal`; `smallerBrain →
lightweight`; pill copy in both languages; `.normal` renders nothing).

Not run: the full unit bundle (known red baseline, out of scope per the
handoff). No device tests here — device checks are the merge gate (§6).

Integration honesty: B′ has two call sites sharing one predicate — the
per-turn pick (coordinator) and the terminal load refusal (interpreter).
The predicate itself is unit-pinned in both directions; a true
end-to-end load-under-pressure test needs a device (the simulator has no
real jetsam ceiling and the scoped suites must not load multi-GB brains),
so final integration proof is the device merge gate. F's view renders only
`DegradedVoiceMode.pillText(locale:)`, which is fully pinned.

## 5. Design decisions (no HIL — logged for review)

1. **Margin = 768 MB**, the handoff's conservative end ("≥ 768 MB
   suggested"), as one shared constant used by the pick AND the load gate.
2. **The handoff's illustrative tier numbers assumed a smaller effective
   margin** ("warn + 2.0 GB free → 1.7B"). With the shipping inventory
   numbers (4B ≈ 3.4 GB live, 1.7B ≈ 1.98 GB live) and the 768 MB margin,
   2.0 GB free fits NOTHING (1.7B needs ≈ 2.75 GB) → lightweight. Tests
   pin the real arithmetic; the property that survives is the ladder
   (bigger brain first, largest that fits, never up). The margin constant
   is a one-line tune if the owner prefers the illustrated numbers.
3. **Candidate pool = curated entries only** (the Settings picker's pool).
   The handoff's "…→ 1B" rung maps to hidden artifacts
   (`intentGemma1B` / `llama3_2_1B`) which are not offered anywhere —
   pressure must not resurrect them. Documented; pinned by
   `testHiddenArtifactsAreNeverPickedByPressure`.
4. **`pressureRefusesLoad` under normal pressure refuses only below the
   margin itself** (catastrophic case), never the plain over-budget
   admission — the explicit 4B pick's `soloOverBudget` contract on healthy
   devices is untouched.
5. **Freshness window 30 s**, reusing `LocalBrainTranslationTier
   .pressureDeferral` so the latch doctrine has one implementation.
6. **Pill publishes on `.keep` recovery too**, so it hides the moment the
   remembered pick is back — no timers, no history.
7. **Warm gate scope: STT + brain only** (TTS is tens of MB — exempt).
8. Seed change E's broken test pin fixed rather than left red — it is
   inside the scoped suites and its failure was a seed regression, not a
   new one.

## 6. Recorded merge gate (NOT executed here)

Per the workflow scope, merging this branch requires, on the Anzaan
device:

1. A real conversation turn (talk → ack → reply) with the explicit 4B pick
   active — **no jetsam kill**.
2. A fresh `JetsamEvent` log pull after the smoke, compared against the
   2026-10-10 08:57/08:59 events.

Out of app scope (recorded in the brief, not a blocker for this task):
the dominant system-layer wired-memory leak on the iOS 26.6.2 beta
(4.69/4.78 GB wired; the app's own contribution ≤ 153 MB) — mitigation is
reboot + leaving the beta, not app code.
