# Final Sign-Off — final-sign-off (phase: sign-off, risk tier T2)

- Task: `final-sign-off` (ai-sdd workflow `elderly-ai-assistant-sdd`, task library `final-sign-off.yaml`: T2, no HIL overlay in-task, human gate via risk tier)
- Report path: `specs/final-sign-off.md` (SDD project: `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`)
- Code repo reviewed: `/Users/anjan/workspace/projects/elderly-ai-assistant` — `master` at **`57abb2e`** (full SHA `57abb2ee…3660e70d`, recorded in `ios/build/.last-tested-sha`; verified with `git rev-parse HEAD`; `origin/master` contains it). Working tree dirty by exactly two uncommitted mirror files under `.ai-sdd/` — `.ai-sdd/outputs/security-test.md` and `.ai-sdd/state/workflow-state.json` — which are the freshly re-run security-test records (the repo mirror of `specs/security-test.md` is byte-identical to the SDD project copy; `diff` clean). No app code is uncommitted.
- This is a **re-run**: the previous `specs/final-sign-off.md` (40,327 bytes, still on disk) returned **NO_GO** with four explicit flip conditions. This report adjudicates the current state against each of those conditions (see Verdict); it does not restate or assume the prior verdict.
- Author: Reviewer agent. This is a decision pack for the human T2 gate. It does not itself grant sign-off; acceptance of any open finding (including the B3–B7 risk acceptance in Open Decision #11) is a human risk-acceptance decision.
- Sources read: `constitution.md` (SDD project and product repo, both copies and their diff), `requirements.md` (46 FR / 32 NFR — ID counts re-derived), `specs/security-test.md` (the re-run), `/tmp/security-test.previous-NO_GO.md` (previous report backup, cross-checked against the prior `final-sign-off.md`), `specs/review-implementation.md`, `specs/implement-notes.md`, `.ai-sdd/outputs/implement-notes.md` (T-042 record + the T-049/T-050 fix-pass record), `.ai-sdd/outputs/plan-tasks/plan.md` (risks, blockers, traceability table), T-049/T-050 task files, `.ai-sdd/outputs/security-design-review.md`, `.ai-sdd/workflows/default-sdd.yaml`, `.ai-sdd/state/workflow-state.json` (repo), `ios/build/.last-tested-sha`, the gate xcresult, app code at `57abb2e` (cited inline), `ios/tools/check-release-log-safety.{sh,py}`, `ios/build.sh`, `docs/OPEN-ITEMS.md`, the T-033 bake-off report on the `worktree-t033-encoder-bakeoff` branch.
- Verification performed (first-hand, this pass): revision/cleanliness/ancestry checks; read of every B1/B2 fix site, the `ErrorCodeMapper`, the `LogSanitiser` bound, the console sink, the guard implementation and its `build.sh` wiring; **executed** `./ios/tools/check-release-log-safety.sh` (exit 0); re-derived the recorded unit gate from `.last-tested-sha` and `xcrun xcresulttool` (summary + per-test extraction for the four security-relevant suites); spot-read of the load-bearing traceability citations at HEAD (default stack, biometric service, emergency handler, plugin sanitise path, keyword net callers, keychain class, absence greps for PIN/HealthKit/Signal/companion-target/Google Calendar); constitution diff; OD#11 text; plan traceability table; T-033 report scope check.
- Explicitly **not** run or verified this pass: the unit gate was **not re-run** (read-only review; evidence re-derived from the recorded xcresult and SHA file); **no Release build was compiled or executed**, no live-device console/sysdiagnose inspection, no network capture, no dynamic auth/emergency/STT testing; the security-test re-run was read, not repeated; dependency/CVE audit and vendored-code audit not performed; Android not re-exercised; rows of the traceability matrix marked *(carried)* were not re-read line-by-line this pass and reuse the prior review's evidence at `98a5e22` or the security re-run's evidence at `57abb2e`; the T-033 evidence numbers were not audited (separate track, see 4.3).

## Summary

The two release-blocking defects that caused the previous NO_GO — B1 (raw transcript prints compiled into Release) and B2 (Gemini API key and raw upstream bodies reaching the console via `error_code`) — are remediated at `57abb2e` and independently re-verified in this review. The fixes landed as `02f22dd`, `b64385b` and `5513323` (all ancestors of HEAD, verified with `git merge-base --is-ancestor`), and the re-run `security-test` returns **SECURITY-GO** with the B3–B7 findings closed by the recorded human risk acceptance (constitution Open Decision #11), not by remediation. The recorded unit gate is green at this exact SHA (`.last-tested-sha` == `57abb2e`; `Test-ElderlyAssistant-2026.09.13_07-07-45-+1000.xcresult`: result `Passed`, 2687 passed, 0 failed, 6 skipped, 2693 total), and the source privacy guard that formalises B1 runs at the top of every test gate and exits 0.

Against the previous report's four flip conditions: **1 MET** (with one caveat stated in 3.2), **2 MET**, **3 PARTIALLY MET** — the descope entry exists in both constitutions but carries **no time box and no owners**, which the condition asked for — and **4 UNMET** (constitution divergence product-vs-SDD, React Native vs native Swift, and the cloud-stack exception/consent remain unreconciled; no Release-build console check was performed and post-deploy monitoring remains a forward-requirement list, not a definition). Because two of the four conditions are not fully satisfied, the verdict remains **NO_GO** — but on a much narrower basis than before: the security substance is now met and the remaining items are governance/completeness, not shipped defects. Sections 1–6 document the evidence; the Verdict section states the precise conditions that would flip it.

## Decision

**Decision: NO_GO — sign-off not yet supportable, on governance grounds only.** The security core of the prior NO_GO is resolved: B1 and B2 are fixed in code at `57abb2e`, pinned by tests that ran green in the recorded gate, defended by a guard wired into every unit gate, and the workflow exit condition `review.decision == "SECURITY-GO"` (`default-sdd.yaml:119`) is re-established by the `security-test` re-run at this revision. Two of the four conditions the previous report named as verdict-flippers are not met: the B3–B7 risk acceptance is recorded but **not time-boxed and carries no owner** (Condition 3), and the constitution divergence plus Release-console/monitoring definitions are **unreconciled/undefined** (Condition 4). This review cannot grant the risk acceptance or amend the constitution; both are human decisions at this T2 gate. If those two items are closed as documentation, the flip to GO is mechanical on the evidence in this report.

## 1. Change summary

### 1.1 Workflow artifact chain

| Phase | Artifact | Status / decision |
|---|---|---|
| define-requirements | `.ai-sdd/outputs/define-requirements.md` (published as `requirements.md`, v1.0, 2026-03-03; 46 FR, 32 NFR — ID counts re-derived) | COMPLETED |
| design-l1 / design-l2 | `.ai-sdd/outputs/design-l1.md`, `design-l2.md` | COMPLETED |
| review-l2 | `.ai-sdd/outputs/review-l2.md` | COMPLETED (GO) |
| security-design-review | `.ai-sdd/outputs/security-design-review.md` (STRIDE, THREAT-001…010; decision GO with BLOCKER-1/2/3, `:346,:370,:384,:398`) | COMPLETED — blockers never closed (see 3.1) |
| plan-tasks | `.ai-sdd/outputs/plan-tasks/plan.md` — 39 parent tasks / 50 task IDs / 9 groups; rework stream T-049/T-050 (`plan.md` risks 28–29, `plan.md:94-96`, traceability `:117-158`) | COMPLETED |
| implement | `specs/implement-notes.md` — scoped to T-042; repo `.ai-sdd/outputs/implement-notes.md` additionally carries the T-049/T-050 fix-pass record (`:183` onwards) | COMPLETED |
| review-implementation | `specs/review-implementation.md` | COMPLETED — **GO** for T-042 (`:3`); not app-wide approval |
| security-test | `specs/security-test.md` (re-run, mirrored byte-identical to `.ai-sdd/outputs/security-test.md`) | **SECURITY-GO** at `57abb2e` (`:16`), with B3–B7 risk-accepted (OD#11) and B5 only partially remediated |
| final-sign-off | this document | **NO_GO** (narrow, governance-only — see Verdict) |

### 1.2 What was built / changed in this window (`98a5e22` → `57abb2e`)

- **T-049 (B1) — `02f22dd`, completed by `5513323`:** the two on-device STT engines no longer compile transcript content into Release. `WhisperSpeechRecognizer.swift:819` (`print("[whisper_stt] transcript=" + joined)`) is now inside `#if DEBUG` (`:812-820`) and the error print at `:842-844` is reduced to `domain` + numeric `code`; `WhisperKitSpeechRecognizer.swift:506` is guarded (`:499-507`), inference-failure `:512-521`, warm-failure `:307-318` and dialect-embedding `:735-745` are guarded and domain/code-only. Metadata-only diagnostics survive (`WhisperSpeechRecognizer.swift:809-811`, `WhisperKitSpeechRecognizer.swift:498`). Compilation contract re-checked: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` exists once, in the Debug configuration only (`project.pbxproj:2722`, closed by `name = Debug` at `:2726`; the Release block `:2728-2786` sets none).
- **Source privacy guard:** `ios/tools/check-release-log-safety.sh` / `.py` (replacing the falsified v1 awk guard). Tree-wide transcript rule over every `*.swift` under `ElderlyAssistant/` (`:274-277`, scan loop `:296-301`); raw-error rule scoped to the two engine files (`ENGINE_FILES :61-64`, engine-gated at `:278-282`); a missing listed engine file fails the gate (`:288-292`). Wired into `run_tests` at `build.sh:414` — i.e. before every test gate, including `test:unit` (`build.sh:501-504`). **Executed by me at HEAD: exit 0**, message `no transcript content or raw error object can be printed in a non-Debug configuration`.
- **T-050 (B2) — `b64385b`:** key moved out of both request URLs into the `x-goog-api-key` header (`GeminiClient.swift:254`, `:416`; URLs built without query key at `:237-241`, `:407-411`; no `key=` remains anywhere under `Services/Gemini/`); raw upstream body dropped — `GeminiClientError.httpError(status:)` carries the status only (`:57`), thrown at `:444` and `:274-278`; all six former `String(describing: error)` emitters now pass `ErrorCodeMapper.code(for:)` (`GeminiSpeechRecognizer.swift:144`, `GeminiCommandInterpreter.swift:111`, `VoicePipeline.swift:857` with the `"STT: <code>"` label at `:862`, `GeminiClient+Vision.swift:120`, `ApplianceHelperSession.swift:192`, `NepaliCalendarPlugin.swift:92`); `ErrorCodeMapper.swift:31-64` emits only type identity (never `localizedDescription`, `String(describing:)` or user-info); `LogSanitiser.boundErrorCode` (`LogSanitiser.swift:94`, `:106-122`, constants `:24-25`, `:42-53`) scrubs, shape-checks, rejects a 32+-character unbroken alphanumeric run, and caps at 64 chars before the console sink prints (`AppCoordinator.swift:7047-7066`).
- **`469520f` + `8265542`:** the default brain `intentQwen4BS43` now points at an HTTPS GitHub release with a full-length sha256 (`ModelCatalog.swift:538`, `:549`; default wired at `AppCoordinator.swift:1170`), and the brain tests were repinned accordingly.
- **`57abb2e`** merges `models/brain-tests-repair` (`8265542`) and is pushed to `origin/master`.
- SDD-side commits in the window: `98a5e22` (T-049/T-050 task definitions + plan rework stream), `87ccbee` (OD#11 + the prior NO_GO report), `be37f5d` (previous SECURITY-NO_GO mirror).

### 1.3 What is defined but not delivered

- T-045…T-048, T-039…T-044, TG-08 (T-033–T-038): planned, not implemented on master (plan.md risks 24–27). T-033's bake-off reached GO on its own branch (see 4.3) — not on master, awaiting lead sign-off.
- Android: not exercised; deferred.

### 1.4 Workflow-state integrity note

`workflow-state.json` now records `security-test` COMPLETED with `iterations: 1` (the re-run) and `final-sign-off` PENDING. Unlike the previous pass, the security-test record now matches its actual decision (`SECURITY-GO`, `specs/security-test.md:16`), so the exit condition is substantively met (`default-sdd.yaml:119`). This does not by itself pass any gate: state is mechanical, the report is the decision record, and the human T2 gate on this document is still required (`default-sdd.yaml:124-126`).

## 2. Requirements traceability

Statuses: **MET** (implemented and evidenced), **PARTIAL** (some evidence, requirement not demonstrably satisfied), **UNMET** (absent or violated, with evidence), **UNVERIFIED** (no evidence either way — not a pass). Evidence is at `57abb2e`; rows marked *(carried)* were not re-read line-by-line this pass and reuse the prior review's evidence at `98a5e22` or the security re-run's evidence at `57abb2e`; rows without the mark were re-verified this pass. Descoped findings are noted where they determine a row.

### 2.1 Functional requirements (46 rows)

| ID | Requirement (abbreviated) | Planned task(s) | Implementation evidence at `57abb2e` | Test evidence | Status |
|---|---|---|---|---|---|
| FR-001 | On-device STT; no audio to cloud | T-009, T-022 | Default voice stack still `.gemini` (`AppCoordinator.swift:1612-1613` — re-verified); that stack sends WAV audio to Gemini | None for the no-cloud-audio contract | UNMET |
| FR-002 | On-device TTS in configured language | T-012 | TTS stack files exist (`Services/Voice/Speaker.swift`, `SpeakQueue.swift` — existence re-verified); Nepali voice availability unverified; prior review dated C1 | None cited | UNVERIFIED |
| FR-003 | Bilingual Nepali/English, remote-updatable | T-012 | *(carried)* language hint/settings exist; remote update depends on absent remote config | None cited | PARTIAL |
| FR-004 | Always-on wake word incl. locked screen | T-005 | `WakeWordEngine.swift` exists (re-verified); product constitution defers production wake activation to v2 (`constitution.md:50`, product copy); SDD copy still mandates locked-screen always-on | None for locked-screen always-on | PARTIAL |
| FR-005 | Accent/dialect personalisation | T-009, T-011 | *(carried)* no accent-tuning implementation found | None | UNMET |
| FR-006 | TTS spoken in configured language | T-012 | As FR-002 | None | UNVERIFIED |
| FR-007 | On-device LLM; no cloud LLM ever | T-018, T-033–T-038 | On-device Qwen3 4B brain is the shipped default (`AppCoordinator.swift:1170`, `ModelCatalog.swift:538-549`); default voice stack still calls Gemini (`:1613`) | `BrainModelSelectionTests` assert wiring, not the requirement (9/9 passed in gate) | UNMET |
| FR-008 | NLU/entity/response within latency | T-018, T-021, T-033–T-038 | 4B brain default; T-033 bake-off GO on a separate branch (unmerged, awaiting lead sign-off) with desktop-proxy latency only | Trainer eval harness; not in the iOS unit gate | PARTIAL |
| FR-009 | LLM not a dependency for safety paths | T-018, T-024, T-026 | Keyword net runs before any model — callers re-verified at `CommandRouter.swift:567-568`, `:1435-1436`, `:2117-2118`; emergency dispatch module absent | `CommandRouterSafetyNetTests` exists (suite green in gate) | PARTIAL |
| FR-010 | Per-user context loaded into prompt | Not mapped in plan | *(carried)* `IntentPrompt` builds context incl. pending meds | None cited | PARTIAL |
| FR-011 | Voice biometric enrolment; secure storage only | T-014 | Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` re-verified (`KeychainEncryptedStorage.swift:82`; `VoiceBiometricStore.swift:6`); embedder MFCC today | Not cited | PARTIAL |
| FR-012 | Verify before sensitive commands | T-014, T-016, T-017 | NOT WIRED — re-verified: no production `.verify(` callers, no gate before `handleCall` confirmation path (`CommandRouter.swift:2224`) | None | UNMET |
| FR-013 | Voice biometric primary; PIN not default | T-014, T-017 | No wired gate (B3) | None | UNMET |
| FR-014 | PIN fallback, salted hash after 3 failures | T-016 | No PIN code — re-verified: no Argon2/bcrypt/PIN symbols anywhere; BLOCKER-2 open (`security-design-review.md:384`) | None | UNMET |
| FR-015 | Re-enrol prompt after PIN | T-017 | Absent | None | UNMET |
| FR-016 | Messenger voice call by voice | Not mapped | *(carried)* `handleCall` + deep links; executes on confirmation alone | None cited | PARTIAL |
| FR-017 | Messenger video call | Not mapped | *(carried)* `callType = "video"` parsed; placement unverified | None | UNVERIFIED |
| FR-018 | Answer incoming call by voice | Not mapped | *(carried)* no incoming-call handling found | None | UNMET |
| FR-019 | Deep link / OS integration | Not mapped | *(carried)* `fb-messenger://` / `whatsapp://` link opening; confirmation-gated | None | PARTIAL |
| FR-020 | Unresolved contact: inform, never call | Not mapped | *(carried)* not-found handling exists | None cited | PARTIAL |
| FR-021 | Google Calendar read/write | Not mapped | Re-verified: no Google Calendar API code (grep empty); only EventKit (`EventKitCalendarGateway.swift`) | None | UNMET |
| FR-022 | Calendar query by voice | Not mapped | *(carried)* EventKit-backed services exist; voice path unverified | None | UNVERIFIED |
| FR-023 | Add event by voice + confirm | Not mapped | *(carried)* unverified | None | UNVERIFIED |
| FR-024 | General reminders, voice delivery | Not mapped | *(carried)* `RoutineScheduler` / alarm services exist | Existing alarm tests | PARTIAL |
| FR-025 | Reminder persistence across restarts | Not mapped | *(carried)* persistence code present | Not verified | PARTIAL |
| FR-026 | Medication reminders naming med | T-028 | Files exist (re-verified `MedicationScheduler.swift`, `EscalationEngine.swift`); prior review C1 background-execution concern (dated) | `MedicationSchedulerTests`, `EscalationEngineTests` | PARTIAL |
| FR-027 | Re-fire 5× / 60 min window | T-028 | *(carried)* refire logic in `EscalationEngine` | `EscalationEngineTests` | PARTIAL |
| FR-028 | Family alert after window + missed-dose log | T-028 | Alert path is a silent stub — re-verified: `FamilyNotifier.swift:109-114` prints an 8-char token prefix and returns `true` unconditionally; broker absent (B6, descoped) | None for delivery | UNMET |
| FR-029 | Ack persisted immediately; re-fire after kill | T-028 | *(carried)* persistence code present; process-kill re-fire unverified | `MedicationSchedulerTests` (not pinned to process-kill) | PARTIAL |
| FR-030 | Family views adherence log | Not mapped | Companion app absent — re-verified: no companion target in `project.pbxproj` | None | UNMET |
| FR-031 | HealthKit / Health Connect monitoring | T-024 | Re-verified: no HealthKit Swift code (grep empty; the only "HealthKit" strings are localised privacy copy); `security-test.md:130`; prior review 0% | None | UNMET |
| FR-032 | Configurable thresholds | T-024 | No threshold code | None | UNMET |
| FR-033 | Emergency sequence (alert → 30 s → call) | T-026 | Absent — re-verified: `handleEmergency` posts a local notification and speaks an ack only (`CommandRouter.swift:2213-2216`); comment concedes no module | None | UNMET |
| FR-034 | Dispatch isolated from LLM | T-026 | No dispatch module (re-verified: no dispatcher symbols); keyword net isolation implemented and tested | `CommandRouterSafetyNetTests` (net only) | UNMET |
| FR-035 | Monitoring failure alert | T-026 | Absent (no monitoring) | None | UNMET |
| FR-036 | Cancel emergency by voice | T-026 | Absent (no countdown) | None | UNMET |
| FR-037 | Emergency data encrypted at rest | Not mapped | No emergency-data model; encrypted storage layer exists but unused for this | None | UNMET |
| FR-038 | Family companion app | T-030, T-032 | Absent (re-verified: no companion target) | None | UNMET |
| FR-039 | E2E config payloads | T-030 | Absent — re-verified: no libsignal/Double Ratchet/config types (`security-test.md:132`) | None | UNMET |
| FR-040 | Apply config immediately + voice confirm | T-031 | Absent | None | UNMET |
| FR-041 | Decrypt + validate before apply | T-031 | Absent | None | UNMET |
| FR-042 | In-app config requires auth | T-031 | Settings screens exist; auth gate absent (B3) | None | UNMET |
| FR-043 | Single on-device user profile | T-032 | *(carried)* multiple on-device stores; single profile object unverified | None cited | PARTIAL |
| FR-044 | Re-enrolment without reset | T-032 | *(carried)* APIs support re-enrol; no UI-flow evidence | None | PARTIAL |
| FR-045 | Reminder style + TTS prefs | T-032 | *(carried)* `TTSVoicesSettingsView`; reminder style unverified | None | PARTIAL |
| FR-046 | Profile on-device; cloud only as required | T-032 | Violated by default: audio + pending med names to Gemini (B7, descoped; `security-test.md:73,121`) | None | UNMET |

### 2.2 Non-functional requirements (32 rows)

| ID | Requirement (abbreviated) | Planned task(s) | Implementation evidence at `57abb2e` | Test evidence | Status |
|---|---|---|---|---|---|
| NFR-001 | STT latency ≤ 2 s | T-009, T-022, T-045 | *(carried)* no measured evidence in this corpus | None | UNVERIFIED |
| NFR-002 | LLM latency ≤ 4 s | T-018, T-022, T-045 | No measured evidence; T-033 proxies are desktop-only and unmerged | None | UNVERIFIED |
| NFR-003 | Wake-word latency ≤ 1 s | Not mapped | No measurement | None | UNVERIFIED |
| NFR-004 | Emergency response ≤ 3 s | T-024 | No module (B4, descoped) | None | UNMET |
| NFR-005 | Med reminder within 30 s | Not mapped | No measurement | None | UNVERIFIED |
| NFR-006 | 24/7 responsive incl. locked screen | T-005, T-007 | *(carried)* prior review C1 (dated); product constitution narrows to v2 wake activation | None | UNMET |
| NFR-007 | Background-mode compliance iOS/Android | T-005, T-007 | *(carried)* no evidence | None | UNVERIFIED |
| NFR-008 | Safety services auto-restart | Not mapped | *(carried)* no evidence | None | UNVERIFIED |
| NFR-009 | Biometric data in secure storage only | Not mapped | Re-verified: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`KeychainEncryptedStorage.swift:82`); `security-test.md:100` | None cited | MET |
| NFR-010 | PIN salted hash; never plaintext/logged | T-050 (per plan) | Absent — no PIN code (re-verified); B3 descoped | None | UNMET |
| NFR-011 | TLS 1.2+ on all outbound | T-014, T-050 | Partial movement: default brain URL now HTTPS (`ModelCatalog.swift:549`, `469520f`); curated `qwen4BNepali` still ships `http://192.168.1.117:8765/...` (`ModelCatalog.swift:654`, offered in `availableBrainEntries` `:815-818`) with ATS `NSAllowsLocalNetworking` present (`Info.plist:105-107`); B5 remainder descoped | None | UNMET |
| NFR-012 | E2E config with forward secrecy | T-030 | Absent (B5, descoped) | None | UNMET |
| NFR-013 | Quarantine sanitisation at all entry points | T-020 | Re-verified: sanitiser at all three interpreter boundaries (`GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, `LocalIntentInterpreter.swift:101`) and the plugin dispatch path (`CommandRouter.swift:2380`) | `InputSanitiserTests`; `security-test.md:94` | MET |
| NFR-014 | STRIDE produced and approved pre-implementation | Not mapped | Produced (`security-design-review.md:346` GO with blockers); BLOCKER-1/2/3 (`:370,:384,:398`) remained open while implementation proceeded | n/a | PARTIAL |
| NFR-015 | No personal data to cloud for AI | T-002, T-004, T-034, T-036 | Violated by default Gemini stack (B7, descoped) | None | UNMET |
| NFR-016 | No PII in logs; sanitiser strips it | T-004, T-042, T-049, T-050 | Remediated this window: B1/B2 fixed at `57abb2e` (section 3.3); residuals: 8-char token-prefix print in the descoped stub (`FamilyNotifier.swift:112`), engine-scoped raw-error guard, guard's documented shape-bound limits | `GeminiKeyLogBoundaryTests` 9/9 and `LogSanitiserTests` 12/12 Passed in the recorded gate; guard green | PARTIAL |
| NFR-017 | Health data minimisation | Not mapped | No HealthKit code exists (nothing to minimise yet) | None | UNMET |
| NFR-018 | Only required permissions, point-of-use | Not mapped | *(carried)* usage strings exist (`Info.plist:61-81`); point-of-use flow not audited; REC-6 unverified | None | UNVERIFIED |
| NFR-019 | Every function voice-accessible | Not mapped | *(carried)* no complete audit | None | UNVERIFIED |
| NFR-020 | 44×44 pt touch targets | Not mapped | No audit | None | UNVERIFIED |
| NFR-021 | ≥ 18 pt body text | Not mapped | No audit | None | UNVERIFIED |
| NFR-022 | WCAG AA contrast | Not mapped | No audit | None | UNVERIFIED |
| NFR-023 | All strings externalised | T-042–T-044 | Catalogue present (`Localizable.xcstrings`, 439,120 bytes — re-verified); T-042 removed one dead hardcoded key; no full sweep | Spot checks in `review-implementation.md` | PARTIAL |
| NFR-024 | Nepali + English at launch (STT/TTS) | Not mapped | *(carried)* resources + language hint present; end-to-end Nepali unverified | None | PARTIAL |
| NFR-025 | Language packs without code changes | T-040 | *(carried)* design claims plugin support; implementation unverified | None | UNVERIFIED |
| NFR-026 | 100% coverage safety-critical paths | T-024, T-026, T-028 | Emergency paths absent; coverage never instrumented (`security-test.md:124` recommendation 4) | `EscalationEngineTests` etc. exist | UNMET |
| NFR-027 | Med persistence abnormal-termination test | T-028 | *(carried)* process-kill test not evidenced | `MedicationSchedulerTests` (scope unverified) | UNVERIFIED |
| NFR-028 | Emergency sequence E2E tests | T-026 | Absent — no emergency module | None | UNMET |
| NFR-029 | Confidence 0.85; 5 rework max | Not mapped | Re-verified workflow config: `default-sdd.yaml:105` (threshold 0.85), `:103` (paired review), `:53,:107` (max rework 5) | `review-implementation.md:3` GO (0.90) | MET |
| NFR-030 | App Store 5.1.1 / 5.1.3 compliance | Not mapped | No submission; cloud-audio tension (B7); no app-target `PrivacyInfo.xcprivacy` (find empty — re-verified) | None | UNVERIFIED |
| NFR-031 | Play sensitive-permissions policy + disclosure | Not mapped | *(carried)* Android dormant; REC-6 open | None | UNVERIFIED |
| NFR-032 | In-app privacy policy | Not mapped | *(carried)* privacy settings section exists; policy content not reviewed | None | UNVERIFIED |

### 2.3 Traceability totals and gaps

- Rows: **78** (46 FR + 32 NFR). MET: **3** (NFR-009, NFR-013, NFR-029). PARTIAL: **21**. UNMET: **33**. UNVERIFIED: **21**. Movement versus the prior report: NFR-016 moves UNMET → PARTIAL on the B1/B2 remediation; NFR-011 remains UNMET but with the default-brain HTTPS movement recorded.
- Plan-level gap unchanged: `plan.md`'s traceability table (`:117-158`) still maps no task to **FR-010, FR-016–FR-025, FR-030, FR-037** (13 FRs) or to **NFR-003, NFR-005, NFR-008, NFR-009, NFR-014, NFR-017–NFR-022, NFR-024, NFR-029–NFR-032** (16 NFRs). The new rows T-049/T-050 (`:157-158`) cover NFR-013/016/010/011. Several of the 29 unmapped rows are implemented anyway (NFR-009); the plan still does not trace them — a plan revision gap.
- Untraced features in the opposite direction: the cloud voice stack (Gemini STT/interpreter) still has no FR/NFR or design-corpus entry (B7; `security-test.md:73,111`). The T-033 encoder track has no row in this table because its artifacts are not on master (4.3).

## 3. Security posture

### 3.1 Security design review (2026-03-04)

STRIDE model with THREAT-001…010; decision GO with conditions (`security-design-review.md:346`). The three conditions were never closed: **BLOCKER-1** PAD/liveness (`:370`), **BLOCKER-2** PIN lockout (`:384`), **BLOCKER-3** pairing + threshold bounds (`:398`). BLOCKER-1/2 remain design debt under the descoped B3; BLOCKER-3 has no remote-config/pairing code at all (descoped B5). REC-5's adversarial blocklist implemented; REC-1/3/4/6/7/8 unverified or dependent on absent modules (carried).

### 3.2 Security test result (re-run)

`specs/security-test.md` (mirror byte-identical to the uncommitted `.ai-sdd/outputs/security-test.md`): **SECURITY-GO** at `57abb2e` (`:16`), with the explicit caveat that the descoped categories read SECURITY-NO_GO on the merits and are annotated `risk-accepted (OD#11)` (`:16`, category table `:91-99`, focus areas `:105-111`). Per-category: SQL injection GO, input validation GO, **auth bypass NO_GO (risk-accepted)**, PII in logs GO, secrets in output GO, audit-log completeness GO (scoped), error leakage GO (`:93-99`). Focus areas: voice injection GO, health PII in logs GO, auth bypass / emergency validation / encrypted config NO_GO risk-accepted (`:107-111`). B5 is explicitly recorded as only **partially** remediated (`:74,121`): the default brain moved to HTTPS in `469520f`, while `qwen4BNepali` still ships the cleartext LAN URL and the ATS exception remains.

The re-run report is a decision record; I re-derived its key claims independently rather than trusting its summary, and I did **not** re-run the security test itself (read-only review). Its own verification limitations are recorded at `:138-145` (no live-device testing, no network capture, no Release-binary execution; guard executed function-level and by hand).

### 3.3 Finding status re-verified at HEAD `57abb2e`

| Finding | Status at `57abb2e` | Evidence I read / executed | Gate effect |
|---|---|---|---|
| B1 — raw transcript prints in Release | **FIXED** | `WhisperSpeechRecognizer.swift:809-820` (guarded transcript; metadata-only print survives), `:842-844` (error domain+code); `WhisperKitSpeechRecognizer.swift:498-507`, `:512-521`, `:307-318`, `:735-745`; DEBUG config only in `project.pbxproj:2722-2726`; I executed `check-release-log-safety.sh` → exit 0; guard wired at `build.sh:414` | Not blocking |
| B2 — key / raw upstream body via `error_code` | **FIXED** | `GeminiClient.swift:57` (status-only error), `:237-241,:254` and `:407-411,:416` (header auth, no `key=`), `:439-444` (body dropped); six emitters via `ErrorCodeMapper` (`GeminiSpeechRecognizer.swift:144`, `GeminiCommandInterpreter.swift:111`, `VoicePipeline.swift:857-862`, `GeminiClient+Vision.swift:120`, `ApplianceHelperSession.swift:192`, `NepaliCalendarPlugin.swift:92`); `ErrorCodeMapper.swift:31-64`; `LogSanitiser.swift:94,:106-122`; sink `AppCoordinator.swift:7047-7066`; boundary tests include the real error path with process-stdout capture (`GeminiKeyLogBoundaryTests.swift:158-180,:184-208,:215-239`, all Passed in the recorded gate) | Not blocking |
| B3 — sensitive-action auth unwired | OPEN — descoped (OD#11) | `SpeakerBiometricService.swift` header states NOT WIRED (`:16-20`); no production `.verify(` callers (grep empty); no PIN code (grep empty); `handleCall` proceeds on confirmation (`CommandRouter.swift:2224`) | Risk-accepted by decision |
| B4/B6 — no emergency module; silent-success alert stub | OPEN — descoped | `handleEmergency` ack-only (`CommandRouter.swift:2213-2216`); `FamilyNotifier.swift:109-114` returns `true` unconditionally | Risk-accepted by decision |
| B5 — cleartext config/model transport | OPEN — partially remediated, remainder descoped | Default brain HTTPS `ModelCatalog.swift:549`; remaining cleartext `http://192.168.1.117:8765/...` at `ModelCatalog.swift:654`, offered at `:815-818`; ATS `NSAllowsLocalNetworking` `Info.plist:105-107`; no remote-config chain (grep empty) | Risk-accepted by decision |
| B7 — cloud stack vs Privacy bullet | OPEN — descoped | Default stack `.gemini` (`AppCoordinator.swift:1612-1613`); audio path unchanged (`security-test.md:73`); no consent/disclosure amendment | Risk-accepted by decision |

Residual caveats attached to the B1/B2 fixes (recorded, not blockers): Debug builds deliberately retain transcript prints (`#if DEBUG`, compiled out of Release per the config contract — do not distribute Debug builds; `security-test.md:85`); the guard's raw-error rule is engine-scoped and its own docstring records the scope gap (`implement-notes.md:396-417`, `security-test.md:84`); the sanitiser bound is a shape bound, not an entropy proof (a secret shorter than 32 chars passed as `error_code` would still pass — `LogSanitiser.swift:36-41`, `implement-notes.md:438-441`); raw OS error prints outside the engines remain in Release with no secret/PII exposure (`security-test.md:135`).

## 4. Open items

### 4.1 Narrow remaining blockers (the sign-off conditions)

| Item | Detail | Owner / next step |
|---|---|---|
| OD#11 is not time-boxed | `constitution.md:117-122` (both copies) records the B3–B7 descope dated 2026-09-13, but carries **no review/expiry date and no named owner**. The accepted risks include no auth gate on sensitive commands (B3) and no emergency module (B4/B6) — an open-ended acceptance. The previous gate's own decision list asked for its time box and owners to be confirmed. | Human T2 decision; add review-by date + owner(s) |
| Constitution divergence unreconciled | The SDD `constitution.md` still differs from the product copy: constraint 4 (SDD line 50 mandates 24/7 locked-screen; repo defers wake activation to v2), OD#5 (remote config `RESOLVED` in repo only), OD#10 (wake word `RESOLVED FOR iOS MVP` in repo only); both copies still state React Native (`:25`, `:103`) while the product is native Swift; neither copy amends the Privacy bullet for the cloud voice stack (OD#11 records acceptance, not an exception/consent design; default unchanged `.gemini`) | Human decisions: amend SDD copy / record why not; resolve React Native vs native Swift; record cloud-stack exception or change the default |
| Release-console check and monitoring not defined as gates | The source guard is now the strongest local control (wired into every gate, executed green), but no Release-build console check on a built binary/device was performed or defined as a pre-release gate, and post-deploy monitoring remains the forward-requirement list of the prior report §4.4 (console-only telemetry; `security-test.md:131`) | Define (owner + evidence format) before any release |

### 4.2 Descoped by human T2 decision (recorded as Open Decision #11)

Residual risk accepted per descoped finding (unchanged in substance from the prior report; the record now exists in the constitution and the security re-run annotates each category):

| Descoped finding | Residual risk accepted |
|---|---|
| B3 | Sensitive voice commands (calls; config; health-data actions once they exist) execute **without** biometric or PIN verification; the LLM-interpreted call path acts on confirmation alone (`CommandRouter.swift:2224`). THREAT-001 replay/PAD and BLOCKER-1/2 design debt unresolved. |
| B4/B6 | An emergency utterance produces only a spoken acknowledgement and a local notification (`CommandRouter.swift:2213-2216`) — no call dispatch, no countdown, no family alert. `sendPush` returns success for alerts that were never sent (`FamilyNotifier.swift:109-114`); the stub must fail closed when finally wired. |
| B5 | No E2E remote configuration and no pairing exist. One cleartext HTTP LAN model URL remains in the offered catalogue (`ModelCatalog.swift:654`; ATS exception `Info.plist:107`); downloads are unauthenticated and unencrypted on the LAN (SHA-256 checks integrity, not confidentiality). Default download path is now HTTPS. |
| B7 | The default stack transmits user audio and pending medication names to Gemini. Consent/disclosure design is not recorded; the Settings disclosure is only "Gemini uses the internet". If this ships, the Privacy bullet needs the recorded exception/consent (or the default changed). |

### 4.3 Other known issues / deferred items

- **T-033 (Nepali intent encoder bake-off) is a separate track, not absorbed here.** Its report (`tools/train-intent/docs/T-033-encoder-bakeoff.md` on branch `worktree-t033-encoder-bakeoff`, commit `035c91a`, based on master `5513323`) records **GO** with a named base (`cartesinus/multilingual_minilm-amazon-massive-intent`) and pre-registered kill criteria (C1 killed on licence; C2 killed on Android int8 emergency recall 0.000; C4 architecturally excluded), but it is **not merged to master** and its own "Open steps" say lead-engineer sign-off is not claimed. It is not part of this workflow's sign-off surface; if the human counts T-033 as in scope, it needs its own gate record. Do not read its GO as evidence for FR-007/FR-008 above.
- Default brain is now HTTPS-hosted, but the curated picker still offers the LAN-only `qwen4BNepali` (`ModelCatalog.swift:815-818`); T-048 is planned to decide hosting vs hiding.
- Open Decisions unresolved: HIPAA assumption, GDPR deferral, data residency, WhatsApp integration method (`constitution.md:97-113`); OD#11's stale clause ("defined, not yet implemented") and stale line references (`ModelCatalog.swift:546,651`) should be corrected when touched.
- Telemetry is console-only with no durable audit trail; no crash reporting or monitoring pipeline identified.
- Compliance artifacts: no app-target `PrivacyInfo.xcprivacy` found; no evidence of App Store/TestFlight submission or privacy-policy review.
- Evidence freshness: `docs/review-2026-08-30.md` remains a dated source; `security-test.md` observation 8 lists its stale claims that must not be re-used.
- Repo state note: the two uncommitted `.ai-sdd/outputs/` mirror files are records only (no app code); they should be committed or otherwise dispositioned by the workflow owner.

### 4.4 Post-deploy monitoring (requirements before any release)

No production deployment exists; this remains a forward requirement list: (1) after the B1/B2 fixes, verify on a **Release build and a real device** that no transcript/key material appears in the device console or sysdiagnose (the source guard is a static check; this runtime check has not been performed); (2) keep the security-test re-run current for any change touching the security surface; (3) define crash/telemetry retention and an alert on anomalous log volume; (4) monitor model-download failures once the hosting decision lands; (5) monitor medication reminder delivery once background execution is re-verified.

## 5. Rollback plan

There is no production deployment: no fastlane/App Store submission machinery exists; `ios/build.sh ipa` is the only release-artifact path. Rollback is at three levels:

1. **Do not ship (recommended until the T2 gate passes).** The current build must not be handed to real users while the sign-off conditions remain open. TestFlight builds expire/replace; no user-facing rollback needed.
2. **App code — this window's changes are individually revertible** (all commits verified as ancestors of `57abb2e`):
   - `git revert 5513323` — drops the widened guard and the two guarded raw-error prints (re-exposes Release raw-error prints; not recommended).
   - `git revert b64385b` — reverts header auth/body-drop/sanitiser bound (reintroduces the key in the URL and the B2 leak; must not be done without a replacement control).
   - `git revert 02f22dd` — removes the transcript guard (reintroduces B1; not recommended).
   - `git revert 469520f` / `8265542` — restores the previous default-brain wiring/tests; the in-app brain picker also allows switching away from the default without a revert.
   - The T-049/T-050 diffs are small and do not touch the keyword safety net or router stage order (`plan.md:94`), so reverting them cannot destabilise the safety path — but reverting them reintroduces the two fixed security defects.
3. **Forward-fix (the only App Store-safe option).** A released iOS binary cannot be downgraded by users; rollback for a shipped version is a hotfix build plus (ideally) a phased rollout. No phased-rollout mechanism exists yet; define one before release.

Trigger conditions for rollback: any transcript/key material observed in device logs; model fetch failures caused by the LAN-only picker entry; medication reminder regressions. Rollback does not restore the failed security gate — B1/B2 must remain fixed forward.

## 6. Compliance checklist

Verdicts: SATISFIED / PARTIAL / NOT SATISFIED / UNVERIFIABLE, each with evidence. Descoped items are marked NOT SATISFIED with "descoped by T2 decision" so the acceptance is visible, not hidden.

### 6.1 App Store / Play Store

| Item | Verdict | Evidence |
|---|---|---|
| Apple Guideline 5.1.1 — Data Collection and Storage | NOT SATISFIED | Cloud audio + pending medication names by default (B7, descoped); no privacy-policy content review; no submission |
| Apple Guideline 5.1.3 — Health and Health Research | UNVERIFIABLE | No HealthKit integration exists (FR-031 absent); no submission |
| iOS Background Modes / 24-7 claim | NOT SATISFIED | No evidence of locked-screen always-on; prior review C1 (dated); product constitution defers wake activation |
| Privacy manifest / required-reason APIs | UNVERIFIABLE | No app-target `PrivacyInfo.xcprivacy` found (re-verified); may not be required depending on APIs used |
| Permissions at point of use, plain language | UNVERIFIABLE | Usage strings in `Info.plist:61-81`; point-of-use disclosure flows not audited |
| Play Sensitive App Permissions — Body Sensors, Contacts + disclosure (NFR-031) | UNVERIFIABLE | Android dormant; no disclosure implementation; REC-6 unverified |
| Play health-app policies | UNVERIFIABLE | No Android build or submission evidence |

### 6.2 Constitution bullets (SDD `constitution.md`)

| Item | Verdict | Evidence |
|---|---|---|
| Constraint 1 — all AI on-device; personal data never leaves for AI | NOT SATISFIED | B7 (descoped): default `.gemini` (`AppCoordinator.swift:1612-1613`) |
| Constraint 2 — remote config E2E encrypted | NOT SATISFIED | B5 (descoped): no chain exists |
| Constraint 3 — voice biometric primary; PIN fallback only | NOT SATISFIED | B3 (descoped): gate unwired; no PIN |
| Constraint 4 — 24/7 always-on background service | NOT SATISFIED | SDD copy mandates locked-screen always-on; product defers wake activation (repo `constitution.md:50`); divergence itself unreconciled |
| Constraint 5 — highly personalised on-device profiles | NOT SATISFIED | Partial stores; no single verified profile; cloud leaks by default (B7) |
| Constraint 6 — Nepali launch + language plugins | UNVERIFIABLE | Resources and training present; end-to-end Nepali unverified (dated C10) |
| Accessibility — voice-first, 44 pt, 18 pt, contrast | UNVERIFIABLE | No accessibility audit or tests found |
| Privacy — no personal data to cloud for AI | NOT SATISFIED | Same as constraint 1 (B7, descoped) |
| Privacy — health data minimisation | UNVERIFIABLE | No HealthKit code exists |
| Privacy — remote config E2E (keys on devices only) | NOT SATISFIED | B5 (descoped) |
| Privacy — logs must not contain PII; sanitiser required | **PARTIAL** (was NOT SATISFIED) | B1/B2 fixed and guard green at `57abb2e` (3.3); residuals: 8-char token-prefix print (`FamilyNotifier.swift:112`, descoped stub), engine-scoped raw-error rule, guard shape-limit caveats (`LogSanitiser.swift:36-41`) |
| Security — biometric storage on-device (Secure Enclave / Keystore) | SATISFIED | `KeychainEncryptedStorage.swift:82`; `VoiceBiometricStore.swift:6`; `security-test.md:100` |
| Security — PIN salted hash, never plaintext | NOT SATISFIED | No PIN code (descoped under B3) |
| Security — emergency data encrypted at rest | NOT SATISFIED | No such data model (descoped under B4) |
| Security — TLS 1.2+ on all outbound | NOT SATISFIED (partially remediated) | Default brain now HTTPS (`ModelCatalog.swift:549`); LAN URL `:654` + ATS `Info.plist:107` remain (B5 remainder, descoped) |
| Security — injection detection at `quarantine` | SATISFIED | Sanitiser at all LLM boundaries (`security-test.md:94`; sites re-verified) |
| Security — STRIDE threat model produced | SATISFIED | `security-design-review.md:346`; BLOCKER-1/2/3 remain open (covered by descopes B3/B5) |
| Quality — 100% coverage safety-critical paths | NOT SATISFIED | Emergency paths absent; coverage not instrumented (`security-test.md:124`) |
| Quality — confidence 0.85 | SATISFIED | `default-sdd.yaml:105`; T-042 GO at 0.90 (`review-implementation.md:3`) |
| Quality — paired review enabled | SATISFIED | `default-sdd.yaml:103`; `review-implementation.md` |
| Quality — max rework 5 | SATISFIED | `default-sdd.yaml:53,:107` |

### 6.3 Reviewer checklist (standard)

| Check | Verdict | Evidence |
|---|---|---|
| Explicit error return types on interface methods | PASS | No interface change in this window; `GeminiClientError` enum with explicit cases (`GeminiClient.swift:49-69`); `PluginResult` with explicit `.failed` (T-042, carried) |
| Async/external calls have documented failure mode and recovery | FAIL | `APNsProvider.sendPush` returns success silently (B6, descoped); no retry/queue for family alerts |
| Timeouts/retries configurable, not hardcoded | PARTIAL | Gemini timeout configurable (`GeminiClient.swift:251,:413`); `InputSanitiser.maxLength = 200` hardcoded (`InputSanitiser.swift:22`); APNs stub has neither |
| Every element traces to an FR/NFR | FAIL | Cloud voice stack untraced (B7); plan maps no task to 13 FRs / 16 NFRs (2.3) |
| Operator-visible behaviour on run and on failure | FAIL | Emergency yields an ack + local notification only (B4, descoped); family alert silent (B6, descoped) |

## Verdict: NO_GO — sign-off not yet supportable (governance conditions only)

**Adjudication of the four prior flip conditions, individually:**

1. **T-049/T-050 land with evidence — MET** (with one caveat stated). Both fixes are ancestors of HEAD (`02f22dd`, `b64385b`, `5513323`; verified `git merge-base --is-ancestor`), read and verified in code at `57abb2e`, pinned by tests that passed in the recorded gate at this SHA, and defended by a guard I executed green and that is wired into every unit gate (`build.sh:414`). No key, URL or raw upstream body is reachable through `error_code` on the code paths I read (mapper never reads descriptions; sink bounds `error_code`). Caveat: the condition's literal phrase "no transcript content in **any** build configuration outside the sanitised bus" is not satisfied literally — Debug configurations deliberately retain transcript prints (`WhisperSpeechRecognizer.swift:812-820`, `WhisperKitSpeechRecognizer.swift:499-506`); **no shipping (Release) configuration contains them** (`project.pbxproj:2722-2726`), and the security re-run adjudicated the Debug-only prints acceptable (`security-test.md:85`). If the human wants the strict reading, the remedy is deleting the Debug prints, not a re-work of the fix.
2. **`security-test` re-run at the fixed revision returns SECURITY-GO — MET.** `specs/security-test.md` reviewed revision `57abb2e` == HEAD (`:6`), verdict SECURITY-GO (`:16`), per-category table present (`:93-99`, `:105-111`). The workflow exit condition `review.decision == "SECURITY-GO"` (`default-sdd.yaml:119`) is met. The GO explicitly rests on the B3–B7 risk acceptance recorded in OD#11; this review verified that annotation and does not itself accept the risks.
3. **B3–B7 descope present as a time-boxed entry in `constitution.md` Open Decisions — PARTIALLY MET.** The entry exists in both constitution copies (`constitution.md:117-122`), dated 2026-09-13, covers B3, B4/B6, B5, B7, and states plainly that B1/B2 were **not** descoped and remain blocking; it also says (correctly for its writing time, now stale) that the B1/B2 remediation is "defined, not yet implemented". **It does not carry a time box and it names no owners** — a decision date is not a review horizon. The prior gate's decision list asked for exactly "its time box and owners". This is the only part of Condition 3 that is unmet.
4. **Constitution divergence reconciled; Release-build console check plus post-deploy monitoring defined — UNMET.** (a) The SDD `constitution.md` is still not reconciled with the product copy: constraint 4 (SDD line 50 vs repo line 50), OD#5 (`:105`), OD#10 (`:115`), and both copies still state React Native (`:25`, `:103`) against a native-Swift product; no cloud-stack exception/consent amendment exists in either copy (OD#11 records risk acceptance; the Privacy bullet is unchanged and the default remains `.gemini`). (b) The source privacy guard + compilation contract are defined and wired (a strong static control, green), but no Release-build console check was executed or defined as a pre-release gate (`security-test.md:138-145`), and post-deploy monitoring remains the prior report's forward-requirement list (§4.4), with console-only telemetry and no retention/alerting definition.

**Why NO_GO and not GO:** the previous verdict's substantial basis — B1/B2 shipping and the security gate un-re-established — is gone; that is the real movement in this re-run. But the prior report's own flip contract required all four conditions, and two of them are not fully satisfied (3 lacks the time box/owners; 4 is unmet). Those are not shipped defects and not security regressions; they are records and governance decisions that this reviewer cannot make, and the T2 gate is mandatory for a safety-critical project. Declaring GO would upgrade the record on the strength of workflow state rather than evidence — exactly what this review must not do.

**Conditions that would flip this verdict to GO:**

1. Open Decision #11 (or a companion recorded decision) gains a **review-by date and named owner(s)** for the accepted B3–B7 risks — the human confirming how long "no auth gate on sensitive commands" and "no emergency-call module" stay accepted.
2. The **constitution divergence is reconciled**: the SDD copy is amended (constraint 4, OD#5, OD#10) or a recorded decision states why it will not be; React Native vs native Swift is resolved; the cloud-stack exception with consent/disclosure is recorded, or the default is changed.
3. The **Release-build console check is performed** (or defined as a pre-release gate with owner and evidence format) and **post-deploy monitoring is defined** (crash/telemetry retention, alerting); the prior report §4.4 list is the starting point.
4. Conditions 1 and 2 remain met at whatever revision the human signs: any further app-code change requires the guard and unit gate green at the new SHA (and a security re-run if it touches the security surface); the B1/B2 fixes must not be reverted by the rollback/hotfix path.

**Specific human decisions required at this T2 gate (this review cannot grant any of them):**

- Accept, reject or amend the B3–B7 risk acceptance as recorded — and confirm its time box and owners (Condition 3).
- Decide the constitution amendments/exception: cloud voice-stack consent/disclosure, React Native vs native Swift, wake-word deferral (Condition 4).
- Decide the Release-console check and monitoring definitions before any release (Condition 4).
- Note that this report's NO_GO is governance-only: no new security defect was found in this re-run, and B1/B2 are fixed and verified at `57abb2e` (full SHA in `ios/build/.last-tested-sha`).
