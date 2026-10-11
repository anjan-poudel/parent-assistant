# Security Test — call-dialer-primary-secondary

- Task: security-test (ai-sdd workflow call-dialer-primary-secondary); contract: security test of the delivered feature; it discharges the obligations contract at specs/security-design-review.md.
- Workflow exit condition for this task: review.decision == "SECURITY-GO" (specs/call-dialer-primary-secondary/workflow.yaml:165-176; focus comment :168-174, exit condition :175-176).
- Agent: sdd-reviewer (Reviewer). Feature: call-dialer-primary-secondary.
- Worktree: /Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary (read-only). Branch: feat/call-dialer-primary-secondary. Reviewed HEAD: e9b74b76 (the review-GO commit; the production bytes equal the W10 closure for every production file — the W10 commit is tests-only).
- Disposition: read-only security pass over delivered bytes plus executed evidence. No git state was touched, no ai-sdd CLI was invoked, the main checkout was not touched, and the only file written is this report.
- Supersession note: this path previously held the security-test record of the multi-turn-conversation feature (154 lines, sha256 2b155d0a 22eae387 c3c4a87e 24a2a7e9 c34a19d3 3c5fbb9f 998efc6b fda7f547; its own References name worktree elderly-ai-assistant-multi-turn-conversation and HEAD a55e22c). This record fully replaces it for call-dialer-primary-secondary; nothing of the older record is claimed as this feature's evidence.
- Change-set basis: git diff 8089c735..e9b74b76 = 15 iOS files (+5572/-203) plus the feature's spec and evidence files; merge-base 8089c735 c679ecb7 0bd5ca0f 04989271 a082a2f0. Production deliveries: AppCoordinator.swift, CallingSettingsView.swift, LeafViews.swift, Localizable.xcstrings, CallChannelChain.swift (new), MethodResolver.swift, project.pbxproj, check-release-log-safety.py; tests: seven files.

## Artifacts under test (delivered bytes; every hash recomputed this session)

| Artifact (worktree-relative) | Role | Size | sha256 (grouped 8x8) |
|---|---|---|---|
| ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift | production (new file) | 212 | fbcc03ef 69c4df94 12283a8f 069ac1f1 f2e0f1fb 100b7fd6 d953da1e e540b35c |
| ios/ElderlyAssistant/App/AppCoordinator.swift | production | 12256 | e19a3740 02cb489b 530862ae fe465111 69963772 7a08c5d2 dce553c1 9d113881 |
| ios/ElderlyAssistant/App/LeafViews.swift | production | 3036 | 371eb89f e9cfb999 22a71268 47e5523e dd8c7f06 ae3f55a1 e5317e2b 34f23d38 |
| ios/ElderlyAssistant/App/CallingSettingsView.swift | production | 116 | 22d05fda 827fc243 5b846b36 eec2cd66 b836d276 161cae21 29e453ee 308d3a0c |
| ios/ElderlyAssistant/Services/Intents/MethodResolver.swift | production | 132 | ce9fe8fe 0e58e927 895931df fe010c3a b2e4c48d 761bb61d ac5b2b1a b4aa94fd |
| ios/ElderlyAssistant/Services/Intents/CallLinks.swift | preserved baseline (zero diff) | 471 | ceb3e493 1c5bd703 5b3b5ce5 4ea28077 bef6221b 3fc820df d8b3caf2 02a73832 |
| ios/ElderlyAssistant/Resources/Localizable.xcstrings | resources | 23660 | f8b08d10 87241392 fb121d66 8c9af905 7cc45252 fd012a24 e8fab3f1 bef7d5e7 |
| ios/seniOS.xcodeproj/project.pbxproj | Xcode registration (+20/-0, mechanical) | 4545 | a28853d5 d1aef10b 99ba20b0 3a4dab5b 7bb5db7e 54dbdd43 51080ba6 513490ef |
| ios/tools/check-release-log-safety.py | release gate | 890 | 31cf7e8f 83b9111a 74310846 d31e0959 08c69bf3 cb60ce84 85ed89b1 861df6ff |
| ios/ElderlyAssistantTests/Services/Voice/CallChannelResolutionTests.swift | tests | 2353 | c8ed4c12 f7979485 1b77d4c7 af50aa25 51db82b7 03130ebf 25710666 c33b786d |
| ios/ElderlyAssistantTests/App/MissedCallDialBackTests.swift | tests | 728 | 9b0a03d7 dffce4fa ef1b09c4 5fce1d3d 64737dfe 254508ae f714c31d 8bbe3567 |
| ios/ElderlyAssistantTests/App/ContactCallButtonsTests.swift | tests | 779 | 86cde063 2483b49e 304bcebf d2204f97 e67cbfd0 2d9210df 93518f25 04be840a |
| ios/ElderlyAssistantTests/App/CallConfirmationWordingTests.swift | tests | 402 | 46c018dc f558c1e1 9d6b87ab 6860e0bd 81c4a911 e6cbc323 86e2250e 9577ea96 |
| ios/ElderlyAssistantTests/App/CallingSettingsSurfaceTests.swift | tests | 330 | f04b7d7e 8a9c4fb7 b8706671 e9fa5199 be3106f1 0a4e615c 70ef3065 94b524a3 |
| ios/ElderlyAssistantTests/Localization/L10nCatalogCoverageTests.swift | tests | 862 | a5514998 ba475cc4 11dbc3cc d5540a5c 84b4ddd6 d9bc703c 72bd12f0 c4eeac89 |
| ios/ElderlyAssistantTests/Services/Intents/MethodResolverTests.swift | tests | 206 | 4a69a377 5e587f03 457f47cb 4d0dc9a5 11f4d8b1 ab40dfae 5c780385 846af394 |
| ios/build/t157-final-sweep.log | executed evidence (sweep of record) | 109 | 709a3527 8151af73 36dd468d b539ca96 5acbd3dd 0db9bd28 591ca745 66e556a7 |
| ios/build/t157-privacy-guard.log | executed evidence (W10 guard run) | 29 | 91ab5103 9f949d03 ac7f4653 ca89fec4 abffc65d d26cbeac 603fee6c 6990657d |

Delivered-hash cross-check: all fifteen delivered values above equal the matching rows in specs/review-implementation.md's table (recomputed here, not read from it). The preservation files VoiceSessionStateMachine.swift, RedesignComponents.swift and Info.plist carry zero diff against the merge-base, so their bytes are the shipped baseline; CallLinks.swift likewise carries zero diff (listed for the normalization evidence).

## Inputs consumed

| Input (worktree-relative) | Role | Size | sha256 (grouped 8x8) |
|---|---|---|---|
| specs/security-design-review.md | obligations contract (SA-1..SA-9, M-1/M-2, R-1..R-7) | 217 | 6f8723d2 a6086e19 ac67331b 9a1be27e af5a8123 7d705512 32d4976b 35acdbce |
| specs/review-implementation.md | implement-phase GO; F-1..F-6 | 139 | adc76d26 0e1181b8 fde23a29 5a9914c2 cf5c2b90 d0cbccad 645d9190 f96b2a44 |
| specs/T-157-notes.md | release-evidence pack (sweep of record, controls, audits) | 555 | 66f48535 2e54d47d ebaf5e3e b8da79eb d9a0c32a e188fdb8 f232aa16 58b3c8dc |
| constitution.md | project Standards | 159 | 7feae062 30b7e58e a2256a4e 332d0b80 7029642c e7a0646f 6ac3ddcd 460c9ef8 |
| specs/call-dialer-primary-secondary/constitution.md | feature constraints 1-12 | 101 | e5f816c3 a9d56743 26136204 ca657fe7 a739e8f6 671f9dfd d838e243 3a1f43e5 |
| specs/call-dialer-primary-secondary/workflow.yaml | task scope and exit condition | 190 | c0ec077b b738e6ad b55eafba 7c30cb97 46fffc78 fabf702f b80df79e 4f8f4ec5 |
| specs/security-test.md (superseded baseline) | prior feature record | 154 | 2b155d0a 22eae387 c3c4a87e 24a2a7e9 c34a19d3 3c5fbb9f 998efc6b fda7f547 |

## Verification method

a) Source re-derivation, not trust in prose. CallChannelChain.swift was read line-level; the chain algebra (attemptOrder containment, unconditional feasibility of .phone and .faceTime, route returning from inside the feasible loop) was re-derived by hand across all 16 ordered pick pairs times 4 feasibility states. The AppCoordinator seams were re-read at the delivered anchors: resolvedCallChannel :2128-2140, resolveChannel :2152-2167, requestCallConfirmation :7707-7774, the override region :7783-7813, confirmationPrompt :7821-7850, performCallAction :7861-7965, the hop machinery :7989-8088, the tap path :8125-8245, the system openers :8265-8461, noteSearchChannelTap :8466-8475, missedCallDialAction :8835-8878, dialBackMissedCall :8899-8946, announceNoUsableNumber :8956-8960, and the LeafViews dial/tile seams :1166-1177 and :1583-1671.

b) Test evidence re-read in source: the 64-cell matrix, the 320-cell seam sweep, dedupe pins, hop-consumption structural sweep, the false-line guards, the override pin, the dial-back source pins and the empty-input pins were read as written code, then matched against the sweep of record.

c) Executed evidence verified this session. ios/build/t157-final-sweep.log was spot-parsed: "Executed 136 tests, with 0 failures" and "** TEST SUCCEEDED **" (:93-103). The log-safety guard was re-run by this pass, read-only, exactly as the build script invokes it: tools/check-release-log-safety.sh from the ios directory returned exit 0, printed "log-safety fixtures: 24 case(s) over 12 rule(s)", and every positive and negative fixture behaved.

d) Diff scans over added lines (iOS scope): network symbols, console writes, emergency identifiers, secret patterns, scheme literals, canOpenURL sites, UIApplication.shared.open sites.

e) Catalogue re-parse: 1394 keys; the five feature keys present with en and ne content; catalogue diff +85/-0.

f) Diff-cleanliness by hunk-range analysis for the override region: the written hunks jump from one ending at :7750 to one starting at :7815, so no hunk covers :7783-7813.

g) Preservation files: CallLinks.swift, VoiceSessionStateMachine.swift, RedesignComponents.swift and Info.plist carry zero diff against the merge-base.

What this pass did NOT execute, stated plainly: there was no rebuild and no unit-suite re-execution (the sweep of record is the executed test evidence; it was spot-parsed, not re-run) — the one gate re-run here was the log-safety guard; there was no simulator or device run; no penetration-test infrastructure exists for a local, serverless iOS app whose change set adds no network surface, so this is by design a static plus executed-evidence pass. The device-level half of the feature rides the DV-1..7 checklist (owner's device run on Anzaan), which is downstream of this gate.

## Focus-area verdicts (the workflow-declared scope)

### Focus 1 — the chain never dead-ends for any pick pair, equal values, uninstalled apps ... PASS

attemptOrder starts with the preferred pick, appends the secondary only when different (dedupe) and appends .phone whenever absent; isFeasible returns true unconditionally for .phone and .faceTime, so the floor candidate is always attemptable and route always returns a feasible channel (the return sits inside the feasible loop; the trailing .phone return is unreachable without changing totality). Environment facts enter as two local booleans on a Feasibility value; no platform call, timer, or store is reachable from the file. Equal picks collapse to one slot with one provenance entry. A false probe (WhatsApp uninstalled) is skipped, never dead-ended. Evidence: the 64-cell matrix test asserts per cell that the routed channel is feasible, .phone stays contained, no duplicate appears, the vocabulary is legal, provenance equals the skipped prefix, and the cell count is exactly 64; the 320-cell seam sweep re-asserts containment through the public seam; the dedupe pins cover equal and unequal pairs; the stubbed-absent-WhatsApp pin routes around the missing app and asserts the probe received exactly CallChannelChain.whatsAppProbeURL.

### Focus 2 — the GSM floor is reachable with every other channel infeasible ... PASS

For any pick pair with both messengers infeasible, route lands on .phone (the matrix's infeasible rows all route the floor); the row-state floor invariant test re-asserts across all 64 states that either the routed channel is .phone or the floor is among the hop candidates — so even the video terminal keeps the floor one hop away. The dial-back floor route test drives missedCallDialAction with messenger preferred (no handle) and WhatsApp secondary (probe false) and asserts the full route value: call to phone with fellBackFrom [messenger, whatsApp] and empty hopCandidates. Vocabulary terminals (audio and anyChannel to .phone; video to .faceTime) are always feasible and permitted, asserted per environment combination, including the substitution case that cannot dead-end the route.

### Focus 3 — the confirmation wording always names the routed channel ... PASS

The prompt composes the disclosure from the action's own snapshot: the skipped label comes from action.fellBackFrom.first and the routed channel label derives from action.method through CallChannelChain.channel(for:) at AppCoordinator.swift:7830-7836, where action.method was built at :7746-7747 from the same route value; the method-to-channel round trip is identity for all four channels (round-trip test). The question sentence names the routed method key. The wording test drives the real catalogue in both languages for floor and chat routes and asserts the disclosure names skipped and routed channels; the no-fallback byte-identity pin keeps the original prompt unchanged when nothing was skipped. Tap and dial-back announcements use route.channel from the same resolution; the hop line names step.next at the single site (launchFailHopStep :8014-8019) and dispatches the same step.next in the same call. One hop line per hop, with the payload closed (launch-fallback behavioural pin: exactly one line, outcome=faceTime:phone, metadata=[:]).

### Focus 4 — emergency and dial-back escalation are unaffected ... PASS

(a) RedesignComponents.swift is not in the change set (file-level zero diff), so the emergency trigger region is byte-unchanged. (b) The override block was located by content at AppCoordinator.swift:7783-7813 (gate :7792-7796, amended construction :7797-7801) and sits inside a diff-clean gap per the hunk-range analysis; the override pin asserts the gate, the amended construction (provenance dropped), the corrected-capture append and the single re-confirmation, and asserts fellBackFrom, hopCandidates and requestedAt never enter the region. (c) Zero added lines match emergencyNotify, NotifyChannel, preferredEmergencyContact or EmergencyChannel (added-line scan, zero matches). (d) The dial-back region and the hop path were re-read at delivered lines (missedCallDialAction :8835-8878, dialBackMissedCall :8899-8946, launchFailHopStep :8005-8021, performLaunchFailHop :8031-8057, hopFromCallAction :8078-8088): no await, sleep, Timer, retry or asyncAfter token appears; the in-test token scan over those regions asserts zero for each. The only concurrency shape reachable from the dial-back dispatch is the shipped one-way DispatchQueue.main.async handoff inside performSystemContactCall (:8273, pre-existing, and it is the dial itself rather than a delay). (e) VoiceSessionStateMachine.swift carries zero diff and the 45-second window constant is untouched.

The T-153 whitespace-handle divergence (review-implementation F-4), read against L2-D9 as the workflow requires: missedCallDialAction keeps the RAW derivation messengerHandle?.isEmpty == false at :8863 with the in-body comment; for a whitespace-only handle the route can resolve .messenger, and the consequent open is refused before any URL, probe or platform call — CallLinks.messengerHandle (:234-243) trims and rejects anything outside the hand-listed ASCII-plus-dot alphabet, and messengerThreadURL and messengerWebURL (:317-331) return nil for an empty normalized handle, so openMessengerThread returns .invalidHandle at :400-403 before its canOpenURL. The shipped honest line speaks, nothing records, and the hop then dials the floor with the row's own number. No injection and no egress path opens through the divergence; both derivation sides are pinned, and the companion negative control demonstrates the pins discriminate. Verdict: design-sanctioned, security-neutral.

### Focus 5 — number and handle PII never reaches logs ... PASS

The two write sites on the new paths were read: the hop event (noteLaunchFailHop :8062-8071) emits outcome with the two closed rawValue tokens and metadata [:]; the extended tap outcome (:8136-8144) emits the media word, the routed channel rawValue, and a direct or fellBack token, with metadata [:] and the C9 policy comment. An added-line scan across the whole iOS diff finds exactly those emit statements on the feature paths and zero added lines interpolating number, handle or contact name into any emit context; no added line anywhere contains print, debugPrint, NSLog, os_log or fputs (the single pattern hit is the guard's own detector regex added to check-release-log-safety.py). check-release-log-safety.py registers the calls directory at :197 inside FEATURE_ROOTS, and the role logic (:831-845) grades every Swift file under it as feature-role, receiving the full rule set including the no-console-write, content-field and unlisted-metadata-key rules; the coordinator-side files stay other-role (Release console and transcript rules). The guard was re-run by this pass: exit 0, 24 fixtures over 12 rules, all behaved. The sweep of record green plus the behavioural tile tests (exact event payloads through console capture, for example outcome=audio:phone:fellBack metadata=[:]) are the executed evidence.

### Focus 6 — no new egress from the feasibility probes ... PASS

The only URL literal on added production lines is the static whatsAppProbeURL built from the compile-time string whatsapp:// (CallChannelChain :910-916). Both probe surfaces delegate to CallChannelChain.whatsAppInstalled(canOpen:) — the coordinator's whatsAppInstalledNow (:7397-7399) over the pre-existing main-thread canOpenURL hop (:7384-7387), and the LeafViews row hint (:1175-1177) over UIApplication.shared.canOpenURL, the same mechanism the shipped row pill already used. canOpenURL is an OS installed-app query; no network symbol appears on added production lines (URLSession, URLRequest, Network and URLConnection scans all zero). The single added https occurrence in the whole diff is a test-side pin needle string at CallChannelResolutionTests.swift:2106, a literal that pins the shipped openMessengerChat web-fallback line — no production URL construction is added. Info.plist carries zero diff (no new scheme, no new permission; the whatsapp scheme was already declared); no entitlement or plist file appears in the change set. The pre-existing shipped openers keep their own universal-link behaviour and their bytes are unchanged (CallLinks zero diff).

## SA-1 .. SA-9 obligation discharge

| SA | Obligation (from the design review) | Evidence checked (delivered bytes plus executed evidence) | Verdict |
|---|---|---|---|
| SA-1 | Exhaustive never-dead-ends matrix (64 cells) and floor reachability | Chain algebra re-derived from CallChannelChain.swift; the 64-cell matrix test, the 320-cell seam sweep, dedupe pins, stubbed-absent probe pin, the 64-cell row floor invariant; the dial-back floor route | PASS |
| SA-2 | At-most-once and termination | Hop statics re-read (strict suffix, terminal append); the hop-consumption test (worked example plus 64-cell structural sweep: strict shrink, no repeats, at most two consumption steps, only an un-attemptable messenger can remain); the no-re-entry and no-await pin (the hop re-enters the executor only, confirmation symbols zero, sync tokens zero); one-hop-line behavioural pin | PASS |
| SA-3 | GSM floor per surface | Seam substitution tests (audio and anyChannel terminal .phone, video terminal .faceTime); tile tests (video and audio vocabulary exclusion, fallback to the floor with provenance); the row floor invariant; dial-back tests (unmatched number dials the floor, FaceTime preference keeps the audio floor route, both-infeasible reaches the floor with full provenance) | PASS |
| SA-4 | Emergency and override preservation | Zero emergency-identifier additions (added-line scan zero); RedesignComponents.swift zero diff; the override block diff-clean by hunk analysis plus the override pin; the dial-back and hop regions sync-only (token scan and re-read); VoiceSessionStateMachine.swift zero diff with the window constant intact | PASS |
| SA-5 | Announcement honesty including the M-1 disposition (i) | Disclosure composed from one snapshot with round-trip identity test; wording tests in both languages; no-fallback byte identity; the hop line single site with the sole-node behavioural pin; the phone and whatsappChat false-case guards speak the shipped line through the recordless helper, with each guard the first statement of its case and every success statement after the return (two source pins); announce-before-open pinned for tap and dial-back | PASS |
| SA-6 | Log safety | The registered FEATURE_ROOTS row (the calls directory at :197) plus role gating (:831-845); emit-site reads (closed tokens, empty metadata); zero added console-write lines; the guard re-run by this pass: exit 0, 24 fixtures over 12 rules, all behaved; the sanitiser file not in the change set | PASS |
| SA-7 | No new surface | The single added URL literal is the probe; zero added network symbols; Info.plist zero diff; project.pbxproj is mechanical file registration only (+20/-0); secondaryCallApp is the only new store key (a raw enum value, non-PII; persistence :346-352, init restore :2924-2926); no per-contact storage added; no new text-intake surface | PASS |
| SA-8 | Localisation | Catalogue parsed independently: 1394 keys; the five feature keys present with en and ne; diff +85/-0; the coverage suite green in the sweep; new speech paths compose through L10n keys (source reads) | PASS |
| SA-9 | Settings persistence | secondaryCallApp persistence via the setter; init restore maps an unknown raw value to .phone; settings tests: absent and garbage both restore .phone, the round trip survives coordinator recreation, two sections are independent, and an equal pair is legal at storage (dedupe is the chain's job) | PASS |

## Standard security categories (template adapted to this app)

| Category | Adapted scope here | Evidence checked | Verdict |
|---|---|---|---|
| Input validation before openers | Every opener must refuse an unusable input before any URL build, probe or platform call | The empty-input pin asserts exact collapsed bodies for the phone, FaceTime, messenger-thread, messenger-chat and WhatsApp-call openers plus the dialer URL builder (guards precede probes); CallLinks normalization re-read (:234-243, whitespace trim, single leading at-sign, hand-listed alphabet); the dial-back shipped guards wrap the empty route | SECURITY-GO |
| Error leakage | Failures surface only as shipped spoken lines; no internals | Failure branches speak shipped catalogue lines (FaceTime unavailable, no phone number, messenger no handle, WhatsApp invalid phone); failures record no learning, no activity and no history (pinned per arm and behaviourally per tile); the emit vocabulary is closed with empty metadata | SECURITY-GO |
| Audit-log completeness | Every routing decision with a security-relevant effect leaves bounded evidence | Hop event per hop (closed tokens, empty metadata); the tap outcome extended with routed channel and provenance token; failed attempts keep their shipped events; the dial-back deliberately adds no event (speech-only region pinned to zero observability writes) | SECURITY-GO |
| Secrets in output | No key material or credential may appear in the change set | Added-line scan over the iOS diff and the feature's spec files for key, secret, token, password and private-key patterns: zero matches; the feature touches no credential store; pre-existing client identifiers live in files that are not in the change set | SECURITY-GO |
| SQL injection | Not applicable | The app has no SQL surface on this path: settings live in UserDefaults, handles in an encrypted key-value store, and no query is constructed anywhere in the feature or its seams | N/A (explicitly: no SQL surface exists) |
| Authorization and authentication | Not applicable | The feature adds no auth surface: no accounts, roles, sessions or permissions; a single-user on-device app; Info.plist permissions unchanged; the only new persistence is a non-PII channel preference | N/A (explicitly: no auth surface exists) |
| STRIDE surfaces S1-S7 (design-review model) | Implementation-level re-check of each control | Chain floor, dedupe and totality re-derived (spoofing and tampering); probes local-only (info disclosure); single-snapshot announcement (repudiation); bounded shrinking hop (denial of service); closed observability vocabulary (info disclosure); decode-safe settings (elevation of privilege); five-key bound (surface) | SECURITY-GO |

## Constitution review checklist (additional criteria)

| Checklist item | Evidence | Verdict |
|---|---|---|
| Every interface method has an explicit return type, not an untyped error | route returns a typed Result; hop statics return an array or an optional of the channel enum; openers return Bool or typed outcome enums; no any or unknown channel added | PASS |
| Every external call has a documented failure mode and recovery path | Every opener outcome maps to a designed handling class: hop with announcement, terminal honest line, or recovery line; exhaustion is a defined, pinned state | PASS |
| Timeouts and retry limits are configurable, not hardcoded constants | No new timeout, timer, retry, queue or actor token appears; the confirmation window stays the shipped constant; sync-only paths pinned | PASS |
| Every element traces to an FR or NFR | The workflow scope comment, feature constraints 1-12 and the design review's five focus areas cover every touched seam; the traceability statement (no router service, no per-contact storage) re-read | PASS |
| The design describes what the operator sees on success and on failure | Every routing outcome has a spoken line: disclosure clause, tap announcement before the open, one hop line per hop, honest terminal lines; the DV-1..7 checklist is the device half | PASS |

## Review-implementation residues (F-1 .. F-6) and their security bearing

- F-1 (documentation wording versus the frozen listing): the T-152 definition-of-done wording differs from the frozen section 9.2 listing while the delivered emit is listing-verbatim and the arbitration definition was met as shipped. Security bearing: none — record and evidence only; the emit vocabulary stays closed with empty metadata and no new sink.
- F-2 (combined negative control, assertion order): two pins share one behavioural control, so their individual red demonstrations were not each observed. Security bearing: none — no verdict-weight claim rests on them; the affected forms were re-read in delivered source and are green in the sweep; the limitation is discriminating-evidence granularity only.
- F-3 (unit-test coverage ceiling on the WhatsApp lane): no security bearing; the DV device run exercises the real-probe paths.
- F-4 (whitespace-handle divergence): read against the design-sanctioned semantics above; no injection or egress path opens; security-neutral.
- F-5 and F-6 (housekeeping and a pre-existing baseline red outside the scoped suites): no security bearing.

## Residual risks and honest limits

- R-1 (probe staleness, accepted at requirements): carried. The mechanism was re-verified — one probe over the compile-time literal, no caching — and staleness is bounded by the hop plus the honest lines; the worst case is one announced attempt and a hop, never a hang or a silent failure.
- R-6 (scheme-registration spoofing, accepted): carried. The mechanism pre-exists (the shipped pill probe) and is unchanged; worst case is an announced attempt that fails, followed by the hop.
- R-2, R-3, R-4, R-5 and R-7 (design-review residuals): carried; nothing found in the implementation-level re-check changes their status.
- Evidence-precision note 1: the T-157 pack's "zero https additions" phrasing is loose at the letter — one added line across the whole diff contains an https literal, the test-side pin needle string named in Focus 6; production adds none, so the security property holds while the evidence sentence is corrected here.
- Evidence-precision note 2: the guard is a source-level check and its own documented limitations stand; it is re-run evidence for the changed surface, not a runtime guarantee.
- Honest limit: this pass is static plus executed-evidence verification. The device-level half (real probes, spoken lines, emergency behaviour on hardware) rides DV-1..7 on the owner's device and remains outstanding by design.
- Confidence: high on the delivered-bytes verdicts (all hashes recomputed, all pins re-read, guard re-run exit 0); bounded by the absence of a device run and by the control-granularity note (F-2).

## Decision

Zero blockers. All nine obligations (SA-1 .. SA-9) are discharged on the delivered bytes with executed evidence; all six workflow focus areas PASS; every adapted category is SECURITY-GO or explicitly not applicable with a surface-absence justification; the emergency and override anchors hold; the log-safety guard re-run by this pass returned exit 0; and the PII, egress and confirmation-honesty properties were re-derived from source rather than trusted from prose.

decision: "SECURITY-GO"
