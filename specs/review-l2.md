# review-l2 — Component design review (L2)

- Task: `review-l2` (workflow `call-dialer-primary-secondary`), contract `review`.
- Workflow exit condition for this task: `review.decision == GO` (specs/call-dialer-primary-secondary/workflow.yaml).
- Feature: call-dialer-primary-secondary. Worktree: /Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary. Branch: feat/call-dialer-primary-secondary.
- Disposition: read-only review — no files written, no git state touched; this report is returned to the orchestrating session for recording at specs/review-l2.md.

## Artifacts under review

| Artifact | Contract | Size | sha256 (64 hex, grouped 8x8 for output hygiene) |
|---|---|---|---|
| specs/design-l2.md | component_design_l2 | 1245 lines | cd6dedcd d578735b 6e33606e 5e550875 8fe91caa 83eb48fb 74ad81d8 1c96e120 |
| specs/design-l1.md (reference baseline) | architecture_l1 | 871 lines | 5446333b 27a6a20a 3cc3f658 7efcc757 da8ec1ba 9d00282c 56b1d09d 3c990c6d |

Both hashes were re-verified with shasum this session and match the contracts exactly; both files were unchanged during the review.

## Inputs consulted

Root constitution.md (Standards, Agent Principles, release gates); feature constitution specs/call-dialer-primary-secondary/constitution.md (12 Feature Constraints; Open Decisions: None); frozen owner design docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md (Decisions 1-5); specs/define-requirements.lock.yaml plus the FR-CDP and NFR-CDP files (read verbatim where binding); the workflow file above; and the worktree source baseline: AppCoordinator.swift, LeafViews.swift, CallingSettingsView.swift, VoiceSessionStateMachine.swift, L10n.swift, MethodResolver.swift, CallLinks.swift, FamilyContactStore.swift, Info.plist, Localizable.xcstrings, ios/tools/check-release-log-safety.py, ios/build.sh, and the test bundle (CallChannelResolutionTests, MethodResolverTests, MissedCallDialBackTests, L10nCatalogCoverageTests, IntentLogStoreTests, SpotifySettingsSurfaceTests).

## Verification method

Adversarial, read-only re-verification: every load-bearing line anchor and behavioural claim in the L2 was re-read against the worktree source at this baseline rather than trusted from L1 prose (the anchor set listed at design-l2.md:14 was spot-checked; all anchors checked were found exact to the line). Independent checks: (a) sha256 and line counts of both artifacts; (b) the five new localization keys confirmed ABSENT and the reused keys (settings.calling.title, calling.defaultCaption, app.name.facetime, app.name.whatsapp, call.announce.noPhoneNumber) confirmed PRESENT in Localizable.xcstrings; (c) C1-C7 cross-mapped one-to-one to the L1 component map and to L1 integration rows 1-31, with the 28-row per-file edit list (design-l2.md section 13) as the implementation surface; (d) owner decisions 1-5 and the frozen type shapes checked for re-opening; (e) the 64-cell never-dead-ends argument, equal-pick dedupe, vocabulary case table and hop termination proof traced by hand; (f) resolvedCallChannel production call sites confirmed to be exactly two (LeafViews.swift:1612-1615, AppCoordinator.swift:8387) plus the test helper; (g) PendingCallAction constructions enumerated repo-wide (exactly four: AppCoordinator.swift:7624, :7670; IntentLogStoreTests.swift:206, :224).

## Summary

decision: GO

Result: 0 BLOCKER / 1 MAJOR / 4 MINOR / 2 NOTE. All five review-checklist items pass. All six binding gates pass: GSM hard floor configurable-away-proof; emergency-contact semantics and the override protocol unchanged; probes local-only; numbers and handles never logged (with check-release-log-safety coverage); ne/en keys bounded to exactly the five named keys. The L2 is a faithful, traceable decomposition of L1 inside ADR-CDP-01..11 and RES-1..10 — no element beyond them, no re-opened owner decision, no frozen-shape drift. The single MAJOR (F-1) is a source-fact error in the launch-failure classification table (openWhatsAppChat mischaracterised as returning Void, and its recovery chain mis-attributed) that must be corrected before the affected row is implemented; it does not break the no-dead-end guarantee or the announcement guarantees. Findings F-1..F-7 are required actions for plan-tasks/implement, not a design re-cycle.

## Checklist

1. Explicit error return types (no any/unknown) — PASS. design-l2.md section 22 (:1112-1114): "No new error type, no throw, no Result-with-Error"; the failure vocabulary is the shipped typed outcomes — CallApp (:66-84), FaceTimeOutcome (:114-123), MessengerOutcome (:145-157), MessengerChatOutcome (:163-171), WhatsAppCallOutcome (:177-190), and openPhone returning Bool (:340) — each bound to exactly one handling class by the classification table at :794-811. Every new interface returns a concrete value type (CallChannelChain.Result carrying channel plus fellBackFrom; the hop step returns an optional pair, exhaustion defined as nil after the already-spoken line). No untyped error channel appears anywhere. The one mislabeled member (openWhatsAppChat claimed Void at :799) is F-1 — a factual mislabel, not a missing type.

2. Async or external calls have a documented failure mode and recovery — PASS (with F-1). Every external open site is enumerated with its outcome set and handling class (:794-811): recoveries (needsNativeCompose, copiedNumber, fellBackToWeb, openedWebChat) are pinned as non-hopping; failed-with-hop speaks the shipped line then the hop; failed-terminal speaks the shipped line only; exhaustion is defined. The hop termination proof (:896) bounds recursion depth by strictly shrinking candidates (depth at most 2). Concurrency: everything main-confined; no new Task, timer, queue, lock or actor (:1142-1146). The whatsappChat row (:799) is the one entry whose stated basis is wrong — see F-1.

3. Timeouts and retry limits are configurable, not hardcoded — PASS. The design introduces no new timeout, timer, retry or backoff (:915, :1145, :1154-1155). The only timing parameter in play remains the shipped VoiceSessionStateMachine.confirmationTimeoutSeconds = 45 (VoiceSessionStateMachine.swift:135), reused untouched and not re-hardcoded (the prompt grows by at most one clause inside the unchanged window, :1154). Hop depth at most 2 is structural — a consequence of the three-step chain plus dedupe — not a magic retry constant.

4. Every element traces to an FR or NFR; L2 decomposes L1 only — PASS. The component map C1-C7 (:70) is identical to the L1 component set; section 29 (:1183+) carries per-component coverage to FR-CDP-* / NFR-CDP-*; section 13 (:995-1027) covers L1 integration rows 1-31 with no extra surfaces. L2-D1..D12 (:49-66) are recorded refinements inside ADR/RES scope (notably L2-D4 LaunchHop replacing L1 C5's bare defaulted parameter, and L2-D9 adding hopCandidates to MissedCallDialRoute) — both consistent with L1's 'hop candidates threaded' prose and recorded with rationale, not silent. Nothing beyond ADR-CDP-01..11 / RES-1..10 was found. Owner decisions 1-5 are not re-opened (automatic routing with announcement; all call paths; messenger feasibility = handle-on-file only, kept by L2-D6; secondary default .phone with dedupe; multi-turn confirmation reused exactly). Frozen type shapes are reproduced verbatim (Feasibility; Result; route(preferred:secondary:feasibility:); CallApp; supportsVideo/supportsAudio).

5. Operator-visible run and failure behaviour (announcement honesty) — PASS (with F-1). Section 23 (:1116-1125) is a complete spoken-line table: disclosure clause inside the prompt for voice; announce-then-open for tap and dial-back; one hop line spoken exactly once (the single call.announce.launchFailedFallback site, :826-828); floor and exhaustion speak the shipped line only. All copy composes from one source (fellBackFrom.first plus the routed channel), so speech cannot diverge from the executed action; empty fellBackFrom keeps the shipped prompt byte-identical (test pin :1173). Announcements are speech only and never routed through logging (:1136). The whatsappChat false case needs the explicit disposition recorded in F-1.

## Binding gates

- GSM hard floor, configurable-away-proof — PASS. route is total: phone is always feasible; equal picks dedupe; both-infeasible lands on or substitutes the floor (:903-909); the 64-cell matrix assertion pins isFeasible(result.channel) and vocabulary legality (:1171). Any settings combination, including duplicates, still reaches an attemptable channel.
- Emergency-contact semantics and override unchanged — PASS. The override block :7656-7686 is listed unchanged (verify only) with the gate :7665-7669 intact and the amended action dropping provenance (:1015, matching :491-492); emergency paths untouched (:1163); dial-back runs the ordinary chain only.
- Probes local-only (canOpenURL plus handle check) — PASS. WhatsApp feasibility is an injected canOpen closure; Messenger feasibility is the address-book handle check; the shipped canOpenURLOnMain hop (:7312-7315) is reused; no plist, permission or host change (Info.plist already lists the schemes, :59 and :94); no new egress or data store (:1159-1160).
- Numbers and handles never in logs (B2/T-050; check-release-log-safety coverage) — PASS. No new console writes anywhere; every emitted event carries metadata with channel raw values only (:1127-1133); no LogSanitiser.allowedKeys change; FEATURE_ROOTS (check-release-log-safety.py:141+) gains Services/Calls so the new file sits inside the gate; ios/build.sh:431 must stay exit 0 (:1134-1135; NFR-CDP-010).
- ne/en keys bounded to exactly five — PASS. Section 12 (:979-991) defines exactly settings.calling.primaryTitle, settings.calling.secondaryTitle, router.call.fallbackDisclosure, call.announce.fallbackRouted, call.announce.launchFailedFallback, with binding parameter contracts and named composition sites; all five verified ABSENT in Localizable.xcstrings today; all other user-visible labels reuse existing keys (CallingSettingsView.swift:70-77; CallChannelChain.nameKey). No sixth user-visible string is introduced.
- Artifact integrity — PASS. design-l2.md matches component_design_l2 (grouped cd6dedcd d578735b 6e33606e 5e550875 8fe91caa 83eb48fb 74ad81d8 1c96e120); design-l1.md matches architecture_l1 (grouped 5446333b 27a6a20a 3cc3f658 7efcc757 da8ec1ba 9d00282c 56b1d09d 3c990c6d).

## Findings

F-1 — MAJOR — openWhatsAppChat mischaracterised in the failure classification (two lines contradict source; one recovery chain mis-attributed).
Evidence. design-l2.md:799 states the .whatsappChat row has "(no outcome — openWhatsAppChat returns Void)". Source: @discardableResult func openWhatsAppChat(_ rawPhone: String) -> Bool (CallLinks.swift:365-370), returning false when whatsAppChatURL is nil (:283-287 — no dialable digits). design-l2.md:609 states openWhatsAppChat's "absent-app path is the shipped needsNativeCompose / copiedNumber recovery" — source: openWhatsAppChat has no recovery chain and no absent-app path (its own doc at :360-364 says it is unconditional and cannot detect absence); the needsNativeCompose / copiedNumber chain belongs to openWhatsAppCallChat (CallLinks.swift:457-470, outcomes at :466-469).
Impact. The document's own totality claim (:1114, 'Every class speaks; none is silent') is contradicted by this row: the shipped .whatsappChat site (AppCoordinator.swift:7755-7765) discards the Bool, so an unusable phone is silently dropped. An implementer following the table literally would reproduce that, and could implement the .whatsappChat branch against the wrong opener's semantics. The intended behaviour (no hop, per RES-10) is defensible and the silent case pre-exists the feature, so this is not BLOCKER-class; but the table's stated basis is wrong under the doc's own 'verified per outcome' heading.
Required action. Correct :799 to state the signature Bool and the false-only-when-no-digits condition (CallLinks.swift:283-287), and record the explicit disposition: either speak the shipped announceNoUsableNumber line on false (recommended, holds the 'none is silent' claim) or document a shipped-identical exception in section 22. Correct :609 to attribute needsNativeCompose / copiedNumber to openWhatsAppCallChat only.

F-2 — MINOR — Non-existent enum case .facebook in the vocabulary case table.
Evidence. design-l2.md:903: the .anyChannel row's preferred-to-routed column reads '.facebook -> .faceTime'; CallApp has exactly four cases (faceTime, phone, messenger, whatsApp; CallLinks.swift:66-84). The same row's attempt-order and candidates columns show the intended preferred was .faceTime.
Required action. Replace .facebook with .faceTime.

F-3 — MINOR — 'five shipped labelled constructions' disagrees with the verified enumeration.
Evidence. design-l2.md:1106: 'the five shipped labelled constructions compile unchanged (verified: :7624, :7670, IntentLogStoreTests.swift:206, :224)' — four sites listed, and a repo-wide enumeration this session found exactly four PendingCallAction constructions (AppCoordinator.swift:7624, :7670; IntentLogStoreTests.swift:206, :224). If 'five' was meant as an arity descriptor (as the parallel 'five-arg' phrasing at :1177 suggests), the wording is ambiguous.
Required action. State 'the four shipped labelled constructions' (or explicitly 'five-argument constructions') so count and sites match.

F-4 — MINOR — replacing() doc comment claims routing provenance carries over; the code drops it.
Evidence. design-l2.md:497-500 comment: 'routed method and remaining candidates replaced; provenance and the flywheel pair carry over, so the hop neither re-speaks the disclosure'. The listing (:501-509) forwards only sourceTranscript, sourceCommand and requestedAt (plus the new hopCandidates); fellBackFrom is not passed and resets to its default [] (:487). In this document's own vocabulary, fellBackFrom IS the provenance (:111).
Impact. Comment accuracy only — the behaviour (the hop never re-speaks the disclosure) is the intended one and matches the one-line-per-outcome rule; the comment as written would mislead a reader into thinking a stale disclosure is carried.
Required action. Reword, e.g. 'the flywheel pair carries over; fellBackFrom deliberately resets to [] so the hop never re-speaks the disclosure'.

F-5 — MINOR — NFR-CDP-006's non-visual selected-state requirement is cited but not specified.
Evidence. NFR-CDP-006 (MUST) requires each row to announce section, channel name and selected state, and that 'the checkmark is not the only indication of selection' (NFR-CDP-006 acceptance criteria). The shipped row conveys selection only by checkmark.circle.fill plus a stroke overlay (CallingSettingsView.swift:40-64), with no selected trait or accessibility value; a plain Text header in a VStack is not automatically a VoiceOver heading. design-l2.md:975 cites (NFR-CDP-006) coverage via 'the shipped row pattern ... is kept' and section headers, and the picker UI test list (:1174) carries no accessibility assertion.
Required action. Specify the non-visual selected signal for both sections (for example a selected accessibility trait or an accessibility value on the selected row), and either add a heading trait for the section titles or soften the claim; add the assertion to the picker UI suite (:1174).

F-6 — NOTE — Section 25's pending-action reader/writer enumeration is not exhaustive.
Evidence. design-l2.md:1143 lists readers as 'confirmationPrompt, the override gate, the timeout recorder' and lists recordConfirmationTimeout under writers with a reads-it parenthetical. Source readers additionally include isAwaitingCallConfirmation (AppCoordinator.swift:7553) and its consumer at :10720 (pendingCallAction is not nil in the routing-busy check); the call block reads and nils the slot at :10611-10612.
Required action. Add isAwaitingCallConfirmation (:7553, :10720) to readers and list recordConfirmationTimeout (:10562) as a reader — it matters here because removing the early return (:7620-7623) changes when the slot can be live.

F-7 — NOTE — Test-name typo in the suite table.
Evidence. design-l2.md:1171 lists testAssessmentOrderAlwaysEndsPhone; the property under test is attempt order and the floor (sections 10.3-10.4), so 'Assessment' is presumably 'Attempt'.
Required action. Rename, for example testAttemptOrderAlwaysEndsPhone, so the name matches the property.

## Decision

decision: GO

0 BLOCKER / 1 MAJOR / 4 MINOR / 2 NOTE. No BLOCKER-class issue exists against the workflow exit condition (review.decision == GO) or the feature constitution constraints: the GSM hard floor, dedupe and at-most-once routing, override and emergency preservation, local-only probes, log safety and the five-key bound are all satisfied by the design as written. The MAJOR (F-1) and the MINOR items are required corrections to be applied at plan-tasks and implement time (F-1 before the .whatsappChat row is implemented); none requires a design re-cycle or re-opens the frozen owner design.