# Security Design Review — Elderly AI Assistant

**Project:** Elderly AI Assistant
**Version:** 1.0 (MVP)
**Review Type:** STRIDE Threat Model + Security Controls Assessment
**Status:** Final
**Date:** 2026-03-04
**Reviewer:** Security Reviewer (ai-sdd)
**Input Documents:** constitution.md, define-requirements.md, design-l1.md, design-l2.md

---

## Executive Summary

This document presents a STRIDE threat model and security design review for the Elderly AI Assistant — a safety-critical, privacy-first mobile health application for elderly users. The application operates on iOS and Android, performing all AI inference on-device, using Signal Protocol E2E encryption for remote configuration, and maintaining safety-critical services (emergency dispatch, health monitoring, medication scheduling) independently of the on-device LLM.

The review covers all 10 mandated threat scenarios and assesses all security controls defined in the L1 and L2 designs.

**Overall Decision: GO with conditions.**

All HIGH risk threats have documented mitigations in the current design. Safety-critical paths are architecturally isolated from the LLM. Biometric data is stored in Secure Enclave / Android Keystore. E2E encryption via Signal Protocol is confirmed. Three required actions must be addressed before implementation begins.

---

## 1. STRIDE Threat Model

### Threat Taxonomy Reference

| Category | Description |
|----------|-------------|
| S — Spoofing | Claiming a false identity |
| T — Tampering | Modifying data or code without authorisation |
| R — Repudiation | Denying an action was taken |
| I — Information Disclosure | Exposing data to unauthorised parties |
| D — Denial of Service | Making a service unavailable |
| E — Elevation of Privilege | Gaining unauthorised permissions or access level |

---

### THREAT-001: Voice Biometric Spoofing via Recorded Audio Replay

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-001 |
| **Category** | Spoofing (S) |
| **Description** | An attacker obtains a recording of the enrolled user's voice (e.g. from a phone call, social media video, or by recording the user directly) and replays it to the VoiceBiometricAuth system to impersonate the user and execute sensitive commands (calls, health data access, config changes). |
| **Affected Components** | VoiceBiometricAuth, AudioSessionManager, STTEngine, VoiceSessionCoordinator, AuthCoordinator |
| **Likelihood** | M — Attacker needs physical proximity or access to audio recordings of the user |
| **Impact** | H — Successful spoofing grants access to sensitive commands including Messenger calls, health data, and configuration changes |
| **Risk Rating** | HIGH |
| **Mitigations in Current Design** | (1) Speaker embedding using ECAPA-TDNN stored in Secure Enclave. Cosine similarity threshold of 0.85 provides resistance to low-quality recordings. (2) Raw voice samples deleted post-enrolment, reducing the attack surface for embedding extraction. (3) Three-failure lockout drops to PIN fallback, limiting replay automation. |
| **Residual Risk** | MEDIUM — The current design does not specify anti-spoofing or liveness detection (Presentation Attack Detection, PAD). Speaker verification models trained without PAD can be fooled by high-quality recordings or voice synthesis. |
| **Required Actions** | BLOCKER: The VoiceBiometricAuth component MUST specify liveness detection (PAD) controls before implementation. Options: (a) confirm the selected ECAPA-TDNN variant includes PAD capability, or (b) integrate a dedicated lightweight anti-spoofing model such as AASIST. |

---

### THREAT-002: On-Device LLM Adversarial Voice Input

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-002 |
| **Category** | Tampering (T) / Elevation of Privilege (E) |
| **Description** | A malicious voice input (spoken aloud or injected via a Bluetooth device or background media) contains adversarial sequences designed to manipulate the LLM's behaviour — such as overriding the system context, requesting unintended actions, or extracting personal information via elaborately crafted conversational scenarios. |
| **Affected Components** | InputSanitiser, LlamaInferenceEngine, IntentClassifier, EntityExtractor, STTEngine, VoiceSessionCoordinator |
| **Likelihood** | M — On-device LLaMA 3.2 3B is susceptible to adversarial conversational inputs; the attack surface is voice-accessible |
| **Impact** | M — LLM is explicitly isolated from safety-critical paths. Successful manipulation cannot directly trigger emergency calls or medication cancellations (those are rule-based). However, it could manipulate contact selection for calls, or cause confusing or abusive TTS output directed at a vulnerable elderly user. |
| **Risk Rating** | MEDIUM |
| **Mitigations in Current Design** | (1) InputSanitiser at quarantine level applied to all external inputs before LLM processing (NFR-013, L2 section 4.1). (2) Quarantine rules strip model template tokens and reject role-override attempts and adversarial patterns. (3) 2000-character input length cap. (4) LLM is not in the critical path for emergency dispatch or medication scheduling. (5) Voice biometric authentication required before sensitive commands are executed. |
| **Residual Risk** | LOW-MEDIUM — No sanitisation is perfect. Red-team testing of adversarial patterns specific to LLaMA 3.2 chat template format is required during implementation. |
| **Required Actions** | RECOMMENDED: (a) Maintain a living blocklist of known LLaMA chat-template adversarial patterns and test against it during implementation. (b) Add an observability event for suspicious input pattern detection (count only, no content). (c) Define the boundary between sanitised text passed to LLM and raw transcript used for wake-word or keyword matching — the cancel keyword path must not be manipulable via crafted LLM input. |

---

### THREAT-003: Emergency Call Trigger Manipulation

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-003 |
| **Category** | Tampering (T) / Denial of Service (D) |
| **Description** | Two sub-threats: (3a) False cancellation — background audio (television, another person speaking the cancel word) causes the emergency countdown to be incorrectly cancelled; (3b) Threshold suppression — a malicious or misconfigured config payload sets health thresholds so high that no legitimate reading would trigger an alert, silently disabling the emergency response. |
| **Affected Components** | AlertEvaluator, EmergencyDispatcher, CancelListenerService, ConfigApplicator, ConfigSchemaValidator, HealthMonitorService |
| **Likelihood** | M (false cancellation from background audio); L (threshold manipulation via malicious config — requires compromised companion app auth) |
| **Impact** | H — Suppressed emergency response can result in serious harm or death for the elderly user |
| **Risk Rating** | HIGH |
| **Mitigations in Current Design** | (3a) CancelListenerService uses a keyword-spotting model (openWakeWord variant) that requires the specific configured cancel keyword — not general speech. (3b) AlertThresholdEditor in companion app validates thresholds against minimum safety bounds (systolic within 60–300 mmHg). ConfigSchemaValidator enforces allowed field keys and value types via allowlist. Signal Protocol authentication ensures config arrives only from the authenticated companion device. |
| **Residual Risk** | MEDIUM (3a — background audio false cancellation); LOW (3b — requires compromised companion app) |
| **Required Actions** | BLOCKER: The design must specify: (a) Minimum confidence threshold for the cancel keyword model below which cancellation is not accepted, to reduce false positives from background audio. (b) Safety bound validation rules for ALL health threshold fields must be explicitly enumerated in the L2 design — currently only systolic BP example is given. Diastolic BP and heart rate bounds must also be specified. RECOMMENDED: (c) Consider requiring two consecutive cancel detections within 3 seconds to accept cancellation, reducing single false-positive risk without materially impacting usability. |

---

### THREAT-004: Health Data Interception by Other Apps or OS-Level Leakage

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-004 |
| **Category** | Information Disclosure (I) |
| **Description** | Health data (blood pressure, heart rate) read from HealthKit or Health Connect is intercepted by: (a) another app with overlapping health permissions, (b) leaked through application logs, (c) included in inter-process communication or push notifications, or (d) written to unencrypted storage. |
| **Affected Components** | HealthMonitorService, AlertEvaluator, HealthAlertLog, LogSanitiser, FamilyNotifier, EncryptedLocalStorage, ObservabilityBus |
| **Likelihood** | L — On-device only; requires elevated OS access or a malicious co-installed app |
| **Impact** | H — Health data is among the most sensitive personal data categories; exposure violates privacy requirements and App Store / Play Store compliance |
| **Risk Rating** | MEDIUM |
| **Mitigations in Current Design** | (1) Health data never passed to LLM raw (L1 section 12). (2) LogSanitiser strips health values from all observability events — confirmed in L2 section 5.1 where threshold breach events include metric name only. (3) HealthAlertLog written to EncryptedLocalStorage (iOS Data Protection Complete / Android EncryptedSharedPreferences and SQLCipher). (4) FCM/APNs family notification payload contains only alert type and timestamp — no health values transmitted over the wire (L1 section 6.3). (5) Permission minimisation — only blood pressure and heart rate data types requested (NFR-017). |
| **Residual Risk** | LOW — Design controls are comprehensive and well-specified. |
| **Required Actions** | RECOMMENDED: (a) Confirm that HealthAlertLog.value (which stores the actual health metric reading) is stored using the same EncryptedLocalStorage layer as other sensitive data — the L1 data model shows this field but does not explicitly confirm encryption class. (b) Verify iOS IPC paths — if HealthMonitorService runs in a separate process extension, the XPC channel must not expose health values to other processes. |

---

### THREAT-005: Remote Config Interception or Tampering via MITM Attack

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-005 |
| **Category** | Information Disclosure (I) / Tampering (T) |
| **Description** | A man-in-the-middle attacker positioned between the companion app and the relay server, or between the relay server and the primary device, intercepts or modifies configuration payloads containing medication schedules, emergency contacts, health thresholds, and contact lists. |
| **Affected Components** | SignalProtocolClient, RelayWebSocketClient, ConfigPayloadDecryptor, ConfigSchemaValidator, relay server |
| **Likelihood** | L — Signal Protocol double-ratchet plus TLS 1.3 plus certificate pinning provides strong protection |
| **Impact** | H — Tampered config could suppress health monitoring or modify emergency contacts |
| **Risk Rating** | MEDIUM |
| **Mitigations in Current Design** | (1) Signal Protocol double-ratchet E2E encryption — relay server is zero-knowledge; it sees only ciphertext envelopes (L1 sections 3.1 and 6). (2) RelayWebSocketClient pins the relay server TLS certificate — MITM on TLS layer is detected and connection rejected (L2 section 7.4). (3) ConfigPayloadDecryptor rejects any payload that fails decryption — tampered ciphertext fails MAC verification. (4) Identity key exchange via Signal Protocol mutual authentication. |
| **Residual Risk** | LOW — Signal Protocol provides proven E2E encryption with forward secrecy. Residual risk concentrates in the key establishment phase. |
| **Required Actions** | RECOMMENDED: (a) Define the out-of-band device pairing flow. The L2 design does not specify how the companion app obtains the primary device's identity key for the initial Signal Protocol session — this bootstrapping moment is the highest-risk phase and must be secured (e.g. QR code scan, shared secret, manual key fingerprint comparison). (b) Specify relay server authentication to prevent an attacker from registering a fraudulent device ID at the KEY_REGISTER endpoint. |

---

### THREAT-006: Wake Word False Activation from Background Audio

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-006 |
| **Category** | Denial of Service (D) / Tampering (T) |
| **Description** | Background audio sources — television, radio, another person speaking — trigger the "Hey Sahayak" wake word, causing the assistant to activate unintentionally. This leads to unintended LLM inference, unintended TTS output disturbing the user, and in the worst case background audio forming a near-complete command sequence after a false activation. |
| **Affected Components** | WakeWordDetector, VoiceSessionCoordinator, AudioSessionManager, STTEngine |
| **Likelihood** | M — openWakeWord models have a configurable false positive rate; television and radio are common sources of false triggers for always-on assistants |
| **Impact** | L — LLM is isolated from safety-critical paths; false activation results in annoyance and wasted inference, not direct safety harm. Combined with THREAT-002 (adversarial voice input), a false activation followed by crafted audio raises the impact to M. |
| **Risk Rating** | MEDIUM |
| **Mitigations in Current Design** | (1) Custom model trained on "Hey Sahayak" — not a generic English wake word, reducing false positives from English-language television. (2) detectionThreshold is configurable (default 0.5) via remote config. (3) Sensitive commands require biometric authentication — a false activation cannot execute a sensitive command without auth. (4) Wake word detection stops during active voice session to avoid double-trigger. |
| **Residual Risk** | LOW-MEDIUM — openWakeWord accuracy for custom Nepali phrases must be validated empirically. |
| **Required Actions** | RECOMMENDED: (a) Define an acceptance criterion for false positive rate for the custom "Hey Sahayak" model (e.g. fewer than 1 false activation per 8-hour period in typical home environment). (b) Implement a voice session timeout — if no valid STT result is received within 5 seconds of wake-word activation, return to IDLE without LLM inference, reducing the window for crafted audio to compose an unintended command. |

---

### THREAT-007: Medication Reminder Suppression

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-007 |
| **Category** | Denial of Service (D) / Tampering (T) |
| **Description** | Medication reminders fail to fire due to: (a) a malicious or buggy config payload deleting or emptying the medication schedule, (b) OS-level alarm suppression from battery optimisation killing the reminder scheduler, (c) a bug in MedicationScheduler causing reminders to be silently dropped, or (d) EncryptedLocalStorage failure causing reminder state loss. |
| **Affected Components** | MedicationScheduler, EncryptedLocalStorage, AlarmManager (Android), BGTaskScheduler (iOS), ConfigApplicator, ConfigSchemaValidator |
| **Likelihood** | L (malicious config) / M (OS battery optimisation on Android) |
| **Impact** | H — Missed medication for an elderly user can have serious health consequences |
| **Risk Rating** | HIGH |
| **Mitigations in Current Design** | (1) MedicationScheduler persists each reminder to EncryptedLocalStorage before setting the OS alarm — ReminderPersistenceFailed blocks alarm scheduling with no silent drop (L2 section 5.4). (2) scheduleAll() re-arms reminders on app relaunch, recovering from process kill. (3) AlarmManager.setExactAndAllowWhileIdle() with USE_EXACT_ALARM permission survives Android Doze mode. (4) START_STICKY foreground service re-arms reminders on service restart. (5) Config schema validation rejects malformed schedules before application. (6) iOS uses local notifications as primary mechanism with BGTask as supplemental (L2 section 14). |
| **Residual Risk** | LOW-MEDIUM — Android battery optimisation is an ongoing platform risk; iOS BGTaskScheduler execution budget constraints are a known risk. Both have documented mitigations. |
| **Required Actions** | RECOMMENDED: (a) Explicitly test Android Doze mode reminder delivery with USE_EXACT_ALARM. (b) Specify what happens if a ConfigPayload contains an empty medication schedule — is this treated as "delete all medications" or "no change to medication schedule"? This safety-critical ambiguity must be resolved before implementation. |

---

### THREAT-008: PIN Brute Force Attack

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-008 |
| **Category** | Elevation of Privilege (E) |
| **Description** | An attacker with physical access to the device iterates through common PIN combinations to bypass the PIN fallback authentication, exploiting the absence of a defined lockout policy on the PIN path. |
| **Affected Components** | PinFallbackAuth, AuthCoordinator, EncryptedLocalStorage |
| **Likelihood** | M — Physical access is required; PIN fallback is only reachable after 3 biometric failures; attacker must first defeat biometric |
| **Impact** | M — PIN bypass grants access to sensitive commands |
| **Risk Rating** | MEDIUM |
| **Mitigations in Current Design** | (1) Argon2id with 64 MB memory, 3 iterations, parallelism 4 — makes offline brute force computationally expensive (L2 section 6.2). (2) PinHashMismatch returns a typed failure — calling AuthCoordinator tracks failure count. |
| **Residual Risk** | MEDIUM — The L2 design does not explicitly define PIN attempt lockout policy for the PIN fallback path. The biometric path has a documented 3-failure lockout, but the PIN path's lockout (rate limiting, maximum attempts, delay between attempts) is not specified. |
| **Required Actions** | BLOCKER: AuthCoordinator or PinFallbackAuth MUST define an explicit PIN attempt lockout policy before implementation: (a) maximum PIN attempts before temporary lockout (recommended 5–10 attempts), (b) lockout duration schedule (recommended exponential: 1 min, 5 min, 15 min, permanent), (c) recovery path after permanent lockout (e.g. family contact notification, device re-enrolment). Without this, the current design has an unmitigated online brute-force path at the PIN fallback level. |

---

### THREAT-009: LLM Process Crash Impact on Safety-Critical Paths

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-009 |
| **Category** | Denial of Service (D) |
| **Description** | The LlamaInferenceEngine (llama.cpp) crashes, hangs, or is OOM-killed by the OS, causing the on-device LLM to become unavailable. A design flaw that creates a dependency on the LLM process could block emergency dispatch, health monitoring, or medication reminders. |
| **Affected Components** | LlamaInferenceEngine, EmergencyDispatcher, HealthMonitorService, MedicationScheduler, CancelListenerService, TTSEngine |
| **Likelihood** | M — LLaMA 3.2 3B at approximately 2 GB RAM on a device that may also have other apps running; OOM is a realistic scenario |
| **Impact** | H (if safety paths are blocked) / L (if isolation is working as designed) |
| **Risk Rating** | HIGH (design must confirm isolation) |
| **Mitigations in Current Design** | (1) Architecture explicitly mandates LLM-independence for all safety-critical services (L1 section 9, FR-009, FR-034). (2) Module responsibility table confirms EmergencyDispatcher, HealthMonitorService, MedicationScheduler, and WakeWordDetector all have no LLM dependency (L1 Table 3.2). (3) CancelListenerService uses openWakeWord keyword spotting — not the LLM — for cancel detection during countdown (L1 section 9.1). (4) TTSEngine at emergency priority falls back to platform-native TTS if Coqui/Piper fails (L2 section 3.3). (5) EmergencyDispatcher runs as a dedicated process/OS service (L1 section 9). |
| **Residual Risk** | LOW — Design isolation is architecturally sound. Residual risk is implementation verification. |
| **Required Actions** | RECOMMENDED: (a) Implement a build-time module boundary check to ensure no safety-critical module imports LlamaInferenceEngine. (b) Add an explicit integration test: LLM process killed and then emergency dispatch still fires within 3 seconds, satisfying NFR-028 and the Gherkin scenario in requirements section 3 (Emergency dispatch not blocked by LLM unavailability). |

---

### THREAT-010: Companion App Impersonation — Malicious Config Push

| Field | Detail |
|-------|--------|
| **Threat ID** | THREAT-010 |
| **Category** | Spoofing (S) / Tampering (T) |
| **Description** | An attacker installs a modified or counterfeit companion app and attempts to push a malicious configuration payload to the primary device by impersonating a legitimate family member. The malicious payload could modify emergency contact numbers, suppress health thresholds, or alter medication schedules. |
| **Affected Components** | CompanionAuthService, SignalProtocolClient, RelayWebSocketClient, relay server KEY_REGISTER endpoint, ConfigSchemaValidator, ConfigApplicator |
| **Likelihood** | L — Signal Protocol mutual authentication via identity key exchange prevents impersonation after initial pairing |
| **Impact** | H — Malicious config could suppress emergency response |
| **Risk Rating** | MEDIUM (dependent on initial pairing security — see THREAT-005) |
| **Mitigations in Current Design** | (1) Signal Protocol identity key: the primary device only decrypts envelopes from the registered companion device's identity key. An impersonating app would need to compromise the companion device's private key stored in platform Keystore. (2) CompanionAuthService uses OS-level biometric — not custom auth. (3) ConfigSchemaValidator with allowlist-based field validation and safety bound checks on threshold values. (4) ConfigPayloadDecryptor rejects payload on failed MAC or decryption. |
| **Residual Risk** | LOW-MEDIUM — Residual risk concentrates in the initial key registration phase (see THREAT-005 recommended action on pairing flow). Once paired, Signal Protocol provides strong mutual authentication. |
| **Required Actions** | BLOCKER (shared with THREAT-005): Define and document the initial device pairing flow. The relay server KEY_REGISTER endpoint must authenticate registration requests — the current design shows KEY_REGISTER accepts a device_id, identity_key, and prekeys with no authentication mechanism specified. An attacker could register a device_id with a fraudulent identity key. The relay must enforce that each device_id to identity_key binding is set once and cannot be changed without explicit re-pairing. |

---

## 2. Security Controls Assessment

### Control 1: On-Device AI — No Cloud LLM Calls

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Standards (Privacy), Architecture Constraint 1, NFR-015 |
| **Design mechanism** | LLaMA 3.2 3B GGUF via llama.cpp; all inference on-device |
| **Assessment** | ADEQUATE — LLM isolation from cloud is architecturally enforced. No cloud AI API integration exists in the design. Module boundary table confirms all NLU is local. |
| **Gaps** | None at design level. Implementation must verify no network call is made from LlamaInferenceEngine. |

---

### Control 2: Voice Biometric Storage in Secure Enclave / Android Keystore

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards, NFR-009, FR-011 |
| **Design mechanism** | ECAPA-TDNN speaker embedding in iOS Secure Enclave (CryptoKit) / Android Keystore (KeyPairGenerator with AndroidKeyStore provider). Raw audio samples deleted post-enrolment. |
| **Assessment** | ADEQUATE — Storage location and deletion policy are explicitly specified. The embedding (not raw audio) is the persisted artifact. |
| **Gaps** | THREAT-001: liveness detection (PAD) not specified. Anti-spoofing is a gap in the biometric design. See BLOCKER-1. |

---

### Control 3: PIN Storage — Argon2id Salted Hash

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards, NFR-010, FR-014 |
| **Design mechanism** | Argon2id (memory: 64 MB, iterations: 3, parallelism: 4). Salt: 16 bytes random. Stored in EncryptedLocalStorage. Never plaintext. |
| **Assessment** | ADEQUATE — Argon2id parameters are strong. Memory-hardness resistant to GPU brute force. |
| **Gaps** | THREAT-008: PIN attempt lockout policy not defined. Argon2id protects against offline cracking but the online path (attacker at the device screen) needs lockout. See BLOCKER-2. |

---

### Control 4: E2E Encrypted Remote Config

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards, Architecture Constraint 2, NFR-012, FR-039 |
| **Design mechanism** | Signal Protocol double-ratchet (libsignal). Relay server is zero-knowledge — sees only ciphertext envelopes. Forward secrecy via ratchet. |
| **Assessment** | ADEQUATE — Signal Protocol is the strongest available E2E encryption standard with proven forward secrecy. Implementation is widely audited. |
| **Gaps** | Initial device pairing flow not specified — this is the critical bootstrapping risk. See BLOCKER-3. |

---

### Control 5: TLS 1.3 with Certificate Pinning

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards, NFR-011 |
| **Design mechanism** | URLSession (TLS 1.3, pinned certs) on iOS; OkHttp (TLS 1.3, pinned certs) on Android. Applied to relay WebSocket and Google Calendar API. |
| **Assessment** | ADEQUATE — TLS 1.3 and certificate pinning is the correct defence against MITM on transport layer. L2 section 7.4 confirms relay WebSocket client pins the certificate. |
| **Gaps** | FCM/APNs delivery paths use TLS inherently by platform design — this should be explicitly documented for completeness. |

---

### Control 6: Input Sanitisation at Quarantine Level

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards, NFR-013 |
| **Design mechanism** | InputSanitiser.sanitise(.quarantine) applied to all external inputs before LLM processing. Rules: strip model template tokens, reject role-override attempts, max 2000 chars. |
| **Assessment** | ADEQUATE at design level — quarantine level is the correct approach for a voice-input LLM. |
| **Gaps** | (a) The specific blocklist of adversarial patterns is not enumerated in the design and must be defined in implementation. (b) Calendar data and contact names loaded into the LLM system prompt context must also pass through sanitisation — L2 section 4.1 states this correctly but must be verified in ContextWindowManager during implementation. |

---

### Control 7: Encrypted At-Rest Local Storage

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards (FR-037), NFR-015 |
| **Design mechanism** | iOS: Core Data with NSFileProtectionComplete. Android: Room with SQLCipher and EncryptedSharedPreferences. |
| **Assessment** | ADEQUATE — Data Protection class Complete is the strongest iOS protection level. SQLCipher provides strong Android database encryption. |
| **Gaps** | Confirm HealthAlertLog.value (actual health metric readings) is stored via EncryptedLocalStorage. Confirm RemoteConfigEnvelope.signal_ratchet_state is stored via EncryptedLocalStorage and not unencrypted app-container storage. |

---

### Control 8: PII-Free Logs

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Privacy standards, NFR-016 |
| **Design mechanism** | LogSanitiser wraps ObservabilityBus at emission. All events exclude health values, voice transcripts, biometric scores, names, contacts, medication names. Entry IDs in events are one-way hashes. |
| **Assessment** | ADEQUATE — The design is thorough. Every observability event in L2 is explicitly listed and confirmed to exclude PII. The entry_id_hash pattern is correct. |
| **Gaps** | None at design level. Implementation must verify the sanitiser is not bypassed by direct log writes that bypass ObservabilityBus. |

---

### Control 9: Safety-Critical Path LLM Independence

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Safety-Critical Constraints, FR-009, FR-034, NFR-008 |
| **Design mechanism** | Dedicated OS services for EmergencyDispatcher, HealthMonitorService, MedicationScheduler. Rule-based threshold evaluation. CancelListenerService uses openWakeWord keyword spotter for cancel detection. |
| **Assessment** | ADEQUATE — The isolation is architecturally sound and explicitly documented. Module responsibility table confirms no LLM dependency on any safety-critical component. |
| **Gaps** | Build-time module boundary enforcement not yet specified. See REC-2. |

---

### Control 10: Permission Minimisation

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Compliance standards, NFR-017, NFR-018 |
| **Design mechanism** | Only blood pressure and heart rate HealthKit/Health Connect types requested. Permissions requested at point of use with plain-language justification. |
| **Assessment** | ADEQUATE — Design explicitly restricts health data types to MVP requirements. |
| **Gaps** | A complete Android permissions manifest is not yet enumerated. This must be produced and reviewed before implementation. |

---

### Control 11: Emergency Contact Data Encryption

| Item | Detail |
|------|--------|
| **Standard reference** | Constitution Security standards (FR-037), Architecture Constraint 1 |
| **Design mechanism** | Contact entities with is_emergency_contact flag and AppConfig.emergency_number stored in EncryptedLocalStorage. |
| **Assessment** | ADEQUATE — Emergency contact data is covered by the EncryptedLocalStorage layer. |
| **Gaps** | None identified. |

---

### Control 12: Config Atomicity and Rejection on Validation Failure

| Item | Detail |
|------|--------|
| **Standard reference** | FR-041, L2 section 7.2 |
| **Design mechanism** | ConfigSchemaValidator allowlist-based field validation. ConfigApplicator all-or-nothing apply with rollback on storage write failure. |
| **Assessment** | ADEQUATE — Partial config application is correctly prohibited. Rejection path is well-specified. |
| **Gaps** | Null or empty medication schedule handling ambiguity must be resolved. See REC-3. |

---

## 3. GO / NO_GO Decision

**Decision: GO — with three blocking required actions that must be resolved before implementation begins.**

### Justification

Criteria for GO (all met):

1. All HIGH risk threats have mitigations:
   - THREAT-001 (Voice biometric spoofing) — HIGH — has mitigations (cosine similarity threshold, SE/Keystore storage, post-enrolment sample deletion, 3-failure lockout). A liveness detection gap is flagged as BLOCKER-1.
   - THREAT-003 (Emergency call manipulation) — HIGH — has mitigations (keyword-spotting cancel detection, safety bound validation in companion app and schema validator, Signal Protocol authentication for config). Safety bound enumeration gap is flagged within BLOCKER-3.
   - THREAT-007 (Medication reminder suppression) — HIGH — has mitigations (durable persistence, re-arm on launch, Doze-mode alarm, no silent drop policy). Empty schedule ambiguity flagged as REC-3.
   - THREAT-009 (LLM crash impact on safety paths) — HIGH — has mitigations (dedicated OS services, explicit no-LLM dependency design, rule-based threshold evaluation, fallback TTS for emergency). Design isolation confirmed adequate.

2. No critical gaps in safety-critical path isolation — THREAT-009 assessment confirms architectural isolation is sound.

3. No plaintext storage of sensitive data — PIN stored as Argon2id hash, biometric embeddings in Secure Enclave/Keystore, health data in encrypted storage, config in encrypted storage. No plaintext storage of sensitive data identified.

4. E2E encryption confirmed for remote config — Signal Protocol double-ratchet confirmed in L1 and L2 design.

Reason the decision is GO and not NO_GO: The NO_GO criteria are: (a) HIGH risk threat with no mitigation, (b) safety-critical paths can be blocked by LLM crash, (c) biometric data stored outside Secure Enclave/Keystore. None of these conditions are met. The identified blockers are design gaps that must be addressed before code is written, not evidence that the current design is fundamentally unsafe.

---

## 4. Required Actions Before Implementation (Blockers)

### BLOCKER-1: Voice Biometric Liveness Detection (PAD)

Source: THREAT-001

The VoiceBiometricAuth component design must be updated to specify anti-spoofing (Presentation Attack Detection) controls before implementation. Options:

- Option A: Confirm the selected ECAPA-TDNN model variant includes a PAD module. Cite the specific model and its anti-spoofing benchmark result.
- Option B: Integrate a dedicated lightweight anti-spoofing model (e.g. AASIST) as a second-factor check alongside the ECAPA-TDNN embedding.
- Option C: Explicitly accept residual replay risk, document it as a risk acceptance with reasoning (e.g. physical device access required; attacker must obtain high-quality recording; three-failure lockout limits automation).

One of these options must be chosen and documented in an updated VoiceBiometricAuth specification.

---

### BLOCKER-2: PIN Fallback Lockout Policy

Source: THREAT-008

The AuthCoordinator design must define an explicit PIN attempt lockout policy including:
- Maximum consecutive PIN failures before lockout
- Lockout duration schedule (e.g. exponential back-off: 1 min, 5 min, 15 min, permanent)
- Recovery path (e.g. family contact notification, device re-enrolment required)
- Whether lockout state persists across app restarts

This must be specified before implementing PinFallbackAuth and AuthCoordinator.

---

### BLOCKER-3: Initial Device Pairing Flow Security

Source: THREAT-005, THREAT-010

The Signal Protocol initial device pairing flow must be designed and documented, covering:
- How the companion app obtains the primary device's Signal Protocol identity key for first session establishment
- What out-of-band verification is performed to prevent MITM during key exchange (e.g. QR code scan, key fingerprint comparison)
- How the relay server KEY_REGISTER endpoint prevents an attacker from registering a device_id with a fraudulent identity key (e.g. pre-shared registration token, app attestation via iOS DeviceCheck or Android Play Integrity)
- Whether a device_id to identity_key binding can be changed, and if so, what the re-pairing security flow requires
- Safety bound validation rules for all health threshold fields (diastolic BP and heart rate bounds in addition to systolic)

---

## 5. Recommended Actions (Non-Blockers)

### REC-1: Cancel Keyword False Positive Rate Reduction (THREAT-003)

- Define an acceptance criterion for false positive rate of the cancel keyword model (e.g. fewer than 1 false cancellation per 8 hours in typical home environment).
- Consider requiring two consecutive detections within 3 seconds to accept cancellation.
- Enumerate all health threshold safety bounds in ConfigSchemaValidator and AlertThresholdEditor.

### REC-2: LLM Module Boundary Enforcement (THREAT-009)

- Implement a build-time module boundary check to ensure no safety-critical module imports LlamaInferenceEngine.
- Add an integration test: LLM process killed and then emergency dispatch still fires within 3 seconds, satisfying NFR-004 and NFR-028.

### REC-3: Empty Medication Schedule Handling (THREAT-007)

- Specify whether a ConfigPayload with an empty or null medication schedule is treated as "delete all medications" or "no change to schedule".
- If delete-all is permitted via remote config, require an explicit confirmation flag in the schema to prevent accidental deletion.

### REC-4: Wake Word Session Timeout (THREAT-006)

- Implement a voice session timeout: if no valid STT result is received within 5 seconds of wake-word activation, return to IDLE without invoking LLM inference.

### REC-5: Adversarial Input Observability (THREAT-002)

- Add an observability event for suspicious input pattern detection (count and pattern category only, no content) to enable detection of adversarial input attempts in production.
- Maintain a living blocklist of LLaMA 3.2 adversarial chat-template patterns and test against it during implementation.

### REC-6: Full Android Permissions Manifest Review

- Before implementation, produce and review a complete Android permissions manifest against the principle of least privilege.
- Confirm no permissions are requested beyond those required for declared MVP features.

### REC-7: HealthAlertLog Encryption Confirmation

- Confirm in implementation that HealthAlertLog.value (the actual health metric reading) is stored via the EncryptedLocalStorage layer.
- Confirm RemoteConfigEnvelope.signal_ratchet_state is stored via EncryptedLocalStorage.

### REC-8: Relay Server Device Registration Authentication

- Specify authentication controls on the relay server KEY_REGISTER endpoint to prevent unauthorised device registration.
- Options: pre-shared registration token generated during device pairing, iOS DeviceCheck, or Android Play Integrity API attestation.

---

## 6. Traceability

| Threat ID | Risk Rating | Constitution Requirement | Action |
|-----------|-------------|--------------------------|--------|
| THREAT-001 | HIGH | NFR-009, FR-011, Constitution Security | BLOCKER-1 |
| THREAT-002 | MEDIUM | NFR-013, FR-007 | REC-5 |
| THREAT-003 | HIGH | FR-033, FR-036, FR-041 | BLOCKER-3 partial + REC-1 |
| THREAT-004 | MEDIUM | NFR-015, NFR-016, NFR-017 | REC-7 |
| THREAT-005 | MEDIUM | FR-039, NFR-012, Constitution Security | BLOCKER-3 |
| THREAT-006 | MEDIUM | FR-004, NFR-006 | REC-4 |
| THREAT-007 | HIGH | FR-026 through FR-029, NFR-027 | REC-3 |
| THREAT-008 | MEDIUM | NFR-010, FR-014 | BLOCKER-2 |
| THREAT-009 | HIGH | FR-009, FR-034, NFR-008 | REC-2 |
| THREAT-010 | MEDIUM | FR-039, FR-041, NFR-012 | BLOCKER-3 |

---

*Security Design Review completed. Decision: GO with blockers BLOCKER-1, BLOCKER-2, and BLOCKER-3 to be resolved before implementation.*
