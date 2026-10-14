# T-177 — Indicator, revocation surfaces and coordinator wiring (implement notes)

**Status: implemented; wave-close rework applied — both scoped class runs green twice
(88 tests, 0 failures, `** TEST SUCCEEDED **`, exit 0) and the compile gate re-run green
(`** TEST BUILD SUCCEEDED **`, exit 0) after the rework (see "Wave-close rework" at the end).**
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`, HEAD `5367b539`). Declared files only, with one
documented deviation (`CommandRouter.swift` — the router-side members this unit cannot work
without; Decisions 1) plus the expected `ios/seniOS.xcodeproj/project.pbxproj` diff produced by
`./build.sh generate` (registers exactly the two new files, nothing else). Per amendment 4
(per-unit cadence) the tests below were authored in-unit but NOT executed here: this unit's gate
was code + the compile gate, and one consolidated scoped suite pass ran at wave close — it
found 21 failures, all in this unit's two suites; both root causes were fixed in this unit and
the two classes re-verified green (the section at the end of this file). No commits, no
pushes, no `ai-sdd` mutating commands.

## What was built

### 1. `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatActivityIndicator.swift` (declared, new, 245 lines)

The badge's model / surface / view, the attempt-begin/settle wrapper and the Home host — the
LiveTranslate indicator-model pattern reused rather than a second mechanism (design-l1 §8.5):

| Line | What |
|---|---|
| `@ 48` | `CloudChatActivityIndicatorModel` — `@Published private(set) var isActive`; `requestBegan()` opens the window (0→1); `requestEnded()` closes it only at 1→0 — an unpaired end is ignored, so a stray funnel cannot drop a window it never opened. `openWindowCount` (+ `openWindowCountForTesting`) exposes the register. |
| `@ 89` | `CloudChatActivityIndicatorSurface` — `isActive`, `cloudChatEnabled`, `locale`; `isShown == isActive && cloudChatEnabled` (the badge "also reflects the enabled state in Settings": a revoked device shows nothing even with a window open); `label = L10n.str("cloud.chat.indicator", locale:)` — a zero-format-slot catalogue value, no content; `symbolName = "cloud"`. |
| `@ 126` | `CloudChatActivityIndicatorView` — renders nothing at all when `!isShown` (the local-turn absence made structural); identifier `"cloudchat.indicator"`. |
| `@ 169` | `CloudChatIndicatorResponder: ChatResponding & CloudFailureReporting` — `init(wrapping:onAttemptBegan:onAttemptSettled:)`; begin fires BEFORE the delegate (the window and the notice are committed before the network call is awaited — the `speakPreAck` discipline), settle fires inside the completion BEFORE forwarding (the provenance is on record before the router's guard asks for it), and failure reporting forwards unchanged. |
| `@ 229` | `CloudChatSurfacesHost: View` — resolves the coordinator from the environment; renders the badge and the consent question's `.sheet(isPresented:)` bound to `cloudChatConsentPromptIsPresented` (setter is a no-op: the answer paths write, never the dismiss gesture). |

Hygiene (pinned by test): imports are Foundation + SwiftUI only; no `emit(` / `print(` /
`NSLog` / `os_log`; no `Info.plist`; the file adds no permission and no platform capability.

### 2. `ios/ElderlyAssistant/App/AppCoordinator.swift` (declared, +608/−3, 10 hunks)

| Hunk | What |
|---|---|
| `@ 881` | The state section (`// MARK: - [CNR T-177] Cloud-chat wiring state`): `cloudChatConsentGate`, `cloudChatReachability: NetworkReachability`, the turn-scoped flags (`cloudChatReplyServedFromCloud`, `cloudChatIndicatorWindowOpen`, `cloudChatAttemptSettled`, `cloudChatNoticeSpoken`, `pendingCloudChatConsentCapture`), the lazily born model/prompt storages with their cancellables, the wrapped responder. |
| `@ 2894` | init: `cloudChatConsentGate = CloudChatConsentGate(storage: liveTranslateStorage, observabilityBus: bus)` — one process-lifetime instance on the same encrypted consent channel, its own key (`plugin.cloud_chat.consent.v1`, T-172), no I/O at construction — and `cloudChatReachability = PathMonitorReachability()`. |
| `@ 3363` | The confirmation-timeout handler: `reofferCloudChatConsent = pendingCloudChatConsentCapture` is read BEFORE the clears — a lapsed capture window lapses the WINDOW, never the QUESTION (T-176's contract). |
| `@ 3407` | …and the timeout branch: with that flag set, `reofferCloudChatConsentAfterTimeout()` replaces the generic `router.confirmationTimeout` line — there is no unanswered request to give up on; the question is still on screen. |
| `@ 4166` | `start()`: the chat lane's seam (T-175) — `router3.cloudChatLane.routingInputs = CloudChatRouting.Inputs(consent: cloudChatConsentInput, online: cloudChatReachability.isReachable, keyConfigured: geminiConfigStore.isConfigured, costAllows: geminiCostGovernor.allowsCall)` (every input READ PER TURN, none cached) — and the ONE wrapped responder `CloudChatIndicatorResponder(wrapping: geminiInterpreter, onAttemptBegan:, onAttemptSettled:)`, shared by the lane's cloud leg and the guard's escalation so every cloud attempt, whichever door issued it, drives the same window and the same notice. |
| `@ 4253` | `start()`: the guard seam (T-174) — `chatGuard: ChatGuardSeam(servingPath: cloudChatServingPath, cloudAllowed: cloudChatGuardAllowsCloud, respondToChat: cloudChatGuardRespondToChat)`. The teardown arm answers `completion(nil)` so the guard's exactly-once contract resolves even without a `self`; `respondToChat` carries the turn's context built here (empty pending medications, the language hint, the guarded address-as) through the same wrapped responder. |
| `@ 5733` | `noteSpeakingEnded`: `self.cloudChatCloseWindowIfSpeechEnded()` — the window's speech-end funnel. |
| `@ 5798` | The T-177 section (+433 lines): surfaces, routing seam, attempt lifecycle, voice controls, consent capture, main-actor factories (behaviour below). |
| `@ 12812` | `handleConfirmationResponse`: the consent question's spoken answer — the LAST flowed confirmation block (`if pendingCloudChatConsentCapture, pendingConfirmationEntryId == nil`): yes → `answerCloudChatConsent(granted: true)`, no → `(granted: false)`; every earlier block has already returned, and a simultaneous dose challenge keeps its claim. |
| `@ 12852` | `isAwaitingConfirmation` widened with `\|\| pendingCloudChatConsentCapture` — while the question is pended the router's confirmation path owns the yes/no. |

Behaviour, exhaustively (all pinned by test):

- **Per-turn reads, no cache.** `cloudChatConsentInput()` reads `currentDecision()` on every
  call; `online` / `keyConfigured` / `costAllows` read their live sources per call; the guard's
  `cloudAllowed` re-runs `CloudChatRouting.decide` over the SAME lane inputs — one chokepoint,
  so consent can never be bypassed at the escalation door.
- **The consent question's one trigger.** Inside the consent closure, only when the decision is
  `.notRecorded` — by construction the reason the turn is local (consent is the decision's
  first input). Never at launch, never in Settings, never speculatively: no chat turn, no call.
  The prompt's own idempotence keeps the question singular across the guard's re-decide for the
  same turn. `consentNeedDetected(answerPendingTurnLocally:)` is called with the EMPTY closure
  — a declaration, not a stub (Decision 6).
- **The question's spoken capture.** The prompt's `startSpokenCapture` seam is the
  coordinator's `beginCloudChatConsentCapture` (sets the pended flag + arms the shipped 45 s
  confirmation window, `openConfirmationWindow()`). The spoken yes/no rides the router's
  confirmation path into the coordinator's block; an answer outside a live question writes
  nothing and says nothing (T-176's `.questionNotLive`); an accepted answer speaks the state
  line read from the gate AFTER the write (truthful state, never the requested one) via
  `cloud.chat.state.spoken.on` / `.off`; a failed grant keeps the question on screen and
  re-offers the spoken answer (`cloudChatCloseConsentCaptureIfResolved`).
- **A lapsed capture re-offers, never expires.** The timeout path above re-offers
  (`reofferCloudChatConsentAfterTimeout()` → T-176's `reofferSpokenAnswer()`); nothing here
  records a verdict.
- **The decision-change aftermath, shared by every writer** (`cloudChatDecisionDidChange()`):
  closes the badge window, clears the pended capture, refreshes the prompt against the gate
  (T-176's rule: a question with an answer is closed), re-renders the surfaces.
- **The badge window.** ONE open site — the wrapped responder's began hook
  (`cloudChatCloudAttemptBegan`), reachable only when a cloud call is actually issued, which is
  what makes "the badge never shows for a local-only turn" structural rather than a rendering
  condition. Close funnels: (a) `cloudChatCloseWindowIfSpeechEnded` at every speech end — the
  window closes only when the attempt has settled AND `speakingCount == 0` (a notice or pre-ack
  still playing simply asks again at its own end); (b) any decision change (revocation
  included); (c) the next chat-turn decide (`cloudChatConsentInput` closes first — "a fresh
  chat-turn decision supersedes any open window"). The provenance flag is cleared at every
  attempt begin, every window close and every decide: no turn can inherit another turn's
  provenance.
- **The notice.** `cloudChatSpeakNoticeOnce()` runs at the attempt begin — once per app session
  (`cloudChatNoticeSpoken`), only when a speaker exists (`speaker != nil`; nil before
  `start()`, so nothing can be spoken early), key `cloud.chat.indicatorSpoken` (T-171; the
  elder's language; zero format slots; no turn content). It is committed before the network
  call is awaited, so it rides the wait and never delays the reply; if the answer arrives
  mid-notice the reply takes the speaker (the speaker's existing cancel discipline — the
  news-path precedent).
- **The voice controls** (`handleCloudChatVoiceRequest`, main-hopped). `.revoke` →
  `cloudChatConsentGate.revoke()` — the ONE writer, deny-first, so a failed write still denies
  and is never reported as success — then `cloudChatDecisionDidChange()` and
  `replyHonestly(key: "cloud.chat.revoke.done")` (true for a landed revoke, a failed one and a
  repeat, which is idempotent). `.stateQuery` → `cloud.chat.state.spoken.on` exactly when
  `currentDecision().allowsEgress`, else `.off` (a revoked record, a decline and an unreadable
  store all read fail-closed as OFF). No model, no interpreter, no NLU — the coordinator only
  acts on the vocabulary the router matched.
- **The Settings write.** `setCloudChatEnabledFromSettings`: ON = `record(granted: true)` (the
  explicit re-enable; how a withdrawn record returns to not-decided without a reset), OFF =
  `revoke()`; the write is SILENT (like every other Settings control — the surfaces are the
  feedback); the row's read-back is `currentDecision()`, so a failed write reads off rather
  than claiming a state that is not on disk.
- **Surfaces.** `cloudChatIndicatorSurface` (the model's window AND the gate, both re-read per
  render), `cloudChatConsentPromptIsPresented` (never builds the prompt — an unbuilt prompt is
  an unasked question), `cloudChatConsentSheetSurface` (T-176's sheet; catalogue keys only),
  `cloudChatEnabled` (the Settings row's fresh read).
- **Factories and locale.** Model and prompt are born on the main actor on first use; their
  publishes are forwarded through the coalescing seam so the status slot and the Settings leaf
  re-render. The prompt's locale is re-applied on EVERY access (`prompt.updateLocale(activeLocale)`),
  so a language change re-resolves every string the question and its sheet show — no
  `syncServiceLocales` edit needed (Decision 9).
- **Threading.** Every new entry point main-hops (`guard Thread.isMainThread` + async
  re-dispatch: settings write, voice request, attempt began/settled, capture begin, answer) and
  the view-state touches sit inside `MainActor.assumeIsolated`; an off-main read of the consent
  input degrades to the fail-closed decision instead of trapping, and the question is never
  raised off-main.

### 3. `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift` (declared, +188/−0, 2 hunks — +142 at the unit gate; the wave-close rework added the family-scoped scalar matcher in the same section)

- `@ 70` — a header paragraph recording the family's placement: the controls live in this file
  but OUTSIDE the `Domain` table, answering two questions from keyword co-occurrence alone —
  "revoke the internet answers" and "are the answers coming from the internet right now?" —
  with no model, no NLU and no classifier widening. (Any `Domain` case would have widened the
  router's exhaustive switch and re-shaped existing claims.)
- `@ 1021` — the `// MARK: - [CLOUD-CHAT]` section: `enum CloudChatVoiceRequest: Equatable
  { revoke, stateQuery }` with `eventToken` `"revoke"` / `"state_query"` (deliberately NOT
  `CaseIterable`: nothing else may iterate the vocabulary), three private groups (internet
  words/phrases; stop verbs; state markers), the variant order
  `[(.revoke, [internet, stop]), (.stateQuery, [internet, state])]` — revoke FIRST is the
  contract — and `static func cloudChatVoiceRequest(transcript raw: String) ->
  CloudChatVoiceRequest?` (`@ 1132`), which falls through to nil for an internet mention with
  neither a stop verb nor a state marker (and for a stop verb with no internet word).

### 4. `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` (NOT declared — documented deviation, +100/−0, 6 hunks)

| Hunk | What |
|---|---|
| `@ 501` / `@ 513` | The protocol's two members: `var isAwaitingCloudChatConsentConfirmation: Bool { get }` and `func handleCloudChatVoiceRequest(_:)`. |
| `@ 651` / `@ 652` | The extension defaults: `{ false }` and `{}` — every existing conformer and construction site stays byte-identical. |
| `@ 1175` | The confirmation block: `isCloudChatConsentConfirmation` read (LAST of every pending flow) and `speaksItsOwnYesNo` widened — the question speaks its own state line; the generic catalogue yes/no would claim a dose was taken. |
| `@ 1210` | The yes branch's typed return for the consent question: `.unrecognised(transcript: raw)` — the turn is consumed, not a medication acknowledgement. |
| `@ 1831` | The keyword-stage block (after the relaxed keyword stage and its switch, before the topic pre-answers and the interpreter): `if let request = KeywordIntentRule.cloudChatVoiceRequest(transcript: preText) { emit…; coordinator?.handleCloudChatVoiceRequest(request); return .unrecognised(transcript: raw) }` — the turn ends deterministically, no model, no dispatch. |
| `@ 2085` | `emitCloudChatVoiceControl`: `component: "command_router"`, `eventType: "cloud_chat_voice_control"`, `outcome: request.eventToken`, `metadata: [:]` — the classification only; no transcript, no content, no identity (pinned by test). |

Why it is a deviation: the unit's DoD cannot be met without router-side entry points — the
voice rule must END the turn before the interpreter runs, and the capture must reach the
coordinator through the router's existing confirmation path. The delta is additive only:
defaults preserve every pre-existing construction site, and every pre-existing rule's
behaviour is pinned unchanged by the extended suite (section 8).

### 5. `ios/ElderlyAssistant/App/HomeSubviews.swift` (declared, +8/−0, 1 hunk)

`CloudChatSurfacesHost()` mounted once in the status slot's content. The host is parameterless
and resolves the coordinator from the environment, so `TalkStage`'s stored fields and its
`Equatable` are untouched; outside a cloud-active window it renders nothing. No new screen
(design §8.5: "the existing status-slot surface").

### 6. `ios/ElderlyAssistant/App/SettingsView.swift` (declared, +37/−0, 2 hunks)

`cloudChatSettingsRow` inserted above `.privacy` in the System tab (where the privacy-shaped
household controls live — the LiveTranslate row's own placement rationale): the shipped
`LiveTranslateToggleRow` (usage only; the row type is untouched), title/note from T-171
(`settings.cloudChat.toggleLabel` / `.toggleNote`, both zero-format-slot values — nothing here
mints copy), identifier `settings.cloudChat.toggleLabel`. The binding reads the gate's CURRENT
decision through the coordinator on every render (no `@State` mirror, no `onAppear` re-read: a
mirror could go stale against a voice revoke, and a failed write must read back as what is on
disk) and writes through `coordinator.setCloudChatEnabledFromSettings`.

### 7. `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatIndicatorAndRevocationTests.swift` (declared, new, 1032 lines, 25 tests — 972 at the unit gate; the wave-close rework added the isolation section and the multi-leg helper)

End-to-end pattern: a real `AppCoordinator(profileStorage:)` over a file-scope in-memory
profile-payload double + a real `CommandRouter` over a `NullCommandInterpreter` + a bus/speaker
double; console capture for the gate's own events; `Mirror` for the coordinator's private seam
flags; region-scoped source scans (`functionBody(named:in:)`, occurrence counts) for the
`start()`-scoped wiring — `start()` cannot run in the test host (BGTaskScheduler throws a
platform exception there), so the wiring the coordinator installs inside `start()` is pinned at
its source (call sites, counts, order), while every reachable behaviour runs end-to-end.

| Gherkin scenario / DoD item | Test(s) |
|---|---|
| Badge on for the whole cloud-active window, never before/after | `testTheBadgeIsOnForTheWholeOpenWindowAndNeverBeforeOrAfter`, `testAnUnpairedWindowCloseIsIgnoredSoTheNextWindowStillShows` |
| Badge never for a local turn | `testALocalOnlyTurnLeavesTheBadgeOff` |
| Badge reflects the enabled state (revoked device shows nothing), zero-slot label | `testTheBadgeRendersOnlyInAnOpenWindowOnADeviceWhereCloudChatIsInForce`, `testTheBadgeLabelCarriesNoFormatSlotsInEitherLanguage` |
| The wrapper's hook order and provenance | `testTheAttemptHooksRunAroundTheDelegateInTheDeclaredOrder`, `testTheSettleHookRecordsProvenanceBeforeTheCallerSeesTheReply`, `testTheWrapperForwardsFailureReporting` |
| Settings row writes through the one writer; silent | `testTheSettingsToggleWritesThroughTheGatesOneWriter`, `testTheSettingsToggleIsSilentAndAsksNoQuestion` |
| Voice revoke: gate write, turn ended, next turn local | `testARevokeUtteranceWithdrawsThroughTheGateAndEndsTheTurn`, `testNoCachedRouteSurvivesRevocation` |
| No content in the voice-control event | `testTheRevokeTurnEmitsOnlyTheClassificationAndNoContent` |
| State query truthful in both states | `testAStateQueryIsAnsweredTruthfullyFromTheGateInBothStates` |
| No model involvement | `testTheVoiceControlsNeverConsultAnInterpreter` |
| Spoken/sheet consent answers write through the same gate writer | `testASpokenYesThroughTheConfirmationWindowWritesTheGrantAndClosesTheQuestion`, `testASpokenNoClosesTheQuestionWithADenial`, `testARepeatedAnswerAfterTheQuestionClosedWritesNothing`, `testTheSheetAnswersWriteThroughTheSameGateWriter`, `testTheConsentAnswerRidesTheExistingYesNoCaptureAndIsNotAMedicationAck` |
| Window lifecycle at the source (one open site, speech-end funnel) | `testTheIndicatorWindowHasExactlyOneOpenSiteAndTheSpeechEndFunnel` |
| Lane + guard seams filled per turn, nothing cached | `testTheLaneAndGuardSeamsAreFilledPerTurnAndNothingIsCached` |
| Notice once per session, rides the attempt begin | `testTheNoticeIsOncePerSessionAndRidesTheAttemptBegin` |
| One writer, router only reports | `testTheCoordinatorOwnsTheWriterAndTheRouterOnlyReports` |
| Surface mount + indicator hygiene | `testTheSurfaceHostIsMountedAndTheIndicatorFileStaysClean` |

### 8. `ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleTests.swift` (declared, +177/−0, 1 hunk, 9 new tests; file now 63)

The `// MARK: - [CLOUD-CHAT] Voice controls (T-177, design-l1 §8.6)` section: the revoke family
resolves every authored utterance (14, data-driven); the state family resolves every authored
utterance (13 — including "is the internet off?", a query); the revoke reading is checked
before the query reading; an internet word alone is never a control; a stop verb without the
internet word never fires this family; an internet mention with neither verb nor state marker
falls through (a pinned music utterance still claims its own); the family is deterministic
under noise and case; **the cloud family never claims an utterance an existing rule claims**
(pinned fixtures: news, YouTube, music — both control utterances match nil in the relaxed
stage); the control tokens are the closed vocabulary. No existing test in the file changed.

### 9. `ios/seniOS.xcodeproj/project.pbxproj` (generate-produced, +8/−0)

`./build.sh generate` registered exactly the two new files (build-file + file-reference +
group + Sources-phase lines each). Expected diff; left in place per the brief.

## DoD mapping (task file, Definition of done)

| DoD item | Where it lives | Pinned by |
|---|---|---|
| Gate lifecycle and routing closures wired; decision read per turn | Coordinator @2894 (gate), @4166 (lane inputs + responder), @4253 (guard) + `cloudChatConsentInput` @5888 (`currentDecision()` per call) | `testTheLaneAndGuardSeamsAreFilledPerTurnAndNothingIsCached`, `testNoCachedRouteSurvivesRevocation`, `testTheCoordinatorOwnsTheWriterAndTheRouterOnlyReports` (behaviour) + region source pins (start()-scoped wiring) |
| Badge present for the whole cloud-active window, absent for local turns | Indicator file `@ 48/@ 89/@ 126`; window lifecycle @5961–6012 | `testTheBadgeIsOnForTheWholeOpenWindowAndNeverBeforeOrAfter`, `testALocalOnlyTurnLeavesTheBadgeOff`, `testAnUnpairedWindowCloseIsIgnoredSoTheNextWindowStillShows`, `testTheBadgeRendersOnlyInAnOpenWindowOnADeviceWhereCloudChatIsInForce`, `testTheIndicatorWindowHasExactlyOneOpenSiteAndTheSpeechEndFunnel` |
| One spoken notice per session at the first cloud-active turn, user's language | `cloudChatSpeakNoticeOnce` @6021–6025, key `cloud.chat.indicatorSpoken` (catalogue: zero format slots both languages) | `testTheNoticeIsOncePerSessionAndRidesTheAttemptBegin`, `testTheBadgeLabelCarriesNoFormatSlotsInEitherLanguage` |
| Settings row and voice revoke write through the one writer; next turn local | `setCloudChatEnabledFromSettings` @5847; `handleCloudChatVoiceRequest` `.revoke` @6043–6053; SettingsView row | `testTheSettingsToggleWritesThroughTheGatesOneWriter`, `testTheSettingsToggleIsSilentAndAsksNoQuestion`, `testARevokeUtteranceWithdrawsThroughTheGateAndEndsTheTurn`, `testNoCachedRouteSurvivesRevocation` |
| Voice state query answered truthfully from the current decision | `.stateQuery` @6054–6063 — keys read from `currentDecision().allowsEgress` | `testAStateQueryIsAnsweredTruthfullyFromTheGateInBothStates` |
| Existing keyword rules unchanged (pinned); no model involvement in the new rules | KeywordIntentRule section @1021–1146 outside the `Domain` table; router block @1831 | the 9 extended KeywordIntentRuleTests incl. `testTheCloudFamilyNeverClaimsAnUtteranceAnExistingRuleClaims`; `testTheVoiceControlsNeverConsultAnInterpreter` (NullCommandInterpreter end-to-end) |
| No new app permission, no Info.plist change | `git status`: no Info.plist entry, no entitlement change; indicator imports Foundation + SwiftUI only | `testTheSurfaceHostIsMountedAndTheIndicatorFileStaysClean` (hygiene scan) |
| No content or identity in any event or log line; scoped unit suites green | Emitter @2085 (`metadata: [:]`, classification only); no new console writes | `testTheRevokeTurnEmitsOnlyTheClassificationAndNoContent`, `testTheCoordinatorOwnsTheWriterAndTheRouterOnlyReports`; suites green = the amendment-4 wave-close consolidated run (compile gate green now) |

## Test results (exact commands)

1. **Compile gate, run 1** (log `/tmp/t177-build.log`):
   `cd <worktree>/ios && ./build.sh generate && xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedDataTests -skipMacroValidation -skipPackagePluginValidation`
   → `EXIT=65`. The app target compiled clean (all production edits) and the test target
   produced exactly ONE true Swift error, in this unit's new test file:
   `CloudChatIndicatorAndRevocationTests.swift:112:40: error: 'InMemoryProfilePayloadStorage' is inaccessible due to 'private' protection level`.
   Fixed by giving the new file its own file-scope private double
   (`CNR177InMemoryProfilePayloadStorage`, the DialogueCoordinatorWiringTests:888-911 shape);
   the sibling suites each carry their own private copy — the house pattern.
2. **Compile gate, run 2** (log `/tmp/t177-build2.log`) — the same command →
   `** TEST BUILD SUCCEEDED **`, `EXIT=0`, zero `error:` lines. Both authored test files
   (`CloudChatIndicatorAndRevocationTests.swift`, the extended `KeywordIntentRuleTests.swift`)
   compiled as part of the test target; no production file errored in either run.
3. **`./build.sh generate`** ran green before both runs; it is what produced the pbxproj diff
   in section 9 (exactly the two new files registered).
4. **Amendment 4 — no suite executed by this unit.** The wave-close consolidated scoped pass
   must include at least: `CloudChatIndicatorAndRevocationTests`, `KeywordIntentRuleTests`
   (extended pins), `CommandRouterTests` and `CommandRouterKeywordIntentTests` (the touched
   router file), `IntentRouterChatRoutingTests`, `ReplyGrammarFlagResolutionTests` (the seam
   this unit fills), `CloudChatConsentPromptTests` (the prompt this unit drives).
   (The wave-close pass ran on 2026-10-15 — 13 classes / 325 tests, 12 classes green, 21
   failures all in this unit's two suites; both fixed and re-verified. See "Wave-close
   rework" at the end.)
5. **Hygiene evidence.** `git status` shows the declared files + the one documented deviation +
   the expected pbxproj diff + the two new files; no Info.plist, no permission/entitlement
   change, no content added to any event or console write. The in-worktree
   `tools/train-intent/**` and `specs/T-180-notes.md` changes belong to a parallel unit and
   were not touched by this unit.

## Decisions and deviations

1. **`CommandRouter.swift` — the one declared-files deviation (scope).** The voice rule must
   END the turn before the interpreter and the capture must reach the coordinator through the
   router's confirmation path; neither is possible from the coordinator alone, and the
   `Domain` table (inside this file) was deliberately NOT widened (that would change the
   router's exhaustive switch and risk reshaping existing claims). The delta is six hunks,
   +100/−0, additive only; the router keeps reporting, never writing (pinned by
   `testTheCoordinatorOwnsTheWriterAndTheRouterOnlyReports`). Needs the coordinator's
   acknowledgement at the wave gate.
2. **Settings toggle-ON is an explicit grant**, not a reset: the gate records `granted: true`,
   which is how a withdrawn record returns to "not decided" without a reset; toggle-OFF is
   `revoke()` itself. Both go through the ONE writer (T-172's key), and the row reads back
   the gate's current decision on every render instead of mirroring state.
3. **Settings writes are silent** — like every other Settings control. The feedback is the
   surfaces: the badge stops appearing (or resumes), and the next chat turn routes
   accordingly. No re-ask on the Settings path; the consent question belongs to chat turns.
4. **Voice revoke is immediate — the `cloud.chat.revoke.title` / `.body` catalogue keys stay
   unused.** Those T-171 keys exist (Localizable.xcstrings:4004/4038) but no Swift code
   references them: a confirmation dialog between the elder and a withdrawal they asked for
   was rejected. The spoken line that follows (`cloud.chat.revoke.done`) is the truth of the
   state either way (landed, failed, or repeat revoke), and the Settings row is the
   reversible second path. If the design intended a dialog, the change is coordinator-only.
5. **Notice timing and overlap.** The notice is committed at the attempt begin, before the
   network call is awaited (the `speakPreAck` discipline) — the elder hears it DURING the
   wait, and the reply, committed later on the router's own lane, is never delayed by it. If
   the answer arrives mid-notice, the reply takes the speaker through the existing cancel
   discipline — the same behaviour the news/pre-ack path ships today. The alternative (speak
   the notice only when the reply is ready) would serialize notice + reply and delay the
   answer; rejected.
6. **The empty `answerPendingTurnLocally` seam is a declaration, not a stub.**
   `consentNeedDetected(answerPendingTurnLocally: {})` — the call happens INSIDE the routing
   evaluation, before the lane has chosen its branch, and the lane's `.local` arm answers the
   turn on-device through its own path; running anything in the closure would serve the turn
   twice. The turn's answer is owned one frame below, by the lane (recorded verbatim in the
   coordinator's doc comment).
7. **A lapsed capture re-offers instead of expiring.** T-176's contract: the capture's window
   can lapse unanswered — that lapses the WINDOW, never the QUESTION. The timeout handler
   reads the pended-consent flag before its clears and replaces the generic line with a
   re-offer; the medication-flavoured "I didn't hear an answer" line would speak about a
   request that is still live.
8. **A revoke phrase during another pending yes/no gets the router's ambiguous re-prompt
   first.** The confirmation block runs earlier in `route()` and owns the turn while any
   confirmation (call, navigation, calendar, launch, consent question) is pended; the phrase
   is not a yes/no, so it re-prompts and is claimed by the keyword stage as soon as the other
   flow resolves. While the CONSENT question itself is up, "no" is the denial path (no
   egress) — the question and the revoke phrase are both answerable, the phrase after.
   Accepted precedence; matches the router's own documented ordering.
9. **No `syncServiceLocales` edit.** The prompt's locale is re-applied on every access
   (`updateLocale(activeLocale)` in the factory), so a language change re-resolves every
   string the question and its sheet show with no new locale-sync call site.
10. **A failed grant keeps the question and re-offers the spoken answer.** The elder's retry
    is never more than saying yes again; the capture stays pended and the 45 s window re-arms
    (`cloudChatCloseConsentCaptureIfResolved`: still presented → re-offer). The WRITE-failure
    branch itself belongs to T-176 (`grant()` leaves the question up on a failed write) and is
    pinned in its own suite (`CloudChatConsentPromptTests`, in the wave-close scoped list).
    This unit pins the answer path end-to-end and reads the state line from the gate AFTER the
    write, so a failure can never be spoken as success. Honest record: the coordinator-side
    re-offer on a still-presented failed grant is a branch no authored test of this unit
    exercises directly (the injected storage is healthy); it is covered at the prompt layer by
    T-176's failure tests and is called out here for the wave gate.
11. **The badge carries classification only.** Zero format slots, no content, no identity, no
    count — both languages pinned. The Settings row's note is the visible disclosure; the
    badge is the activity truth.
12. **`openWindowCountForTesting`** is an internal accessor added alongside `openWindowCount`
    for the register tests; it exposes a count, not state.
13. **Honest limitation.** The notice's audibility and the badge's on-screen rendering need a
    real speaker/UI, which the test host cannot provide (`start()` is unavailable there —
    BGTaskScheduler throws a platform exception). They are pinned at call-site + catalogue
    level; the audible/visible check is the device validation owed to T-185/T-186/T-187.
14. **AppCoordinator ownership for the P0 window.** The task file records this unit as the
    coordinator-file owner for the P0 window and T-184 as a later re-toucher (catalog default
    resolution). The lane seam and the responder were built to be re-read, not re-wired, so
    T-184's swap lands inside `CloudChatRouting`/responder construction without touching this
    unit's surfaces.

## Open items

- **T-184** (blocks on this unit): the v17 catalog entry and gated swap — the default
  resolution re-touches `AppCoordinator.swift`; the responder/lane construction it changes is
  `@ 4166`'s block, which this unit kept single-instance and re-readable.
- **T-185**: release-log gate — add this unit's emission site (`cloud_chat_voice_control` in
  `CommandRouter.swift`) and the indicator file to the gate's feature roots and re-gate
  against the allow-list (the payload is already allow-list-clean and pinned by test);
  device validation of the badge and the notice.
- **T-186**: the end-to-end acceptance + scoped sweep — the amendment-4 consolidated scoped
  suite run (list in Test results 4) plus the Gherkin scenarios on device where the unit
  process cannot assert (notice audible exactly once, badge visible for the whole window and
  gone for local turns, revocation heard and effective on the next turn).
- **T-187**: DV items — on Anzaan: first-cloud-turn notice once per session in Nepali; badge
  present/gone across turns; voice revoke and state query in both languages; Settings row
  flip and read-back; the consent question's spoken yes/no.
- **Wave gate**: acknowledge the `CommandRouter.swift` deviation (Decision 1) and keep the
  generate-produced pbxproj diff in place (per the brief).

## Wave-close rework (2026-10-15)

The coordinator's consolidated wave-close scoped pass (13 classes, 325 tests, run on a quiet
tree after T-180 completed) came back with **21 failures, all of them in this unit's two
suites**; the other 12 classes were green. Two independent root causes, one test-side and one
impl-side. Both fixed in this unit; the two classes re-verified green twice and the compile
gate re-run.

### Root cause A (test-side) — consent-state pollution in `CloudChatIndicatorAndRevocationTests`

The suite's isolation was built on the assumption that a fresh `AppCoordinator` starts with a
clean consent record. It does not: the coordinator's init builds `let storage =
MigratingEncryptedStorage()` and the gate is constructed on
`LiveTranslateCipherStorage(wrapping: storage)` — the REAL container. The injected
`profileStorage:` argument only backs the profile store (`profileStorage ?? storage`), so the
in-memory profile double gave no isolation for the consent record at all. A grant written by
one test leaked into every later-constructed gate in the process, and 17 assertions across 4
tests were order-dependent (they passed individually; the consolidated pass, with a
different execution order after the class list changed, caught it).

Evidence read before fixing: init's `MigratingEncryptedStorage()` + gate construction (notes
section 2, `@ 2894`); `LiveTranslateCipherStorage.delete(key:)` forwards `wrapped.delete(key:)`
unchanged; `MigratingEncryptedStorage.delete(key:)` routes by key (the keychain copy first,
then the file store); `StoragePlacementPolicy.migratesToFile` — `plugin.cloud_chat.consent.v1`
is NOT keychain-resident, so the record lives in the encrypted file store. The record is
process-external state; every test that constructs a new coordinator is a fresh-install
scenario.

Fix, minimal and test-side only (no coordinator init-signature change — the coordinator's
standing instruction):

- an **Isolation section** with `setUp`/`tearDown` purging via `_ =
  MigratingEncryptedStorage().delete(key: CloudChatConsentGate.storageKey)` — the house
  pattern (`AppCoordinatorSpotifyWiringTests:158`: "cleared through the app's own encrypted
  channel — never around the storage under test");
- a **clean-store guard** in `presentTheQuestion`: the gate must read `.notRecorded` at the
  question's start, or the test fails at the cause instead of at a downstream symptom;
- `makeFreshCoordinator()` (purge, then `makeCoordinator()`) for the **multi-leg tests** —
  `testTheSheetAnswersWriteThroughTheSameGateWriter` (legs: allow / not-now / untouched) and
  `testTheConsentAnswerRidesTheExistingYesNoCaptureAndIsNotAMedicationAck` (legs: yes / no).
  A later leg follows the previous leg's real write, so it purges explicitly. (Rework run 1
  proved this was needed: those two tests still failed on the guard after the setUp purge —
  all other tests were green in run 1.)

### Root cause B (impl-side) — the revoke family returned nil for 4 of 14 authored utterances

`KeywordIntentRuleTests.testTheRevokeFamilyResolvesEveryAuthoredUtteranceDataDriven` failed on
the contract's own utterances. The contract pairs a bare stem with the honorific form:
"बन्द गर" ⊃ "बन्द गर्नुहोस्"; "रोक" ⊃ "रोक्नुहोस्"; and "इन्टरनेट नपठाउ" ⊃ "…नपठाऊ". A
Devanagari virama conjunct has no Character boundary: the stem's final consonant is absorbed
into the honorific's cluster ("गर"+"्नुहोस्" forms the single grapheme "गर्नुहोस्"), so
Character-level `text.contains(phrase)` fails for "बन्द गर", "रोक", "नपठाउ" even though the
utterance plainly contains them. The fourth miss is the उ/ऊ spelling variant "नपठाऊ".

Fix, scoped to this family: `cloudChatPhraseContained` compares Unicode scalars (scalar-level
containment sees through the cluster), `cloudChatMatches` switches `.token` (unchanged,
whole-token) vs `.phrase` (scalar), and the [CLOUD-CHAT] resolver uses it — the shared
`Alternative`/`firstMatchingKey` semantics are untouched, so the house pin (Search's
Character-cluster behaviour stays as-is) is respected; no other suite's fixture touches these
phrases. Also added `.phrase("नपठाऊ")` to the stop group beside `.phrase("नपठाउ")`. Variant
order (revoke before state), canonicalization and the negative pins are unchanged and green.

### Class-run verdicts (exact commands)

Scope note: per the coordinator's protocol, ONLY these two classes were run (never the other
classes, never the full bundle); the compile gate was re-run because a production Swift file
changed.

1. **Rework run 1** — `cd <worktree>/ios && ./build.sh test:unit
   CloudChatIndicatorAndRevocationTests KeywordIntentRuleTests`
   (log `/tmp/t177-rework-run1.log`): `EXIT=65`, `** TEST FAILED **`, 88 tests, 2 failures.
   `KeywordIntentRuleTests` 63/63 passed (**root cause B verified fixed**). The 2 failures were
   `testTheSheetAnswersWriteThroughTheSameGateWriter()` and
   `testTheConsentAnswerRidesTheExistingYesNoCaptureAndIsNotAMedicationAck()` — both
   multi-leg tests tripping the (correct) clean-store guard on their second/third coordinator;
   fixed with `makeFreshCoordinator()`.
2. **Rework run 2 (cold — starting from the store the failed run left)** — the same command
   (log `/tmp/t177-rework-run2.log`): `EXIT=0`, 88 tests executed, 0 failures,
   `** TEST SUCCEEDED **` (`KeywordIntentRuleTests` 63, `CloudChatIndicatorAndRevocationTests`
   25); `✓ unit tests passed`.
3. **Rework run 3 (the same command again — warm isolation proof)** (log
   `/tmp/t177-rework-run3.log`): `EXIT=0`, 88 tests executed, 0 failures,
   `** TEST SUCCEEDED **`. Isolation holds cold and warm.
4. **Compile gate after the production edit** — `./build.sh generate` (no new files; pbxproj
   diff unchanged at +8/−0 — exactly the two base T-177 files) then
   `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination
   'generic/platform=iOS Simulator' -derivedDataPath build/DerivedDataTests -skipMacroValidation
   -skipPackagePluginValidation` (log `/tmp/t177-rework-gate.log`): `EXIT=0`,
   `** TEST BUILD SUCCEEDED **`.

### Files changed by the rework

- `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift` (declared; +188/−0 total now) —
  the family-scoped scalar matcher and the नपठाऊ variant (root cause B).
- `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatIndicatorAndRevocationTests.swift`
  (declared; now 1032 lines) — the isolation section, the clean-store guard, the multi-leg
  helper (root cause A).
- Nothing else: no coordinator change, no init-signature change, no commits, no pushes; HEAD
  still `5367b539`; `tools/train-intent/**` and `specs/T-180-notes.md` untouched.

### Notes corrections carried by this section

- The status line and Test results item 4 now record that the wave-close pass ran and its
  failures were all in this unit's suites (above), superseding the "not executed here" note as
  the final state of record.
- Decision 10's honest record stands unchanged (the failed-grant re-offer branch belongs to
  T-176's layer).
