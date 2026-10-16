Reviewer: sdd-reviewer subagent (read-only), orchestrated by the main session
Reviewed revision: feat/multi-turn-conversation @ cf416ac + uncommitted W4 implementation (2026-10-10)
Verdict: NO_GO at base review (1 blocker) → GO after the F-1 fix and re-review (same reviewer, revised verdict)
Confidence: 0.90 (both passes)

# W4 Implementation Review — multi-turn-conversation (T-134, T-136)

## Base review (pre-fix)

**Reviewer:** sdd-reviewer (read-only; no edits, no builds, no commits)
**Verdict:** NO_GO
**Confidence:** 0.9 overall (F-1 at 0.9 — static trace, every premise verified in code; no build/test execution permitted under the review mandate)
**Blockers:** 1 (F-1)

### Scope and method

**Delta accounting.** `git diff cf416ac --numstat` + `git status --short`: exactly 6 modified + 4 untracked, matching the dispatch brief path-for-path — no extra paths. Hunk census: `CommandRouter.swift` 4 hunks (`@@ -875,9+875,37`, `-1411,7+1439,17`, `-2211,7+2249,16`, `-3932,9+3979,25` — no other region touched, helpers `:2936-3209` byte-unchanged); `AppCoordinator.swift` 11 hunks (none near the 60 s watchdog `:4940`, the start watchdog `:1185-1194`, or the talk-contract region — watchdog untouched as required); `VoiceSessionStateMachine.swift` exactly 1 hunk (`@@ -257,6+257,17`); `CommandRouterDialogueTests.swift` 2 hunks inside one test (`:448-471`); `project.pbxproj` adds only the two new test files (xcodegen regeneration, 8 additive lines); `specs/implement-notes.md` = the single `W3HASH → cf416ac` fill, verified as the only change.

**Hashes.** Claimed: `CommandRouter.swift` `10f747ea…bd1e` ✓, `CommandRouterDegenerateTriggerTests.swift` `697ed81a…c53276` ✓, `CommandRouterDialogueTests.swift` `cac7517b…a9e124` ✓ — all match. Recorded: `AppCoordinator.swift` `dd95bc7eb6cd4363329e8f5754c393e76f10e100d7accdd79026cc4f7a722d81`; `VoiceSessionStateMachine.swift` `0c737dd5a3181e7e1f8f4dc99a700444e2925116b68d30246c5414aad2153a6a`; `DialogueCoordinatorWiringTests.swift` `865c04bd4e411cadc6eb5440bf402cb6fd199801190531fbae0bcd4e761dcc29`.

**Gate evidence re-read (logs + read-only `xcresulttool`).** Combined gate `/tmp/mtc-w4-gate.log` + bundle `…18-01-58…xcresult` re-verified: 203 passed / 0 failed, per-suite walk exactly 13 (DegenerateTrigger) / 21 (Dialogue) / 35 (Music) / 33 (Router) / 16 (Wiring) / 4 (SpotifyWiring) / 24 (VSM) / 4 (Binding) / 17 (Frame) / 36 (AnswerPath) — identical to the orchestrator walk; in-build guards shown in the same log (privacy guards ✓; log-safety 24 cases over 12 rules, every fixture ✓; prompt mirror + 7 drift self-tests ✓). T-134 red history: run1/run2 logs carry the two claimed sibling-WIP compile errors (`run1.log:64` "has no member 'resolveDialogueFrameOnSessionExit'"; `run2.log:64` "wakeWordEnabled … before all stored properties"); run3 bundle `/tmp/mtc-w4-evidence/…17-47-29` re-verified 101/1 with the single failure `testExpiredFrameLeavesTheUtteranceAFreshCommand` — the deviation-1 collision; run4 bundle `…17-51-09` re-verified 102/0, per-suite 13/21/35/33. T-136: gate1 log carries the exact phase-1 error; gate2 log carries `** TEST FAILED **` + the failing list (`testScenario1AnOffMainStart…`, `testScenario4PipelineEvents…`) + the SIGILL `.ips` (`EXC_BAD_INSTRUCTION`, `ElderlyAssistant-2026-10-10-174604.ips`); gate3 log + `/tmp/T-136-gate3-tests.json` (101/0; per-suite 16/4/24/4/17/36), bundle `…17-54-27` re-verified 101/0. Gate2/run1-2 xcresults were pruned by later runs; claims verified from retained logs. Log-safety script byte-identical to cf416ac (sha256 `94d14b21…` on both sides); no fixture/tool path in the delta — no new roots needed, confirmed.

### Flagged-context adjudications (base pass)

1. **T-134 deviation 1 (fixture swap) — ACCEPT.** `भजन बजाऊ` is now by-design degenerate (FR-MTC-002; new suite test 1 pins exactly that route), so the old fixture could not keep the expired-frame pin's own contract. The swap to `दशैं दुर्गा भजन बजाऊ` preserves every assertion of that pin: expired frame resolves nothing (`resolutions.isEmpty`), zero dialogue telemetry, ladder runs once, fired request byte-equal to the shipped expression. The run3 bundle proves the collision was real (that test was the only failure); run4 102/0 after the swap; the other 20 tests are byte-unchanged (numstat 12/4 = this test only). Nothing else should move.
2. **T-134 deviation 2 (one composed utterance) — ACCEPT.** The composer body for candidateChoice already leads with `dialogue.understood.no` (`DialogueManager.swift:349-357`; retry prefixes `dialogue.retry`, `:325-326`). The design's literal two-call sequence would repeat the lead sentence. The implemented single utterance speaks the honest lead exactly once and the question once; test 4 pins `hasPrefix(dialogue.understood.no)` (`CommandRouterDegenerateTriggerTests.swift:246-249`). No duplicate sentence.
3. **T-134 V-2 region-scoped scan — ACCEPT (W3 F-5 precedent).** All four changed line ranges sit inside the four scan regions (banner → next anchor: `CommandRouter.swift:878→911`, `1442→1453`, `2252→2264`, `3986→4001`); the whole delta's added lines contain zero `print(`/`NSLog`/`os_log`/`debugPrint` tokens (grep-verified). Anchors are content-based and fail loudly (test 13).
4. **T-136 deviation 1 (off-main refusal, no hop) — ACCEPT.** A synchronous `Bool` cannot honor §12.6's literal "hop internally" without lying: the caller would take its non-probe fallback while the hop later opened an unspoken window. Refusal keeps one action per utterance; every production caller is the main-thread router; the refusal is behaviorally pinned (`DialogueCoordinatorWiringTests.swift:143-162`).
5. **T-136 deviation 2 (supersede via the funnel) — ACCEPT.** The literal `dialogueManager.resolve(.superseded)` would clear the frame without closing the window and without the §26 emit the coordinator owns. `resolveDialogueFrame(.superseded)` at the opener top (`AppCoordinator.swift:7094-7112`) closes the window through legal edges and emits exactly once, only when a frame was live (nil-guard `:11094`); the router emits `.superseded` nowhere (its `emitDialogueFrameResolved` call sites are the seven only, `CommandRouter.swift:1028/1033/1042/3119/3168/3177/3181/3237/3255`).
6. **T-136 deviation 4 / C-1 (one additive `answerWindowSeconds` accessor) — ACCEPT: sanctioned coordination, not scope creep.** C-1 itself demands the window "sourced from the session machine instance's config value"; `config` is a private instance field (`VoiceSessionStateMachine.swift:136`), so an instance accessor is the minimal mechanism. The accessor (`:260-268`) is additive, reads the one 45 s home (`:120`), has exactly one reader (the construction at `AppCoordinator.swift:2552`), and the machine's diff is exactly this one hunk — no other edit. Pinned by `DialogueCoordinatorWiringTests.swift:554-588` (accessor == 45, one literal home, no type-level access, no literal in the construction).
7. **T-136 decision 3 (`handlePipelineState` internal) — ACCEPT, minimal.** One visibility word changed (`private` removed; hunk `@@ -4747,13+4811,24`), mirroring the `executeDialogueCandidate` seam; source-pinned as internal (`DialogueCoordinatorWiringTests.swift:351-362`) and behaviorally driven by the six-stage guard test (`:302-345`). No other widening anywhere in the diff.
8. **T-136 decision 5 (construction at top of init) — ACCEPT.** Necessity proven by red gate1 (the exact phase-1 error in `/tmp/T-136-gate1.log`). `DialogueManager.init` stores two values, allocates and observes nothing (`DialogueManager.swift:225-230`), so no behavior is reordered beyond the construct-before-observer-backed-assignments rule; everything below the two new init blocks (`onSlotAnswerTimeout` + observer, `:3081-3102`) is otherwise unchanged.

### Per-unit results (base pass)

| Unit | Result | Evidence |
|---|---|---|
| **T-134** | **PASS** (router-side contract) | `CommandRouter.swift` sha `10f747ea…`; 4 hunks only; helpers untouched; 102/0 across the four router suites (bundle `17-51-09` re-verified; per-suite 13/21/35/33); byte-identity spot-checks pass (`KeywordIntentRule.swift:840-843` wrapper; `fireMusicRequestOrProbe` `:2999-3017`); V-2 scan covers all four hunks. The blocker F-1 lives in the composed flow, not in this file's contract — see Findings. |
| **T-136** | **PASS** (coordinator-side contract) | `AppCoordinator.swift` sha `dd95bc7e…` + `VoiceSessionStateMachine.swift` sha `0c737dd5…`; M-1 (`:4830-4831` guard), M-2 (four sites `:7317/:7490/:7550/:8638` + opener supersede), M-3 (`:11048-11052` + accessor `:11159-11162`), C-1 all verified in code and by tests; 101/0 gate3 (bundle `17-54-27` re-verified; per-suite 16/4/24/4/17/36). The blocker F-1 is the composed flow. |

### Cross-cutting checks (base pass)

- **FR-MTC-017 causality — PASS with one nuance.** The three ladder/keyword/interpreted sites (`:1450`, `:2261`, `:3995`) sit below the interception (`:1006-1095`), which returns before them for every consumed arm; only `.expired`/`.bargeIn` deliberately fall through. The rephrase site (`:878-909`) is in fact ABOVE the interception in source order (inside the confirmation hook), but it is reachable only while a rephrase confirmation is pending, and by M-2 mutual exclusion (frame-start refuses while `isAwaitingConfirmation`; confirmation arming supersedes) no armed frame can coexist with it — so it cannot consume an armed-frame turn. No bypass found.
- **No-double-emit — PASS.** Router emits the seven turn-time outcomes at its own sites; the coordinator funnel emits only `timedOut`/`emergency`/`superseded` (`AppCoordinator.swift:11098-11108`), component `app_coordinator`, metadata `["outcome": …]` mirroring the router helper (`CommandRouter.swift:3285-3307`). The coordinator's seven cases are `break`. Wiring test pins zero coordinator emits for all seven (`DialogueCoordinatorWiringTests.swift:221-245`).
- **maxProbes erratum — intact.** `attempts <= DialogueConfig.maxProbes` at `CommandRouter.swift:1086`, untouched by the diff; the `<` erratum comment stands (`:1079-1085`).
- **W2 F-1 producer side — PASS.** `AppCoordinator.swift:10317` `medicationVoiceEntries { medicationScheduler.medicationEntries() }` is a live scheduler read (no snapshot); the interception (`:1009`) and keyword stage (`:1412`) read it per turn; pinned live by `DialogueCoordinatorWiringTests.swift:592-638`.
- **NFR-MTC-012 byte-identity — PASS (spot-checked).** Ladder non-degenerate fires `query.query ?? raw` ≡ shipped `musicQuery(from:) ?? raw` (thin wrapper, same input); interpreted non-nil query path byte-unchanged (`:3982-3984`); zero-candidate/arm-failure fallbacks are the exact `speak(key: "router.reprompt")` / `speak(key: "router.rephrase.discard")` lines (`:3096/:3102/:907`); cloud-failure branch untouched (`:2244-2251`). Tests 2/5/7/8/9/10/11 pin these and are green.
- **No helper-signature churn — PASS.** The four new call sites consume W3 helpers unchanged; the only W4-created code in CommandRouter is the four hunks.
- **Watchdog / confirmation timers — PASS.** No diff hunk touches the 60 s watchdog (`AppCoordinator.swift:4940`), start watchdog (`:1185-1194`), or the confirmation timer machinery; `recordConfirmationTimeout()` keeps exactly one call site (`:3038`), source-pinned.
- **V-2 — PASS.** Zero console tokens in the delta's added lines; both suites' region scans green in-gate. (T-136's scan regions do not cover the four small arming-site substitutions, the opener body, or the M-1 guard — those are diff-verified clean; W3 F-5 precedent, note-level only.)
- **NFR-MTC-007 — PASS.** One bounded frame struct, no new model loads or long-lived buffers; the six members are synchronous main-queue calls (one defensive hop in `noteDialogueAttempt`).
- **W1 F-5 status — open by design**, not a blocker: the `.awaitingSlotAnswer` UI mappings remain compile-forced placeholders to confirm at the review/device wave (`T-136-notes.md:113`).

### Findings (base pass)

**F-1 (blocker) — the rephrase-discard upgrade's probe is answer-dead in production wiring: the queued confirmation-close lands after the new slot window opens, and the session-exit observer then supersedes the freshly armed frame.**
Trace (every line verified): (1) `CommandRouter.swift:891` `let taken = coordinator?.takePendingRephraseCommand()` → `AppCoordinator.swift:7494-7501` clears `pendingRephrase` and queues block A: `DispatchQueue.main.async { voiceSession.transition(to: .idle) }`. (2) `CommandRouter.swift:898-903` calls `coordinator.startDialogueFrame(...)` synchronously on main; guards pass; `voiceSession.openSlotAnswerWindow()` bridges `.awaitingConfirmation → .idle → .awaitingSlotAnswer` and the frame arms; each bridge transition publishes, so the observer queues hops AFTER block A. (3) Router speaks the composed probe. (4) Main drains FIFO: block A runs first → `.awaitingSlotAnswer → .idle`, slot timer cancelled — the just-opened window is gone while the frame is live. (5) The observer hop then sees state `.idle` ≠ `.awaitingSlotAnswer` and `liveFrame != nil` → `resolveDialogueFrame(.superseded)` → frame cleared, spurious `dialogue_frame_resolved superseded` emitted. Net: the elder hears the did-you-mean question; the frame dies about one runloop later; their answer is not intercepted; a `superseded` event fires immediately after `dialogue_probe_spoken`. Contradicts T-134 Gherkin 4 and design §12.4 edit 5, and transiently breaks the "a frame is only ever armed WITH a window" invariant. Invisible to both suites (T-134's rephrase test drives a mock coordinator with no session machine; no test called the real `takePendingRephraseCommand`).
**Required action:** fix the composition so the probe window outlives the queued confirmation close (e.g. synchronous `.idle` when on main, or defer the arm+speak one main tick); add the F-2 real-wiring test; re-run both scoped gates. No commit until then.

**F-2 (minor) — no test covers the router→coordinator `take`/`start` seam.** Required action: add an integration test (real `AppCoordinator`: `startRephraseConfirmation` → route `"होइन"` → drain main → assert frame live, window still open, zero `dialogue_frame_resolved`; then answer and assert interception).

**F-3 (note) — gate2 red-run tally in `T-136-notes.md:101` not reproducible from the retained log.** Required action: annotate/correct the tally before commit.

**F-4 (note) — the opener's supersede now also applies beyond M-2's four sites** (`pendAppLaunch` `:7083`, `startVoiceAckConfirmation` async `:10426`); ADR-MTC-03-consistent but untested. Required action: record in the notes; A/B test candidate at next touch.

**F-5 (note) — T-136's V-2 scan anchors cover the large new regions only**; small hunks diff-verified clean (W3 F-5 precedent). Required action: optional anchor extension at next touch.

**F-6 (note, status)** — W1 F-5 remains open by design; not a blocker.

### Conclusion (base pass)

**NO_GO — 1 blocker (F-1).** Commit conditions: (1) F-1 fixed and both scoped gates re-run green, with the F-2 integration test added; (2) F-3's tally corrected/annotated; (3) F-4 recorded in the notes; (4) commit exactly the reviewed 6 modified + 4 untracked paths (fixed files change hashes — re-verify at re-review). Everything else in the delta is sound: hashes exact, delta exact, all eight flagged adjudications ACCEPT, all obligations verified against code, logs and re-read bundles.

---

## Re-review (post F-1 fix) — revised verdict

**Reviewer:** sdd-reviewer (read-only; no edits, no builds)
**Reviewed revision:** feat/multi-turn-conversation @ cf416ac + uncommitted W4 + F-1 fix
**Verdict:** GO
**Confidence:** 0.9 (all fix premises verified in source; red/green bundles directly demonstrate the behavioral difference)
**Blockers:** 0 (F-1 closed; F-2/F-3/F-4/F-5 closed; one new note-level finding F-7, not a commit blocker)

### Delta re-verification

Same 6 modified + 4 untracked, no extra paths. `CommandRouter.swift` numstat grew 70/7 → 103/7 (+33 lines, all in the discard-branch hunk); hunks 2–4 (ladder :1472, keyword-remainder :2282, interpreted :4012) are textually identical to the reviewed revision. Hashes: `CommandRouter.swift` `f198b729…b3a31` ✓, `CommandRouterDegenerateTriggerTests.swift` `16ac3e09…f354` ✓, `DialogueCoordinatorWiringTests.swift` `af44a8bc…762f` ✓, `T-134-notes.md` `d08dbb24…3f96` ✓; `AppCoordinator.swift` `dd95bc7e…2d81` and `VoiceSessionStateMachine.swift` `0c737dd5…53a6a` byte-unchanged by the fix ✓; `CommandRouterDialogueTests.swift` still `cac7517b…e124` ✓. `T-136-notes.md` now `cd4e218b5d01247d427af2a59ac41e8f3afbe559701d7e5a0ab44f618b52ed96` (computed; not previously claimed).

### (a) Fix verified against the original trace

Read the fixed branch (`CommandRouter.swift:891-941`). The ordering proof holds under main-queue FIFO:

- Block A (queued by `takePendingRephraseCommand()`) runs first: `.awaitingConfirmation → .idle`; its observer hop is queued AFTER block B (B was queued before A executed), so at hop-A execution the frame is already live — hop A is a no-op via the resolver's first guard (`state != .awaitingSlotAnswer`). Net result is exactly the required no-op; rationale nuance in F-7.
- Block B runs from `.idle`: `openSlotAnswerWindow()` takes the direct legal `.idle → .awaitingSlotAnswer` edge (`VoiceSessionStateMachine.swift:237-246`, bytes unchanged); the observer hops for both publishes see `.awaitingSlotAnswer` → no-op.
- No window without its probe: `startDialogueFrame` is called ONLY at `:929` inside B; on success (`:936-937`) `speakDialogueDidYouMean` runs immediately in the same block; on window-open or arm failure `startDialogueFrame` closes any opened window before returning false (`AppCoordinator.swift:10975-10986`, unchanged).
- Fallback legs byte-identical: deferred failure leg `self.speak(key: "router.rephrase.discard")` (`:933`) and the synchronous else leg (`:940`) — same key/call as the pre-fix shipped line; zero-candidate/nil-coordinator paths stay synchronous. No double-speak possible (single exit per leg).
- The candidate-positive probe composition is unchanged from the reviewed intent (same builder call, same frame, same speak helper — one tick later).
- Nuance, verified not a defect: `guard let self else { return }` (`:927`) means a deallocated ROUTER speaks nothing (its code comment `:919-920` states this accurately); the deallocated-COORDINATOR leg (`:928-934`) speaks the shipped line. Code and comment are consistent.

### (b) The new test exercises the real seam

`testF1TheDiscardBranchesDeferredArmKeepsTheProbeWindowOpenAndAnswerable` (`DialogueCoordinatorWiringTests.swift:500-589`): a real `AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())` plus a real `CommandRouter(coordinator:)`; the exercised path — real `startRephraseConfirmation` → real `takePendingRephraseCommand` (with its queued hop) → real deferred block B → real `startDialogueFrame`/`openSlotAnswerWindow`/`arm` → real observer — is production code, not a restatement of the mock. The BGTaskScheduler/`start()` limitation is real and the workaround is honestly stated in the addendum (`T-134-notes.md:354-363`). Dual-surface zero-resolution check is genuine (recording bus + `captureConsole` dup2, `:857-883`). Decisive: the pre-fix bundle `…18-30-16…` shows this test failing with the exact trace — `:532` "the freshly armed frame died on the next tick…", `:539` `("stopped") is not equal to ("awaitingSlotAnswer")`, `:545` `("1") is not equal to ("0") — the funnel resolved the fresh frame (superseded) — F-1`, `:577/578` answer-path resolutions. The test catches the defect and passes on the fix; nothing else changed in the suite's 16 pre-existing tests.

### (c) Evidence and findings resolution

- r2 combined gate `/tmp/mtc-w4-gate-r2.log`: same 10 `only-testing` classes, `** TEST SUCCEEDED **`, `Executed 204 tests, with 0 failures`; bundle `…18-26-06…` re-walked read-only: 204 passed/0 failed, per-suite leaf counts exactly 4/13/21/35/33/36/17/17/4/24. Guards green in the same log (log-safety 24 cases/12 rules; prompt mirror + 7 drift self-tests). Zero `warning:`/`error:` lines (grep count 0). Pre-fix red: `/tmp/mtc-w4-prefix-f2.log:93` "Executed 17 tests, with 14 failures"; restore green: `/tmp/mtc-w4-postrestore-f2.log` 17/0 + TEST SUCCEEDED, bundle `18-32-28` 17/0. Notes: gate-2 tally annotated in place (`T-136-notes.md:101`), "Post-review annotations" section records F-3/F-4/F-5 (`:118-122`); T-134 addendum records the defect, option-2 fix, pre-fix-fails evidence, new hashes and honest red history (`T-134-notes.md:273-460`).
- Tests 4 and 10 drains verified correct (synchronous halves asserted pre-drain; pins after `waitForDelivery`); test 5 correctly stays synchronous.
- The fix's new lines sit INSIDE the [MTC-T134] region-1 scan (banner `:878` → `return .unrecognised` `:942`) and contain no console tokens — V-2's F-5 caveat is further shrunk, not widened.

**Findings resolution:** F-1 CLOSED (fix verified, red→green demonstrated). F-2 CLOSED. F-3 CLOSED (annotated). F-4 CLOSED (recorded). F-5 CLOSED (recorded; scan coverage now extends over the fix). F-6 unchanged (W1 F-5 UI mappings open by design).

**New finding — F-7 (note, documentation only, no behavior change).** The ordering rationale at `CommandRouter.swift:912-913` (echoed in `T-134-notes.md:323-325`) says the block-A observer hop "finds no frame yet — a no-op". In the actual FIFO schedule, B is queued before A executes, so hop A executes after the frame is armed; the no-op actually comes from the resolver's first guard (`.awaitingSlotAnswer` short-circuit), not from the frame being absent. The conclusion is right and doubly guarded either way, and testF1 pins the net outcome. **Required action:** one-line comment correction when this file is next opened; record it in the run notes (done — implement-notes §2 W4 disposition). Not a commit blocker — do not edit the file pre-commit (any edit invalidates the reviewed `f198b729…` hash).

### Conditions for commit (re-review)

1. Commit exactly the currently reviewed 6 modified + 4 untracked paths; the commit must carry the bytes matching `f198b729…` (CommandRouter), `16ac3e09…`, `af44a8bc…`, `d08dbb24…`, `cd4e218b…`, with `dd95bc7e…`/`0c737dd5…`/`cac7517b…` unchanged. Any post-review edit to a listed file requires re-review of that file.
2. Record F-7 in the notes; comment fix at next touch.
3. F-6 status carries to the review/device wave as before.

### Summary (re-review)

**GO — commit the reviewed delta as-is under the conditions above.** The F-1 prescription was implemented exactly (option 2, one-tick deferral, discard branch only), and the fix is verified correct against the original trace: block A lands first, the window opens from `.idle` with the observer seeing `.awaitingSlotAnswer`, the probe is spoken once into a live 45 s window, no window can open without its probe, and every fallback leg speaks the shipped line byte-identically. The new real-seam integration test genuinely composes the router and coordinator and demonstrably fails on the pre-fix revision with the exact superseded signature (14 assertion failures in bundle `18-30-16`) and passes green on the fix (17/0, `18-32-28`); the r2 combined gate reproduces 204/204 with per-suite counts, guards, and clean logs exactly as claimed. F-1 through F-5 are closed; F-7 rides to the next touch.
