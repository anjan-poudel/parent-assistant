# L2 Component Design — Multi-Turn Conversation (v1)

**Feature:** `multi-turn-conversation` · **Branch:** `feat/multi-turn-conversation` (worktree `elderly-ai-assistant-multi-turn-conversation`; requirements baseline `437d4dc`)
**Task:** `design-l2` (agent `sdd-principal-engineer`) · **Contract:** `component_design_l2` → `specs/design-l2.md`
**Date:** 2026-10-10 · **Status:** for `review-l2` (GO gate), `security-design-review` (SECURITY-GO gate), `plan-tasks` and `implement`
**Refines:** `specs/design-l1.md` (binding architecture) to implementation-grade component interfaces. Every ADR-MTC-01…ADR-MTC-16 decision is preserved; the refinements this document adds are itemised in §5, and the reconciliations it fixes in §6. It resolves the L1 §31 items R1–R12.

**Path convention (inherited from L1 §Path convention).** Paths are repo-relative. Where one path would exceed the release-log sanitiser's token limit (40 consecutive characters from the class `[A-Za-z0-9/+=]`), it is split across adjacent code spans; `` `ios/ElderlyAssistant/Services/` + `Voice/DialogueManager.swift` `` denotes the single path obtained by joining the spans with `/`. The split is a sanitiser convention only — do not read the `+` as concatenation in code.

**Identifier-break convention.** The same 40-character limit applies to any single identifier (including test names): where its text would form one run of 40 or more characters from the class above, it is broken across adjacent code spans at a point that keeps every span under the limit, and the spans join with no separator. Example: `` `testAnswerTurnNeverReachesThe` + `InterpreterOrCache` `` denotes the single test name formed by joining the spans directly. Every break of this kind in this document follows this convention.

**Sanitizer discipline.** This document contains no credential-shaped values, no token samples and no secret material of any kind. Every quoted utterance is a benign fixture from the requirements corpus (the owner's bhajan example and its variants). No auth surface is touched by this feature.

**Sources verified for this document.** Every interface below was written against the worktree source at this baseline, not against L1 prose alone: `CommandRouter.swift` (`route` open with `recordTranscript`; gibberish guard `:747-758`; emergency block `:779-783`; confirmation hook `:787-886` incl. rephrase follow-up `:794-809` and the call-override predicate `:816-820`; keyword stage `:1169-1266` with the news arm `:1194-1198`, the YouTube arm `:1218-1221`, the music arm `:1223-1234` and the appLaunch arm `:1256-1264`; rephrase band `:1504-1519`; interpreted `.music` `:3336-3355`; `routeKeywordRemainder` `:1968-2030`; speech lanes `:3819-3882`; `isYesResponse`/`isNoResponse` `:3801-3814`; phrase helpers `:1824-1840`; `emergencyPhrases` `:1854`; `sensitiveCallPhrases` `:1869`; `isExplicitMedicationAcknowledgement` `:1913`; `routeSafetyNet` `:1931`); `KeywordIntentRule.swift` (Domain/Match/match `:69-206`; Alternative/Group/Variant/Rule `:289-345`; rules table `:349`; `musicQuery` `:752-779`; drop sets and marker helpers `:787-851`); `VoiceContactSearchRoute.swift` (`decide` `:67`; `directCallPhrases`/`isDirectCallUtterance` `:117-140`); `YouTubeRoute.swift` (`Decision` `:41-56`); `VoiceSessionStateMachine.swift`; `AppCoordinator.swift` (watchdog `:4823-4883`; coordinator event component `:7327`; pending-rephrase seams `:7395-7406`); `LocalBrainChain.swift` (`InputSeam` `:109-115`; `turnInput` `:275-285`; `plainText` `:296-307`); `InputSanitiser.swift`; `IntentPrompt.swift`; `LlamaCommandInterpreter.swift` (`InterpreterContext` `:95-118`; `InterpretedCommand` `:122-229`); `ios/tools/` + `check-release-log-safety.py` (`FEATURE_ROOTS` `:141`, `RULES` `:187`); `check-prompt-mirror.py` (`INTERPOLATIONS` `:56-61`); and the test bundle under `ios/ElderlyAssistantTests/` (incl. `Services/Voice/` suites and `App/VoiceSessionStateMachineTests.swift`).

---

## Overview

### 1. Purpose

Today the voice pipeline is strictly single-turn; this feature adds a one-deep dialogue frame (L1 §1). This document fixes what `plan-tasks` turns into coding tasks and what `implement` builds: the exact Swift surfaces (types, initialisers, method signatures with access levels), the data shapes (the frame, the candidate, the extraction provenance, the catalog JSON), the capture ladder and merge as testable pure-function tables with input/output vectors, the exact edits each existing file receives (which function gains what, at which verified anchor), the interception block's concrete integration into `route()`, the `VoiceCommandCoordinating` additions with threading, the state-machine deltas with full signatures, the observability and release-gate deltas, the Phase 2 clause plumbing (defaulted so Phase 1 compiles and behaves byte-identically), the test seams per L1 §29 suite (file-private doubles, the `CommandRouterMusicTests` pattern), and a traceability matrix over all 32 requirements.

### 2. Inputs

- `specs/define-requirements.md` + `specs/multi-turn-conversation/` — FR-MTC-001…FR-MTC-020, NFR-MTC-001…NFR-MTC-012, 97 Gherkin scenarios (locked).
- `specs/design-l1.md` — binding architecture (ADR-MTC-01…16; §9 frame model; §10 interception; §11 capture/merge; §12 degenerate detection; §13 did-you-mean; §14 the window; §15 catalog; §16 degradation; §17 Phase 2; §20 config; §21 error taxonomy; §22 events/log-gate/localisation; §29 test suites; §31 open items).
- `specs/multi-turn-conversation/constitution.md` — Safety-Relevant Constraints 1–4, Feature Constraints 1–10, the DV gate, OD-M1..M4.
- `.ai-sdd/workflows/multi-turn-conversation.yaml` — the `review-l2` / `security-design-review` / `security-test` focus areas and exit conditions.
- `constitution.md` (root) — architecture constraints, standards, release gates, agent principles (explicit error types, configurable timeouts, explicit concurrency, no silent stubs).
- `docs/multi-turn-conversation-feasibility.md` — the owner's study (grounding; not a binding source where it disagrees with L1).

### 3. What this document resolves (the L1 §31 list)

| L1 item | Resolution |
|---|---|
| R1 barge-in predicate stage list — pin the exact call sites, add a test per stage | §6 R1 (the `B1`–`B7` table, rows at §6 lines 93-99); §12.1 protocol/access widenings; tests §18 rows `CommandRouterDialogueTests.` `B*` |
| R2 discard-path candidate composition | §6 R2; §5 L2-D9; §24 |
| R3 `candidateChoice` exhaustion reading | §6 R3; §5 L2-D17; §24 exhaustion table |
| R4 strip/marker rules as an ordered algorithm | §6 R4; §22 ordered algorithm with vectors |
| R5 escape / re-probe interaction | §6 R5; §5 L2-D4; §22 escape step |
| R10 `InterpretedCommand` reuse for `activeCommand` | §5 L2-D13; §9 listing of `merging(message:)`; §12.5 execution |
| R11 shared seam helper shape (`IntentTranscriptPreparation`) | §5 L2-D14; §12.5; §15 listing; parity tests §18 |
| R12 Phase 2 `frameClause` plumbing | §5 L2-D15; §19 C-MTC-12 (defaulted field + fifth interpolation + mirror/pin update list) |
| The L1 §29 test suites, made cuttable as units | §18 (per-suite file, doubles, test names) |
| Exact per-file edit list | §8–§19 (one section per component; the edit table §12.4 for the router) |
| Log-gate deltas (event names, metadata keys, allowedKeys, FEATURE_ROOTS) | §26 |
| The catalog JSON schema + loader API | §11 |

### 4. Cross-cutting conventions

**Error typing.** No new API returns an untyped error. `DialogueError` (§8) is the complete error vocabulary of the new types; the two throwing surfaces are `DialogueManager.arm(_:)` and `DialogueOptionCatalog.init(data:)` / `.load(bundle:)`. No `Error` existential crosses a component boundary. Errors are all `Equatable` so tests compare them directly.

**Timeouts are configuration.** The answer window is never a new literal: both the frame's deadline and the session timer derive from `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` (45 s; single source, L1 §20). `DialogueManager` receives the value by injection at construction; tests inject small values and a fake clock (`now` closure) to exercise boundaries without wall-clock waits.

**Concurrency (explicit).** The frame and the dialogue manager are main-queue-confined — the same contract as `VoiceSessionStateMachine` (all mutations on the main queue; router reads and writes travel the coordinator hooks; the coordinator hops to main exactly as `AppCoordinator.openConfirmationWindow()` does). Who reads: the router's `route()` on every utterance (one synchronous main-thread read), the coordinator's timeout task and confirmation funnels. Who writes: `startDialogueFrame` (arm), `noteDialogueAttempt` (attempt + deadline), `resolveDialogueFrame` / `clearDialogueFrame` (clear) — all coordinator-confined. Isolation mechanism: main-queue confinement only — no locks, no actors, no atomics. Conversations are serialised (the pipeline runs one utterance turn at a time), so the interception never races a second turn. Deregistration paths are first-class: every resolution clears the frame, cancels the timer, and closes the window through legal state edges; resolution is idempotent (a second resolution is a no-op on a cleared frame). The `DialogueOptionCatalog` is immutable after load and safe from any thread.

**Deterministic-first.** The Phase 1 answer turn consults no model, no network and no cache: classification, merge, candidate assembly and probe composition are pure functions over the frame, the prepared text and the catalog. This is the degradation guarantee of L1 §16 restated as an interface rule — nothing on the dialogue path can load a model or gate a safety stage.

**Template-only speech.** Every probe string is a `dialogue.*` xcstrings key composed by `DialogueProbeComposer` (§8); matching vocabularies (index words, escape, cancel, default-answer aliases, probe-echo words) are Swift input tables, never spoken and never model-generated. This restates Feature Constraint 2 at the interface level.

**No silent paths.** Every outcome of the interception block speaks exactly one line per turn through the existing lanes, or falls through to the ladder which speaks its own line. The one deliberate silence is the timeout (L1 ADR-MTC-08: the window expires silently).

### 5. L2 decision log (refinements of L1; each is implemented, tested and reviewable)

| ID | Decision | Rationale / pin |
|---|---|---|
| L2-D1 | **Barge-in is evaluated before the cancel/amendment split** (after the escape check). The ordered classifier is: deadline → length → escape → barge-in → cancel/amendment → answer. | L1 ADR-MTC-04 places cancel/amendment before barge-in. The counterexample: "होइन, मेरो छोरालाई फोन गर" (no, call my son) would reach the amendment branch first and merge call words as a music answer, silently defeating the direct-call and sensitive-call shields. The escape check still runs first (L1 is explicit that the escape phrase embeds a negation). Pinned by test `testNegationPlusStrongCommandBart` + `gesInNotMerges`. |
| L2-D2 | **Two barge-in vocabularies are widened `private` → `internal`** with extraction comments mirroring the `isExplicitMedicationAcknowledgement` precedent: `CommandRouter.sensitiveCallPhrases` and `VoiceContactSearchRoute.isDirectCallUtterance` (which keeps its lowercase-input contract; the caller passes canonical text). | A second call site now needs the exact same vocabulary — the same reason the F3 extraction exists. One table, never duplicated. |
| L2-D3 | **Cancel detection is LEADING-position** over a mirrored token table ({no, nope, wrong, छैन, होइन, होइनन्} from `isNoResponse` `:3809-3814`, plus the constitution's {रद्द, never mind, cancel}); the bare-whole-utterance case additionally accepts today's `isNoResponse` semantics. | `isNoResponse` matches anywhere in the utterance; under that reading "दुर्गा होइन" (not durga — a correction) would cancel the frame. Leading position keeps textured corrections as answers while "होइन" alone stays a cancel. Vector `V11` in §22. |
| L2-D4 | **The escape vocabulary is a Swift input table; probes do not advertise it.** `dialogue.escape` is the acknowledgement spoken after the user escapes, not an instruction in the probe. | L1 §22 defines only the ack key; the constitution's escape phrase is what the user says. R5 resolved: escape fully drops the frame, so no attempts reset exists or is needed. |
| L2-D5 | **The over-length check runs on the RAW answer** (`raw.count > InputSanitiser.maxLength` ⇒ invalid) before the sanitise + seam call. | `InputSanitiser.sanitise` CLAMPS at 200 Characters (verified: it truncates via `prefix`), and a truncated merge is forbidden (L1 §11). Checking raw length is the only way to distinguish "invalid over-length" from "valid short". |
| L2-D6 | **A re-probe refreshes the deadline** (one full window per probe; `attempts` persists on the same frame). The state machine gains `refreshSlotAnswerWindow()`; `DialogueManager.noteAttempt()` restamps the deadline. | L1 §9 "deadline: 45 s from probe speech" — a re-probe IS a probe speech. Total dialogue is bounded at 2 windows, well under any watchdog envelope (§27 backstops). Window rows in §27. |
| L2-D7 | **`DialogueFrame.attempts` and `deadline` are `var`; `arm` is the only deadline writer.** | The frame keeps one identity through a re-probe (§L2-D6); arm stamps `now + answerWindowSeconds`, resolution clears everything. |
| L2-D8 | **Capture-form taxonomy**: leading index token ⇒ `.indexWord`; whole-value alias match ⇒ `.optionName`; marker-dropped-variant alias match ⇒ `.repetition`; anything else non-empty ⇒ `.freeText`. | Makes all four FR-MTC-005 forms distinguishable from the value alone — no `sourceTranscript` comparison needed for classification (repetition means "repeated with its marker context", e.g. "दुर्गा भजन" vs bare "दुर्गा"). Vectors `V1`–`V8` in §22. |
| L2-D9 | **Free-form on a `candidateChoice` frame must be claimed by a candidate's own domain extractor** (music → `musicQuery`; YouTube → `YouTubeRoute.extractQuery`); the first claiming candidate in list order executes with the extracted value; no claim ⇒ invalid. | R2's bounded reading of "free-form always accepted": free text can only drive a domain that accepts free text; news/appLaunch candidates cannot be claimed, so nothing is fabricated and nothing executes unasked. |
| L2-D10 | **`DialogueCandidate.matchKeys` = the near-match's `matchedKeys`** (the user's own partial words, fixed rule vocabulary). Matching mirrors the repo's script-split idiom (`isMusicDropToken`): Devanagari keys match by containment ("युट्युबमा" ⊃ "युट्युब"), Latin keys whole-token only. | One vocabulary source (the rule's own keys); the pick by name is the user repeating their own words. |
| L2-D11 | **`DialogueCandidate` gains `appID: String?` and `matchKeys: [String]`** on top of L1 §9's fields. | `appID` is the launcher seam's payload (mirrors `KeywordIntentRule.Match.appID`); `matchKeys` is L2-D10. Defaults keep construction sites explicit. |
| L2-D12 | **The catalog's `groups` is an ordered ARRAY, not a dictionary**; group selection is `groupForMusicQuery` over each group's `matchKeys`, first match in file order; no group or an unloadable catalog ⇒ a free-text-only probe using `dialogue.probe.musicAny`, default still offered. Additionally the L1 §28 optional `dialogueOptionCatalog` protocol member is DROPPED. | Dictionary iteration order is not stable across lookups — first-match semantics need the array. The catalog is a static bundle resource with no coordinator state; the router owns one cached load (`private lazy`), so no protocol member is needed. |
| L2-D13 | **R10 — merged music command**: `activeCommand` is reused exactly as L1 §11 says (the query travels the free-text `message` entity). Execution of a slotFill answer with a non-nil `activeCommand` goes through `dispatchInterpreted(command.merging(message: value), raw: raw)` — byte-for-byte the interpreted route's own executor; with a nil `activeCommand` (the ladder-arm intake) it calls `fireMusicRequest(query: value)` directly — the ladder arm's own seam. Both converge on `fireMusicRequest`. | §9 lists `merging(message:)` on `InterpretedCommand` (memberwise-init copy; every other field preserved verbatim). This keeps NFR-MTC-012's parity claim structural: a merged answer executes through the same executor a fresh interpreted utterance uses. |
| L2-D14 | **R11 — the shared seam helper** is `IntentTranscriptPreparation.prepare(_:seam:)` in a new `Services/Intents/` file, returning `Prepared { raw, sanitised, prepared, pair }`; internal order sanitise → seam, identical to `LocalBrainChain.turnInput`; `LocalBrainChain` is rewired to call it. `LocalBrainChain.plainText(for:raw:)` is untouched. | One implementation, two callers. The dialogue path consumes `prepared` (= the seam's `pickerBrainInput` when a seam exists, else the sanitised text); the brain path keeps its raw-vs-picker equality mapping verbatim. Parity suite §18 rows `T*`. |
| L2-D15 | **R12 — the Phase 2 clause arrives as a defaulted `InterpreterContext.frameClause: String? = nil`**, rendered by `IntentPrompt.frameClause(_:)` into a fifth interpolation `{frame_clause}` inserted between the `User said:` line and the closing imperative. | The `addressAs` precedent (an explicit initialiser carrying a defaulted field, `LlamaCommandInterpreter.swift:110-117`) is the closest in-repo shape; every pre-feature construction site compiles unchanged and the Phase 1 prompt is byte-identical (the renderer returns the empty string for nil). §19 carries the atomic update list (seed, mirror anchors, digests, baseline). |
| L2-D16 | **`DialogueFrameResolution` gains `.emergency`** alongside L1 §9's nine outcomes; the emergency-clear emits `dialogue_frame_resolved {outcome: "emergency"}`. | Distinguishes the emergency side-effect clear from a barge-in and from a supersession in telemetry; the outcome vocabulary stays closed (§26). |
| L2-D17 | **Exhaustion (R3 confirmed)**: slotFill exhaustion executes the pending command with its default query through the same executor as an explicit default pick; `candidateChoice` exhaustion closes honestly with `dialogue.exhausted`. A bare cancel at any attempt count resolves as cancelled — the default never fires on a cancel. | L1 ADR-MTC-07 table, verbatim. Exhaustion table §24. |
| L2-D18 | **The safety shields act on the answer turn**: an answer classified as barge-in (med-ack, sensitive-call, direct-call, contact-search, YouTube-play, non-frame-domain keyword match) leaves the frame and falls through to the unaltered ladder, so an answer can never carry med-ack or sensitive vocabulary into the merge or into provider egress. | This is the security-relevant reading of L1 ADR-MTC-05 for the mid-frame answer path; the hostile corpus (§18) pins it. |

### 6. Reconciled readings and marked gaps

**R1 — barge-in stage list (pinned).** The predicate set, in order, with the exact call sites (each is the same pure decision its ladder stage uses; single source, no vocabulary duplication):

| # | Predicate (exact) | Call site / source | Interaction after barge-in |
|---|---|---|---|
| B1 | `CommandRouter.isExplicitMedicationAcknowledgement(text)` | `CommandRouter.swift:1913` (internal `static`; denials excluded inside) | falls through; the safety net `:897` acknowledges exactly as today |
| B2 | `CommandRouter.sensitiveCallPhrases` containment (widened internal, L2-D2) | `CommandRouter.swift:1869` + `containsPhrase` semantics `:1824` | falls through; `routeKeywordRemainder` `:1973-1980` blocks with `router.sensitiveBlocked` unchanged |
| B3 | `VoiceContactSearchRoute.isDirectCallUtterance(text)` (widened internal, L2-D2; lowercase-input contract) | `VoiceContactSearchRoute.swift:137-140` | falls through; the interpreter/direct-call path handles it (its normal confirmation runs — FR-MTC-012 scenario 1) |
| B4 | `VoiceContactSearchRoute.decide(transcript:)` returns `.openPhone` | `VoiceContactSearchRoute.swift:67` | falls through; the contact-search stage `:916` opens the Phone screen |
| B5 | `YouTubeRoute.decide(transcript:)` returns `.play` | `YouTubeRoute.swift:56` | falls through; the YouTube stage `:1164` plays |
| B6 | `KeywordIntentRule.match(transcript:medicationNames:)` resolves a domain ≠ `frame.domain` | `KeywordIntentRule.swift:164` | falls through; the keyword stage or interpreter executes it |
| B7 | (negative pin) a music-domain match mid-**music** frame is NOT a barge-in | FR-MTC-005 scenario 3 ("दुर्गा भजन बजाऊ" is an answer) | the classifier continues to the answer path |

The negative examples R1 named are covered: "मेरो छोरालाई फोन गर" hits B3 (and its normal confirmation runs afterwards); "औषधि खाएँ" hits B1; a repetition of the probe's own option hits nothing (B4's vetoes keep music-marked text out of the contact route, B6 excludes the frame's domain). Test rows in §18.

**R2 — discard-path candidate composition (final).** At the rephrase-discard branch (`CommandRouter.swift:806-809`): the denied hypothesis is re-offered **only when at least one near-match exists**, appended last; when it is the only possible candidate, no candidate frame opens and today's `router.rephrase.discard` line stands alone. This is the L1 ADR-MTC-07 reading, confirmed; the alternative "never re-offer" stays recorded for review-l2 (§31 R2 of L1).

**R3 — candidateChoice exhaustion (final).** Closes honestly with `dialogue.exhausted`; no execution. Confirmed per L1 ADR-MTC-07's table — executing an unasked candidate is the trap FR-MTC-004/FR-MTC-010 forbid. Reconfirmed at review-l2 against FR-MTC-007's literal wording (carried as risk 11 in the risks table for the reviewer).

**R4 — strip/marker rules (final, ordered).** §22 defines the ordered algorithm `S1`–`S6` with the vectors the requirements imply ("दुर्गा भजन" matches the दुर्गा option; "दशैं दुर्गा भजन" survives as free text; "गीत चलाऊ" is invalid, not a search).

**R5 — escape/re-probe (final).** The escape drops the frame entirely (`.escaped`), speaks the ack, and the turn ends; the next utterance is a fresh command or a fresh trigger. No attempts bookkeeping is involved.

**Marked gaps (not guessed).** (1) OD-M1..M4 stay owner-facing; this document implements the L1 defaults (2 probes; curated catalog; Phase 1 first; Phase 3 separate) as config/scope. (2) The exact ne/en copy in §16 is draft for the copy review; the keys, structure and join rules are the binding part. (3) The catalog's bhajan alias lists are draft match vocabulary — extendable without code by the data file alone. (4) The `DialogueOptionCatalog.json` resource name is pinned; its bundle placement matches the existing `Resources/` JSON precedent (`DialectLexicon.json`).

---

## Components

### 7. Component map

C-MTC-01…C-MTC-13 per L1 §27, at the file granularity this document pins. `NEW` = new file in the change set; `CHANGED` = existing file edited. State ownership and concurrency are stated per component.

| ID | Component | File(s) | State ownership | Concurrency |
|---|---|---|---|---|
| C-MTC-01 | `DialogueManager`, `DialogueFrame`, `DialogueCandidate`, `ProbeKind`, `DialogueSlot`, `DialogueFrameResolution`, `DialogueProbeComposer`, `DialogueConfig`, `DialogueError` | NEW `` `ios/ElderlyAssistant/Services/` + `Voice/DialogueManager.swift` `` | the one live frame | main-queue-confined; reads = router turn + coordinator; writes = coordinator only |
| C-MTC-02 | `DialogueAnswerPath`, `AnswerClassification`, `DialogueMerge`, `CaptureForm`, `MergeSource`, `InvalidAnswerReason`, vocab tables, `InterpretedCommand.merging(message:)` | NEW `` `ios/ElderlyAssistant/Services/` + `Voice/DialogueAnswerPath.swift` `` | none (pure statics) | stateless; callable from any thread |
| C-MTC-03 | `DialogueCandidateBuilder` | NEW `` `ios/ElderlyAssistant/Services/` + `Voice/DialogueCandidateBuilder.swift` `` | none (pure statics) | stateless |
| C-MTC-04 | `DialogueOptionCatalog`, `DialogueOptionGroup`, `DialogueOption` + the bundled resource | NEW `` `ios/ElderlyAssistant/Services/` + `Voice/DialogueOptionCatalog.swift` ``; NEW `` `ios/ElderlyAssistant/Resources/` + `DialogueOptionCatalog.json` `` | the loaded catalog (immutable) | immutable after load; safe from any thread |
| C-MTC-05 | Interception block, two didYouMean trigger edits, the degenerate trigger helper, the execution helpers, protocol members + extension defaults, the emergency clear | CHANGED `` `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` `` | per-turn locals only | main-thread turn (existing contract) |
| C-MTC-06 | `MusicQueryExtraction` + `musicQueryOutcome`, `nearMatches` + `NearMatch`, scaffold/marker accessors | CHANGED `` `ios/ElderlyAssistant/Services/` + `KeywordIntentRule.swift` `` | none (pure statics) | stateless |
| C-MTC-07 | `awaitingSlotAnswer`, `openSlotAnswerWindow`, `refreshSlotAnswerWindow`, `onSlotAnswerTimeout`, mirrored timer | CHANGED `` `ios/ElderlyAssistant/App/` + `VoiceSessionStateMachine.swift` `` | the session state + `slotAnswerTimer` | main-queue-confined (existing contract) |
| C-MTC-08 | `DialogueManager` ownership, conformance, timeout handler, confirmation coexistence funnel, `prepareDialogueAnswerText` | CHANGED `` `ios/ElderlyAssistant/App/` + `AppCoordinator.swift` `` | owns the manager + the timeout task | main-queue-confined; hops mirror `openConfirmationWindow()` |
| C-MTC-08b | `isDirectCallUtterance` widened private → internal | CHANGED `` `ios/ElderlyAssistant/Services/` + `Voice/VoiceContactSearchRoute.swift` `` | none | stateless |
| C-MTC-08c | `turnInput` rewired to the shared helper; seam accessor | CHANGED `` `ios/ElderlyAssistant/Services/` + `Intents/LocalBrainChain.swift` ``; NEW `` `ios/ElderlyAssistant/Services/Intents/` + `IntentTranscriptPreparation.swift` `` | none | stateless (existing seam) |
| C-MTC-09 | `dialogue.*` keys (16) | CHANGED `` `ios/ElderlyAssistant/Resources/` + `Localizable.xcstrings` `` | none | n/a |
| C-MTC-10 | Log-gate coverage + fixtures | CHANGED `` `ios/tools/` + `check-release-log-safety.py` `` and its fixtures module | none | n/a |
| C-MTC-11 | Test suites + hostile corpus | NEW/CHANGED under `` `ios/ElderlyAssistantTests/` `` | n/a | n/a |
| C-MTC-12 | Frame clause + seed mirror + pin updates (Phase 2) | CHANGED `` `ios/ElderlyAssistant/Services/` + `Voice/IntentPrompt.swift` ``, `` `ios/ElderlyAssistant/Services/` + `Voice/LlamaCommandInterpreter.swift` ``; CHANGED `` `tools/train-intent/seeds/` + `prompt_template.txt` ``; tests | none | stateless |
| C-MTC-13 | Reminder/calendar rollover (Phase 3, deferred) | CHANGED `CommandRouter.swift` slot vocabulary | none now | deferred |

### 8. C-MTC-01 — `DialogueManager.swift` (the frame, the manager, the composer, config, errors)

**Responsibility.** Own the single live frame; stamp its deadline; count attempts; resolve it through one funnel; compose probe text from template keys. Responsibility fence: it never speaks, never executes, never loads the catalog, never touches the session state machine, never logs.

Complete interface listing (internal access throughout; the file is new):

```swift
import Foundation

enum ProbeKind: String, Equatable {
    case slotFill
    case candidateChoice
}

enum DialogueSlot: Equatable {
    case musicQuery          // Phase 3 adds .reminderTime, .calendarTitle, .calendarTime
}

struct DialogueCandidate: Equatable {
    let id: String                        // stable within one frame; never logged with content
    let labelKey: String                  // xcstrings key for the spoken label template
    let domain: KeywordIntentRule.Domain
    let query: String?                    // the user's own extracted words; nil when the domain needs none
    let appID: String?                    // .appLaunch only (L2-D11); mirrors Match.appID
    let matchKeys: [String]               // pick-by-name vocabulary (L2-D10)
}

struct DialogueFrame {
    let id: UUID                          // process-local identity; telemetry/debugging only
    let probeKind: ProbeKind
    let slot: DialogueSlot
    let domain: KeywordIntentRule.Domain? // the frame's own domain (barge-in exclusion, B6/B7)
    let activeCommand: InterpretedCommand? // non-nil only when action == .music (L2-D13)
    let candidates: [DialogueCandidate]   // <= DialogueConfig.maxCandidates
    let defaultQuery: String?             // slotFill: the pending degenerate query
    let sourceTranscript: String          // the utterance that opened the frame (near-match context)
    var attempts: Int                     // probes spoken so far; arm sets 1
    var deadline: Date                    // arm is the only initial writer (L2-D7)
    func isExpired(at now: Date) -> Bool { now >= deadline }

    static func slotFill(candidates: [DialogueCandidate],
                         defaultQuery: String?,
                         domain: KeywordIntentRule.Domain,
                         activeCommand: InterpretedCommand?,
                         sourceTranscript: String) -> DialogueFrame
    static func candidateChoice(candidates: [DialogueCandidate],
                                sourceTranscript: String) -> DialogueFrame
}

enum DialogueFrameResolution: Equatable {
    case answered(DialogueMerge)
    case defaultExecuted
    case candidateSelected(index: Int)    // 0-based position in frame.candidates
    case exhausted
    case cancelled
    case escaped
    case bargedIn
    case timedOut
    case superseded
    case emergency                       // L2-D16
}

final class DialogueManager {
    private(set) var frame: DialogueFrame?
    private let answerWindowSeconds: TimeInterval
    private let now: () -> Date

    init(answerWindowSeconds: TimeInterval =
             TimeInterval(VoiceSessionStateMachine.Config.confirmationTimeoutSeconds),
         now: @escaping () -> Date = { Date() })

    /// nil when absent OR expired; an expired frame is dropped on read
    /// (the half-open-window guarantee, L1 §14).
    var liveFrame: DialogueFrame? { get }

    /// Validates, stamps deadline = now() + answerWindowSeconds, stores.
    /// The window itself is the coordinator's; this call never speaks.
    func arm(_ draft: DialogueFrame) throws        // .windowBusy | .noResolution
    @discardableResult func noteAttempt() -> Int   // attempts += 1; deadline restamped (L2-D6); returns attempts
    @discardableResult func resolve(_ resolution: DialogueFrameResolution) -> DialogueFrame?  // clears + returns
}

enum DialogueProbeComposer {
    /// slotFill: question key (group) or dialogue.probe.musicAny (no group),
    /// with %@ = option labels + the anyPlay label joined ", "; retry prefixes
    /// dialogue.retry + " ". candidateChoice: dialogue.understood.no + " " +
    /// dialogue.didYouMean with %@ = candidate labels joined ", ".
    static func probeText(for frame: DialogueFrame,
                          catalog: DialogueOptionCatalog?,
                          retry: Bool,
                          locale: Locale) -> String
}

enum DialogueConfig {
    static let maxProbes = 2          // OD-M1; counts probes spoken
    static let maxCandidates = 3      // FR-MTC-004 <= 2-3
    static let maxSlotOptions = 4     // FR-MTC-003 <= 3-4
}

enum DialogueError: Error, Equatable {
    case windowBusy          // arm while a window is live (defensive)
    case noResolution        // arm with neither candidates nor a default
    case catalogUnavailable  // resource missing/malformed
    case emptyMerge          // merge produced no value (callers treat as invalid)
}
```

**Arm-time validation.** `arm` throws `.noResolution` when `draft.candidates.isEmpty && draft.defaultQuery == nil`; it throws `.windowBusy` when `liveFrame != nil` (expiry-aware, so a stale frame never blocks). `liveFrame` drops an expired frame silently. `noteAttempt` on an absent frame is a no-op returning 0.

**Probe composition rules (template-only, testable by string equality).** Labels resolve via `L10n.str(labelKey, locale:)`; the composed strings use exactly one space after the `dialogue.retry` prefix and `", "` between labels. Anchor example (ne, first probe, bhajan group): "कस्तो भजन? शिव, दुर्गा, विष्णु, देवी, जे पनि बजाऊ … वा आफैँ भन्नुहोस्". A candidate label with a query renders its `%@` from `DialogueCandidate.query`; without one (news, or a degenerate music near-match) the primary `matchKey` renders instead — the user's own word, never generated text.

### 9. C-MTC-02 — `DialogueAnswerPath.swift` (classification, merge, vocabularies)

**Responsibility.** The pure brain of the answer turn: classifier, barge-in predicates, the strip/canonicalise/merge pipeline, and the input vocabularies. No state, no side effects, no router dependency beyond internal statics (B1-B6).

```swift
import Foundation

enum CaptureForm: String, Equatable { case indexWord, optionName, repetition, freeText }

enum MergeSource: String, Equatable {
    case catalog, freeText, candidate, defaultQuery
}

struct DialogueMerge: Equatable {
    let value: String            // the merged slot value / execution payload
    let capture: CaptureForm
    let source: MergeSource
}

enum InvalidAnswerReason: String, Equatable {
    case overLength              // raw > InputSanitiser.maxLength (L2-D5)
    case emptyAfterStrip         // scaffold strip left nothing
    case degenerateAnswer        // only markers/scaffold survived (e.g. "गीत चलाऊ")
    case noCandidateClaimed      // candidateChoice free-form no extractor claimed (L2-D9)
}

enum AnswerClassification: Equatable {
    case expired
    case escape
    case cancel
    case bargeIn
    case candidatePick(index: Int, capture: CaptureForm)   // 1-based spoken position
    case answer(DialogueMerge)
    case freeFormForCandidate(index: Int, value: String)   // 0-based candidate position
    case invalid(InvalidAnswerReason)
}

/// Input vocabularies — matched, never spoken (L2-D3/L2-D4).
enum DialogueAnswerVocabulary {
    static let indexWords: [(token: String, position: Int)] = [
        ("पहिलो", 1), ("first", 1),
        ("दोस्रो", 2), ("second", 2),
        ("तेस्रो", 3), ("third", 3)
    ]
    static let escapePhrases: [String] = [
        "फेरि भन्छु", "फेरि भन्न दिनु", "फेरि भन्नुहोस्", "म फेरि भन्छु",
        "let me say it again", "let me repeat", "i'll say it again"
    ]
    static let cancelTokens: [String] = [               // leading-position table (L2-D3)
        "no", "nope", "wrong", "छैन", "होइन", "होइनन्",
        "रद्द", "never mind", "cancel"
    ]
    static let anyPlayAliases: [String] = [             // the default-answer pick
        "जे पनि", "जे पनि बजाऊ", "जे भए पनि", "anything", "anything works"
    ]
    static let probeEchoWords: [String] = [             // probe question words, stripped as scaffold
        "कस्तो", "कुन", "के", "what", "which", "kind"
    ]
}

enum DialogueAnswerPath {
    static func classify(raw: String,
                         prepared: String,
                         frame: DialogueFrame,
                         catalog: DialogueOptionCatalog?,
                         locale: Locale,
                         now: Date) -> AnswerClassification
    static func isBargeIn(_ prepared: String,
                          frame: DialogueFrame,
                          medicationNames: [String]) -> Bool
    static func stripScaffold(_ text: String) -> String
    static func markerDroppedVariant(_ text: String) -> String
    static func matchCandidate(_ value: String, frame: DialogueFrame) -> Int?   // 0-based
    static func merge(_ value: String,
                      into frame: DialogueFrame,
                      catalog: DialogueOptionCatalog?) throws -> DialogueMerge
}
```

**Classifier order (pinned; L2-D1).** `C0` deadline (`frame.isExpired(at: now)` ⇒ `.expired`); `C1` raw length (`raw.count > InputSanitiser.maxLength` ⇒ `.invalid(.overLength)`); `C2` escape (any `escapePhrases` containment on the lowercased prepared text ⇒ `.escape`); `C3` barge-in (`isBargeIn` ⇒ `.bargeIn`); `C4` cancel/amendment (leading token in `cancelTokens`; scaffold-only remainder ⇒ `.cancel`; otherwise the remainder continues through `C5` — the no-with-amendment precedent); `C5` resolve (index word ⇒ `.candidatePick`; candidate `matchKeys` match ⇒ `.candidatePick`; anyPlay alias or the localized anyPlay label ⇒ `.answer(defaultQuery pick)`; catalog alias whole value / marker-dropped variant ⇒ `.answer(catalog)`; candidateChoice free-form extractor claim ⇒ `.freeFormForCandidate`; slotFill non-empty stripped value ⇒ `.answer(freeText)`; else `.invalid`); `C6` empty-frame guard (a nil/cleared frame can never enter — the router reads `liveFrame`).

**Barge-in (pinned, L2-D18; R1 rows B1-B7).** `isBargeIn` lowercases the prepared text once and evaluates, in order: B1 `CommandRouter.isExplicitMedicationAcknowledgement(text)`; B2 `CommandRouter.sensitiveCallPhrases.contains { text.contains($0) }`; B3 `VoiceContactSearchRoute.isDirectCallUtterance(text)`; B4 `if case .openPhone = VoiceContactSearchRoute.decide(transcript: text)`; B5 `if case .play = YouTubeRoute.decide(transcript: text)`; B6 `if let m = KeywordIntentRule.match(transcript: text, medicationNames: medicationNames), m.domain != frame.domain`; B7 return false otherwise (a music-domain match mid-music-frame is an answer). The function is total, pure and synchronous.

**`InterpretedCommand` extension (same file; L2-D13).**

```swift
extension InterpretedCommand {
    /// Copy with the free-text `message` entity replaced — every other field
    /// verbatim (memberwise init; all fields are `let`). Used only by the
    /// frame execution path; the merged command then travels the same
    /// executor a fresh interpreted `.music` command uses.
    func merging(message: String) -> InterpretedCommand {
        InterpretedCommand(action: action, entryId: entryId, contact: contact,
                           time: time, medication: medication, message: message,
                           callType: callType, requestedApp: requestedApp,
                           topic: topic, steps: steps, pluginAction: pluginAction,
                           pluginEntities: pluginEntities,
                           confidence: confidence, reply: reply)
    }
}
```

### 10. C-MTC-03 — `DialogueCandidateBuilder.swift`

**Responsibility.** Assemble the didYouMean candidate list, deterministically, from the sources L1 ADR-MTC-07 pins. Pure; no state; no execution knowledge beyond the domain tag.

```swift
enum DialogueCandidateBuilder {
    /// Sources in priority order: relaxed near-matches (L2-D10), then the
    /// denied rephrase hypothesis appended LAST and ONLY when >= 1 near-match
    /// exists (R2). Returns [] when nothing is eligible ("never fabricate").
    static func build(for utterance: String,
                      excludingDomain: KeywordIntentRule.Domain?,
                      rephraseHypothesis: InterpretedCommand?) -> [DialogueCandidate]

    /// slotFill options from the catalog group (>= maxSlotOptions sliced to
    /// the first maxSlotOptions), ids from the catalog, queries = canonical
    /// queries, matchKeys = the option's aliases.
    static func slotFillCandidates(from group: DialogueOptionGroup,
                                   catalog: DialogueOptionCatalog) -> [DialogueCandidate]
}
```

**Near-match mapping (pinned).** For each `KeywordIntentRule.NearMatch` in table order, subject to `excludingDomain` and the four-domain eligibility {news, youtube, music, appLaunch}:

| Domain | Candidate label | `query` | `matchKeys` | `appID` |
|---|---|---|---|---|
| news | `dialogue.candidate.news` | nil | the near-match's `matchedKeys` | nil |
| youtube | `dialogue.candidate.youtube` (`%@` = extracted query) | `YouTubeRoute.extractQuery(from: utterance)` — candidate omitted when nil | `matchedKeys` | nil |
| music | `dialogue.candidate.music` (`%@` = `musicQuery` or primary key) | `KeywordIntentRule.musicQuery(from: utterance)` | `matchedKeys` | nil |
| appLaunch | `dialogue.candidate.appLaunch` (`%@` = primary key) | nil | `matchedKeys` | the near-match's `appID` |

**Hypothesis mapping (pinned).** Action → domain: `.music` → `.music` (query = `command.message`); `.suggestVideo` → `.youtube` (query = `command.topic`); any other action → omitted (silent). `matchKeys` = `[]` (index-word pickable only). Appended last, capped by `maxCandidates` with the near-matches keeping priority.

### 11. C-MTC-04 — `DialogueOptionCatalog.swift` + `DialogueOptionCatalog.json`

**Responsibility.** Load and serve the curated on-device option catalog (OD-M2's default). Immutable after load.

**JSON schema (v1; the reviewable data artifact).** `groups` is an ordered array (L2-D12); every spoken label is a key (ADR-MTC-09); `aliases` and `matchKeys` are match vocabulary, never spoken.

```json
{
  "version": 1,
  "groups": [
    {
      "id": "bhajan.deity",
      "questionKey": "dialogue.probe.bhajanKind",
      "matchKeys": ["भजन", "bhajan"],
      "options": [
        { "id": "shiva",  "labelKey": "dialogue.option.bhajan.shiva",
          "query": "shiva bhajan",  "aliases": ["शिव", "shiv", "shiva"] },
        { "id": "durga",  "labelKey": "dialogue.option.bhajan.durga",
          "query": "durga bhajan",  "aliases": ["दुर्गा", "durga"] },
        { "id": "bishnu", "labelKey": "dialogue.option.bhajan.bishnu",
          "query": "bishnu bhajan", "aliases": ["विष्णु", "bishnu"] },
        { "id": "devi",   "labelKey": "dialogue.option.bhajan.devi",
          "query": "devi bhajan",   "aliases": ["देवी", "devi"] }
      ]
    }
  ]
}
```

```swift
struct DialogueOption: Equatable {
    let id: String
    let labelKey: String
    let query: String            // the canonical search string the merge substitutes
    let aliases: [String]        // match vocabulary; whole-token (Devanagari containment per idiom)
}

struct DialogueOptionGroup: Equatable {
    let id: String
    let questionKey: String
    let matchKeys: [String]      // group selection vocabulary (L2-D12)
    let options: [DialogueOption]
}

struct DialogueOptionCatalog: Equatable {
    let version: Int
    let groups: [DialogueOptionGroup]

    init(data: Data) throws                       // .catalogUnavailable on malformed JSON/schema
    static func load(bundle: Bundle = .main,
                     resource: String = "DialogueOptionCatalog") throws -> DialogueOptionCatalog

    func group(_ id: String) -> DialogueOptionGroup?
    /// First group (file order) whose matchKeys hit the canonicalized query.
    func groupForMusicQuery(_ query: String) -> DialogueOptionGroup?
    /// Whole-value alias match (the caller passes the value and the
    /// marker-dropped variant separately); nil when nothing matches.
    func option(matchingWholeValue value: String, in group: DialogueOptionGroup) -> DialogueOption?
}
```

**Matching discipline.** Whole-value / whole-token matching after canonicalisation (lowercase + whitespace collapse), with the repo's script-split idiom (Devanagari keys containment, Latin keys whole-token) — never Devanagari substring for short forms ("गीता" must not match "गीत"). The default option ("जे पनि बजाऊ" / "just play anything") is NOT a catalog entry: it is rendered from `dialogue.option.anyPlay` and resolved by the frame's `defaultQuery` (L1 §15).

**Failure behaviour.** `load` throws `.catalogUnavailable`; the router's cached load stores `nil` and the trigger degrades honestly (free-text-only probe + default, §22 `E3`). A gate test asserts the resource ships and parses.

### 12. C-MTC-05 — `CommandRouter.swift` edits (exact)

**12.1 New protocol members + extension defaults.** `VoiceCommandCoordinating` gains six requirements after the confirmation cluster (`pendingRephraseCommand`/`takePendingRephraseCommand` region, `:105-108`), each with an inert extension default in the `extension VoiceCommandCoordinating` block, following the established "requirement-with-extension-default" pattern (the router holds the coordinator as a protocol reference, so an extension-only member would bind statically):

```swift
// In `protocol VoiceCommandCoordinating: AnyObject`, after :108:
/// The live dialogue frame, nil when absent OR expired (the coordinator
/// drops an expired frame on read — the interception's half-open-window
/// guarantee). Main-queue read; the router calls it once per turn.
var activeDialogueFrame: DialogueFrame? { get }
/// Arms the frame AND opens the answer window (state machine hop), in that
/// order (L2 §21 step 3). false = a window is already open (confirmation or
/// frame); the caller then takes its non-probe fallback path.
func startDialogueFrame(_ frame: DialogueFrame) -> Bool
/// Invalid-answer accounting: attempts += 1, deadline restamped, window
/// timer refreshed (L2-D6). Returns the updated attempt count. Silent.
@discardableResult func noteDialogueAttempt() -> Int
/// The single resolution funnel: clear the frame, cancel the timer, close
/// the window through legal edges, emit dialogue_frame_resolved. Idempotent.
func resolveDialogueFrame(_ resolution: DialogueFrameResolution)
/// Emergency/supersession clear — resolveDialogueFrame with a reason (L2-D16).
func clearDialogueFrame(reason: DialogueFrameResolution)
/// The answer text through the exact seam every turn uses: sanitise
/// (.quarantine) then the shared input seam (L2-D14). Never the model.
func prepareDialogueAnswerText(_ raw: String) -> String

// In `extension VoiceCommandCoordinating` (inert defaults):
var activeDialogueFrame: DialogueFrame? { nil }
func startDialogueFrame(_ frame: DialogueFrame) -> Bool { false }
@discardableResult func noteDialogueAttempt() -> Int { 0 }
func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {}
func clearDialogueFrame(reason: DialogueFrameResolution) {}
func prepareDialogueAnswerText(_ raw: String) -> String {
    InputSanitiser.sanitise(raw, level: .quarantine)
}
```

**12.2 The interception block (NEW; exact position).** Inserted between the confirmation hook's closing brace (`CommandRouter.swift:886`) and the safety-net comment (`:888`), inside `route(transcript:)`. It consumes or falls through; the emergency check above (`:779-783`) is untouched and absolute. The block's body, concretely:

```swift
// [MTC] Dialogue-frame interception (design-l2 §12.2). Runs after the
// confirmation hook and before the safety net; consumes an answer,
// re-probes, or falls through to the ladder unchanged. Every state
// mutation goes through the coordinator hooks; this block never speaks
// a model-generated line.
if let frame = coordinator?.activeDialogueFrame {
    let prepared = coordinator?.prepareDialogueAnswerText(raw)
        ?? InputSanitiser.sanitise(raw, level: .quarantine)
    let medicationNames = (coordinator?.medicationVoiceEntries ?? []).flatMap {
        MedicationVoiceVocabulary.voiceKeys(for: $0)
    }
    let classification = DialogueAnswerPath.classify(
        raw: raw, prepared: prepared, frame: frame,
        catalog: dialogueCatalog, locale: coordinator?.activeLocale ?? neLocale,
        now: Date())
    switch classification {
    case .expired:
        break                                             // fresh command, fall through
    case .escape:
        coordinator?.resolveDialogueFrame(.escaped)
        speak(key: "dialogue.escape")
        return .unrecognised(transcript: raw)
    case .cancel:
        coordinator?.resolveDialogueFrame(.cancelled)
        speak(key: "dialogue.cancelled")
        return .unrecognised(transcript: raw)
    case .bargeIn:
        coordinator?.resolveDialogueFrame(.bargedIn)      // fall through; ladder executes it
    case .candidatePick(let index, let capture):
        return executeDialogueCandidate(index - 1, capture: capture,
                                        queryOverride: nil, frame: frame, raw: raw)
    case .answer(let merge):
        return executeDialogueAnswer(merge, frame: frame, raw: raw)
    case .freeFormForCandidate(let index, let value):
        return executeDialogueCandidate(index, capture: .freeText,
                                        queryOverride: value, frame: frame, raw: raw)
    case .invalid(let reason):
        let attempts = coordinator?.noteDialogueAttempt() ?? DialogueConfig.maxProbes
        emit(eventType: "dialogue_answer",
             outcome: "invalid",
             metadata: ["reason": reason.rawValue])
        if attempts < DialogueConfig.maxProbes {
            speakDialogueProbe(frame: frame, retry: true)   // re-probe; deadline refreshed
        } else {
            return resolveDialogueExhaustion(frame: frame, raw: raw)
        }
        return .unrecognised(transcript: raw)
    }
}
```

Note on `.answer` vs `.bargeIn`: the `case .bargeIn` arm deliberately does NOT return — control continues into the safety net and the ladder below, where the utterance executes exactly once with its normal tiers (L1 ADR-MTC-05; the `.bargedIn` resolution has already cleared the frame).

**12.3 The emergency clear (edit to `:779-783`).** After `handleEmergency()` and before `return .emergencyTriggered`, add the single side-effect-only statement:

```swift
coordinator?.clearDialogueFrame(reason: .emergency)     // post-dispatch, side-effect only
```

It contributes no condition, delay or gate to the emergency path (L1 ADR-MTC-02; a test pins dispatch with the clear forced to a no-op, §18 `E2`).

**12.4 Full edit list for `CommandRouter.swift`.**

| # | Function / region | Edit |
|---|---|---|
| 1 | `route(transcript:)` after `:886` | insert the interception block (§12.2) + doc comment |
| 2 | `route()` emergency branch `:779-783` | one `clearDialogueFrame(reason: .emergency)` line (§12.3) |
| 3 | keyword stage music arm `:1223-1234` | replace `fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)` with `fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: preText), raw: raw, intake: .ladder)` (emit + return lines unchanged) |
| 4 | `dispatchInterpreted` interpreted `.music` `:3336-3355` | keep the `interpretedQuery` computation byte-identical; non-nil ⇒ `fireMusicRequest(query:)` exactly as today; nil ⇒ `fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: raw), raw: raw, intake: .interpreted)` |
| 5 | rephrase-discard branch `:806-809` | after `takePendingRephraseCommand()` and `emit(rephrase_discarded)`: build candidates via `DialogueCandidateBuilder.build(for: taken?.sourceTranscript ?? raw, excludingDomain: nil, rephraseHypothesis: taken?.command)`; with ≥1 candidate ⇒ `speak(key: "dialogue.understood.no")` + `speakDialogueDidYouMean(...)` + arm; with 0 ⇒ `speak(key: "router.rephrase.discard")` (today, unchanged) |
| 6 | `routeKeywordRemainder` reprompt fallback `:2019-2021` | replace the `speak(key: "router.reprompt")` fallback with `speakDialogueDidYouMeanOrReprompt(raw)` — candidates built via `DialogueCandidateBuilder.build(for: raw, excludingDomain: nil, rephraseHypothesis: nil)`; ≥1 ⇒ honest line + probe + arm; 0 ⇒ `speak(key: "router.reprompt")`. The cloud-failure-class branch (`:2013-2018`) and both no-brain branches (`:2024-2027`) are untouched |
| 7 | protocol + extension (§12.1) | six members + inert defaults |
| 8 | `sensitiveCallPhrases` `:1869` | `private static let` → `static let` (L2-D2) with an extraction comment |
| 9 | new private helpers (below) | one contiguous `// MARK: - [MTC] Dialogue frame` region near the music helpers |

**12.5 New private router helpers (signatures pinned).**

```swift
private enum DialogueDegenerateIntake: String { case ladder, interpreted, candidate }

private lazy var dialogueCatalog: DialogueOptionCatalog?   // one cached load; nil on failure

private func fireMusicRequestOrProbe(query: KeywordIntentRule.MusicQueryExtraction,
                                     raw: String,
                                     intake: DialogueDegenerateIntake)
private func speakDialogueProbe(frame: DialogueFrame, retry: Bool)              // composes + speak(text:)
private func speakDialogueDidYouMean(_ candidates: [DialogueCandidate], locale: Locale)
private func speakDialogueDidYouMeanOrReprompt(_ raw: String)                   // edit 6's helper
private func executeDialogueAnswer(_ merge: DialogueMerge, frame: DialogueFrame, raw: String) -> RoutingResult
private func executeDialogueCandidate(_ index: Int, capture: CaptureForm,
                                      queryOverride: String?, frame: DialogueFrame, raw: String) -> RoutingResult
private func resolveDialogueExhaustion(frame: DialogueFrame, raw: String) -> RoutingResult
private func executeDialogueDefault(_ frame: DialogueFrame, raw: String) -> RoutingResult
```

`fireMusicRequestOrProbe` (the one degenerate trigger helper, shared by both intakes and by candidate execution): when `query.isDegenerate`, emit `dialogue_degenerate_query {intake}`, build the fold via `DialogueFrame.slotFill(candidates: defaultQuery: domain: .music, activeCommand: intake == .interpreted ? interpretedCommand : nil, sourceTranscript: raw)`, arm through `coordinator?.startDialogueFrame`; on `true` speak the probe (`retry: false`) and return; on `false` (window busy — defensive, unreachable on the current ladder) fall back to `fireMusicRequest(query: query.query ?? raw)` (today's exact behaviour). When NOT degenerate: `fireMusicRequest(query: query.query ?? raw)` — for the ladder intake this reproduces the previous line byte-for-byte (`musicQuery(from:)` is a thin wrapper over `musicQueryOutcome`, §13). The interpreted intake passes the arrived `command` as `activeCommand` (L2-D13).

`executeDialogueAnswer` (music slot): `coordinator?.resolveDialogueFrame(.answered(merge))`; emit `dialogue_answer` and `dialogue_frame_resolved`; then, when `frame.activeCommand` is non-nil and `action == .music`, `dispatchInterpreted(frame.activeCommand!.merging(message: merge.value), raw: raw)`; else `fireMusicRequest(query: merge.value)`. Returns `.unrecognised(transcript: raw)`.

`executeDialogueCandidate` (news/youtube/music/appLaunch, executed through the ladder's own seams — ADR-MTC-07 "as if it had been understood"):

| Domain | Execution (mirrors the ladder arm exactly) |
|---|---|
| news | `speakPreAck()` then `coordinator?.fireNewsReader()` then `emit(eventType: "news_reader_command", outcome: "success")` (`:1194-1198` parity) |
| youtube | `guard let q = queryOverride ?? candidate.query`; `fireYouTubePlay(query: q)` (`:1218-1221` parity, default `logProjection`) |
| music | `fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: queryOverride ?? candidate.query ?? raw), raw: raw, intake: .candidate)` — a degenerate pick chains a fresh slotFill frame sequentially |
| appLaunch | `if let line = coordinator?.requestAppLaunch(appID: appID, confidence: nil) { coordinator?.noteGenericReply(line); speak(text: line) }` (`:1256-1264` parity) |

Resolution first (`.candidateSelected(index:)` or `.answered(capture: source: .candidate)` for the free-form claim), events after, then the seam above.

`resolveDialogueExhaustion`: `candidateChoice` ⇒ `resolveDialogueFrame(.exhausted)` + `speak(key: "dialogue.exhausted")`; `slotFill` ⇒ `executeDialogueDefault(frame, raw:)` (`.defaultExecuted`). `executeDialogueDefault`: resolve, emit, then the same dispatch as `executeDialogueAnswer` with `merge.value = frame.defaultQuery ?? frame.sourceTranscript`.

**12.6 Threading/state notes.** All helper code runs on the main thread inside `route()`; `startDialogueFrame` and `resolveDialogueFrame` hop to main internally only when already off it (mirroring `openConfirmationWindow()` `:7019-7027`); `dialogueCatalog` is loaded lazily on first use (main thread) and then immutable.

### 13. C-MTC-06 — `KeywordIntentRule.swift` edits

**(a) `MusicQueryExtraction` + provenance (R-side of ADR-MTC-06).**

```swift
struct MusicQueryExtraction: Equatable {
    enum Provenance: Equatable { case content, markerFallback, transcriptFallback }
    let query: String?           // nil only when the input canonicalizes empty
    let provenance: Provenance
    var isDegenerate: Bool { provenance != .content || query == nil }
}

/// The existing three-step fallback (:764-775), restructured to report
/// WHICH step produced the query. Byte-identical outputs to `musicQuery`.
static func musicQueryOutcome(from raw: String,
                              maxLength: Int = KeywordIntentRule.maxMusicQueryLength) -> MusicQueryExtraction

/// Thin wrapper — `musicQueryOutcome(from:maxLength:).query`; return values
/// (and every existing test) are byte-identical.
static func musicQuery(from raw: String,
                       maxLength: Int = KeywordIntentRule.maxMusicQueryLength) -> String?
```

Step mapping: tokens survive the drop sets ⇒ `.content`; `kept.isEmpty` and a marker token chosen ⇒ `.markerFallback`; `kept.isEmpty` and no marker ⇒ `.transcriptFallback`; canonical-empty input ⇒ `.transcriptFallback` with `query = nil`.

**(b) Near-match reporting (`nearMatches`).**

```swift
struct NearMatch: Equatable {
    let domain: Domain
    let matchedKeys: [String]    // the groups that DID co-occur (fixed vocabulary)
    let appID: String?           // .appLaunch near-matches only
}

/// Domains whose rule PARTIALLY co-occurs: for each rule (table order),
/// each variant with 1 <= matchedGroups < groupCount, the rule's `excluded`
/// groups absent. One entry per domain (first partial variant wins),
/// restricted to {news, youtube, music, appLaunch}.
static func nearMatches(transcript raw: String) -> [NearMatch]
```

Eligibility is enforced here (the four-domain set); executability (a usable query) is enforced by `DialogueCandidateBuilder` (§10). Pure; no dynamic vocabulary (the medication rule is excluded by the four-domain set, never consulted).

**(c) Scaffold/marker accessors (the answer strip's one vocabulary source).**

```swift
/// A NON-marker drop token — the music verb family, particles and the
/// filter words — used by the answer scaffold strip. Markers deliberately
/// return false (markers are kept in the free-text fallback; they are
/// dropped only through `markerDroppedVariant`).
static func isMusicScaffoldToken(_ token: String) -> Bool   // = isMusicDropToken(token) && !isMusicMarkerToken(token)
/// The music marker family (currently private): भजन, गीत, गाना, संगीत,
/// सङ्गीत, music, song, bhajan — exposed for the marker-dropped variant.
static func isMusicMarkerToken(_ token: String) -> Bool
```

No existing private set changes contents; both accessors read the same tables the extractor uses.

---

### 14. C-MTC-07 — `VoiceSessionStateMachine.swift` edits

Mirroring, never refactoring, the confirmation machinery (L1 §14). Edit list (full signatures in §25):

| # | Member | Edit |
|---|---|---|
| 1 | `VoiceSessionState` enum (`:9-17`) | add `case awaitingSlotAnswer` after `awaitingConfirmation` |
| 2 | `canTransition` (`:21-57`) | entry edges from `.idle` and the busy set (exactly the set that accepts `.awaitingConfirmation` at `:29-38`); exit edges to `[.idle, .error, .stopped]` (mirror of `:39-40`) |
| 3 | `supportsTalkReset` (`:71-78`) | returns `false` in `.awaitingSlotAnswer`, exactly as in `.awaitingConfirmation` (the dialogue owns the turn) |
| 4 | `Config` (`:93-96`) | unchanged — `confirmationTimeoutSeconds` (45 s) is the single source for both windows |
| 5 | callbacks | add `var onSlotAnswerTimeout: (() -> Void)?` beside `onConfirmationTimeout`; the confirmation callback and its spoken notice are untouched |
| 6 | `transition(to:)` (`:111-127`) | mirrored arms — leaving `.awaitingSlotAnswer` cancels `slotAnswerTimer`; entering it arms |
| 7 | `openSlotAnswerWindow()` | NEW; mirrors `openConfirmationWindow()` (`:153-181`) — bridge via `.idle`, legal edges only, "the window must EXIST, not merely be attempted" (F14); `@discardableResult`, `Bool` |
| 8 | `refreshSlotAnswerWindow()` | NEW; true only when already in `.awaitingSlotAnswer` (cancels + re-arms the timer; the re-probe path, L2-D6) |
| 9 | `armSlotAnswerTimer()` / `cancelSlotAnswerTimer()` | NEW; mirror `armConfirmationTimer` (`:183-203`, incl. the F6 still-open guard `guard self.state == .awaitingSlotAnswer`) and `cancelConfirmationTimer` (`:205-208`) |

Boundary correctness is unchanged from L1 §14: the timer cancels on every resolution and re-checks state before firing (F6 guard); the interception reads the frame's own expiry — an utterance just before expiry is an answer, the same utterance after expiry is a fresh command.

### 15. C-MTC-08 / 08b / 08c — coordinator, contact route, brain chain edits

**`AppCoordinator.swift` (C-MTC-08).**

| # | Member / region | Edit |
|---|---|---|
| 1 | stored state | `private let dialogueManager: DialogueManager` — constructed with `answerWindowSeconds: TimeInterval(VoiceSessionStateMachine.Config.confirmationTimeoutSeconds)` at the existing router/wiring point (`:3761` region) |
| 2 | `extension AppCoordinator: VoiceCommandCoordinating` (`:10856`) | implement the six members (§12.1; each does its main-thread hop mirroring `openConfirmationWindow()` `:7019-7027`) |
| 3 | `startDialogueFrame` | order pinned: guard `!isAwaitingConfirmation` (false otherwise) → guard `dialogueManager.liveFrame == nil` (false) → `openSlotAnswerWindow()` (false ⇒ return false) → `try dialogueManager.arm(frame)` (throw ⇒ cancel the window, return false) → true. Never speaks |
| 4 | `noteDialogueAttempt` | `dialogueManager.noteAttempt()` then `refreshSlotAnswerWindow()`; returns the count. Silent |
| 5 | `resolveDialogueFrame` / `clearDialogueFrame(reason:)` | one funnel: `guard let resolved = dialogueManager.resolve(resolution)` → cancel the timer / close the window through legal edges (`transitionViaIdle`-style) → emit `dialogue_frame_resolved {outcome}` with component `app_coordinator` (`:7327` precedent). Idempotent |
| 6 | `onSlotAnswerTimeout` handler (fires from `armSlotAnswerTimer`) | resolve `.timedOut`, emit the event, **speak nothing**, never call `recordConfirmationTimeout()` (L1 ADR-MTC-08) |
| 7 | `openConfirmationWindow()` (`:7019-7027`) | gains, at its top, `_ = dialogueManager.resolve(.superseded)` — the structural funnel that makes the two windows mutually exclusive in the frame direction (arming a confirmation clears any frame; ADR-MTC-03) |
| 8 | `prepareDialogueAnswerText` | `IntentTranscriptPreparation.prepare(raw, seam: brainChain.transcriptPreparationSeam).prepared` (C-MTC-08c) |
| 9 | pending-rephrase seams (`:7395-7406`) | unchanged; edit 7 covers them (they pend through the window opener) |

**`VoiceContactSearchRoute.swift` (C-MTC-08b).** `isDirectCallUtterance` `private static func` → `static func` (L2-D2), doc noting the second call site and the unchanged lowercase-input contract.

**`LocalBrainChain.swift` + NEW `IntentTranscriptPreparation.swift` (C-MTC-08c).**

```swift
// NEW file: IntentTranscriptPreparation.swift at Services/Intents/ (see the §7 map)
enum IntentTranscriptPreparation {
    struct Prepared: Equatable {
        let raw: String                 // the caller's transcript, verbatim
        let sanitised: String           // InputSanitiser.sanitise(raw, level: .quarantine)
        let prepared: String            // pair?.pickerBrainInput ?? sanitised (the dialogue answer value)
        let pair: IntentTranscriptPair? // the STT-corrector + canonicalizer output, nil without a seam
    }
    static func prepare(_ transcript: String,
                        seam: LocalBrainChain.InputSeam?) -> Prepared
}
```

`prepare`'s internal order is exactly `LocalBrainChain.turnInput`'s (`:275-285`): nil seam ⇒ `Prepared(raw:, sanitised: raw, prepared: raw, pair: nil)` without calling the sanitiser (byte-parity: `turnInput` returns `plainText: transcript` untouched); non-nil seam ⇒ sanitise first, then `seam.prepare(clean)`, `prepared = pair.pickerBrainInput`. `LocalBrainChain.turnInput` is rewired to call the helper; `plainText(for:raw:)` (`:296-307`) is untouched, so the brain input remains byte-identical. A new accessor `var transcriptPreparationSeam: InputSeam? { inputSeam }` (internal) serves the coordinator.

### 16. C-MTC-09 — localisation inventory (the reviewable copy artifact)

16 new `dialogue.*` keys, all ne+en mandatory, sourceLanguage en. Probe text is template-composed only (§8 rules); `%@` placeholders are filled from catalog labels, candidate labels or the user's own words — never generated text.

| Key | ne (draft) | en (draft) | Used by |
|---|---|---|---|
| `dialogue.probe.bhajanKind` | कस्तो भजन? %@ … वा आफैँ भन्नुहोस् | What kind of bhajan? %@ … or say it yourself | slotFill probe, bhajan group (%@ = labels) |
| `dialogue.probe.musicAny` | कस्तो संगीत चाहियो? नाम भन्नुहोस्। | What kind of music? Say the name. | slotFill probe, no group / catalog unavailable |
| `dialogue.option.bhajan.shiva` | शिव | shiva | catalog label |
| `dialogue.option.bhajan.durga` | दुर्गा | durga | catalog label |
| `dialogue.option.bhajan.bishnu` | विष्णु | bishnu | catalog label |
| `dialogue.option.bhajan.devi` | देवी | devi | catalog label |
| `dialogue.option.anyPlay` | जे पनि बजाऊ | just play anything | default option label + `C5` anyPlay match |
| `dialogue.retry` | फेरि सोध्छु — | Let me ask again — | re-probe prefix |
| `dialogue.understood.no` | मैले बुझिन। | I didn't understand. | didYouMean honest line |
| `dialogue.didYouMean` | के तपाईंको मतलब %@ हो? | Did you mean %@? | didYouMean probe (%@ = candidate labels) |
| `dialogue.candidate.news` | समाचार सुनाउने हो? | The news? | candidate labels (§10) |
| `dialogue.candidate.youtube` | युट्युबमा %@ हेर्ने हो? | Watch %@ on YouTube? | candidate labels (%@ = query/key) |
| `dialogue.candidate.music` | %@ बजाउने हो? | Play %@? | candidate labels (%@ = query/key) |
| `dialogue.candidate.appLaunch` | %@ खोल्ने हो? | Open %@? | candidate labels (%@ = key) |
| `dialogue.cancelled` | ठीक छ। | OK. | cancel ack |
| `dialogue.escape` | ठीक छ, फेरि भन्नुहोस्। | OK, tell me again. | escape ack |
| `dialogue.exhausted` | मैले बुझिन। पछि फेरि भन्नुहोस्। | I didn't understand. Try again later. | candidateChoice exhaustion |
| `dialogue.timeout` | — | — | deliberately absent (silent expiry) |

### 17. C-MTC-10 — release-gate edits

| File | Edit |
|---|---|
| `` `ios/tools/` + `check-release-log-safety.py` `` | `FEATURE_ROOTS` (`:141-176`) gains four entries with no trailing slash, matching the existing per-file precedent (`Services/Spotify`, `Services/Plugins/SpotifyPlugin.swift`): `Services/Voice/` `+` `DialogueManager.swift`, `Services/Voice/` `+` `DialogueAnswerPath.swift`, `Services/Voice/` `+` `DialogueCandidateBuilder.swift`, `Services/Voice/` `+` `DialogueOptionCatalog.swift` (single strings, path-span-split here for the sanitiser only) |
| fixtures module | one fixture entry per new root mirroring the existing per-feature fixtures (a printed console line and a raw content write in each new file must both fail the gate) |
| `DEFAULT_ALLOW_LIST` path | unchanged — it reads `LogSanitiser.allowedKeys`, so the §26 key additions flow through automatically |
| runtime `LogSanitiser.allowedKeys` | gains the seven metadata keys of §26 with fixed vocabularies and justified-key comments |

Rationale: the four new files must be inside the gate from the day they land (L1 §22 R9) — the gate then fails any future console write or content-derived field in them, before any release build.

### 18. C-MTC-11 — test seams per suite (cuttable as units)

Paths under the test bundle; every suite has its own **file-private doubles** (the `CommandRouterMusicTests` pattern: doubles are copied per suite because a suite's doubles are `private` there — `MusicMockCoordinator`, `MockObservabilityBus`, `MusicMockSpeaker`, `MusicStubTransport`). The dialogue suites add: `DialogueMockCoordinator` (a `VoiceCommandCoordinating` double scripting `activeDialogueFrame`/`isAwaitingConfirmation`/brainReadiness/medicationVoiceEntries and recording calls), `DialogueMockSpeaker`, `MockObservabilityBus` (copy), and a `DialogueOptionCatalog` built from an inline JSON `Data` literal.

| Suite file | Kind | Covers (test-name groups) |
|---|---|---|
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueFrameTests.swift` `` | NEW | FR-MTC-001 lifecycle: `testArmStampsDeadlineFromTheInjectedWindow`, `testLiveFrameDropsExpiredOnRead`, `testArmThrowsWindowBusy`, `testArmThrowsNoResolution`, `testResolveClearsAllFields`, `testNoteAttemptRestampsTheDeadline` (L2-D6), `testResolveIsIdempotent` |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueAnswerPathTests.swift` `` | NEW | the §22 vectors `V1`–`V14` one test each (`testIndexWordPicksOptionOne`, `testWholeAliasIsOptionName`, `testMarkerDroppedVariantIsRepetition`, `testFreeTextIsKept`, `testMarkerOnlyAnswerIsInvalid`, `testAnyPlayAliasResolvesTheDefaultPick`, `testAmendmentContentIsAnAnswer`, ...); escape/cancel rows (`V8`–`V11`); `testNegationPlusStrongCommandBart` `+` `gesInNotMerges` (L2-D1); barge-in rows `B1`–`B7` one test each incl. `testMusicMatchMidMusicFrameIsNotBargeIn` (FR-MTC-005 scenario 3); over-length `testOverLongRawAnswerIsInvalidNotTruncated` (L2-D5) |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueCandidateBuilderTests.swift` `` | NEW | near-match mapping rows (§10), hypothesis-last rule `testHypothesisAppendedLastOnlyWithNearMatch` (R2), `testEmptyCandidatesReturnsEmpty` (never fabricate) |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueOptionCatalogTests.swift` `` | NEW | resource parses; `testCanonicalQueryWholeValueOnly`; `testGitaDoesNotMatchGeet` (grapheme discipline); `testGroupForMusicQueryFileOrder`; `testMalformedDataThrowsCatalogUnavailable`; bundle gate `testResourceShipsInTheBundle` |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/CommandRouterDialogueTests.swift` `` | NEW | interception placement `testAnswerTurnNeverReachesThe` `+` `InterpreterOrCache`; `testEmergencyMidFrameDropsTheFrameAnd` `+` `DispatchIsUnchanged` (dispatch with the clear forced to a no-op, R6); `testBargeInFallsThroughAndExecutesOnce`; `testStaleFrameExpiryLastMomentAnswer` `+` `VersusPostExpiryCommand`; `testProbeSpeaksThroughTheReplyLaneAndNotesSpoken`; `testGibberishMidFrameConsumesNoAttempt` (R7); `testConfirmationHookIsUntouched` `+` `WithALiveFrame`; `testSlotFillExhaustionExecutesThe` `+` `DefaultQuery`; `testCandidateChoiceExhaustionCloses` `+` `WithTheExhaustedLine`; `testReProbePrefixesRetryAndRefreshesTheDeadline` |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueHostileCorpusTests.swift` `` | NEW | the security corpus (R8): answers embedding emergency phrases (`testEmergencyAnswerMidFrameDispatchesEmergency`), injection-marker text, sensitive-call vocabulary (`testSensitivePhraseAnswerNeverMergesAnd` `+` `TheLadderBlocksIt`), candidate-poisoning utterances, authority claims (`testAnswerClaimingATierChangesNothing`) |
| `` `ios/ElderlyAssistantTests/Services/` + `Intents/IntentTranscriptPreparationTests.swift` `` | NEW | parity rows `T1`–`T4`: same input ⇒ identical `sanitised`/`prepared`/`pair` as the historical `turnInput` outputs, incl. nil seam, corruptor-hit and corruptor-miss fixtures |
| `` `ios/ElderlyAssistantTests/Services/` + `Intents/DialogueCacheBypassTests.swift` `` | NEW | `testPendingTranscriptStaysNilOnFrameExecution`; `testAnswerTextIsNeverInternedByTheCache`; `testConfirmedExecutionRecordingIsUnchanged` |
| `` `ios/ElderlyAssistantTests/App/` + `VoiceSessionStateMachineTests.swift` `` | CHANGED | new-state edges legal/illegal; `testOpenSlotAnswerWindowExistsFromEveryLegalState`; timer arm/cancel/refresh; F6 still-open guard; `testSlotAnswerTimeoutIsSilent`; the confirmation suite unchanged |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/CommandRouterMusicTests.swift` `` | CHANGED | degenerate trigger replaces the blind search on both intakes (new tests; the existing supersession block stays green — specific queries byte-identical); merged dispatch goes through `fireMusicRequest` (and `dispatchInterpreted` when `activeCommand` exists) |
| `` `ios/ElderlyAssistantTests/Services/` + `Voice/KeywordIntentRuleTests.swift` `` | CHANGED | provenance rows (content/marker/transcript), `nearMatches` sets, wrapper byte-parity `testMusicQueryWrapperMatchesOutcome` |

**Pins that must stay green in Phase 1** (NFR-MTC-012 evidence): the golden music digest, the prompt digests, the 2_506 baseline, the 3_000 ceiling, `GoldenCorpusTests`, the Spotify suites, the confirmation-protocol suites, and every suite the feature does not touch.

### 19. C-MTC-12 — Phase 2 clause plumbing (R12; ships only with v17)

**Interfaces (pinned now, implemented in the v17 change only).**

```swift
// LlamaCommandInterpreter.swift — InterpreterContext gains a defaulted field
// (the `addressAs` precedent, :110-117; every pre-feature construction site
// compiles unchanged):
struct InterpreterContext {
    // ... existing fields ...
    let frameClause: String?    // nil = no dialogue context (Phase 1 default)
    init(pendingMedications: [String], userLanguageHint: String,
         addressAs: String? = nil, frameClause: String? = nil)
}

// IntentPrompt.swift — the renderer + the insertion point:
/// "" for nil/empty; else the clause line. The default keeps the Phase 1
/// prompt byte-identical (the empty render appends nothing).
static func frameClause(_ clause: String?) -> String
// build(transcript:context:activePlugins:) inserts \(frameClause(context.frameClause))
// between the `User said: "\(transcript)"` line and the closing imperative
// (the fifth interpolation; the stable template prefix above the insertion
// point is untouched — KV-prefix stability, NFR-MTC-011).
```

**The atomic update list (same change, or the gates fail):** (1) the seed mirror `` `tools/train-intent/seeds/`+`prompt_template.txt` `` updated byte-identically with the interpolation; (2) `check-prompt-mirror.py` `INTERPOLATIONS` (`:56-61`) gains the fifth entry `{frame_clause}` → `frameClause(context.frameClause)`, and its self-test mutations extend to five; (3) `IntentPromptTests` baseline (2_506) and worst-case recomputed (clause ≤ 300 Characters, worst case ≤ 2_886, ceiling 3_000 unchanged); (4) `PinnedSurfaceGuardTests` prompt digests updated; (5) `LlamaCommandInterpreter` threads the frame clause into `InterpreterContext` at its construction site; (6) v17 trains on follow-up turns (FR-MTC-018). Phase 1 ships **no** prompt edits: the interface additions above land with the v17 change only, so the Phase 1 diff contains zero prompt files.

### 20. C-MTC-13 — Phase 3 (deferred; interface stability notes)

No Phase 3 code ships. The interfaces already accommodate it: `DialogueSlot` gains `.reminderTime` / `.calendarTitle` / `.calendarTime`; the trigger points are the current ask-lines of `handleSetReminder` and `handleCreateCalendarEvent`; the merge canonicalises through the existing `NepaliTimeParser` path instead of the music catalog; `.confirm` tiers are unchanged. `DialogueFrame.slotFill`'s factory is slot-parametric, `DialogueManager` is slot-agnostic, and the interception block reads `frame.slot` only through the classifier — so the rollover is additive per ADR-MTC-15. RepetitionGuard sees only confirmed executions (the frame resolves before any confirmation pend; edit 7 of §15 keeps the funnels exclusive).

---

## Interfaces

### 21. The answer turn end-to-end (the cross-component call contract)

One utterance, in order, all main-thread inside `route(transcript:)`:

1. `recordTranscript(raw)` and `TranscriptSanityGuard` (`:741`/`:747-758`) — unchanged. A rejected utterance speaks `router.reprompt` and leaves the frame armed, consuming no attempt (R7; the deadline bounds it).
2. Emergency check (`:779-783`) — unchanged, absolute. On dispatch, the post-dispatch clear (`.emergency`) runs; the frame never gates, delays or precedes this path.
3. Confirmation hook (`:787-886`) — byte-identical. The windows are mutually exclusive structurally (§15 edit 7): arming a confirmation clears a live frame (`.superseded`); `startDialogueFrame` refuses while `isAwaitingConfirmation`.
4. **Dialogue block** — `coordinator?.activeDialogueFrame` (live, expiry-checked). Nil ⇒ fall through untouched. Live ⇒ `prepareDialogueAnswerText(raw)` (sanitise → seam, L2-D14), then `DialogueAnswerPath.classify(...)`.
5. Classification arms (the exact switch, §12.2): `.expired` falls through; `.escape`/`.cancel` resolve + speak their acks; `.bargeIn` resolves and falls through (executes once below, with its normal tiers); `.candidatePick`/`.answer`/`.freeFormForCandidate` resolve first, then execute through the domain's own seam (§12.5); `.invalid` increments attempts and re-probes or exhausts.
6. Every consumed arm returns `.unrecognised(transcript: raw)` (the confirmation hook's own convention); the barge-in arm returns nothing and lets the stages below run.
7. Fall-through stages (`:888` onward) — unchanged except the two trigger edits (§12.4 edits 5-6).

Guarantees this sequence carries, each pinned by a §18 test: emergency first and unmodified (`E2`); the answer turn never reaches the interpreter or the cache (`CommandRouterDialogueTests` placement rows; `DialogueCacheBypassTests`); one spoken line per outcome, through the existing lanes; no state survives a resolution.

### 22. The capture ladder — ordered algorithm `S1`–`S6` with vectors

All steps operate on the prepared answer (§21 step 4). `normalize` = lowercase + whitespace/punctuation trim (the `containsToken` split idiom, mirrored locally). `stripScaffold` drops tokens that are `KeywordIntentRule.isMusicScaffoldToken` or `DialogueAnswerVocabulary.probeEchoWords` members. `markerDroppedVariant` drops tokens that are `KeywordIntentRule.isMusicMarkerToken` members. `wholeTokenMatch(text, key)` = containment for keys containing Devanagari scalars, whole-token for Latin keys (L2-D10).

| Step | Rule | Failure/continuation |
|---|---|---|
| `S1` | normalize the prepared value | empty ⇒ `.invalid(.emptyAfterStrip)` |
| `S2` | leading index token: first token ∈ `indexWords` and position ≤ the frame's option/candidate count ⇒ slotFill: option `position`'s canonical query (`.answer(.indexWord, .catalog)`); candidateChoice: `.candidatePick(index: position, capture: .indexWord)`. With content after the index token, the token is treated as scaffold and the remainder continues | no index token ⇒ continue with the value |
| `S3` | scaffold strip the working value (verbs, particles, probe-echo words) | empty ⇒ `.invalid(.emptyAfterStrip)` |
| `S4` | match, in order: (a) whole stripped value against catalog option aliases (slotFill) ⇒ `.answer(.optionName, .catalog)` with the option's canonical query; against candidate `matchKeys` (candidateChoice) ⇒ `.candidatePick(.optionName)`; (b) the marker-dropped variant against the same tables ⇒ capture `.repetition` | no match ⇒ `S5` |
| `S5` | slotFill with `defaultQuery != nil`: the stripped value equals the localized `dialogue.option.anyPlay` label (normalized) or ∈ `anyPlayAliases` ⇒ `.answer(.optionName, .defaultQuery)` with `value = frame.defaultQuery` | no match ⇒ `S6` |
| `S6` | markerDroppedVariant empty (only markers survived) ⇒ `.invalid(.degenerateAnswer)`; candidateChoice: first candidate (list order) whose domain extractor claims the value (music → `musicQuery`; youtube → `YouTubeRoute.extractQuery`) ⇒ `.freeFormForCandidate(index, extracted ?? value)`; otherwise ⇒ `.invalid(.noCandidateClaimed)`; slotFill: ⇒ `.answer(.freeText, .freeText)` with the stripped value (markers kept — the free-text fallback is never marker-stripped) | — |

**Vectors (input/output, fixture text only).**

| # | Frame / input | Outcome |
|---|---|---|
| `V1` | slotFill; "पहिलो" | `.answer(value: "shiva bhajan", capture: .indexWord, source: .catalog)` |
| `V2` | slotFill; "दुर्गा" | `.answer(value: "durga bhajan", capture: .optionName, source: .catalog)` |
| `V3` | slotFill; "दुर्गा भजन बजाऊ" | `.answer(value: "durga bhajan", capture: .repetition, source: .catalog)` (scaffold drops बजाऊ; the marker-dropped variant matches) |
| `V4` | slotFill; "दशैं दुर्गा भजन" | `.answer(value: "दशैं दुर्गा भजन", capture: .freeText, source: .freeText)` (owner's merge example; markers kept) |
| `V5` | slotFill; "गीत चलाऊ" | `.invalid(.degenerateAnswer)` (marker-only survives) |
| `V6` | slotFill; "कस्तो भजन" | `.invalid(.degenerateAnswer)` (probe-echo + marker) |
| `V7` | slotFill(defaultQuery "भजन"); "जे पनि बजाऊ" | `.answer(value: "भजन", capture: .optionName, source: .defaultQuery)` |
| `V8` | slotFill; "फेरि भन्छु" | `.escape` |
| `V9` | any; "होइन" | `.cancel` |
| `V10` | slotFill; "होइन, दुर्गा भजन" | amendment: the remainder resolves as `V3` (`.answer(.repetition, .catalog)`) |
| `V11` | slotFill; "दुर्गा होइन" | NOT a cancel (non-leading negation) ⇒ `.answer(.freeText, .freeText)` with "दुर्गा होइन" (L2-D3) |
| `V12` | any; "मेरो छोरालाई फोन गर" | `.bargeIn` (B3) |
| `V13` | candidateChoice; "युट्युब" with a youtube candidate | `.candidatePick(index, .optionName)` |
| `V14` | any; a 201-Character raw answer | `.invalid(.overLength)` (L2-D5; `InputSanitiser` would clamp — the check runs first) |

### 23. Degenerate detection (both intakes, one helper)

`isDegenerate ⇔ provenance != .content || query == nil` (§13). Intake matrix:

| Intake | Trigger site | Degenerate decision | Non-degenerate path (byte-identical to today) |
|---|---|---|---|
| ladder | music arm `:1223-1234` | `musicQueryOutcome(from: preText)` | `fireMusicRequest(query: query ?? preText)` — the previous expression's exact values (`musicQuery` is the wrapper) |
| interpreted | `.music` dispatch `:3336-3355` | `interpretedQuery` nil (model set no `message`), then `musicQueryOutcome(from: raw)` | `interpretedQuery` non-nil ⇒ `fireMusicRequest(query:)` exactly as today |
| candidate | pick execution (§12.5) | `musicQueryOutcome(from: picked query/word)` | `fireMusicRequest(query:)`; a degenerate pick chains a fresh slotFill frame sequentially |

Every degenerate arm emits `dialogue_degenerate_query {intake}` before arming (no content in the event; the intake enum only).

### 24. Candidate assembly and exhaustion (interface summary)

Sources in priority order (L1 ADR-MTC-07; §10 mapping): relaxed near-matches (`KeywordIntentRule.nearMatches`, four-domain eligibility, executable-query rule) → the denied rephrase hypothesis appended last and only alongside ≥ 1 near-match (R2) → the live frame's own candidates on a re-probe (re-offered unchanged). Cap `maxCandidates` (3). Empty ⇒ no frame, the honest line stands alone.

| Frame | Attempt-cap exhaustion | Bare cancel at any count |
|---|---|---|
| slotFill | execute the pending command with `defaultQuery` (`.defaultExecuted`, same executor as `.answer`) | `.cancelled`, nothing executes |
| candidateChoice | `.exhausted` + `dialogue.exhausted`, nothing executes (R3) | `.cancelled`, nothing executes |

### 25. State-machine deltas — full signatures

```swift
// VoiceSessionStateMachine.swift additions (main-queue-confined, existing contract)
enum VoiceSessionState {
    // ... existing cases ...
    case awaitingSlotAnswer        // beside awaitingConfirmation (:9-17)
}

var onSlotAnswerTimeout: (() -> Void)?     // silent callback; the spoken
                                           // confirmation notice is untouched
@discardableResult
func openSlotAnswerWindow() -> Bool        // mirrors openConfirmationWindow():153-181
@discardableResult
func refreshSlotAnswerWindow() -> Bool     // re-arm while already in the state (L2-D6)
private func armSlotAnswerTimer()          // mirrors armConfirmationTimer():183-203,
                                           // incl. the F6 guard `state == .awaitingSlotAnswer`
private func cancelSlotAnswerTimer()       // mirrors cancelConfirmationTimer():205-208
```

`canTransition`: entering `.awaitingSlotAnswer` is legal from `.idle` and the busy set that accepts `.awaitingConfirmation`; leaving is legal to `[.idle, .error, .stopped]`. `transitionViaIdle` bridging applies exactly as for confirmation. Any transition out cancels the timer; entering arms it. The confirmation state, timer and spoken timeout line are untouched.

### 26. Events and log-gate deltas

Four event types, all closed-vocabulary, count/enum metadata only (no probe text, no answer text, no candidate labels, no transcript):

| Event | Emitter (component) | Metadata keys | Fixed vocabularies |
|---|---|---|---|
| `dialogue_degenerate_query` | `command_router` | `intake` | `ladder` / `interpreted` / `candidate` |
| `dialogue_probe_spoken` | `command_router` | `probe_kind`, `attempt`, `option_count`; `errorCode: "catalogUnavailable"` when degraded (E3) | `slotFill` / `candidateChoice`; attempts `1|2`; count `0..4` |
| `dialogue_answer` | `command_router` | `capture_form`, `merge_source`; on invalid: outcome `invalid` + `reason` | `indexWord`/`optionName`/`repetition`/`freeText`; `catalog`/`freeText`/`candidate`/`defaultQuery`; reasons §9 |
| `dialogue_frame_resolved` | `command_router` (turn-time resolutions); `app_coordinator` (timeout, emergency, superseded — the `:7327` component precedent) | `outcome` | the ten-case `DialogueFrameResolution` vocabulary (`answered`, `defaultExecuted`, `candidateSelected`, `exhausted`, `cancelled`, `escaped`, `bargedIn`, `timedOut`, `superseded`, `emergency`) |

`LogSanitiser.allowedKeys` gains exactly seven keys — `intake`, `probe_kind`, `attempt`, `option_count`, `capture_form`, `merge_source`, `reason` — each with a justified-key comment and the fixed vocabulary above; `DEFAULT_ALLOW_LIST` in the gate follows automatically (§17). The four new files join `FEATURE_ROOTS` (§17) so no future console write or content-derived field in them can ship. Probe and ack text rides the existing on-device reply surface (`speak(text:)` → `noteAssistantSpoke`, `:3864`); the transcript-recording policy (`recordTranscript`, `:741`) is unchanged. **No new egress**: the feature adds zero network calls; the only network touched by a merged command is the existing music path (Spotify-feature owned), carrying the user's own words through the same seam a directly-spoken music request already uses.

### 27. Configuration parameters

| Knob | Default | Home | Notes |
|---|---|---|---|
| `DialogueConfig.maxProbes` | 2 | `DialogueManager.swift` | OD-M1; counts probes spoken |
| `DialogueConfig.maxCandidates` | 3 | same | FR-MTC-004 |
| `DialogueConfig.maxSlotOptions` | 4 | same | FR-MTC-003 |
| Answer window | `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` = 45 s | state machine `:93-96` | single source for both windows and both the frame deadline and the timer (injected into `DialogueManager.init`); never a new literal |
| Re-probe window refresh | same 45 s value | same | `noteAttempt` restamp + `refreshSlotAnswerWindow` (L2-D6) |
| `InputSanitiser.maxLength` | 200 Characters | `InputSanitiser.swift` | existing; the raw-answer length bound (L2-D5) — not raised |
| Capture timeout / watchdog | 22 s / 60 s | `VoicePipeline` / `AppCoordinator` `:4865` | unchanged envelopes; the watchdog only fires while the session is `.listening`, and the window state is not `.listening`, so a live frame coexists exactly as a confirmation window does today |
| `maxMusicQueryLength` | 100 | `KeywordIntentRule.swift:722` | unchanged |
| Catalog resource | `DialogueOptionCatalog.json`, version 1 | app bundle | §11 |

**Threading contract.** Frame reads/writes: main queue only (router turn + coordinator hooks). Timer: a `Task` cancelled on every resolution, re-checking window state before firing (F6 guard); it can only clear an already-clear frame (silent by design). Turns never overlap (single in-flight utterance), so no lock, actor or atomic is introduced anywhere.

### 28. Security-review focus mapping (workflow gates)

| Workflow focus area | Where this design answers it |
|---|---|
| Emergency precedence mid-dialogue | §21 step 2 (check above the block, unchanged); §12.3 (post-dispatch clear only); §18 `E2` (dispatch with the clear forced to a no-op); hostile corpus remains full of emergency-phrase answers |
| Free-text answer injection | §22 `S1`–`S6` (sanitise + seam before any use, L2-D5/D14); answers can only fill a slot value or pick an enumerated candidate — never select an execution path (§9 `C5`); candidate lists are restricted to the four safe fast-path domains by construction (§10) |
| Frame-trap resistance | §24 (cancel/escape/barge-in/exhaustion tables), §25 (silent expiry + re-arm), §21 guarantees; one-deep, no persistence |
| Log sanitisation | §26 (closed vocabularies, seven keys, FEATURE_ROOTS + fixtures) |
| No new egress | §26 last paragraph; zero new calls; answers reuse the existing music-search seam |
| Degraded-brain path | §4 deterministic-first (the answer turn returns before the interpreter); PR #156 ladder untouched (no new residents; no model consulted) |

---

## Traceability — every requirement mapped

All 32 requirements (FR-MTC-001…020, NFR-MTC-001…012) are touched; none is silently dropped.

| Requirement | Component(s) | Interface (exact symbol) | Test seam |
|---|---|---|---|
| FR-MTC-001 frame lifecycle | C-MTC-01, C-MTC-08 | `DialogueManager.arm/liveFrame/resolve`, `startDialogueFrame` | `DialogueFrameTests` lifecycle rows |
| FR-MTC-002 degenerate detection | C-MTC-06, C-MTC-05 | `musicQueryOutcome`, `fireMusicRequestOrProbe` | `KeywordIntentRuleTests` provenance; `CommandRouterMusicTests` intake rows |
| FR-MTC-003 slotFill probe | C-MTC-01, C-MTC-04, C-MTC-09 | `DialogueProbeComposer.probeText`, catalog group, keys §16 | `DialogueFrameTests` composition; `DialogueOptionCatalogTests` |
| FR-MTC-004 candidateChoice | C-MTC-03, C-MTC-05 | `DialogueCandidateBuilder.build`, `speakDialogueDidYouMeanOrReprompt` | `DialogueCandidateBuilderTests`; `CommandRouterDialogueTests` trigger rows |
| FR-MTC-005 capture forms | C-MTC-02 | `DialogueAnswerPath.classify` vectors `V1`–`V7`, `V13` | `DialogueAnswerPathTests` (one test per form) |
| FR-MTC-006 merge/execution | C-MTC-02, C-MTC-05 | `DialogueMerge`, `executeDialogueAnswer`, `merging(message:)` | `DialogueAnswerPathTests` (`V4` owner example); `CommandRouterMusicTests` merged-dispatch rows |
| FR-MTC-007 probe budget | C-MTC-01, C-MTC-05 | `DialogueConfig.maxProbes`, exhaustion §24 | `DialogueFrameTests` attempts; `CommandRouterDialogueTests` exhaustion rows |
| FR-MTC-008 escape | C-MTC-02, C-MTC-05 | `.escape`, `dialogue.escape` ack | `DialogueAnswerPathTests` `V8`; router escape row |
| FR-MTC-009 interception | C-MTC-05, C-MTC-08 | §12.2 block, `activeDialogueFrame` | `CommandRouterDialogueTests` placement rows |
| FR-MTC-010 cancel | C-MTC-02, C-MTC-05 | `cancelTokens`, `.cancel`/amendment | `DialogueAnswerPathTests` `V9`–`V11` |
| FR-MTC-011 emergency | C-MTC-05, C-MTC-08 | emergency block + `.emergency` clear | `CommandRouterDialogueTests` `E2`; hostile corpus |
| FR-MTC-012 barge-in | C-MTC-02 | `isBargeIn` rows `B1`–`B7` | `DialogueAnswerPathTests` one test per row |
| FR-MTC-013 timeout | C-MTC-07, C-MTC-08 | `onSlotAnswerTimeout`, silent handler | `VoiceSessionStateMachineTests`; router timeout rows |
| FR-MTC-014 awaitingSlotAnswer | C-MTC-07 | `openSlotAnswerWindow`, edges §25 | `VoiceSessionStateMachineTests` state rows |
| FR-MTC-015 catalog | C-MTC-04 | `DialogueOptionCatalog` + schema §11 | `DialogueOptionCatalogTests` (incl. bundle gate) |
| FR-MTC-016 template probes | C-MTC-01, C-MTC-09 | `DialogueProbeComposer` | composition rows; `L10nCatalogCoverageTests` |
| FR-MTC-017 cache bypass | C-MTC-05 | structural return before interpreter | `DialogueCacheBypassTests` |
| FR-MTC-018 Phase 2 v17 | C-MTC-12 | `frameClause` plumbing §19 | Phase 2 change set (not Phase 1) |
| FR-MTC-019 Phase 3 | C-MTC-13 | slot-parametric factories §20 | Phase 3 change set |
| FR-MTC-020 DV gate | all | DV-1…DV-5 (L1 §6) + Phase 0 smoke | device validation on Anzaan |
| NFR-MTC-001 turn envelope | C-MTC-07, C-MTC-08 | 22 s / 45 s / 60 s unchanged §27 | timeout-injection tests |
| NFR-MTC-002 prompt budget | C-MTC-12 | §19 budget arithmetic | Phase 2 pins; Phase 1 zero prompt delta |
| NFR-MTC-003 no egress | C-MTC-05 | §26 statement; no new call sites | egress grep gate (existing); router tests |
| NFR-MTC-004 log safety | C-MTC-05, C-MTC-10 | §26 vocabularies; FEATURE_ROOTS §17 | gate fixtures; `DialogueHostileCorpusTests` log rows |
| NFR-MTC-005 degraded brain | C-MTC-05, C-MTC-08c | §4/§28 deterministic-first | `DialogueAnswerPathTests` (no model touched — structural) |
| NFR-MTC-006 localisation | C-MTC-09 | §16 (16 keys) | catalog completeness (both languages) |
| NFR-MTC-007 jetsam | C-MTC-08 | no new residents §27 | DV-5 (PR #156 protocol) |
| NFR-MTC-008 sanitisation/injection | C-MTC-02, C-MTC-08c | `prepareDialogueAnswerText`, L2-D5 | `IntentTranscriptPreparationTests`; hostile corpus |
| NFR-MTC-009 voice-only accessibility | C-MTC-01, C-MTC-09 | spoken options + index words §22 | `DialogueFrameTests` composition rows |
| NFR-MTC-010 trap resistance | C-MTC-01, C-MTC-07 | cancel/escape/barge-in/expiry §21/§24/§25 | trap rows; DV-2/DV-3 |
| NFR-MTC-011 KV prefix | C-MTC-12 | §19 insertion point | Phase 2 mirror/digest gates |
| NFR-MTC-012 no regression | all | §18 pins; §12.4 edit list is the full router diff | golden/prompt/confirmation suites unchanged |

## Technical risks and mitigations

| # | Risk | Mitigation (implemented where) | Residual |
|---|---|---|---|
| 1 | The interception block perturbs the confirmation flow | The hook is byte-identical; the block sits after its closing brace; extended clear is limited to the emergency branch as a side-effect-only line (§12) | Router-diff review at `review-implementation` |
| 2 | Barge-in false negatives trap a user who speaks a real command mid-frame | Predicates are conservative by design; the 45 s window + cancel + escape always recover; ambiguity is an answer (never a drop) | Accepted; DV-3 |
| 3 | `sensitiveCallPhrases` false positives drop a legitimate answer as barge-in | The fall-through path speaks an honest blocked/other line (never silence, never a wrong execution); the frame is gone, so the next utterance is fresh | Accepted, bounded |
| 4 | The answer strip mis-keeps a marker so a degenerate query executes | `V5`/`V6` pin marker-only invalidity; a merged free-text value executes through the same honest music outcome matrix as any query | None at merge level |
| 5 | Free-form on candidateChoice weakens "always accepted" | L2-D9 applies it to the domains whose own extractors claim the text; elsewhere the user gets one honest re-probe, then the honest exhausted line — never a fabricated execution | Flagged for `review-l2` (risk 11 in the table below) |
| 6 | Re-probe timing vs the watchdog | The window state is never `.listening`; the watchdog only fires there; total windows bounded at 2 (§27) | None |
| 7 | Catalog data drift (aliases miss pronounced forms) | Matching vocabulary is data: extendable without code; the degraded probe (free-text-only) keeps the flow working with an unloadable catalog | Accepted; catalog copy review (§6 gap 3) |
| 8 | Event metadata smuggling a transcript fragment | All seven keys have fixed vocabularies or bounded integers; the hostile corpus + gate fixtures assert no content | Gate's documented static limits |
| 9 | New files missed by the Xcode targets | `project.pbxproj` edits (app target: 6 new Swift files + the JSON resource; test target: 8 new test files) are part of the change set | Build-time detection |
| 10 | `IntentTranscriptPreparation` drifts from `turnInput` behaviour | Parity suite `T1`–`T4` compares both callers on the same fixtures; `plainText(for:raw:)` untouched | None |
| 11 | R3's reading (candidateChoice exhaustion closes honestly) vs FR-MTC-007's literal wording | Table §24; reconciliation note §6 R3 | Reviewer confirms the reading at `review-l2` |
| 12 | A frame left live across a Talk-button recovery or watchdog recycle | `supportsTalkReset` false in the state; any session transition out resolves `.superseded` through the coordinator funnel; readings are expiry-checked | None (tested) |

## Not in this design

Explicit boundary (the L1 out-of-scope list and Feature Constraints, restated as non-goals):

- No training run, no model change, no prompt change in Phase 1 (the §19 interface is Phase 2 only; Phase 1 ships zero prompt files).
- No open-ended conversation/chat; no transcript history in prompts; no model-generated probe text.
- No new network egress, no cloud/BYO-LLM path, no new storage or persistence of dialogue state (in-memory, one-deep, cold start = no frame).
- No changes to reminder/calendar behaviour (Phase 3 is separately scoped), no RepetitionGuard edits, no new UI (probes are replies), no Android/platform scope.
- No database migrations, no new encrypted-store keys, no auth changes — the merge cannot authenticate, cannot bypass a confirmation tier, and cannot reach a sensitive action except through that action's existing gate.
- No edits to the emergency/medication surfaces beyond the single side-effect clear line of §12.3; no new observability components, no `LogSanitiser.allowedKeys` change beyond the seven §26 keys.
- No edits to the pinned test surfaces: `IntentPrompt.swift`'s template, `GoldenCorpus.swift`, the seed mirror, and the Spotify/YouTube/confirmation suites are untouched in Phase 1.
