# Final sign-off — multi-turn conversation (Phase 1)

**Task:** final-sign-off (T2 human gate) — decision pack
**Feature:** multi-turn-conversation (elderly-ai-assistant) — Phase 1
**Worktree:** /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation — branch feat/multi-turn-conversation
**Date:** 2026-10-11
**Reviewed revision:** production content 134d77e (W7); records HEAD 433ad07
**Diff base:** 0cbe4e6 (master at the branch point)
**Commit range:** 437d4dc..433ad07 — 15 commits (six design-chain, seven waves, two records)
**Scope:** Phase 1 as designed and planned. Phase 2 (v17 authorship, FR-MTC-018) and Phase 3 (FR-MTC-019 rollover) are recorded later-phase scope, not part of this delivery. Device validation is the outstanding completion gate (FR-MTC-020).

**What this document is.** The decision pack for the T2 sign-off: the consolidated result of the feature's full stage chain — requirements, design L1/L2, the L2 review, the security design review, the 19-unit plan, implementation waves W1-W7, the implementation review of record, the security test of record, and this review. It states what is verified, what is not, and what remains the owner's to decide.

**How this pack was produced.** Read-only review from the feature worktree. Every figure below was taken from, or re-verified against, the committed stage records and the retained evidence bundles listed under References; no new test, build, simulator or device run was performed for this pack. The fresh re-runs cited are the security test's own runs of 2026-10-11, with outputs retained.

## Summary

The feature gives the voice assistant a one-deep dialogue frame. When a turn is degenerate or needs one clarification, the assistant speaks a short template probe (curated on-device catalog; no model, no network); the next utterance is captured as the answer (option name, index word, repetition, or free-form correction); a deterministic, model-free merge produces the intended command; and the ordinary pipeline executes it. The frame is in-memory and main-queue-confined, never persisted. Cancel, escape, barge-in and a silent 45 s timeout always return the user to the normal path, and emergency handling always outranks the frame.

What the chain verified (engineering record):

- All 32 requirements trace to an implementation witness and a test/evidence witness, or to an explicitly recorded later-phase scope (Phase 2/3) — table below; full detail with file anchors in specs/review-implementation.md section 3.
- The production delta is exactly the designed set: 14 changed production Swift files (five new dialogue units plus IntentTranscriptPreparation plus nine touched files) plus the catalog JSON resource and the strings catalog — 16 app-source production files, no file outside the set, no debug leftovers.
- Seven wave reviews stand GO at 0.90 with zero blockers (W4 from a base NO_GO with one blocker fixed pre-commit, red to green on a real-seam test); the implementation review stands GO at 0.90 with zero blockers; the security design review and the security test stand SECURITY-GO at 0.90 with zero blockers, all five focus areas PASS with source anchors.
- The release log-safety gate is green and falsification-proven (24 cases over 12 rules; 36 falsification cases; every rule load-bearing); new network egress is zero across the 14 changed production files; human gates are respected (no code path auto-resolves a gate).
- The one full-suite run at W6 (per the unit-gate policy) is baseline-classified: 6638/6620/8/10 at HEAD against a directly measured base of 6403/6357/36/10, strictly redder at base in every paired comparison; the scoped comparison is 4 failures at HEAD against 13 at base.

What is not verified — stated plainly:

- No device run exists. DV-1..DV-5 are BLOCKED and step zero (the Phase 0 PR #156 device smoke) is OUTSTANDING; no observation was recorded — none may be — from a simulator or unit run. The protocol and the empty record are in specs/MTC-device-validation-protocol.md; the owner fills the record on Anzaan. FR-MTC-020 makes this record part of the completion gate.
- The owner's copy review of the 17 dialogue keys is outstanding (owner action OA-5).
- OD-M1..OD-M4 (the designed defaults: two probes; curated catalog; Phase 1 first; music probe only) await the owner's re-confirmation at this gate.
- A ledger of note-level carried items (no blockers) — findings F-1..F-10, wave-review obligations, the FR-MTC-019 ask-lines boundary, the R1 residual log surfaces, and the M-2 scope note — is enumerated under Open items.

Reviewer recommendation: GO at confidence 0.90, conditional on the owner acknowledging the carried items. The authoritative T2 sign-off is the owner's, given through the HIL gate this pack feeds (see Decision). Merging and completing are separable — see Owner decision point 3.

## Release gates verified

**Gate 1 — Release log-safety gate (NFR-MTC-004, NFR-MTC-012).** Re-run fresh on 2026-10-11 from the worktree: exit 0, "24 case(s) over 12 rule(s)"; the fixtures falsification mode: exit 0, "36 case(s) over 12 rule(s)", "every rule is load-bearing". The gate is wired into ios/build.sh ahead of every test scope; feature roots extended 17 to 21; fixtures 38 to 55. Outputs retained at /tmp/mtc-st-gate.log and /tmp/mtc-st-falsify.log; citation: specs/security-test.md, "Independent re-runs", items 2-3.

**Gate 2 — No new network egress (NFR-MTC-003).** Fresh diff scan on 2026-10-11: 0 matches for the network-symbol set (URLSession, URLRequest, http/https URL literals, NWConnection, Network.framework, socket, curl) across the 14 changed production files; independently, the E6 evidence shows 20 spy transports empty across five legs. Retained: /tmp/mtc-st-prod.txt, /tmp/mtc-st-diffnames.txt.

**Gate 3 — Human gates respected (NFR-001; T1/T2).** T1 story approval: owner, 2026-10-10. T2: this pack — the authoritative sign-off is the HIL gate, pending until the owner decides. NFR-001 (only the operator resolves a gate — framework rule): verified — the diff carries no code path that auto-resolves a human gate, and a direct-transition search in the feature's hook region is empty.

**Gate 4 — Test discipline.** Per-unit scoped gates green (W1 270/270; W2 65/65; W3 99/99; W4 204/204 with the pre-fix red retained; W5 157/157; T-139 114/114; T-140 117/117; T-142 structural validation 0 failures). One full suite per the unit-gate policy: W6 at 5860878 — 6638/6620/8/10 against the directly measured base 6403/6357/36/10 (strictly redder at base in every paired comparison; all 8 HEAD failures baseline-classified; the measured base inventory supersedes the older rough estimate). Scoped comparison: HEAD 173/169/4 against base 173/160/13.

**Gate 5 — Security gates.** Security design review: SECURITY-GO (mitigations M-1..M-5 pinned; verifications V-1..V-4 recorded; obligations E1..E8; residuals R1..R5 accepted). Security test of record: SECURITY-GO, 0.90, zero blockers; five focus areas PASS — emergency precedence mid-frame; probe/answer text never reaching logs; cancel, barge-in and the 45 s timeout always recovering; the degraded-brain fallback honoured; the candidate list unable to skip the routing ladder — each with source anchors. Index integrity: structural validator exit 0 (E 8/8, V 4/4, M 5/5, R 5/5; 43/43 tokens; FAILURES 0).

## Change summary

**Shape of the change.** One deep, in-memory dialogue frame on the voice path:

- Frame lifecycle — DialogueManager.swift / DialogueFrame: arm on a degenerate turn or a did-you-mean trigger; note attempts; resolve once through a single idempotent funnel (terminal triple: no half-open window, late notifications are no-ops, double resolves are no-ops). One frame at a time; main-queue confined; nothing persisted.
- Probe kinds — .slotFill (e.g. a bhajan request without a kind) and .candidateChoice (did-you-mean for music near-matches; the hypothesis is only offered alongside real matches, never fabricated; an empty list yields no frame — the honest dead-end is kept).
- Answer capture — four forms: option name, index word, repetition, free-form correction (CaptureForm). The transcript is read raw once for the length bound; every decision is made from the sanitised value.
- Deterministic merge — model-free and pure: slotFill fills the slot; candidateChoice resolves to the arrived command; the design's S6 gates are enforced; execution proceeds through the ordinary pipeline (the interpreter is not consulted; FR-MTC-017 causality pinned by an A/B row).
- Pre-ladder interception — in CommandRouter.swift between the confirmation hook and the deterministic safety net (block :1021-:1129); consumed arms return before the interpreter and before the transcript-cache write. Emergency precedence sits above it: the emergency dispatch runs first and the frame clear (:853) is a post-dispatch side effect, not a dependency (E1 pins dispatch with the clear forced to a no-op).
- Exits — cancel tokens; escape phrases; barge-in (B1..B7, including a negation counterexample that must not barge) falls through to the new command exactly once; a silent 45 s timeout drops the frame with no spoken line, and the next utterance is processed fresh (drop-and-re-arm; expiry is half-open; the window value is injected at construction — one source, no literal held in the manager).
- Probe budget — two probes maximum, then defaults; the implemented comparison attempts <= maxProbes yields exactly two probes and is an accepted erratum against the design snippet's stricter form — it must not be reverted. The budget and the 45 s window are injected/configurable values with single sources, not scattered constants.
- Curated catalog — DialogueOptionCatalog.json (v1; on-device resource; includes the bhajan group); template probes are composed from catalog keys only; 17 dialogue keys in the strings catalog, both languages (the catalog grew by exactly those keys).
- Log safety — LogSanitiser.swift extends its closed vocabulary from 78 to 84 keys (intake, probe_kind, attempt, option_count, capture_form, merge_source; reason reused); out-of-vocabulary values are redacted and unlisted keys are dropped fail-closed.
- Tests — 14 new suites plus 7 edited test files, including the dialogue frame, answer path, candidate builder, catalog, transcript preparation, trap matrix, hostile corpus, and the acceptance sweep; accepted red histories retained in the wave records.

**Execution.** 19 planned units (T-125..T-143) ran in seven implementation waves, W1..W7; every wave closed with a paired implementation review (all GO 0.90, zero blockers; W4 from a base NO_GO with its blocker fixed pre-commit). Commit chain, 7-char refs: requirements 437d4dc (T1 owner-approved); design L1 59b66d9; design L2 ab43526; L2 review GO 1ed8c21; security design review SECURITY-GO 60850db; plan of 19 tasks b71ca2a; waves 76b28b9 (W1), 3b44c0c (W2), cf416ac (W3), cc065b0 (W4), ac89744 (W5), 5860878 (W6), 134d77e (W7); records a55e22c (implementation review) and 433ad07 (security test).

**Diff census at the content revision.** 168 changed files, +26,876/-3,888: 16 app-source production files (the 14 Swift files above plus the catalog JSON and the strings catalog); 21 test-tree files (14 new suites, 7 edited); 99 spec files; 10 run-state files (the framework's per-feature worktree convention); 1 docs file; 21 other iOS files (the regenerated project file, the project.yml resource entry, the release log-safety script and its added fixture trees).

**Two documented baseline test repairs (both bounded, both explained in-file).** The Spotify catalog pin 1341 to 1361, with the arithmetic and provenance in its comment (red at base, green at HEAD); the second allow-list pin widened by exactly the six dialogue keys (a feature-caused regression caught by the full sweep, fixed in-unit; the cross-check still computes the declared union, so it is not a rubber stamp).

**User-visible behaviour (what the user hears when the feature runs and when it fails).** A short clarifying probe is spoken in the user's language when the assistant needs one clarification; the user answers by name or index word; the merged request executes and plays through the ordinary path; a timeout is silent and the next utterance is treated fresh; cancel, escape and barge-in all fall back to normal behaviour; emergency handling always wins; nothing is persisted between sessions. Every failure path recovers through the one idempotent resolve funnel (the trap matrix pins cancel, escape, barge-in, timeout, expiry, Talk-mid-window, watchdog and session exit).

## Requirements traceability

Summarized from specs/review-implementation.md section 3 (32 requirements: FR-MTC-001..020, NFR-MTC-001..012). PHASE marks recorded later-phase scope.

| Req | Topic | Witness summary |
|---|---|---|
| FR-MTC-001 | Frame lifecycle | arm / noteAttempt / resolve in DialogueManager.swift; one-deep frame value; frame tests 17/17; trap matrix 8/8 (every outcome clears; no half-open window) |
| FR-MTC-002 | Degenerate detection | keyword-rule provenance + isDegenerate; probe fired from the degenerate intake; provenance tests 23/23; trigger tests 13/13; acceptance S1 |
| FR-MTC-003 | Slot-fill probe | slotFill frame factory; composer branch; catalog group resolution; composition rows; router probe/default rows; acceptance S1 |
| FR-MTC-004 | Candidate choice (did-you-mean) | builder near-matches with hypothesis-last-only-alongside; builder tests 29/29; empty list yields no frame (honest dead-end kept) |
| FR-MTC-005 | Capture forms | classify vectors (index word / option name / repetition / free text) + CaptureForm payload; answer-path tests 36/36; hostile corpus E2 |
| FR-MTC-006 | Merge and execution | merge (S6 gates) + executeDialogueAnswer dispatching the arrived command; merge and wiring rows; acceptance S1 (canonical query executed, interpreter 0) |
| FR-MTC-007 | Budget then defaults | maxProbes comparison; default execution; exhausted close; router budget row (attempts=2 then re-probe); corpus injection row; M-5 exhaustion row |
| FR-MTC-008 | Escape | escape-phrase table leading to escaped + catalog acknowledgement; answer-path escape vector; router and trap rows |
| FR-MTC-009 | Interception placement | the block between the confirmation hook and the safety net; router placement row (content anchors); cache A/B causality row |
| FR-MTC-010 | Cancel | cancel tokens leading to cancelled + acknowledgement; answer-path cancel vectors; router and trap rows |
| FR-MTC-011 | Emergency precedence | emergency path above the frame; post-dispatch clear; E1 pair (dispatch with clear forced to a no-op; clears ordering) |
| FR-MTC-012 | Barge-in | isBargeIn B1..B7; barge-in falls through once; B rows incl. the negation counterexample; router and trap rows |
| FR-MTC-013 | Timeout drop and re-arm | timer arms only from the awaited state; silent callback; state-machine tests 24/24; trap timeout row (production callback + 1 s clock leg); half-open boundary |
| FR-MTC-014 | Awaited-answer state | state enum and edges; opener; state-machine tests 24/24; wiring scenarios 4/5; UI mappings are inert placeholders (F-4) |
| FR-MTC-015 | Curated catalog | loader + JSON resource + project entry; catalog tests 10/10 incl. the ships-in-bundle row |
| FR-MTC-016 | Template probes | composer, catalog keys only; composer rows; localization coverage 10/10 (verbatim both languages) |
| FR-MTC-017 | Cache bypass | consumed arms return before the interpreter and the cache write; cache-bypass suite 4/4 (seeded-entry A/B); router causality row |
| FR-MTC-018 | PHASE — Phase 2 (v17) | designed, not shipped in Phase 1; feature vocabulary absent from all three prompt files; digests byte-identical; recorded; owner decision OD-M3 |
| FR-MTC-019 | PHASE — Phase 3 rollover | Phase-1 guard shipped (reminder/calendar/medication turns open no frame; S2 A/B equality); the literal missing-slot ask-lines are untested everywhere — recorded boundary (F-5); owner decision OD-M4 |
| FR-MTC-020 | Device-validation completion gate | protocol + record with named dependencies; DV-1..DV-5 BLOCKED; step zero OUTSTANDING (protocol section 7.3) — open by design until the owner device run |
| NFR-MTC-001 | Turn envelope | the frame turn is model-free; the 22/45/60 s timers unchanged; timeout-injection tests (24/24); device latency rides DV-1 |
| NFR-MTC-002 | Prompt budget | Phase 1 adds zero prompt delta; S3: 2,506 under the 3,000 budget; both prompt digests re-derived |
| NFR-MTC-003 | No new egress | new files import Foundation only; no new call sites; E6 (20 spy transports) + the fresh 0-symbol diff scan |
| NFR-MTC-004 | Log safety | closed vocabularies; six new keys; fail-closed value bounding; four gate roots; E4/E5: gate exit 0 (24 cases / 12 rules); 8-leg runtime capture; sanitiser suite 34/34 |
| NFR-MTC-005 | Degraded brain | deterministic classify/merge before any model call; E7 determinism half; interpreter-0 rows; DV-4 device leg |
| NFR-MTC-006 | Localization | 17 dialogue keys ne/en; per-locale composition; localization coverage 10/10 (verbatim both languages); composer locale rows |
| NFR-MTC-007 | Sustained stability | one bounded frame; no new long-lived buffers; trap suite rows; device leg rides DV-5 |
| NFR-MTC-008 | Answer-path security | raw-once bound; decisions from the sanitised value; production seam non-nil; hostile corpus E2/E8; transcript-preparation tests 8/8; M-3 pin |
| NFR-MTC-009 | Voice-only accessibility | all probes spoken; candidates pickable by index word; no visual dependency; composer, builder and answer-path rows; UI inert (F-4) |
| NFR-MTC-010 | Trap resistance | terminal triple holds in every trap row; trap matrix 8/8 (no half-open window; late notifications no-op; double resolve no-op) |
| NFR-MTC-011 | Prompt-prefix stability | no prompt change in Phase 1 (frame clause deferred); S3 digests and absence pins; Phase 2 pins untouched (2,506 baseline) |
| NFR-MTC-012 | Compliance and release gates | release log gate covers the four new files; prompt mirror; no release-capable debug prints in new code; T-138 gate + fixtures (roots 17 to 21, fixtures 38 to 55) |

Phase note: FR-MTC-018 (Phase 2) and FR-MTC-019 (Phase 3) are later-phase requirements by design — Phase 1 ships the guards and records the boundaries; FR-MTC-020 is the completion gate, open until the device run (see Device validation status). Row-level file:line anchors are in specs/review-implementation.md section 3.

## Security posture

- **Security design review (60850db): SECURITY-GO.** Mitigations M-1..M-5 pinned (pipeline guard; all four arming sites; the production sanitiser seam; the six keys with reason untouched; candidate-index bounds end to end); verifications V-1..V-4 recorded; obligations E1..E8; accepted residuals R1..R5.
- **Security test of record (433ad07): SECURITY-GO, confidence 0.90, zero blockers.** Five focus areas PASS with source anchors: F1 emergency precedence mid-frame (the check runs on the raw transcript before every content handler and does not depend on the frame clear); F2 probe/answer text never reaches logs (six new closed keys; out-of-vocabulary redacted; unlisted keys dropped fail-closed); F3 cancel, barge-in and the 45 s timeout always recover through one idempotent resolve funnel; F4 the degraded path is model-free and pure; F5 the candidate list is bounded, total, and cannot skip the routing ladder or any existing confirmation tier.
- **Evidence index** (specs/MTC-security-evidence-index.md), sha256 d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617; structural validator exit 0 (E 8/8, V 4/4, M 5/5, R 5/5; 43/43 tokens; FAILURES 0). The digest was re-checked by the security test — the file of record is the file reviewed.
- **Honest bounds carried.** Residuals R1..R5 (legacy debug prints on non-release surfaces; static-gate blind spots; unconstrained values for allow-listed string keys; transcript policy unchanged; guard ordering shipped) and coverage boundaries 1..7 (including the sink-line-scoped marker scan, the FR-MTC-019 ask-lines boundary, the measured-base inventory, and the open device validation). No boundary conceals a failure; none makes a verdict-weight claim false or unproven.

## Device validation status

- **State at this sign-off: no device run has occurred.** No session block exists; every DV item is BLOCKED with its named dependency, and step zero — the Phase 0 PR #156 device smoke (PR #156 merged 437631e; one real conversation turn with the explicit 4B pick active: no jetsam kill, then a fresh JetsamEvent pull) — is OUTSTANDING. Nothing in the record is a device observation; no row was filled from a simulator or unit-test run. Owner actions OA-1..OA-5 are open.
- **The five items, all BLOCKED** on step zero plus the owner's device and the Release build (protocol section 7.3): DV-1 probe, answer, correct playback (the bhajan example); DV-2 the 45 s timeout drops the frame silently and re-arms; DV-3 barge-in mid-probe (call placement); DV-4 a mid-dialogue degraded-brain turn carried by the deterministic merge (the degraded state must be observed in force — never passed on a healthy-brain run); DV-5 a sustained scripted session (at least 10 consecutive dialogue turns including probe-answer pairs and one degraded-brain turn; Release configuration) with a post-session JetsamEvent pull compared against the step-zero pull.
- **Completion-gate relationship (FR-MTC-020; protocol section 8).** Only PASS closes an item; FAIL and BLOCKED both hold the gate; a failed step zero stops the session without partial results; a failed item is fixed, re-run on the fixed build, and recorded. The workflow's own final-gate statement: "DV-* device validation on Anzaan is part of the completion gate."
- **Merging and completing are separable.** Merging the branch puts the code on master; the DV record completes the feature. The completion claim stays blocked until the record shows PASS on all five items — the reviewer's recommendation (Owner decision point 3) is to approve the merge with the DV record remaining the outstanding completion gate.

## Open items

Numbered ledger of carried items. None of these blocks the engineering or security verdicts; each is owner-facing, a recorded boundary, a next-touch fixup, or bookkeeping.

1. **Device validation — the outstanding completion gate.** DV-1..DV-5 BLOCKED; step zero OUTSTANDING; OA-1..OA-5 open; the owner fills the record on Anzaan at run time. This is the only item that keeps the feature from being called complete. Details above.
2. **OD-M1..OD-M4 re-confirmation at this gate.** The designed defaults are implemented and tested: a two-probe budget; a curated on-device catalog; Phase 1 first; the music probe only. The owner confirms or changes.
3. **Owner copy review of the 17 dialogue keys (OA-5).** The readings are draft-quality by design; no agent changes owner-facing copy. Owner-facing.
4. **FR-MTC-019 ask-lines boundary.** The literal missing-slot ask-lines of the Phase-1 rollover guard are tested nowhere; the reminder/calendar handlers are source-untouched and Phase 1 scopes them as no-change. Recorded (W6 F-3; index boundary 3). Carried, not blocking.
5. **Minor findings F-1..F-10 (all note-level; none blocks).** F-1/F-2 comment citation fixups at the next touch of CommandRouter.swift; F-3 queued spec-wording fixups; F-4 the awaited-answer UI mappings are compile-forced, inert placeholders (device validation DV-1/DV-2 is where they become observable); F-5 is item 4; F-6 is item 3; F-7 is item 9; F-8 the opener's frame supersede also covers the pending-app-launch and voice-ack confirmation paths, behaviourally untested (A/B candidate at the next touch); F-9 optional scan-anchor extension; F-10 scanner-class awareness carried to record files.
6. **Wave-review carried obligations (all note-level; dispositions recorded in the wave reviews and specs/implement-notes.md).** W1/W2 spec-wording fixups; W3's erratum-comment citation; optional scan anchors (W3 F-5 / W4 F-5); the CommandRouter.swift :912-913 comment wording (net behaviour pinned and doubly guarded — a next-touch fixup); W5/W6 awareness items. None affects behaviour.
7. **Residual log surfaces (R1).** The marker scan covers bus-format sink lines only; the did-you-mean spoken output and a legacy debug print sit outside it (a spoken surface and a non-release surface, stated honestly; security-test Gaps item 3).
8. **M-2 medication-challenge scope note.** The medication-challenge supersede path is behaviourally untested; only the four arming sites are source-pinned (T-136 F-4); no auto-resolution exists (security-test Gaps item 4).
9. **Inherited-filename collision at integration.** 10 tracked spec files at the base share names with this branch's records: implement-review-w1 through w7 plus review-implementation.md, security-test.md and final-sign-off.md. The base copies hold other features' sign-off records (including a security-test record for profile-interview and a review record for the voice-OOM quickfix). The integration step must resolve the numbering deliberately rather than letting the merge pick silently (finding F-7; Owner decision point 4). The base's implement-review-w8.md belongs to the Spotify feature and is untouched by this branch.
10. **Process and bookkeeping note (fully disclosed; no verdict affected).** One stray evidence record pair (run "default") appears in the append-only tasks.jsonl from a mis-targeted completion call during the review-implementation step; the default run's state file was restored to its committed content, and the multi-turn records are correct; also, the review-implementation reviewer performed its own completion call instead of returning content to the session — the returned content was verified correct against the committed file. Separately, the measured base inventory supersedes the older failure-count estimate; no older figure should be re-read as current.

## Rollback plan

- **Revert route.** Revert the merge commit on master, or drop the branch before merge. The change is one feature branch; reverting it is a single revert with no data migration and no follow-up cleanup.
- **No persisted state.** The frame is in-memory and dies with the process; nothing in the feature writes to disk (no user data, no provider state, no network state, no training artifacts). Rollback has no residual state to unwind.
- **Additive resources.** The catalog JSON resource and the 17 strings-catalog keys are additions; reverting removes them with the branch. The only pre-existing-file edits outside the feature are the two documented baseline test repairs (test-only, bounded).
- **Log-safety additions.** The six new LogSanitiser.swift keys are additive and fail-closed (unlisted keys drop, out-of-vocabulary values redact). Reverting narrows the allow-list back; no log consumer depends on the new keys.
- **Device validation unaffected.** DV runs can be performed on a build of the branch or of post-merge master; the record's build identity (protocol section 2) names whichever build was used, so rollback ordering does not invalidate the protocol.

## Compliance checklist

| Check | Result |
|---|---|
| Release log-safety gate wired into ios/build.sh ahead of every test scope | PASS — in-build gates green in every wave and both full runs (specs/review-implementation.md section 5) |
| No new network egress (NFR-MTC-003) | PASS — 0 network symbols across the 14 changed production files (fresh scan; E6) |
| Log safety, fail-closed (NFR-MTC-004) | PASS — gate exit 0 (24 cases / 12 rules); falsification exit 0 (36 cases); 8-leg runtime capture |
| New spoken copy localized ne/en (NFR-MTC-006) | PASS — all 17 dialogue keys present verbatim in both languages (localization coverage 10/10) |
| Human gates respected (NFR-001; T1/T2) | PASS — no code path auto-resolves a gate; T1 approved 2026-10-10; T2 pending, this pack |
| Unit-gate policy honoured (focused per unit; one full suite at the end) | PASS — one full suite at W6, baseline-classified; every unit gate green |
| No secrets in the delta | PASS — scans clean across the reviewed files; no credential material added |
| Phase discipline (Phase 1 scope; Phases 2/3 recorded) | PASS — later-phase requirements recorded, guards shipped, no Phase 2/3 code |

## Owner decision points

1. **T2 sign-off** — decide the authoritative human gate on the implementation and verification bundle as written here (the chain's GO/SECURITY-GO verdicts and the carried ledger). The reviewer's recommendation: GO.
2. **Re-confirm OD-M1..OD-M4** (the designed defaults: two probes; curated catalog; Phase 1 first; music probe only) — or record changes; any change becomes a scoped follow-up, not rework of what is verified here.
3. **Device-validation disposition** — (a) approve the merge now with the DV record remaining the outstanding completion gate (recommended), or (b) hold the merge until the DV run completes. Why (a): the engineering chain is complete and green on every rung; DV is gated only on the owner's device time (step zero first); the merge ships nothing to users — it is not a release — and is a clean revert; holding would only increase integration drift against an active master, while protocol section 8 keeps the completion claim blocked until the DV record shows PASS on all items. This separation is the design's own: merging puts the code on master; the DV record completes the feature.
4. **Integration handling at run end** — open a PR against master (the standing integration rule) and resolve the inherited-filename collisions deliberately (item 9): decide the numbering of this feature's review records against the base copies that hold other features' records.

## References

- **Stage records:** specs/review-implementation.md; specs/security-test.md; specs/implement-notes.md; specs/MTC-security-evidence-index.md; specs/MTC-device-validation-protocol.md; specs/plan-tasks/plan.md; specs/define-requirements/ (20 FR + 12 NFR); the wave reviews specs/implement-review-w1.md through implement-review-w7.md; specs/multi-turn-conversation/constitution.md.
- **Evidence bundles and logs:** /tmp/mtc-w5-evidence/ (incl. w5-gate.xcresult); /tmp/mtc-w6-evidence/ (full-run bundles and base summaries); /tmp/mtc-t142-validate.log; /tmp/mtc-st-gate.log; /tmp/mtc-st-falsify.log; /tmp/mtc-st-prod.txt; /tmp/mtc-st-diffnames.txt.
- **Artifacts:** DialogueOptionCatalog.json; Localizable.xcstrings; ios/tools/check-release-log-safety.sh and its fixture scripts; ios/build.sh.

## Decision

decision: GO
confidence: 0.90
blockers: 0

All criteria met. The multi-turn conversation Phase 1 is fully implemented per the approved design chain, and every rung of the chain stands at GO or SECURITY-GO with zero blockers, reconciled against the committed bytes: the seven wave reviews, the implementation review, the security design review and the security test of record. The 32 requirements trace to witnesses or to explicitly recorded later-phase scope; the production delta is exactly the designed set; the release log-safety gate and its falsification discipline are green; new network egress is zero; and no new test failures are attributable to the feature (the measured base is strictly redder in every paired comparison).

This GO is the reviewer's recommendation to the owner. **The authoritative T2 senior-human sign-off is the HIL gate, which remains PENDING until the owner decides**; the recommendation is conditional on the owner acknowledging the carried items (Open items 1-10). Nothing in this pack is a device observation: the device-validation record (FR-MTC-020) remains the outstanding completion gate, and merging and completing are separable (Owner decision point 3).
