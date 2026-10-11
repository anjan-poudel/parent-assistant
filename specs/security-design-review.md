# security-design-review — Security design gate (STRIDE)

- Task: security-design-review (ai-sdd workflow call-dialer-primary-secondary); contract: security review of the component design.
- Workflow exit condition for this task: review.decision == "SECURITY-GO" (specs/call-dialer-primary-secondary/workflow.yaml).
- Agent: sdd-reviewer (Reviewer). Feature: call-dialer-primary-secondary.
- Worktree: /Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary (read-only). Branch: feat/call-dialer-primary-secondary.
- Disposition: read-only security review — no files written, no git state touched; this report is returned to the orchestrating session for recording at specs/security-design-review.md.

## Artifacts under review

| Artifact | Contract | Size | sha256 (grouped 8x8 for output hygiene) |
|---|---|---|---|
| specs/design-l1.md | architecture_l1 | 871 lines | 5446333b 27a6a20a 3cc3f658 7efcc757 da8ec1ba 9d00282c 56b1d09d 3c990c6d |
| specs/design-l2.md | component_design_l2 | 1245 lines | cd6dedcd d578735b 6e33606e 5e550875 8fe91caa 83eb48fb 74ad81d8 1c96e120 |
| specs/review-l2.md | review (design-gate record) | 87 lines | 4526d427 9bd31f84 9988f867 b6a9deaa cda75ab4 eeebe7a3 33c8c201 83ef7a33 |

The two design hashes match their declared contracts exactly; all three artifacts were re-hashed at the end of this review and were unchanged during it. review-l2.md has no declared contract hash — its content (decision GO; 0 BLOCKER / 1 MAJOR / 4 MINOR / 2 NOTE; findings F-1..F-7) was read verbatim this session and is the disposition baseline this review carries forward.

Basis documents consulted (hashes grouped 8x8): specs/define-requirements.lock.yaml — 242 lines, cea80dcd 3f793b0a bcc752f5 8b84af25 23248f80 85629890 c6497648 07758f8 (19 FR / 10 NFR; six security_surfaces; the security-design-review and security-test traceability gates are the basis for the five focus areas); frozen owner design docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md — 183 lines, 16a5a9c3 822d3ad6 4a460a71 7bd6a219 a78626c0 bbfaa201 47f42672 82941fd8; feature constitution specs/call-dialer-primary-secondary/constitution.md — 101 lines, e5f816c3 a9d56743 26136204 ca657fe7 a739e8f6 671f9dfd d838e243 3a1f43e5; root constitution.md — 159 lines, 7feae062 30b7e58e a2256a4e 332d0b80 7029642c e7a0646f 6ac3ddcd 460c9ef8; workflow specs/call-dialer-primary-secondary/workflow.yaml and its mirror .ai-sdd/workflows/call-dialer-primary-secondary.yaml — 190 lines each, c0ec077b b738e6ad b55eafba 7c30cb97 46fffc78 fabf702f b80df79e 4f8f4ec5 in both copies; byte-identical (diff exit 0).

## Verification method

Adversarial, read-only re-verification against the worktree source at this baseline — every load-bearing security claim of the design was re-read from source rather than trusted from the documents. Specifically: the chain algebra (the CallChannelChain listing and its never-dead-end argument) was traced by hand over all 4 x 4 pick pairs x 4 feasibility states (64 cells); the AppCoordinator seams (resolve, request/confirmation, override, perform, launch-fail hop, dial-back, observability) were re-read at the line anchors the L2 cites; the probe path (the canOpenURLOnMain hop, the LeafViews installed probe, Info.plist declared schemes, the address-book handle check) was re-read; the log-safety coverage mechanics (check-release-log-safety.py FEATURE_ROOTS and role matching) were re-read and the release gate was run to a baseline exit 0; the catalog state (five new keys absent; reused keys present) was re-checked; the call-site enumerations (resolvedCallChannel, resolvedMissedCallChannel, PendingCallAction constructions) were re-grepped repo-wide. review-l2 findings F-1..F-7 were re-verified against source, not accepted on their internal evidence alone. Output hygiene: hashes are grouped 8x8 and long paths are broken across spans.

## Summary

Decision: SECURITY-GO

0 BLOCKERs. 2 must-fix conditions (M-1, M-2). 6 verify-and-record items (V-1..V-6). 9 evidence obligations for security-test (SA-1..SA-9). 7 accepted residuals (R-1..R-7). 7 STRIDE surfaces modelled (settings persistence, feasibility probes, chain resolution, announcement/confirmation copy, launch-fail hop, observability, localisation strings).

All five workflow focus areas pass as designed: (1) the GSM hard floor cannot be configured away — traced inspection of the chain shows attemptOrder always contains .phone, .phone and .faceTime are unconditionally feasible, equal picks dedupe, route returns only inside the feasible loop, and the vocabulary substitution terminals (.phone for anyChannel/audio, .faceTime for video) are themselves always feasible and permitted; (2) emergency precedence and the override protocol are untouched — the emergency dial is UIKit-direct outside every touched seam and the override gate at AppCoordinator.swift:7665-7669 is marked verify-only/unchanged, with the amended action intentionally dropping provenance; (3) probes are local-only — the shipped canOpenURL hop plus the address-book handle check; no new plist entry, permission, store or egress; (4) announcement honesty — confirmation and announcements compose from fellBackFrom.first plus the routed channel at single sites, with one must-fix (M-1) pinning the disposition of a known pre-existing counterexample the feature makes more reachable; (5) log sanitisation — no new console writes; metadata is [:] and events carry closed-vocabulary raw-value tokens only; Services/Calls joins FEATURE_ROOTS in check-release-log-safety.py so the new file sits inside the release gate.

The two must-fix conditions are corrections, not guarantee breaks. M-1 pins the disposition review-l2 already required for the .whatsappChat launch-failure row (a source-fact error plus an unpinned disposition for a pre-existing shipped site). M-2 corrects the attempt-order wording ("always ending .phone" is literally false when preferred == .phone) and the planned test name that would encode the false property, so neither documents nor a shipped test can be 'fixed' into reordering the chain away from preferred-first.

## Verification ledger

| # | Claim verified | Evidence (source re-read this session) | Verdict |
|---|---|---|---|
| 1 | Chain never dead-ends; floor containment; dedupe; vocabulary terminals | CallChannelChain listing (design-l2 section 6) traced over 16 pick pairs x 4 feasibility states; FR-CDP-006/007, NFR-CDP-001 | PASS |
| 2 | .phone and .faceTime unconditionally feasible; messenger feasible iff handle; whatsApp feasible iff probe | isFeasible semantics in the C1 listing; FR-CDP-004/005/006; CallLinks.swift supportsVideo :80, supportsAudio :83 | PASS |
| 3 | Override gate byte-identical | AppCoordinator.swift:7656-7686; gate :7665-7669 speaks router.call.messengerNoHandle, original stays pending, returns true; design edit #17 marks verify-only | PASS |
| 4 | Amended action :7670-7674 compiles with the new defaulted var fields and drops provenance (no stale disclosure re-spoken) | Source :7670-7674 (5-arg construction); design-l2 :491-492 | PASS |
| 5 | Emergency dial bypasses every touched seam | RedesignComponents.swift:229-237 (trigger calls coordinator.emergencyNotify(), then PhoneDialer.url, then UIApplication.shared.open); emergency notify :6745-6758 is notification + ack and does not place a call | PASS |
| 6 | Emergency-contact resolution not rewired | AppCoordinator.swift:6463-6480 is NotifyChannel.resolve-based; non-goal in design and requirements index | PASS |
| 7 | Dial-back routes the ordinary chain only; never delays escalation | :8382-8390 (supportsAudio guard :8386); dial-back call chain :8423-8483 contains no emergencyNotify or NotifyChannel call | PASS |
| 8 | Probes local-only; no plist delta planned | canOpenURLOnMain :7312-7315; whatsapp:// literal :7270; LeafViews installed probe :1171-1174; Info.plist :59 with whatsapp :94, fb-messenger :69, facetime :66, facetime-audio :67, tel :90 | PASS |
| 9 | No new console writes; PII out of logs | Design sections 24-25; metadata [:] C9 policy at :7840; LogSanitiser.allowedKeys :56 unchanged; NFR-CDP-003 | PASS (SA-6) |
| 10 | Release-gate coverage mechanics | check-release-log-safety.py FEATURE_ROOTS :141+ (tail :184-187), role match :821-834 makes the new Services/Calls file feature-role (rules 3-6); coordinator-side files receive rules 1-2 only — source-audit obligation | PASS (SA-6) |
| 11 | Release gate baseline green | ios/tools/check-release-log-safety.sh run this session: exit 0 (fixture suite proves each rule positive and negative); build.sh :431-434 wiring intact | PASS |
| 12 | F-1 confirmed and security-reframed | CallLinks.swift:366-370 openWhatsAppChat returns Bool (false when whatsAppChatURL nil, :283-287); doc :360-364 claims unconditional; needsNativeCompose/copiedNumber belong to openWhatsAppCallChat :457-470 (:465-469); AppCoordinator :7755-7765 discards the Bool, speaks router.call.whatsappOpened and calls noteConfirmedCallExecution — a false success claim plus false learning on the voice path | M-1 |
| 13 | New .phone guard fixes the false-claim class at the voice floor | Source :7723-7732 discards openPhone Bool today (:340-344, false only when no digits); design adds guard + announceNoUsableNumber + no recency on failure | PASS (SA-5) |
| 14 | PendingCallAction constructions repo-wide: exactly 4 | :7624 and :7670; IntentLogStoreTests.swift :206 and :224 (re-grepped this session) | PASS (V-2 wording) |
| 15 | resolvedCallChannel production call sites: exactly 2 plus one test helper | LeafViews.swift:1612-1615; AppCoordinator.swift:8387; CallChannelResolutionTests.swift:61 | PASS |
| 16 | resolvedMissedCallChannel: exactly 1 production site plus tests | AppCoordinator.swift:8432; MissedCallDialBackTests | PASS |
| 17 | MethodResolver global-default step becomes the settings primary via injected closure | MethodResolver.swift :74-78 (step 4 .phone / .globalDefault); init :22-26; FR-CDP-012 | PASS |
| 18 | secondaryCallApp persistence mirrors the defaultCallApp pattern; absent/garbage decodes to .phone | :329-335; :2850-2853 (.flatMap(CallApp.init(rawValue:)) ?? .phone); NFR-CDP-005 | PASS |
| 19 | Confirmation timeout untouched | VoiceSessionStateMachine.swift:135 = 45 seconds | PASS |
| 20 | Settings UI selection conveyed only by checkmark plus stroke overlay (F-5 evidence) | CallingSettingsView.swift:40-64; no selected trait or accessibility value | CONFIRMED (V-4) |
| 21 | Five new keys absent; reused keys present | Localizable.xcstrings: the five new keys count 0; settings.calling.title, calling.defaultCaption, app.name.facetime, app.name.whatsapp, call.announce.noPhoneNumber, router.call.messengerNoHandle, router.call.confirmQuestion count 1 each | PASS |
| 22 | Speech is catalog-bound (no hardcoded user-visible literals on new paths) | Design sections 9 and 12 composition sites; L10nCatalogCoverageTests exists | PASS (SA-8) |
| 23 | Hop dispatch reuses the shipped openers | LeafViews tile/row funnel :1536-1597; performContactCall :7831-7910; performSystemContactWhatsApp :7971-8000; performSystemContactMessenger :8053-8083 | PASS |
| 24 | Address-book handle checks unchanged in mechanism | storedMessengerHandle :8009-8011; LeafViews stale-state guard :1573-1580 | PASS |
| 25 | Observability events stay closed-vocabulary with metadata [:] | :7834-7841 (outcome video:<rawValue>, C9 comment :7840); hop event tokens are raw values | PASS |
| 26 | Design-l2 section 25 reader/writer list is not exhaustive (F-6) | isAwaitingCallConfirmation :7553, consumer :10717-10723; slot nil'd :10611-10612; recordConfirmationTimeout :10561-10569 reads the slot | V-5 |
| 27 | New file graded feature-role by directory-prefix match | role assignment code :821-834 (path == feature or startswith feature + os.sep) | CONFIRMED (SA-6) |
| 28 | No store beyond secondaryCallApp; no per-contact primary/secondary storage | Design edit list; FR-CDP-018 boundary | PASS |
| 29 | Workflow mirror byte-identical; exit condition string confirmed | diff exit 0; workflow.yaml read | PASS |
| 30 | review-l2 findings mapped forward | F-1 → M-1; F-2..F-7 → V-1..V-6 (F-7 linked to M-2) | PASS |

## STRIDE threat model

The lock's six security_surfaces expand to the seven implementation surfaces below (the chain floor and feasibility split across chain resolution and probes; PII exposure across observability and localisation). Every control named was verified against the worktree source at the anchors in the ledger. Residuals are labelled R-n and defined in full below.

### S1 — Settings persistence (secondaryCallApp, UserDefaults)

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | A second process faking the stored pick | iOS app-container UserDefaults is single-writer by sandbox; value consumed only via CallApp.init(rawValue:) | PASS |
| Tampering | User or device-access attacker sets secondary == primary, garbage, or a hostile pick | Equal picks are legal by design and deduped; garbage/absent decodes to .phone (:2850-2853 pattern); no configuration can remove the floor (S3) | PASS |
| Repudiation | Dispute over what was selected | No security-audit obligation in FR-CDP-003; the picker is visible UI state | PASS |
| Information disclosure | The stored value is a channel name only (non-PII) | Mirrors defaultCallApp's 'a UI preference, not a secret' (:329-335); cannot exfiltrate numbers | PASS |
| Denial of service | Corrupt value disabling calling | Decode failure falls back to .phone; dialability never depends on the setting | PASS |
| Elevation of privilege | Setting bypassing feasibility or emergency | Feasibility re-evaluated per call; the setting cannot force execution on an infeasible channel (openers re-guard); emergency chain untouched | PASS |

### S2 — Feasibility probes (canOpenURL hop; address-book handle check)

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | An app registering the whatsapp scheme answers canOpenURL | Bounded by iOS declare-scheme mechanics; mechanism pre-exists (row pill probe :1171-1174) and is unchanged; worst case is an announced attempt + hop | PASS (R-6) |
| Tampering | Stale or negatively cached probe result | A negative probe routes to the next feasible channel (never blocks a call); a stale positive yields attempt + disclosed hop; staleness accepted at requirements time | PASS (R-1) |
| Repudiation | n/a — no security decision rests on the probe | — | PASS |
| Information disclosure | Probe leaking device state | On-device query only; declared schemes (:59, :94) bound what is askable; handle check reads the local address-book store; no egress | PASS |
| Denial of service | Probe false dead-ending the chain | .phone floor is structural; no new timers, queues or locks; the canOpenURLOnMain hop is reused | PASS |
| Elevation of privilege | Probe ordering attempts | Probe only orders attempts; no privileged action reachable | PASS |

### S3 — Chain resolution (CallChannelChain, pure static)

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | A forged Feasibility closure | Openers re-guard at execution time (digits, handle, URL), so a forged claim can only cause an announced attempt + hop, never execution on a truly infeasible channel | PASS |
| Tampering | Configuration or state removing the floor | Traced 64-cell argument: .phone always in attemptOrder; .phone/.faceTime always feasible; dedupe; route returns inside the feasible loop; vocabulary substitution terminals always feasible and permitted; no dead end for any pair including equals and both-infeasible | PASS (core focus-area-1 assurance; M-2 wording correction) |
| Repudiation | n/a | — | PASS |
| Information disclosure | Inputs are channel enums plus a handle-presence Boolean; outputs are enums only | No PII represented or emitted | PASS |
| Denial of service | Unbounded behaviour | Total function; loop-free; at most three candidates | PASS |
| Elevation of privilege | Privilege surface | None; the chain appears in no emergency path | PASS |

### S4 — Announcement and confirmation copy

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | An announcement naming a channel that is not what executes | Copy composes at one site from fellBackFrom.first plus the routed channel the executor switches on; label() maps the same value 1:1 | PASS with M-1 (the known pre-existing counterexample site; disposition must be pinned before that row is implemented) |
| Tampering | Edited catalog text changing behaviour | Text is speech-only; routing is independent of strings; ne/en parity enforced | PASS |
| Repudiation | A silent route change | Every fallback announced before execution (FR-CDP-016); the prompt names the routed channel (FR-CDP-013); empty fellBackFrom keeps the shipped prompt (pinned test) | PASS with M-1 |
| Information disclosure | Spoken copy leaking into logs | Announcements never routed through logging (design; FR-CDP-015 rule); contact name is speech-only | PASS |
| Denial of service | Longer prompt breaking the confirmation window | At most one clause added inside the unchanged 45-second window (:135) | PASS |
| Elevation of privilege | n/a | — | PASS |

### S5 — Launch-fail hop

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | Hop line claiming a channel it does not attempt | Single hop-line site names the next candidate from the same list the dispatcher consumes | PASS |
| Tampering | Stale candidates or infinite hop | Candidates computed at resolution; dispatch filters messenger-no-handle at consumption; strictly shrinking suffix gives depth at most 2; no re-prompt and no re-pending; only the executed method is taught | PASS |
| Repudiation | Silent exhaustion | The opening failure line is spoken before the hop decision; exhaustion speaks only the already-spoken shipped line — never silent | PASS |
| Information disclosure | Hop line content | Channel names plus contact name, speech only; events carry raw-value tokens | PASS |
| Denial of service | Recursion or repetition | Bounded recursion; finite candidates; single execution per request | PASS |
| Elevation of privilege | Hop targets | Ordinary channel set only; cannot touch escalation | PASS |

### S6 — Observability (events, outcomes, metadata)

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | Outcome tokens claiming what executed | Tap outcomes now record the routed channel with a direct/fellBack suffix (an improvement over the legacy preferred-app claim); captures record the executed method | PASS |
| Tampering | Free text injected into events | Closed vocabularies only (raw values plus fixed suffix strings) | PASS |
| Repudiation | Missing post-hoc evidence | Per-execution emit unchanged in shape (:7834-7841) | PASS |
| Information disclosure | Numbers/handles/names in event fields | metadata [:] (C9, :7840); no number, handle or name in any new field; LogSanitiser.allowedKeys unchanged | PASS (SA-6) |
| Denial of service | Event volume | One additional event per hop | PASS |
| Elevation of privilege | n/a | — | PASS |

### S7 — Localisation strings (five new ne/en keys)

| Threat | Scenario | Control (verified) | Verdict |
|---|---|---|---|
| Spoofing | Copy misdescribing the mechanism | Parameter contracts bind channel labels to app.name.* and routed-channel values; copy cannot alter routing | PASS |
| Tampering | Catalog edits | Static text; L10nCatalogCoverageTests enforces parity | PASS |
| Repudiation | n/a | — | PASS |
| Information disclosure | Placeholders | Filled at speech time only; never logged | PASS |
| Denial of service | Missing key degrading one line | Coverage test prevents; routing unaffected | PASS |
| Elevation of privilege | n/a | — | PASS |

## BLOCKER-class findings

None. No finding breaks a security focus area or a constitution constraint as designed: the floor, dedupe and at-most-once, override and emergency preservation, local-only probes, log safety and the five-key bound all hold as written. M-1 and M-2 are corrections required downstream; failing to apply M-1 before the affected row is implemented becomes a release-blocking condition at implement/security-test time (see conditions).

## Conditions carried to plan-tasks / implement

M-1 (must-fix; carried from review-l2 F-1, security-framed — announcement honesty, focus area 4). Before the .whatsappChat row is implemented: (a) correct design-l2.md:799 to state openWhatsAppChat's real signature (returns Bool; false only when whatsAppChatURL is nil — CallLinks.swift:283-287, :366-370) and correct :609 to attribute needsNativeCompose/copiedNumber to openWhatsAppCallChat only (:457-470); (b) record the explicit disposition, one of: (i, recommended) the voice .whatsappChat branch speaks the shipped honest line (call.announce.noPhoneNumber) when the Bool is false and records no success, no learning and no activity, matching the new .phone guard; or (ii) document a shipped-identical exception in design-l2 section 22 with the reachability analysis (new settings configurations and hop targets route more voice calls into this branch). Either disposition is acceptable for SECURITY-GO; silence is not.

M-2 (must-fix; new — attempt-order wording and test contract). design-l1.md:147 and the attemptOrder comment in design-l2 section 6 say 'always ends .phone'; that is literally false when preferred == .phone and secondary differs (the order is [.phone, secondary]). The invariant that actually holds and is load-bearing is containment: .phone is always IN the order, and route therefore never dead-ends. At plan-tasks/implement: correct both wordings to the containment form; write the planned order test (testAssessmentOrderAlwaysEndsPhone, design-l2.md:1171; see V-6) to assert containment plus isFeasible(routed) plus preferred-first — NEVER last-element; and do not reorder attemptOrder to satisfy the old wording — attempting the secondary before the preferred channel would be a behaviour and safety deviation from FR-CDP-007.

Carried without change: review-l2's requirement that F-1 be applied before the affected row is implemented, and its F-2..F-7 required actions, tracked below as V-1..V-6.

## Verify-and-record items

V-1: F-2 — .facebook in the vocabulary case table (design-l2.md:903) is not a CallApp case; replace with .faceTime.

V-2: F-3 — 'five shipped labelled constructions' (design-l2.md:1106) versus four verified PendingCallAction constructions (:7624, :7670; IntentLogStoreTests.swift:206, :224; re-grepped this session); state four (or explicitly 'five-argument').

V-3: F-4 — the replacing() comment (design-l2.md:497-500) claims provenance carries over while fellBackFrom resets to [] by design; reword so the comment matches the deliberate reset.

V-4: F-5 — NFR-CDP-006 (MUST): specify the non-visual selected signal (selected trait or value) for both picker sections and a heading trait (or soften the claim); add the picker-suite assertion (design-l2.md:975, :1174). Verified source reality: selection is checkmark plus stroke overlay only (CallingSettingsView.swift:40-64).

V-5: F-6 — design-l2 section 25 readers/writers: add isAwaitingCallConfirmation (:7553, consumer :10717-10723) to readers and list recordConfirmationTimeout (:10561-10569) as a reader; note the call block nils the slot (:10611-10612) — this matters because removing the early return changes when the slot can be live.

V-6: F-7 — rename testAssessmentOrderAlwaysEndsPhone (design-l2.md:1171) so the name matches the property; the rename rides M-2's containment form.

## Evidence obligations for security-test

SA-1 (focus 1) Chain matrix: exhaustive (preferred, secondary) x (messenger-handle present/absent, whatsApp probe true/false) = 64 cells; per cell assert isFeasible(routed) under the injected closure, .phone in the order, no duplicates, preferred-first, routed vocabulary legality, messenger-without-handle never routed; separately, floor reachability with every other channel infeasible (probe false, no handle) for anyChannel/audio (routed .phone) and video (documented .faceTime terminal per FR-CDP-010).

SA-2 At-most-once and termination: exactly one prompt per request; the hop executes without re-asking; a forced-failure recursion terminates (depth at most 2) with the selection never re-pending; exactly one committed attempt per request.

SA-3 GSM floor per surface: voice anyChannel; voice video-word (video floor == .faceTime); address-book circle rows; family audio tile; family video tile; missed-call dial-back — for each, with preferred infeasible, routed equals the surface floor and the announcement names it.

SA-4 (focus 2) Emergency and override preservation: (a) the change set contains no emergency file; the emergency trigger (RedesignComponents.swift:229-237) is byte-unchanged; (b) override block AppCoordinator.swift:7656-7686 — gate :7665-7669 diff-clean, amended action :7670-7674 still constructs; (c) grep of the whole change set shows zero emergencyNotify / NotifyChannel / preferredEmergencyContact additions; (d) the dial-back call chain contains no escalation-delaying awaits; (e) VoiceSessionStateMachine.confirmationTimeoutSeconds untouched (:135).

SA-5 (focus 4) Announcement honesty: composed prompt/announcement for all matrix cells names the routed channel (and skipped channels in attempt order); one hop line per hop, spoken before the opener's outcome line; fellBackFrom == [] keeps the shipped prompt byte-identical (pinned test); the M-1 disposition's chosen variant is exercised (honest false-case line, or the documented shipped-identical exception with its reachability analysis); the new .phone false-case guard speaks call.announce.noPhoneNumber and records nothing.

SA-6 (focus 5) Log safety: check-release-log-safety.sh exits 0 with Services/Calls present in FEATURE_ROOTS (python :141+ — verify the exact added string matches the directory prefix so role-match :821-834 grades the new file feature-role); source audit of the coordinator-side hunks (AppCoordinator.swift, LeafViews.swift, CallingSettingsView.swift, MethodResolver.swift — rules 1-2 only): no new console writes, metadata [:] or closed-vocabulary tokens only, no phone number, handle or contact name reaching any log call, LogSanitiser.allowedKeys (:56) unchanged, build.sh:431-434 intact.

SA-7 (focus 3) No new surface: Info.plist byte-diff empty (no new scheme or permission); no new network symbol in the change set; secondaryCallApp is the only new store key and stores a channel raw value (non-PII); no per-contact primary/secondary storage (FR-CDP-018).

SA-8 Localisation: exactly five new keys, ne/en parity, no user-visible literals in code, coverage test green.

SA-9 Settings persistence: round-trip; absent/garbage decodes to .phone; equal picks legal and deduped.

## Accepted residuals (explicit)

R-1 Probe staleness (canOpenURL caching) — accepted at requirements time (specs/define-requirements/index.md assumptions); bounded by the hop plus honest failure lines.

R-2 The hop may best-effort attempt WhatsApp even when the probe said not installed — disclosed by the hop line; tap-context attempts land on the shipped honest recoveries; voice-context attempts land on the M-1 disposition.

R-3 performSystemContactWhatsApp treats .invalidPhone as terminal (no hop even when a messenger-handle candidate exists) — conservative and never silent; consistent with FR-CDP-015's recoveries-as-terminal rule.

R-4 Family tiles always pass a non-nil per-contact app as preferred, so the settings primary does not enter those tiles' step-1 when a pick exists — intended (FR-CDP-009 explicit-pick-wins; frozen design); recorded so it is not misfiled as a defect.

R-5 The pre-existing voice .whatsappChat false-claim site (AppCoordinator.swift:7755-7765) remains until M-1's disposition is applied; the feature increases its reachability but does not create the class.

R-6 canOpenURL scheme-registration spoofing is bounded by iOS declare-scheme mechanics and pre-exists the feature (the row pill probe ships today); the mechanism is unchanged.

R-7 Non-load-bearing document imprecisions beyond M-2 (F-2, F-3, F-4, F-7-class) — display-level corrections tracked as V-items; none carries a guarantee.

## Decision

decision: "SECURITY-GO"

0 BLOCKERs. The design satisfies all five workflow security focus areas as written; the two must-fix conditions (M-1, M-2) are required downstream corrections to be applied at plan-tasks/implement time and evidenced at security-test — M-1 before the .whatsappChat row is implemented, M-2 before the order test is written. No design re-cycle is required; no frozen owner decision is re-opened.
