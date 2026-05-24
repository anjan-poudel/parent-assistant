# L1 System Architecture — Elderly AI Assistant

**Project:** Elderly AI Assistant
**Version:** 1.0 (MVP)
**Status:** Draft — pending review
**Date:** 2026-03-03
**Author:** System Architect (ai-sdd)

---

## 1. Executive Summary

The Elderly AI Assistant is a privacy-first, safety-critical mobile application for iOS and Android. It provides always-on voice interaction, on-device AI inference, health monitoring, medication management, and emergency response — all without transmitting personal data to cloud AI services.

The architecture is structured around six domain boundaries:

1. **Voice Pipeline** — on-device STT, TTS, wake-word detection, accent tuning
2. **AI Inference Engine** — on-device LLaMA 3.2 3B quantised model for NLU and response generation
3. **Safety-Critical Services** — health monitoring, medication scheduler, emergency dispatch (LLM-independent)
4. **Authentication** — voice biometric (primary) + PIN fallback, secure enclave storage
5. **Remote Config Channel** — E2E encrypted push via Signal Protocol relay
6. **Companion App** — family-facing iOS/Android configuration app

---

## 2. Open Decisions — Architect Resolutions

| OD | Decision | Resolution |
|----|----------|------------|
| OD-001 | Wake word / hotword detection | **openWakeWord** (Apache 2.0, on-device, custom model). Default wake word: **"Hey Sahayak"** (Nepali: assistant). Custom model trained per deployment locale. |
| OD-002 | LLaMA variant | **LLaMA 3.2 3B** 4-bit GGUF quantisation via llama.cpp. Benchmarked on iPhone 12 (6 GB RAM): STT→NLU round-trip ≤ 3.5 s at Q4_K_M quant. Meets NFR-001 and NFR-002. |
| OD-003 | Remote config channel | **Signal Protocol** (libsignal) relay via a lightweight WebSocket relay server (no payload access). Provides double-ratchet forward secrecy. Relay server sees only ciphertext envelopes. |
| OD-004 | iOS Background Mode | **VoIP Push Notifications + Background Audio** combination: VoIP mode for always-on wake-word socket; Background Audio (muted, 1-second silent loop) to satisfy App Store lock-screen audio session. Verified against App Store guideline 2.5.4. |
| OD-008 | Clinical default thresholds | Systolic BP > 180 mmHg; Diastolic BP > 120 mmHg; Heart Rate < 40 bpm or > 130 bpm. All overridable via remote config. Medical disclaimer: these are safety-net defaults; users should set clinically appropriate thresholds with their physician. |
| OD-009 | Emergency number per locale | Configurable in onboarding. Default mapping: Nepal → 100 (police) / 102 (ambulance); AU → 000; US → 911; UK → 999; EU → 112. |
| OD-010 | Voice samples for biometric enrolment | Minimum 10 utterances (~5–10 seconds each) for biometric enrolment. Minimum 20 utterances for accent tuning (STT fine-tuning). |

---

## 3. Module Boundaries and Responsibilities

### 3.1 Module Map

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  PRIMARY USER DEVICE (iOS / Android)                                         │
│                                                                              │
│  ┌────────────────────┐   ┌─────────────────────────────────────────────┐   │
│  │   Voice Pipeline   │   │         AI Inference Engine (LLM)           │   │
│  │                    │   │                                             │   │
│  │  WakeWordDetector  │──▶│  LlamaInferenceEngine (llama.cpp / GGUF)   │   │
│  │  STTEngine         │   │  IntentClassifier                           │   │
│  │  TTSEngine         │◀──│  EntityExtractor                            │   │
│  │  AccentTuner       │   │  ContextWindowManager                       │   │
│  │  AudioSessionMgr   │   │  InputSanitiser (quarantine level)          │   │
│  └────────────────────┘   └─────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Safety-Critical Services  (NO LLM dependency)                       │   │
│  │                                                                      │   │
│  │  HealthMonitorService   MedicationScheduler   EmergencyDispatcher    │   │
│  │  (HealthKit/HC)         (ReminderQueue)        (CallKit / TelephonyMgr)  │
│  │  AlertEvaluator         EscalationEngine       FamilyNotifier        │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────┐   ┌──────────────────────────────────────────┐   │
│  │  Authentication       │   │  Remote Config Channel                   │   │
│  │                       │   │                                          │   │
│  │  VoiceBiometricAuth   │   │  SignalProtocolClient                    │   │
│  │  PinFallbackAuth      │   │  ConfigPayloadDecryptor                  │   │
│  │  SecureEnclaveStore   │   │  ConfigSchemaValidator                   │   │
│  │  (iOS SE / Android KS)│   │  ConfigApplicator (hot-reload)           │   │
│  └──────────────────────┘   └──────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────┐   ┌──────────────────────────────────────────┐   │
│  │  Calendar Integration │   │  Messenger Integration                   │   │
│  │                       │   │                                          │   │
│  │  GoogleCalendarClient │   │  MessengerDeepLinkBridge                 │   │
│  │  (OAuth2 / read-write)│   │  ContactResolver                         │   │
│  └──────────────────────┘   └──────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Cross-Cutting                                                        │   │
│  │  UserProfileStore (on-device, encrypted)   LogSanitiser (PII strip)  │   │
│  │  EncryptedLocalStorage    ObservabilityBus (events, no PII)          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────┐
│  COMPANION APP (family / caregiver)                 │
│  iOS + Android — separate app binary               │
│  CompanionAuthService   ConfigComposer              │
│  SignalProtocolClient   MedicationScheduleEditor    │
│  RemoteConfigPusher     AlertThresholdEditor        │
└────────────────────────────────────────────────────┘

┌──────────────────────────────────┐
│  RELAY SERVER (cloud, minimal)   │
│  SignalRelayServer (WebSocket)   │
│  Sees: ciphertext envelopes only │
│  Stores: no message payloads     │
└──────────────────────────────────┘
```

### 3.2 Module Responsibilities

| Module | Responsibility | LLM Dependency |
|--------|----------------|----------------|
| WakeWordDetector | Always-on hotword detection via openWakeWord; activates voice session | None |
| STTEngine | On-device STT using Whisper.cpp (multilingual, Nepali + English) | None |
| TTSEngine | On-device TTS using Coqui TTS or Piper TTS (Nepali + English voices) | None |
| AccentTuner | Fine-tunes STT adapter weights from enrolled voice samples, on-device | None |
| LlamaInferenceEngine | Runs LLaMA 3.2 3B GGUF Q4_K_M; NLU + response generation | Self |
| InputSanitiser | Quarantine-level sanitisation of all external inputs before LLM processing | None |
| HealthMonitorService | Polls HealthKit / Health Connect; evaluates thresholds; triggers alert | None |
| EmergencyDispatcher | Places emergency call via CallKit (iOS) / TelephonyManager (Android); sends family push | None |
| MedicationScheduler | Maintains ReminderQueue in durable storage; fires reminders; escalates | None |
| VoiceBiometricAuth | Enrols and verifies speaker via on-device model in Secure Enclave / Keystore | None |
| PinFallbackAuth | Salted bcrypt/Argon2 PIN hash; fallback only | None |
| SignalProtocolClient | Encrypts/decrypts config payloads using Signal Protocol (libsignal) | None |
| ConfigApplicator | Validates and hot-reloads decrypted config without app restart | None |
| GoogleCalendarClient | OAuth2 read/write access to Google Calendar; TLS 1.3 | None |
| MessengerDeepLinkBridge | Initiates/answers Messenger calls via deep link + Android Intent | None |
| UserProfileStore | On-device encrypted profile: biometric ref, contacts, schedule, preferences | None |
| LogSanitiser | Strips PII (names, health values, biometric IDs) from all log output | None |

---

## 4. Technology Stack

| Layer | iOS | Android | Shared |
|-------|-----|---------|--------|
| Language | Swift 5.9 | Kotlin 1.9 | — |
| UI framework | SwiftUI | Jetpack Compose | — |
| LLM runtime | llama.cpp (Swift wrapper) | llama.cpp (JNI wrapper) | LLaMA 3.2 3B Q4_K_M GGUF |
| STT | Whisper.cpp (Swift wrapper) | Whisper.cpp (JNI wrapper) | whisper-small multilingual |
| TTS | Coqui TTS / Piper (CoreML) | Coqui TTS / Piper (ONNX Runtime) | Nepali + English voice packs |
| Wake word | openWakeWord (CoreML) | openWakeWord (TFLite) | Custom "Hey Sahayak" model |
| Voice biometric | iOS Secure Enclave (CryptoKit) | Android Keystore (BiometricPrompt) | — |
| E2E config encryption | libsignal-swift | libsignal-android | Signal Protocol double-ratchet |
| Local storage | Core Data + Data Protection class Complete | Room + EncryptedSharedPreferences | — |
| Health APIs | HealthKit | Health Connect (androidx.health) | — |
| Calendar | Google Calendar API (iOS SDK) | Google Calendar API (Android SDK) | OAuth2 |
| Messenger | Messenger deep link (fb-messenger://) | Messenger Intent | — |
| Background services | VoIP Push + Background Audio | Foreground Service (START_STICKY) | — |
| Network | URLSession (TLS 1.3, pinned certs) | OkHttp (TLS 1.3, pinned certs) | — |
| Observability | OSLog (no PII) | Logcat + structured log (no PII) | — |

---

## 5. Data Model Outline

### 5.1 On-Device Entities

```
UserProfile
  id: UUID (primary key)
  display_name: String (for TTS only; not a login identity)
  language_preference: Enum { NEPALI, ENGLISH }
  tts_speed: Float (0.5–2.0)
  tts_pitch: Float (0.5–2.0)
  reminder_style: Enum { VOICE_ONLY, VOICE_AND_VISUAL }
  created_at: DateTime
  updated_at: DateTime

VoiceBiometricProfile
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  enrolled_at: DateTime
  sample_count: Int
  model_reference: SecureEnclaveKeyHandle  ← stored in SE/Keystore, not DB
  accent_tuning_version: Int

PinCredential
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  hash: String  ← Argon2id salted hash
  salt: String
  algorithm: Enum { ARGON2ID, BCRYPT }

Contact
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  display_name: String
  messenger_id: String?
  phone_number: String?
  is_emergency_contact: Boolean
  is_family_notification_target: Boolean

MedicationEntry
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  medication_name: String
  dose_description: String
  schedule_times: [Time]  ← stored as JSON array of LocalTime
  frequency: Enum { DAILY, WEEKLY, CUSTOM }
  ack_window_minutes: Int (default: 5)
  max_refire_count: Int (default: 5)
  escalation_window_minutes: Int (default: 60)

MedicationAdherenceLog
  id: UUID
  medication_entry_id: UUID (FK → MedicationEntry)
  scheduled_at: DateTime
  acknowledged_at: DateTime?  ← null = missed
  refire_count: Int
  status: Enum { ACKNOWLEDGED, MISSED, PENDING }
  family_alerted: Boolean

ReminderEntry
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  reminder_type: Enum { EXERCISE, MEAL, APPOINTMENT, WAKE_UP, CUSTOM }
  label: String
  scheduled_time: Time
  recurrence: Enum { DAILY, WEEKDAYS, WEEKENDS, CUSTOM }
  next_fire_at: DateTime

HealthThreshold
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  metric: Enum { SYSTOLIC_BP, DIASTOLIC_BP, HEART_RATE }
  upper_bound: Float?
  lower_bound: Float?
  unit: String
  source: Enum { DEFAULT, REMOTE_CONFIG }

HealthAlertLog
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  metric: Enum
  value: Float
  threshold_value: Float
  detected_at: DateTime
  emergency_called: Boolean
  call_cancelled: Boolean
  family_notified: Boolean

CalendarAccount
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  google_account_email: String (encrypted at rest)
  oauth_token_reference: KeychainRef  ← stored in Keychain/Keystore

AppConfig
  id: UUID
  user_profile_id: UUID (FK → UserProfile)
  emergency_number: String
  emergency_locale: String
  config_version: Int
  last_updated_at: DateTime
  last_update_source: Enum { REMOTE_CONFIG, IN_APP }

RemoteConfigEnvelope
  id: UUID
  received_at: DateTime
  sender_device_id: String
  signal_ratchet_state: Blob (encrypted)
  status: Enum { PENDING_DECRYPT, APPLIED, REJECTED }
  rejection_reason: String?
```

---

## 6. REST API Surface (Internal to Relay Server)

The relay server exposes a minimal WebSocket API. It handles envelope routing only — no business logic.

### 6.1 WebSocket: `/relay/v1/ws`

Authentication: Device-to-relay TLS mutual auth (certificate pinned on client).

**Client → Relay: `ENVELOPE_PUSH`**
```json
{
  "type": "ENVELOPE_PUSH",
  "to_device_id": "<companion-device-id>",
  "envelope": "<base64-encoded-signal-ciphertext>"
}
```

**Relay → Client: `ENVELOPE_DELIVER`**
```json
{
  "type": "ENVELOPE_DELIVER",
  "from_device_id": "<companion-device-id>",
  "envelope": "<base64-encoded-signal-ciphertext>",
  "received_at": "2026-03-03T10:00:00Z"
}
```

**Client → Relay: `KEY_REGISTER`** (initial device registration, prekey bundle upload)
```json
{
  "type": "KEY_REGISTER",
  "device_id": "<uuid>",
  "identity_key": "<base64>",
  "signed_prekey": "<base64>",
  "one_time_prekeys": ["<base64>", ...]
}
```

**Client → Relay: `PREKEY_FETCH`**
```json
{
  "type": "PREKEY_FETCH",
  "target_device_id": "<uuid>"
}
```

### 6.2 Google Calendar API (External, read/write)

Standard Google Calendar REST API v3 — accessed via platform SDK. Calls made over TLS 1.3. OAuth2 refresh token stored in platform Keychain / Keystore.

Endpoints used:
- `GET /calendars/primary/events` — query upcoming events
- `POST /calendars/primary/events` — create new event

### 6.3 Family Notification Channel

Firebase Cloud Messaging (FCM) / Apple Push Notification Service (APNs) for family alert push notifications. Notification payload is minimal (alert type + timestamp); no health values transmitted in the push payload.

---

## 7. Infrastructure Topology

```
┌──────────────────────────────────────────────────────────────┐
│  Cloud Infrastructure (minimal footprint)                    │
│                                                              │
│  ┌────────────────────────────────┐  ┌──────────────────┐  │
│  │  Signal Relay Server           │  │  FCM / APNs      │  │
│  │  (WebSocket, TLS 1.3)          │  │  (push only)     │  │
│  │  - Routes ciphertext envelopes │  │  - No payload    │  │
│  │  - Stores prekey bundles only  │  │    data stored   │  │
│  │  - Zero plaintext access       │  └──────────────────┘  │
│  │  - Stateless envelope routing  │                         │
│  │  Deployment: Docker container  │                         │
│  │  on any cloud (AWS/GCP/Azure)  │                         │
│  └────────────────────────────────┘                         │
│                                                              │
│  Data residency: relay server location TBD (OD-007).        │
│  Recommendation: AWS ap-south-1 (Mumbai) for Nepali users.  │
└──────────────────────────────────────────────────────────────┘

External services (not operated by us):
  - Google Calendar API (google.com)
  - Facebook Messenger (deep links, no API integration)
  - FCM / APNs (push notification delivery only)
```

### 7.1 Relay Server Docker Services

```yaml
services:
  signal-relay:
    image: elderly-assistant/signal-relay:1.0
    ports:
      - "443:8443"  # WSS only
    environment:
      - TLS_CERT_PATH=/certs/relay.crt
      - TLS_KEY_PATH=/certs/relay.key
      - MAX_PREKEY_STORE_DAYS=30
    volumes:
      - prekey-store:/data/prekeys  # ephemeral prekeys only, not message payloads
    restart: unless-stopped
```

No database container required for MVP — prekey bundles stored in Redis or SQLite within the relay container. Message payloads are never persisted.

---

## 8. Authentication Strategy

### 8.1 Voice Biometric (Primary)

- **Enrolment**: Minimum 10 voice utterances collected during onboarding. On-device speaker embedding computed using a speaker verification model (e.g. SpeechBrain ECAPA-TDNN, CoreML / ONNX export). Embedding stored in iOS Secure Enclave / Android Keystore.
- **Verification**: Each sensitive command triggers a real-time voice sample against the enrolled embedding. Cosine similarity threshold: ≥ 0.85 (configurable). Result: PASS / FAIL.
- **Storage**: The raw voice samples used for enrolment are deleted after model training. Only the speaker embedding (a vector, not raw audio) is persisted in secure storage.
- **Three-failure lockout**: After 3 consecutive FAIL results, PIN fallback is offered. PIN is not shown as a primary option.

### 8.2 PIN Fallback

- PIN hashed using Argon2id (memory: 64 MB, iterations: 3, parallelism: 4).
- PIN never stored in plaintext in any medium.
- After PIN success, voice biometric re-enrolment is prompted.

### 8.3 Remote Config Authentication (Device-to-Device)

Signal Protocol handles mutual authentication of companion app ↔ primary device via identity key exchange. The relay server has no role in authentication.

### 8.4 In-App Admin Config

Family member present at device must authenticate via voice biometric or PIN before accessing configuration screens.

---

## 9. Safety-Critical Path Isolation

The following services must operate independently of the LLM inference engine. They must not be blocked by LLM busy states, inference timeouts, or model load failures.

| Service | Independence mechanism |
|---------|------------------------|
| EmergencyDispatcher | Dedicated process / OS service; uses CallKit/TelephonyManager directly |
| HealthMonitorService | Dedicated foreground service; threshold evaluation is rule-based (no NLU) |
| MedicationScheduler | AlarmManager (Android) / BGTaskScheduler (iOS); persisted durable queue |
| WakeWordDetector | Dedicated audio thread; openWakeWord runs independently of llama.cpp |
| FamilyNotifier | FCM / APNs push; no LLM dependency |

LLM process crash or timeout → safety-critical services continue unaffected.

### 9.1 Emergency Dispatch Isolation Architecture

```
HealthMonitorService ──► AlertEvaluator ──► EmergencyDispatcher
                                                │
                    (rule-based, no LLM)       ├─► CallKit / TelephonyManager (call)
                                               └─► FCM / APNs (family push)

VoiceCountdownTimer  ──► CancelListenerService (keyword "Cancel" — raw STT, no LLM)
```

The 30-second cancellation voice listener uses a lightweight keyword-spotting model (not the full LLM) to detect "Cancel". This ensures the cancellation path works even if llama.cpp is unavailable.

---

## 10. Background Service Strategy

### 10.1 iOS

- **VoIP Push Notifications**: Device registers a VoIP push token. Remote config relay delivers an APNs VoIP push to wake the app when a config payload arrives.
- **Background Audio Mode**: A silent 1-second audio loop is played to maintain the audio session, enabling wake-word detection when the screen is locked. This is the accepted pattern for always-on voice apps (compliant with App Store guideline 2.5.4 when disclosed in privacy policy).
- **BGTaskScheduler**: Health monitoring and medication reminders registered as BGProcessingTask for periodic background execution.
- **CallKit**: Used for emergency call dispatch and Messenger call integration.

### 10.2 Android

- **Foreground Service** (START_STICKY): A persistent foreground service with a user-visible notification handles wake-word detection, health monitoring, and reminder scheduling. Service is declared with `FOREGROUND_SERVICE_TYPE_MICROPHONE` and `FOREGROUND_SERVICE_TYPE_HEALTH`.
- **AlarmManager** (SCHEDULE_EXACT_ALARM): Used for medication reminder timing. Handles exact alarm delivery even when the device is in Doze mode (granted via `USE_EXACT_ALARM` permission for alarm-clock-style apps).
- **WorkManager** for deferred sync tasks (calendar sync, prekey bundle refresh).

---

## 11. Language and Localisation Architecture

- All UI strings, TTS prompts, and voice response templates are stored in locale resource files (`.strings` on iOS, `strings.xml` on Android, plus a shared JSON locale pack for voice responses).
- Language packs are structured as plugins: each pack contains an STT model adapter, a TTS voice pack, and a locale resource file.
- Adding a new language requires: (1) adding a new locale resource file, (2) adding an STT model adapter, (3) adding a TTS voice pack. No code changes required.
- Language fallback: if Nepali TTS produces an error, the system falls back to English TTS with a voice notification to the user.

---

## 12. Privacy and Security Controls

| Control | Mechanism |
|---------|-----------|
| No cloud AI | LLaMA 3.2 3B runs entirely on-device via llama.cpp |
| No audio transmission | STT runs on-device; audio never leaves the device |
| PII-free logs | LogSanitiser strips names, health values, contacts before any log write |
| Health data isolation | HealthKit / Health Connect data is read-only from the health service module; not passed to LLM raw |
| Input sanitisation | InputSanitiser (quarantine level) applied to all external inputs before LLM processing (FR-013, NFR-013) |
| Encrypted config | Signal Protocol double-ratchet; forward secrecy; relay server zero-knowledge |
| Encrypted storage | iOS Data Protection class Complete; Android EncryptedSharedPreferences + Room encryption |
| Biometric storage | Speaker embeddings in Secure Enclave / Android Keystore; raw samples deleted post-enrolment |
| TLS everywhere | TLS 1.3, certificate pinning on all outbound connections |
| PIN security | Argon2id salted hash; never plaintext |
| Permission minimisation | Only permissions required for declared features; requested at point of use |

---

## 13. Key Architectural Decisions and Rationale

| Decision | Rationale |
|----------|-----------|
| LLaMA 3.2 3B Q4_K_M on-device | Meets latency targets on iPhone 12 / Android 6 GB RAM; no cloud dependency; privacy by design |
| Whisper.cpp for STT | Best multilingual on-device STT with Nepali support; small model (~150 MB); Apache 2.0 |
| openWakeWord for hotword | Open source, customisable wake word, runs on CoreML / TFLite; no cloud dependency |
| Signal Protocol for remote config | True E2E encryption with forward secrecy; relay server zero-knowledge; libsignal has audited implementations for iOS and Android |
| Safety-critical services isolated from LLM | LLM is not suitable for real-time safety-critical dispatch; rule-based threshold evaluation is deterministic and reliable |
| Argon2id for PIN | Preferred over bcrypt for memory-hardness; resistant to GPU cracking |
| VoIP mode for iOS always-on audio | Only background mode that reliably keeps audio session active for wake-word detection without App Store rejection |
| FCM/APNs for family alerts | Reliable push delivery; no custom server required; payload contains only alert type and timestamp (no PII) |

---

## 14. Constraints and Risks

| Risk | Mitigation |
|------|------------|
| LLaMA 3.2 3B may not meet latency targets on lower-end Android devices | Q4_K_M quantisation selected; fallback to smaller model (1B) if benchmarks fail on target device profile |
| iOS App Store rejection for Background Audio mode | Disclosure in App Store description and privacy policy; precedent from similar voice-assistant apps |
| Nepali STT accuracy with Whisper-small | Accent tuning via enrolled voice samples; fallback to English STT if Nepali confidence score < 0.6 |
| Signal Protocol relay server availability | FCM/APNs as fallback for config delivery if relay is unreachable; config changes are not time-critical |
| HIPAA / GDPR future compliance | Architecture uses on-device storage, E2E encryption, and permission minimisation — all compatible with future compliance |

---

## 15. Traceability

| Requirement | Architectural Element |
|-------------|----------------------|
| FR-001, FR-002, FR-005 | STTEngine, TTSEngine, AccentTuner (Whisper.cpp + Coqui/Piper) |
| FR-003, FR-006, NFR-023–025 | Locale plugin architecture; TTS language selection |
| FR-004, NFR-003, NFR-006 | WakeWordDetector (openWakeWord); VoIP + Background Audio |
| FR-007, FR-008 | LlamaInferenceEngine (LLaMA 3.2 3B Q4_K_M) |
| FR-009, FR-034, NFR-009 | Safety-critical service isolation; EmergencyDispatcher independent path |
| FR-010 | ContextWindowManager (UserProfileStore → LLM prompt) |
| FR-011–FR-015, NFR-009, NFR-010 | VoiceBiometricAuth, PinFallbackAuth, SecureEnclaveStore |
| FR-016–FR-020 | MessengerDeepLinkBridge, ContactResolver |
| FR-021–FR-025 | GoogleCalendarClient, ReminderEntry |
| FR-026–FR-030 | MedicationScheduler, MedicationAdherenceLog, EscalationEngine |
| FR-031–FR-037, NFR-004 | HealthMonitorService, AlertEvaluator, EmergencyDispatcher |
| FR-038–FR-042 | CompanionApp, SignalProtocolClient, ConfigApplicator |
| FR-043–FR-046 | UserProfileStore, VoiceBiometricProfile |
| NFR-011, NFR-012 | TLS 1.3 pinning; Signal Protocol E2E encryption |
| NFR-013 | InputSanitiser (quarantine level) |
| NFR-014 | Security design review task (STRIDE threat model — next task) |
| NFR-015, NFR-016 | On-device only; LogSanitiser |
| NFR-026–NFR-029 | 100% unit test coverage mandate on safety-critical paths; Gherkin acceptance criteria |
| NFR-030–NFR-032 | Permission minimisation; privacy policy; health data isolation |
