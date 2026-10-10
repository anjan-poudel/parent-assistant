# Security design review — Multi-Turn Conversation (STRIDE)

**Task.** `security-design-review` — the security gate of the `multi-turn-conversation` workflow. Workflow exit condition: `review.decision == "SECURITY-GO"`.

**Agent.** sdd-reviewer (ai-sdd), read-only.

**Artifacts under review**

| Artifact | Contract | Size | Status |
|---|---|---|---|
| `specs/design-l1.md` | `architecture_l1` | 680 lines | gate-cleared at `design-l1` |
| `specs/design-l2.md` | `component_design_l2` | 1005 lines | `review-l2` GO (F-1..F-4, C-1..C-5) |
| `specs/review-l2.md` | review record | 245 lines | security-relevant findings carried |

`design-l2.md` sha256 re-verified at review time (chunked here for readability): `9c164658 5b137833 0129c007 8cc4ae0f 3a32ab3e 818e3a86 ac87fe8c 069c6f51`.

**Feature / worktree.** `multi-turn-conversation` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`, branch `feat/multi-turn-conversation`. **Date.** 2026-10-10.

**Basis.** Feature supplement `specs/multi-turn-conversation/constitution.md` (Safety-Relevant Constraints 1-4; Feature Constraints 1-10); root `constitution.md` (Standards: encrypted storage, quarantine-level injection discipline, logs must not contain PII; Release gates: the release log-surface gate wired into `ios/build.sh`); the requirement set FR-MTC-001..020 / NFR-MTC-001..012 (security-relevant: FR-MTC-005/006/009/011/012/013/017, NFR-MTC-004/008/012); the workflow's six security focus areas; `specs/review-l2.md`.

**Verification method.** Read-only; no artifact, workflow file or git state was modified. Every load-bearing security claim was re-checked against shipped source in this worktree — routing order in `route()`, the emergency block, the confirmation hook, the contact/YouTube/keyword predicates, the session state machine and timers, the coordinator window seams, the input seam, `InputSanitiser`, `LogSanitiser`, and the release-log gate (script, shell entry point, `build.sh` wiring). The ledger below states claim, source read and verdict.

## Summary

**Decision: SECURITY-GO** — 8 surfaces threat-modelled, 0 BLOCKERs, 5 must-fix conditions (M-1..M-5), 4 verify-and-record items (V-1..V-4), 8 evidence obligations for `security-test`, 5 accepted residuals.

The load-bearing safety properties hold against the shipped code: the emergency check runs on the raw transcript before every other content handler; the interception block sits between the confirmation hook and the safety net, so an answer turn returns before the interpreter, the cache and the ladder; every recovery word, barge-in, timeout and expiry path resolves the frame; the new sources join the release log gate with per-root fixtures; the feature adds no network surface; and the deterministic merge is the degraded-brain contract. The must-fix items are edit-list and implementation pins found by reading the code — wiring and bookkeeping, not design rework.

- **M-1** — the pipeline-state guard is not extended to the new window state, so pipeline events can close the window and cancel its timer.
- **M-2** — four confirmation arming sites transition the session directly, not through the window opener the design names as the funnel.
- **M-3** — the answer sanitiser source must be pinned in production (the shared helper's nil-seam path returns the raw transcript).
- **M-4** — log-gate bookkeeping: six new metadata keys, not seven, and the pre-existing `reason` key must hold closed tokens only.
- **M-5** — candidate-index bounds: the classifier's index must never address outside the frame's candidate list.

## Verification ledger

| # | Claim | Source read (worktree) | Verdict |
|---|---|---|---|
| 1 | Emergency check precedes all answer handling; reads the raw transcript | `CommandRouter.swift:775` (`preText = raw`), `:779-783` | HOLDS |
| 2 | The planned emergency frame-clear is side-effect-only after dispatch; it gates nothing | design-l2 `:542-548`; shipped branch `:779-783` | HOLDS |
| 3 | Interception insertion point between the confirmation hook and the safety net | `:789-886` (hook), `:897-899` (safety net); design-l2 `:486-538` | HOLDS |
| 4 | Handler order: sanity `:747-758` → emergency `:779-783` → hook `:789-886` → interception `:886-897` → safety net `:897-899` | direct read | HOLDS |
| 5 | B1-B7 predicate sites exist and compile as planned | `CommandRouter.swift:1913`, `:1869`; `VoiceContactSearchRoute.swift:52-58,67,101,137-140`; `YouTubeRoute.swift:41-46,56`; `KeywordIntentRule.swift:164` | HOLDS |
| 6 | Access widenings (L2-D2) match the declarations | `:1869` `private static let`; `:137-140` `private static func`; `:1913` already internal | HOLDS |
| 7 | Medication-ack exclusion is scoped to app-launch confirmations | `CommandRouter.swift:858-862` | HOLDS |
| 8 | Music parity: ladder arm and interpreted dispatch converge on one executor | `:1223-1234` (`:1233`), `:3336-3355`, `:2667-2678`, `:2614-2647` | HOLDS |
| 9 | State machine mirrors (enum, edges, Talk reset, Config, transition, opener, arm guard, cancel) | `VoiceSessionStateMachine.swift:9-17,21-57,71-78,93-96,111-127,153-181,183-208` | HOLDS |
| 10 | The pinned window-seconds expression cannot type-level address the instance `Config` property (carried F-1/C-1) | `:93-96`; design-l2 `:54,:207,:687,:917` | CONFIRMED, mechanical |
| 11 | Confirmation timeout speaks; the frame timeout must not, and must not call `recordConfirmationTimeout` | `AppCoordinator.swift:2996-3038` (`:3035-3036`); ADR-MTC-08 | HOLDS |
| 12 | The window opener is the main-hop funnel with two callers | `:7019-7027`; callers `:7008`, `:10337` | HOLDS |
| 13 | Four confirmation arming sites transition the session directly, not via the opener | `:7228`, `:7401`, `:7461`, `:8548` | CONTRADICTS edit 9 → M-2 |
| 14 | `handlePipelineState` early-return guard is single-state and absent from the edit lists | `:4750-4766` (guard `:4756`); design-l2 §14/§15 edit lists | GAP → M-1 |
| 15 | Watchdog fires only in `.listening`; Talk reset suppressed in the window states | `:4865`, `:4871`; `VoiceSessionStateMachine.swift:71-78` | HOLDS (M-2's observer owed) |
| 16 | `isAwaitingConfirmation` is pending-field based, not state based | `:10535-10540` | HOLDS |
| 17 | Sanitiser discipline: quarantine level, 200-char clamp behind a raw-length gate (L2-D5) | `InputSanitiser.swift:22,37-50,52-85`; design-l2 `:760` | HOLDS |
| 18 | Shared seam: sanitise then `seam.prepare`; nil seam returns raw as `prepared` (byte-parity) | `LocalBrainChain.swift:275-285,296-307`; design-l2 `:715` | HOLDS; M-3 pins production |
| 19 | Production input seam wired non-nil | `AppCoordinator.swift:1812-1825` | HOLDS |
| 20 | Transcript recording at route entry (existing policy); cache untouched because `pendingTranscript` is dispatch-only | `CommandRouter.swift:741`, `:3307`, `:1516-1518`; `AppCoordinator.swift:5986-5999` | HOLDS (V-3, R4) |
| 21 | Log choke point: unknown keys dropped; `reason` pre-allow-listed; other allowed values shape-scrubbed only | `LogSanitiser.swift:466-511` (drop `:483`), `:175` | CONFIRMED → M-4 |
| 22 | Release gate: feature-root rules, four new roots, per-root fixtures, shell wiring | `check-release-log-safety.py:141-176,664-701`; `check-release-log-safety.sh`; `ios/build.sh:431` | HOLDS |
| 23 | The `emit` helper is two-argument; §12.2's three-argument call does not exist (carried F-3/C-3) | `:3982-3991`; direct-construction pattern `:1406-1413` | CONFIRMED → M-4 |
| 24 | Debug-only text print in `speak()` (pre-existing) | `:3850-3851` | RESIDUAL R1 |
| 25 | Gibberish guard precedes the emergency check | `:747-758` vs `:779` | HOLDS (V-1, R5) |
| 26 | Candidate execution shape `executeDialogueCandidate(index - 1, ...)` needs a bounds pin | design-l2 `:517-524`, `:862` | GAP → M-5 |

Assets: the frame's slot value and candidate set; probe and answer text; the window/session state; the intent cache and chat history; log and telemetry sinks; the emergency dispatch path. Boundaries: microphone/STT → `route()`; router → coordinator hooks (main-queue confined); coordinator → state machine and dialogue manager; events → `LogSanitiser` → observability bus; the release gate over the four new source files; network egress (unchanged by this feature).

## STRIDE threat model

### S1 Emergency precedence mid-dialogue (Spoofing, Elevation)
Threat: a hostile or corrupted answer reaching the merge or an executor ahead of, or in place of, the emergency dispatch. Verified: the check (`:779-783`) runs on the raw transcript (`:775`) before the hook and the interception; the planned clear is post-dispatch and gates nothing; no answer handling runs before it. Residual: the sanity guard (`:747-758`) sits above it — shipped ordering (V-4/R5). Evidence: E1.

### S2 Free-text answer into routing and execution (Tampering, Elevation)
An answer carrying command vocabulary, structured text or tool-shaped payloads must not steer execution beyond the frame's two admissible effects — fill one slot value, or pick one enumerated candidate — and must not reach the interpreter or cache. Verified: interception before the ladder and interpreter; classification is a pure function over the prepared text plus the frame; execution stays inside the frame's own domain seam. Barge-in predicates (B1-B7) only decide whether an utterance executes as itself under normal tiers — the not-trapped requirement, not an injection. Sanitisation rides the shared helper; M-3 pins the production seam. Evidence: E2, E8.

### S3 Frame-trap resistance (Denial of service)
No state the user cannot leave: cancel and escape words resolve and ack; barge-in resolves and falls through to execute once; the 45 s timer mirrors the confirmation machinery including the still-open guard; frame reads are expiry-checked; resolve is idempotent; Talk reset is suppressed inside the window, with the watchdog and Talk recovery as outer backstops. Gaps: M-1 (the timer can be cancelled by pipeline events) and M-2 (the transition-out observer is under-anchored). Evidence: E3.

### S4 Answer authority claims and candidate poisoning (Spoofing, Tampering)
An answer claiming to be a confirmation, naming an unlisted candidate, or engineered to match another domain must not change what executes. Verified: picks address the frame's candidate list only; the merge value is data; tiers do not read the answer (hostile-corpus row `testAnswerClaimingATierChangesNothing`); B6 keeps a same-domain music match from bouncing mid-music answers to the ladder. M-5 pins index bounds. Evidence: E2.

### S5 Log and observability disclosure (Information disclosure)
Probe, answer and candidate text must not reach logs or telemetry beyond the existing transcript policy. Verified: closed-vocabulary events with count/enum metadata; the four new source files join `FEATURE_ROOTS` (any non-Debug console write fails; content-worded writes fail in any configuration; unlisted metadata keys fail); the unknown-key drop at `LogSanitiser.swift:483` is the runtime choke point. Gaps: M-4. Note: the router/coordinator edits live outside the feature roots — the gate's transcript/error rules are the only static cover there; E4/E5 carry the burden. Evidence: E4, E5.

### S6 Egress (Information disclosure)
Probes and answers must stay on-device. Verified by source shape: no new network calls; the merged music command reuses `fireMusicRequest` (`:2667`) through the same seam a directly spoken request uses; probes and acks ride the on-device reply lane (`speak` → `noteAssistantSpoke`, `CommandRouter.swift:3864`). Evidence: E6.

### S7 Degraded-brain path integrity (Tampering)
With the brain abstaining or unavailable, the merge must not weaken safety. Verified structurally: the answer turn returns from the interception block before the interpreter, so the deterministic merge cannot depend on brain output; the Phase 2 clause is defaulted off; the emergency path and confirmation tiers are untouched by the merge. Evidence: E7.

### S8 Window lifecycle and co-existence (Tampering, Denial of service)
A live frame and a confirmation window must not coexist, and no session transition may strand a frame. Verified: arming a frame refuses while any pending confirmation exists (edit 3's guard over the pending-field `isAwaitingConfirmation`, `:10535-10540`); the opener is a main-hop funnel; turn serialisation keeps one utterance in flight. Gaps: M-1 and M-2 — the four direct arming sites and the pipeline-state guard sit outside the funnel the design names, and "any transition out resolves" is not anchored to an edit. Evidence: E3.

## BLOCKERs

None. Every gap above is bounded by shipped invariants — turn serialisation, expiry-checked frame reads, the pending-field window check, the unknown-key drop — and none yields a reachable path that dispatches emergency late, executes an unasked action, opens an egress, or leaves a user without a recovery word. They are must-fix conditions on the implementation (M-1..M-5), not design defects that block this gate.

## Conditions carried to plan-tasks / implement

- **M-1 (window state can be closed by pipeline events).** Shipped `handlePipelineState` returns early only for `.awaitingConfirmation` (`AppCoordinator.swift:4756`), and the comment above it states why — pipeline events must not close a window that owns the turn. The C-MTC-07/C-MTC-08 edit lists do not extend the guard to `.awaitingSlotAnswer`, so the probe's own speaking/listening events can transition the session out of the window and cancel the slot timer; the 45 s silent close and its `.timedOut` event would then never fire. Add the guard extension to the edit list; pin with a pipeline-events-mid-window test (E3).
- **M-2 (mutual-exclusion wiring under-anchored).** Edit 7 funnels `openConfirmationWindow()` only; edit 9 asserts the pending-rephrase seams "pend through the window opener" — false in code: `startRephraseConfirmation` (`:7401`), calendar (`:7228`), call (`:7461`) and navigation (`:8548`) transition the session directly. The claimed "any transition out resolves through the coordinator funnel" (L2 risk 12) is likewise not anchored to a concrete hook. Route the four sites through the funnel or add resolve-at-site, and name the observer that resolves the frame on any legal session exit; pin with Talk-mid-window, watchdog-mid-window and pipeline-event tests (E3).
- **M-3 (answer sanitiser source pinned).** `IntentTranscriptPreparation` returns the raw transcript as its answer value when the seam is nil (deliberate byte-parity with `turnInput`). Production wires a non-nil seam (`AppCoordinator.swift:1824`) and the router fallback sanitises when the coordinator is absent, but no test pins either fact. Pin the production wiring (seam non-nil; or sanitise in the helper's nil-seam path for the answer value) and keep the parity path test-only. No production path may consume an unsanitised answer (NFR-MTC-008).
- **M-4 (log-gate facts corrected).** `reason` is already in `LogSanitiser.allowedKeys` (`LogSanitiser.swift:175`); of the seven proposed keys, six are new. The design text and the §26 justification must read six-new-plus-one-reused; because `reason` is generic and pre-existing, dialogue values under it must be closed enum tokens enforced at the construction site. The carried F-3/C-3 three-argument `emit` must be implemented by direct event construction (`:1406-1413` pattern) — the `reason` metadata must never be dropped to make it compile.
- **M-5 (candidate index bounds).** `executeDialogueCandidate(index - 1, ...)` trusts the classifier's index. `DialogueAnswerPath.classify` / `matchCandidate` must be total over the frame's candidate list and the executor must bounds-check; a hostile answer must not be able to address outside the frame's candidates or induce a crash (local denial of service).

Carried mechanical conditions from `review-l2` (no security content beyond being done): C-1 (the pinned default-argument expression cannot type-level address the instance `Config` property `:93-96`; keep 45 s single-source with no new literal), C-2 (news-arm anchor), C-5 (bind the taken rephrase command at `:806`).

## Verify-and-record items

- **V-1.** Gibberish mid-frame: the sanity guard (`:747-758`) precedes the emergency check and the interception; such an utterance is dropped with the router's reprompt, increments no attempt, and the frame lives to its deadline (§18's gibberish row). Record the ordering so later edits keep it.
- **V-2.** Debug lanes: the touched legacy files (router, coordinator) carry Debug-only prints and are outside the feature roots; record that the diff adds no console write there — the gate's transcript/error rules are the only static cover for those files.
- **V-3.** Answer flow vs persistence: `recordTranscript` runs for every utterance (existing policy) while `pendingTranscript` stays dispatch-only, so the intent cache is not taught by answers; re-verify after implementation (E8).
- **V-4.** Sanity-guard-above-emergency ordering (R5): record as pre-existing and unchanged.

## Evidence obligations for security-test

- **E1 — emergency answer mid-frame.** With a frame live, an utterance embedding emergency vocabulary dispatches emergency; the frame is cleared with `.emergency`; dispatch is proven independent of the clear by forcing the clear to a no-op (§18 `E2` row).
- **E2 — hostile answer corpus through the production-shaped seam.** Injection-marker text, control characters, structured/tool-shaped payloads, candidate-poisoning utterances and authority claims all resolve to the frame's admissible effects or a re-probe/close; no interpreter, no cache, no crash; run through a non-nil seam so the sanitiser is exercised (M-3).
- **E3 — trap matrix.** Cancel, escape, barge-in, timeout, expiry, Talk-mid-window, watchdog-mid-window and pipeline-events-mid-window all recover; after 45 s no window is half-open; resolve stays idempotent (covers M-1, M-2).
- **E4 — log capture over a full dialogue.** Probe, answer, merge, cancel, timeout, escape, exhaustion and the did-you-mean path, in Debug and Release: zero raw transcript/answer/probe/candidate text in console and log sinks (NFR-MTC-004 scenarios 1-3); `ios/tools/check-release-log-safety.sh` exits 0 including its fixtures suite, with the four new roots and their fixture entries present.
- **E5 — log allow-list diff and value vocabularies.** Exactly the six new keys are added; `reason` is reused with closed tokens; every dialogue event field is a non-content token; the unlisted-key drop remains in force at the runtime choke point.
- **E6 — egress.** Source-level grep (design §29) shows zero new network calls in the feature's files; the merged music path calls only the existing helper (`fireMusicRequest`, `:2667`).
- **E7 — degraded brain.** With the brain abstaining or unavailable, the merge remains deterministic; emergency precedence and confirmation tiers are unchanged; the Phase 2 clause is off in Phase 1 builds (prompt-digest pins).
- **E8 — cache/history boundary.** No answer text reaches `pendingTranscript` or the intent cache on the frame execution path; chat history follows the existing transcript policy unchanged.

## Accepted residuals (explicit)

- **R1.** Debug-configuration prints in touched legacy files (e.g. the `#if DEBUG` text print in `speak()`, `CommandRouter.swift:3850-3851`) remain possible in Debug builds; they cannot compile into Release (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` is Debug-only) and the design adds none.
- **R2.** The release gate is a static source check with documented blind spots (indirection, runtime-assembled metadata — its own header states them); the runtime choke point, typed construction and E4/E5 are the primary arms.
- **R3.** Values of allow-listed string keys are scrubbed for PII shapes but not value-constrained; closed vocabularies at construction sites are the discipline (M-4, E5).
- **R4.** Answer utterances are recorded into the on-device chat history by the existing transcript policy (V-3); no new persistence or egress is introduced.
- **R5.** The sanity guard precedes the emergency check (`:747-758` vs `:779`); an utterance it rejects is dropped with the router's reprompt before any handler — shipped ordering, unaltered by this feature (V-4).

## Decision

decision: SECURITY-GO

**Rationale.** The safety constraints with security content are carried by verified structure: emergency precedence is absolute (check on the raw transcript at `:779-783`, ahead of every content handler; the planned clear is post-dispatch and cannot gate); the answer path opens no new injection surface (pre-ladder interception, pure-function classification, execution confined to the frame's own domain seam, quarantine sanitisation through the shared helper with M-3 pinning the production wiring); and log safety keeps its shipped framing (closed-vocabulary events, four new gate roots with fixtures, the unknown-key drop). Frame-trap resistance is genuinely backed by the confirmation-machinery mirror, expiry-checked reads, idempotent resolve and the suppressed Talk reset. The five must-fix conditions are wiring and bookkeeping gaps found by reading the shipped code — specific, real, and fixable inside `plan-tasks`/`implement` without design rework; none is a reachable path that dispatches emergency late, executes an unasked action, opens an egress, or leaves a user without a recovery word. No BLOCKER exists; the gate passes with the conditions above binding implementation and the evidence obligations binding `security-test`.
