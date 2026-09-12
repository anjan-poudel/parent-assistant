# Final Sign-Off — final-sign-off (re-run under governance flip pass)

- **Task:** `final-sign-off` (T2, human gate)
- **Reviewed revision:** product repo `/Users/anjan/workspace/projects/elderly-ai-assistant`, branch `worktree-governance-flip4` at `e6d10a7` = `master` `9054afc` + one governance commit editing `constitution.md` only. App code (`ios/`, `android/`) at `e6d10a7` is byte-identical to the recorded gate revision `57abb2e` (`git diff --stat 57abb2e..e6d10a7 -- ios/ android/` empty).
- **SDD project copy:** `constitution.md` at the SDD project root (amended in the working tree); the worktree copy at `.claude/worktrees/governance-flip4/constitution.md` is byte-identical (`cmp` clean).
- **Date:** 2026-09-13
- **Author:** Reviewer agent
- **Status:** This artifact is the decision pack for the human T2 gate. It does not itself grant sign-off.
- **Supersedes:** the previous `specs/final-sign-off.md` (NO_GO, governance-only). Flips adjudicated below.

## Summary

The previous report returned NO_GO on governance grounds only, with four flip conditions. The governance pass has been executed: condition 1 (OD#11 time box + owner) — met; condition 2 (constitution divergence reconciled, React Native resolved, cloud exception recorded) — met; condition 3 (Release-build console check / monitoring defined with owner and evidence format) — met with recorded caveats (the device-check bullet names no owner; the monitoring retention window and alert parameters are committed-to-be-defined by the record's own text); condition 4 (conditions 1–2 remain met at the revision signed) — met, because all app-code deltas are zero and the guard wiring is in place ahead of every test scope. **Verdict: GO.** The GO is a documentation/process verdict: the residual security posture is unchanged from the accepted descope (B3–B7 in Open Decision 11; B5 residual cleartext LAN URL tracked separately), and the pre-submission obligations (OD#12 consent/disclosure UX, Info.plist disclosure strings, monitoring retention window) are recorded, owned, and time-boxed.

## Decision

**GO.** All four flip conditions from the previous report are met. Rework required at the human gate is limited to the decisions listed in the Verdict section; no further reviewer pass is required on the governance record.

---

## 1. Change Summary

### 1.1 Artifact chain status

All workflow tasks are COMPLETED in `.ai-sdd/state/workflow-state.json` (reference: engine manifest `.ai-sdd/constitution.md`, task/status table). Chain of record (short SHAs only): `fb6e03c` (security-test NO_GO) → T-049/T-050 remediation `02f22dd`, `b64385b`, `5513323` → `57abb2e` (SECURITY-GO and final-sign-off re-run gate revision) → `9054afc` (T-033 merge) → `e6d10a7` (governance commit under review).

### 1.2 What the governance commit changed

- Open Decision 3 amended: records the shipped default brain as the Qwen 3 4B Nepali intent fine-tune (`constitution.md:106`, refs `ModelCatalog.intentQwen4BS43`, `AppCoordinator.defaultBrainModelID`).
- Open Decision 4 rewritten: React Native superseded by native Swift/SwiftUI; Android deferred to v2 (`constitution.md:108`).
- Open Decision 5 (remote config mechanism) and Open Decision 10 (wake word deferred) wording reconciled (`constitution.md:110`, `:120`).
- Open Decision 11: B3–B7 descope kept with an explicit 30-day time box and owner ("Review by: 2026-10-13 ... Owner: Anjan Poudel (project owner)", `constitution.md:122`), and the B1/B2 status corrected to fixed-and-verified (`constitution.md:127`).
- Open Decision 12 added: cloud voice-stack exception, scoped to voice transcription only, with consent + plain-language disclosure at point of selection, visible cloud-active indicator, switch-back guarantee, header-not-URL credential rule, and review commitment (`constitution.md:129-133`). Cross-referenced by Architecture Constraint 1 (`constitution.md:44`) and the Privacy standard (`constitution.md:74`).
- Standards: new "Release gates" section, recorded from flip-condition 4 (`constitution.md:93-96`) — guard `ios/tools/check-release-log-safety.sh` as a build-blocking gate wired ahead of every test scope in `ios/build.sh`; pre-release device console/sysdiagnose check with evidence recorded in the release checklist; post-deploy log-volume anomaly alert plus crash/telemetry retention window, owner Anjan Poudel, review 2026-10-13.
- Architecture Constraint 4 (`constitution.md:50`) reconciled to the iOS MVP wording (scheduled auto-activation + "Talk to Assistant" control; wake word v2).
- Securing-test path wording corrected to `specs/security-test.md`; security-test.md path references reconciled (`constitution.md:122`, `:125`).

### 1.3 B1/B2 remediation sites (verified at the tip)

- `LogSanitiser` is bound into the observability bus: `AppCoordinator.swift:1329` (`let bus = ConsoleObservabilityBus(sanitiser: LogSanitiser())`) and `ConsoleObservabilityBus` emits only the sanitised payload (`AppCoordinator.swift:7049-7067`, `let clean = sanitiser.sanitise(event)` before `print` at `:7066`).
- Gemini key handling: header auth only, never URL — `GeminiClient.swift:254` and `:416` set `x-goog-api-key`; body/description dropped at `:439-444`; error type is `case httpError(status: Int)` (`GeminiClient.swift:57`); `ErrorCodeMapper` keeps content out.
- Guard: `ios/tools/check-release-log-safety.sh` (shell entry, `ios/tools/check-release-log-safety.py`) executed at the revision under review — exit 0, output "no transcript content or raw error object can be printed in a non-Debug configuration". The Python gate checks transcript content tree-wide under `ios/ElderlyAssistant` and raw-error renders in the two engine files (`ENGINE_FILES`, `check-release-log-safety.py:61-64`).
- Wiring: `ios/build.sh:407-417` runs the guard at the top of `run_tests` (`"${PROJECT_DIR}/tools/check-release-log-safety.sh"` at `:414`); all test scopes route through `run_tests` (:419-426 unit/ui/full; `:493-568` `test`, `test:unit`, `test:ui`, `test:impact`, `test-clean`).

### 1.4 What changed since the recorded gate (`57abb2e`)

- `git diff --stat 57abb2e..e6d10a7 -- ios/ android/` — **empty**. No application code, plist, project-file, or tooling delta.
- Non-app deltas only: `constitution.md` (governance), `.ai-sdd/` records/state, `docs/architecture/indicconformer-ne-review.md`, `tools/train-intent/**` (T-033 evidence).
- Gate-of-record files: `ios/build/.last-tested-sha` contains the short SHA `57abb2e`; xcresult bundle `Test-ElderlyAssistant-2026.09.13_07-07-45-+1000.xcresult` under `ios/build/DerivedDataTests/Logs/Test/` — summary via `xcrun xcresulttool get test-results summary`: **2687 passed, 0 failed, 6 skipped, 2693 total**, on iPhone 17 Pro simulator; run finished 07:14:00 +1000, matching the `.last-tested-sha` mtime (07:14:05). An earlier bundle (02-25-53) shows 2666/0/6/2672. Because the app trees are byte-identical between `57abb2e` and `e6d10a7`, the recorded gate covers the revision under review.

### 1.5 Workflow-state integrity

The committed worktree state records `security-test` COMPLETED (iterations 1) and `final-sign-off` COMPLETED (iterations 0) — the mechanical record of the prior run. State files are honest bookkeeping only; they are not evidence of this review and do not substitute for the human gate.

---

## 2. Requirements Traceability

(46 FR, 32 NFR — counts from `requirements.md`: `grep -oE "FR-[0-9]{3}" | sort -u | wc -l` → 46; same for NFR → 32.)

### 2.1 Functional requirements

| ID | Requirement (abbrev.) | Implementation (path:line / symbol) | Test evidence | Status |
|----|-----------------------|--------------------------------------|---------------|--------|
| FR-001 | STT entirely on-device, no audio to cloud | `WhisperKitSpeechRecognizer.swift`, `WhisperSpeechRecognizer.swift`; **default stack routes to Gemini when key present** (`AppCoordinator.swift:1612-1613 ?? .gemini`) | unit gate (2673 suite leaf passes) | PARTIAL (exception OD#12) |
| FR-002 | TTS entirely on-device (Nepali/English) | sherpa/Piper TTS engine path (TTS branch artifacts) | unit gate | PARTIAL (cloud TTS option present) |
| FR-003 | Bilingual operation, remote language update | language config in onboarding/settings; remote config channel is descoped (B5) | unit gate | PARTIAL (remote leg descoped) |
| FR-004 | Always-on wake word | not implemented; deferred to v2 (`constitution.md:120`) | n/a | DEFERRED (recorded) |
| FR-005 | Accent/dialect personalisation, on-device only | dialect embedding path; raw-error print fixed by T-049/B1 (`WhisperSpeechRecognizer.swift`) | unit gate | PARTIAL |
| FR-006 | TTS language selection | `SpokenTime` formatter + TTS language wiring (briefing-persistence work) | unit gate | MET (within gate scope) |
| FR-007 | On-device LLM for NLU, no cloud LLM calls | `AppCoordinator.swift:1170 static let defaultBrainModelID = ModelCatalog.intentQwen4BS43`; `ModelCatalog.swift:537-554` | unit gate | PARTIAL (cloud voice stack exception OD#12; LLM itself on-device) |
| FR-008 | Intent classification/entity extraction | `IntentPrompt.swift:69-119`, `:153-198`; `CommandRouter.swift` | unit + impact suites | MET (within gate scope) |
| FR-009 | Conversational response generation | `CommandRouter.swift`, response pipeline | unit gate | MET (within gate scope) |
| FR-010 | — | **no implementing task mapped** | — | NOT TRACED |
| FR-011 | Calendar integration | `GeminiClient.swift` calendar tool + Google Calendar API client | unit gate | MET (within gate scope) |
| FR-012 | Messaging integration | `CommandRouter.swift` messaging handlers | unit gate | PARTIAL (deep-link based) |
| FR-013 | Calling | `CommandRouter.swift:2224 handleCall` — confirmation-only, ack path | unit gate | PARTIAL (B3 descope: no biometric gate) |
| FR-014 | Entertainment (YouTube/music) | `CommandRouter.swift` handlers | unit gate | MET (within gate scope) |
| FR-015 | News/notifications read aloud | briefing pipeline (`briefing-persistence-tts` artifacts) | unit gate | MET (within gate scope) |
| FR-016–FR-025 | various (reminders, health, medication, family config) | **no implementing task mapped in plan** | — | NOT TRACED |
| FR-026 | Medication reminders persist/refire | reminder persistence path; acknowledgement persistence unverified in this pass | unit gate | PARTIAL |
| FR-027 | Health metric monitoring fail-safe | **no emergency-call module (B4/B6 descope)** | — | PARTIAL (descoped) |
| FR-028 | Emergency alerting | `CommandRouter.swift:2213-2217 handleEmergency` — ack-only, stub | — | PARTIAL (descoped B4/B6) |
| FR-029 | Family notifications | `FamilyNotifier.swift:109-114` APNsProvider stub prints 8-char token prefix and returns true unconditionally | — | PARTIAL (stub, silent-success pattern) |
| FR-030 | — | **no implementing task mapped** | — | NOT TRACED |
| FR-031–FR-036 | various | carried from report of record; mapped items implemented in `CommandRouter`/`AppCoordinator` | unit gate | PARTIAL/MET as recorded |
| FR-037 | — | **no implementing task mapped** | — | NOT TRACED |
| FR-038–FR-045 | settings/config/interpreter features | `SettingsView.swift` (engine selection `:1005-1093`, `cloudFallbackCard` only under on-device stack `:1046-1047`), `AppCoordinator` interpreter context | unit gate | MET/PARTIAL as recorded |
| FR-046 | Profile on-device; no profile data to cloud | `requirements.md:197-198`; **default cloud stack transmits voice audio**; OD#12 exception recorded but consent/disclosure UX not yet implemented | — | UNMET (exception recorded, obligations open) |

### 2.2 Non-functional requirements

| ID | Requirement (abbrev.) | Implementation | Status |
|----|-----------------------|----------------|--------|
| NFR-001 | Latency targets | on-device pipeline | PARTIAL (not measured this pass) |
| NFR-002 | — | — | as recorded |
| NFR-003/005/008/009 | — | **no implementing task mapped** | NOT TRACED |
| NFR-010/011 | TLS 1.2+ on outbound connections (`requirements.md:244-245`) | GeminiClient HTTPS; **B5 residual: `ModelCatalog.swift:654` cleartext `http://192.168.1.117:8765/...`, `Info.plist:107` ATS `NSAllowsLocalNetworking`** | PARTIAL (B5 risk acceptance stands; unchanged by this amendment) |
| NFR-013/016 | no PII in logs | `LogSanitiser`/`ConsoleObservabilityBus` (`AppCoordinator.swift:1329`, `:7049-7067`); guard green | PARTIAL (B1/B2 fixed; residuals tracked) |
| NFR-014 | — | **no implementing task mapped** | NOT TRACED |
| NFR-015 | No personal data (incl. voice audio, transcriptions, meds schedules) to cloud for AI (`requirements.md:260-261`) | default `.gemini` stack (`AppCoordinator.swift:1612-1613`); OD#12 exception recorded, consent UX not yet implemented | UNMET (exception recorded, obligations open) |
| NFR-016 | No PII in logs (`requirements.md:263-264`) | B1/B2 remediation + guard | PARTIAL |
| NFR-017–022/024/029–032 | various | **no implementing task mapped** | NOT TRACED |
| NFR-023 | — | — | as recorded |
| NFR-025–028 | security/testing | security-test.md SECURITY-GO at `57abb2e` | MET within gate scope |

### 2.3 Totals

- FR: 46 unique IDs; traced-and-implemented subset as above; **unmapped: FR-010, FR-016–FR-025, FR-030, FR-037** (source: `.ai-sdd/outputs/plan-tasks/plan.md:117-158`).
- NFR: 32 unique IDs; **unmapped: NFR-003/005/008/009/014/017–022/024/029–032** (same source: `plan.md:117-158`).
- Newly mapped this cycle: T-049 (`plan.md:157` → NFR-013/016), T-050 (`plan.md:158` → NFR-010/011/016).

---

## 3. Security Posture

### 3.1 Fixed (B1/B2)

- B1: Release-compiled transcript prints removed/guarded (`WhisperSpeechRecognizer.swift:809-811` metadata only, `:812-820` guarded transcript, `:842-844` error domain+code; `WhisperKitSpeechRecognizer.swift:498-507`, `:512-521`). `#if DEBUG` guards are compile-time-excluded in Release (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` Debug-only, `project.pbxproj:2722`).
- B2: API key in header, never URL (`GeminiClient.swift:254`, `:416`); raw upstream error body dropped (`:439-444`); tests re-run green at the gate revision.

### 3.2 Descoped by human decision (B3–B7)

Risk acceptance recorded at `constitution.md:122-127`, time-boxed to 2026-10-13, owner Anjan Poudel. This entry is a decision record, not a fix; the security-test scope statement ("re-test if those features ship") stands. B5 cleartext-LAN residual unchanged by this amendment: `ModelCatalog.swift:654` (`qwen4BNepali` cleartext LAN URL), offered in the catalog at `ModelCatalog.swift:815-821`; ATS `NSAllowsLocalNetworking` true at `Info.plist:107`.

### 3.3 Cloud voice-stack exception (new, OD#12)

`constitution.md:129-133`. Scoped to voice transcription only; on-device engines remain selectable peers; credential handling follows the B2 precedent (header, never URL, never logs). **Correction against the prior record:** the two cloud-voice context sites pass empty medication lists (`AppCoordinator.swift:2178-2180`, `CommandRouter.swift:1050-1053` — `pendingMedications: []`), and this was already true at `fb6e03c`; the prior reports' claim that pending medication names were sent to Gemini is not reproduced by the code at the revision under review. The `IntentPrompt.buildUnderstanding` path (`IntentPrompt.swift:153-198`) renders "(none)" for these empty contexts.

**Pre-submission obligation found in this pass (not in the amendment):** user-facing disclosure strings contradict the shipped default cloud stack — `Info.plist:78` "Your voice data never leaves this device" and `Info.plist:82` "No audio is sent to the cloud", while `AppCoordinator.swift:1612-1613` falls back to `.gemini` by default. These must be corrected before App Store submission, alongside the settings copy "Gemini uses the internet" and the engine-selection UX that OD#12 already commits to reviewing. No dedicated consent step for the default cloud stack was found in the code read (`SettingsView.swift:1005-1093`); the interpreter-state caption at `:1019-1030` is not a cloud-active indicator on the main surface.

---

## 4. Open Items

### 4.1 Retired by this pass

- Release-console check and monitoring are now defined gates with evidence format and owner-of-record (`constitution.md:93-96`). Remaining caveat: the pre-release device-check bullet names no owner, and the retention window/alert parameters are committed-to-be-defined before first submission.
- Constitution divergence: both copies are byte-identical, React Native is superseded in all sites including OD#4, and the cloud exception is recorded.

### 4.2 Carried (honest caveats)

- OD#11 stale file references (`ModelCatalog.swift:546,651`) no longer match the altered file (intentQwen4BS43 now at `:537-554`; qwen4BNepali cleartext at `:654`). Cosmetic; fix in next constitution edit.
- Leftover bullet at `constitution.md:34` ("On-device LLaMA model ... variant to be confirmed") remains in the required-integrations list despite OD#3/OD#4 amendments. Cosmetic.
- Guard scope caveats (from the gate's own docstring, `check-release-log-safety.py:19-22`): raw-error rule is limited to the two `ENGINE_FILES`; other subsystems' raw-error prints are out of scope by design and "tracked separately".
- B5 residual (cleartext LAN model download + ATS local networking) remains a standing risk acceptance, unchanged.
- Unmapped requirement IDs in §2 remain unmapped; no evidence was produced this cycle tracing them.

### 4.3 T-033 (separate track, merged)

T-033 Nepali intent encoder bake-off merged to `master` via `9054afc`. Its record (`tools/train-intent/docs/T-033-encoder-bakeoff.md` §8 GO at `:420`, C3 named base at `:425`, kills `:433-447`) carries its own open steps including lead-engineer sign-off (open steps `:449-465`). It is a separate track: it does not absorb into this sign-off's scope, and no app-code delta it produced is in the gated tree (confirmed by the empty `ios/` diff).

### 4.4 Pre-submission obligations (for the release checklist, not blockers to this sign-off)

1. OD#12 consent/disclosure UX + visible cloud-active indicator + switch-back path.
2. `Info.plist:78/:82` disclosure copy correction.
3. Monitoring retention window and alert parameters defined per `constitution.md:96` (owner: Anjan Poudel).
4. Re-review OD#11/OD#12 by 2026-10-13.

---

## 5. Rollback Plan

- If the governance text is found deficient at the human gate: revert the single governance commit `e6d10a7` (or amend `constitution.md` in place); no app-code rollback is implied because app trees are unchanged from the gated `57abb2e`.
- If the security gate must be rolled back: do **not** revert `5513323` (widened guard) or the T-049/T-050 changes; reverting them re-introduces B1/B2 and the guard wiring in `ios/build.sh:407-417` will fail the next test run by design.
- Release rollback (post-submission): app remains a local-first build; disabling the cloud engine stack returns behaviour to on-device-only, at the cost of the shipped default path from `AppCoordinator.swift:1612-1613` — this is a product decision, hence the OD#12 consent UX obligation.

---

## 6. Compliance Checklist

### 6.1 Process

| Item | Grade | Evidence |
|------|-------|----------|
| Security review re-run at gate revision, SECURITY-GO | PASS | `specs/security-test.md:16`, revision `:6`; mirror `.ai-sdd/outputs/security-test.md` byte-identical |
| Independent review of implementation | PASS | `specs/review-implementation.md:3` GO (T-042) |
| Security design review with blockers dispositioned | PASS | `.ai-sdd/outputs/security-design-review.md:346` GO with blockers, BLOCKER-1 `:370`, BLOCKER-2 `:384`, BLOCKER-3 `:398` |
| Governance divergence reconciled | PASS | `constitution.md:44/:74/:106/:108/:122-133`; `cmp` clean between copies |
| Recorded test gate covers reviewed revision | PASS | `.last-tested-sha` `57abb2e`; empty `ios/`+`android/` diff to `e6d10a7`; xcresult 2687/0/6 |
| Commit-message/state integrity | PASS | state honest; prior-run record explicitly distinguished |

### 6.2 Security

| Item | Grade | Evidence |
|------|-------|----------|
| B1 fixed, verified at revision | PASS | guarded prints; guard exit 0 executed this pass |
| B2 fixed, verified at revision | PASS | `GeminiClient.swift:254/:416/:439-444` |
| Guard is build-blocking ahead of every test scope | PASS | `ios/build.sh:407-417`, `:493-568` |
| B3–B7 risk acceptance time-boxed + owned | PASS | `constitution.md:122` (2026-10-13, Anjan Poudel) |
| Cloud exception bounded + obligations recorded | PASS (with follow-up) | `constitution.md:129-133`; consent UX not yet implemented (§3.3) |
| No PII/keys in this artifact | PASS | no SHAs ≥40 chars, no secrets/PII printed |

### 6.3 Requirements

| Item | Grade | Evidence |
|------|-------|----------|
| All requirements traced to implementation/test | PARTIAL | §2; unmapped FR-010, FR-016–FR-025, FR-030, FR-037; unmapped NFR set as listed |
| Safety-critical paths 100% unit coverage | PARTIAL | suite green (2673 leaf passes) but no per-path coverage number produced this pass |
| NFR-015 (no personal data to cloud for AI) | FAIL (recorded exception) | default `.gemini` stack; OD#12 recorded, obligations open |
| NFR-011 (TLS 1.2+ outbound) | PARTIAL | B5 residual cleartext LAN URL `ModelCatalog.swift:654`; ATS `Info.plist:107` |

---

## Verdict

**GO.**

Adjudication against the previous report's flip conditions:

1. **OD#11 time box + owner — MET.** "Review by: 2026-10-13 (30 days). Owner: Anjan Poudel (project owner)" (`constitution.md:122`); B1/B2 status corrected (`:127`).
2. **Constitution divergence reconciled — MET.** SDD and worktree copies byte-identical; React Native superseded everywhere including OD#4 (`:108`); constraint 4/OD#5/OD#10/OD#3/security-test path wording reconciled; OD#12 records the cloud exception with scope, consent, credential, and review terms (`:129-133`), cross-referenced by Constraint 1 (`:44`) and Privacy (`:74`).
3. **Release-console check + monitoring defined — MET with recorded caveats.** Guard is a build-blocking gate wired ahead of every test scope (`:94`, `ios/build.sh:407-417`); pre-release device console/sysdiagnose check with release-checklist evidence format (`:95`); post-deploy log-volume alert + retention window, owner and review date (`:96`). Caveats for the gate: the device-check bullet names no owner; the retention window and alert parameters are committed-to-be-defined by the record itself.
4. **Conditions 1–2 remain met at the revision signed — MET.** `ios/`+`android/` trees byte-identical to the gated `57abb2e`; recorded gate (2687 passed / 0 failed / 6 skipped) covers the revision; guard re-executed green at the tip.

Because the GO is documentation-scope, what the human is signing at the T2 gate is: (a) the recorded risk acceptance for B3–B7 (2026-10-13 review), including the B5 cleartext-LAN residual; (b) the cloud voice-stack exception OD#12 with its not-yet-implemented consent/disclosure UX and the `Info.plist:78/:82` copy correction as pre-submission obligations; (c) the unmapped requirement set in §2 as accepted for this release scope. No further reviewer pass is required unless the human rejects any of (a)–(c), in which case the affected condition above re-opens.
