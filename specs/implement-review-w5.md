# Implementation review — W5 (multi-turn-conversation)

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** branch `feat/multi-turn-conversation`, HEAD `cc065b0` (W4) + uncommitted W5 implementation
**Date:** 2026-10-10
**Verdict:** **GO — Confidence 0.90**
**Blockers:** 0 (1 minor, 2 note-level findings)

## Scope and method

Units under review: **T-139** (hostile corpus + trap matrix suites), **T-140** (cache-bypass + log/egress suites), **T-143** (device-validation protocol). Test-only + docs wave; no production source.

Method: read-only verification in the worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`. Delta confirmed exact against the dispatch (`git status --short` / `git diff --stat`): `M ios/seniOS.xcodeproj/project.pbxproj` (+16/−0, additions-only — 4 PBXBuildFile, 4 PBXFileReference, 4 group children, 4 Sources entries, one per new test file); `M specs/implement-notes.md` (single line: W4 row `W4HASH` → `cc065b0`); untracked: the four new test files, `specs/T-139-notes.md`, `specs/T-140-notes.md`, `specs/T-143-notes.md`, `specs/MTC-device-validation-protocol.md`. No other file in the delta; **no production source modified**. Gate evidence verified against preserved logs/bundles — not re-run, per dispatch.

Files and sha256 (computed):

| File (worktree-relative) | sha256 | Lines |
|---|---|---|
| `ios/ElderlyAssistantTests/Services/Voice/DialogueHostileCorpusTests.swift` | `ec607a15e3bf850c0361cbf02a74cc828b35febe053720545ec06984eb0f131a` | 724 |
| `ios/ElderlyAssistantTests/Services/Voice/DialogueTrapMatrixTests.swift` | `273f62c3dea4ff6e3b99b0e2e1f14c08443c07c7d083818ceb82cba269b32a63` | 660 |
| `ios/ElderlyAssistantTests/Services/Voice/DialogueCacheBypassTests.swift` | `aa1ee630519caeb74d593f86e03992ba99c0125b5c8f1626b4bdeeb3605c2452` | 603 |
| `ios/ElderlyAssistantTests/Services/Observability/DialogueLogAndEgressTests.swift` | `d7703880ced20d46517bc29534b5868469a23fbc66353dee784bcb6bb73de1fc` | 956 |
| `specs/T-139-notes.md` | `e0360033a0dadd198948a2ba149f193592ffa0b29e3be83ff8c96b7ea23eb530` | 216 |
| `specs/T-140-notes.md` | `d074a2de177b63692d40fb09f9800cf667963ab182c7c836de4ff60b6e562cae` | 201 |
| `specs/T-143-notes.md` | `e54d7d70c750d20486676ce24b0b53533fb17d482973ef1587d8be5f14837159` | 226 |
| `specs/MTC-device-validation-protocol.md` | `b06a76563c9baf8c3ab9e237f5cea2a014056bce9c8eff4449f8ad873e4e7c8a` | 300 |

Authority read for criteria: feature `constitution.md` (DV table :113-117), `design-l2` §12/§22-§26, `security-design-review.md` (E1-E8, V-1..V-4, M-1..M-5, R1/R2), FR-MTC-007/017/020, NFR-MTC-003/004/007/008/012, and prior reviews `specs/implement-review-w1..w4.md` for continuity (closed items not re-litigated).

Gate evidence (verified, not re-run):
- W5 combined gate: `/tmp/mtc-w5-gate.log` → `Executed 157 tests, with 0 failures`, `** TEST SUCCEEDED **`, `GATE rc=0`; bundle `/tmp/mtc-w5-evidence/w5-gate.xcresult` walk: CommandRouterDialogueTests 21, DialogueAnswerPathTests 36, DialogueCacheBypassTests 4, DialogueCoordinatorWiringTests 17, DialogueHostileCorpusTests 8, DialogueLogAndEgressTests 5, DialogueTrapMatrixTests 8, LogSanitiserTests 34, VoiceSessionStateMachineTests 24 — 157 total, all `Passed`.
- T-139 unit gate: `/tmp/t139-build-run1..4.log`; run 4 green **114/114** (`/tmp/t139-run4-green.xcresult`); honest red history preserved (run 1 own-file compile errors :317/:440; run 2 sibling-file compile block; run 3 one expectation corrected to production normalization).
- T-140 unit gate: red `/tmp/t140-gate.log` (rc=65, one failure — own file, `DialogueCacheBypassTests.testPendingTranscriptStaysNilOnFrameExecution`) + `/tmp/t140-gate-red.xcresult`; green `/tmp/t140-gate2.log` (rc=0, **117/117**) + `/tmp/t140-gate2.xcresult`.

## Flagged-context adjudications

**T-139**
1. **Timeout row fires `onSlotAnswerTimeout` directly + T-135 1 s clock leg — ACCEPT.** `AppCoordinator.swift:211` declares `let voiceSession = VoiceSessionStateMachine()` (non-injectable); default config `VoiceSessionStateMachine.swift:120` (45 s); the callback is production-installed at `AppCoordinator.swift:3081`. Firing the exact installed seam, plus the bare-machine `Config(confirmationTimeoutSeconds: 1)` leg (:115-120), is deterministic and faithful; one 1 s expectation wait, no sleeps.
2. **Watchdog row: precondition + terminal consequence — ACCEPT.** Work item is private, `voiceWatchdogSeconds = 60` (`AppCoordinator.swift:4940`), fire guard `if self.voiceSession.state == .listening` (:4946). The row asserts the fire precondition is false mid-window and drives the `.stopped` flip to exercise the session-exit observer (`AppCoordinator.swift:3098-3102` → `:11116-11120`, superseded through the funnel) — the only reachable consequence without waiting out 60 s.
3. **Expiry row: mock over REAL `DialogueManager(answerWindowSeconds: 4, now:)` — ACCEPT.** The manager's own clock seam exists (`DialogueManager.swift:225-227`); half-open `isExpired` is `now >= deadline` (:94); the absolute epoch (1_800_000_000) avoids FP drift at the boundary; real coordinator window is not injectable, so a file-private mock over the real manager is the closest-real option.
4. **Candidate-poisoning normalized `"दुर्गा"` — ACCEPT.** The shipped music arm adds the music vocabulary to the drop sets (`KeywordIntentRule.swift` doc block :781-790, markerFallback arm :798+), so `भजन` is dropped from `"दुर्गा भजन"` and the executed query is `"दुर्गा"`. Run 3's one-edit correction pins verified production behavior (comment records it), not the pre-normalization fixture.

**T-140**
5. **One red run then one-edit fix — ACCEPT.** Red log failure is in this unit's own file (`/tmp/t140-gate.log:67`), rc=65; the retry-not-fix protocol applies to sibling-file failures, of which none occurred; both red and green bundles preserved. The one edit was in-unit.
6. **Raw-read for the router source pin — ACCEPT.** `FeatureSourceScan.codeText(of:)` strips comments by design (`FeatureSourceScan.swift:55-61`), and the six region anchors are comment lines — the red run's `region anchor missing: interception` is exactly that; raw read is also the tighter E8 claim (zero `pendingTranscript` references including comments) and matches the already-passing E6 suite idiom for the same six regions.
7. **`§12.2` heading anchor at line 1021 — ACCEPT.** Verified in `CommandRouter.swift`: `§12.1` mentions at :110 and :559, the `§12.2` interception heading at :1021; each anchor string occurs exactly once, in order (1021/1130, 2953/3342, 878/944, 1475/1488, 2285/2297, 4019/4034).
8. **File-private `LogInMemoryProfilePayloadStorage` — ACCEPT.** The established fake is file-scoped (`DialogueCoordinatorWiringTests.swift:790-813`, verified); mirroring its shape in the E4 suite rather than widening another file's private symbol is the right call, and the red run's sibling-compile incident (T-139 run 2) shows exactly why file-private is the safe default.
9. **Timeout leg drives `voiceSession.onSlotAnswerTimeout?()` — ACCEPT.** Same reasoning as adjudication 1; the `[app_coordinator] … outcome=timedOut` emitter is exercised for real and observed in the sink scan.
10. **dym fixture pairs hypothesis with near-match `"समाचार"` — ACCEPT.** `DialogueCandidateBuilder.build` appends the hypothesis only alongside non-empty near-matches (`DialogueCandidateBuilder.swift:79-82`, R2 never-alone, verified); the suite additionally asserts the marker is inside the armed frame's candidates and in the spoken text, so the marker-absence claim is non-vacuous.
11. **E5 allow-list re-verified at runtime — ACCEPT.** Static count at `LogSanitiser.swift:56` = 84 quotes, matching the runtime pin (84, contains `reason`, `reason` ∉ six-key dialogue vocabulary); "verify, don't assume" correctly applied to T-137's static claim.

**T-143**
12. **DV table lives in the feature constitution (:113-117), not the root — ACCEPT.** Root `constitution.md` contains no `DV-1`; all five DV lines verbatim in the feature constitution, matching design-l1 §6 (:197-209).
13. **Record merged into protocol §7 — ACCEPT.** The task file's implementation notes permit the appended record section (task file :59-61); §7.3 records all items **BLOCKED** and step zero **OUTSTANDING** — honest current state.
14. **JetsamEvent two routes (on-device Analytics Data export; `devicectl systemCrashLogs`) — ACCEPT.** Both are documented approaches; the second matches the repo's crash-log pull practice. No canonical command is documented in-repo, so the protocol's dual route is the right level of prescription.
15. **DV-5 Release route via `build.sh ipa` — ACCEPT.** `ios/device-install.sh:45` builds `Debug-iphoneos` (verified); `ios/build.sh:522-525` + `xcodebuild archive … -configuration Release` (verified :216-224) is the correct Release path for NFR-MTC-007's "6 GB-class reference device in Release configuration".
16. **DV-4 BLOCKED if not forcible — ACCEPT.** There is no debug toggle to force the pressure pick; design-l1 §6 itself offers "force (or unload)" as the levers, so honestly marking BLOCKED when device-side forcing fails is the correct discipline.
17. **dym leg optional — ACCEPT.** The candidate probe firing depends on device brain/STT variance; the fixed-fixture proofs remain automated upstream, so an optional device leg is honest.
18. **Presentation conventions — ACCEPT.** Outer quotes/bold and `" / "` joins are marked conventions; item text otherwise byte-verbatim (spot-checked ≥4 items and 3 gate phrases against constitution/design-l1/FR-MTC-020/NFR-MTC-007/012).
19. **Three source texts per item — ACCEPT.** Carrying all three (constitution, design-l1, FR/NFR) satisfies the task's "do not paraphrase pass criteria" instruction; verified verbatim.
20. **DV-3 utterance also pinned in `CommandRouterDegenerateTriggerTests` — ACCEPT.** "मेरो छोरालाई फोन गर" verified at `CommandRouterDegenerateTriggerTests.swift:278`; the deliberate cross-pin is the right device-observability choice.

## Per-unit results

| Unit | Verdict | Evidence |
|---|---|---|
| T-139 | **PASS** | 8 corpus (E1 pair, 5 E2 rows, M-5) + 8 trap (E3) tests; 114/114 run 4; E1 forced-no-op clear verified (dispatch side effects asserted with clear disabled; `clears` empty; frame survives; interpreter 0); injection-marker re-probe `attempts=2` + causal control leg; M-5 `[-1, 1, 12]` → three `.exhausted` closes component `command_router`; trap rows all end in the terminal triple (`assertNoHalfOpenWindow`, `assertLateHourglassIsANoOp`, `assertResolveTwiceIsANoOp`). |
| T-140 | **PASS** | 4 + 5 tests; 117/117 green; E8 seeded-entry causal A/B (seeded entry served on control re-route), answer text never interned, `pendingTranscript` nil via Mirror + source pin + positive control; E4 production `ConsoleObservabilityBus` + `LogSanitiser` over 8 legs, marker tokens absent from sink lines, suite pin of the 8-key vocabulary; E5 `[redacted]` OOV + dropped unlisted key + `reason=overLength` producer closure; E6 source regions + 20 spy transports all empty, only `YouTubeTool.appSearchURL` opens. |
| T-143 | **PASS** | 300-line protocol; DV-1..DV-5 with verbatim tri-source texts, steps, pass/fail, evidence fields; step zero = PR #156 device smoke as HARD PREREQUISITE (OUTSTANDING); §9 capture discipline (NFR-MTC-004); no execution claimed. |

## Cross-cutting checks

- **E-row fidelity:** traceable to real methods/assertions on spot-check: E1 forced-no-op clear; E2 injection re-probe + control; M-5 exhaustion render; E3 terminal triple; E8 causal A/B; E4 marker-absence over the production bus; E5 OOV redaction + 84-key runtime pin; E6 unique-ordered anchors + spy transports; V-3 `pendingTranscript` nil + positive control. M-1/M-2/M-3/M-5 tags sit in test names/comments — citable by T-142.
- **No weakening vs binding carryovers:** the `attempts <= maxProbes` erratum is intact — the re-probe arm stays live (attempts=2 asserted in corpus + M-5 route leg; no code changed). The `dialogue_frame_resolved` component split is intact — router emits the seven turn-time outcomes (`CommandRouter.swift:3318-3340`, component `command_router`; trap cancel asserts exactly 1), the funnel emits only timedOut/emergency/superseded (`AppCoordinator.swift:11093-11107`, :11128-11150; timeout/watchdog rows assert exactly 1), no double-emit asserted in every trap row. NFR-MTC-012 byte-identity: spoken-line assertions go through `L10n.str(key, locale:)` over shipped catalog keys (`dialogue.cancelled` xcstrings:3923, `dialogue.escape` :4025, `router.emergencyAck` :13644) — the same keys the router speaks via `speak(key:)` (`CommandRouter.swift:4497-4503`); no re-typed literals.
- **Determinism:** no `sleep`/`Thread.`/`RunLoop`/`DispatchTime` anywhere in the four suites; `asyncAfter` only inside the four bounded `waitForDelivery` drains (pre-existing `CommandRouterDialogueTests.swift:101` idiom); clock seams injected absolutely; watchdog/expiry exercised via preconditions + terminal consequences. No flakiness vectors found.
- **Test hygiene:** doubles sit at sanctioned seams (file-private mirrors of shipped fake shapes); the delta touches no production file; pbxproj additions-only; no sibling test file modified; production-seam references match shipped interfaces (`prepareDialogueAnswerText` `AppCoordinator.swift:11048-11052` + `:11159-11162`; `medicationVoiceEntries` `CommandRouter.swift:432`; `answerWindowSeconds` `DialogueManager.swift:219`; `onSlotAnswerTimeout` `VoiceSessionStateMachine.swift:134`; `startDialogueFrame` protocol `:131`, call site `:929`).
- **Cross-wave coherence:** harness idioms are the sanctioned ones (`MockObservabilityBus` MedicationSchedulerTests.swift:72; `StubCommandInterpreter` IntentTestHelpers.swift:64/:149; `GeminiInMemoryStorage` GeminiConfigStoreTests.swift:155; `FeatureSourceScan.iosDirectory(file:)`). W1 F-4 (pre-existing Spotify catalog pin red at base) remains routed to T-141 — not a W5 regression.
- **Protocol fidelity and safety:** no execution claimed; all DV items BLOCKED; step zero OUTSTANDING; no conflict with DV-5's Release requirement; capture discipline bounded to the scripted fixtures per NFR-MTC-004. No sanitizer-class literal found in the protocol.
- **Sanitizer scan:** of the four new spec files, one hit only — `specs/T-139-notes.md:194` (`evil.example`/`open_url`, backticked table cell). Test files are not scanned; no over-report.

## Findings

- **F-1 (minor) — `specs/T-140-notes.md:49` overstates the marker scan.** It claims the suite "asserts no marker token appears anywhere in the captured console text at all"; the suite's marker scan is scoped to bus-format sink lines (`DialogueLogAndEgressTests.swift:182-184`, `assertSinkHygiene` over `^[HH:mm:ss.SSS][`-format lines). A whole-console scan would in fact be wrong: the dym leg's marker provably reaches spoken output (`:393`) and the legacy `DebugConfiguration` print is accepted residual R1. **Required action:** none in code — scope the claim to sink lines when citing this row in the W5 implement-notes rows and the T-142 index.
- **F-2 (note) — seeding description mismatch.** `specs/T-140-notes.md:28` says the cache was seeded "via `IntentRouter.recordConfirmedExecution`"; the suite seeds via `cache.record(transcript:command:)` directly (`DialogueCacheBypassTests.swift:164-165`). Effect is identical — the control leg proves the entry is live. No action.
- **F-3 (note) — sanitizer-class literals in `specs/T-139-notes.md:194`.** The evidence map quotes `evil.example`/`open_url` in backticks. Awareness only: avoid quoting these literals verbatim into scanned records (T-141/T-142 index rows) if OutputSanitizer rules matter; the test files themselves are out of scan scope.

## Conclusion

**GO — Confidence 0.90.** The W5 delta is exactly as dispatched, test-only plus docs, additions-only in the Xcode project, no production source touched. All 20 flagged adjudications verified and accepted; every binding carryover (maxProbes re-probe arm, component split/no double-emit, NFR-MTC-012 byte-identity) is preserved and positively asserted; determinism and hygiene checks pass; gate evidence is consistent and preserved.

Commit conditions: commit the reviewed delta as-is — the four new test files, `ios/seniOS.xcodeproj/project.pbxproj`, `specs/T-139-notes.md`, `specs/T-140-notes.md`, `specs/T-143-notes.md`, `specs/MTC-device-validation-protocol.md`. Append the W5 rows to `specs/implement-notes.md` after this review (with F-1's scope corrected in the T-140 citation). Do not edit the suites. DV execution, step zero (PR #156 device smoke), and the T-141/T-142 downstream consumption remain open feature-gate items — none block this wave.
