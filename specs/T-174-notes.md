# T-174 — Guard flag resolution at the dispatch seam (implement notes)

**Status: implemented, scoped suite green (21/21), regression set green (182/182).**
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). Declared files only
(`CommandRouter.swift` modified, `ReplyGrammarFlagResolutionTests.swift` new — verified by
`git status`). No commits, no pushes, no `ai-sdd` mutating commands. No AppCoordinator edits;
the T-177 wiring point is the injected `ChatGuardSeam` closure.

## What was built

### 1. `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` (declared, +376/−21, 8 hunks)

| Hunk | What |
|---|---|
| `@ 609` | `ChatGuardSeam` — the injected seam (before the class): `servingPath: () -> ServingPath` (default `.onDevice`), `cloudAllowed: () -> Bool` (default `false` — dormant), `respondToChat: ((String, @escaping (InterpretedCommand?) -> Void) -> Void)?` (default nil — no lane). `ServingPath: String { onDevice, cloud }`. The definitional default keeps every pre-existing construction site and router test byte-identical. |
| `@ 835` | Router properties: `private let chatGuard: ChatGuardSeam`; `private var chatEscalationInFlight = false` (turn-scoped hold for the escalation hop). |
| `@ 878/891` | Init: `chatGuard: ChatGuardSeam = ChatGuardSeam()` appended after `turnTracer`; assigned. |
| `@ 1946` | Interpreter dispatch completion tail: `if chatEscalationInFlight { chatEscalationInFlight = false } else { resolveTurnReplyPending(); turnTracer?.endTurn() }` — a flagged turn's hold survives the dispatch tail; the hop's completion resolves (or the hold is cleared by a completion-less tail so a never-arriving hop cannot defer the NEXT turn). |
| `@ 4511` | `dispatchInterpreted` entry resets `chatEscalationInFlight = false` (fresh turn, no stale hold). |
| `@ 4629` | `.chat` case (after the unchanged confidence floor): `deliverGuardedChatReply(command.reply, transcript: raw)` replaces the direct `deliverModelReply` call. `raw` is the same turn's transcript, in scope precisely for the escalation. |
| `@ 4659` | `deliverModelReply` refactored to delegate to `private func polishedModelReply(_:) -> String?` — sanity gate → **the single** `SpokenReplyPolisher.polish(` call site → nil when rejected/empty. `deliverModelReply`'s behaviour is unchanged byte-for-byte; the extraction exists so the chat path computes its candidate and runs the guard over it WITHOUT duplicating the polish site (design-l1 §7.1). |
| `@ 4659+` | The guard-resolution block (`// MARK: - [CNR T-174] Guard flag resolution`): `deliverGuardedChatReply`, `resolveFlaggedChatReply`, `finishChatGuardEscalation`, `speakChatSafeTemplate`, `emitChatGuardEvent`. |

Behaviour, exhaustively (all tested):

- **Gate order**: sanity gate → polish → guard verdict → speak. A sanity-rejected (or
  empty-after-polish) candidate is answered with the existing honest line
  (`router.modelReplyUnclear`) and emits **no** guard event — nothing was deliverable, so
  there was nothing to verify (the rejection is already observable as
  `llama_response_rejected_sanity`).
- **`.pass`** → the polished text is spoken byte-identically (carded + spoken exactly as at
  HEAD); event `notApplicable`, classes `""`, count `"0"`.
- **`.flag(classes)`** → the flagged text is never spoken on any path:
  - escalate **once** iff the flagged reply came from the local shape
    (`path == .onDevice`) AND `cloudAllowed()` AND a `respondToChat` lane is wired; the
    escalation carries the same turn's transcript; `markTurnReplyPending()` goes up before
    the call, so the pipeline's idle hold is armed across the hop;
  - the hop's completion runs the reply through the **same guard**: verify pass → speak the
    cloud reply (`escalated`, original classes); re-flag → safe template keyed by the
    escalated reply's classes (`safeTemplate`); `unavailable` → speak + `degraded`, empty
    classes; nil / non-`.chat` shape / sanity-rejected reply → safe template with the
    original classes. Exactly one attempt; a second completion from a wiring that violates
    the responder's exactly-once contract is dropped by a once-guard;
  - a flagged **cloud** reply (or local routing denying cloud, or no lane wired) →
    **safe template only** (design §7.3's documented asymmetry: escalating a cloud reply
    back to the same cloud would repeat the failure).
  - The template resolves only through T-171's catalogue API:
    `L10n.safeTemplate(forCheckClasses: classes.map(\.rawValue))` → `L10n.safeTemplate(_:locale:)`.
    No copy in code (pinned by source scan). An empty resolution (unreachable with the
    shipped catalogue, which `L10nCatalogCoverageTests` pins) answers with
    `router.modelReplyUnclear` — never silence, never the flagged text (the one uncovered
    defensive branch; recorded below).
- **`.unavailable`** → today's behaviour stands (the polished text is spoken — a guard that
  is not running must never block or replace speech) + event `degraded`. Never reported as
  verified.
- **The turn is always answered** on every path; the hop's completion resolves the
  reply-pending hold and ends the turn (mirroring the interpreter tail), so the reply's
  speech-start hop precedes the pipeline's deferred idle hop.
- **`.query`/`.none` and every other action are untouched** (the guard wraps exactly the
  `.chat` case).

The frozen event (design-l1 §7.5 mapped onto the shipped bus vocabulary — see Decisions):

```
component: "command_router", eventType: "reply_grammar_flag"
outcome:  notApplicable | escalated | safeTemplate | degraded
metadata: ["origin": "onDevice"|"cloud",            // design's `path`
           "reason": "<space-joined GrammarCheckClass raw values>" ("" when nothing flagged),
           "count":  "0"|"1"]                       // escalation attempts
```

No transcript, no reply text, no identity/health/contacts/profile/key material; no console
write; timestamps come from the channel's own stamp.

### 2. `ios/ElderlyAssistantTests/Services/Voice/ReplyGrammarFlagResolutionTests.swift` (declared, new)

21 tests. The guard under test is T-169's real shipped entry point (not a double), so every
verdict comes from executing the real check rules; injected are only the seam's provenance /
routing / lane (`ChatGuardSeam`), the speaker, the observability bus, the coordinator stub
and a scripted interpreter.

| Gherkin scenario / DoD item | Test(s) |
|---|---|
| Fixtures really exercise the intended branches | `testTheFixturesExerciseTheIntendedGuardBranches` (verdicts pinned against the live guard; a fixture that drifts fails here naming the branch) |
| Pass speaks byte-identically + notApplicable | `testAPassSpeaksThePolishedTextByteIdenticallyWithNotApplicable` (exact spoken sequence `[ack, reply]`, card text, event payload) |
| Verdict over the polished text, not the raw candidate | `testTheVerdictIsComputedOverThePolishedTextNotTheRawCandidate` (5-sentence fixture flags raw at sentence 5, trims to 4 sentences before the guard → pass; asserts the exact trimmed text) |
| Sanity rejection answered without a guard event | `testASanityRejectedCandidateIsAnsweredWithoutAGuardEvent` (the shipped JSON-remnant fixture) |
| Flag → escalate once, same turn's transcript, re-guard the reply | `testAFlaggedLocalReplyEscalatesOnceForTheSameTurnTranscript` (one call, transcript recorded, flagged text absent from the whole sequence, hold armed mid-hop, one `escalated` event, hold resolved, count `"1"`) |
| Re-flagged escalation reply → template | `testAReFlaggedEscalationReplyStopsAtTheSafeTemplate` (first-known-class selection, escalated reply's classes in the event) |
| Failed/timeout escalation → template (one attempt) | `testAFailedEscalationStopsAtTheSafeTemplateWithTheOriginalFlag` |
| Non-`.chat` escalation result never executes | `testANonChatEscalationReplyIsNeverExecutedAndFallsToTheTemplate` (no `command_llm_query`, no dispatch) |
| Second completion cannot produce a second reply | `testASecondCompletionCannotProduceASecondReply` |
| Flag + local routing / no lane → template | `testAFlaggedReplyWithLocalRoutingSpeaksTheSafeTemplate`, `testAFlaggedReplyWithoutACloudLaneSpeaksTheSafeTemplate` |
| Flagged cloud reply → template only | `testAFlaggedCloudReplyTakesTheSafeTemplatePathOnly` |
| Unavailable keeps today's behaviour + degraded, never verified | `testGuardUnavailableKeepsTodaysBehaviourAndRecordsDegraded` (en-US session), `testARomanizedReplyDegradesRatherThanPassingOrFlagging` |
| Floor still first | `testASubFloorChatReplyNeverReachesTheGuard` (no guard event at all) |
| Commands untouched | `testCommandRepliesAreUntouchedByTheGuardCase` (`.query` and `.none` with a reply that would flag; spoken byte-identically, no guard event) |
| Event carries only permitted fields, no content | `testEveryOutcomeEmitsTheExactPermittedPayloadWithNoContent` (all four outcomes through real paths; exact key set; every key in `LogSanitiser.allowedKeys`; no transcript/reply value; origin/class/count values in closed vocabularies), `testTheSanitiserDropsNothingFromTheFlagEvent` (the sanitising bus rewrites nothing — fail-closed would silently drop an unlisted key) |
| Content-free/non-blocking by construction | `testTheEmissionSiteIsContentFreeByConstruction` (comment-stripped emitter body scanned: no transcript/reply/text/contact/profile/health token can appear — "reply_grammar_flag" cannot match `\breply\b`; no `print(`/`NSLog`/`os_log`/`debugPrint`/`String(describing:)`/`localizedDescription`; the three frozen keys present), `testTheGuardRunsOverThePolishedCandidateAtTheSinglePolishCallSite` (order gate→verdict→speak; exactly one `SpokenReplyPolisher.polish(` in the router, inside `polishedModelReply`), `testTheFlaggedResolutionNeverSpeaksTheFlaggedTextByConstruction` (the `.flag` branch speaks nothing; templates only via the catalogue API; no Devanagari literal in the resolution region) |

## Test results (exact commands)

1. **New suite** — `cd <worktree>/ios && ./build.sh test:unit ReplyGrammarFlagResolutionTests`
   → exit 0, `Executed 21 tests, with 0 failures (0 unexpected) in 1.448 (1.471) seconds`,
   `** TEST SUCCEEDED **`, `=== Scoped unit run passed (baseline not advanced) ===`.
   xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_22-18-10-+1100.xcresult`.
   - Honesty record — earlier run of the same suite (22-15-05): 21 tests, **4 failed**
     (`testARomanizedReplyDegrades…`, `testCommandRepliesAreUntouchedByTheGuardCase`,
     `testEveryOutcomeEmits…` (3 of 4 events), `testGuardUnavailableKeepsTodaysBehaviour…`).
     All four were the same test-fixture defect, not a code defect: the transcripts
     `"namaste"`, `"आज मौसम कस्तो छ?"`, `"hello"` are intercepted by earlier keyword-intent
     stages (greeting/weather), so the stub interpreter — and therefore the dispatch seam —
     was never reached. Fixed by using the interpreter-reaching transcript `"के छ खबर?"`
     everywhere (the fixture under test is the REPLY's script/language, not the
     transcript's). Re-run green with the same production code.
   - Two runs before that were blocked by a sibling unit's in-flight compile error
     (`CloudChatConsentPromptTests.swift`, `@Published` misuse in the shared test target —
     not this unit's file). Waited for the sibling's fix and for its xcodebuild to exit,
     then retried; no DerivedData deletion, no `clean`.
2. **Regression set + sanctioned L10n cross-check** (one invocation) —
   `./build.sh test:unit ChatConfidenceFloorTests ChatResponseShapeTests ChatSamplingTests IntentRouterChatRoutingTests LlamaCommandInterpreterTests CommandRouterTests CommandRouterReplySafetyTests L10nCatalogCoverageTests`
   → exit 0, `Executed 182 tests, with 0 failures (0 unexpected) in 15.133 (15.280) seconds`,
   `** TEST SUCCEEDED **`. Per-class (from the xcresult): ChatConfidenceFloorTests 10/10,
   ChatResponseShapeTests 19/19, ChatSamplingTests 20/20, CommandRouterReplySafetyTests 18/18,
   CommandRouterTests 38/38, IntentRouterChatRoutingTests 6/6, **L10nCatalogCoverageTests
   39/39**, LlamaCommandInterpreterTests 32/32. xcresult:
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_22-19-27-+1100.xcresult`.
3. **House gates** (run by `build.sh` inside both invocations, both green each time):
   release-log safety — `✓ no transcript content or raw error object can be printed in a
   non-Debug configuration, and the live-camera-translation sources carry no console write or
   content-bearing event field` (24 fixtures over 12 rules, each positive/negative pair
   behaving); prompt mirror — `✓ the seed mirrors IntentPrompt.build byte-for-byte
   (2717 bytes, 4 placeholders)` with all drift self-tests rejecting.
4. The 21/21 run's own log shows the ordering pin executing live:
   `speak() … text="नमस्ते हजुर। तपाईंलाई कस्तो छ? म ठीक छु। आज घाम लाग्छ।"` — the 5-sentence
   candidate spoken in its 4-sentence trimmed form.

## Decisions and deviations

1. **Event field mapping (design names → shipped bus vocabulary).** `LogSanitiser.allowedKeys`
   is the shipped authority for what a metadata key may be, and `LogSanitiser.swift` is NOT a
   declared file for this unit — so the design's field set was mapped onto allow-listed keys
   rather than widening the sanitiser: `path` → `origin`, `check` → `reason` (space-joined
   `GrammarCheckClass` raw values; empty when nothing flagged — pass and degraded both),
   outcome → the top-level `outcome`, counters → `count`, timestamps → the channel's own
   stamp (the console bus already prints `[HH:mm:ss.SSS]`; duplicating it would be a second
   clock). The suite pins the exact key set AND that `sanitise()` drops nothing. If the
   design's literal key names are wanted, the change is a LogSanitiser allow-list edit owned
   by a unit that declares it (T-185 re-gates this site; recorded for the wave gate).
2. **Provenance is injected, not derived.** `InterpretedCommand` carries no
   "which lane produced this", and today's only chat producer is the local ladder — so the
   seam carries `servingPath` (default `.onDevice`, today's truth) and the cloud lane becomes
   visible to the guard when T-175/T-177 classify it. The `.cloud` path is fully exercised
   by the suite through the same injection. The router cannot silently mis-attribute a lane
   it was not told about; the tension (design §7.3 presumes path knowledge the command type
   does not carry) is recorded rather than guessed.
3. **`unavailable` for every reason → `degraded`** (including `localeNotNepali`). The
   alternative considered was `notApplicable` for non-Nepali sessions (a guard correctly
   declining a register it does not police). Rejected: §7.4's single sentence — a guard that
   is not running is visible rather than silently absent, and an unverified reply is never
   reported as if verified — reads uniformly; the event still carries the serving path, so
   the English-session rate is separable in analysis. Recorded as the deliberate reading.
4. **The `escalated` event records the ORIGINAL flag's classes**, the `safeTemplate` event
   the classes that flagged NOW (the escalated reply's, when it re-flagged). `origin` is
   always the FLAGGED reply's serving path — the flag the event is about — not the hop's
   destination. `count` is the escalation-attempt count (0 when no hop was issued, 1 when
   one was), making §14's one-attempt rule visible in the event itself.
5. **No copy in code** — the resolution region contains no Devanagari literal (pinned by
   source scan); templates resolve only via T-171's catalogue API. The L10n cross-check
   (39/39) additionally verifies CommandRouter.swift — a file in T-171's hardcoded-copy
   sweep probe set — introduces no duplicate of any catalogue value.
6. **The escalation issues the cloud chat call with the turn's transcript only** — context
   assembly lives in the wiring closure (T-177's `respondToChat`), so no second context
   constructor was created here.
7. **Hold model and its bound.** `chatEscalationInFlight` defers the dispatch tail's
   resolve/endTurn across the hop; the hop's completion resolves. The flag is cleared at
   `dispatchInterpreted` entry and by the tail when no hop is in flight, so a never-arriving
   completion cannot defer the NEXT turn (the pipeline's 45 s hold remains the backstop for
   the hung hop, exactly as for a hung interpreter). Bound, recorded: an interleaved turn
   started while a stale hop is still in flight inherits the shipped single-token model —
   the same behaviour any straggling interpreter completion has today.
8. **The one uncovered branch** is the empty-template fallback in `speakChatSafeTemplate`
   (`router.modelReplyUnclear`): unreachable with the shipped catalogue, whose completeness
   `L10nCatalogCoverageTests` pins in both languages. Every other branch of every new
   function is executed by the 21-test suite.
9. **Pre-existing DEBUG console writes in CommandRouter.swift** (e.g. `[command_router][DEBUG]
   speak() called…` visible in the run logs) are not this unit's and were not touched; the
   new emission site carries none (pinned by source scan). CommandRouter.swift is not yet in
   the release-log gate's `FEATURE_ROOTS` — T-185 owns gating this site.
10. **Notes-only record of the notApplicable/escalation interplay**: escalation is never
   attempted for a flagged cloud reply even when the decision allows cloud (tested with
   egress allowed and a lane wired) — §7.3's asymmetry is deliberate.

## Open items

- **T-177 wiring**: fill `ChatGuardSeam` from the coordinator — `servingPath` from the lane
  that produced the reply, `cloudAllowed` from `CloudChatRouting.decide(...) == .cloud`
  (the consent gate's single egress chokepoint), `respondToChat` as the cloud chat call
  with the turn's context. Until then the seam is dormant (`.onDevice`, no egress, no lane)
  and the flagged path degrades honestly to the safe template.
- **T-185**: add `CommandRouter.swift` to the release-log gate's feature roots and re-gate
  the emission site against the allow-list (the event's keys are already allow-listed and
  pinned by this unit's tests).
- **Wave gate**: confirm the design's literal event field names vs the allow-listed mapping
  (decision 1) — a declarable change either way.
- **DV (T-186/T-187)**: on-device hearing check — a flagged turn on Anzaan must be heard as
  the safe template (or the verified cloud reply), never as the flagged text; the echo is
  not assertable in a unit process.
