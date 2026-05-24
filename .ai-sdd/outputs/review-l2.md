# Review Report — L2 Component Design

## Summary

Reviewed: `.ai-sdd/outputs/design-l2.md`
Input artifacts: `design-l1.md`, `define-requirements.md`
Review date: 2026-03-04
Reviewer: ai-sdd reviewer agent

### Criteria Assessed

This review assessed the L2 component design against:
1. Constitution Standards (Accessibility, Privacy, Security, Quality)
2. L1 Architecture alignment (design-l1.md)
3. Requirements coverage (define-requirements.md)
4. Component interface completeness and correctness
5. Data model completeness

### Findings by Criterion

**Accessibility**
- Voice-first access: All interactions route through `VoiceSessionCoordinator`; every feature is accessible by voice. PASS.
- Localisation: `TTSEngine` accepts a `Language` parameter; locale plugin architecture is addressed. All TTS/STT go through the engine. PASS.
- Touch UI size targets: Deferred appropriately to implementation; no violations introduced at L2. PASS.

**Privacy**
- No cloud AI: `LlamaInferenceEngine` is an on-device-only component; no network I/O in its interface. PASS.
- Health data minimisation: `HealthMonitorService` reads only systolic BP, diastolic BP, and heart rate — exactly the types required by FR-031. PASS.
- Remote config E2E: Signal Protocol double-ratchet in `SignalProtocolClient`; relay server is zero-knowledge. PASS.
- PII-free logs: `LogSanitiser` wraps `ObservabilityBus` at emission point. All 30+ observability events defined in §§3-8 contain no voice transcripts, health values, biometric scores, names, or contact data. PASS.

**Security**
- Voice biometric storage: `VoiceBiometricAuth` stores embedding in iOS Secure Enclave (`SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave`) or Android Keystore. Raw audio deleted post-enrolment. PASS.
- PIN hashing: `PinFallbackAuth` specifies Argon2id with 64 MB memory, 3 iterations, 4 parallelism, 16-byte random salt, 32-byte output. Never plaintext. PASS.
- Encrypted at rest: iOS Data Protection class Complete + Android Room/SQLCipher + EncryptedSharedPreferences for all on-device data. PASS.
- TLS pinning: `RelayWebSocketClient` specifies certificate pinning with fail-fast on mismatch. PASS.
- Input sanitisation: `InputSanitiser` at quarantine level applied to all external inputs (voice transcripts, calendar data, contact names loaded into prompt). PASS.
- Config atomicity: `ConfigApplicator` uses all-or-nothing apply with rollback on write failure. Matches NFR-041 reject-partial requirement. PASS.

**Quality**
- Safety-critical path isolation: Emergency dispatch, health monitor, medication scheduler all have interfaces that explicitly carry no LLM dependency. Dedicated process/service mechanism specified for `EmergencyDispatcher`. PASS.
- Emergency call reliability: `EmergencyDispatcher` specifies retry on call failure, falls back to voice instruction, and family notification proceeds independently of call status. PASS.
- Medication reminder durability: `MedicationScheduler` persists to `EncryptedLocalStorage` before OS alarm is set; `scheduleAll()` on app relaunch satisfies NFR-027. PASS.
- Health monitoring fail-safe: `HealthMonitorService` on permission revocation surfaces voice announcement, sends FCM/APNs push to family — does not silently fail. Satisfies NFR-035 requirement. PASS.

**Component Interface Correctness**
- All 6 L1 domain boundaries are present: Voice Pipeline, AI Inference, Safety-Critical Services, Authentication, Remote Config, Companion App.
- `Result<T, E>` pattern consistently used across all component protocols. No thrown exceptions cross component boundaries. PASS.
- Error taxonomy §2.2 is comprehensive: covers all identified failure modes for each domain.
- State machines defined for `VoiceSessionCoordinator` (FSM) and `BiometricAuthSession` (three-failure lockout). PASS.
- `TTSPriority.emergency` is non-cancellable with platform-native TTS fallback — satisfies safety-critical announcement requirement. PASS.

**L1 Architecture Alignment**
- All architect decisions from L1 §2 are reflected: openWakeWord, LLaMA 3.2 3B Q4_K_M, Signal Protocol double-ratchet, VoIP+Background Audio, clinical defaults, minimum 10 biometric / 20 accent samples. PASS.
- iOS silent 1-second background audio loop is correctly confined to `AudioSessionManager` only (no other component manages it). PASS.
- Companion app architecture is a separate binary sharing `SignalProtocolClient`. All config flows through relay, no direct device-to-device communication. PASS.

**Requirements Traceability**
- §15 traceability table maps all 46 FRs and all relevant NFRs to specific L2 components. No FR or NFR is untraced. PASS.

**Minor Observations (non-blocking)**
- `NFR-002` specifies ≤ 4 seconds for LLM response + TTS start; L2 §3.6 VoiceSessionCoordinator uses 3500 ms LLM timeout (appropriate — leaves headroom for TTS start). Consistent.
- `MessengerDeepLinkBridge` and `GoogleCalendarClient` from L1 are not detailed at L2. These are integration adapters with simple interfaces; absence of L2 detail is acceptable — they will be covered in the L3 task breakdown.
- `HealthAlertLog` in L1 data model stores `value: Float` (health value) in on-device encrypted storage — this is correct per the constitution (full data retained on-device in encrypted form, just not in observability events). Confirmed correct.

## Decision

GO

All constitution Standards criteria are met. Component interfaces are complete, internally consistent, and aligned with L1 architecture decisions. All 46 FRs and relevant NFRs are traceable to L2 components. Safety-critical isolation, privacy controls, security patterns, and error handling strategies are all adequately specified to support implementation planning.

The design is approved to proceed to security-design-review (STRIDE threat model).
