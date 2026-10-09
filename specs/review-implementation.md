# Review — implementation, voice-turn OOM hardening (quickfix-voice-turn-oom-hardening)

Artifact under review: the `worktree-voice-oom-hardening` worktree (branch `worktree-voice-oom-hardening`; base `688f980`, on top of seeds `56073e8` E, `30514b2` D, `22103bc` A, `870d186` brief) and the implement artifact `specs/fix-summary.md`, for task `review-implementation`.
Read with: `.ai-sdd/workflows/quickfix-voice-turn-oom-hardening.yaml` (SEED / IMPLEMENT SCOPE), `docs/2026-10-10-voice-oom-hardening-brief.md` including its HANDOFF NOTE, `constitution.md` Standards, and the seed commits themselves.
Method: verification re-derived read-only — the full `git diff master...HEAD` and each of the ten commits read individually, every changed and supporting source read directly, the ne/en pill copy byte-compared against the brief, the scoped-run logs re-read, and the one semantic dependency (`max(by:)` tie order) re-checked empirically on the review host (Swift 6.3.3: an equal-key tie returns the FIRST of equals). No build or test was re-run (the developer's scoped runs are the evidence of record; device work is the merge gate). Nothing under review was modified.

## Summary

GO. All seven scrutiny areas resolve clean. A, D and E are seeded and verified green on this tree; C is finished with real inputs (probe, STT footprint, brain live bytes) and a gate that provably skips; B' is complete with the never-download / installed-only / curated-only / never-up guarantees and ONE shared arithmetic between the per-turn pick and the terminal load-site refusal, so the two can never disagree; F renders the brief's copy byte-identically, non-interactively, and hides itself on recovery. The one seed regression (E's broken test pin) is fixed by `a927fc1` as a genuine intent-preserving repair, not a masked defect. The final scoped run is green (168 tests, 0 failures, TEST SUCCEEDED) and the reviewed content is byte-identical to the compiled content (mtimes + clean tree, section 8). Scope is clean: the pre-existing `ios/TimerAlarmWidget/Info.plist` edit and `.ai-sdd/**` scaffolding are not committed. The 768 MB margin deviation from the handoff's illustrative tier numbers is honestly documented, arithmetically justified, and leaves the ladder property pinned by tests. The device merge gate remains correctly outstanding as post-merge work. Non-blocking observations are recorded in section 11; none requires rework.

### 1. Change E — STT default repoint to `whisperKitMediumV6` (56073e8) — verified

- Recognizer init default is `preferredModelID: ModelID = ModelCatalog.whisperKitMediumV6` (`WhisperKitSpeechRecognizer.swift:159`), with the doc updated at :153 (v6 ≈ 1.0 GB live, the superseded fp16 artifact retired). The coordinator's construction passes the stored preference with the v6 fallback: `preferredModelID: sttModelPreference ?? ModelCatalog.whisperKitMediumV6` (`AppCoordinator.swift:1269`).
- Repointing flows through `setPreferredModel(_:)` (`WhisperKitSpeechRecognizer.swift:223`), which adopts an id only on change — the same-value no-op guard that section 7's regression fix leans on.
- Pinned by the 4 seeded pins in `WhisperKitSpeechRecognizerTests.swift` (:106-:149 region): default/effective id is v6, the v6 artifact path is used, preference changes emit one content-free event, same preference emits none.

### 2. Change D — encoder slot evictable (30514b2) — verified

- The ANE encoder slot is now registered `evictable: true` (`AppCoordinator.swift:9184`, inside `registerEncoderSlotIfNeeded()` at :9179; rationale comment at :9168), so the critical-pressure sweep can drop the ~140 MB light slot alongside the heavy models. The corrector slot stays deliberately `evictable: false` (`AppCoordinator.swift:9013-9017`) — it is a ~2.6 MB static lexicon, and that intent is unchanged.
- The rewritten rationale ("the idle sweep never touches a light slot; the `.warning` squeeze takes heavy models first") checks out against the manager: `evictIdle` guards on `entry.footprint.isHeavy` (`ModelLifecycleManager.swift:2178`), and `handleMemoryPressure` squeezes LRU heavy-first (`lruEvictionOrderLocked`, same file). So making the encoder evictable does not hand it to the routine sweeps — it changes only the critical path, which is the intent.
- Pinned by `testCriticalPressureEvictsTheLightEncoder` (ModelLifecycleManagerTests; suite 81/0 in the final run).

### 3. Change A — post-turn eviction policy (22103bc) — verified

- The tier order in `decide` (`WhisperPostTurnPolicy.swift:153-165`) is exactly as briefed: (1) brain over class budget → `.releaseOnly(.brainOverBudget)` first, no headroom arithmetic (:157); (2) `available < footprint` → `.releaseOnly(.ramCritical)` (:160); (3) hold iff `available >= footprint + brain.liveBytes + headroomMarginBytes` (:164-165), else `.releaseOnly(.ramHeadroom)`. Margin 512 MB is the named constant (`:84`); `Decision.releaseOnly(ReleaseReason)` carries the typed reason (`:91`); `transcriptAction` (:193-:216) is the unchanged transcript surface.
- This is what stops the per-turn 4B↔STT ping-pong: with D in place, the over-budget short-circuit releases the brain rather than cycling the encoder. `ResidencyConfig: Equatable` conforms (compile-checked by the seed run; `VoiceEngineStack` is a String raw-value enum).
- Pinned by the reshaped suite (19/0): `testWeightsFitWithMarginHolds`, `testMarginalHeadroomReleasesOnly`, `testOverBudgetBrainForcesRelease`, `testResidentBrainCountsAgainstTheHeadroomGate`, `testTranscriptActionOverBudgetBrainReleases`.

### 4. Change C — boot-warm headroom gate, finished (688f980 + 2621b3b) — verified

- `WarmStartConfig` gained the three optional inputs (`WarmStart.swift:141`, `:144`, `:147`; `nil` = ungated), the floor is `warmHeadroomFloorBytes = 1_000_000_000` (:173), and `lowHeadroomReason` (:179-:183) returns `"low_headroom"` iff `available < footprint + floor`. The gate is consulted in the whisperKit STT step (:208-:210) and the llama step (:245-:247).
- The wiring is REAL, not inert: `startBootWarmPhase` (`AppCoordinator.swift:4221`) builds the config with `availableProcessMemoryBytes: MemoryProbe.availableProcessMemoryBytes`, `sttWarmFootprintBytes: whisperFootprintBytes`, and `brainWarmFootprintBytes: ModelLifecycleInventory.footprint(for: .brain, modelID: llamaCommandInterpreter.baseModelID).liveBytes` (config block ~:4239-:4253, with the rationale comment). These are the same probes the post-turn policy consumes — one account of the device.
- Gate behavior pinned by the 5 new WarmStart cases (suite 32/0): below-floor skips STT + brain; generous keeps the default plan; the small STT footprint warms while the multi-GB brain is skipped (partial plan); the boundary exactly at the floor warms (`<` not `<=`); inputs absent = ungated (so no device's plan changes when the probe is unavailable).
- TTS exemption is intentional and recorded (fix-summary section 5.7): TTS artifacts are tens of MB, the gate covers the ~1 GB ANE weights and the multi-GB brain only. The whisper.cpp STT branch remains ungated — see section 11, observation (2).

### 5. Change B' — pressure-tiered brain pick + terminal load refusal (ffbe6ae) — verified

- Resolver core (`PressureBrainPick.swift`, read in full, 235 lines): margin `safetyMarginBytes = 768_000_000` (:78); freshness window 30 s (:89), delegated to the existing latch doctrine `LocalBrainTranslationTier.pressureDeferral` (:108-:110) so there is one implementation of "a stale warning/critical ages out; a recent critical counts under a normal level; no ages = fresh". `pressureEngages` (:102-:117) additionally engages when `available < margin` even with no kernel signal (the sick-device ~30 MB case). `pressureRefusesLoad` (:123-:136) is the single shared predicate = engages AND `available < liveBytes + margin`.
- `resolve` (:145-:192): the remembered pick leads the candidate list and caps the size (never up, :163-:174); the pool is `ModelCatalog.curatedEntries(kind: .llamaBase)` ∩ `installedModelIDs` ∩ language-compatible (:171-:174); the fit filter re-checks installed and applies the same `pressureRefusesLoad` (:176-:187); the winner is `fitting.max(by: liveBytes <)` (:188) — largest live bytes that fits; `.keep` iff best == remembered (:191). The tie rule (`max(by:)` keeps the first of equals) was re-checked on the review host: `swift -e '…max(by: { $0.b < $1.b })…'` printed `remembered` for equal keys, matching the in-repo doctrine stated in `LanguageModelResolver.resolvedAutomaticPick`.
- Never-download is traceable, not asserted: the pool is the curated Settings list only, the installed set comes from `modelStore.isCached` reads, and nothing in `PressureBrainPick.swift` or the pick call path touches a download API (full read). Pinned by `testInstalledOnlyNeverChoosesAnUninstalledBrain`, `testPressureNeverDownloadsWhenNothingIsInstalled`, `testHiddenArtifactsAreNeverPickedByPressure` (hidden `intentGemma1B` stays invisible — the handoff's "…→ 1B" rung maps to hidden artifacts, deliberately not resurrected, fix-summary section 5.3).
- Call sites: `applyPressureBrainPickForTurn()` (`AppCoordinator.swift:6131`, called from `recordTranscript` at :5921, right after the post-turn policy at :5915); `.stepDown` swaps via the existing `switchBaseModel(to:)` seam (`LlamaCommandInterpreter.swift:585-592`, drops the handle + `lifecycle.didUnload`); `.lightweight` drops any resident handle (`unloadModel()`, :609-612); `.keep` swaps BACK when an earlier turn stepped down (recovery). The stored preference is never touched.
- Terminal refusal consistency: `loadLLMHandle` refuses BEFORE registering/reserving, at the SAME predicate (`LlamaCommandInterpreter.swift:1096-1102`), emitting `model_load_denied:pressure_low_headroom` and returning the typed `.failure(.insufficientHeadroom)` — whose existing consumer (`completion(nil)` → router `routeKeywordRemainder`) gives the deterministic fallback answer, so the pick can never promise a load the gate later refuses on the same arithmetic. Pinned by `testPressureRefusesLoadMatrix` (both directions at normal, warning and stale-warning readings).
- Tier walk matches the brief where the numbers allow: warn + 4.5 GB → keep (3.4 + 0.768 = 4.168 ≤ 4.5); warn + 3.0 GB → 1.7B (en); critical + 30 MB → lightweight. All pinned.
- The 768 MB margin deviation from the handoff's illustrative numbers ("warn + 2.0 GB free → 1.7B") is real and honestly documented (fix-summary sections 5.1-5.2): with the shipping inventory (4B ≈ 3.4 GB, 1.7B ≈ 1.98 GB live), 2.0 GB free fits nothing (1.7B needs ≈ 2.75 GB) — the illustrative row is arithmetically impossible under any honest page-in margin (it would require ≤ ~20 MB). The property that survives is the ladder — prefer the remembered pick, take the largest installed curated language-compatible brain that fits, never up, nothing fits → lightweight — and it is pinned by five tests. The margin is a single constant; accepted as an honest, documented deviation, not a defect.

### 6. Change F — degraded-mode status pill (18c33c5) — verified

- `DegradedVoiceMode` (`PressureBrainPick.swift:199-235`): pure `resolved(from:)` (:211), `copyKey` (:222), `pillText(locale:)` (:232) yielding nil for `.normal`.
- Copy is byte-identical to the brief (compared in `Localizable.xcstrings:6881-6916`): `home.degradedMode.lightweight` = en "Simple answer — low memory" / ne "सरल जवाफ — कम मेमोरी"; `home.degradedMode.smallerBrain` = en "Simple mode — low memory" / ne "सरल मोड — कम मेमोरी". Both `manual`/`translated`.
- The pill `DegradedModeStatusPill` (`RedesignComponents.swift:374`) renders in `HomeView` at :126, between the top bar and the scroll (outside the scroll, above the talk hero). Non-interactive (no gesture/button), silent (no sound, haptics or AudioServices), low-contrast (caption-sized warm font, secondary ink, standard card surface — no accent color, no glyphs), and it renders NOTHING for `.normal` (`pillText` nil → no view), so it auto-hides on recovery; the fade respects reduce-motion. State is published per turn by the coordinator (`degradedVoiceMode` at `AppCoordinator.swift:680`, set in `applyPressureBrainPickForTurn` :6184-:6187 with a main-hop guard for the published write).
- Pinned by the F tests: state transitions (`normal → smallerBrain → normal`; `smallerBrain → lightweight`), copy in both languages, copy-key mapping, and `.normal` rendering nothing.

### 7. The seed regression fix, a927fc1 — verified, intent-preserving

- The seed failure was genuine and disclosed: E repointed the init default to v6, so `testPreferenceChangeEmitsOneContentFreeEvent`'s first `setPreferredModel(v6)` became a same-value no-op (guard at `WhisperKitSpeechRecognizer.swift:223-226`), producing zero events — 3 assertion failures at `WhisperKitSpeechRecognizerTests.swift:195/196/198`, visible in `build/logs/seed-scoped2.log` (:902-903, "14 tests, with 3 failures").
- The fix moves the recognizer OFF the default first (`recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV5)` before clearing events), then changes to v6 — the event-per-real-change semantics under test are unchanged and still asserted; nothing was weakened. The commit is test-only (no production file in `git show a927fc1`), and the default-v6 behavior remains separately pinned by E's four tests. This is a correct intent-preserving pin repair, not a masked defect.

### 8. Test evidence honesty — observed, and re-derived from the logs

| Log | Observed in the file |
| --- | --- |
| `build/logs/impl-scoped2.log` | ModelLifecycleManagerTests 81/0 (:3526-3527); PressureBrainPickTests 22/0 (:3573-3574); WarmStartTests 32/0 (:3641-3642); WhisperKitSpeechRecognizerTests 14/0 (:3675-3676); WhisperPostTurnPolicyTests 19/0 (:3716-3717); totals 168/0 (:3719-3721); ** TEST SUCCEEDED ** (:3729). Suite counts match fix-summary section 4 exactly. |
| `build/logs/seed-scoped2.log` | 141 tests, 3 failures (:946-948) — exactly the single disclosed pin failure; the other suites green. |
| `build/logs/impl-scoped1.log` | The disclosed earlier iteration (`LocalBrainDeferral has no member 'pressureDeferral'`) — matches the summary's disclosure; iteration, not hidden. |
| `build/logs/seed-scoped.log` | The disclosed MIInstaller symlink install failure (environment note) — matches the summary. |

- The new tests pin what is claimed: `PressureBrainPickTests.swift` (read in full, 379 lines, 22 tests) covers the tier walk, freshness doctrine, installed-only/no-download/never-up/curated guarantees, the language gate (incl. remembered-pick bypass), the shared refusal matrix, production inventory defaults, and the F transitions/copy. WarmStart's 5 new cases pin the gate boundary both sides. ModelLifecycleManager pins critical eviction of the light encoder.
- Reviewed content = tested content, established read-only: every product source's mtime is ≤ 09:53:08 (PressureBrainPick.swift 09:53:08, AppCoordinator.swift 09:48:18, WarmStart.swift 09:19:55), the compiled objects postdate them (PressureBrainPick.o 09:53:37, AppCoordinator.o 09:53:47, WarmStart.o 09:39:31), the final run executed at 09:54:44-45 (TEST SUCCEEDED), the commits follow (ffbe6ae 09:55:30, 18c33c5 09:55:33, 42fa1a1 09:56:03), and `git status` is clean against HEAD for all product directories. The suite counts in the fix-summary are exactly what the logs show; nothing was taken on trust.

### 9. Scope discipline — verified

- Commits on `master..HEAD` are exactly the ten expected (five seeds + `a927fc1`, `2621b3b`, `ffbe6ae`, `18c33c5`, `42fa1a1`); no unrelated source changes ride along. The full file set is the OOM-hardening surfaces: the three voice sources + coordinator (+ HomeView, RedesignComponents), the strings catalog, the two test files, the new `PressureBrainPick.swift`/`PressureBrainPickTests.swift`, and the XcodeGen-regenerated `project.pbxproj`.
- `git log master..HEAD -- ios/TimerAlarmWidget/Info.plist` is empty — the pre-existing local CFBundleVersion edit is NOT in any commit (still a working-tree modification, as declared). `git log master..HEAD -- .ai-sdd` is empty — the run scaffolding is untracked setup. `build/` is untracked.

### 10. Merge gate — declared, correctly outstanding

- fix-summary section 6 records the gate exactly as the workflow requires: on the Anzaan device, (1) a real conversation turn (talk → ack → reply) with the explicit 4B pick active, no jetsam kill; (2) a fresh `JetsamEvent` pull afterwards, compared against the 2026-10-10 08:57/08:59 events. The beta-OS wired-memory leak is recorded as out of app scope (the brief's own conclusion).
- Not executed here — device work belongs to the merge gate, not this review task. The record is accurate and does not overclaim.

### 11. Non-blocking observations (no rework required)

1. fix-summary section 1 phrasing, "the only 'error:' strings in the log are the word error inside whisper.cpp C++ sources", is imprecise — `seed-scoped.log` carries the disclosed MIInstaller error line and `seed-scoped2.log` carries the 3 disclosed assertion errors. Both are disclosed in the same section, so the context is honest; the sentence should have said "compile error strings". Cosmetic.
2. The whisper.cpp STT warm branch remains ungated (only the whisperKit STT and llama steps consult `lowHeadroomReason`). Deliberate scope (legacy path; fix-summary 5.7 covers the TTS exemption only), but a low-headroom boot on the whisper.cpp stack still pages in there. Not a blocker; worth a one-line gate if that branch ever returns to a default stack.
3. Pick and gate read `available`/pressure at slightly different instants (the pick at `recordTranscript`, the gate at handle load). Inherent; they cannot disagree about the same reading, and any change between them lands in the gate's refusal → deterministic fallback, which is the safe direction.
4. The `.keep` recovery swap-back runs without re-checking install state (the no-pressure short-circuit at `PressureBrainPick.swift:161` returns before any fitness filter); if the remembered artifact were removed mid-session, the swap-back points at a missing model whose load follows the pre-existing failure path — no worse than before this change, and unreachable under pressure (the fit filter requires installed).
5. The regenerated `project.pbxproj` carries an unrelated UUID re-identification of `HomeProfileLinkTests.swift` (generator churn; the file exists and its target membership is unchanged). Noted for merge cleanliness only.
6. The handoff's illustrative "→ 1B" rung maps to hidden artifacts that were deliberately excluded (documented and pinned) — recorded here so the deviation is not re-litigated at the merge gate.

### 12. Role checklist

| Item | Verdict | Basis |
| --- | --- | --- |
| Every interface method has an explicit error return type | Pass | `PressureBrainPick` / `DegradedVoiceMode` are typed enums; the load site keeps `.failure(.insufficientHeadroom)`; the new code introduces no `any`/`unknown` escape hatch |
| Every async or external call documents failure mode and recovery | Pass | The load refusal emits `model_load_denied:pressure_low_headroom`, returns the typed failure, and the router's deterministic fallback answers; the skipped warm records `low_headroom` with first-use re-arm documented (fix-summary, brief) |
| Timeouts and retry limits are configurable parameters, not hardcoded constants | Pass | `marginBytes` / `pressureWindowSeconds` are parameters with defaults on every resolver entry point; the warm gate inputs are `WarmStartConfig` fields (nil = ungated); the margin/floor/window are named single-point constants (fix-summary 5.2 calls the margin a one-line tune) |
| Every element traces back to a specific FR or NFR — no unspecified features | Pass | A/C/D/E are seeded brief changes; B' and F are the workflow-recorded owner amendments; no download path, no new surface beyond the one pill, hidden artifacts deliberately not resurrected |
| The design describes what the operator sees when the feature runs and when it fails | Pass | Pill copy for both degraded states (ne/en, byte-checked) and it hides on recovery; `pressure_brain_pick` and `model_load_denied` events on the observability bus; healthy path silent (no event on `.keep`) |

### Reviewed commits

| Commit | Content |
| --- | --- |
| `56073e8` | Repoint ANE recognizer default to `whisperKitMediumV6` (E, seed) |
| `30514b2` | Make the encoder slot evictable so critical pressure can drop it (D, seed) |
| `22103bc` | Post-turn 4B↔STT eviction policy (A, seed) |
| `870d186` | Document the voice-OOM hardening handoff state (brief, seed) |
| `688f980` | WIP change C: warm-start low-headroom gate (inert, unverified) (seed) |
| `a927fc1` | Fix the preference-change test pin for the v6 default repoint (test-only) |
| `2621b3b` | Finish change C: wire the boot warm's headroom gate inputs |
| `ffbe6ae` | Pressure-tiered brain pick before the load (B') + terminal load refusal |
| `18c33c5` | Degraded-mode status pill on Home (F) |
| `42fa1a1` | Implement-fix summary (the reviewed artifact) |

### Verification commands (run read-only from the worktree)

```
git diff master...HEAD
git show --stat <sha>          # each of the ten commits above
git log master..HEAD -- ios/TimerAlarmWidget/Info.plist   # scope -> empty
git log master..HEAD -- .ai-sdd                           # scope -> empty
git status --porcelain -- ios/ElderlyAssistant/Services/Voice ios/ElderlyAssistant/App ios/ElderlyAssistant/Resources ios/ElderlyAssistantTests
grep -n / sed -n ... PressureBrainPick.swift, WhisperPostTurnPolicy.swift, WarmStart.swift,
    LlamaCommandInterpreter.swift, AppCoordinator.swift, HomeView.swift, RedesignComponents.swift,
    ModelLifecycleManager.swift, WhisperKitSpeechRecognizer.swift, Localizable.xcstrings,
    docs/2026-10-10-voice-oom-hardening-brief.md
grep -n "Test Suite\|Executed\|TEST SUCCEEDED\|TEST FAILED" build/logs/impl-scoped2.log build/logs/seed-scoped2.log
grep -n "error:" build/logs/seed-scoped.log build/logs/impl-scoped1.log
swift -e 'struct M { let id: String; let b: Int }; let ms = [M(id:"remembered", b:10), M(id:"sibling", b:10)]; print(ms.max(by: { $0.b < $1.b })!.id)'   # -> remembered (first of equals)
ls -lT build/DerivedDataTests/.../Objects-normal/x86_64/PressureBrainPick.o AppCoordinator.o WarmStart.o
```

## Decision

decision: GO

All criteria met. Changes A, D and E are green on this tree; C's gate is wired to real inputs and provably skips below the floor; B' delivers the pressure-tiered pick with the never-download / installed-only / curated-only / never-up guarantees, one shared arithmetic with the terminal load refusal (so pick and gate cannot disagree), and the recovery path back to the remembered pick; F shows the brief's exact ne/en copy, non-interactively, and hides on recovery. The seed regression introduced by E is fixed as a genuine intent-preserving pin repair, and the final scoped run is green (168 tests, 0 failures, TEST SUCCEEDED, exit 0) with the reviewed content byte-identical to the compiled content. Scope is clean (no unrelated commits; the pre-existing `Info.plist` edit and `.ai-sdd` scaffolding uncommitted), and the 768 MB margin deviation is honestly documented, arithmetically justified, and leaves the ladder property pinned by tests. The device merge gate (conversation smoke + fresh JetsamEvent pull on Anzaan) remains correctly outstanding as post-merge work, and the section-11 observations require no rework. The workflow exit condition (review decision GO) is met.
