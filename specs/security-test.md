# Security Test — multi-turn-conversation

**Status:** complete — read-only independent review; all re-runs executed in the feature worktree on 2026-10-11.

## Metadata

| Field | Value |
|---|---|
| Task | security-test (ai-sdd workflow step; exit condition review.decision == "SECURITY-GO") |
| Feature | multi-turn-conversation |
| Project | elderly-ai-assistant — local on-device elderly voice assistant (iOS); no server component in this feature |
| Date of review | 2026-10-11 |
| Worktree / branch | feature worktree for multi-turn-conversation / feat/multi-turn-conversation (absolute path in References) |
| Reviewed HEAD | a55e22c ("Record review-implementation GO for multi-turn-conversation"); it changes only .ai-sdd state and spec files relative to the content revision, so production source at HEAD is byte-equal to 134d77e |
| Feature content revision | 134d77e (diff base 0cbe4e6) |
| Artifact under test | specs/MTC-security-evidence-index.md, sha256 d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617 |
| Inputs consumed | the evidence index; security-design-review.md; review-implementation.md; T-137 through T-142 notes; MTC-device-validation-protocol.md; feature and root constitutions; the workflow step's focus comment (workflow.yaml:165-173); live source and tests in the worktree |
| Replacement note | This file fully replaces its inherited content (a prior feature's security-test record); nothing of the inherited record is retained. |

## Summary

The multi-turn-conversation feature adds a one-deep dialogue frame to voice turns: a probe is spoken, the spoken answer is captured, merged deterministically, and the merged command executes. The workflow's security-test step asks five questions: emergency precedence mid-frame; probe/answer text never reaching logs; cancel, barge-in and the 45 s timeout always recovering; the degraded-brain fallback honoured; and the did-you-mean candidate list unable to skip the routing ladder. This review answered all five by independent means: the evidence index was validated structurally and re-hashed; the two cheap static gates were re-run; every verdict-weight claim was spot-verified down to source file:line; diff scope and new egress were re-checked; and the standard categories (injection, log/PII, secrets, authorization, dependency changes, human-gate auto-resolution) were swept. All five focus areas PASS; the index's coverage boundaries are honest and none over-claims; no false evidence claim, no plausible coverage hole and no unmet security requirement was found. Decision: SECURITY-GO, 0 blockers, confidence 0.90. Carried items (all device-scope or recorded test boundaries, enumerated in Gaps) belong to the final sign-off, not to this gate.

## Decision

decision: SECURITY-GO
confidence: 0.90
blockers: 0

All review criteria are met. Emergency precedence runs on the raw transcript before every content handler and does not depend on the frame clear; probe and answer text can only reach the observability bus through six new closed keys (out-of-vocabulary values redacted, unlisted keys dropped fail-closed); every trap exit — cancel, escape, barge-in, 45 s silent timeout, expiry, Talk-mid-window, watchdog and session exit — recovers through one idempotent resolve funnel; the degraded path is model-free and pure; and the candidate list is bounded, total, and cannot skip the routing ladder or any existing confirmation tier.

Confidence is 0.90 rather than 1.0 for two honest reasons: the feature's unit-suite evidence was consumed from the committed producer records and spot-checked in source rather than re-executed by this review, and device validation is outstanding by design. Neither reason touches a verdict-weight claim; both are stated in Gaps.

## Scope and method

- Scope: feature content 134d77e against base 0cbe4e6 — 14 changed production Swift files (the four dialogue helper files plus AppCoordinator, VoiceSessionStateMachine, HomeView, HomeSubviews, IntentTranscriptPreparation, LocalBrainChain, LogSanitiser, CommandRouter, KeywordIntentRule, VoiceContactSearchRoute), the new dialogue test suites, the log-safety gate and fixture trees, and the feature's spec and evidence records. Path shorthands below: Services/Voice/, App/, Services/Intents/, Services/Observability/ and Resources/ under ios/ElderlyAssistant/; tests under ios/ElderlyAssistantTests/.
- Method: (a) index integrity — structural validator re-run plus a fresh sha256; (b) the two static gates re-run read-only with exact rc values recorded; (c) source spot verification of every index claim carrying verdict weight; (d) egress and diff-scope check; (e) category sweep, including a source-and-diff check that no added code path auto-resolves a human gate; (f) adversarial re-read of the index's coverage boundaries for over-claiming, and of the workflow focus comment against the evidence.
- Not in scope, deliberately: builds, simulator, device runs, full unit gates. This review did not re-execute the feature's unit suites; unit evidence is taken from the committed producer records and is spot-checked in source.
- Read-only: the only file written by this review is this report; no ai-sdd command was run; no state-mutating git command was issued.

## Focus-area verdicts

### F1 — Emergency precedence mid-frame: PASS

The emergency check executes on the raw transcript inside route(), before every other content handler: the lowercased prepared text is built from the raw transcript at CommandRouter.swift:839-842, the phrase check is at :843, the event emits at :844, handleEmergency() dispatches at :845, the frame clear is a post-dispatch side effect at :853, and the method returns .emergencyTriggered at :854. The confirmation hook (the next handler) follows at :861, and the dialogue-frame interception block begins only at :1021 (frame gate :1039).

The frame clear is therefore not load-bearing: the E1 pair (DialogueHostileCorpusTests, :244-288) proves the dispatch stands with the clear forced to a no-op and observes the clear only after the assistant spoke (post-dispatch ordering via callLog). Cross-check: an emergency phrase arriving as a frame answer is emergency-checked on that same utterance before classification, because the check precedes the interception for every route() call; the resolution vocabulary carries .emergency in a closed 10-case set (DialogueManager.swift:192-205).

### F2 — Probe/answer text never reaches logs: PASS

- Write surfaces: the four new dialogue sources contain no console write; the release gate's FEATURE_ROOTS now lists all four (tools/check-release-log-safety.py:184-187) with per-root positive/negative fixture trees (feature-console-write, feature-content-print).
- Choke point: the LogSanitiser allow-list moved 78 to 84 with exactly six new keys at Services/Observability/LogSanitiser.swift:343-348 (intake, probe_kind, attempt, option_count, capture_form, merge_source), the pre-existing reason key at :175, and closed value vocabularies at :448-452; out-of-vocabulary values redact and unlisted keys drop fail-closed. The router's dialogue emissions carry only those keys: emitDialogueAnswer sends capture_form and merge_source only (CommandRouter.swift:3296-3308); the invalid-answer note uses reason with producer-closed tokens (:1096-1103); emitDialogueFrameResolved uses a closed outcome vocabulary (:3318-3339).
- Runtime capture: the full-dialogue leg scans planted marker tokens against bus-format sink lines (DialogueLogAndEgressTests, assertSinkHygiene :157-196) and the hostile corpus suites assert hostile text absent from telemetry; answer text reaches neither the intent cache nor pendingTranscript (E8 rows; DialogueCacheBypassTests, Mirror pin :146-149).
- Boundary honesty and sanitisation: the index scopes the marker-scan claim to sink lines (boundary 1) and records the spoken did-you-mean output and the legacy Debug print as residual R1 — accurate, no over-claim. Every production answer path uses the non-nil shared seam (AppCoordinator.swift:11048-11052, :11159-11162); classification reads the raw transcript only for the raw-length gate C1 (DialogueAnswerPath.swift:193) and takes its working text from the prepared value (:197).

### F3 — Cancel, barge-in and the 45 s timeout always recover: PASS

- Exits: expiry is half-open on the frame (DialogueManager.swift:94: now >= deadline) and dropped on read (:234-241); classification checks expiry first (C0, DialogueAnswerPath.swift:188) and the router treats .expired as a fresh command (CommandRouter.swift:1055-1058); escape (:1059-1063) and cancel (:1064-1068) resolve and speak closed lines; barge-in (:1069-1075) resolves the frame and deliberately falls through so the strong command runs once through the normal ladder.
- Timeout: the 45 s timeout is the session machine's slot-answer clock (AppCoordinator.swift:3081 wires voiceSession.onSlotAnswerTimeout; Config.confirmationTimeoutSeconds = 45 at App/VoiceSessionStateMachine.swift:120; armSlotAnswerTimer :302-323 with the still-open guard :318 and a silent callback :320) and resolves the frame as .timedOut silently — it never enters the confirmation-timeout recording path.
- Funnel and guards: resolveDialogueFrameOnMain (AppCoordinator.swift:11093-11109) clears the frame first, then closes the window, emitting telemetry only for timedOut/emergency/superseded; DialogueManager.resolve is idempotent (:285-289); the session-exit observer (:3100; resolveDialogueFrameOnSessionExit :11116-11120) supersedes on any window loss; the M-1 pipeline guard refuses both window states (AppCoordinator.swift:4830-4831).
- Test cover: the trap matrix's eight rows all terminate with the shared triple assertNoHalfOpenWindow / assertLateHourglassIsANoOp / assertResolveTwiceIsANoOp (DialogueTrapMatrixTests :136-185, rows :198-432).

### F4 — Degraded-brain fallback honoured: PASS

- Model-free purity: classification and merge are pure functions (DialogueAnswerPath.swift:188-472; merge at :342-377 raises DialogueError.emptyMerge rather than inventing content), pinned by the merge-purity test in DialogueAnswerPathTests and by assertNoModelOrCacheConsultation in the hostile corpus suites; probes are template-composed (DialogueProbeComposer :298-370) from the curated on-device catalog; on answer turns the interpreter count is 0 (E2/E7/E8 rows, recorded and spot-checked).
- The merge cannot weaken gates or tiers: the merged result (InterpretedCommand.merging, 14 fields, :711-718) re-enters the ordinary dispatch pipeline; the emergency check already ran on the same utterance before interception (F1) and the frame is cleared on any emergency; merged side effects keep their normal tiers — an appLaunch candidate still pends through pendAppLaunch into openConfirmationWindow (AppCoordinator.swift:7025+, :7081-7084); candidate domains exclude medication by construction (DialogueCandidateBuilder: news, youtube, music, appLaunch only; slot-fill candidates fail closed on an unknown group). A degraded brain therefore changes nothing about what the feature can execute or skip.

### F5 — The did-you-mean candidate list cannot skip the routing ladder: PASS

- Gate order and bounds: the interception block sits after the confirmation hook and before the safety net (:1021-1139), entered only with a live frame (:1039). Within it, escape/cancel/barge-in outrank any answer (C2-C4 before C5/C6 in classify order); a bare index word resolves only inside the candidate count (S1-S6, DialogueAnswerPath.swift:382-472); matching is total (:314-323); and free text on a candidate frame routes .freeFormForCandidate back to ladder behaviour (:1084-1088) instead of forcing a pick. An invalid or unclaimed answer consumes an attempt (:1096-1103) against the probe budget (DialogueConfig.maxProbes :1119) and then exhausts honestly via resolveDialogueExhaustion (:1124, :3266-3276) — never a silent execution.
- Execution bounds and sensitive tiers: the candidate executor refuses out-of-range indices with its own guard (CommandRouter.swift:3199-3204) and closes as exhausted; the framable domains are the four curated ones; the hypothesis is offered only alongside at least one near-match (builder pairing rule, R2); startDialogueFrame refuses while a confirmation is pending or a frame is live (AppCoordinator.swift:10975-10987); app launches keep their confirmation (requestAppLaunch into pendAppLaunch, AppCoordinator.swift:7025+, :7081-7084).
- Human-gate check: the confirmation hook's routing is untouched — its yes branch still reaches handleConfirmationResponse(:yes) (:997); the diff's only hook-region hunk (CommandRouter.swift, new-file offset :875) is the rephrase-discard rebuild on the no path: it binds the taken hypothesis and re-offers it as the last candidate; with zero candidates or a window that cannot open, the shipped line stands byte-identical; it confirms nothing and resolves no frame (deferred arm ordering per W4 F-1). A source grep found no direct transition to awaitingConfirmation remaining, and the opener supersedes a live frame instead of stacking (:7094-7113).

## Category verdict table

| Category | Verdict | Basis |
|---|---|---|
| Injection / hostile input | PASS | Quarantine sanitiser on every production answer path (non-nil seam, AppCoordinator.swift:11048-11052 and :11159-11162); the hostile corpus suites (E2) resolve injection markers, control characters and poisoned candidates to closed effects with interpreter 0 and cache 0, with causal control legs; unlisted metadata keys drop fail-closed. |
| Log / PII exposure | PASS | F2 — six closed keys, redaction, sink-scoped marker scan, release gate rc=0 (24 cases over 12 rules). |
| Secrets | PASS | No credential or key material appears in the diff; nothing new to protect. |
| Authorization | N/A (true) | Local single-user on-device app — no authn/authz surface exists; the analogous control, the human confirmation tier, is verified preserved (F5). |
| Human-gate auto-resolution | PASS | No added code path answers or auto-resolves a confirmation (F5 hook check); startDialogueFrame refuses while a confirmation is pending; four arming sites route through the opener; nothing in the feature touches the ai-sdd state. |
| Dependency changes | PASS | No package manifest or lockfile change in the production diff. |
| Egress | PASS | 0 network symbols among the added lines of the 14 changed production files (re-run below). |
| Trap resistance | PASS | F3. |
| Emergency integrity | PASS | F1. |

## Evidence-index integrity (E/V/M/R)

- E1..E8: 8/8 rows populate producer, exact command, observed result and a reproducible pointer; the re-run validator resolved all 43 cited Suite.test tokens to functions in the test tree and found no missing pointer; the NFR self-scan (no user text, no marker tokens, no fixture literals) passed. Spot checks: E1's forced-no-op-clear construction and post-dispatch ordering match DialogueHostileCorpusTests (:244-288); E3's rows match the trap matrix (:198-432); E4/E5's key claims match LogSanitiser (:343-348, :448-452).
- V-1..V-4: 4/4 with dispositions; V-3 is recorded as re-verified by observation (T-140's counters and Mirror readings), not assumed; V-4 (sanity guard above emergency) matches the shipped ordering and its own test.
- M-1..M-5: 5/5 pinned. Spot checks done here: M-1 guard AppCoordinator.swift:4830-4831; M-2 opener :7094-7113 and the four arming sites (:7317, :7490, :7550, :8638); M-3 seam :11048-11052 and :11159-11162; M-5 executor guard CommandRouter.swift:3199-3204. M-2's recorded residual scope (medication-challenge supersede path untested behaviourally; only the four sites source-pinned) is carried openly — no closure claimed.
- R1..R5: 5/5 recorded with accepted dispositions that match the design review — R1 legacy Debug prints; R2 static-gate blind spots; R3 allow-listed values scrubbed but not value-constrained (closure at producers); R4 answers recorded into on-device chat history under the existing policy; R5 sanity guard above emergency, pre-existing. None is worded as a closure; none hides a live issue found by this review.
- Coverage boundaries 1..7: assessed honest — each states what the gate does not cover. Boundary 1's scoped citation matches the suite's own note; boundary 3 (FR-MTC-019 ask-lines), boundary 5 (measured base inventory) and boundary 6 (device validation open) match the record and the device protocol. No boundary conceals a failure.

## Independent re-runs (fresh, 2026-10-11, from the worktree root)

1. Structural validator (index integrity) — command:
   python3 /tmp/mtc-t142-validate.py
   Observed rc=0; output: E-rows 8/8 (6 cols, ids E1..E8); V-rows 4/4; M-rows 5/5; R-rows 5/5; no table cell empty or INCOMPLETE; E-row reproducible pointers 8/8; cited Suite.test tokens 43, missing 0; NFR self-scan devanagari=0 markers=0; FAILURES: 0. Reproduces the retained producer log /tmp/mtc-t142-validate.log.

2. Release log-safety gate — command:
   bash ios/tools/check-release-log-safety.sh
   Observed rc=0; "log-safety fixtures: 24 case(s) over 12 rule(s)"; every rule has a positive and a negative fixture and every fixture behaves, including the dialogue per-root entries. Output retained at /tmp/mtc-st-gate.log.

3. Fixtures falsification discipline — command:
   python3 ios/tools/check-release-log-safety-fixtures.py --falsify
   Observed rc=0; "log-safety fixtures: 36 case(s) over 12 rule(s)"; "every rule is load-bearing: disabling it makes its positive fixture pass". Output retained at /tmp/mtc-st-falsify.log.

4. Index provenance — command:
   shasum -a 256 specs/MTC-security-evidence-index.md
   Observed: d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617 — equal to the corrected final value recorded in T-142-notes.md; the file of record is the file reviewed.

5. Egress and scope — commands:
   git diff --name-only 0cbe4e6..134d77e -- 'ios/ElderlyAssistant/**/*.swift'   (returned 14 files; the list is exactly the designed production set — the four dialogue helper files plus ten touched legacy files); an added-line scan over the same range and paths for the network-symbol set (URLSession, URLRequest, http/https URL literals, NWConnection, Network.framework, socket(, curl) returned 0 matches. The wider 0cbe4e6..134d77e range additionally carries the feature's specs, tests and state files, as designed. Retained lists: /tmp/mtc-st-prod.txt, /tmp/mtc-st-diffnames.txt.

## Verification ledger (claim → strongest independent check)

| Verdict-weight claim | Strongest independent check made in this review |
|---|---|
| Evidence index complete, reproducible, honest | Validator re-run rc=0 (rows 8/4/5/5; 43/43 tokens resolve; FAILURES 0) plus a fresh sha256 of the index (re-runs 1 and 4) |
| Log-safety gate green with the dialogue roots live | Gate re-run rc=0; falsification rc=0 with every rule load-bearing (re-runs 2 and 3) |
| Emergency check precedes interception and the frame clear is not load-bearing | Source anchors CommandRouter.swift:839-854 against :861 and :1021; the E1 pair read in source (:244-288) |
| Only six closed keys can carry dialogue telemetry | Source anchors LogSanitiser.swift:343-348 and :448-452; CommandRouter.swift:1096-1103, :3296-3308, :3318-3339 |
| Every trap exit recovers; timeout is silent | Source anchors across DialogueManager, DialogueAnswerPath and the state machine (F3); the trap matrix read in source |
| Merge is pure and gathers no model input on answer turns | Source read of the merge and classify paths; unit counts consumed from the committed records, not re-executed here |
| Candidate picks stay inside bounds and inside the normal tiers | Source anchors CommandRouter.swift:3199-3204 and AppCoordinator.swift:10975-10987; diff read of the hook-region hunk |
| No new egress | Fresh diff scan — 0 network symbols across the 14 changed production files (re-run 5) |
| No human-gate auto-resolution | Diff read of the hook region; empty grep for a direct transition to awaitingConfirmation |

## Gaps, limitations and carried items

1. Device validation: DV-1..DV-5 are all BLOCKED and step zero (the Phase 0 device smoke) is OUTSTANDING per specs/MTC-device-validation-protocol.md. Carried to the final device sign-off (FR-MTC-020); not a blocker here — no claim in this decision depends on an unverified device result.
2. FR-MTC-019 literal missing-time / missing-title ask-lines are tested nowhere (coverage boundary 3); the handlers are untouched by the feature and Phase 1 scopes them as no-change. Carried, not a blocker.
3. Marker-scan scope: log-hygiene marker scanning covers bus-format sink lines only; the did-you-mean spoken output and the legacy Debug print sit outside it (R1). Stated honestly in the index; a spoken-output surface and a non-release surface, not log surfaces.
4. M-2's medication-challenge supersede path is behaviourally untested; only the four arming sites are source-pinned (T-136 F-4). No auto-resolution exists; carried as a record-scope note.
5. V-2 anchor extension remains optional at the next touch (T-136 F-5) — noted, not required.
6. T-138 fixture scoping for the metadata-key and interpolated-event rules (boundary 7) is a recorded test-shape note, accepted.
7. Bookkeeping: the measured base inventory (boundary 5) supersedes the older failure-count estimate; noted so no older figure is re-read as current.

None of these is a security-test blocker: each is a device-scope carry, a recorded coverage boundary with mitigations, or a residual accepted by the design review; none of them makes a claim this decision relies on false or unproven, and none leaves a focus area without evidence.

## References

- Worktree (absolute): /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation — branch feat/multi-turn-conversation, HEAD a55e22c, content revision 134d77e, base 0cbe4e6.
- specs/MTC-security-evidence-index.md — sha256 d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617.
- specs/security-design-review.md — the E/V/M/R ledger this gate consumes.
- specs/review-implementation.md — implementation review, GO at 0.90.
- specs/T-137-notes.md, specs/T-138-notes.md, specs/T-139-notes.md, specs/T-140-notes.md, specs/T-141-notes.md, specs/T-142-notes.md; specs/implement-notes.md.
- specs/MTC-device-validation-protocol.md — device validation status (all BLOCKED / step zero OUTSTANDING at review time).
- specs/multi-turn-conversation/constitution.md; constitution.md (root).
- specs/multi-turn-conversation/workflow.yaml:165-173 — this step's focus comment and exit condition.
- Source shorthand roots: ios/ElderlyAssistant/ (Services/Voice/, App/, Services/Intents/, Services/Observability/); tests under ios/ElderlyAssistantTests/; gate and fixtures under ios/tools/.
- Retained re-run outputs: /tmp/mtc-st-gate.log, /tmp/mtc-st-falsify.log, /tmp/mtc-st-diffnames.txt, /tmp/mtc-st-prod.txt; producer log /tmp/mtc-t142-validate.log.
