# Final Sign-Off — final-sign-off (phase: sign-off, risk tier T2)

- Task: `final-sign-off` (ai-sdd workflow `elderly-ai-assistant-sdd`, task library `final-sign-off.yaml`: T2, no HIL overlay in-task, human gate via risk tier)
- Report path: `specs/final-sign-off.md` (SDD project: `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`)
- Code repo reviewed: `/Users/anjan/workspace/projects/elderly-ai-assistant` — `master` at **`98a5e22`**, working tree clean (re-verified during this review)
- Revision equivalence: the `security-test` of record was authored at `fb6e03c`. `git diff fb6e03c..98a5e22 --stat -- ios/ android/` shows the only app-code delta is `34c81b9` (AppCoordinator.swift +2/-1, ModelCatalog.swift +20), which that report's revision note already assessed; `be37f5d` and `98a5e22` touch only `.ai-sdd/outputs/**`. No finding changes.
- Author: Reviewer agent. This is a decision pack for the human T2 gate. It does not itself grant sign-off; acceptance of any open finding is a human risk-acceptance decision.
- Sources read: `constitution.md` (SDD project), `requirements.md`, `requirements-dementia-supplement.md` (referenced), `specs/security-test.md`, `specs/review-implementation.md`, `specs/implement-notes.md`, `.ai-sdd/outputs/security-design-review.md`, `.ai-sdd/outputs/plan-tasks/plan.md`, T-049/T-050 task files, `.ai-sdd/state/workflow-state.json`, `.ai-sdd/workflows/default-sdd.yaml`, task library `final-sign-off.yaml` / `security-test.yaml` / `security-design-review.yaml`, product repo code at `98a5e22`, `docs/review-2026-08-30.md`, `docs/OPEN-ITEMS.md`
- Verification performed: static re-verification of every blocking security finding B1–B7 at HEAD (grep plus reading the cited code); git revision checks; requirement-to-code spot checks for the traceability matrix. I did not run the test suite for this report; the latest recorded gate is the `security-test` green unit run (2672 tests, 0 failures at `fb6e03c`, `ios/build.sh test:unit`).

## Summary

The workflow's artifacts are complete end-to-end (requirements, L1/L2 design, STRIDE security design review, plan, implementation, reviews), but the security gate failed and the failure was not remediated before this sign-off task. The `security-test` of record returned **SECURITY-NO_GO** with blocking findings B1–B7; its exit condition `review.decision == "SECURITY-GO"` was **not met**, yet the engine advanced the workflow because it does not enforce exit conditions — `workflow-state.json:98-109` records `security-test` as COMPLETED. Re-verification at `98a5e22` confirms B1–B7 are all still present; the B1/B2 rework exists only as task definitions T-049/T-050 (`98a5e22` touches only `.ai-sdd/outputs/plan-tasks/**`, no Swift).

During this review the workflow orchestrator reported a human T2 risk-acceptance decision: **B3, B4, B5, B6 and B7 are explicitly descoped** (recorded state of that decision in `constitution.md` was not yet present when this report was written — `constitution.md` is unchanged since 2026-05-23; the entry is being added under Open Decisions). With that descope, the sign-off turns on **B1 and B2 alone** — and both remain open with no landed fix. The descoped findings still leave documented residual risk, stated in Open Items and marked in the compliance checklist; the descope is not a clean bill of health.

## Decision

**Decision: NO_GO.** Not ready for sign-off. B1 (raw Release-build transcript prints) and B2 (API key / raw upstream error body reaching logs through `error_code`) are release-blocking PII/secret leaks that ship in the current code at `98a5e22`, their remediation is planned only (T-049/T-050 definitions in `98a5e22`, no fix landed), and the `security-test` exit condition `review.decision == "SECURITY-GO"` has not been re-established. The B3–B7 descope is a human risk-acceptance decision recorded by the gate (not by this review); this report does not grant it and cannot upgrade the failed security gate.

## 1. Change summary

### 1.1 Workflow artifact chain

| Phase | Artifact | Status / decision |
|---|---|---|
| define-requirements | `.ai-sdd/outputs/define-requirements.md` (published as `requirements.md`, v1.0, 2026-03-03; 46 FR, 32 NFR) | COMPLETED |
| design-l1 / design-l2 | `.ai-sdd/outputs/design-l1.md`, `design-l2.md` | COMPLETED |
| review-l2 | `.ai-sdd/outputs/review-l2.md` | COMPLETED (GO) |
| security-design-review | `.ai-sdd/outputs/security-design-review.md` (STRIDE, THREAT-001…010) | COMPLETED — GO with conditions: BLOCKER-1 (`:370`), BLOCKER-2 (`:384`), BLOCKER-3 (`:398`); REC-1…REC-8 (`:413-455`) |
| plan-tasks | `.ai-sdd/outputs/plan-tasks/plan.md` — 39 parent tasks / 50 task IDs / 9 groups; rework stream T-049/T-050 added by `98a5e22` | COMPLETED |
| implement | `specs/implement-notes.md` — scoped to T-042 (plugin `transcript` contract + plugin-architecture guide truth-up), landed as `6e3eb93` | COMPLETED |
| review-implementation | `specs/review-implementation.md` | COMPLETED — **GO** for T-042 (2672 tests, 0 failures) |
| security-test | `specs/security-test.md` | **SECURITY-NO_GO** — B1–B7; exit condition not met; state nonetheless records COMPLETED (see 1.4) |
| final-sign-off | this document | **NO_GO** |

### 1.2 What the implementation actually delivered

- The product is a native Swift iOS app (`ios/ElderlyAssistant/`, 194 unit-test files under `ios/ElderlyAssistantTests/`); the Android tree is dormant scaffolding (no Android tests run in this workflow). This is a governance deviation from the constitution's "React Native" resolution (Open Decision 4, `constitution.md:103`); the product repo's constitution is not amended on this point.
- The implementation phase of record for this workflow is **T-042**: both `PluginCommand` dispatch paths route through `makePluginCommand` (`CommandRouter.swift:2302`, `:2340`, helper at `:2376`), which applies `InputSanitiser.sanitise(..., level: .quarantine)` (`:2380`); `docs/plugin-architecture.md` was truthed-up; the dead key `plugin.applianceHelper.notReady` was removed. Regression tests at `CommandRouterTests.swift:262` and `:295`. Reviewed GO at 0.90 (`specs/review-implementation.md:3,151,179`).
- The latest landed app-code change is `34c81b9` ("ship the gate-passing 4B intent brain"): `defaultBrainModelID = ModelCatalog.intentQwen4BS43` (`AppCoordinator.swift:1170`) with a LAN-hosted model entry (`ModelCatalog.swift:546`). This is the app-code delta since the security test's reviewed revision.
- The rest of the app (voice pipeline, interpreters, medication scheduler, alarms, contacts, plugins) predates this workflow window and is the subject of the security test; its coverage by the workflow's implement/review chain is T-042 only. Do not read the T-042 GO as app-wide approval.

### 1.3 What is defined but not delivered

- **T-049/T-050 (B1/B2 remediation): task definitions only.** `git show --stat 98a5e22` = `plan.md` + `T-049` + `T-050` + two task indexes only, no Swift. At HEAD the defects B1 and B2 are unchanged (re-verified below).
- T-045…T-048, T-039…T-044, TG-08 (T-033–T-038): planned, not implemented (plan.md risks 24–27).
- Android: not exercised; deferred.

### 1.4 Workflow-state integrity note

`security-test` failed its exit condition (`review.decision == "SECURITY-GO"`, `default-sdd.yaml:118-119`) but `workflow-state.json:98-109` records it COMPLETED and the workflow advanced to `final-sign-off`. The commit that mirrored the failure (`be37f5d`) states it plainly: "workflow-state: security-test COMPLETED (9/10); final-sign-off PENDING (not run — exit condition unmet, engine does not enforce it)". This is a mechanical state record, not a passed gate. `plan.md:96` records the substantive block: "final-sign-off remains blocked until those findings are either remediated under their own tasks or explicitly descoped by a human decision recorded as an Open Decision (constitution.md:93)."

## 2. Requirements traceability

Statuses: **MET** (implemented and evidenced), **PARTIAL** (some evidence, requirement not demonstrably satisfied), **UNMET** (absent or violated, with evidence), **UNVERIFIED** (no evidence either way in this review — not a pass). Implementation evidence is at `98a5e22`; the security test's evidence is pinned to `fb6e03c` plus the delta stated in the header.

### 2.1 Functional requirements (46 rows)

| ID | Requirement (abbreviated) | Planned task(s) | Implementation evidence at 98a5e22 | Test evidence | Status |
|---|---|---|---|---|---|
| FR-001 | On-device STT; no audio to cloud | T-009, T-022 | On-device engines exist (`WhisperSpeechRecognizer.swift`, `WhisperKitSpeechRecognizer.swift`); default stack `.gemini` (`AppCoordinator.swift:1612-1613`) sends WAV audio (`GeminiSpeechRecognizer.swift:113,118,129`) | Gate green but nothing tests the no-cloud-audio contract | UNMET |
| FR-002 | On-device TTS in configured language | T-012 | TTS stack present (`Services/Voice/Speaker.swift`, `SpeakQueue.swift`; sherpa/Piper references); Nepali voice availability not verified at HEAD; prior review: broken (`docs/review-2026-08-30.md:79-83`) | None cited | UNVERIFIED |
| FR-003 | Bilingual Nepali/English, remote-updatable | T-012 | Language hint/settings exist (`IntentPrompt.swift:71-87`, SettingsView language row); remote update depends on absent remote config | None cited | PARTIAL |
| FR-004 | Always-on wake word incl. locked screen | T-005 | `WakeWordEngine.swift` present; wake word landed per `OPEN-ITEMS.md` table row #4 (`95b7ff7`); product constitution defers wake activation for the iOS MVP (`product constitution:50`, diverges from SDD `constitution.md:50`) | None for locked-screen always-on | PARTIAL |
| FR-005 | Accent/dialect personalisation | T-009, T-011 | No accent-tuning implementation found (grep "accent" hits UI copy only; research docs) | None | UNMET |
| FR-006 | TTS spoken in configured language | T-012 | As FR-002 | None | UNVERIFIED |
| FR-007 | On-device LLaMA; no cloud LLM ever | T-018, T-033–T-038 | On-device interpreter exists (`LlamaCommandInterpreter.swift`); shipped default is a Qwen3 fine-tune (`intentQwen4BS43`, `AppCoordinator.swift:1170`) and default stack calls Gemini (`:1613`) | `BrainModelSelectionTests` assert wiring, not the requirement | UNMET |
| FR-008 | NLU/entity/response within latency | T-018, T-021, T-033–T-038 | Interpreters + `IntentRouter` present; training-side eval shows on-device model failed §10 gates as of 2026-09-07 (`OPEN-ITEMS.md` #6); `34c81b9` claims a now-passing 4B brain | Trainer eval harness; not in the iOS unit gate | PARTIAL |
| FR-009 | LLM not a dependency for safety paths | T-018, T-024, T-026 | Keyword safety net runs before any model (`CommandRouter.swift:567,1435` keyword; `:2117` LLM-path emergency) and is unit-tested; emergency dispatch module absent (B4) | `CommandRouterSafetyNetTests.testEmergencyKeywordFiresBeforeConfidentInterpreter` | PARTIAL |
| FR-010 | Per-user context loaded into prompt | Not mapped in plan | `IntentPrompt` builds context incl. pending meds (`IntentPrompt.swift:71-87`); enrolled-voice reference in prompt unverified | None cited | PARTIAL |
| FR-011 | Voice biometric enrolment; secure storage only | T-014 | Enrolment + verification service present with Keychain `WhenUnlockedThisDeviceOnly` storage (`VoiceBiometricStore.swift:6`; `KeychainEncryptedStorage.swift:82`); embedder is MFCC today, ECAPA candidate (`SpeakerBiometricService.swift:12-14`); security test rates the storage bullet met (`security-test.md:100`) | Not cited | PARTIAL |
| FR-012 | Verify before sensitive commands | T-014, T-016, T-017 | NOT WIRED (`SpeakerBiometricService.swift:16-20`); no production `.verify(` callers; `handleCall` proceeds on confirmation alone (`CommandRouter.swift:2224-2244`) | None | UNMET |
| FR-013 | Voice biometric primary; PIN not default | T-014, T-017 | No wired gate (B3) | None | UNMET |
| FR-014 | PIN fallback, salted hash after 3 failures | T-016 | No PIN code (no Argon2/bcrypt anywhere); BLOCKER-2 open (`security-design-review.md:384`) | None | UNMET |
| FR-015 | Re-enrol prompt after PIN | T-017 | Absent | None | UNMET |
| FR-016 | Messenger voice call by voice | Not mapped in plan | `handleCall` + contact resolution (`CommandRouter.swift:2224`); `fb-messenger://` deep link (`AppCoordinator.swift:4619-4627`); executes on confirmation alone; "trial wiring" comment (`CommandRouter.swift:2218-2223`) | None cited | PARTIAL |
| FR-017 | Messenger video call | Not mapped | `callType = "video"` parsed (`IntentPrompt.swift:185`; UI at `LeafViews.swift:2595`); placement unverified | None | UNVERIFIED |
| FR-018 | Answer incoming call by voice | Not mapped | No incoming-call handling found | None | UNMET |
| FR-019 | Deep link / OS integration, no screen interaction | Not mapped | `fb-messenger://` / `whatsapp://` link opening (`AppCoordinator.swift:4627`, `LeafViews.swift:1057`); still confirmation-gated | None | PARTIAL |
| FR-020 | Unresolved contact: inform, never call | Not mapped | `command_call_contact_not_found` + spoken `router.call.contactNotFound` (`CommandRouter.swift:2235-2237`) | None cited | PARTIAL |
| FR-021 | Google Calendar read/write | Not mapped | No Google Calendar API code (grep); only EventKit (`Services/CalendarSync/EventKitCalendarGateway.swift`) | None | UNMET |
| FR-022 | Calendar query by voice | Not mapped | EventKit-backed calendar services exist; voice path unverified | None | UNVERIFIED |
| FR-023 | Add event by voice + confirm | Not mapped | Unverified | None | UNVERIFIED |
| FR-024 | General reminders, voice delivery | Not mapped | `Services/Reminders/RoutineScheduler.swift`, `Services/Alarms/AlarmTimersService.swift` | `AlarmTimersServiceTests.swift` etc. | PARTIAL |
| FR-025 | Reminder persistence across restarts | Not mapped | `RoutineStore.swift` + persistence code | Not verified | PARTIAL |
| FR-026 | Medication reminders naming med | T-028 | `Services/MedicationScheduler/MedicationScheduler.swift`, `EscalationEngine.swift`; prior review C1: background execution broken (dated 2026-08-30) | `MedicationSchedulerTests.swift`, `EscalationEngineTests.swift` | PARTIAL |
| FR-027 | Re-fire 5× / 60 min window | T-028 | `EscalationEngine` implements refire logic | `EscalationEngineTests.swift` | PARTIAL |
| FR-028 | Family alert after window + missed-dose log | T-028 | Alert path is a silent stub (`FamilyNotifier.swift:109-114`, B6); broker absent | None for delivery | UNMET |
| FR-029 | Ack persisted immediately; re-fire after kill | T-028 | Persistence code present; process-kill re-fire unverified | `MedicationSchedulerTests.swift` (not pinned to process-kill) | PARTIAL |
| FR-030 | Family views adherence log | Not mapped | Companion app absent (no companion target/type found) | None | UNMET |
| FR-031 | HealthKit / Health Connect monitoring | T-024 | No HealthKit code at HEAD (grep empty; `security-test.md:130`; `docs/review-2026-08-30.md:65-67`: 0%) | None | UNMET |
| FR-032 | Configurable thresholds | T-024 | No threshold code | None | UNMET |
| FR-033 | Emergency sequence (alert → 30 s → call) | T-026 | Absent; `handleEmergency` posts a local notification and speaks an ack only (`CommandRouter.swift:2213-2216`); comment concedes no module exists (`:2211-2212`) | None | UNMET |
| FR-034 | Dispatch isolated from LLM | T-026 | No dispatch module; keyword net isolation implemented and tested | `CommandRouterSafetyNetTests` (net only) | UNMET |
| FR-035 | Monitoring failure alert | T-026 | Absent (no monitoring) | None | UNMET |
| FR-036 | Cancel emergency by voice | T-026 | Absent (no countdown) | None | UNMET |
| FR-037 | Emergency data encrypted at rest | Not mapped | No emergency-data model; encrypted storage layer exists but unused for this | None | UNMET |
| FR-038 | Family companion app | T-030, T-032 | Absent (design only) | None | UNMET |
| FR-039 | E2E config payloads | T-030 | Absent (no Signal/Double-Ratchet code; `security-test.md:132`) | None | UNMET |
| FR-040 | Apply config immediately + voice confirm | T-031 | Absent | None | UNMET |
| FR-041 | Decrypt + validate before apply | T-031 | Absent | None | UNMET |
| FR-042 | In-app config requires auth | T-031 | Settings screens exist; auth gate absent (B3) | None | UNMET |
| FR-043 | Single on-device user profile | T-032 | Multiple on-device stores (contacts, meds, voice template, prefs); single profile object unverified | None cited | PARTIAL |
| FR-044 | Re-enrolment without reset | T-032 | Enrolment/verification APIs support re-enrol; no UI-flow evidence | None | PARTIAL |
| FR-045 | Reminder style + TTS characteristics prefs | T-032 | `TTSVoicesSettingsView` (`SettingsView.swift:181`); reminder style unverified | None | PARTIAL |
| FR-046 | Profile on-device; cloud only as required | T-032 | Violated by default: audio + pending med names to Gemini (B7; `GeminiSpeechRecognizer.swift:113,118,129`; `IntentPrompt.swift:154-156,166`) | None | UNMET |

### 2.2 Non-functional requirements (32 rows)

| ID | Requirement (abbreviated) | Planned task(s) | Implementation evidence at 98a5e22 | Test evidence | Status |
|---|---|---|---|---|---|
| NFR-001 | STT latency ≤ 2 s | T-009, T-022, T-045 | No measured evidence in this corpus | None | UNVERIFIED |
| NFR-002 | LLM latency ≤ 4 s | T-018, T-022, T-045 | No measured evidence | None | UNVERIFIED |
| NFR-003 | Wake-word latency ≤ 1 s | Not mapped | No measurement | None | UNVERIFIED |
| NFR-004 | Emergency response ≤ 3 s | T-024 | No module (B4) | None | UNMET |
| NFR-005 | Med reminder within 30 s | Not mapped | No measurement | None | UNVERIFIED |
| NFR-006 | 24/7 responsive incl. locked screen | T-005, T-007 | Prior review C1: background execution broken (dated); product constitution narrows to v2 wake activation | None | UNMET |
| NFR-007 | Background-mode compliance iOS/Android | T-005, T-007 | No evidence | None | UNVERIFIED |
| NFR-008 | Safety services auto-restart | Not mapped | No evidence | None | UNVERIFIED |
| NFR-009 | Biometric data in secure storage only | Not mapped | Keychain `WhenUnlockedThisDeviceOnly` (`KeychainEncryptedStorage.swift:82`; `VoiceBiometricStore.swift:6`); `security-test.md:100` | None cited | MET |
| NFR-010 | PIN salted hash; never plaintext/logged | T-050 (per plan) | Absent (B3) | None | UNMET |
| NFR-011 | TLS 1.2+ on all outbound | T-014, T-050 | Cleartext HTTP model URLs ship (`ModelCatalog.swift:546,651`; B5); ATS scoped allowance `NSAllowsLocalNetworking` (`Info.plist:107`) | None | UNMET |
| NFR-012 | E2E config with forward secrecy | T-030 | Absent (B5) | None | UNMET |
| NFR-013 | Quarantine sanitisation at all entry points | T-020 | Verified at every LLM boundary (`GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, `LocalIntentInterpreter.swift:101`) and plugin path (`CommandRouter.swift:2376-2384`) | `InputSanitiserTests`; `security-test.md:98` | MET |
| NFR-014 | STRIDE produced and approved pre-implementation | Not mapped | Produced (`security-design-review.md`); BLOCKER-1/2/3 conditions remained open while implementation proceeded | n/a | PARTIAL |
| NFR-015 | No personal data to cloud for AI | T-002, T-004, T-034, T-036 | Violated by default Gemini stack (B7) | None | UNMET |
| NFR-016 | No PII in logs; sanitiser strips it | T-004, T-042, T-049, T-050 | Violated: B1 (raw transcripts to console) and B2 (key/raw body into `error_code`) open at HEAD | Unit gate green; nothing tests the leak paths | UNMET |
| NFR-017 | Health data minimisation | Not mapped | No HealthKit code exists (nothing to minimise yet) | None | UNMET |
| NFR-018 | Only required permissions, point-of-use | Not mapped | Usage strings exist in `Info.plist`; point-of-use flow not audited; REC-6 (Android) unverified | None | UNVERIFIED |
| NFR-019 | Every function voice-accessible | Not mapped | Voice-first app, but no complete audit | None | UNVERIFIED |
| NFR-020 | 44×44 pt touch targets | Not mapped | No audit | None | UNVERIFIED |
| NFR-021 | ≥ 18 pt body text | Not mapped | No audit | None | UNVERIFIED |
| NFR-022 | WCAG AA contrast | Not mapped | No audit | None | UNVERIFIED |
| NFR-023 | All strings externalised | T-042–T-044 | `Localizable.xcstrings` (439 KB) is the resource; T-042 removed one hardcoded dead key; no full sweep | Spot checks in `review-implementation.md` | PARTIAL |
| NFR-024 | Nepali + English at launch (STT/TTS) | Not mapped | Resources + language hint present; end-to-end Nepali unverified (dated C10) | None | PARTIAL |
| NFR-025 | Language packs without code changes | T-040 | Design claims plugin support; implementation unverified | None | UNVERIFIED |
| NFR-026 | 100% coverage safety-critical paths | T-024, T-026, T-028 | Emergency paths absent; coverage never instrumented (`security-test.md:177`) | `EscalationEngineTests` etc. exist | UNMET |
| NFR-027 | Med persistence abnormal-termination test | T-028 | Process-kill test not evidenced | `MedicationSchedulerTests` (scope unverified) | UNVERIFIED |
| NFR-028 | Emergency sequence E2E tests | T-026 | Absent | None | UNMET |
| NFR-029 | Confidence 0.85; 5 rework max | Not mapped | Workflow config enforces (`default-sdd.yaml:53,105,107`); T-042 review GO at 0.90 | `review-implementation.md:151` | MET |
| NFR-030 | App Store 5.1.1 / 5.1.3 compliance | Not mapped | No submission; cloud-audio tension (B7); no app-target privacy manifest found | None | UNVERIFIED |
| NFR-031 | Play sensitive-permissions policy + disclosure | Not mapped | Android dormant; no disclosure evidence (REC-6 open) | None | UNVERIFIED |
| NFR-032 | In-app privacy policy | Not mapped | Privacy settings section exists (`SettingsView.swift:19,136`; key `settings.privacy.title`); policy content not reviewed | None | UNVERIFIED |

### 2.3 Traceability totals and gaps

- Rows: **78** (46 FR + 32 NFR). MET: **3** (NFR-009, NFR-013, NFR-029). PARTIAL: **20**. UNMET: **34**. UNVERIFIED: **21**. Nothing is "rounded up": FR-001/FR-007/FR-046 are marked UNMET despite substantial code, because the default configuration violates them.
- Plan-level gap: `plan.md`'s traceability table maps no task to **FR-010, FR-016–FR-025, FR-030, FR-037** (13 FRs) or to **NFR-003, NFR-005, NFR-008, NFR-009, NFR-014, NFR-017–NFR-022, NFR-024, NFR-029–NFR-032** (16 NFRs). Several of these are implemented anyway (e.g. NFR-009), but the plan does not trace them — a plan-to-requirements traceability gap to fix in the next plan revision.
- Untraced features in the opposite direction: the cloud voice stack (Gemini STT/interpreter) has no FR/NFR or design-corpus entry (see B7 and `security-test.md:142`).

## 3. Security posture

### 3.1 Security design review (2026-03-04)

STRIDE model with THREAT-001…THREAT-010; decision "GO with conditions". The conditions were never closed before implementation: **BLOCKER-1** PAD/liveness for voice biometrics (`security-design-review.md:370`), **BLOCKER-2** PIN lockout policy (`:384`), **BLOCKER-3** initial device pairing + health-threshold bounds (`:398`). All three remain open at HEAD — BLOCKER-1/2 have no code (B3), BLOCKER-3 has no remote-config/pairing code at all (B5). REC-5's adversarial blocklist is implemented; REC-1/3/4/6/7/8 unverified or depend on absent modules.

### 3.2 Security test result (of record)

`specs/security-test.md`: **SECURITY-NO_GO**. Five of the categories mapped fail (auth bypass; PII in logs; secrets in output; error leakage; and the voice/emergency/remote-config focus areas), blocking findings **B1–B7**, and the workflow exit condition `review.decision == "SECURITY-GO"` is **not met** (`security-test.md:13-15`). The workflow state nevertheless records `security-test` COMPLETED (`workflow-state.json:98-109`) — mechanically advanced by the engine, as `be37f5d` itself documents. That record is not a passed gate.

### 3.3 Finding status re-verified at HEAD 98a5e22

| Finding | Status at 98a5e22 | Re-verified evidence | Gate effect |
|---|---|---|---|
| B1 — raw transcript prints in Release | **OPEN** | `WhisperSpeechRecognizer.swift:815` (`print("[whisper_stt] transcript=" + joined)`, with the `:811-814` comment conceding it bypasses the sanitised bus) and `WhisperKitSpeechRecognizer.swift:488`; `:493` also prints the raw error; neither file contains any `#if DEBUG` (only `#if canImport`) | **BLOCKING** |
| B2 — Gemini API key / raw upstream body into logs via `error_code` | **OPEN** | Key in URL query (`GeminiClient.swift:230,395`); transport errors rethrown untouched (`:259-263`, `:414-418`); `httpError` retains raw body (`:53`, thrown `:428-429`); six stringify sites (`GeminiClient+Vision.swift:117`, `ApplianceHelperSession.swift:190`, `NepaliCalendarPlugin.swift:90`, `GeminiSpeechRecognizer.swift:139`, `GeminiCommandInterpreter.swift:107`, `VoicePipeline.swift:855`); `LogSanitiser` copies `errorCode` unscrubbed (`LogSanitiser.swift:59`; allow-listed `:30`; scrub patterns `:37-47` cover phone/e-mail/BP only) | **BLOCKING** |
| B3 — sensitive-action biometric/PIN auth unwired | **OPEN — DESCOPED by T2 decision** | `SpeakerBiometricService.swift:16-20` NOT WIRED; no production `.verify(` callers; no PIN/Argon2/bcrypt code; `handleCall` proceeds on confirmation alone (`CommandRouter.swift:2224-2244`); deterministic layer fails closed (`:1489-1490`) | Descoped; residual risk recorded in §4 |
| B4 — no emergency-call module | **OPEN — DESCOPED** | `handleEmergency` posts a local notification + speaks ack only (`CommandRouter.swift:2213-2216`) | Descoped; residual risk in §4 |
| B5 — remote-config chain absent; cleartext LAN URLs | **OPEN — DESCOPED** | No Signal/WebSocket/config types; cleartext `http://192.168.1.117:8765/...` at `ModelCatalog.swift:546` (the current default brain's URL) and `:651` | Descoped; residual risk in §4 |
| B6 — alert stubs return success silently | **OPEN — DESCOPED** | `APNsProvider.sendPush` prints a token prefix, returns `true` unconditionally (`FamilyNotifier.swift:109-114`) | Descoped; residual risk in §4 |
| B7 — cloud stack vs constitution Privacy bullet | **OPEN — DESCOPED** | Default `.gemini` (`AppCoordinator.swift:1613`); WAV audio sent (`GeminiSpeechRecognizer.swift:113,118,129`); pending medication names embedded in the audio-path prompt (`IntentPrompt.swift:154-156,166`) | Descoped; residual risk in §4 |

- Remediation status: B1/B2 have task definitions only (T-049, T-050 — `98a5e22`); no Swift change landed. T-049/T-050 would not cover B3–B7 (`plan.md:94-96`).
- Revision effect: the test was authored at `fb6e03c`; HEAD `98a5e22` adds only `34c81b9` in app code (already assessed in the report's revision note — it added the second B5 URL at `:546` and made it the default brain's URL) plus two SDD-only commits. No finding changes.

## 4. Open items

### 4.1 Blocking (must be remediated before sign-off)

| Item | Detail | Owner / next step |
|---|---|---|
| B1 | Release builds print every recognised utterance verbatim (medications, symptoms, family names, emergency phrases) to the device console; retrievable via sysdiagnose. Fix = T-049 (guard/remove, keep PII-free counters). | T-049 |
| B2 | Gemini API key and raw upstream bodies reach the console through `error_code` on any offline/DNS/TLS/timeout failure. Fix = T-050 (key out of URL, stop `String(describing:)`, bound `error_code`, drop raw bodies). | T-050 |
| Security gate | `security-test` must be re-run and return `SECURITY-GO` at the fixed revision. | workflow |

### 4.2 Descoped by human T2 decision (reported during this review; record in `constitution.md` pending)

The orchestrator reported the human risk-acceptance decision descoping B3–B7. At the time this report was written the entry was **not yet present** in `constitution.md` (Open Decisions unchanged; file unchanged since 2026-05-23) — sign-off evidence should include the landed entry. Residual risk per descoped finding:

| Descoped finding | Residual risk accepted |
|---|---|
| B3 | Sensitive voice commands (calls; config; health-data actions once they exist) execute **without** biometric or PIN verification; the LLM-interpreted call path acts on confirmation alone (`CommandRouter.swift:2224-2244`). A replayed or synthetic voice can trigger them. THREAT-001 replay/PAD and BLOCKER-1/2 remain unresolved design debt. |
| B4/B6 | An emergency utterance produces only a spoken acknowledgement and a local notification (`CommandRouter.swift:2213-2216`) — no call dispatch, no countdown, no family alert. Family-alert callers that trust `sendPush`'s return value will report success for alerts that were never sent (`FamilyNotifier.swift:109-114`); the stub must fail closed when finally wired. |
| B5 | Remote configuration does not exist (no E2E channel, no pairing). The brain catalogue ships cleartext HTTP LAN model URLs (`ModelCatalog.swift:546,651`); downloads are unauthenticated and unencrypted on the LAN (SHA-256 checks integrity, not confidentiality), and the current default brain is LAN-hosted (`34c81b9`), so the default configuration cannot fetch its model off that LAN. |
| B7 | The default stack transmits user audio and pending medication names to Gemini (`GeminiSpeechRecognizer.swift:113,118,129`; `IntentPrompt.swift:154-156,166`) against `constitution.md:74`. Consent/disclosure design is not recorded; the Settings disclosure is only "Gemini uses the internet". If this ships, the constitution Privacy bullet must be amended with the recorded exception (or the default changed). |

### 4.3 Other known issues / deferred items

- Constitution divergence (product vs SDD): three lines differ — architecture constraint 4, Open Decision 5 (remote config), Open Decision 10 (wake word). The SDD `constitution.md` is the workflow's acceptance criteria and was not amended.
- React Native vs native Swift: Open Decision 4 (`constitution.md:103`) says React Native; the product is native Swift. Governance drift, needs a recorded resolution.
- Open Decisions unresolved: HIPAA assumed not applicable, GDPR deferred, data residency unspecified, WhatsApp integration method open (`constitution.md:97-113`).
- Android dormant: no tests run; B6's FCM mirror is unverified.
- Default brain is LAN-hosted (`ModelCatalog.swift:546`) and the shipped picker offers LAN-only entries (`plan.md:76`); T-048 is planned to decide hosting vs hiding.
- Telemetry is console-only with no durable audit trail (`security-test.md` observation 4); no crash reporting or monitoring pipeline identified.
- Compliance artifacts: no app-target `PrivacyInfo.xcprivacy` found; no evidence of App Store/TestFlight submission or of a privacy-policy review.
- Evidence freshness: `docs/review-2026-08-30.md` is a dated source; `security-test.md` observation 8 lists its stale claims that must not be re-used.

### 4.4 Post-deploy monitoring (requirements before any release)

There is no production deployment, so this is a forward requirement list: (1) after B1/B2 fixes, verify on a Release build and a real device that no transcript/key material appears in the device console or sysdiagnose; (2) re-run the security test for `SECURITY-GO`; (3) define crash/telemetry retention and an alert on anomalous log volume; (4) monitor model-download failures once the hosting decision lands; (5) monitor medication reminder delivery once background execution is re-verified.

## 5. Rollback plan

There is no production deployment: no fastlane/App Store submission machinery exists; `ios/build.sh ipa` (`build.sh:15-17,201`) is the only release-artifact path. Rollback is therefore currently at three levels:

1. **Do not ship (recommended).** The current build must not be handed to real users while B1/B2 are open. If a tester build exists, expire it (TestFlight builds expire/replace; no user-facing rollback needed).
2. **App code.** The window's changes are individually revertible:
   - `git revert 34c81b9` — restores the previous default-brain wiring and removes the LAN cleartext entry; the in-app brain picker (`ModelCatalog.availableBrainEntries`) also allows switching away from the LAN brain without a revert.
   - `git revert 6e3eb93` — T-042 plugin-transcript change (reverts to the pre-fix empty/raw transcript behaviour; not recommended — it removes sanitisation from the plugin path).
   - T-049/T-050, when landed, are small independent diffs per `plan.md:94` and revert without touching the keyword safety net or router stage order.
3. **Forward-fix (the only App Store-safe option).** A released iOS binary cannot be downgraded by users; rollback for a shipped version is a hotfix build plus (ideally) a phased rollout. No phased-rollout mechanism exists yet; define one before release.

Trigger conditions for rollback: any transcript/key material observed in device logs; model fetch failures caused by the LAN-hosted default; medication reminder regressions. Rollback does not restore the failed security gate — B1/B2 must be fixed forward.

## 6. Compliance checklist

Verdicts: SATISFIED / NOT SATISFIED / UNVERIFIABLE, each with evidence. Descoped items are marked NOT SATISFIED with "descoped by T2 decision" so the acceptance is visible, not hidden.

### 6.1 App Store / Play Store

| Item | Verdict | Evidence |
|---|---|---|
| Apple Guideline 5.1.1 — Data Collection and Storage | NOT SATISFIED | Cloud audio + pending medication names by default (B7, descoped); no privacy-policy content review; no submission |
| Apple Guideline 5.1.3 — Health and Health Research | UNVERIFIABLE | No HealthKit integration exists (FR-031 absent); no submission; policy content unavailable |
| iOS Background Modes / 24-7 claim | NOT SATISFIED | No evidence of locked-screen always-on; prior review C1 (dated); product constitution defers wake activation |
| Privacy manifest / required-reason APIs | UNVERIFIABLE | No app-target `PrivacyInfo.xcprivacy` found (only vendored ZIPFoundation in build products); may not be required depending on APIs used |
| Permissions at point of use, plain language (`constitution.md:64`) | UNVERIFIABLE | Usage strings in `Info.plist`; point-of-use disclosure flows not audited |
| Play Sensitive App Permissions — Body Sensors, Contacts + prominent disclosure (NFR-031) | UNVERIFIABLE | Android tree dormant; no disclosure implementation; REC-6 unverified |
| Play health-app policies | UNVERIFIABLE | No Android build or submission evidence |

### 6.2 Constitution bullets (SDD `constitution.md`)

| Item | Verdict | Evidence |
|---|---|---|
| Constraint 1 — all AI on-device; personal data never leaves for AI | NOT SATISFIED | B7 (descoped): default `.gemini`; `GeminiSpeechRecognizer.swift:113,118,129`; `IntentPrompt.swift:154-156,166` |
| Constraint 2 — remote config E2E encrypted | NOT SATISFIED | B5 (descoped): no chain exists |
| Constraint 3 — voice biometric primary; PIN fallback only | NOT SATISFIED | B3 (descoped): gate unwired; no PIN |
| Constraint 4 — 24/7 always-on background service | NOT SATISFIED | As NFR-006; prior review C1; product constitution divergence |
| Constraint 5 — highly personalised on-device profiles | NOT SATISFIED | Partial stores; no single verified profile; cloud leaks by default (B7) |
| Constraint 6 — Nepali launch + language plugins | UNVERIFIABLE | Resources and training present; end-to-end Nepali unverified (dated C10) |
| Accessibility — voice-first, 44 pt, 18 pt, contrast | UNVERIFIABLE | No accessibility audit or tests found |
| Privacy — no personal data to cloud for AI | NOT SATISFIED | Same as constraint 1 (B7, descoped) |
| Privacy — health data minimisation | UNVERIFIABLE | No HealthKit code exists |
| Privacy — remote config E2E (keys on devices only) | NOT SATISFIED | B5 (descoped) |
| Privacy — logs must not contain PII; sanitiser required | NOT SATISFIED | **B1/B2 OPEN (blocking, not descoped)** |
| Security — biometric storage on-device (Secure Enclave / Keystore) | SATISFIED | Keychain `WhenUnlockedThisDeviceOnly` (`KeychainEncryptedStorage.swift:82`; `VoiceBiometricStore.swift:6`); `security-test.md:100` |
| Security — PIN salted hash, never plaintext | NOT SATISFIED | No PIN code (descoped under B3) |
| Security — emergency data encrypted at rest | NOT SATISFIED | No such data model (descoped under B4) |
| Security — TLS 1.2+ on all outbound | NOT SATISFIED | B5 (descoped): cleartext LAN URLs `ModelCatalog.swift:546,651` |
| Security — injection detection at `quarantine` | SATISFIED | `security-test.md` focus area GO; sanitiser at all LLM boundaries (NFR-013 row) |
| Security — STRIDE threat model produced | SATISFIED | `security-design-review.md`; BLOCKER-1/2/3 remain open (covered by descopes B3/B5) |
| Quality — 100% coverage safety-critical paths | NOT SATISFIED | Emergency paths absent; coverage not instrumented (`security-test.md:177`) |
| Quality — confidence 0.85 | SATISFIED | `default-sdd.yaml:105`; T-042 GO at 0.90 |
| Quality — paired review enabled | SATISFIED | `default-sdd.yaml:103`; `review-implementation.md` |
| Quality — max rework 5 | SATISFIED | `default-sdd.yaml:53,107` |

### 6.3 Reviewer checklist (standard)

| Check | Verdict | Evidence |
|---|---|---|
| Explicit error return types on interface methods | PASS | No interface change in T-042 (`review-implementation.md:84`); `GeminiClientError` enum (`GeminiClient.swift:49-56`); `PluginResult` with explicit `.failed` |
| Async/external calls have documented failure mode and recovery | FAIL | `APNsProvider.sendPush` returns success silently (B6, descoped); no retry/queue for family alerts; `plan.md` risk 3 |
| Timeouts/retries configurable, not hardcoded | PARTIAL | Gemini timeout configurable (`GeminiClient.swift:69,79,243,400`); `InputSanitiser.maxLength = 200` hardcoded (`InputSanitiser.swift:22`; `security-test.md` observation 1); APNs stub has neither |
| Every element traces to an FR/NFR | FAIL | Cloud voice stack untraced (B7); plan maps no task to 13 FRs / 16 NFRs (section 2.3) |
| Operator-visible behaviour on run and on failure | FAIL | Safety path: emergency yields an ack + local notification only (B4, descoped); family alert silent (B6, descoped). Other failure paths render localized text (`HomeView.swift:322-332` per `security-test.md:90`) |

## Verdict: NO_GO — not ready for sign-off

The evidence does not support sign-off. B1 and B2 are verified-open at `98a5e22`, ship in the current code, and have no landed fix; the security gate was never re-established after its SECURITY-NO_GO. The B3–B7 descope, once recorded as the human Open Decision it is reported to be, removes those five findings from the sign-off gate but leaves the residual risks in §4.2 on the record; it does not make B1/B2 acceptable.

Conditions that would flip this verdict:

1. T-049 and T-050 land with evidence: no transcript content in any build configuration outside the sanitised bus; no API key, URL, or raw upstream body reachable through `error_code`; the fix verified against the real error-handling path (per the T-049/T-050 acceptance criteria).
2. The `security-test` is re-run at the fixed revision and returns `SECURITY-GO` (restoring the workflow exit condition `review.decision == "SECURITY-GO"`).
3. The B3–B5/B6/B7 descope is present as a time-boxed entry in `constitution.md` Open Decisions (it was not yet in the file when this report was written); without that record, those findings remain open blockers under `plan.md:96`.
4. Constitution divergence (product vs SDD; React Native vs native Swift; cloud-stack exception or default change) is reconciled, and a Release-build console check plus post-deploy monitoring are defined.

Specific human decisions required at the T2 gate (this review cannot grant any of them):

- Accept or reject the B3–B7 risk acceptance as recorded (and confirm its time box and owners).
- Decide the constitution amendments: cloud voice-stack exception and consent/disclosure, the React Native vs native Swift resolution, and the wake-word deferral.
- Authorise the T-049/T-050 rework now; no further implementation work is meaningful for sign-off until B1/B2 are fixed.
- Defer release decision until condition 2 is met. A sign-off cannot be granted by advancing workflow state; it requires an explicit human decision on this document.
