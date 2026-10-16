# Android Port Assessment — VoiceBridge (Elderly AI Assistant)

**Date:** 2026-10-01
**Prepared:** Claude Code, based on repo review of `elderly-ai-assistant` (product repo) and `ai-sdd-claude/examples/elderly-ai-assistant` (SDD governance mirror)
**Audience:** Project owner / decision-makers

---

## 1. Executive summary

The product is a voice-first, on-device-AI safety assistant for elderly Nepali speakers (medication, reminders, health monitoring, emergency dispatch, family companion app). The **iOS app exists and is production-grade**; the **Android app is a deliberate v2 deferral** with only a small skeleton (~21 Kotlin files).

**The verdict in one sentence:** building Android is not a "port" — it is a **parallel native build** in Kotlin/Jetpack Compose that shares model artifacts, protocol contracts, and one relay-server design, but shares ~0% of application code.

| Dimension | Assessment |
|---|---|
| **Complexity** | **HIGH** — equal-or-higher than iOS in the voice/background/ML areas (no ANE, OEM background killers, Play policy), lower in others (medication core already ported) |
| **Time (core MVP)** | ~3–5 months AI-augmented solo (the way iOS was built); ~2.5–3.5 months with 2–3 developers |
| **Time (full parity with today's iOS)** | ~6–9 months solo; ~4–6 months with a team |
| **Cost (hard costs, solo AI-augmented)** | ~$5–10K (devices, CI, LLM/agent API, Play fees) + notional owner time (~700–1,200 hrs) |
| **Cost (hired team)** | ~$110–200K (2–3 devs, 4–6 months); ~$300–600K agency |
| **Biggest risks** | Background survival on OEM Android (Xiaomi/OPPO/Samsung), on-device STT/LLM latency without an Apple-Neural-Engine equivalent, Play policy on notification/SMS/call access, Health Connect's passive-only model |

A critical framing point: the plan and constitution already specify exactly what Android must look like — 13 Android platform subtasks with prescribed APIs (TFLite/openWakeWord, AudioRecord, AlarmManager+START_STICKY, Health Connect, Android Keystore, FCM). What is missing is not specification, but **build effort and hardware validation**.

---

## 2. Baseline: what exists today

### 2.1 Measured codebase sizes (2026-10-01)

| Metric | iOS — VoiceBridge | Android skeleton |
|---|---|---|
| App source files | **356 Swift files** | **16 Kotlin files** |
| App LoC | **~151,000** | ~1,600 |
| Test files | **345 files (~137,000 LoC)** | 5 test classes (~740 LoC) |
| Passing tests (last full gate) | **2,687 passed / 0 failed** (2026-09-13, iPhone 17 Pro simulator) | JUnit suites for medication + family modules |
| UI framework | SwiftUI (+ WidgetKit widget target) | XML layout only — **Compose is disabled in `build.gradle`** |
| Build/test harness | xcodegen-generated project, impact-aware test gate (`build.sh test:impact`), parallel simulator fan-out, build-blocking log-safety gate | `build.sh`: assembleDebug / release / `gradlew test` + lint |
| Min/target SDK | iOS (simulator-tested; App Store submission pending) | minSdk 26 / targetSdk 34 |
| Git activity | Active — PRs through #136+ (VoiceBridge rebrand, OCR, camera translation, brain chat schema) | Effectively dormant since initial skeleton |

### 2.2 Feature surface comparison

| Capability | iOS (built) | Android |
|---|---|---|
| Voice pipeline (STT/TTS/audio session) | ✅ WhisperKit on ANE/CoreML (800 MB model), sherpa/Piper TTS, Speech fallback | ❌ none |
| Wake word | ✅ Porcupine "Hey Sahayak" (behind `#if canImport`, default Null engine) | ❌ none (openWakeWord TFLite prescribed) |
| On-device LLM | ✅ llama.cpp + Qwen3 4B Nepali intent brain (default), model catalog, chat framing, RAM-gated lifecycle | ❌ none (llama.cpp JNI prescribed) |
| Cloud LLM fallback | ✅ Gemini (consent exception OD#12) | ❌ none |
| Medication core | ✅ scheduler, escalation, double-dose, photo verification | ✅ **scheduler, escalation engine, double-dose detector, confirmation challenge, photo verifier, platform alarm scheduler** (with tests) |
| Family notifier | ⚠️ `APNsProvider` stub prints + returns true (B-findings, re-review 2026-10-13) | ✅ FCM notifier + `fcm_delivery_failed` error code |
| Emergency dispatch | ❌ descoped (B4/B6) | ❌ (isolated-process design prescribed) |
| Health monitoring | ❌ HealthKit not yet wired | ❌ Health Connect client (alpha) dependency only |
| Auth (voice biometric + PIN) | ⚠️ partially (B-findings: no biometric/PIN gate wired) | ❌ |
| Remote config (Signal E2E) | ❌ broker designed, not built | ❌ |
| Companion app | ❌ not built | ❌ |
| Plugin runtime (4 plugins: NepaliCalendar, ApplianceHelper, Routine, YouTube) | ✅ iOS-only (`Services/Plugins/`) | ❌ **nothing — no registry, no protocol** |
| Live camera translation + OCR | ✅ (Vision framework; LCT feature complete) | ❌ CameraX dependency only |
| Calendar/reminders | ✅ EventKit + own scheduler | ❌ |
| Call detection | ✅ CallKit `CXCallObserver` (live-call presence) | ❌ |
| Widgets | ✅ TimerAlarmWidget | ❌ |
| Physical device validation | ⚠️ **LCT protocol exists but no physical-device run happened — simulator only** | ❌ |

### 2.3 What IS shared (reuse inventory)

- **Model artifacts**: LLaMA/Qwen GGUF brains, whisper models, openWakeWord model, Piper/sherpa Nepali + English voices — file-format portable, re-download per platform
- **ML track outputs** (TG-08, TG-10–TG-13): intent encoder (ONNX/LiteRT export — T-033/T-037 explicitly decide the Android runtime), training corpus, evaluation harness, robustness fixtures — platform-neutral artifacts
- **Protocol contracts**: component interfaces per L2 §, typed error taxonomy, requirement locks
- **Server design**: Signal-style config broker (ciphertext envelopes, APNs/FCM wake-up only) — one server serves both platforms
- **Test strategy**: impact-aware gating, safety-net suite concept, LCT device-validation protocol template

---

## 3. What "Android v2" actually means

Per the SDD plan (product repo `.ai-sdd/outputs/plan-tasks/`, evolved to T-001–T-089): **59–70 parent tasks, 26 platform subtasks, of which 13 are Android-specific**. Plus parity work for iOS features that post-date the plan (plugins, camera translation, widgets, brain catalog).

### 3.1 The 13 prescribed Android subtasks

| ID | Component | Prescribed Android APIs | Effort/Risk (from spec) |
|---|---|---|---|
| T-002-b | Encrypted local storage | Room + SQLCipher + EncryptedSharedPreferences; Argon2id needs libsodium JNI below API 29 | M / — |
| T-005-b | Wake word | openWakeWord via TFLite; `AudioRecord` 16 kHz/80 ms; P95 <10 ms/frame; CPU ≤3% | M / MEDIUM |
| T-007-b | Audio session | `AudioManager` + `AudioFocusRequest`; `ACTION_AUDIO_BECOMING_NOISY`; `ForegroundService` + persistent notification | M / MEDIUM |
| T-009-b | STT | whisper.cpp via TFLite; P95 ≤2 s; Nepali confidence <0.6 → English fallback; typed `.STTTimeout` | M / MEDIUM |
| T-012-b | TTS | Coqui/Piper primary; Android `TextToSpeech` emergency fallback (silent-failure = CI-blocking gate) | M / MEDIUM |
| T-014-b | Voice biometric | ECAPA-TDNN embeddings in **Android Keystore**; PAD/liveness replay rejection (THREAT-001 CI blocker); 3-failure lockout | L / **HIGH** |
| T-018-b | LLM inference | llama.cpp via **JNI**; RAM gate — refuse load <2.5 GB free; footprint ≤2100 MB; P95 ≤3.5 s | L / **HIGH** |
| T-022-b | Voice session coordinator | Pure FSM (no new APIs); 3.5 s LLM timeout + 1 retry | M / HIGH |
| T-024-b | Health monitor | Health Connect `PassiveListenerService`; permission-revocation fail-safe CI gate; no LLM import | M / HIGH (safety-critical) |
| T-026-b | Emergency dispatcher | `TelephonyManager`/`ACTION_CALL`; `android:process` isolated process; 30 s cancellable countdown | M / HIGH (safety-critical) |
| T-028-b | Medication scheduler | `AlarmManager.setExactAndAllowWhileIdle()` + `USE_EXACT_ALARM`; START_STICKY re-arm from encrypted storage; FCM escalation | M / HIGH (safety-critical) |
| T-032-b | Companion app | `BiometricPrompt` gating config; Signal-encrypted relay push; mock-relay E2E on CI | M / MEDIUM |
| T-037-b | Intent encoder runtime | ONNX Runtime Mobile **or** LiteRT (decided by T-033 export spike; blocked → group NO-GO); p50 ≤1.0 s / p95 ≤2.0 s on 6 GB reference device | M / HIGH |

### 3.2 Scope beyond the plan (iOS parity features Android must also get)

- **Plugin runtime** — `AssistantPlugin` protocol, registry, `CommandRouter .plugin` case, intent-fragment composition, 4 existing plugins. iOS-only today; Android builds this from scratch (~2–4 weeks)
- **Live camera translation** (Vision OCR + overlay + cache) — ML Kit `TextRecognition` + CameraX; the LCT plan (30 tasks, ~42–58 dev-days) would need its own Android pass (~2–4 weeks)
- **Widgets** — Glance or RemoteViews (~1 week)
- **Brain catalog / chat framing** — model picker parity (T-048 records Android has none of this code) (~1–2 weeks)
- **Call detection** — `TelephonyCallback.CallStateListener` (~1 week)

---

## 4. Platform diff: iOS vs Android native layer

### 4.1 Capability-by-capability mapping

| Layer | iOS (shipped or designed) | Android (prescribed) | Verdict |
|---|---|---|---|
| Audio capture/session | `AVAudioSession` (`.measurement`), Background Audio/VoIP modes | `AudioRecord` + `AudioManager`/`AudioFocusRequest` + **foreground service with permanent notification** | **Harder on Android** — persistent notification is user-visible and OEM-fragile |
| Wake word | Porcupine on-device | openWakeWord TFLite (both models portable) | Comparable |
| STT | **WhisperKit on ANE/CoreML** — 800 MB model, hardware-accelerated | whisper.cpp via TFLite — **CPU-only**; NNAPI fragmented across SoCs | **Significantly harder on Android** — the 2 s P95 budget must be met without the Neural Engine |
| On-device LLM | llama.cpp + Metal/ANE acceleration, RAM-class-based lifecycle | llama.cpp via JNI — CPU; NPU/GPU delegates fragmented; 2.5 GB free-RAM gate | **Harder on Android** — 3.5 s P95 on a 6 GB mid-range phone is a real risk; Qwen 4B may need to become 1B–1.7B (bake-off already in OPEN-ITEMS #6) |
| TTS | sherpa/Piper (same engine family) | Coqui/Piper + Android TTS fallback | Comparable |
| Health data | HealthKit `HKObserverQuery` + `BGProcessingTask` (background delivery) | Health Connect `PassiveListenerService` — **passive store**, no live push; user consent flow; weaker background delivery | **Harder on Android** — "monitoring" = polling |
| Alarms/reminders | `BGTaskScheduler` + local notifications + Background Modes | `AlarmManager.setExactAndAllowWhileIdle` + `USE_EXACT_ALARM` + START_STICKY + WorkManager | **Much harder on Android** — Doze, app standby, and OEM killers (Xiaomi/OPPO/Samsung) routinely kill foreground services; user battery-exemption opt-in required |
| Emergency call | `tel://` prompt (descoped B4/B6 on iOS) | `ACTION_CALL` + `CALL_PHONE` + isolated process | **Infeasible as literally specced on both** (auto-dial without user gesture) — requirement renegotiation needed |
| Biometrics (device) | Secure Enclave, Keychain | Android Keystore (`KeyPairGenerator`), `BiometricPrompt` | Comparable (voice biometrics themselves = custom ML on both; Keystore only stores, can't match) |
| Secure storage | Core Data + Data Protection Complete | Room + SQLCipher + EncryptedSharedPreferences; Argon2id < API 29 needs libsodium JNI | Comparable, slightly harder on Android (crypto-backport) |
| Push | APNs (stub today) | FCM | Comparable; **high-priority FCM throttled under Doze** — conflicts with the 60 s caregiver-override SLA |
| Messaging/calling | Outbound-only: `wa.me`/`tel:`/`facetime://` deep links, `MFMessageComposeViewController`, `CXCallObserver` (state) | `NotificationListenerService` can **read/mirror** WhatsApp/Messenger/SMS notifications (iOS cannot do this at all); but `READ_CALL_LOG`/`READ_SMS` are Play-restricted to dialer/SMS apps | **Android is actually more capable here** — but Play policy is the gate; draft justification before architecting |
| Calendar | EventKit | Calendar Provider (`READ/WRITE_CALENDAR`) | Comparable |
| UI | SwiftUI + WidgetKit | Jetpack Compose (**not yet enabled**) + Glance | Comparable once Compose is turned on |
| ML runtime | CoreML/ANE/Metal | TFLite / ONNX Runtime Mobile / NNAPI | iOS advantage in practice |
| Store compliance | App Review (VoIP-mode misuse risk for always-on mic) | Play policy (sensitive permissions, notification access justification, exact-alarm policy) | Different flavor of hard; neither is free |

### 4.2 Where Android is genuinely better

1. **Notification reading/mirroring** — the messaging research doc's own recommendation: Android-primary for `read_notifications` (via `NotificationListenerService` + mirrored SQLite log). iOS simply cannot do this.
2. **Foreground-service model** — Android's declared model for "always-running" is a supported concept; iOS's Background Audio/VoIP usage for a non-audio app risks App Store rejection.
3. **Sideloading** — device validation on the parents' actual phone doesn't require TestFlight bureaucracy.
4. **Cheaper reference hardware** — the fallback-device decision already budgeted a mid-range Android at ~$200–300 (vs iPhone 12+ as iOS floor).

### 4.3 Where Android is genuinely worse

1. **No Neural Engine equivalent** — the iOS STT/LLM latency wins rest on ANE/CoreML; Android gets CPU + fragmented NNAPI. Expect model downsizing (1B–1.7B) or relaxed latency budgets.
2. **Background survival** — Doze + OEM task killers are the single biggest Android risk for a 24/7 safety app; `START_STICKY` (assumed by NFR-008) does not defeat Xiaomi/OPPO aggressive battery managers.
3. **Fragmentation** — must validate across Samsung/Xiaomi/OPPO/vivo SoCs; iOS is one chip family.
4. **Play policy on sensitive permissions** — call-log/SMS access likely denied; notification-listener requires a declared companion-app use case.
5. **Background camera** (photo verification while locked, FR-D04a) is restricted — needs foreground state.
6. **Health Connect is passive** — no equivalent of HealthKit's background delivery; connection-loss detection (FR-035) is weaker.

---

## 5. Complexity assessment

**Overall: HIGH (8/10).** The AI/voice/background core is harder than iOS; the safety-services core is partly done; the UI layer is simple.

| Area | Complexity | Notes |
|---|---|---|
| Medication + escalation core | **LOW (mostly done)** | Already ported with tests; remainder is alarm-hardening + FCM wiring |
| Family notifier (FCM) | LOW | Already ported |
| UI shell | LOW–MED | XML-only today; Compose switch is a decision, not a risk |
| Remote config + companion | MEDIUM | Broker server is new for both platforms; FCM wake + Double Ratchet per design |
| Plugin runtime + parity features | MEDIUM | Net-new Android code but well-specified by the iOS implementation |
| Voice pipeline (wake word → STT → TTS → session) | **HIGH** | Latency budgets on 6 GB mid-range hardware without ANE; audio-focus interplay with wake word |
| On-device LLM | **HIGH** | JNI build, RAM gates, NPU fragmentation, brain-catalog parity |
| Background survival engineering | **HIGHEST** | OEM killer exemptions, Doze, exact alarms, persistent notification UX for elderly users |
| Voice biometrics | **HIGH** | Custom ECAPA-TDNN ML + PAD/replay rejection + Keystore integration — genuinely hard on both platforms |
| Health Connect | MEDIUM–HIGH | Passive-only; permission-revocation fail-safes; no live BP stream |
| Emergency dispatch | MEDIUM (build) / **HIGH (policy)** | Isolated process + countdown is buildable; auto-dial requirement must be renegotiated |
| Nepali intent encoder runtime | MEDIUM–HIGH | Depends on T-033 export decision (ONNX Runtime Mobile vs LiteRT); model R&D itself is platform-neutral and already underway |

---

## 6. Time estimates

### 6.1 Benchmarks to calibrate against

- **iOS delivery record:** init (2026-05-24) → final sign-off GO with 2,687 tests (2026-09-13) = **~16 weeks**, AI-augmented via the ai-sdd framework, followed by continuous feature cycles (PRs through #136+).
- **SDD plan's own estimate** (full scope, both platforms): 185–304 sequential dev-days / 39–64 days fully parallelized. The Android-specific stream is 13 of 26 platform subtasks plus its share of 14 shared tasks — roughly **50–65% of platform work**, but ~0% of the ML R&D (TG-08/TG-10–13 artifacts are shared).

### 6.2 Scenarios

| Scenario | Core MVP¹ | Full parity with today's iOS² |
|---|---|---|
| **A. AI-augmented solo** (mirrors how iOS was built) | **3–5 months** | **6–9 months** |
| **B. 2–3 developers** (1 Kotlin lead + 1 ML/audio eng, ± QA) | **2.5–3.5 months** | **4–6 months** |
| **C. Agency** | 3–4 months | 5–7 months (with more overhead) |

¹ Core MVP = voice pipeline + on-device LLM + medication/emergency/health/auth + remote config + companion app (the 13 subtasks + 14 shared).
² Full parity = MVP + plugin runtime, live camera translation, widgets, brain catalog, call detection, plus Play hardening.

### 6.3 Phase breakdown (Scenario A reference)

| Phase | Duration | Contents |
|---|---|---|
| 1. Foundation + build hardening | 1–2 wks | Gradle harness parity (impact-aware tests, lint gates, log-safety gate), Compose enablement, CI on emulator + Firebase Test Lab |
| 2. Voice pipeline | 6–10 wks | Audio session → wake word (openWakeWord) → STT (whisper TFLite) → TTS (Piper) → session FSM; latency tuning on mid-range hardware |
| 3. On-device AI | 4–6 wks | llama.cpp JNI, RAM-gated model lifecycle, brain catalog, encoder runtime (ONNX/LiteRT per T-033 outcome) |
| 4. Safety services | 3–4 wks | Emergency dispatcher (isolated process), Health Connect listener, alarm hardening (exact alarms + START_STICKY + boot receiver) — medication core already exists |
| 5. Auth | 2–3 wks | Voice biometric enrollment + Keystore + PIN fallback + BiometricPrompt |
| 6. Remote config + companion | 4–6 wks | Broker server (shared), FCM wake, Double Ratchet client, companion-app config editors |
| 7. Parity features | 6–8 wks | Plugin runtime + 4 plugins, camera translation, widgets, call detection |
| 8. Device validation + store | 3–5 wks | LCT-style protocol on 2–4 real devices (Samsung + Xiaomi + Pixel + the parents' phone), Play policy justifications, closed track with caregivers |

---

## 7. Cost estimates

### 7.1 Hard costs (any scenario)

| Item | Estimate | Notes |
|---|---|---|
| Test device lab | **$600–1,500** | Mid-range reference (6 GB, ~$200–300) + 2–3 OEM devices for background-kill matrix |
| Google Play Console | $25 (one-time) | |
| CI (emulator minutes / Firebase Test Lab) | $50–150/mo | |
| Model artifact hosting (GGUF/whisper/Piper CDN) | $10–50/mo | Portable artifacts already produced for iOS |
| LLM/agent API costs (Scenario A only) | **$2–6K** | Rough analog of the iOS build's AI-augmented development cost |
| **Total hard costs** | **~$4–8K** | Scenario A |

### 7.2 Labor scenarios

| Scenario | Composition | Duration | Estimated cost |
|---|---|---|---|
| A. AI-augmented solo | Owner + ai-sdd workflow | 4–8 months | $4–8K hard + **notional owner time 700–1,200 hrs** (≈ $55–120K at $75–100/hr loaded) |
| B. Small team | 1 Android/Kotlin senior + 1 ML/audio eng (part-time QA) | 4–6 months | **~$110–160K** |
| C. Team + designer/QA | Scenario B + designer + QA (elderly-UX focus) | 4–6 months | **~$150–210K** |
| D. Agency | Full-service | 5–7 months | **~$300–600K** |

**Cost drivers to watch:** OEM background-survival QA (each additional OEM adds regression surface), ML latency optimization without ANE (may force a model retrain/bake-off — GPU time ~$100s–$1,000s), Play policy rework cycles, and per-OEM device-validation passes (the iOS side has not even done its physical-device run yet — budget for both).

---

## 8. Top risks & mitigations

1. **OEM background killers defeat the 24/7 service model** (highest risk). Mitigation: DontKillMyApp-style per-OEM checklist; user-facing battery-exemption onboarding flow (caregiver-assisted); watchdog self-heal; honest device-matrix validation before store launch.
2. **Doze throttles FCM high-priority pushes** — breaks the 60 s caregiver-override SLA (NFR-D06). Mitigation: FCM high-priority + user exemption from battery optimization + degraded-mode UI; document SLA deviation if unmet.
3. **STT/LLM latency budgets (2 s / 3.5–4 s P95) on mid-range hardware without ANE.** Mitigation: model downsizing (Gemma 3 1B vs Qwen 3 1.7B bake-off — OPEN-ITEMS #6 already underway; IndicBERT-v3-270M recommended in model-options doc), Whisper small vs medium, quantization, and an explicit decision to relax budgets if the reference device cannot meet them.
4. **Play policy on sensitive permissions** (call log, SMS, notification listener). Mitigation: draft the Play justification before architecting (the research doc's own recommendation); scope to notification-listener companion-app use case; expect to drop or renegotiate FRs.
5. **Requirement infeasibility as literally written** — auto emergency dial (FR-033c) and answering Messenger calls (FR-018) are infeasible on iOS too; Android only slightly different (CALL_PHONE still needs user consent). Mitigation: renegotiate to confirmation-gated dial + notification-read/reply scope; record as requirement amendments like the iOS descopes (B4/B6).
6. **Health Connect passive-only semantics** — "monitoring" becomes polling; connection-loss detection (FR-035) is weaker. Mitigation: define polling cadence and alert thresholds in the spec; permission-revocation fail-safe (already a prescribed CI gate).
7. **Voice-biometric replay/PAD risk** (THREAT-001 is a CI-blocking gate on both platforms). Mitigation: keep the security-reviewer sign-off precondition; liveness challenges.
8. **Test-infrastructure gap** — iOS has a sophisticated impact-aware harness; Android has plain `gradlew test`. Mitigation: Phase 1 builds the Gradle equivalent (affected-module test selection, safety-net suite, Robolectric + emulator matrix) before feature work scales.
9. **Physical-device validation debt exists on BOTH platforms** (iOS LCT: 16/16 checks NOT RUN — simulator only). Mitigation: run the LCT-style protocol on real hardware for Android *before* announcing v2 readiness; the protocol template already exists.
10. **Scope creep from iOS feature velocity** — iOS keeps growing (PRs #133–136+). Mitigation: pin an iOS parity snapshot as the Android v2 contract; new features enter the Android backlog, not the v2 release.

---

## 9. Recommendations

1. **Confirm the v2 contract**: pick the parity snapshot (recommend: today's iOS minus LCT-camera-translation), and record requirement amendments for FR-018/FR-033c before build starts.
2. **Enable Jetpack Compose now** and delete the XML shell — no reason to keep the skeleton's UI dead-end.
3. **Run the bake-off decisions first** (T-033 export spike, OPEN-ITEMS #6 model bake-off): they gate the Android runtime (ONNX vs LiteRT) and model size — starting voice/AI work before these land risks rework.
4. **Build in the prescribed order**: safety services (mostly ported) → voice pipeline → LLM → auth → remote config → parity features.
5. **Draft the Play policy justification** (notification listener / companion app) as a spec-doc task before architecting messaging features.
6. **Copy the LCT device-validation protocol to Android**, and this time buy the devices up front (~$600–1,500) — including the parents' target phone.
7. **Reuse the iOS harness philosophy** (impact-aware tests, build-blocking log-safety gate, safety-net suites) in Gradle from week 1.
8. **Leverage Android's strengths**: notification read/mirror via `NotificationListenerService` (impossible on iOS) can make Android the *primary* platform for messaging features — worth stating in the v2 product framing.
9. **Track cost honestly**: Scenario A is the cheapest (~$4–8K hard costs) but consumes 4–8 months of owner time; Scenario B (~$110–160K) is the rational choice if the owner's time is the constraint.

---

## Appendix: data sources

- Product repo: `/Users/anjan/workspace/projects/elderly-ai-assistant` — `ios/` (source, tests, `build.sh`), `android/`, `docs/` (plugin-architecture, messaging-calling-platform-research, ios-platform-integration-plan, OPEN-ITEMS, remote-config-channel-design), `.ai-sdd/outputs/plan-tasks/` (evolved plan T-001–T-089), `specs/` (LCT results, final-sign-off)
- SDD governance mirror: `ai-sdd-claude/examples/elderly-ai-assistant` — constitution.md, requirements.md, requirements-dementia-supplement.md, docs/decisions-and-status.md, docs/llm-spec-and-implementation-plan.md, specs/final-sign-off.md
- Code metrics measured 2026-10-01 via `find`/`wc -l` (iOS excludes `vendor/`, DerivedData, build outputs; LoC figures are approximations).
- Time/cost figures are estimates with stated assumptions; effort labels (S/M/L) and risk tiers are quoted from the plan's task specs.
