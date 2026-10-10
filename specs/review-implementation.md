# Review — implementation, multi-turn conversation (stage-level, whole feature)

Artifact under review: branch `feat/multi-turn-conversation`, worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation` — 13 commits over base `0cbe4e6` (six design-chain commits 437d4dc..b71ca2a plus seven wave commits 76b28b9..134d77e; HEAD = 134d77e = W7), 168 changed files (+26,876/−3,888) — together with `specs/implement-notes.md`, `specs/implement-review-w1..w7.md`, `specs/MTC-security-evidence-index.md` and `specs/MTC-device-validation-protocol.md`, for task `review-implementation`.
Read with: `constitution.md` (Standards), the feature constitution, `specs/define-requirements/index.md` (20 FR-MTC + 12 NFR-MTC), `specs/design-l1.md`, `specs/design-l2.md`, `specs/review-l2.md`, `specs/security-design-review.md`, `specs/plan-tasks/plan.md`, and the seven wave reviews.
Method: read-only verification re-derived from the worktree. Every new production file and every production hunk in the feature delta read against the design chain; all seven wave reviews read and consolidated; the reviewed sha256 chains recomputed (T-141 notes f3edd2a2…, security index d03d8dc4…, T-142 notes 753b77bb… — all match the corrected committed values); the wave-gate counts re-verified from the retained evidence (W5 157/157; W4 run 2 204/204; the W4 pre-fix red 16/17 of 17 and the post-restore 17/17; the W6 run 1 / run 2 full gates 6638 executed / 6620 passed / 8 failed / 10 skipped; the measured base full gate 6403/6357/36/10; base scoped 173/160/13 against HEAD scoped 173/169/4 — all from the retained summary files); the commit and file inventory, the baseline test repairs, the key inventory and the run-state delta re-derived. No build or test was re-run (the wave gates and the W6 full sweep are the evidence of record); nothing under review was modified; the single uncommitted `specs/implement-notes.md` line (the W7 hash fill) was left untouched.

## Summary

**GO at confidence 0.90 with 0 blockers.** All 32 requirements (FR-MTC-001…020, NFR-MTC-001…012) trace to an implementation witness plus a test or evidence witness, or to an explicitly recorded gap; every design-conformance pin behind the review checklist verified at file:line — pre-ladder answer interception between the confirmation hook and the safety net with emergency precedence above it, the one-deep main-queue-confined frame, the awaited slot answer riding the same single-source 45 s window, the deterministic model-free merge, the curated on-device catalog, template-only probes in both languages, the max-two-probe budget with defaults. All seven wave gates stand GO at 0.90 with zero blockers; every applied in-place correction was verified against committed bytes, and every carried item is still open and listed here. Evidence is internally consistent: the reviewed sha chains match the committed artifacts; every re-checked gate count matches its retained bundle; all 8 HEAD full-suite failures are baseline-classified against a directly measured base that is strictly redder in every paired comparison. Scope is clean: the production delta is exactly the 16 designed files, no debug leftovers or stray files, the two test baseline repairs are documented and bounded, and resources are consistent. The security posture is summarized below by pointer (E1..E8 into the T-142 index; M-1..M-5 pinned; V-1..V-4 recorded; R1..R5 and the seven coverage boundaries accepted); this review does **not** issue the security-test verdict — that is the next task, consuming the same index. Ten findings remain, all note-level and none blocking. Open items for final sign-off: the DV device run (DV-1..DV-5 BLOCKED, step zero OUTSTANDING), OD-M1..OD-M4, the owner copy review, and the PR-time reconciliation of inherited review filenames.

### 1. Scope and method — re-derived, sampled, not verified

- **Re-derived directly.** The full production delta (all new files read in full; all router/coordinator/state-machine/keyword/sanitiser hunks read); the interception placement and emergency ordering by content anchors; the 45 s window chain (config default, accessor, manager construction, timer, callback); the traceability mapping of all 32 requirements against `specs/design-l2.md` §Traceability and the suites; the sha256 chains and the gate counts against the retained bundles and summary files; the commit inventory (13 commits) and the file-category census (16 app-source production files, 21 test-tree files, 99 spec files, 10 run-state files, 1 docs file, 21 other iOS files — the regenerated project file, the project.yml entry, the release log-safety script and its added fixture trees); the two baseline-test repairs (read in full); the 17 dialogue keys in the strings catalog (both languages); the run-state file contents (no transcript, marker, or fixture content).
- **Sampled.** The per-unit notes files (T-125..T-143) were not each re-read end to end; their wave reviews (which already adjudicated them with recorded shas) were the basis, with the referenced sections and the decisive numbers spot-checked. W7's structural re-validation of the T-142 index was accepted on the basis of the W7 re-check (its checker was reconstructed, not retained byte-for-byte — carried as W7 adjudication K).
- **Not verified (and why).** No build or test re-run — read-only mandate; the wave gates and the W6 full sweep are the evidence of record. Device validation not executed — owner device; step zero outstanding by design. Full-suite flake membership is run-to-run variable by nature; the classification rests on suite-level stability plus the measured base, exactly as recorded. Per-commit file lists for W1..W5 were not re-derived (their wave reviews did that); the W6/W7 deltas were re-derived here.

### 2. Design conformance — the load-bearing pins (file:line at HEAD)

- **Interception ordering.** The dialogue-frame banner sits at `CommandRouter.swift:1021`; the frame gate `if let frame = coordinator?.activeDialogueFrame` at :1039; every consumed arm returns before the interpreter and before the transcript-cache write (FR-MTC-017 causality, pinned by a causal A/B row); the deterministic safety net begins directly below at :1130, and the confirmation hook region sits above — the designed seam, between them, verified by content anchor rather than line numbers. Emergency precedence: the frame clear `coordinator?.clearDialogueFrame(reason: .emergency)` at :853 runs after the emergency dispatch and before its return (ADR-MTC-02 side-effect-only; the E1 pair pins dispatch independence with the clear forced to a no-op, and the post-dispatch ordering).
- **The awaited slot answer and the 45 s window.** State case at `VoiceSessionStateMachine.swift:16`; the single 45 s source at :120; the accessor at :268 returns `TimeInterval(config.confirmationTimeoutSeconds)`; the timer at :302 arms only from the awaited state and is silent; the callback field at :134 fires at :320 and is installed by the coordinator at `AppCoordinator.swift:3081` into a resolve with the timedOut outcome (silent — never the confirmation-timeout recorder). The manager is constructed at :2552 with the window value and `DialogueManager.swift` init (:225-229) holds no literal (C-1 shape: value injected at construction). Expiry is half-open (`now >= deadline`), dropped on read — the next utterance is a fresh command (FR-MTC-013's drop-and-re-arm).
- **Probe budget and defaults.** `DialogueConfig` at `DialogueManager.swift:374-381` (2 / 3 / 4); the budget comparison at `CommandRouter.swift:1119` — `attempts <= DialogueConfig.maxProbes` with the erratum comment at :1112-1118 (adjudication B); exhaustion executes the default or speaks the honest exhausted line.
- **Deterministic merge.** `DialogueAnswerPath.merge` at :342 with both S6 gates (slotFill and candidateChoice) and the closed `emptyMerge` error; classification order per L2-D1 with barge-in ahead of cancel/amendment; `isBargeIn` at :245 (B1..B7; the live medication vocabulary passed at the interception site, W2 F-1 discharged with a causal A/B); the arrived command merged via its own 14-field memberwise copy and dispatched through the normal music path (interpreter count asserted 0 on every answer row).
- **Curated catalog.** `DialogueOptionCatalog.swift` (loader, fail-closed all-or-nothing, version 1) with `DialogueOptionCatalog.json` (one group, file-order options) registered in `ios/project.yml`; whole-value/whole-token matching with the grapheme-cluster discipline pinned; a resource-ships row proves the bundle path.
- **Template probes.** `DialogueProbeComposer` (`DialogueManager.swift:298-370`): retry prefix plus exactly one space, ", " joins, candidate label from the query or the first match key; every string is a catalog key — the model is never consulted (byte-composed in tests; both languages pinned by the coverage suite).
- **Degraded brain.** The frame turn returns before the interpreter (0-interpreter assertions across E2/E8); classify and merge are pure and model-free (structural absence scan); a brain abstain cannot change the deterministic outcome (E7 half; the device leg rides DV-4).
- **M-1/M-2.** The pipeline-state guard names both windows (`AppCoordinator.swift:4816` region; guard at :4831); the four confirmation arming sites (:7317, :7490, :7550, :8638) pend through the opener; the opener supersedes a live frame first (:7094 region), covering the two additional direct-transition paths recorded at :7083 and :10426 (W4 F-4, finding F-8); the session-exit observer at :3100 resolves through :11116.

### 3. Requirements traceability (FR-MTC-001…020, NFR-MTC-001…012)

Witness = implementation; evidence = the test/evidence record (counts are from the wave gates and the W6 sweep).

| Requirement | Implementation witness | Test / evidence witness |
|---|---|---|
| FR-MTC-001 frame lifecycle | `DialogueManager.swift` arm/noteAttempt/resolve (251/271/285); one-deep frame value | DialogueFrameTests 17/17; trap matrix 8/8 (every outcome clears; no half-open window) |
| FR-MTC-002 degenerate detection | keyword-rule provenance + `isDegenerate`; probe fired from the degenerate intake | Provenance tests 23/23; trigger tests 13/13; acceptance S1 |
| FR-MTC-003 slot-fill probe | frame factory slotFill; composer slotFill branch; catalog group resolution | DialogueFrameTests composition rows; router probe/default rows; acceptance S1 |
| FR-MTC-004 candidateChoice | builder (near-matches, hypothesis-last-only-alongside); the did-you-mean speak helper | Builder tests 29/29; trigger tests (empty list ⇒ no frame, honest dead-end kept) |
| FR-MTC-005 capture forms | classify vectors (index word / option name / repetition / free text) + CaptureForm payload | AnswerPath tests 36/36 (one row per vector); E2 corpus |
| FR-MTC-006 merge and execution | `merge` (S6 gates) + executeDialogueAnswer dispatching the arrived command's merge | AnswerPath merge rows; coordinator wiring rows; acceptance S1 (canonical query executed, interpreter 0) |
| FR-MTC-007 budget then defaults | maxProbes comparison :1119; default execution; exhausted close | Router budget row (attempts=2 then re-probe); corpus injection re-probe; M-5 exhaustion row |
| FR-MTC-008 escape | escape-phrase table → escaped + catalog ack | AnswerPath escape vector; router escape row; trap escape row |
| FR-MTC-009 interception | the block at :1021-:1129 between hook and safety net | Router placement row (content anchors); cache A/B causality row |
| FR-MTC-010 cancel | cancel tokens → cancelled + ack; amendment reads | AnswerPath cancel vectors; router cancel row; trap cancel row |
| FR-MTC-011 emergency precedence | emergency path above; clear :853 post-dispatch | E1 pair (dispatch with clear forced no-op; clears == [.emergency], ordering) |
| FR-MTC-012 barge-in | `isBargeIn` B1..B7; barge-in falls through once | AnswerPath B rows (incl. the negation counterexample, B7 negative); router barge-in row; trap row |
| FR-MTC-013 timeout silent drop and re-arm | timer :302 + silent callback → timedOut; expiry drop on read | State-machine tests 24/24; trap timeout row (production callback + 1 s clock leg) and expiry row; half-open boundary |
| FR-MTC-014 awaited-answer state | enum/edges/opener (:16/:237); UI mappings | State-machine tests 24/24; wiring scenarios 4/5; UI mappings are inert placeholders (finding F-4) |
| FR-MTC-015 curated catalog | loader + JSON resource + project.yml entry | Catalog tests 10/10 incl. the ships-in-bundle row; acceptance S1 anchor |
| FR-MTC-016 template probes | composer (catalog keys only) | Composer rows; L10n coverage 10/10 (verbatim both languages); builder byte-exact renders |
| FR-MTC-017 cache bypass | consumed arms return before interpreter and cache write | Cache-bypass suite 4/4 (seeded-entry A/B); router causality row |
| FR-MTC-018 Phase 2 (v17) | designed, not shipped — Phase 1 scope | S3: feature vocabulary absent from all three prompt files; digests base-byte-identical; OD-M3 owner |
| FR-MTC-019 Phase 3 rollover | Phase-1 guard shipped: reminder/calendar/medication turns open no frame | S2 A/B equality; literal missing-slot ask lines untested — recorded boundary (finding F-5); OD-M4 owner |
| FR-MTC-020 DV completion gate | protocol + record with named dependencies | DV-1..DV-5 BLOCKED; step zero OUTSTANDING (protocol §7.3) — open by design until the owner device run |
| NFR-MTC-001 turn envelope | the frame turn is model-free; the 22/45/60 s timers unchanged | Timeout-injection tests (state machine 24/24); device latency measured via DV-1 |
| NFR-MTC-002 prompt budget | Phase 1 adds zero prompt delta | S3: weather vocabulary 2,506 ≤ 3,000; both prompt digests re-derived |
| NFR-MTC-003 no new egress | new files import Foundation only; no new call sites | E6: source audit + 20 spy transports empty across five legs |
| NFR-MTC-004 log safety | closed vocabularies; six new keys; fail-closed value bounding; four gate roots | E4/E5: gate rc=0 (24 cases / 12 rules); in-build gates; 8-leg runtime capture; sanitiser suite 34/34 |
| NFR-MTC-005 degraded brain | deterministic classify/merge before any model call | E7 determinism half (pure merge + structural absence); interpreter-0 rows; DV-4 device leg |
| NFR-MTC-006 localisation | 17 dialogue keys ne/en; per-locale composition | L10n coverage 10/10 (verbatim both languages); composer locale rows |
| NFR-MTC-007 sustained stability | one bounded frame; no new long-lived buffers | Trap suite (watchdog/pipeline/Talk rows); device leg rides DV-5 (PR #156 protocol) |
| NFR-MTC-008 answer-path security | classify reads raw once for the bound; decisions from the sanitised value; production seam non-nil | Hostile corpus E2/E8; transcript-preparation tests 8/8; M-3 pin |
| NFR-MTC-009 voice-only accessibility | all probes spoken; candidates index-word pickable; no visual dependency | Composer rows; builder index rows; answer-path index rows; UI inert (finding F-4) |
| NFR-MTC-010 trap resistance | terminal triple holds in every trap row | Trap matrix 8/8 (no half-open window; late hourglass no-op; double-resolve no-op) |
| NFR-MTC-011 KV-prefix stability | no prompt change in Phase 1 (frame clause deferred) | S3 digests and absence pins; Phase 2 pins untouched (2,506 baseline) |
| NFR-MTC-012 compliance and release gates | release log gate covers the four new files; prompt mirror; no Release-capable debug prints in new code | T-138 gate + fixtures (roots 17→21, fixtures 38→55); in-build gates green in every wave and both full runs |

Recorded gaps (explicit, not buried): FR-MTC-018 and FR-MTC-019 are later-phase requirements by design (owner decisions OD-M3/OD-M4 pending; Phase-1 guards shipped and tested); FR-MTC-019's literal missing-slot ask lines are untested anywhere (W6 F-3, boundary 3 of the T-142 index); FR-MTC-020 is open until the DV device run (below); NFR-MTC-001/005/007's device-measured halves ride the DV items.

### 4. Wave-review consolidation (W1..W7)

All seven wave reviews returned **GO at confidence 0.90 with 0 blockers** (W4 came from a base **NO_GO — 1 blocker** closed by the prescribed fix with red→green bundles; the others were GO on first pass). Findings counts: W1 seven (all note-level), W2 seven (one major cross-wave obligation + one minor latent + five notes), W3 six (notes), W4 six at the base pass including the blocker, plus F-7 at re-review (closed/recorded), W5 three (one minor + two notes), W6 six (three minor record corrections + three notes), W7 three (two minor + one note). Nothing was silently dropped — every finding has a disposition in its wave review, in `specs/implement-notes.md` (wave log, dispositions and gate bullets), or in the T-142 index.

- **Applied in-place corrections verified against committed bytes.** W2 F-2 (the medication doc now names B6's keyword stage, at `DialogueAnswerPath.swift:174/:243`) and W2 F-3 (the candidateChoice S6 gate is present in `merge`, with the review tag in the comment) — both confirmed in the committed file. W3 F-1 — `specs/T-133-notes.md:166` now carries the corrected statement that the four new gate roots are the dialogue helper files. W4 F-3/F-4/F-5 — `specs/T-136-notes.md` carries the "Post-review annotations" section at :118-122 and the annotated gate-2 tally at :101. W6 F-1/F-2/F-6 — the committed T-141 notes digest f3edd2a2 matches the corrected artifact (the base-scoped family count, the run-1 framing, the dictionary-path family softening all present at :108/:65/:104). W7 F-1/F-2/F-3 — the committed index digest d03d8dc4 and notes digest 753b77bb match the corrected artifacts.
- **W1 F-1 (non-redeclaration of the hoisted merge types) — discharged at W2**, which verified single declaration sites and consumption without redeclaration; re-confirmed here (the three types are declared once, in `DialogueManager.swift:160-186`).
- **W1 F-4 (pre-existing Spotify pin) — discharged at W6/T-141**: the bounded 1341→1361 edit is in the committed test file with the arithmetic and provenance in its comment (adjudication B of W6; re-read here).
- **W1 F-7 (intake vocabulary forward-reference) — discharged at W3**: the degenerate-intake type landed with the interception and the vocabulary mirrors it; the sanitiser suite pins the same six keys independently.
- **W2 F-1 (live medication vocabulary at the interception) — discharged at W3** at :981-983 region with a causal A/B row; the producer-side live read re-verified at W4.
- **W2 F-6/F-7 (executor bounds; gate roots) — discharged at W3** (pre-addressing refusal seam with hostile-index rows; the four gate roots).
- **W3 F-3 (opt-in falsify capture) — discharged by record**: the falsify run (rc=0, all 12 rules load-bearing) is recorded in the T-138 notes and cited by the T-142 index E4 row.
- **W5 F-1 (scoped marker-scan citation) — discharged at W7**: the index's E4 row carries the sink-line scope and the boundary item; the notes file was left byte-exact by design.
- **Still open (carried, all note-level).** W1 F-2/F-3 and W2 F-4/F-5 (spec/design wording fixups at the next spec touch); W1 F-5 (UI placeholders → device validation); W1 F-6 (owner copy review); W3 F-2 (the erratum comment at `CommandRouter.swift:1117` still cites "§24's" for the phrase that lives in the design risk table); W3 F-5 / W4 F-5 (optional scan-anchor extension); W4 F-4 (the opener's supersede also covers the pending-app-launch and voice-ack paths — recorded, behaviourally untested); W4 F-7 (the :912-913 comment still says "finds no frame yet — a no-op" while the mechanism is the resolver's first guard — the net behaviour is pinned and doubly guarded; fix at next touch); W5 F-2/F-3 (awareness); W6 F-3/F-5 (recorded boundaries 3/4 of the T-142 index).

### 5. Evidence integrity

- **Reviewed sha chains (recomputed, all match the corrected committed values).** `specs/T-141-notes.md` f3edd2a20f66…, `specs/MTC-security-evidence-index.md` d03d8dc4dc00…, `specs/T-142-notes.md` 753b77bb7558… — the pre-correction digests in the W6/W7 reviews (54ede977…, e6d1c17c…, bc7ebd84…) are superseded by exactly the in-place review corrections those reviews describe.
- **Wave-gate counts re-verified from the retained bundles.** W5 combined rerun 157/157 (`/tmp/mtc-w5-evidence/w5-gate.xcresult`: 157 passed / 0 failed); W4 rerun 2 204/204 (bundle 18-26-06: 204/0); W4 pre-fix red bundle 18-30-16 (1 failing test of 17 — the F-1 real-seam row with the superseded signature) against post-restore 18-32-28 (17/17); W6 run 1 and run 2 both 6638 / 6620 / 8 / 10; measured base full 6403 / 6357 / 36 / 10; base scoped 173 / 160 / 13; HEAD scoped 173 / 169 / 4 — the last five from the retained summary files in `/tmp/mtc-w6-evidence/` (the bundle clones named there exist).
- **Failure classification stands.** All 8 HEAD run-2 failures are classified (5 exact-name at base, 2 same-suite family members, 1 load flake green in an isolated rerun); run 1's eighth failure was feature-caused (the second allow-list pin) and was fixed in-unit with scoped-green evidence; the base is strictly redder in every paired comparison. The measured base inventory (36 records / 34 unique, grouped 15 timing-family + 17 measurement-environment + 2 margin + 1 pin + 1 glyph) supersedes the old "~21" estimate.
- **Other wave gates (from the recorded gate bullets and logs, consistent with the reviews).** W1 270/270; W2 64/64 then the r2 gate 65/65; W3 99/99 with the T-133 rerun 89/89; W4 T-136 gate 3 101/101 and the T-134 rerun 102/102; W5 unit gates 114/114 and 117/117; W7 structural validation 0 failures on the corrected index (E 8/8, V 4/4, M 5/5, R 5/5, 43/43 tokens resolve, negative path exercised on a mutated copy).
- **In-run build gates.** The release log-safety gate (24 cases / 12 rules) and the intent-prompt mirror ran green inside the W6 full runs (present in the retained full-run log) and in every wave gate.
- **Honesty checks.** The red histories are retained (T-133 run 1 compile-red; T-136 gate-2 SIGILL; T-139 runs 1-3; T-140 red then green; the W6 base first-attempt red). Console-vs-bundle count discrepancies are disclosed and the bundle declared authoritative. No console or bundle count in the record failed re-verification here.

### 6. Code quality and scope

- **Delta census (re-derived).** 13 commits = six design-chain commits (requirements → design L1 → design L2 → review L2 → security design review → task plan) + seven wave commits (W1..W7). 168 changed files, +26,876/−3,888, categorized: 16 app-source production files, 21 test-tree files (14 new suites plus 7 edited), 99 spec files, 10 run-state files, 1 docs file, 21 other iOS files (the regenerated project file, the `ios/project.yml` resource entry, the release log-safety script and its added fixture trees).
- **Production delta = the designed set, exactly (16 files).** Four new dialogue files (`DialogueManager`, `DialogueAnswerPath`, `DialogueCandidateBuilder`, `DialogueOptionCatalog`), the catalog JSON resource, `IntentTranscriptPreparation`, and the designed edits to `LocalBrainChain`, `CommandRouter`, `AppCoordinator`, `VoiceSessionStateMachine`, `KeywordIntentRule`, `VoiceContactSearchRoute`, `LogSanitiser`, `HomeView`, `HomeSubviews`, and the strings catalog — matching the T-141 production-file list verbatim. No file outside the designed set. No debug leftovers (TODO/FIXME scan clean on all new files; the only prints in `CommandRouter` are pre-existing debug-only sites outside every new region); no stray files (working tree carries only the one recorded notes line plus run bookkeeping by the framework's review step).
- **Documented baseline test repairs (both read in full).** The Spotify catalog pin 1341→1361 with the arithmetic and provenance in its comment (W1 F-4 discharged; red at base, green at HEAD); the second allow-list pin widened by exactly the six dialogue keys with a declaration comment (feature-caused regression found by the full sweep, fixed in-unit; the cross-check assertion still computes the declared union, so it is not a rubber stamp).
- **Resources consistent.** The catalog JSON is registered in `ios/project.yml` and the regenerated project file; the resource-ships row proves the shipped path; the strings catalog holds exactly the 17 dialogue keys (both languages, no timeout key, contiguous block — per the W1 review's key audit).
- **Run-state delta (observation, no action).** 10 `.ai-sdd/` run-state files ride the branch (constitution copy, workflow yaml, run records, gate and task evidence records, two HIL records). This is the framework's per-feature worktree convention — the wave-commit conditions recorded them and the W7 commit condition explicitly included the T-142 task record; they carry no product code and were scanned here (no transcript, marker, or fixture content). The PR integration keeps them with the branch as the feature's run record.

### 7. Security posture — summary only (the security-test verdict belongs to the next task)

The W7 index (`specs/MTC-security-evidence-index.md`, sha d03d8dc4, 65 lines) is the standing record and was re-read here; its facts were re-verified at W7 by reconstruction and its decisive numbers spot-checked here. Summary by pointer:

- **E1..E8** each carry producer, an exact reproducible invocation, observed counts and a pointer: E1 emergency dispatch with the clear forced to a no-op (corpus pair); E2 five hostile-answer rows with causal control legs (interpreter 0, cache 0); E3 the eight trap rows with the shared terminal assertions; E4 the log capture over the full dialogue set (gate rc=0 incl. fixtures; sink-line-scoped marker absence); E5 the allow-list diff and closed vocabularies (exactly six new keys, `reason` reused); E6 egress (source audit + 20 spy transports); E7 degraded-brain determinism and the Phase-1 prompt pins; E8 cache/history boundary (seeded-entry A/B; four rows).
- **M-1..M-5** pinned with task DoD lines and observed pins (pipeline guard; all four arming sites; the production sanitiser seam; six keys with `reason` untouched; candidate-index bounds end to end).
- **V-1..V-4** recorded against named rows (gibberish ordering; debug-lane regions; the V-3 re-verification; the sanity-guard-above-emergency ordering).
- **R1..R5** accepted residuals with dispositions (debug prints; static-gate blind spots; unconstrained values for allow-listed string keys; transcript policy unchanged; guard ordering shipped). **Coverage boundaries 1-7** include the W5 scoped citation, the W6 F-3 ask-line boundary, the W6 F-5 S3 division of labour, the measured base inventory, the honest device-status item, and the T-138 fixture scoping.
- **Awareness carried to the security-test step:** the index's E4 row quotes the gate command in a form that matches an injection-class scanner pattern, and several long camelCase names on run-mentioning lines match the known INJ-009-class — honest evidence in an ungated file; the security-test content must avoid those shapes (W7 note).
- No security-test verdict is issued here. Conditions M-1..M-5 and obligations E1..E8 are in place; the residuals and boundaries above bound the claim.

### 8. Adjudications (A..P)

- **A — T-125 wave-order hoist (merge types into `DialogueManager.swift`) — accepted.** Declared once, verbatim from the design; required because the resolution payload is design-pinned; consumed (not re-declared) at W2; preserves the four-entry gate wiring.
- **B — the budget comparison `<=` vs the design snippet's `<` — accepted (erratum).** Post-increment semantics make the implemented form yield exactly two probes then default/exhaust, matching the requirement's own acceptance criteria and the task Gherkin; pinned by tests; must not be "fixed" back to the snippet.
- **C — candidateChoice scaffold strip narrowed to probe-echo — accepted.** The minimal resolution of a genuine design-internal contradiction (§22 preamble vs the pinned V13 row); the public pinned predicate is unchanged; slotFill keeps the full request reading.
- **D — ladder order deadline→length→escape→barge-in→cancel→answer — accepted per the design's own counterexample**; the task-file splash order is void.
- **E — the raw-length bound is inclusive at exactly the bound — accepted** (the sanitiser clamps only above it; both boundaries pinned; no data loss).
- **F — strict whole-value candidate matching against the containment catalog API — accepted** as the only reading satisfying the pinned vectors (V3/V11); the catalog API and its suite are untouched.
- **G — the medication vocabulary parameter and its live wiring — accepted**; defaulted additively so pinned call shapes compile, then passed live at the interception with a causal A/B (W2 F-1 discharged); the design snippet's omission recorded as an erratum.
- **H — hypothesis candidate omitted when its own words are absent — accepted** (never fabricate; the composer would otherwise render an empty placeholder).
- **I — two additive defaulted parameters on the probe helpers — accepted**; pinned signatures intact, no call-site churn.
- **J — resolution-event component split (router seven turn-time outcomes; coordinator timeout/emergency/superseded) — accepted**; one emit per resolution, no double-emit, pinned in every trap row.
- **K — executor bounds seam (internal visibility; pre-addressing refusal closing as exhausted) — accepted**; hostile indices refused end to end with nothing addressed.
- **L — coordinator wiring mechanisms — accepted as minimal, each pinned:** off-main start refusal (a synchronous Bool cannot hop without lying); supersede through the funnel at the opener (closes the window through legal edges, emits once, nil-guarded); one additive window accessor (the C-1 single-source demand made concrete); the pipeline-guard visibility widening (mirrors the executor seam); manager construction at the top of the init (required by observer ordering — proven by the red gate).
- **M — the W4 blocker fix (one-main-tick deferral of arm+probe in the rephrase-discard branch) — accepted**; the fix is verified correct against the original ordering trace, the fallback legs are byte-identical to the shipped lines, and the red→green bundles on the real seam demonstrate it (finding F-1 of W4 closed).
- **N — W5 test-seam choices (timeout fired through the production-installed callback plus the bare-machine 1 s clock leg; watchdog precondition-plus-consequence; expiry over the real manager's clock seam; normalized candidate expectation) — accepted** as deterministic and faithful.
- **O — the device protocol's merged record and honest status — accepted** (all items BLOCKED with named dependencies; step zero OUTSTANDING; no device claim anywhere).
- **P — W6/W7 in-place record corrections — accepted**; the committed artifacts match the corrected digests (verified above).

### 9. Findings (all note-level; none blocks)

- **F-1 (note, documentation carry) — the W4 F-7 comment fixup is still open.** `CommandRouter.swift:912-913` says the observer hop "finds no frame yet — a no-op"; in the actual queue order the no-op comes from the resolver's first guard. Net behaviour is correct, pinned, and doubly guarded; recorded in the implement-notes dispositions. Fix the wording when the file is next opened.
- **F-2 (note, documentation carry) — the W3 F-2 citation wording.** The erratum comment at `CommandRouter.swift:1117` cites "§24's" for a phrase that lives in the design risk table; substance unaffected. Next-touch fixup.
- **F-3 (note, spec text) — queued wording fixups, no code impact:** the T-130 task-file wording (W1 F-2), the design §13b clarification (W1 F-3), the T-131 task-file wording (W2 F-4), the design errata for §10/§11/§22 (W2 F-5).
- **F-4 (note) — the awaited-answer UI mappings are compile-forced placeholders** (listening-family visuals, disabled Talk hero, empty status), additive and inert, confirmed by code read only; device validation DV-1/DV-2 is where they become observable. No rework.
- **F-5 (note, recorded boundary) — FR-MTC-019's literal missing-slot ask lines are untested anywhere** (W6 F-3); the reminder/calendar handlers are source-untouched and Phase 1 scopes them as no-change. Recorded as boundary item 3 of the T-142 index.
- **F-6 (note, owner item) — the draft copy review of the 17 dialogue keys is outstanding** (owner action OA-5; W1 F-6's drafty did-you-mean reading is an example). Owner-facing by design; no code change by any agent.
- **F-7 (note, integration hazard) — PR-time inherited-filename reconciliation.** Master-side tracked files share names with this branch's review artifacts (`implement-review-w1..w8`, `review-implementation.md`, `security-test.md`, `final-sign-off.md` all exist at the base; the branch replaces w1..w7 and this review replaces `review-implementation.md`; the base's w8 file belongs to the Spotify feature and is untouched here). The integration step must resolve the two features' numbering deliberately rather than letting the merge pick silently.
- **F-8 (note, recorded scope) — the opener's frame supersede also covers the pending-app-launch and voice-ack confirmation paths** beyond the four source-pinned arming sites (W4 F-4); consistent with the coexistence rule, behaviourally untested; A/B candidate at the next touch.
- **F-9 (note, optional) — scan-anchor coverage.** The small interface hunks and small arming-site substitutions sit outside the region-scoped console-write scans (diff-verified clean); optional anchor extension at the next touch (W3 F-5 / W4 F-5).
- **F-10 (note, awareness) — scanner-class tripwires carried forward.** See section 7's last bullet: the security-test content file must avoid the backtick command form and the long-identifier-on-run-line form (W7 note, W3 F-3-adjacent).

### 10. Open items for final sign-off

1. **Device validation — open by design.** DV-1..DV-5 are BLOCKED with named dependencies and step zero (the Phase 0 device smoke) is OUTSTANDING (`specs/MTC-device-validation-protocol.md` §7.3); owner actions OA-1..OA-5 open. FR-MTC-020 gates final sign-off on this.
2. **OD-M1..OD-M4** remain owner decisions with the designed defaults implemented (two probes; curated catalog; Phase 1 first; music probe only); confirm at the final sign-off (OA-4).
3. **Owner copy review** of the 17 dialogue keys (OA-5; findings F-6).
4. **Inherited-filename reconciliation at PR time** (finding F-7).
5. **Next workflow step:** the security-test task consumes the T-142 index (this review deliberately issues no security verdict).
6. **Carried fixups** (F-1..F-3, F-9, F-8's optional A/B) at the next touches of the respective files; none affects behaviour.

### Reviewed commits

| Commit | Content |
|---|---|
| 437d4dc | define-requirements: feature story (T1 owner-approved) |
| 59b66d9 | design-l1: L1 architecture |
| ab43526 | design-l2: component design |
| 1ed8c21 | review-l2: GO — design chain cleared |
| 60850db | security-design-review: SECURITY-GO |
| b71ca2a | Add task breakdown (plan-tasks, 19 tasks) |
| 76b28b9 | W1: T-125..T-130, T-135, T-137 (foundations, keys, vocabularies) |
| 3b44c0c | W2: T-131, T-132 (answer path, candidate builder) |
| cf416ac | W3: T-133, T-138 (interception, release log gate) |
| cc065b0 | W4: T-134, T-136 (triggers, coordinator wiring; blocker fixed pre-commit) |
| ac89744 | W5: T-139, T-140, T-143 (hostile corpus, trap matrix, log/egress, device protocol) |
| 5860878 | W6: T-141 (acceptance and no-regression sweep) |
| 134d77e | W7: T-142 (security evidence index) |

### Verification commands (read-only, from the worktree)

```
git log --oneline 0cbe4e6..HEAD
git status --porcelain
git diff 0cbe4e6..HEAD --stat | tail -5
git diff 0cbe4e6..HEAD --name-only | (category census)
shasum -a 256 specs/T-141-notes.md specs/MTC-security-evidence-index.md specs/T-142-notes.md
xcrun xcresulttool get test-results summary --path <retained bundle>   # W5, W4 r2, W4 pre/post, W6 set
python3 (extract totals from /tmp/mtc-w6-evidence/*-summary.json)
grep -n (interception banner / gate / attempts / emergency clear / comment anchors in CommandRouter.swift)
grep -n (state machine window chain; coordinator construction/observer/guard; answer path landmarks)
grep -c '"dialogue\.' ios/ElderlyAssistant/Resources/Localizable.xcstrings   # 17
git diff 0cbe4e6..HEAD -- <the two baseline test files>   # bounded repairs
```

## Decision

decision: GO

All criteria met. The multi-turn conversation feature is fully implemented per the approved design chain, and every stage review in the chain — requirements, L1, L2 (GO), security design review (SECURITY-GO), and the seven wave reviews (GO 0.90, zero blockers) — is reconciled against the committed bytes at HEAD 134d77e: the sha chains recompute, the gate counts match their retained bundles, the applied corrections are present in the artifacts, and every carried item is open and listed. The 32 requirements trace to a witness and an evidence row or an explicitly recorded gap; the production delta is exactly the designed 16 files with no leftovers; the measured base is strictly redder than HEAD in every paired comparison, so no new failures are attributable to the feature. The remaining obligations are owner-facing or scheduling items, not implementation defects: the DV device run behind FR-MTC-020, OD-M1..OD-M4, the copy review, and the PR-time filename reconciliation. The security posture is summarized by pointer only; its verdict belongs to the next workflow task. Confidence 0.90 exceeds the 0.85 stage overlay threshold.

Commit conditions: (1) the reviewed content is HEAD 134d77e as-is; the single uncommitted implement-notes line (the W7 hash fill) rides the next worktree commit or the integration step, and nothing else in the working tree belongs to the reviewed delta; (2) integrate the branch without content edits to the reviewed files — any post-review edit requires re-review of that file; (3) resolve the inherited-filename collision deliberately at integration (finding F-7); (4) carry the open items (section 10) into the final-sign-off gate without waiver — in particular the DV record and the owner decisions.
