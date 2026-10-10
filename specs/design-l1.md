# L1 Architecture — Multi-Turn Conversation (v1)

**Feature:** `multi-turn-conversation` · **Branch:** `feat/multi-turn-conversation` (worktree `elderly-ai-assistant-multi-turn-conversation`, requirements baseline `437d4dc`)
**Task:** `design-l1` (agent `sdd-architect`) · **Contract:** `architecture_l1` → `specs/design-l1.md`
**Date:** 2026-10-10 · **Status:** for review; feeds `design-l2`, `review-l2` and `security-design-review`
**Resolves (design-owned):** the interception seam and its strict ordering (§10), the frame model (§9), degenerate-query detection (§12), the did-you-mean assembly (§13), the answer window + silent timeout (§14), the catalog format (§15), degradation survival (§16), the Phase 2 clause budget/mirror (§17), cache bypass (§11, §19), log-gate coverage (§22).
**Drafts (owner-facing, final T2):** OD-M1 probe policy, OD-M2 option source, OD-M3 sequencing, OD-M4 Phase-3 scope → §5. All four stay **OPEN** per the feature constitution; the feasibility study's recommendations are the design defaults; the owner re-confirms at final sign-off.

**Inputs folded in.** The feature constitution (`specs/multi-turn-conversation/` `constitution.md` — probe kinds, the answer-turn contract, the frame shape, Safety-Relevant Constraints 1–4, Feature Constraints 1–10, the DV gate, OD-M1..M4); the root `constitution.md` (Architecture Constraints 1–6, Standards, release gates, Agent Principles); `specs/define-requirements.md` (FR-MTC-001…FR-MTC-020, NFR-MTC-001…NFR-MTC-012, 97 Gherkin scenarios — locked, `specs/define-requirements.lock.yaml`); `docs/multi-turn-conversation-feasibility.md` (§2 today's behaviour, §4 existing mechanisms, §5 hard constraints, §6 recommended design, §7 phasing, §9 ODs); and `.ai-sdd/workflows/multi-turn-conversation.yaml` (the `design-l1` obligation list and the `security-design-review` focus areas). Every line reference below was re-verified against this worktree at `437d4dc` for this document (§7).

**Path convention.** Paths are repo-relative. Where a single path would exceed the release-log sanitiser's token limit (SEC-002: 40 consecutive characters from the class `[A-Za-z0-9/+=]`), it is split across adjacent code spans; `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` denotes the single path obtained by joining the spans with `/`. The split is a sanitizer convention only — do not read the `+` as concatenation in code.

---

## Overview

### 1. Purpose and the broken-to-working flip

Today the voice pipeline is strictly single-turn: `route(transcript:)` (`ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift:740`) turns one transcript into one `RoutingResult`; no state survives the turn. Two user-visible failures follow, both verified at this baseline:

- **The music path guesses.** For a bare "भजन बजाऊ" the extractor's never-empty fallback (`KeywordIntentRule.swift:764-775`) returns the bare marker `"भजन"`, the ladder arm fires `fireMusicRequest(query:)` with it (`CommandRouter.swift:1233` → `:2667` → `runMusicTurn` `:2684`), and the outcome is the literal top search hit (`selectMusicOutcome` `:2614`). The user asked for *a bhajan*; Pip plays *whatever ranks first*.
- **The not-understood path dead-ends.** `routeKeywordRemainder` speaks the honest-but-stateless `router.reprompt` (`:2021`), and the rephrase-discard branch speaks `router.rephrase.discard` (`:806-809`). Both tell the user Pip failed; neither helps them succeed.

The flip is a bounded, one-deep **dialogue frame**: a short template probe ("कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्"), the user's spoken answer captured by name / index word / repetition / free text, a **deterministic merge** of the answer into the pending command, and execution through the existing music path — the owner's example ("play bhajans" → probe → "dasain durga bhajans" → correct playback) working end-to-end in Phase 1 with no training run. The same frame answers the second owner requirement: when Pip does not understand, it says so **and** offers voice-pickable candidate interpretations (didYouMean) instead of the dead-end line.

The architectural shape is deliberately small and brownfield-faithful: one new in-memory frame type, one new pre-ladder interception block that generalizes the existing confirmation hook, one new session state beside `awaitingConfirmation` reusing its 45 s timer, one bundled option catalog, zero model-stack change in Phase 1, zero new network egress, and no new UI (probes are spoken through the existing reply lane and appear in the chat history like any reply — `speak(text:)` already calls `coordinator?.noteAssistantSpoke(text)` at `CommandRouter.swift:3864`).

### 2. Scope

**In scope (Phase 1 — deterministic MVP, shippable alone):**

- `DialogueManager` + `DialogueFrame` (`probeKind` `.slotFill` / `.candidateChoice`, `slot`, `activeCommand`, `candidates`, `attempts`, `deadline`) — one-deep, in-memory, coordinator-owned (FR-MTC-001; §9).
- Pre-ladder answer interception placed at the confirmation hook's position, with emergency absolute above it (FR-MTC-009/011; §10).
- Answer capture — option name, index word, repetition, free-form — and the deterministic merge (sanitise → strip scaffolding → catalog canonicalise → merge → dispatch `fireMusicRequest` → `runMusicTurn`) (FR-MTC-005/006; §11).
- Degenerate music-query detection on both intake routes — the ladder arm and the interpreted `.music` action (FR-MTC-002; §12).
- The didYouMean probe upgrading the two `routeKeywordRemainder`-family dead ends (FR-MTC-004; §13).
- The `awaitingSlotAnswer` session state with the reused 45 s timer, silent expiry and re-arm (FR-MTC-013/014; §14).
- The curated on-device option catalog (FR-MTC-015; §15), template probes ne/en (FR-MTC-003/016; §9, §22), the probe budget (FR-MTC-007; §11), the escape (FR-MTC-008; §10), cancel (FR-MTC-010; §10), barge-in (FR-MTC-012; §10), cache bypass (FR-MTC-017; §11, §19).
- Focused tests mirroring the confirmation-protocol suites, and the DV-* device gate (FR-MTC-020; §29, §6).

**In scope (later phases, designed but not shipped now):** Phase 2 — follow-up NLU fine-tune v17 with the frame clause inside the pinned prompt (FR-MTC-018; §17); Phase 3 — the same frame path over the stateless reminder/calendar missing-slot re-prompts plus RepetitionGuard interplay (FR-MTC-019; §18).

**Out of scope (must not change):** open-ended conversation/chat; raw transcript history in prompts; model-generated probe text; cloud/BYO-LLM anything; persistent dialogue state across sessions; reminder/calendar turn behaviour in Phase 1; any new network egress; the on-device stance and existing encrypted stores; any new compliance regime. Emergency and medication behaviour is byte-for-byte today's in every phase.

### 3. Inherited binding constraints → design response

| # | Constraint (verbatim gist) | Design response | Where |
|---|---|---|---|
| S1 | Emergency precedence is absolute; hostile answer cannot sidestep it | Emergency check stays exactly at `CommandRouter.swift:779-783`, **above** the new frame block; the frame clear is a post-dispatch, side-effect-only statement (never a condition); all answer text is data, never control flow | §10, §24 |
| S2 | Frames must never trap the user | Cancel → drop + honest line; escape → drop + re-capture ack; strong barge-in → drop + execute new command; ambiguous → answer; 45 s silent timeout; one-deep; no persistence; interception-time deadline check (no half-open window) | §10, §14 |
| S3 | Privacy & log-safety stance unchanged | No new egress; answer text through the existing `InputSanitiser` seam before any use; no probe/answer text in logs or events; B2/T-050 precedent; the release-build log gate extended to the new files | §21, §22 |
| S4 | Security-review focus is the answer-capture path | STRIDE pre-map (§24); answer text can only fill a slot or pick from a pre-built enumerated candidate set — it never selects an execution path | §11, §13, §23, §24 |
| 1 | 1024-token ceiling; dialogue state in the app, never transcript history in prompts | Frame is app-side state only; Phase 1 adds **zero** prompt tokens; Phase 2 clause ≤300 Characters inside the ~300-token headroom | §9, §17 |
| 2 | Template probes only, localized ne/en; the model never writes probe text | `DialogueManager` composes probes from `dialogue.*` xcstrings keys + static separators; the model is not consulted on any Phase 1 probe or answer turn | §9, §22 |
| 3 | Probe budget: ≤2 probes then execute with defaults; ≤3–4 options (slotFill), ≤2–3 (candidateChoice); free text always accepted | `DialogueConfig.maxProbes = 2`, `maxSlotOptions = 4`, `maxCandidates = 3`; default option on probe 1; exhaustion table (§11) | §9, §11, §20 |
| 4 | Deterministic merge works with the brain absent or degraded; PR #156 hardening intact | Phase 1 answer turn never consults the brain (structurally: the frame block returns before the interpreter); no new residents; pressure-tiered picks and the per-turn STT release are untouched | §16 |
| 5 | The Phase 2 clause ships only with v17; byte-identical seed mirror; `.raw` framing unaltered | The clause is the 5th interpolation; seed + mirror gate + digest pins updated in the **same** change; no clause without training data | §17 |
| 6 | KV-prefix stability | The clause is inserted after the `User said:` line, before the closing imperative; the stable template prefix stays byte-identical | §17 |
| 7 | Cache bypass during `awaitingSlotAnswer`; only confirmed merged commands are recordable | The answer turn returns before the interpreter/cache; `pendingTranscript` stays `nil` on the frame execution path so no answer text can teach the cache | §11, §19 |
| 8 | Delivery gates: focused tests + typecheck per unit; full suite once at the end; DV on Anzaan | Test plan §29; DV-1..DV-5 §6; Phase 0 note §25 |
| 9 | Phase 0 prerequisite: PR #156 device smoke outstanding | Phase 0 gate recorded in §6/§25 — run before Phase 1 device validation | §6, §25 |
| 10 | iOS only | No platform scope; all work in the existing app target and test bundle | §25 |

### 4. Decision log

Full ADR entries for the load-bearing decisions; each records the alternatives and why they lost.

| ADR | Decision (one line) |
|---|---|
| ADR-MTC-01 | One-deep `DialogueFrame` (value type) owned by the coordinator via `DialogueManager`, in memory only, never in prompts; both probe kinds share the same interception, capture and merge path. |
| ADR-MTC-02 | The answer interception is a new block at the confirmation hook's structural position — immediately **after** the hook's closing brace (`CommandRouter.swift:886`) and **before** the safety net (`:897`) — with emergency unchanged above it; the emergency branch gains a post-dispatch frame clear. |
| ADR-MTC-03 | Confirmation window and frame window are mutually exclusive by construction (arming a frame asserts no pend; pending a confirmation clears any frame); the confirmation flow stays byte-for-byte today's. |
| ADR-MTC-04 | The answer turn is fully deterministic in Phase 1: classify (deadline → escape → cancel/amendment → barge-in → answer → invalid), then merge. No model call on the answer turn. |
| ADR-MTC-05 | Barge-in is defined as "a deterministic ladder stage would claim this utterance, and it is not the frame's own domain" — evaluated with the stages' existing **pure** decision functions, never by invoking side-effecting executors. |
| ADR-MTC-06 | Degenerate detection reads the extractor's **provenance** (`.content` / `.markerFallback` / `.transcriptFallback`), never re-derives it; both intake routes share one trigger helper. |
| ADR-MTC-07 | Candidate assembly is deterministic and restricted to the safe fast-path domains (news, YouTube, music, appLaunch); candidates execute through the same seams the ladder uses; `candidateChoice` exhaustion closes honestly (nothing to execute), while `slotFill` exhaustion executes the pending command with its default query. |
| ADR-MTC-08 | `awaitingSlotAnswer` is a sibling state with its own opener (`openSlotAnswerWindow()`), its own timer (same 45 s config value) and its own **silent** expiry callback; expiry differs deliberately from the confirmation timeout's spoken line. |
| ADR-MTC-09 | The option catalog is a bundled JSON resource (ids + queries + alias tokens) with **all spoken labels in `Localizable.xcstrings`** — one localisation source of truth; matching is whole-token, never Devanagari substring. |
| ADR-MTC-10 | Phase 1 adds no brain dependency anywhere on the dialogue path; the PR #156 ladder (per-turn STT release, pressure-tiered picks) is untouched; brain-assisted frame merge is Phase 2 only. |
| ADR-MTC-11 | Cache bypass is structural: the answer turn returns before the interpreter, and frame execution never sets `pendingTranscript` — answer text cannot be interned by `IntentCommandCache`. |
| ADR-MTC-12 | Phase 2 clause: inserted between the `User said:` line and the closing imperative as the 5th interpolation; ≤300 Characters; byte-identical seed mirror; `check-prompt-mirror` anchors + digest pins + the 2_506 baseline updated in the same change; the 3_000-Character ceiling is **not** raised. |
| ADR-MTC-13 | Probes speak through the existing `speak(text:)` lane (`noteAssistantSpoke` parity, chat history, no new UI); every string is a `dialogue.*` key; the timeout speaks nothing. |
| ADR-MTC-14 | Observability uses closed-vocabulary events (`dialogue_probe_spoken`, `dialogue_answer`, `dialogue_frame_resolved`, `dialogue_degenerate_query`) with count/enum metadata only; the new files join the release-log gate's `FEATURE_ROOTS` with a fixtures entry. |
| ADR-MTC-15 | Phase 3 (reminder/calendar rollover) reuses the frame path unchanged, with a dedicated slot vocabulary; it ships separately (OD-M4) and Phase 1 registers no such trigger. |
| ADR-MTC-16 | All frame state is main-queue-confined (the `VoiceSessionStateMachine` contract); probes speak through the actor `ReplySpeakLane`; the timeout `Task` is cancelled on every resolution and re-checks window state before firing (the F6 guard pattern, `VoiceSessionStateMachine.swift:191-198`). |

#### ADR-MTC-01 — One-deep dialogue frame, coordinator-owned, in memory only

**Decision.** A single `DialogueFrame` value held by a `DialogueManager` (a small class) that the coordinator owns, mirroring the existing pending-command ownership pattern (`AppCoordinator.swift:7395-7401` pending rephrase; read by the router through `VoiceCommandCoordinating` hooks such as `isAwaitingConfirmation`, `AppCoordinator.swift:10535-10539`). The frame carries exactly the constitution's fields:

| Field | Type | Meaning |
|---|---|---|
| `probeKind` | `.slotFill` / `.candidateChoice` | which probe was asked |
| `slot` | `DialogueSlot` (`.musicQuery` in Phase 1) | what the probe asked for |
| `activeCommand` | `InterpretedCommand?` | the pending resolved command (nil for a pure didYouMean frame) |
| `domain` | `KeywordIntentRule.Domain?` | the frame's own domain (barge-in exclusion set) |
| `candidates` | `[DialogueCandidate]` | the pre-built enumerated options (candidateChoice) |
| `defaultQuery` | `String?` | slotFill: the pending degenerate query — the "just play anything" resolution |
| `attempts` | `Int` | probes spoken so far (capped by `DialogueConfig.maxProbes`) |
| `deadline` | `Date` | 45 s from probe speech (`VoiceSessionStateMachine.Config.confirmationTimeoutSeconds`) |

**Why a structured frame and not a fifth `pending*` field:** the existing one-deep `pending*` state (`pendingRephrase`, `pendingCallAction`, `pendingCalendarEvent`, `pendingNavigationWalk`, `pendingAppLaunch`) is a family of ad-hoc optionals each with its own handling. This feature adds a dialogue *shape* (two probe kinds, candidates, attempts, a deadline) that the next feature (Phase 3) extends by adding a slot case, not another optional. The frame is deliberately **in-memory and main-queue-confined**: no persistence (cold start ⇒ no frame; FR-MTC-001 scenario 3), no transcript history, nothing serialisable to disk.

**One-deep invariant, enforced structurally:** every probe trigger sits on the ladder *below* the interception block (§10). If a frame is live, the interception consumes or falls through the utterance before any trigger can run; a barge-in clears the frame before the ladder executes. Trigger code additionally guards `activeDialogueFrame == nil` (defensive). A resolution may *chain* into a new frame (e.g. picking a music candidate whose query is itself degenerate triggers the slotFill probe) — sequentially, never nested: the old frame is fully cleared before the new probe is spoken.

#### ADR-MTC-02 — The interception seam: position, ordering, and the emergency clear

**Decision.** Insert the dialogue block between the confirmation hook (closing brace at `CommandRouter.swift:886`) and the safety-net comment (`:888-899`). Resulting `route()` order — everything above the new block and everything below it keeps today's code:

1. `TranscriptSanityGuard` (`:747-758`) — unchanged, still first.
2. Emergency keywords (`:779-783`) — unchanged position, unchanged dispatch; **plus one new side-effect-only statement after `handleEmergency()`**: `coordinator?.clearDialogueFrame(reason: .emergency)`.
3. Confirmation hook (`:789-886`) — byte-identical, untouched.
4. **Dialogue-frame interception (NEW)** — §10's classifier.
5. Safety net (`:897-899`) — unchanged; this is why med-ack and sensitive-call vocabulary still win when an answer is ambiguous, and why barge-in falls *through* to it.
6. Contact search (`:916-920`), directions, alarms, YouTube (`:1164-1167`), keyword-intent stage (`:1169-1244`), topic/interpreter (`:1488…`), `routeKeywordRemainder` (`:1968-2030`) — unchanged except the two designated probe-trigger edits (§12, §13).

**Why *after* the confirmation hook rather than between emergency and the hook:** the two windows are mutually exclusive (ADR-MTC-03), so the relative order between them is behaviourally immaterial; placing the block after the hook keeps the hook's 100-line body byte-identical (zero regression risk to the confirmation flow, NFR-MTC-012) and reads top-down ("confirmation answers first, then dialogue answers, then the ladder").

**Why the emergency clear is safe (S1, FR-MTC-011):** the clear runs *after* `handleEmergency()` has already been dispatched, is non-throwing and side-effect-only, and contributes no condition, delay or gate to the emergency path. A frame left armed across an emergency would strand the window (the next utterance would be parsed as a stale answer); a clear placed *before* dispatch would put frame machinery *in front of* the emergency path — forbidden. A test pins that emergency dispatch is unaffected, and that an emergency utterance with a live frame leaves no frame (§29).

**Emergency detection stays only where it is.** `emergencyPhrases` (`:1855`) is checked at `:779-783` and again inside `routeKeywordRemainder` (`:1936`); both checks are unchanged. The frame classifier never inspects emergency phrases itself — the check has already run above it on every utterance.

#### ADR-MTC-04 — The answer turn is deterministic; classification precedence is fixed

**Decision.** `DialogueAnswerPath.classify` runs this ordered ladder on the prepared utterance (the raw transcript having passed sanitise + seam, §11):

1. **Deadline** — `frame.deadline <= now` ⇒ drop the frame silently and **fall through** (the utterance is a fresh command; the utterance-arrives-just-before-expiry case is an answer because the frame block reads a live frame). This is the half-open-window guarantee (FR-MTC-013 scenario 3) and the last-resort anti-trap backstop.
2. **Escape** — the localized "no — let me say it again" phrase ⇒ drop frame + speak `dialogue.escape` + re-arm listening; nothing executes (FR-MTC-008). Checked before cancel because the escape phrase embeds a negation.
3. **Cancel / amendment** — a leading negation from the existing `isNoResponse` vocabulary (`CommandRouter.swift:3809`): with **no content after it** ⇒ drop frame + speak `dialogue.cancelled` + nothing executes (FR-MTC-010); **with content** ("होइन, दुर्गा भजन") ⇒ the content is an answer (the no-with-amendment precedent, `:816-820`), so the bare-cancel branch must not swallow it. Bare cancel resolves even at the attempt cap (scenario 2); the default execution does not fire on a cancel.
4. **Barge-in** (ADR-MTC-05) — drop the frame and **fall through**: the utterance executes through the normal ladder exactly as today, subject to the normal tiers (FR-MTC-012).
5. **Answer** — capture forms §11; a valid answer merges and executes.
6. **Invalid** — content resolved to nothing (empty after the scaffold strip, or a degenerate-answer value, §11) ⇒ `attempts += 1`; while `attempts < maxProbes` re-probe (`dialogue.retry` prefix + the same question body); on the cap, exhaustion resolution (§11 table). Ambiguity is never a drop: an utterance that is not a strong different-command match is an answer attempt (FR-MTC-012 scenario 2).

**Gibberish-guard interaction (recorded behaviour):** an utterance rejected by `TranscriptSanityGuard` (`:747-758`) never reaches the frame block; the guard speaks `router.reprompt` and the frame **stays armed with no attempt consumed** (noise is not an answer attempt). The 45 s deadline bounds the window regardless, and the next utterance is still an answer. No new guard code.

#### ADR-MTC-05 — Barge-in is defined with pure stage decisions, never by re-running executors

**Decision.** `DialogueAnswerPath.isBargeIn(prepared, frame:)` is true iff any of the following holds, evaluated with **side-effect-free** predicates only (each is the same decision function its ladder stage uses — single source, no vocabulary duplication):

- `CommandRouter.isExplicitMedicationAcknowledgement(utterance)` (`:1913`) — the F3 discipline: a dose acknowledgement mid-probe is a barge-in, never an answer (the app-launch window learned this; `CommandRouter.swift:847-862`).
- `sensitiveCallPhrases` match (`:1869`, via `containsPhrase` `:1826`) — sensitive-call blocking keeps its behaviour (it will block below, unchanged).
- `VoiceContactSearchRoute.decide(transcript:) != .notSearch` (`ios/ElderlyAssistant/Services/` + `Voice/VoiceContactSearchRoute.swift:67`) — e.g. "मैयाको फोन नम्बर खोज".
- `YouTubeRoute.decide(transcript:)` returns `.play` (`CommandRouter.swift:1164`).
- `KeywordIntentRule.match(transcript:)` (`KeywordIntentRule.swift:164`) resolves a domain **≠ the frame's own domain** (news / YouTube / appLaunch all barge in; **music never does** — FR-MTC-005 scenario 3: "दुर्गा भजन बजाऊ" mid-frame is an answer, not a new command).

The classifier must **not** call `routeSafetyNet` (`:1931`) or any executor (they act); it mirrors their vocabulary with pure statics. On barge-in the frame block returns nothing (falls through) and the stage below executes exactly once. **Ambiguity defaults to answer** — the predicate is deliberately conservative.

#### ADR-MTC-06 — Degenerate detection reads extraction provenance

**Decision.** `KeywordIntentRule` gains `musicQueryOutcome(from:maxLength:) -> MusicQueryExtraction { query: String?, provenance: .content | .markerFallback | .transcriptFallback }` — the existing three-step fallback (`:764-775`) restructured to report *which* step produced the query; `musicQuery(from:maxLength:)` becomes a thin wrapper returning `.query`, so its return values (and every existing test) are byte-identical. **Degenerate ⇔ provenance ≠ `.content`** (the bare-marker fallback, or a query that canonicalised away and would fall back to the raw transcript). Specific queries keep today's behaviour exactly (FR-MTC-002 scenario 2, NFR-MTC-012). On the interpreted route the model's own `message` entity, when non-empty (`CommandRouter.swift:3350-3352`), counts as `.content` and passes through (§12).

#### ADR-MTC-07 — Candidate assembly, eligibility, and exhaustion resolution

**Decision.** `DialogueCandidateBuilder.build(for:excludingDomain:rephraseHypothesis:)` produces ≤ `DialogueConfig.maxCandidates` (3) candidates from deterministic sources, in priority order:

1. **The rephrase-band hypothesis** — the mid-band (confidence < 0.7, tier `.free`) interpretation the pipeline already computed (`CommandRouter.swift:1493-1519`). Placement: as today it becomes a yes/no question (`:1513`, unchanged); when the user answers **no** (`:806-809`), the taken hypothesis joins the candidate list **only when relaxed near-matches contribute at least one other candidate** (ordered last) — a re-offer alongside alternatives, never alone (re-asking a just-denied single option would ignore the "no": a trap). If it is the only possible candidate, today's `router.rephrase.discard` line stands alone. *Alternative considered and rejected:* converting the yes/no itself into a candidate probe — it would change the confirmation flow the constitution freezes (NFR-MTC-012, FR-MTC-014 scenario 3).
2. **Relaxed near-matches** — a new pure `KeywordIntentRule.nearMatches(transcript:)` reporting the rule's own domains that *partially* co-occur (at least one required keyword group present, not all), each rendered from a fixed `dialogue.candidate.*` template; an eligible domain must be executable with the utterance's own extracted query (no query invented).
3. **The active frame's candidates** — the re-probe case (the same list, re-offered).

Eligibility is restricted to the safe fast-path domains {news, YouTube, music, appLaunch}: **a candidate can never carry `.call` / `.sendMessage` / `.setReminder` / `.createCalendarEvent` or any `neverGated` action**, so picking a candidate can never bypass a confirmation tier (§23). Execution of a pick goes through the **same seam the ladder uses for that domain** (`fireNewsReader`, `fireYouTubePlay`, `fireMusicRequest`, the launcher's `requestAppLaunch`-equivalent) — "executed exactly as if it had been understood as that command" (FR-MTC-004 scenario 2) with byte-identical outcome paths.

**Never fabricate (FR-MTC-004 scenario 3):** an empty candidate list ⇒ no frame opened; the honest line (`router.reprompt` / `router.rephrase.discard`) stands alone, today's behaviour.

**Exhaustion resolution (FR-MTC-007 reconciliation).** Each frame carries its terminal default:

| Frame | On attempt-cap exhaustion with no valid answer |
|---|---|
| `.slotFill` with `activeCommand` | Execute the pending command with its default behaviour — the default query (the pending degenerate query); the user hears the normal execution outcome. |
| `.candidateChoice` (no pending command) | Close the frame and speak the honest `dialogue.exhausted` line, then re-arm. There is no pending command to execute; executing a candidate unasked would be exactly the trap the requirements forbid (FR-MTC-004 "never fabricate", FR-MTC-010 "never executes unasked"). This is the design's reading of FR-MTC-007's "executes with its default behaviour … rather than asking again or dead-ending" where no default exists; flagged for review-l2 (§31 R3). |

#### ADR-MTC-08 — The window and its silent timeout

**Decision.** `VoiceSessionState` gains `case awaitingSlotAnswer` beside `awaitingConfirmation` (`VoiceSessionStateMachine.swift:9-17`), with transition-table edits mirroring the confirmation edges exactly: entry from `.idle` and the busy states (the same set that accepts `.awaitingConfirmation`, `:29-38`), exits to `[.idle, .error, .stopped]`. A sibling opener `openSlotAnswerWindow()` mirrors the F14 "the window must EXIST, not merely be attempted" discipline of `openConfirmationWindow()` (`:153-181`): bridge through `.idle`, only ever travelling legal edges. Entering the state arms `slotAnswerTimer` with the **same config value** (`config.confirmationTimeoutSeconds`, `:93-96`: 45 s — single source, no new literal); any transition out cancels it (`:119-123` mirrored).

**The expiry is silent and different.** `armConfirmationTimer`'s callback (`:183-203`) speaks nothing itself — the coordinator's `onConfirmationTimeout` handler does (`AppCoordinator.swift:2996-3038`, speaking `router.confirmationTimeout` at `:3035-3036`). For the frame window the design adds a **separate callback** `onSlotAnswerTimeout`, fired by the mirrored timer after its own F6 still-open guard (`guard self.state == .awaitingSlotAnswer`): the coordinator's handler clears the frame, emits `dialogue_frame_resolved {timeout}`, and **speaks nothing** (FR-MTC-013: silent drop and re-arm; deliberately unlike the confirmation notice). The confirmation callback and its spoken notice are untouched; `recordConfirmationTimeout()` is not called on the frame path (it is yes/no accept-band telemetry).

#### ADR-MTC-12 — Phase 2 clause inside the pinned prompt

**Decision.** The frame clause is the **5th interpolation** of `IntentPrompt.build` (`ios/ElderlyAssistant/Services/` + `Voice/IntentPrompt.swift:69-128`), inserted after the `User said: "\(transcript)"` line and before the closing `Now output ONLY the JSON object for that request.` imperative — the latest possible point, so the stable template prefix (what the vendored LLM's KV-prefix reuse depends on) stays byte-identical (NFR-MTC-011). Draft clause (feasibility study §6.4), gated behind `frameClause: String? = nil` so Phase 1 call sites are unchanged:

> `Answer to the earlier question about music. Missing detail: kind of bhajan.`

Budget: clause **≤300 Characters** (the existing slack: measured baseline 2,506, worst-case composition 2,586, ceiling 3,000 — `IntentPromptTests.swift:482-495`, `:126`), leaving ≥180 qwen3-token headroom under the 1,024-token cap (`LlamaCommandInterpreter.swift:1159-1163`, `:1199`). The same change updates: the seed mirror `tools/train-intent/seeds/prompt_template.txt` (byte-identical; the identity rule at `IntentPrompt.swift:44-55`), the `check-prompt-mirror` anchor validation (it validates each interpolation placeholder's anchors — the 5th gains anchors in the same change), and the `PinnedSurfaceGuardTests` digests + baseline Character count (`ios/ElderlyAssistantTests/Services/` + `Voice/PinnedSurfaceGuardTests.swift:57-67`, `:61`, `:63`). The 3,000-Character ceiling and the 1,024-token cap are **not** raised. The `.raw` framing (chat-format table `LlamaCommandInterpreter.swift:820-896`, framing at `:973-1000`) is untouched. A clause without the v17 training iteration does not ship (Feature Constraint 5).

### 5. Open decisions OD-M1..OD-M4 — drafted for T2

All four remain **OPEN** (the constitution is explicit); the design *implements* the study's recommendations as configurable defaults so the owner's resolution is a config/scope change, not a redesign. Owner confirms at final T2 sign-off.

**OD-M1 — probe policy (DRAFTED FOR T2).** Default: **2 probes max**, the default answer offered **on the first probe**, default wording `dialogue.option.anyPlay` = "जे पनि बजाऊ" / "just play anything". Implemented as `DialogueConfig.maxProbes = 2`; if the owner resolves to 1, the only change is the config value (all tests parameterised). *Why 2:* one unrecognised answer (a cough, a mis-transcription) would otherwise burn the single probe and execute with defaults; the second probe is the recovery. Cost: at most one extra question, bounded by the deadline.

**OD-M2 — option source (DRAFTED FOR T2).** Default: **curated on-device catalog** (§15) — zero latency, on-device stance, works with no network and no Spotify link; the live-Spotify-playlist alternative would add a network round trip *per probe* and a `SpotifyTool` extension, and its results would be model/API-generated option text (tension with "template probes only"). The catalog is a JSON resource precisely so a later OD-M2 resolution can swap or extend the source behind `DialogueOptionCatalog` without touching the frame path.

**OD-M3 — sequencing (DRAFTED FOR T2).** Default: **Phase 1 deterministic-only ships first** (it alone covers the owner's bhajan example with no training run); v17 data authoring proceeds in parallel; the Phase 2 clause attaches to the v17 change (§17). *Why:* Phase 1 is a complete, shippable unit; the clause is worthless without v17 (prompt-identity drift is the named hazard).

**OD-M4 — Phase-3 scope (DRAFTED FOR T2).** Default: **Phase 3 ships separately** — the reminder/calendar rollover (FR-MTC-019) is designed (§18) but not built with the music probe, so the Phase 1 release carries exactly one new trigger domain (music), keeping the safety review and DV scope tight. The frame and the state machine are built slot-agnostic so Phase 3 is additive.

### 6. Success criteria and the DV plan

| Success criterion (constitution) | Mechanism | Verified by |
|---|---|---|
| Owner's bhajan example works end-to-end, Phase 1, no training run | §12 trigger → §9 probe → §11 merge → existing music path | FR-MTC-002/003/006 tests; DV-1 |
| Every probe template-generated, localized ne/en; ≤2 probes then defaults | §9 probe composer; `dialogue.*` keys; `DialogueConfig.maxProbes` | FR-MTC-003/007/016 tests; §22 key inventory |
| Answers captured by name / index / repetition / free-form | §11 capture ladder | FR-MTC-005 tests (one per form) |
| Unrecognised utterance → honest line + didYouMean probe + escape | §13; §10 step 2 | FR-MTC-004/008 tests |
| Cancel drops with an honest line; emergency wins; barge-in executes; 45 s silently re-arms — zero stuck states | §10, §14 | FR-MTC-010/011/012/013 tests; DV-2/3 |
| Brain-degraded turns fall back to the deterministic merge or one more probe; reminder/calendar unchanged | §16 (structural) | FR-MTC-006 scenario 4; unchanged-suite runs |
| No jetsam across sustained multi-turn use | §16 (no new residents, no new GPU work) | DV-5; §16 |

**DV-1..DV-5 (Anzaan device gate, FR-MTC-020):** DV-1 probe → answer → correct playback (the bhajan example, one shot, owner-path). DV-2 timeout: 45 s expiry drops silently, next utterance is a fresh command. DV-3 barge-in: "मेरो छोरालाई फोन गर" mid-probe places the call (its normal confirmation runs) with no residual frame. DV-4 mid-dialogue degraded-brain turn: force the pressure pick (or unload), answer the probe; the deterministic merge carries the dialogue. DV-5 sustained multi-turn without jetsam (post-conversation JetsamEvent log pull, the PR #156 protocol). **Phase 0 prerequisite (constitution #9):** the outstanding PR #156 device smoke (conversation → no jetsam → JetsamEvent pull) runs first; its protocol is the DV-5 harness.

### 7. Source verification and reconciliations

Every seam below was re-verified in this worktree at `437d4dc` for this document (the study's references were treated as claims, not facts):

- `route()` opens at `CommandRouter.swift:740`; gibberish guard `:747-758`; **emergency block `:779-783`** (`handleEmergency()` dispatch at `:781`, `:3556`); **confirmation hook `:785-886`** (guard `:789`; rephrase follow-up `:794-809`; call-override predicate `:816-820`; `speaksItsOwnYesNo` `:830-846`; F3 med-ack exclusion `:847-862`; yes/no/ambiguous `:863-885`); safety net `:897-899`; contact search `:916-920`; YouTube stage `:1164-1167`; keyword-intent stage `:1169-1244` (**music arm `:1223-1234`**, `fireMusicRequest` call at `:1233`); rephrase band `:1493-1519` (condition `:1509-1512`, arm `:1513`); `routeKeywordRemainder` `:1968-2030` (sensitive block `:1973-1980`; web-search hook `:2004`; `router.reprompt` `:2021`; brain-downloading/needs-setup `:2024-2027`); music execution `selectMusicOutcome` `:2614`, `fireMusicRequest` `:2667-2678`, `runMusicTurn` `:2684`; `pendingTranscript` `:3307`; `dispatchInterpreted` `:3315`; **interpreted `.music` `:3336-3355`** (query composition `:3350-3355`); `handleEmergency` `:3556`; `isYesResponse` `:3801` / `isNoResponse` `:3809`; `speak(text:)` `:3848` with `noteAssistantSpoke` at `:3864`; `VoiceCommandCoordinating` protocol `:47-140`; emergency vocabulary `:1855`; `sensitiveCallPhrases` `:1869`; `isExplicitMedicationAcknowledgement` `:1913`; `routeSafetyNet` `:1931`; second emergency check `:1936`.
- `KeywordIntentRule.swift`: `maxMusicQueryLength` `:722`; `mentionsMusic` `:730-734`; `musicQuery(from:)` `:752-779` with the three-step fallback `:764-775` and the marker branch at `:770`; drop sets `:781-850`.
- `VoiceSessionStateMachine.swift` (`ios/ElderlyAssistant/App/`): enum `:9-17` (`awaitingConfirmation` `:15`); `canTransition` `:21-57`; `supportsTalkReset` `:71-78`; `Config.confirmationTimeoutSeconds` `:93-96`; `transition` `:111-127`; `transitionViaIdle` `:143-151`; `openConfirmationWindow` `:153-181`; `armConfirmationTimer` `:183-203` (F6 guard `:191-198`); `cancelConfirmationTimer` `:205-208`.
- `AppCoordinator.swift`: `onConfirmationTimeout` handler `:2996-3038` (spoken line `:3035-3036`); voice watchdog `:4865`; `noteAssistantSpoke` `:5210`; `openConfirmationWindow()` `:7019-7027`; `pendingRephrase` `:7395-7396`; `startRephraseConfirmation` `:7397-7401`; `handleCallConfirmationOverride` `:7473`; `isAwaitingConfirmation` `:10535-10539`.
- `LocalBrainChain.swift` (`ios/ElderlyAssistant/Services/` + `Intents/`): `turnInput` `:275-285` — `InputSanitiser.sanitise(_, level: .quarantine)` then `inputSeam.prepare(clean)` at `:281-282` (the answer merge's seam, §11).
- `IntentPrompt.swift`: size-budget doc `:29-42` (696 qwen3 / 677 gemma of 1,024; ~300 left), identity doc `:44-55`, `build` `:69-128`, `addressAsClause` `:142-145`. `LlamaCommandInterpreter.swift`: `.raw` kind `:820-830` region `:820-896`, framing `:973-1000`/`:1176-1184`, `maxTokenCount: 1024` `:1199` with the 2048-crash comment `:1159-1163`.
- Prompt pins: `IntentPromptTests.swift:105-131` (3,000-Character tripwire), `:257`, `:482-495` (2,506 baseline, 2,586 worst case). `PinnedSurfaceGuardTests.swift:16-47`, `:57-67` (music digest `fb14012e…`, prompt digests `18003ddd…`/`bd47910d…`, 2_506/3_000).
- Log gate: `ios/tools/check-release-log-safety.py` — `ENGINE_FILES` `:132`, `FEATURE_ROOTS` `:141`, `DEFAULT_ALLOW_LIST` `:181`, `RULES` `:187`; wired into `ios/build.sh` ahead of every test scope.
- Degradation stack: `PressureBrainPick.swift` (`ios/ElderlyAssistant/Services/` + `Voice/`) `.keep`/`.stepDown`/`.lightweight` `:57-62`, `safetyMarginBytes` 768 MB `:78`, `pressureWindowSeconds` `:89`; `WhisperPostTurnPolicy.swift` `.brainOverBudget` per-turn release (PR #156, `437631e`).

**Reconciliations (requirement text vs. verified code):**

- FR-MTC-004's "rephrase band … `CommandRouter.swift:794-809`" cites the follow-up *handler*; the band's *trigger* is `:1493-1519`. Both are correct for what they name; this design uses the trigger for candidate sourcing and the handler for the discard path.
- FR-MTC-002's "marker fallback at `KeywordIntentRule.swift:765-775`" — verified as the `kept.isEmpty` branch `:765-775` inside `musicQuery(from:)` `:752-779`; the marker line is `:770`.
- FR-MTC-014's "states at 15–16" is the enum region `:9-17` (only `awaitingConfirmation` is at `:15`; the enum's true span is 9–17); "the 45 s timer at 91–127" spans `Config` `:93-96` and the transition arms `:119-127`, with the timer construction at `:183-203`. The design edits all three regions.
- The workflow comment's "generalize the confirmation hook ~785-886" — verified: the block's doc comment opens at `:785`, the guard at `:789`, the closing brace at `:886`.
- Accessibility precedent for the probe: this repo's ambiguity-walk (`isAwaitingNavigationDisambiguation`, `AppCoordinator.swift:8537` region) already speaks candidate questions one-by-one; the frame path keeps that pattern's spirit but is deliberately a **single** bounded question with ≤3 candidates (no walk), because the frame is one-deep and time-bounded.

---

## Architecture

### 8. Context and end-to-end flow

```
 user speech ──► WhisperKit STT (unchanged)
                     │  transcript
                     ▼
        CommandRouter.route(transcript:)                       [CommandRouter.swift:740]
        ┌─ 1 TranscriptSanityGuard .......................... :747-758  unchanged
        ├─ 2 EMERGENCY keywords ............................ :779-783  unchanged + frame clear (§10)
        ├─ 3 confirmation hook (yes/no, rephrase, …) ....... :789-886  unchanged; mutually exclusive (§14)
        ├─ 4 DIALOGUE FRAME INTERCEPTION (NEW) ............. §10
        │      live frame? ─ expired ─► drop, fall through (fresh command)
        │             ├─ escape ─► drop + ack + re-arm
        │             ├─ cancel / cancel+amendment ─► drop + line  |  answer=amendment
        │             ├─ barge-in (pure-stage match) ─► drop, fall through
        │             ├─ answer ─► merge + execute (§11) ─► return
        │             └─ invalid ─► attempts++; re-probe or default (§11)
        ├─ 5 safety net (med-ack, sensitive) ............... :897-899  unchanged
        ├─ 6 contact search / directions / alarms .......... :916-…    unchanged
        ├─ 7 YouTube stage ................................. :1164-1167 unchanged
        ├─ 8 keyword-intent stage ........................... :1169-1244
        │      music arm :1223-1234 ─ degenerate? ─► ARM slotFill FRAME + probe (§12)
        │                            else ─► fireMusicRequest (today)
        ├─ 9 topic pre-answer + interpreter ................ :1488-…    unchanged
        │      interpreted .music :3336-3355 ─ degenerate? ─► ARM frame (§12)
        │      abstention :1521 ─► routeKeywordRemainder
        └─ 10 routeKeywordRemainder ........................ :1968-2030
               .available + no web-search/failure line ─► honest line + didYouMean probe (§13)
               no candidates ─► today's honest line alone
```

Probe speech goes through the router's existing `speak(text:)` lane (`CommandRouter.swift:3848-3884` → `ReplySpeakLane` actor → `noteAssistantSpoke` `:3864`), so a probe is a normal reply on every existing surface (speech, chat history, outcome machinery) with zero new UI.

### 9. The frame model

Types (new file `ios/ElderlyAssistant/Services/` + `Voice/DialogueManager.swift`):

```swift
enum ProbeKind: Equatable { case slotFill, candidateChoice }

enum DialogueSlot: Equatable { case musicQuery }        // Phase 3 adds .reminderTime, .calendarTitle

struct DialogueCandidate: Equatable {
    let id: String                 // stable; index words map to position
    let labelKey: String           // xcstrings key for the spoken name
    let domain: KeywordIntentRule.Domain
    let query: String?             // extracted from the user's own utterance; nil when the domain needs none
}

struct DialogueFrame {
    let id: UUID
    let probeKind: ProbeKind
    let slot: DialogueSlot
    let domain: KeywordIntentRule.Domain?     // barge-in exclusion
    let activeCommand: InterpretedCommand?    // nil for a pure candidateChoice frame
    let candidates: [DialogueCandidate]       // ≤ maxCandidates
    let defaultQuery: String?                 // slotFill: the pending degenerate query
    var attempts: Int
    let deadline: Date                        // probe-spoken + confirmationTimeoutSeconds
    var isExpired: Bool { Date() >= deadline }
}

enum DialogueFrameResolution: Equatable {
    case answered(capture: CaptureForm, merge: MergeSource)
    case defaultExecuted
    case candidateSelected(Int)
    case exhausted, cancelled, escaped, bargedIn, timedOut, superseded
}

final class DialogueManager {                 // main-queue-confined, coordinator-owned
    private(set) var frame: DialogueFrame?
    var liveFrame: DialogueFrame?             // nil when absent; drops an expired frame on read
    func arm(_ frame: DialogueFrame) throws   // DialogueError.windowBusy | .noResolution
    @discardableResult func noteAttempt() -> Int
    func resolve(_ r: DialogueFrameResolution) -> DialogueFrame?   // clears + returns the frame
}
```

**Probe composition (template-only).** `DialogueManager` renders probe text from `dialogue.*` keys: slotFill = question key + ordered option labels (from `DialogueOptionCatalog`, ≤ `maxSlotOptions`) + the default label + the free-text invitation, joined with static separators; candidateChoice = the honest `dialogue.understood.no` line + `dialogue.didYouMean` with ≤ `maxCandidates` labels. Retry (second probe) prefixes `dialogue.retry`. The model is never consulted. FR-MTC-003's acceptance anchor probe text ('कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्') and the default ('जे पनि बजाऊ') are the draft catalog/string values (§15, §22).

**Lifecycle.** arm (probe spoken, window opened, timer armed) → attempts (invalid answers only) → resolve (single funnel: clear frame, cancel timer, emit, close window via the state machine's legal edges) → optional sequential re-arm (§ADR-MTC-01). Terminal outcomes: answered, defaultExecuted, candidateSelected, exhausted, cancelled, escaped, bargedIn, timedOut, superseded (a confirmation pend while a frame exists — defensive; §14). Every terminal outcome clears all frame state; nothing survives the turn-resolution funnel.

### 10. The interception seam and its strict ordering

The block (ADR-MTC-02 position) runs at the top of `route()`, after the emergency check and the confirmation hook. Pseudocode with the classified outcomes:

```swift
if let frame = coordinator?.activeDialogueFrame {          // live (expiry-checked on read)
    // The raw transcript went through TranscriptSanityGuard above (:747-758).
    let prepared = preparedForDialogue(raw)                // §11: sanitise + shared input seam
    switch DialogueAnswerPath.classify(prepared, frame: frame, catalog: catalog) {
    case .expired:                    // deadline passed on read: liveFrame already dropped it
        break                                             // fall through — fresh command
    case .escape:
        coordinator.resolveDialogueFrame(.escaped); speak(key: "dialogue.escape"); return .unrecognised(transcript: raw)
    case .cancel:
        coordinator.resolveDialogueFrame(.cancelled); speak(key: "dialogue.cancelled"); return .unrecognised(transcript: raw)
    case .amendment(let content):     // "होइन, दुर्गा भजन" — a negative carrying content is an answer
        return executeDialogueAnswer(content, frame: frame, raw: raw)          // §11
    case .bargeIn:
        coordinator.resolveDialogueFrame(.bargedIn)       // fall through — the ladder executes it (ADR-MTC-05)
    case .answer(let a):
        return executeDialogueAnswer(a.value, frame: frame, raw: raw)          // §11
    case .invalid:
        let n = coordinator.noteDialogueAttempt()
        if n < DialogueConfig.maxProbes { speakProbeAgain(frame) }             // re-probe
        else { return resolveDialogueExhaustion(frame, raw: raw) }             // §11 table
        return .unrecognised(transcript: raw)
    }
}
```

**Ordering guarantees this block carries (each one binding):**

1. **Emergency first, absolute** (S1): the check at `:779-783` runs above the block on every utterance; the block never re-evaluates, weakens or delays it; a hostile answer containing an emergency keyword is dispatched as an emergency before the block exists in its path (FR-MTC-011 scenario 3).
2. **Confirmation hook intact**: mutually exclusive windows (ADR-MTC-03). Enforcement is coordinator-side and structural: `startDialogueFrame` returns false (and the caller then executes today's non-probe behaviour — a defensive-only path, unreachable on the current ladder) when `isAwaitingConfirmation`; every confirmation-pending seam clears any live frame with `.superseded`. The hook's 100 lines stay byte-identical.
3. **Interception armed exactly while the window is live** (FR-MTC-009): reading `activeDialogueFrame` after expiry returns nil and drops the frame (no half-open window); every resolution disarms. A stale frame cannot swallow a later command.
4. **Barge-in falls through, never duplicates**: the classifier uses pure predicates only (ADR-MTC-05); after `resolveDialogueFrame(.bargedIn)` the utterance executes exactly once, in the stages below, with all their confirmation tiers.
5. **Med-ack F3 discipline** (the app-launch lesson at `:847-862`): a dose acknowledgement mid-probe is a barge-in, reaches the safety net (`:897`), and is acknowledged exactly as today.
6. **Ambiguity is an answer**: only a *strong* different-command match drops the frame (FR-MTC-012 scenario 2).

### 11. Answer capture and the deterministic merge

**Preparation (step 1 of FR-MTC-006).** The answer text passes the exact seam every turn uses: `InputSanitiser.sanitise(_:level: .quarantine)` (the AM-3/CL-6 boundary) followed by the shared input seam (STT-error corrector + dialect canonicalizer, `LocalBrainChain.swift:281-282`). This feature extracts that pair into one shared helper (`IntentTranscriptPreparation.prepare(_:seam:)`) called by both `LocalBrainChain.turnInput` and the dialogue path — one implementation, two callers, byte-identical behaviour. The router reaches it through a new coordinator protocol member `prepareDialogueAnswerText(_:) -> String` (the router does not own the seam). `InputSanitiser`'s 200-Character cap applies unchanged; an over-length answer is an invalid answer (re-probe/default), not a truncated merge.

**Capture ladder (FR-MTC-005), on the stripped value:**

| Form | Rule | Example |
|---|---|---|
| Index word | first token ∈ the localized index table (`पहिलो`/`first`→1, `दोस्रो`/`second`→2, `तेस्रो`/`third`→3), index ≤ option count | "पहिलो" → option 1 |
| Option name | the value (or its marker-dropped variant, below) whole-token-matches a catalog alias or a candidate label alias | "दुर्गा" → the दुर्गा option |
| Repetition | same as option name — a repetition *is* a name match ("दुर्गा भजन बजाऊ" → strip → "दुर्गा भजन" → marker-dropped "दुर्गा" matches) | FR-MTC-005 scenario 3 |
| Free-form | any non-empty stripped value not matching an option — **always accepted** | "दशैं दुर्गा भजन" |

**Scaffold strip (step 2).** Remove the *scaffolding*: the music verb family and particles (reusing the extractor's own drop vocabulary through a new narrow accessor on `KeywordIntentRule` — one vocabulary source, no duplication), probe-echo words (the `dialogue.probe.*` question words), and a leading index word in index form. **Markers are not stripped from the free-text fallback** (FR-MTC-006 keeps "दशैं दुर्गा भजन" intact), but a marker-dropped *variant* of the value is also compared for **option matching** — that is how "दुर्गा भजन" still canonicalises as the दुर्गा option. If nothing survives the strip, the answer is invalid (§ADR-MTC-04 step 6); a marker-only answer ("गीत चलाऊ") is exactly that case, not a valid answer.

**Catalog canonicalisation (step 3).** Whole-value alias match (not per-token substitution): "दुर्गा" → canonical query `"durga bhajan"` (FR-MTC-006 scenario 2); "दशैं दुर्गा भजन" matches nothing whole ⇒ the sanitised free text is kept as the value (scenario 3). **Never reject, never invent.**

**Merge and dispatch (steps 4–5).** The answer fills the missing slot on `activeCommand` (music: the query travels the free-text `message` entity, the same field the interpreted `.music` route reads at `:3350-3352`; all other command properties unchanged). Dispatch for a merged music command: `fireMusicRequest(query:)` (`:2667`) → `runMusicTurn` (`:2684`) → the existing outcome matrix (`selectMusicOutcome` `:2614`), so pre-ack, Spotify/YouTube precedence and every honest outcome line are exactly the directly-spoken path's (NFR-MTC-012). A merged slotFill answer whose value is again degenerate does not re-probe recursively: the default behaviour of a *merged* command executes directly.

**Cache bypass (FR-MTC-017, ADR-MTC-11).** The answer turn returns from the frame block before the interpreter, so `IntentCommandCache.command(for:)` is structurally unreachable on it (the cache check lives inside `interpret()`). On execution the frame path never sets `pendingTranscript` (`:3307`) — it executes `fireMusicRequest` directly or dispatches a candidate through its deterministic seam — so no answer text can reach `recordConfirmedExecution` learning (`AppCoordinator.swift:7626-7635` call site). **Recorded caveat for review:** today no confirmed-execution path records *music* commands at all (the only `recordConfirmedExecution` call site is the call path); the design keeps it that way and pins it with a test (§29) — a merged music command is not internable.

### 12. Degenerate music-query detection

Both intake routes share one trigger helper on the router:

- **Ladder arm** (`CommandRouter.swift:1223-1234`): replace the direct call with `let outcome = KeywordIntentRule.musicQueryOutcome(from: preText)`; if `outcome.isDegenerate` → arm the slotFill frame (catalog group `bhajan.deity`, default query = `outcome.query ?? preText`) and speak the probe instead of searching; else `fireMusicRequest(query: outcome.query ?? preText)` — today's behaviour, byte-identical.
- **Interpreted route** (`.music`, `:3336-3355`): compute the selected query exactly as today (`interpretedQuery ?? musicQuery ?? raw`, `:3350-3355`), then classify: a non-empty model query is `.content` (specific); otherwise the extractor's provenance decides; the `?? raw` transcript fallback is degenerate by definition (FR-MTC-002 scenario 3: no search is fired with the raw transcript as the query).

`isDegenerate ⇔ provenance != .content`. Detection is model-free, zero prompt tokens, and applies only inside the music domain — specific queries keep today's exact behaviour (NFR-MTC-012). The trigger emits `dialogue_degenerate_query {intake: ladder|interpreted}` before arming.

### 13. The did-you-mean candidate assembly

Trigger points (both replace a dead-end *line*, never a live branch):

1. `routeKeywordRemainder`, `.available` branch, the bare `speak(key: "router.reprompt")` at `CommandRouter.swift:2021` → when `DialogueCandidateBuilder` yields ≥1 candidate: speak `dialogue.understood.no` + `dialogue.didYouMean` with the candidates, arm the `.candidateChoice` frame, open the window. When the web-search hook answered (`:2004`) or a cloud-failure-class line was spoken (`:2013-2019`), the turn is owned — no probe. The `.downloadingBrain` / `.needsSetup` branches (`:2024-2027`) keep their truthful lines exactly (FR-MTC-004: no-brain states preserved) — a probe is also not offered there, because the honest state message is the more useful line and NFR-MTC-012 protects that behaviour.
2. The rephrase-discard branch (`:806-809`): the taken hypothesis is captured before discarding (it is already returned by `takePendingRephraseCommand()` at `:806`); candidates = near-matches of the **original** utterance (`taken.sourceTranscript`), with the denied hypothesis appended last **only when** ≥1 near-match exists (ADR-MTC-07). With candidates: honest line + probe instead of `router.rephrase.discard`. Without: today's line stands.

Candidate labels are rendered from `dialogue.candidate.*` templates (never model text) and may embed the user's own extracted query (their own words, not generated content). Picking a candidate closes the frame, then executes through that domain's existing deterministic seam (ADR-MTC-07) — "as if it had been understood". A candidate whose execution would itself need a missing slot (a degenerate music near-match) chains sequentially into a fresh slotFill frame (ADR-MTC-01), never nests.

### 14. The answer window: `awaitingSlotAnswer` and the 45 s reuse

Edits to `VoiceSessionStateMachine.swift` (mirroring, not refactoring, the confirmation machinery):

- `VoiceSessionState` gains `.awaitingSlotAnswer` (`:9-17`); `canTransition` gains the mirrored edges — entry from `.idle` and the busy states (same set as `:29-38`), exits to `[.idle, .error, .stopped]` (`:39-40` mirrored); `supportsTalkReset` returns false in the new state exactly as in `.awaitingConfirmation` (`:75-76`: the dialog owns the turn).
- `@discardableResult func openSlotAnswerWindow() -> Bool` mirrors `openConfirmationWindow()` `:153-181` (bridge via `.idle`; legal edges only). The coordinator exposes the same main-thread hop pattern as `AppCoordinator.openConfirmationWindow()` (`:7019-7027`).
- `transition(to:)` (`:111-127`) gains the mirrored arms: leaving the state cancels `slotAnswerTimer`; entering it arms. `armSlotAnswerTimer()` mirrors `armConfirmationTimer()` `:183-203`, including the F6 still-open guard — `guard self.state == .awaitingSlotAnswer` — before firing `onSlotAnswerTimeout`.
- The timer value is `config.confirmationTimeoutSeconds` (`:93-96`, 45 s) — one config field serves both windows; no new literal. The expiry callback is the silent one (ADR-MTC-08); the confirmation callback (`onConfirmationTimeout`, `:102`) and its spoken notice (`AppCoordinator.swift:3035-3036`) are untouched.

**Boundary correctness (FR-MTC-013).** Two independent guards make a half-open window impossible: (a) the timer cancels on every resolution and re-checks state before firing; (b) the interception reads `liveFrame`, which auto-drops an expired frame *while the same turn continues as a fresh command*. An utterance just before expiry is an answer; the same utterance after expiry is a fresh command.

**Backstops.** The 60 s voice watchdog (`AppCoordinator.swift:4865`) and the Talk-button recovery (`supportsTalkReset` semantics) are unchanged; the frame path adds no new stuck path. A watchdog fire or a Talk tap that moves the session out of `.awaitingSlotAnswer` legally also resolves the frame with `.superseded` (coordinator-side funnel). Frame timeout does **not** call `recordConfirmationTimeout()` (yes/no telemetry) — it emits `dialogue_frame_resolved {timeout}` instead.

### 15. The curated on-device option catalog

New resource `DialogueOptionCatalog.json` (app bundle) + `DialogueOptionCatalog.swift` loader:

```json
{
  "version": 1,
  "groups": {
    "bhajan.deity": {
      "questionKey": "dialogue.probe.bhajanKind",
      "options": [
        { "id": "shiva", "labelKey": "dialogue.option.bhajan.shiva",
          "query": "shiva bhajan", "aliases": ["शिव", "shiv", "shiva"] },
        { "id": "durga", "labelKey": "dialogue.option.bhajan.durga",
          "query": "durga bhajan", "aliases": ["दुर्गा", "durga"] },
        { "id": "bishnu", "labelKey": "dialogue.option.bhajan.bishnu",
          "query": "bishnu bhajan", "aliases": ["विष्णु", "bishnu"] },
        { "id": "devi", "labelKey": "dialogue.option.bhajan.devi",
          "query": "devi bhajan", "aliases": ["देवी", "devi"] }
      ]
    }
  }
}
```

- **Spoken labels live in `Localizable.xcstrings`** (via `labelKey`), not in the JSON — one localisation source of truth (ADR-MTC-09; the ne/en rule).
- `query` is the canonical search string the merge substitutes on an option match (FR-MTC-006 scenario 2: दुर्गा → `"durga bhajan"`).
- `aliases` is match vocabulary only (never spoken) — consistent with the keyword tables' precedent; matching is **whole-token** after normalisation, with the marker-dropped variant allowed, and **never Devanagari substring containment** (the repo's grapheme-cluster discipline: partial-word Devanagari substring matching is a known hazard; "गीता" must not match "गीत").
- The default option ("जे पनि बजाऊ" / "just play anything") is not a catalog entry: it is the frame's `defaultQuery` resolution (the pending degenerate query) rendered from `dialogue.option.anyPlay`; offered on every probe (FR-MTC-003/007).
- **Loading errors are first-class**: `DialogueOptionCatalog.load` throws `DialogueError.catalogUnavailable` (missing/malformed resource). The slotFill trigger then degrades honestly: the probe still asks, free-text-only (options omitted), and the default still resolves — never a crash, never a silent no-question. A gate test asserts the resource ships in the bundle and parses.
- The catalog is the OD-M2 seam: a future live-search source implements the same lookup shape behind `DialogueOptionCatalog`, leaving the frame path untouched.

### 16. Surviving the degradation ladder (PR #156)

Phase 1's guarantee is structural, not defensive: **the dialogue path never consults the brain**. The interception block returns before `interpreter` is reached (the interpreter call is in the async completion of the topic stage, `CommandRouter.swift:1488`); the probe text is template-composed; the merge is deterministic (`DialogueAnswerPath`); candidate assembly is `KeywordIntentRule`-pure. Consequences:

- **No new memory residents, no new GPU/ANE work** — the frame is a few hundred bytes of value state on the coordinator. The PR #156 hardening is untouched: the `.brainOverBudget` per-turn STT release (`WhisperPostTurnPolicy`) sees the same turn shape; the pressure-tiered picks (`PressureBrainPick` `.keep`/`.stepDown`/`.lightweight`, `:57-62`; 768 MB margin `:78`; 30 s window `:89`; INSTALLED ONLY / NEVER UP) are unaffected because no frame turn loads a model.
- **Brain absent / downloading / needs-setup**: unchanged lines (`:2024-2027`); a live frame's *answer turn* still works because it needs no brain. The one interplay that remains a model path is the didYouMean **trigger** point when the brain is `.available` (the abstention line): with the brain degraded, the abstention branch is not reached and the truthful no-brain lines stay — correctness over cleverness (recorded, §31 R7).
- **Degraded-mode pill**: no change; the pill reflects brain readiness, which this feature never alters.
- **Phase 2 optional brain merge**: the frame clause (§17) lets the model classify the answer; its absence degrades to exactly the Phase 1 path ("brain unavailable → one more probe, then execute with defaults" — the frame stays deterministic-first at all times). The degraded path must not weaken the safety gates: the clause is additive prompt text under the unaltered emergency/safety stages; no ordering changes.
- **Jetsam stance (NFR-MTC-007)**: sustained multi-turn adds bounded dialogue state and unchanged capture/STT work; DV-5 verifies with the PR #156 protocol.

### 17. Phase 2 — the frame clause inside the pinned prompt (ships only with v17)

Per ADR-MTC-12: 5th interpolation, inserted after the `User said:` line; defaulted parameter `frameClause: String? = nil` keeps Phase 1 byte-identical; `.raw` framing untouched. **The same change** must: (1) update `tools/train-intent/seeds/prompt_template.txt` byte-identically (the `IntentPrompt.swift:44-55` identity rule); (2) extend `check-prompt-mirror`'s anchor validation for `{frame_clause}` (its four-interpolation anchors become five, with the gate's self-test mutation updated); (3) update the `PinnedSurfaceGuardTests` digest literals (`:61`, `:63`) and the `IntentPromptTests` 2,506 baseline + worst-case recomputation (`:482-495`) — the 3,000-Character ceiling (`:126`) and the 1,024-token cap (`LlamaCommandInterpreter.swift:1199`) stay unchanged; (4) the v17 iteration trains on follow-up turns (golden corpus + synthetic follow-ups: probe → answer pairs with the frame clause in-prompt), per FR-MTC-018. Budget discipline: clause ≤300 Characters (≥494 Characters of slack under the ceiling today; worst-case 2,586 → ≤2,886); the prompt-identity drift hazard is managed by making clause + mirror + pins + digest one atomic change (the seed and template can never diverge).

### 18. Phase 3 — reminder/calendar rollover (deferred, designed additively)

The same frame path carries the existing stateless missing-slot re-prompts for reminders/calendar: `DialogueSlot` gains `.reminderTime`, `.calendarTitle`, `.calendarTime`; their trigger points are the current handlers' ask-lines (`handleSetReminder` `CommandRouter.swift:3462`, `handleCreateCalendarEvent` `:3510`) converted to frame arms; the answer merge canonicalises a time expression through the existing `NepaliTimeParser` path instead of the music catalog; the `.confirm` tier behaviour is unchanged (the merged command still confirms). RepetitionGuard interplay (FR-MTC-019): the frame resolves before the confirmation pend, so the guard sees the merged command only on confirmed execution — the existing recording seam (`AppCoordinator.swift:7626-7635` region). No Phase 3 trigger registers in Phase 1 (ADR-MTC-15; OD-M4).

### 19. Concurrency and isolation

- **Frame state is main-queue-confined** — the same contract as `VoiceSessionStateMachine` (all mutations on the main queue; callers hop as today, `AppCoordinator.openConfirmationWindow()` `:7019-7027` pattern). Router reads/writes travel the coordinator hooks; no lock, no actor needed.
- **Turns never overlap** — `VoicePipeline` serialises utterances (the `pendingTranscript` doc comment `:3302-3306` is explicit: single in-flight interpretation). The interception therefore never races a second turn; a barge-in utterance is the *same* turn continuing into the ladder.
- **Speech is serialised by the existing actor** — `ReplySpeakLane` (FIFO) orders the probe and any outcome line exactly as it orders today's replies.
- **Timer lifecycle** — `slotAnswerTimer` is a `Task` cancelled on every resolution and state exit; the F6 guard re-checks the window before firing (a queued callback after cancellation cannot speak — it is silent by design anyway; it may only clear an already-clear frame).
- **Candidate execution is synchronous with the turn** — no new async surface; the seams preserve their own async behaviour below (music search etc. unchanged).
- **Isolation tests**: the plan (§29) includes concurrent-ish sequences (answer-then-timeout ordering, timeout-then-answer, resolution-then-second-resolution) proving idempotent clearing.

### 20. Configuration parameters

| Knob | Default | Home | Notes |
|---|---|---|---|
| `DialogueConfig.maxProbes` | 2 | `DialogueManager.swift` | OD-M1; counts probes spoken |
| `DialogueConfig.maxCandidates` | 3 | same | FR-MTC-004 ≤2–3 |
| `DialogueConfig.maxSlotOptions` | 4 | same | FR-MTC-003 ≤3–4 |
| Window timeout | `confirmationTimeoutSeconds` = 45 s | `VoiceSessionStateMachine.Config` `:93-96` | single source for both windows; never a new literal |
| Capture timeout / watchdog | 22 s / 60 s | `VoicePipeline.swift:130`; `AppCoordinator.swift:4865` | unchanged envelopes the frame path must not exceed |
| Catalog resource | `DialogueOptionCatalog.json` v1 | bundle | §15 |
| `maxMusicQueryLength` | 100 | `KeywordIntentRule.swift:722` | unchanged |

Invariant: no numeric literal is introduced in the frame path; tests inject small values (short timeouts, cap 1) to exercise boundaries without wall-clock waits.

### 21. Error taxonomy and failure modes

```swift
enum DialogueError: Error, Equatable {
    case windowBusy          // arm while a window is open (defensive; unreachable on the current ladder)
    case noResolution        // arm with neither a candidate list nor a default to resolve
    case catalogUnavailable  // resource missing/malformed
    case emptyMerge          // merge produced no value (answer was invalid — callers treat as re-probe)
}
```

| Failure | Behaviour | Retryable |
|---|---|---|
| Catalog load fails | probe asks free-text-only + default; `dialogue_*` event with `error_code` | next launch (resource fixed) |
| Answer resolves to nothing | invalid answer → attempt++ → re-probe / exhaustion | yes, bounded by `maxProbes` |
| Brain absent on answer turn | nothing to fail — Phase 1 path is brain-free | n/a |
| Speech lane busy | probe/outcome queues FIFO (existing lane) | n/a |
| Window expiry races a resolution | first resolution wins; the second is a no-op on a cleared frame (idempotent `resolve`) | n/a |
| Merged command execution fails | the music path's own honest failure lines (unchanged) | per existing path |

### 22. Privacy, log safety, observability, localisation

**No new egress (NFR-MTC-003).** Probes, candidates, the catalog and the merge are on-device; the only network traffic on the executed path is the existing music search (Spotify-feature-owned). The feature adds zero calls.

**No content in logs (NFR-MTC-004, S3, B2/T-050).** Events are closed-vocabulary and count/enum-shaped only: `dialogue_degenerate_query {intake}`, `dialogue_probe_spoken {probe_kind, attempt, option_count}`, `dialogue_answer {capture_form, merge_source}`, `dialogue_frame_resolved {outcome}`. New metadata keys (`probe_kind`, `capture_form`, `merge_source`, `intake`, `attempt`, `option_count`) join `LogSanitiser.allowedKeys` with fixed vocabularies, following the existing justified-key comment convention. The new source files (`DialogueManager.swift`, `DialogueAnswerPath.swift`, `DialogueCandidateBuilder.swift`, `DialogueOptionCatalog.swift`) join the release-log gate's `FEATURE_ROOTS` (`ios/tools/check-release-log-safety.py:141`) with a fixtures entry, so any future console write or content-derived field in them fails `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`). The transcript-recording policy is unchanged (`recordTranscript`, `CommandRouter.swift:741`); probe text rides the existing assistant-reply surface via `noteAssistantSpoke` (`:3864`) — the chat-history parity the requirements want, and the same on-device surface replies already use.

**Localisation (NFR-MTC-006).** New `dialogue.*` keys in `Localizable.xcstrings` (sourceLanguage en), all ne+en, with draft copy:

| Key | ne (draft) | en (draft) |
|---|---|---|
| `dialogue.probe.bhajanKind` | कस्तो भजन? %@ … वा आफैँ भन्नुहोस् | What kind of bhajan? %@ … or say it yourself |
| `dialogue.option.bhajan.shiva/durga/bishnu/devi` | शिव / दुर्गा / विष्णु / देवी | shiva / durga / bishnu / devi |
| `dialogue.option.anyPlay` | जे पनि बजाऊ | just play anything |
| `dialogue.retry` | फेरि सोध्छु — | Let me ask again — |
| `dialogue.understood.no` | मैले बुझिन। | I didn't understand. |
| `dialogue.didYouMean` | के तपाईंको मतलब %@ हो? | Did you mean %@? |
| `dialogue.candidate.<domain>` | (per-domain templates, e.g. युट्युबमा %@? ) | (e.g. YouTube: %@?) |
| `dialogue.cancelled` | ठीक छ। | OK. |
| `dialogue.escape` | ठीक छ, फेरि भन्नुहोस्। | OK, tell me again. |
| `dialogue.exhausted` | मैले बुझिन। अर्को पटक फेरि भन्नुहोस्। | I didn't understand. Try again another time. |
| `dialogue.timeout` | — | — (intentionally absent: expiry is silent) |

Matching vocabularies (index words, escape variants) are input tables in Swift, mirroring `isYesResponse`/`isNoResponse` (`:3801-3809`) — not spoken strings, not xcstrings. Voice-only accessibility (NFR-MTC-009): every option is spoken by name and answerable as a single word; no visual affordance required; the chat-history copy is a transcript, not an interaction requirement.

### 23. Auth and sensitive-action posture

No auth changes of any kind: no new credential, no new store, no new permission. The frame cannot authenticate, cannot bypass a tier, and cannot reach a sensitive action except through its existing gate:

- A merged command is the **same resolved command** that would have executed anyway; its tier is unchanged (music = `.free`).
- Candidate lists are restricted to safe fast-path domains (§ADR-MTC-07) — no `.call`/`.sendMessage`/`.setReminder`/`.createCalendarEvent` candidate can be constructed in Phase 1, by construction, not by filtering.
- A barge-in command executes through the normal ladder with its normal confirmation tiers (FR-MTC-012 scenario 1: the call still asks).
- The answer text is data with exactly two possible effects: fill one slot value or select one enumerated candidate. It never selects an execution path, never names a contact, never names a time (§24 E-row).

### 24. STRIDE pre-map for security-design-review

| Threat | Surface | Mitigation (design) | Verified by |
|---|---|---|---|
| **S**poofing | answer claims authority ("यो फोन गर" as an answer) | answers cannot trigger sensitive actions (candidates safe-only; barge-in uses normal tiers); no auth surface touched | §23; barge-in tests |
| **T**ampering | crafted/corrupted answer text | sanitised at the boundary (`InputSanitiser` `.quarantine`, 200-char cap) before any use; merge is pure over the stripped value; no prompt in Phase 1 | §11; hostile corpus |
| **R**epudiation | dialogue resolutions | closed-vocabulary events per resolution; transcript recording unchanged (`:741`) | §22; event tests |
| **I**nformation disclosure | probe/answer text in logs, new egress | no content in events; allow-list keys; FEATURE_ROOTS coverage; zero new network calls; chat surface is the existing on-device reply path | §22; log gate; egress grep gate (§29) |
| **D**enial of service | trap loops, probe fatigue | one-deep; ≤2 probes; 45 s silent timeout; cancel/escape/barge-in recoveries; idempotent resolve; watchdog untouched | §10, §14; trap tests; DV-2/3 |
| **E**levation of privilege | answer drives execution | answer ∉ control flow: slot value or enumerated pick only; candidates free-domain-only; emergency above everything | §10, §23; injection corpus |

The workflow's security focus areas land as: emergency precedence mid-dialogue (§10 guarantee 1, tested in DV-3-adjacent suites); free-text answer injection (§11/§24 T+E); frame-trap resistance (§10, §14); log sanitisation of probe/answer text (§22); no new egress (§22); degraded-brain path must not weaken safety gates (§16 — nothing on the dialogue path gates safety).

### 25. Infrastructure and build topology

**No Docker, no backend, no services.** This is an iOS-only, on-device feature (Feature Constraint 10): one app target, one test bundle, one bundled JSON resource. Build/test topology is the existing one: `ios/build.sh` (which runs the release-log gate ahead of test scopes), the focused-suite discipline per unit (project rule: focused tests + typecheck per unit; full suite once at the end), and the DV harness on Anzaan. The Phase 0 prerequisite (PR #156 smoke) and the DV sessions use the existing devicectl/deploy script (`ios/tools/deploy` path, `5bf8685` recipe) and the JetsamEvent pull protocol.

### 26. Phase coverage

| Phase | Content | Sections | Ships |
|---|---|---|---|
| 0 | PR #156 device smoke (outstanding) | §6, §25 | prerequisite, before Phase 1 DV |
| 1 | Frame + both probes + catalog + deterministic merge + window + gates + tests | §9–§16, §19–§24, §27–§29 | first, alone (OD-M3) |
| 2 | v17 fine-tune + frame clause + brain-assisted merge | §17 | only together with v17 |
| 3 | Reminder/calendar rollover + RepetitionGuard | §18 | separately (OD-M4) |

---

## Components

### 27. Component inventory

| ID | Component | File (repo-relative) | New/Changed | Phase |
|---|---|---|---|---|
| C-MTC-01 | `DialogueManager`, `DialogueFrame`, `ProbeKind`, `DialogueSlot`, `DialogueFrameResolution`, probe composer | `ios/ElderlyAssistant/Services/` + `Voice/DialogueManager.swift` | NEW | 1 |
| C-MTC-02 | `DialogueAnswerPath` (classify/merge), `CaptureForm`, `MergeSource`, vocab tables | `ios/ElderlyAssistant/Services/` + `Voice/DialogueAnswerPath.swift` | NEW | 1 |
| C-MTC-03 | `DialogueCandidateBuilder`, `DialogueCandidate` | `ios/ElderlyAssistant/Services/` + `Voice/DialogueCandidateBuilder.swift` | NEW | 1 |
| C-MTC-04 | `DialogueOptionCatalog` + resource | `ios/ElderlyAssistant/Services/` + `Voice/DialogueOptionCatalog.swift`; `ios/ElderlyAssistant/Resources/` + `DialogueOptionCatalog.json` | NEW | 1 |
| C-MTC-05 | Interception block + two trigger edits + execution seams | `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` | CHANGED | 1 |
| C-MTC-06 | `musicQueryOutcome` provenance, `nearMatches`, narrow drop-vocabulary accessor | `ios/ElderlyAssistant/Services/` + `Voice/KeywordIntentRule.swift` | CHANGED | 1 |
| C-MTC-07 | `awaitingSlotAnswer`, `openSlotAnswerWindow`, `onSlotAnswerTimeout`, timer mirror | `ios/ElderlyAssistant/App/` + `VoiceSessionStateMachine.swift` | CHANGED | 1 |
| C-MTC-08 | Ownership + protocol conformance + timeout handler + confirmation coexistence funnels | `ios/ElderlyAssistant/App/` + `AppCoordinator.swift` | CHANGED | 1 |
| C-MTC-09 | `dialogue.*` keys | `ios/ElderlyAssistant/Resources/` + `Localizable.xcstrings` | CHANGED | 1 |
| C-MTC-10 | Log-gate coverage + fixtures | `ios/tools/check-release-log-safety.py` | CHANGED | 1 |
| C-MTC-11 | Test suites + hostile corpus (§29) | `ios/ElderlyAssistantTests/…` | NEW/CHANGED | 1 |
| C-MTC-12 | Frame clause + seed mirror + pin updates + v17 | `ios/ElderlyAssistant/Services/` + `Voice/IntentPrompt.swift`; `tools/train-intent/seeds/prompt_template.txt`; tests | CHANGED | 2 |
| C-MTC-13 | Reminder/calendar rollover + RepetitionGuard interplay | `CommandRouter.swift`, slot vocabulary | CHANGED | 3 |

### 28. Component detail

**C-MTC-01 `DialogueManager`** — owns the single frame; probe text composition. Interface in §9. Errors: `DialogueError.windowBusy`, `.noResolution`. Async: none (pure state; the deadline is read, never awaited). Concurrency: main-queue-confined. Responsibility fence: it never speaks, never executes, never touches the catalog beyond rendering passed-in options.

**C-MTC-02 `DialogueAnswerPath`** — the pure brain of the answer turn:

```swift
enum AnswerClassification { case expired, escape, cancel, amendment(String), bargeIn, answer(DialogueAnswer), invalid }
static func classify(_ prepared: String, frame: DialogueFrame, catalog: DialogueOptionCatalog) -> AnswerClassification
static func isBargeIn(_ prepared: String, frame: DialogueFrame) -> Bool          // ADR-MTC-05 predicates
static func merge(_ value: String, into frame: DialogueFrame, catalog: DialogueOptionCatalog) throws -> String  // §11
```

Errors: `throws DialogueError.emptyMerge`. Pure and synchronous — every rule in §11 is unit-testable without a coordinator.

**C-MTC-03 `DialogueCandidateBuilder`** — `static func build(for utterance: String, excluding domain: KeywordIntentRule.Domain?, rephrase: InterpretedCommand?) -> [DialogueCandidate]` (ADR-MTC-07). Pure; returns `[]` when nothing is eligible ("never fabricate"). No side effects, no execution knowledge beyond the candidate's domain tag.

**C-MTC-04 `DialogueOptionCatalog`** — `load(bundle:) throws`, `group(_:) -> DialogueOptionGroup?`, `canonicalQuery(forAnswer:in:) -> String?` (§15). Errors: `DialogueError.catalogUnavailable`. Read-only after load; static data, thread-safe by immutability.

**C-MTC-05 router edits** — (a) the interception block (§10); (b) the `fireMusicRequestOrProbe` trigger helper used by the ladder arm (`:1233`) and the interpreted `.music` route (`:3353-3355`); (c) the two didYouMean trigger edits (`:806-809`, `:2021`); (d) the emergency-frame clear (`:779-783`); (e) new `VoiceCommandCoordinating` members: `var activeDialogueFrame: DialogueFrame?`, `func startDialogueFrame(_:) -> Bool`, `@discardableResult func noteDialogueAttempt() -> Int`, `func resolveDialogueFrame(_:)`, `func prepareDialogueAnswerText(_:) -> String`, and `var dialogueOptionCatalog: DialogueOptionCatalog` (or a throwing accessor). Everything else in the file is untouched.

**C-MTC-06 `KeywordIntentRule` edits** — `MusicQueryExtraction` + `musicQueryOutcome` (wrapper keeps `musicQuery` byte-identical); `nearMatches(transcript:)`; a narrow `isMusicScaffoldToken(_:)` accessor for the answer strip. Existing drop sets stay private and single-sourced.

**C-MTC-07 state machine edits** — §14, mirrored edges only; the confirmation machinery is not refactored.

**C-MTC-08 coordinator edits** — `DialogueManager` ownership; `VoiceCommandCoordinating` conformance (main-thread hops mirroring `:7019-7027`); `onSlotAnswerTimeout` wiring (silent clear + event); confirmation-pend funnels call `clearDialogueFrame(.superseded)`; `prepareDialogueAnswerText` delegates to the shared seam helper; the timeout handler does **not** call `recordConfirmationTimeout()`.

**C-MTC-09..C-MTC-13** — §22 (strings), §22 (gate), §29 (tests), §17, §18.

### 29. Testing strategy

Focused suites per unit (project rule), mirroring the confirmation-protocol pattern; full suite once at the end; DV on Anzaan completes the gate.

| Suite (test-bundle path) | Covers |
|---|---|
| `Services/Voice/DialogueFrameTests.swift` (NEW) | FR-MTC-001: one-deep arming, retrigger suppression, resolution clears all fields, no-persistence shape; FR-MTC-007 attempts accounting |
| `Services/Voice/DialogueAnswerPathTests.swift` (NEW) | FR-MTC-005 forms (one test each incl. single-word), FR-MTC-006 merge (owner example; दुर्गा → `durga bhajan`; free-form kept; brain-absent path), FR-MTC-008/010 escape/cancel/amendment, ADR-MTC-04 precedence, ADR-MTC-05 barge-in predicates (incl. "मेरो छोरालाई फोन गर", "औषधि खाएँ", repetition-of-candidate negative case), invalid-answer/degenerate-answer guard |
| `Services/Voice` + `DialogueOptionCatalogTests.swift` (NEW) | resource parses, canonical mapping, whole-token/no-substring discipline ("गीता"/"गीत"), load-failure degradation |
| `Services/Voice` + `CommandRouterDialogueTests.swift` (NEW) | interception placement (answer never reaches the ladder/interpreter — spy interpreter proves zero calls), emergency-mid-frame drops the frame with dispatch unchanged, barge-in falls through and executes once, stale-frame/expiry boundary (last-moment answer vs post-expiry fresh command), confirmation coexistence (hook byte-behaviour), gibberish mid-frame consumes no attempt; file-private doubles per the `CommandRouterMusicTests` pattern |
| `Services/Voice/CommandRouterMusicTests.swift` (CHANGED) | degenerate trigger on both routes replaces the blind search; specific queries byte-identical (existing supersession block kept green); merged dispatch goes through `fireMusicRequest`/`runMusicTurn` |
| `App/VoiceSessionStateMachineTests.swift` (CHANGED) | new state edges legal ±, window-exists opener, timer arm/cancel/expiry, F6 still-open guard, silent callback never speaks, confirmation suite unchanged |
| `Services/Intents` + `DialogueCacheBypassTests.swift` (NEW) | `pendingTranscript` stays nil on frame execution; `IntentCommandCache` never consulted/recorded on the answer turn |
| `Services/Voice` + `DialogueHostileCorpusTests.swift` (NEW) | the security corpus (§24): answers embedding injections/emergency phrases/candidate-list poisons; assert emergency wins, frames clear, no sensitive action without its tier, no fabrication |
| `Services/Voice/KeywordIntentRuleTests.swift` (CHANGED) | provenance cases (content/marker/transcript), `nearMatches` sets, wrapper byte-parity |
| `Services/Voice/IntentPromptTests.swift` + `PinnedSurfaceGuardTests.swift` | Phase 2 only: baseline/digests/anchors updated in the clause change; Phase 1 green unchanged |
| `ios/tools/check-prompt-mirror.sh` self-test; `check-release-log-safety.sh` fixtures | Phase 2 anchor extension; Phase 1 FEATURE_ROOTS + fixture entry |

**Pins that must stay green in Phase 1** (no-regression evidence): golden music digest `fb14012e…`, prompt digests `18003ddd…`/`bd47910d…`, the 2_506 baseline, the 3_000 ceiling, `GoldenCorpusTests`, the Spotify suites, the confirmation-protocol suites.

**DV protocol (FR-MTC-020)** — DV-1..DV-5 per §6, each recorded (date, device, build, transcript script, observed outcome, jetsam log for DV-5) with the feature spec, per the repo's DV convention.

### 30. Traceability

| Requirement | Design section(s) |
|---|---|
| FR-MTC-001 frame lifecycle | §9, §19, §27 C-MTC-01 |
| FR-MTC-002 degenerate detection | §12, ADR-MTC-06 |
| FR-MTC-003 slotFill probe | §9 (composition), §15, §22 |
| FR-MTC-004 candidateChoice | §13, ADR-MTC-07 |
| FR-MTC-005 capture forms | §11 |
| FR-MTC-006 merge/execution | §11, ADR-MTC-11 |
| FR-MTC-007 probe budget | §9, §11 (exhaustion table), §20 |
| FR-MTC-008 escape | §10, ADR-MTC-04 |
| FR-MTC-009 interception | §10, ADR-MTC-02 |
| FR-MTC-010 cancel | §10, ADR-MTC-04 (amendment precedent) |
| FR-MTC-011 emergency | §10 (guarantee 1), §24 |
| FR-MTC-012 barge-in | §10, ADR-MTC-05 |
| FR-MTC-013 timeout | §14, ADR-MTC-08 |
| FR-MTC-014 awaitingSlotAnswer | §14, ADR-MTC-08 |
| FR-MTC-015 catalog | §15, ADR-MTC-09 |
| FR-MTC-016 template probes | §9, §22, ADR-MTC-13 |
| FR-MTC-017 cache bypass | §11, §19, ADR-MTC-11 |
| FR-MTC-018 Phase 2 v17 | §17, ADR-MTC-12 |
| FR-MTC-019 Phase 3 | §18, ADR-MTC-15 |
| FR-MTC-020 DV gate | §6, §29 |
| NFR-MTC-001 turn envelope | §14, §20 (22 s/45 s/60 s unchanged) |
| NFR-MTC-002 prompt budget | §17, ADR-MTC-12 |
| NFR-MTC-003 no egress | §22 |
| NFR-MTC-004 log safety | §22, §27 C-MTC-10 |
| NFR-MTC-005 degraded brain | §16, ADR-MTC-10 |
| NFR-MTC-006 localisation | §22 |
| NFR-MTC-007 jetsam | §16, §6 DV-5 |
| NFR-MTC-008 sanitisation/injection | §11, §24 |
| NFR-MTC-009 voice-only accessibility | §11, §22 |
| NFR-MTC-010 trap resistance | §10, §14, §24 |
| NFR-MTC-011 KV prefix | §17, ADR-MTC-12 |
| NFR-MTC-012 no regression | §7 pins, §29 |

### 31. Open items and risks

For **review-l2**: (R1) the barge-in predicate's stage list (ADR-MTC-05) — design-l2 must pin the exact call sites and add a test per stage the negative examples rely on ("मेरो छोरालाई फोन गर" must resolve through the contact-search/direct-call vocabulary; verify against `VoiceContactSearchRoute.isDirectCallUtterance` `:137`). (R2) The discard-path candidate composition (hypothesis appended last only with ≥1 near-match) — flagged as the least-forced reading of FR-MTC-004's source list; alternative (never re-offer) recorded. (R3) `candidateChoice` exhaustion closes honestly rather than executing (ADR-MTC-07 table) — reconcile with FR-MTC-007's literal wording at review. (R4) The strip/marker rules embedded in §11 — pin with tests, since the FR's examples imply both "markers kept in free text" and "markers droppable for option matching". (R5) Whether the re-probe should reset `attempts` after an escape (design: escape drops the frame entirely, so no reset is needed).

For **security-design-review**: (R6) the emergency-branch frame clear (ADR-MTC-02) — verify non-gating by test (dispatch with the clear forced to a no-op). (R7) The gibberish-guard interaction (§10): rejected noise leaves the frame armed without consuming an attempt — verify no trap (the deadline bounds it) and no log content. (R8) The hostile corpus (§29) must include: answers containing emergency keywords or injection markers, candidate-poisoning utterances, and claims of authority. (R9) Log-gate coverage: the four new files + the modified router paths.

For **design-l2**: (R10) `InterpretedCommand` reuse for `activeCommand` (the free-text `message` entity carries the music query — pin the exact field mapping in the interface). (R11) The shared seam helper's shape (`IntentTranscriptPreparation`) must not disturb `LocalBrainChain.turnInput`'s byte behaviour. (R12) Phase 2's `frameClause` plumbing through `InterpreterContext` vs a `build` parameter — either is acceptable; the mirror gate must see the same text.

Residual risks recorded for the record: the PT-identifier and Stage-3 findings are out of scope (no chat); the Phase 0 smoke is a standing prerequisite; OD-M1..M4 remain owner-facing and are implemented as defaults pending T2.
