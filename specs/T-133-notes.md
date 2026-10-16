# T-133 — Router dialogue interception, protocol and execution — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`; W1 at 76b28b9, W2 at 3b44c0c). Unit:
C-MTC-05, TG-26. No commits were made (the session commits); `.ai-sdd/` untouched.

## Status

Done and green. The pre-ladder dialogue-frame interception is implemented in
`CommandRouter.swift` (protocol surface, emergency clear, interception block,
execution/probe helpers) with a new focused suite of 21 named tests. Combined
scoped run under the shared build lock: **rc=0, 89 tests executed, 0 failures,
`** TEST SUCCEEDED **`, "Scoped unit run passed (baseline not advanced)"** —
`CommandRouterDialogueTests` 21/21, `CommandRouterMusicTests` 35/35,
`CommandRouterTests` 33/33. Trigger call sites are deliberately NOT wired —
T-134 owns them (anchor map below).

## Files changed

- MODIFIED `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`
  (sha256 `71156b85a298700f3080bdb8e097015a4b5809822feff0761a6a6a89de4fd625`)
  — the ONLY production file touched.
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/CommandRouterDialogueTests.swift`
  (sha256 `fb444f598c2bb9668423b803b658f1c087c76f7658ae39c0f6b33f2a76c388eb`)
  — 21 tests, one per Gherkin scenario / cross-wave pin. Joins the test target
  via the existing source glob (`build.sh` regenerates the pbxproj).
- NEW `specs/T-133-notes.md` (this file).

Not touched: `DialogueManager.swift`, `DialogueOptionCatalog.swift`,
`KeywordIntentRule.swift`, `VoiceSessionStateMachine.swift`, `LogSanitiser.swift`,
`AppCoordinator.swift`, `LocalBrainChain.swift`, `.ai-sdd/`, and the existing
`CommandRouterMusicTests.swift` doubles (all left byte-identical; the music
suite is green unmodified in the evidence run).

## What was built

### 1. Protocol surface (C-MTC-05 §12.1)

Six requirement-with-extension-default members on `VoiceCommandCoordinating`
(requirements `:125-153`, defaults `:570-576`): `activeDialogueFrame` (`:125`),
`startDialogueFrame(_:) -> Bool` (`:131`), `noteDialogueAttempt() -> Int`
(`:136`), `resolveDialogueFrame(_:)` (`:142`), `clearDialogueFrame(reason:)`
(`:147`), `prepareDialogueAnswerText(_:) -> String` (`:153`). The default for
the last is `InputSanitiser.sanitise(raw, level: .quarantine)`. Every existing
conformer compiles unchanged (defaults), so nothing behavioural changes until
T-136 implements the hooks on `AppCoordinator`.

### 2. Emergency clear (§12.3) — `:853`

`coordinator?.clearDialogueFrame(reason: .emergency)` sits after
`handleEmergency()` and before `return .emergencyTriggered` (`:843-855`).
POST-dispatch and side-effect only: it contributes no condition, delay or gate
to the emergency path (L1 ADR-MTC-02). Two tests pin both halves: dispatch
unchanged with the clear live, and dispatch unchanged with the clear forced to
a no-op.

### 3. The interception block (§12.2) — `:960-1067`

Runs between the confirmation hook's close (`:958`) and the deterministic
safety net (`// Deterministic safety net FIRST` `:1069`,
`if let safetyResult = routeSafetyNet(raw) {` `:1078`); the emergency block
(`:843-855`) and the gibberish guard (`:811-822`) stay absolutely above it.
Reads `coordinator?.activeDialogueFrame`; classifies via
`DialogueAnswerPath.classify(raw:prepared:frame:catalog:locale:now:medicationNames:)`
with the live medication vocabulary computed exactly as the keyword stage
computes it (`:981-983`, mirroring `:1385`). Arms:
- `.expired` → fall through (fresh command);
- `.escape` / `.cancel` → resolve + `dialogue_frame_resolved` +
  `dialogue.escape` / `dialogue.cancelled`, return terminal;
- `.bargeIn` → resolve `.bargedIn` + event, fall through so the ladder
  executes the strong command exactly once (L1 ADR-MTC-05, L2-D18);
- `.candidatePick(index:capture:)` → executor with `index - 1` (1-based
  spoken → 0-based executor, §12.2);
- `.answer(merge)` → `executeDialogueAnswer`;
- `.freeFormForCandidate(index:value:)` → executor with the 0-based index
  consumed directly and `queryOverride = value`, capture `.freeText`;
- `.invalid(reason)` → `dialogue_answer` {`reason`} (C-3: direct
  `ObservabilityEvent` construction — the two-argument helper hardcodes empty
  metadata) then one honest re-probe while `attempts <= DialogueConfig.maxProbes`,
  else exhaustion.

Every consumed arm returns before the interpreter and the transcript cache
(FR-MTC-017). No console writes anywhere in the block or helpers (V-2).

### 4. Helpers (§12.4/§12.5, the trigger seam T-134 consumes) — `:2873-3260`

`// MARK: - [MTC] Dialogue frame (multi-turn conversation, design-l2 §12)` at
`:2873`, ending before `/// One music turn, state machine B` (`:3262`):
`DialogueDegenerateIntake` (`:2889`), `dialogueCatalog` (`:2899`),
`dialogueSlotFillDraft` (`:2909`), `fireMusicRequestOrProbe` (`:2948`),
`speakDialogueProbe` (`:2985`), `dialogueProbeOptionCount` (`:3012`),
`speakDialogueDidYouMean` (`:3032`), `speakDialogueDidYouMeanOrReprompt`
(`:3044`), `executeDialogueAnswer` (`:3067`), `dispatchDialogueMusicValue`
(`:3085`), `executeDialogueCandidate` (`:3114`), `resolveDialogueExhaustion`
(`:3186`), `executeDialogueDefault` (`:3203`), `emitDialogueAnswer` (`:3216`),
`emitDialogueFrameResolved` (`:3238`).

Execution semantics: a consumed value dispatches through the pending
command's own merge (`.music` arm, cache-free) or `fireMusicRequest`;
candidate picks run through the domain's own arm — `.news` mirrors the relaxed
arm (`speakPreAck` → `fireNewsReader` → `news_reader_command`, C-2), `.youtube`
fires the play, `.music` chains through `fireMusicRequestOrProbe`
(`intake: .candidate`), `.appLaunch` hands to `requestAppLaunch` and speaks the
returned line. Exhaustion: candidateChoice closes `.exhausted` +
`dialogue.exhausted`, nothing executed (R3); slotFill executes its pending
default (`.defaultExecuted`).

### 5. Events (§26, C-3)

Four events, all directly constructed with closed metadata vocabularies:
`dialogue_degenerate_query` {`intake`}, `dialogue_probe_spoken`
{`probe_kind`, `attempt`, `option_count`; `degraded`/"catalogUnavailable" when
the slotFill catalog is absent}, `dialogue_answer` {`capture_form`,
`merge_source` | `reason`}, `dialogue_frame_resolved` (outcome field + 
`outcome` metadata; the ten-case map in one place). Component split: the
router emits the turn-time seven (answered, defaultExecuted,
candidateSelected, exhausted, cancelled, escaped, bargedIn); timeout /
emergency / supersession belong to the coordinator's funnel (T-136).

## Tests (21, `CommandRouterDialogueTests`)

Gherkin scenarios 1–10 of the task file plus the DoD/cross-wave pins:

| # | Test | Pins |
|---|---|---|
| 1 | `testAnswerTurnNeverReachesTheInterpreterOrCache` | FR-MTC-017 — real `IntentRouter` over a seeded real `IntentCommandCache` on a counting storage: answer consumed with interpretCount/reads/writes all 0 and no `cache_hit`; control leg (no frame) reaches interpreter + cache and hits |
| 2 | `testEmergencyMidFrameDropsTheFrameAndDispatchIsUnchanged` | emergency dispatch byte-unchanged; clear is post-dispatch (callLog order); `.emergency` is the coordinator's event |
| 3 | `testEmergencyDispatchStillRunsWithTheClearForcedToANoop` | E1 producer side — no condition/delay/gate |
| 4 | `testCancelIsSpokenAndTerminalForTheTurn` | C4 → `.cancelled`, line spoken, ladder never runs |
| 5 | `testEscapeIsSpokenAndTerminalForTheTurn` | C2 → `.escaped`, line spoken, ladder never runs |
| 6 | `testBargeInResolvesTheFrameAndFallsThroughExactlyOnce` | B5 → `.bargedIn`, ladder executes exactly once (opener URL + openingSearch line) |
| 7 | `testInvalidAnswerConsumesOneAttemptAndReProbesWithTheRetryVariant` | C-3 `reason` metadata; probe event ordinal; retry text = `DialogueProbeComposer`; fresh window; no resolution |
| 8 | `testSlotFillExhaustionExecutesTheDefaultQueryThroughTheMusicArm` | `.defaultExecuted`, merge metadata, default query reaches the music arm |
| 9 | `testCandidateChoiceExhaustionClosesHonestlyWithoutExecutingAnything` | `.exhausted`, nothing executed, both reasons carried |
| 10 | `testExpiredFrameLeavesTheUtteranceAFreshCommand` | `.expired` falls through unaltered; zero dialogue telemetry |
| 11 | `testConfirmationHookIsBehaviourallyUntouched` | hook outranks the frame: `.acknowledgedMedication`, frame untouched |
| 12 | `testInterceptionBlockSitsBetweenTheConfirmationHookAndTheSafetyNet` | placement source pin (hook → interception → safety net, emergency above) |
| 13 | `testCandidateExecutorBoundsChecksHostileIndices` | M-5 bounds refuse −1/2/5 before any addressing; `.exhausted` + honest line; no execution |
| 14 | `testIndexWordCandidatePickDecrementsToTheZeroBasedExecutor` | 1-based spoken → index 0 `.candidateSelected`; candidate's own query executes |
| 15 | `testFreeFormClaimConsumesTheZeroBasedIndexAndExecutesTheCandidate` | 0-based claim consumed directly; `.answered` `.freeText`/`.candidate` |
| 16 | `testNewsCandidateExecutesWithTheRelaxedArmParity` | C-2 news triplet + pre-ack |
| 17 | `testLiveMedicationVocabularyReachesTheClassifierAtTheInterceptionSite` | W2 F-1 discharge — A/B: with vocabulary `.bargedIn`; without, free-text merge |
| 18 | `testOverLengthRawAnswerIsRejectedWithItsReasonMetadata` | C1 gate + C-3 `reason: overLength` |
| 19 | `testGibberishMidFrameConsumesNoAttemptAndLeavesTheFrameLive` | V-1 |
| 20 | `testSanityGuardPrecedesEmergencySoRejectedNoiseNeverTriggersIt` | V-4 |
| 21 | `testInterceptionAndHelperRegionsAddNoConsoleWrite` | V-2 region-scoped scan |

Fixtures are real behaviour: the armed frames go through the REAL
`DialogueManager` (mock coordinator's six members are thin adapters), the
catalog is the shipped `DialogueOptionCatalog.json`, and the music arm lands
on the keyless-YouTube leg (opener URL assertions). Interpreter/cache
behaviour is the REAL `IntentRouter`/`IntentCommandCache` behind a counting
`CommandInterpreter` and counting `EncryptedLocalStorage`.

## Results

- **Green run (the gate evidence)** — 2026-10-10 17:04 AEDT:
  `cd ios && ./build.sh test:unit CommandRouterDialogueTests CommandRouterMusicTests CommandRouterTests`
  → rc=0; `Executed 89 tests, with 0 failures (0 unexpected)`; per suite:
  CommandRouterDialogueTests **21**, CommandRouterMusicTests **35**,
  CommandRouterTests **33**. xcresult
  `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_17-04-52-+1100.xcresult`;
  log `/tmp/mtc-w3-t133-run2.log`. The release log-safety gate and the
  prompt-mirror gate ran green inside the same build. (Correction, W3 review
  F-1: the command-line is covered by the gate's existing transcript/error
  rules; the four new T-138 feature roots are the dialogue helper files —
  DialogueManager, DialogueAnswerPath, DialogueCandidateBuilder,
  DialogueOptionCatalog — and CommandRouter.swift is not among them.)
- **Red-run history (honest)** — run 1, 17:00 AEDT, rc=65: 2 compile errors in
  the new suite only ("'try' cannot appear to the right of a non-assignment
  operator" — the V-2 region-slice `..< try …` construction); fixed by
  hoisting the range bounds into `let`s. xcresult
  `Test-ElderlyAssistant-2026.10.10_17-00-58-+1100.xcresult`; log
  `/tmp/mtc-w3-t133-run1.log`. Two further corrections were made pre-build
  against a standalone replica of `TranscriptSanityGuard`: the over-length
  fixture was 153 chars (< the 200 gate) and was extended to 228 (guard
  `.pass`, >200, ≤300); one `XCTAssertNil` misuse on a `Bool` was corrected.
- **Not run here (by protocol):** the full unit bundle (known ~21 pre-existing
  failures at the branch base — none of the three suites above is among them;
  T-141 owns the full-gate comparison).

## DoD checklist (task file)

- [x] `testAnswerTurnNeverReachesTheInterpreterOrCache` — spy counters zero + causal control leg.
- [x] Emergency test with the clear forced to a no-op (E1) — dispatch identical.
- [x] C-2 news-parity anchors — `speakPreAck` → `fireNewsReader` → `news_reader_command`.
- [x] C-3 direct event construction carries `reason` (never dropped).
- [x] M-5 hostile index refused with no addressing.
- [x] V-1 / V-4 recorded by tests (guard placement unchanged).
- [x] V-2 no console write in either new region.
- [x] Focused suite green + the two existing router suites green in one locked run.
- [x] No sibling-unit file modified; music-suite doubles intact.

## Deviations (with rationale)

1. **§12.2's `attempts < maxProbes` implemented as `attempts <= maxProbes`**
   (`:1058`, with an in-code erratum comment). `noteDialogueAttempt()` returns
   the post-increment count (≥2 on the first invalid answer), so `<` makes the
   re-probe unreachable and contradicts the task-file Gherkin and §24's "one
   honest re-probe".
2. **`medicationNames` passed at the interception call site** (`:981-983`) —
   the W2 review F-1 obligation and the discharge of the §12.2 snippet's
   recorded erratum. Computed exactly as the keyword stage computes it
   (`coordinator.medicationVoiceEntries` → `MedicationVoiceVocabulary.voiceKeys`);
   with the default the medication-photo half of B6 is inert.
3. **`fireMusicRequestOrProbe`** keeps §12.5's pinned
   `(query:raw:intake:)` shape and gains an additive defaulted
   `activeCommand: InterpretedCommand? = nil` fourth parameter (L2-D13: the
   interpreted intake passes the arrived command so the armed frame can merge
   into it).
4. **`speakDialogueProbe(frame:retry:locale:)`** carries an additive defaulted
   `locale` so the pinned `speakDialogueDidYouMean` signature can pass one;
   in-turn call sites pass nothing and read the coordinator's locale.
5. **`dialogue_frame_resolved` component split** — the router emits the
   turn-time seven; T-136's funnel emits timeout/emergency/supersession only
   (must not double-emit turn-time outcomes). Recorded in the helper doc and
   handed to T-136 below.
6. **The T-133 Gherkin's barge-in wording ("resolves as superseded") vs the
   design's `.bargedIn`** — implemented `.bargedIn` (L2-D18 vocabulary; the
   task file's parenthetical is the older draft).
7. **M-5 test seam** — classify is total, so a hostile index cannot arrive
   through `route()`; `executeDialogueCandidate` is therefore `internal` (not
   file-private) so the bounds refusal can be driven directly. Refusal
   semantics: resolve `.exhausted`, emit the event, speak
   `dialogue.exhausted`, execute nothing.
8. **V-2 scan is region-scoped** — the file's pre-existing `#if DEBUG`
   `print`s (`speak(text:)` `:4430` and friends) sit outside both new regions
   and are untouched; the release log-safety gate covers the whole tree and is
   green.

## Integration notes

### For T-134 (trigger call sites — NOT wired by this unit)

Post-change line numbers (verified against the working file; re-locate by the
quoted symbol if the file drifts):
1. **Ladder music arm** — `:1414`
   `fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)`
   (inside the relaxed deterministic music stage). Replace with
   `fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: preText), raw: raw, intake: .ladder)`.
2. **Interpreted-command music path** — `dispatchInterpreted` at `:3897`; its
   `.music` case calls `fireMusicRequest(query: interpretedQuery…` at `:3935`.
   Replace with `fireMusicRequestOrProbe(…, intake: .interpreted, activeCommand: command)`.
3. **Rephrase-discard** — confirmation-hook discard branch `:878-880`
   (`_ = coordinator?.takePendingRephraseCommand()` / `rephrase_discarded` /
   `speak(key: "router.rephrase.discard")`). The did-you-mean helpers to call
   are `speakDialogueDidYouMeanOrReprompt(raw)` (`:3044`, assembles
   candidates via `DialogueCandidateBuilder` and falls back to the reprompt)
   and `speakDialogueDidYouMean(_:locale:)` (`:3032`, speaks only — the caller
   arms the frame).
4. **Keyword-remainder reprompt** — `routeKeywordRemainder` `:2161-2223`,
   `speak(key: "router.reprompt")` at `:2214` (the occurrence inside that
   function; the same key also appears at `:820` (guard — not a trigger site),
   `:2573`, and my helper's fallbacks `:3049`/`:3055`). Replace with
   `speakDialogueDidYouMeanOrReprompt(raw)`.

All helpers are in-file (`private` is fine for T-134); the intake enum is
`DialogueDegenerateIntake` (`:2889`). Fallbacks are never dead ends: an
arm-failure (`startDialogueFrame == false`) or a non-degenerate extraction
falls back to today's exact blind request.

### For T-136 (coordinator wiring)

- Implement the six members on `AppCoordinator` (signatures at `:125-153`);
  defaults at `:570-576` keep the app compiling until then. The coordinator
  owns the `DialogueManager`; the router only calls the hooks and reads
  `activeDialogueFrame`.
- `medicationVoiceEntries` must return the live schedule (the interception
  reads it at `:981-983` — W2 F-1 is discharged at the producer side).
- The funnel emits `dialogue_frame_resolved` for timeout / emergency /
  supersession ONLY; the router already emits the turn-time seven (`:3238`).
  The `.emergency` clear from `:853` arrives through `clearDialogueFrame` —
  the coordinator's own event surface.
- `prepareDialogueAnswerText` default (quarantine sanitiser) may be kept.

### Open items

- The youtube/appLaunch arms of `executeDialogueCandidate` ride T-132's
  builder guarantees and defensive guards; they are not exercised by this
  suite (no Gherkin scenario); the T-139 trap matrix / T-141 sweep can pin
  them.
- `fireMusicRequestOrProbe`'s degenerate branch has no production caller
  until T-134 lands; its probe/event half is covered here through the
  interception's re-probe path, the candidate-chain intake comes with T-134's
  wiring.
