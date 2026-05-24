# L2 Component Design — Elderly AI Assistant

**Project:** Elderly AI Assistant
**Version:** 1.0 (MVP)
**Status:** Draft — pending review
**Date:** 2026-03-04
**Author:** Principal Engineer (ai-sdd)
**Input:** L1 Architecture (`design-l1.md`), Requirements (`define-requirements.md`)

---

## 1. Overview

This document provides the L2 component design for all six domain boundaries defined in the L1 architecture:

1. Voice Pipeline
2. AI Inference Engine
3. Safety-Critical Services
4. Authentication
5. Remote Config Channel
6. Companion App + Relay Server

For each component, this document specifies:
- Public interfaces and contracts
- Internal data models (where not already in L1)
- Error handling strategy
- Observability approach (events, metrics, no-PII)
- Performance and security implementation patterns
- Technical risks and mitigations

---

## 2. Cross-Cutting Component Contracts

### 2.1 Result Type Convention

All component interfaces use a typed `Result<T, E>` pattern. No thrown exceptions cross component boundaries. Platform-specific exceptions are caught at the adapter boundary and mapped to typed errors.

```swift
// Swift
enum Result<T, E: Error> {
    case success(T)
    case failure(E)
}
```

```kotlin
// Kotlin — use stdlib sealed Result
sealed class ComponentResult<out T> {
    data class Success<T>(val value: T) : ComponentResult<T>()
    data class Failure(val error: ComponentError) : ComponentResult<Nothing>()
}
```

### 2.2 Shared Error Taxonomy

```
ComponentError
  ├── VoiceError
  │     ├── MicrophonePermissionDenied
  │     ├── AudioSessionInterrupted
  │     ├── WakeWordModelLoadFailed(reason: String)
  │     ├── STTTimeout(elapsedMs: Long)
  │     └── TTSRenderFailed(reason: String)
  ├── InferenceError
  │     ├── ModelNotLoaded
  │     ├── InferenceTimeout(elapsedMs: Long)
  │     ├── ContextWindowOverflow
  │     └── InputSanitisationRejected(quarantineLevel: Int)
  ├── AuthError
  │     ├── BiometricEnrolmentIncomplete
  │     ├── BiometricVerificationFailed(attemptCount: Int)
  │     ├── PinHashMismatch
  │     ├── SecureStorageUnavailable
  │     └── MaxAttemptsExceeded
  ├── SafetyError
  │     ├── HealthPermissionRevoked
  │     ├── EmergencyCallFailed(reason: String)
  │     ├── ReminderPersistenceFailed
  │     └── FamilyNotificationFailed(reason: String)
  ├── ConfigError
  │     ├── DecryptionFailed
  │     ├── SchemaValidationFailed(fields: List<String>)
  │     └── PartialApplicationRejected
  └── StorageError
        ├── EncryptedWriteFailed
        └── EncryptedReadFailed
```

### 2.3 Observability Bus Interface

All components emit structured events to `ObservabilityBus`. Events carry no PII. `LogSanitiser` wraps the bus at the emission point.

```swift
protocol ObservabilityBus {
    func emit(_ event: ObservabilityEvent)
}

struct ObservabilityEvent {
    let component: String          // e.g. "voice_pipeline.stt"
    let eventType: String          // e.g. "stt_completed"
    let durationMs: Int?
    let outcome: String            // "success" | "failure" | "timeout"
    let errorCode: String?         // ComponentError case name, no message
    let metadata: [String: String] // pre-sanitised key-value pairs
}
```

No health values, voice transcriptions, biometric scores, names, or contact data appear in any `ObservabilityEvent`.

---

## 3. Voice Pipeline

### 3.1 WakeWordDetector

**Responsibility:** Continuously listen for the configured wake word using openWakeWord. Operates on a dedicated audio thread. Notified to `VoiceSessionCoordinator` on detection.

**Interface:**

```swift
protocol WakeWordDetector {
    /// Start continuous listening. Must be called after AudioSessionManager grants session.
    func start() -> Result<Void, VoiceError>
    /// Stop listening (e.g. during active voice session to avoid double-trigger).
    func stop()
    /// Update the active wake word model (hot-reload from remote config).
    func reloadModel(modelPath: String) -> Result<Void, VoiceError>
    var onDetected: (() -> Void)? { get set }
}
```

**Internal model:**

```
WakeWordDetectorState
  modelPath: String
  isRunning: Bool
  detectionThreshold: Float  (default: 0.5, configurable via remote config)
  audioBufferSizeMs: Int     (default: 80ms window)
```

**Error handling:**
- `ModelLoadFailed`: emit event, surface to `VoiceSessionCoordinator`, disable wake word (degraded mode — assistant still accessible via screen tap).
- `AudioSessionInterrupted` (phone call, alarm): stop, wait for `AVAudioSession.interruptionNotification` / Android `AudioManager.ACTION_AUDIO_BECOMING_NOISY`, restart.
- Re-enable within 2 seconds of interruption end (NFR-007).

**Observability events:** `wake_word.started`, `wake_word.stopped`, `wake_word.detected`, `wake_word.model_reload_success`, `wake_word.model_reload_failed`.

**Performance:** openWakeWord inference runs on CoreML (iOS) / TFLite (Android) at < 10 ms per 80 ms audio frame. CPU usage target: < 3% continuous.

---

### 3.2 STTEngine

**Responsibility:** Transcribe captured audio to text using Whisper.cpp. Applies the enrolled accent adapter before transcription if available.

**Interface:**

```swift
protocol STTEngine {
    /// Transcribe audio data. Returns full transcript or error.
    func transcribe(audio: AudioBuffer, language: Language) -> Result<STTResult, VoiceError>
    /// Load or reload the accent adapter (delta weights).
    func loadAccentAdapter(adapterPath: String) -> Result<Void, VoiceError>
}

struct STTResult {
    let transcript: String
    let confidenceScore: Float     // 0.0–1.0
    let language: Language         // detected or forced
    let durationMs: Int
}
```

**Error handling:**
- `STTTimeout` (> 2000 ms for transcription): return `Failure(.STTTimeout)`. Voice session coordinator announces "I didn't catch that, please repeat." No retry — user re-activates with wake word.
- Low confidence (< 0.5): `STTResult` is returned but flagged; NLU intent classifier may request clarification.
- If Nepali confidence < 0.6 and fallback English enabled: re-run transcription with `language: .english` and return the higher-confidence result (NFR-021 implicit).

**Observability events:** `stt.started`, `stt.completed{durationMs, outcome}`, `stt.timeout`, `stt.accent_adapter_loaded`.

No transcript text appears in any event.

**Performance target:** Whisper-small transcription ≤ 2000 ms (NFR-001). Accent adapter is applied as a delta — no full re-inference.

---

### 3.3 TTSEngine

**Responsibility:** Synthesise text to audio using Coqui TTS / Piper. Plays directly via `AudioSessionManager`.

**Interface:**

```swift
protocol TTSEngine {
    /// Synthesise and play text. Returns when audio playback completes or fails.
    func speak(text: String, language: Language, priority: TTSPriority) -> Result<Void, VoiceError>
    /// Interrupt current speech (for emergency announcements).
    func interrupt()
    /// Configure voice properties.
    func configure(speed: Float, pitch: Float)
}

enum TTSPriority {
    case normal       // queued
    case high         // interrupts queued items
    case emergency    // interrupts all, non-cancellable
}
```

**Error handling:**
- `TTSRenderFailed`: emit event. If `priority == .emergency`, attempt platform-native TTS fallback (`AVSpeechSynthesizer` / `TextToSpeech` Android). Emergency announcement must always play — silent failure is not acceptable.
- Language fallback: if Nepali TTS render fails, retry with English TTS and surface voice notification to user.

**Observability events:** `tts.started{priority}`, `tts.completed{durationMs}`, `tts.interrupted`, `tts.render_failed`, `tts.fallback_to_english`.

---

### 3.4 AudioSessionManager

**Responsibility:** Manage platform audio session lifecycle (iOS `AVAudioSession`, Android `AudioManager`). Coordinate between WakeWordDetector, STTEngine, and TTSEngine so they do not conflict.

**Interface:**

```swift
protocol AudioSessionManager {
    func requestMicrophoneAccess() async -> Result<Void, VoiceError>
    func activateForWakeWord() -> Result<Void, VoiceError>
    func activateForCapture() -> Result<Void, VoiceError>   // STT input
    func activateForPlayback() -> Result<Void, VoiceError>  // TTS output
    func deactivate()
    var isBackgroundAudioLoopActive: Bool { get }
}
```

**iOS-specific:** Silent background audio loop (1 s, muted) is started immediately after first app foreground and never stopped while `isWakeWordEnabled`. Managed entirely by `AudioSessionManager` — no other component starts background audio.

**Error handling:**
- `MicrophonePermissionDenied`: surface to user via screen notification and voice fallback. Log event. Do not retry silently.
- iOS audio session interruptions follow `AVAudioSession.setActive(false)` → interrupt → `setActive(true)` → resume. `WakeWordDetector.start()` is called again after resume.

---

### 3.5 AccentTuner

**Responsibility:** Fine-tune the STT accent adapter from enrolled voice samples. Runs as a background batch task during onboarding and re-enrolment.

**Interface:**

```swift
protocol AccentTuner {
    /// Enrol voice samples. Minimum: 20 utterances for accent tuning.
    func enrol(samples: [AudioBuffer], onProgress: (Float) -> Void) async -> Result<AccentAdapterPath, VoiceError>
    /// Update an existing adapter with additional samples.
    func update(adapterPath: String, newSamples: [AudioBuffer]) async -> Result<AccentAdapterPath, VoiceError>
    var currentAdapterVersion: Int { get }
}
```

**Storage:** Adapter weights stored in `EncryptedLocalStorage` under key `accent_adapter_v{version}`. Raw audio samples are deleted immediately after adapter training is complete (privacy requirement, L1 §12).

**Error handling:**
- Insufficient sample count (< 20): return `Failure(.insufficientSamples(required: 20, provided: count))`. Onboarding flow prompts user to provide more samples.
- Training failure: retain previous adapter version. No regression.

---

### 3.6 VoiceSessionCoordinator

**Responsibility:** Orchestrate the full voice interaction lifecycle: wake word → capture → STT → NLU → TTS response. Acts as the FSM for a single voice session.

**State machine:**

```
IDLE
  └─ wake word detected ──► LISTENING (STT capture starts)
       └─ end-of-utterance / timeout ──► TRANSCRIBING
            └─ transcript ready ──► AUTHENTICATING (if sensitive command)
                 │                 └─ auth passed ──► PROCESSING (NLU + LLM)
                 └─ (no auth required) ──────────────► PROCESSING
                      └─ response ready ──► RESPONDING (TTS)
                           └─ playback complete ──► IDLE
```

**Error recovery:**
- Any failure in TRANSCRIBING returns to IDLE after TTS "sorry" message.
- AUTHENTICATING failure after 3 attempts → PIN fallback → PROCESSING or IDLE.
- PROCESSING timeout (> 3500 ms LLM, NFR-002) → TTS "still thinking, one moment" → retry once → failure → IDLE.

---

## 4. AI Inference Engine

### 4.1 LlamaInferenceEngine

**Responsibility:** Run LLaMA 3.2 3B Q4_K_M GGUF via llama.cpp. Manage model loading, context window, and inference. No safety-critical paths depend on this component.

**Interface:**

```swift
protocol LlamaInferenceEngine {
    /// Load model into memory. Should be called at app launch in background.
    func load() async -> Result<Void, InferenceError>
    /// Unload model (low memory warning).
    func unload()
    /// Run inference. Returns generated text or error.
    func infer(prompt: String, maxTokens: Int, temperature: Float) async -> Result<InferenceResult, InferenceError>
    var isLoaded: Bool { get }
    var memoryUsageMB: Int { get }
}

struct InferenceResult {
    let text: String
    let tokensGenerated: Int
    let durationMs: Int
    let finishReason: FinishReason  // .maxTokens | .endOfSequence | .timeout
}
```

**Context window management (ContextWindowManager):**

```swift
protocol ContextWindowManager {
    /// Assemble system prompt from UserProfile and current session state.
    func buildSystemPrompt(profile: UserProfile, sessionContext: SessionContext) -> String
    /// Trim context to fit within model's context window (4096 tokens for 3B model).
    func trimContext(messages: [Message], maxTokens: Int) -> [Message]
}
```

Context window budget:
- System prompt (profile, preferences, contacts summary): ≤ 512 tokens
- History: up to 1024 tokens (trimmed oldest-first)
- User utterance: ≤ 512 tokens
- Reserved for response: 2048 tokens

**InputSanitiser (quarantine level):**

```swift
protocol InputSanitiser {
    /// Apply quarantine-level sanitisation. Returns sanitised string or rejection.
    func sanitise(input: String, level: SanitisationLevel) -> Result<String, InferenceError>
}

enum SanitisationLevel {
    case quarantine   // blocks injection patterns, adversarial role-play, system prompt overrides
    case standard     // strips control characters only
}
```

Sanitisation rules (quarantine level):
- Strip or reject inputs containing model template tokens (e.g. INST delimiters, system/user/assistant role markers).
- Reject inputs with known adversarial patterns (role-override attempts, system prompt overrides, adversarial sequences).
- Maximum input length: 2000 characters. Truncate silently beyond limit.
- All external inputs (voice transcripts, calendar data, contact names loaded into prompt) pass through `sanitise(.quarantine)`.

**Error handling:**
- `ModelNotLoaded`: safety-critical services continue unaffected. Voice session coordinator announces "AI assistant is loading, please wait."
- `InferenceTimeout` (> 3500 ms, NFR-002): return timeout error. Session coordinator plays "still thinking" (once). On second timeout → IDLE + "please try again later."
- `ContextWindowOverflow`: trim context further (remove oldest messages first) and retry once.
- `InputSanitisationRejected`: log sanitisation event (no input content), return safe canned response.

**Memory management:**
- Model loaded at app launch in background thread.
- On iOS memory warning (level 2): unload model. Reload on next inference request.
- Target RAM footprint: Q4_K_M 3B ≈ 2.0 GB. Verified within iPhone 12 6 GB limit.

**Observability events:** `llm.load_started`, `llm.load_completed{durationMs}`, `llm.infer_started`, `llm.infer_completed{durationMs, tokensGenerated}`, `llm.infer_timeout`, `llm.input_sanitised_rejected`, `llm.context_trimmed`, `llm.unloaded_memory_pressure`.

---

### 4.2 IntentClassifier / EntityExtractor

These are prompt-engineering layers on top of `LlamaInferenceEngine`. They are not separate model processes.

**IntentClassifier** sends a structured classification prompt and parses the response JSON to determine intent (e.g. `CALL_CONTACT`, `QUERY_CALENDAR`, `SET_REMINDER`, `HEALTH_QUERY`, `GENERAL_CONVERSATION`).

**EntityExtractor** extracts typed entities (contact name, date/time, medication name, reminder type) from the transcribed utterance via a structured extraction prompt.

Both components use `InputSanitiser.sanitise(.quarantine)` before passing to the LLM.

---

## 5. Safety-Critical Services

All components in this section are LLM-independent. They must not be blocked by `LlamaInferenceEngine` state.

### 5.1 HealthMonitorService

**Responsibility:** Poll HealthKit / Health Connect at a configurable interval (default: 30 s). Evaluate readings against `HealthThreshold` entries. Trigger `AlertEvaluator` on threshold breach.

**Interface:**

```swift
protocol HealthMonitorService {
    func start() -> Result<Void, SafetyError>
    func stop()
    func updateThresholds(_ thresholds: [HealthThreshold])  // called by ConfigApplicator
    var pollingIntervalSeconds: Int { get set }  // configurable, default 30
}
```

**Implementation detail:** On iOS, uses `HKObserverQuery` for push-based updates plus a `BGProcessingTask` for periodic fallback. On Android, uses `PassiveListenerService` from Health Connect `androidx.health.services.client` for continuous monitoring.

**Error handling:**
- `HealthPermissionRevoked`: stop service, emit `health_monitor.permission_revoked` event, announce by voice "Health monitoring is unavailable — please check app permissions", send FCM/APNs push to family contacts. Must NOT fail silently (NFR requirement).
- Read error on individual metric: log error (no metric value in log), skip that reading cycle, continue monitoring.

**Observability events (no health values in any event):**
`health_monitor.started`, `health_monitor.stopped`, `health_monitor.permission_revoked`, `health_monitor.threshold_breach_detected{metric_name_only}`, `health_monitor.read_error{metric_name_only}`.

---

### 5.2 AlertEvaluator

**Responsibility:** Receive threshold breach notifications from `HealthMonitorService`. Evaluate deduplication (do not re-trigger if already in emergency countdown). Pass to `EmergencyDispatcher`.

**Interface:**

```swift
protocol AlertEvaluator {
    func evaluate(breach: ThresholdBreach) -> AlertDecision
}

struct ThresholdBreach {
    let metric: HealthMetric
    let value: Float
    let threshold: HealthThreshold
    let detectedAt: Date
}

enum AlertDecision {
    case dispatchEmergency(breach: ThresholdBreach)
    case suppress(reason: SuppressionReason)  // e.g. already in countdown, duplicate within 5 min
}
```

**Deduplication:** A breach for the same metric is suppressed if a countdown is already active for that metric, or if the previous call for that metric was within 5 minutes.

---

### 5.3 EmergencyDispatcher

**Responsibility:** Execute the full emergency response sequence (voice announcement → 30-second countdown → call + family notify). Runs on a dedicated process/service. No LLM dependency.

**Interface:**

```swift
protocol EmergencyDispatcher {
    func dispatch(breach: ThresholdBreach) async
    func cancel()  // user says "Cancel" — only valid during countdown
    var isCounting: Bool { get }
}
```

**Sequence:**
1. Play emergency announcement via `TTSEngine(.emergency)` — interrupts all other TTS.
2. Start 30-second `CountdownTimer`.
3. Activate `CancelListenerService` — lightweight keyword spotter ("Cancel") independent of LLM.
4. On "Cancel" detected: cancel timer, log cancellation, TTS confirm, done.
5. On timer expiry: `CallKitManager.placeCall(emergencyNumber)` / `TelephonyManager.call(emergencyNumber)`.
6. Simultaneously: `FamilyNotifier.notifyAll(breach)`.
7. Write `HealthAlertLog` entry (no health value in observability event, but full value in on-device encrypted log).

**Error handling:**
- `EmergencyCallFailed`: retry once after 3 s. If retry fails, log failure, TTS "Emergency call failed — please call [number] manually." Family notification must still be sent.
- `FamilyNotificationFailed`: log failure, continue. Call takes priority.
- If `TTSEngine` fails for emergency announcement: use platform-native TTS fallback (`AVSpeechSynthesizer` / Android `TextToSpeech`). Announcement must play.

**CancelListenerService:** Uses openWakeWord keyword detection (same runtime, different model) for "Cancel" keyword. Operates as a raw STT bypass — no NLU or LLM. Activates only during countdown.

---

### 5.4 MedicationScheduler

**Responsibility:** Maintain the `ReminderQueue` of pending medication reminders. Fire reminders at scheduled times. Escalate via re-fire up to 5 times within 60 minutes. Alert family on missed dose.

**Interface:**

```swift
protocol MedicationScheduler {
    func loadSchedule(entries: [MedicationEntry])
    func acknowledge(entryId: UUID, at: Date) -> Result<Void, SafetyError>
    func scheduleAll()  // called on app launch to reschedule any outstanding reminders
    var pendingReminders: [ScheduledReminder] { get }
}
```

**Durability:** Each `ScheduledReminder` is persisted to `EncryptedLocalStorage` before the OS alarm is set. On app relaunch, `scheduleAll()` reads outstanding reminders and re-arms platform alarms. This satisfies NFR-027 (process kill recovery).

**Platform alarms:**
- iOS: `BGTaskScheduler` (BGAppRefreshTask for reminder checks) + local notification with alert.
- Android: `AlarmManager.setExactAndAllowWhileIdle()` with `USE_EXACT_ALARM` permission. `START_STICKY` foreground service ensures re-arm on relaunch.

**Escalation logic:**
```
Reminder fires at T+0.
If not acknowledged within 12 min: re-fire (re-fire 1).
Repeat every 12 min: re-fires 2, 3, 4, 5.
If not acknowledged after re-fire 5 (T+60 min): mark MISSED, call FamilyNotifier.
```

**Error handling:**
- `ReminderPersistenceFailed`: do not set OS alarm until persistence confirmed. Fail visibly to the reminder scheduling flow — do not silently drop.

**Observability events:** `medication.reminder_fired{entry_id_hash}`, `medication.acknowledged{entry_id_hash}`, `medication.refire{entry_id_hash, refire_count}`, `medication.missed{entry_id_hash}`, `medication.family_alerted{entry_id_hash}`.

No medication names appear in any event. `entry_id_hash` is a one-way hash of the UUID.

---

### 5.5 FamilyNotifier

**Responsibility:** Send push notifications to family contacts via FCM (Android) / APNs (iOS). Notification payload: alert type + timestamp only. No PII, no health values.

**Interface:**

```swift
protocol FamilyNotifier {
    func notifyAll(alertType: FamilyAlertType, at: Date) async -> [NotificationResult]
}

enum FamilyAlertType {
    case emergencyCall(metric: HealthMetric)   // no value
    case missedMedication(entryIdHash: String) // no medication name
    case healthMonitoringInterrupted
    case configurationUpdateApplied
}
```

**Error handling:**
- Per-contact notification failure: log `NotificationResult.failure(contactIdHash, errorCode)`, continue with remaining contacts. Partial delivery is acceptable; silent total failure is not.

---

## 6. Authentication

### 6.1 VoiceBiometricAuth

**Responsibility:** Enrol and verify speaker identity. Embedding stored in iOS Secure Enclave / Android Keystore. Raw audio samples deleted post-enrolment.

**Interface:**

```swift
protocol VoiceBiometricAuth {
    /// Enrol from voice samples (minimum 10 utterances for auth, 20 for accent tuning — OD-010).
    func enrol(samples: [AudioBuffer]) async -> Result<EnrolmentRecord, AuthError>
    /// Verify speaker against enrolled embedding.
    func verify(sample: AudioBuffer) async -> Result<VerificationResult, AuthError>
    /// Delete enrolled profile (for re-enrolment or data erasure).
    func deleteProfile() -> Result<Void, AuthError>
    var enrolmentStatus: EnrolmentStatus { get }
}

struct VerificationResult {
    let passed: Bool
    let similarityScore: Float       // stored in Secure Enclave; not logged
    let threshold: Float             // configurable, default 0.85
}

enum EnrolmentStatus {
    case notEnrolled
    case enrolled(sampleCount: Int, enrolledAt: Date)
}
```

**Secure storage pattern:**
- The speaker embedding (ECAPA-TDNN output vector, ~192 floats) is stored as opaque data in iOS Secure Enclave (using `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave`) or Android Keystore (`KeyPairGenerator` with `AndroidKeyStore` provider).
- The raw audio samples used for enrolment are held in memory only and deleted immediately after `enrol()` completes — never written to disk.
- The similarity threshold (default: 0.85) is stored in `EncryptedLocalStorage` and configurable via remote config.

**Three-failure lockout:**

```swift
class BiometricAuthSession {
    private var failureCount: Int = 0
    private let maxFailures: Int = 3

    func attempt(sample: AudioBuffer) async -> AuthSessionResult {
        let result = await voiceBiometricAuth.verify(sample: sample)
        switch result {
        case .success(let v) where v.passed:
            failureCount = 0
            return .passed
        case .success:
            failureCount += 1
            if failureCount >= maxFailures {
                return .lockedOut  // triggers PIN fallback
            }
            return .failed(attemptsRemaining: maxFailures - failureCount)
        case .failure(let e):
            return .error(e)
        }
    }
}
```

**Error handling:**
- `SecureStorageUnavailable`: surface to user, disable sensitive commands, prompt re-enrolment.
- `BiometricEnrolmentIncomplete`: block sensitive commands, prompt onboarding completion.

**Observability events:** `biometric.enrol_started`, `biometric.enrol_completed{sampleCount}`, `biometric.verify_started`, `biometric.verify_passed`, `biometric.verify_failed{attemptCount}`, `biometric.lockout_triggered`, `biometric.profile_deleted`.

No similarity scores, embeddings, or audio data appear in any event.

---

### 6.2 PinFallbackAuth

**Responsibility:** Argon2id PIN verification. PIN is the fallback only — never presented as primary path.

**Interface:**

```swift
protocol PinFallbackAuth {
    func setPin(_ pin: String) -> Result<Void, AuthError>
    func verify(_ pin: String) -> Result<Bool, AuthError>
    func deletePin() -> Result<Void, AuthError>
}
```

**Hashing parameters (Argon2id):**
- Memory: 64 MB
- Iterations: 3
- Parallelism: 4
- Salt: 16 bytes, cryptographically random, unique per PIN set
- Output: 32 bytes

**Storage:** `PinCredential` record in `EncryptedLocalStorage`. The algorithm field allows future migration from Argon2id without data loss.

**Error handling:**
- `PinHashMismatch`: return `success(false)` (not an error — a valid failed verification). The calling `AuthCoordinator` tracks failure count.
- `SecureStorageUnavailable`: return `Failure(.SecureStorageUnavailable)`.

**Observability events:** `pin.set`, `pin.verify_passed`, `pin.verify_failed`, `pin.deleted`. No PIN values or hashes in any event.

---

### 6.3 AuthCoordinator

**Responsibility:** Orchestrate the full authentication flow for a sensitive command. Manages biometric → PIN fallback → re-enrolment prompt.

**Flow:**

```
SensitiveCommand received
  └─► BiometricAuthSession.attempt()
        ├─ passed ──────────────────────────────────────────► execute command
        ├─ failed (< 3 attempts) ──► TTS "Please try again" ─► retry
        └─ lockedOut ──► TTS "Voice not recognised" ─► PinFallbackAuth
              ├─ PIN passed ──► execute command ──► prompt biometric re-enrolment
              └─ PIN failed ──► TTS "Incorrect PIN" ──► max attempts ──► deny
```

---

## 7. Remote Config Channel

### 7.1 SignalProtocolClient

**Responsibility:** Encrypt outbound and decrypt inbound config payloads using Signal Protocol (libsignal). Manages double-ratchet state per session.

**Interface:**

```swift
protocol SignalProtocolClient {
    /// Initialise on first use (generates identity key, signed prekey, one-time prekeys).
    func initialise() async -> Result<PreKeyBundle, ConfigError>
    /// Encrypt a config payload for the target device.
    func encrypt(payload: Data, for targetDeviceId: String) -> Result<CiphertextEnvelope, ConfigError>
    /// Decrypt an incoming envelope.
    func decrypt(envelope: CiphertextEnvelope, from senderDeviceId: String) -> Result<Data, ConfigError>
    /// Refresh one-time prekeys if supply is running low.
    func refreshPreKeys() async -> Result<Void, ConfigError>
}
```

**Key storage:** All Signal Protocol keys (identity key, signed prekey, one-time prekeys, ratchet state) are stored as opaque blobs in `EncryptedLocalStorage`. The identity private key never leaves the device.

**Error handling:**
- `DecryptionFailed`: return `Failure(.DecryptionFailed)`. Do NOT process payload. Log `config.decryption_failed` event (no payload content). Notify companion app.
- Prekey exhaustion: trigger `refreshPreKeys()` asynchronously when supply drops below 5.

---

### 7.2 ConfigPayloadDecryptor + ConfigSchemaValidator

**Decryptor:**

```swift
protocol ConfigPayloadDecryptor {
    func decrypt(envelope: CiphertextEnvelope) -> Result<ConfigPayload, ConfigError>
}
```

Calls `SignalProtocolClient.decrypt()` then JSON-deserialises the plaintext.

**Validator:**

```swift
protocol ConfigSchemaValidator {
    func validate(_ payload: ConfigPayload) -> Result<ValidatedConfig, ConfigError>
}

struct ConfigPayload: Codable {
    let version: Int
    let timestamp: Date
    let fields: [String: AnyCodable]
}
```

Validation rules:
- `version` must be ≥ current `AppConfig.config_version`.
- All field keys must be in the allowed schema (allowlist, not denylist).
- Value types must match the schema for each field.
- On any validation failure: return `Failure(.SchemaValidationFailed(fields: [...]))`. The entire payload is rejected — no partial application (L1 §9 config relay invariant).

---

### 7.3 ConfigApplicator

**Responsibility:** Apply validated config changes to live services. Hot-reload without app restart.

**Interface:**

```swift
protocol ConfigApplicator {
    func apply(_ config: ValidatedConfig) -> Result<Void, ConfigError>
}
```

**Application order:**
1. Update `AppConfig` in `EncryptedLocalStorage`.
2. Push threshold changes to `HealthMonitorService.updateThresholds()`.
3. Push medication schedule changes to `MedicationScheduler.loadSchedule()`.
4. Push wake word model path to `WakeWordDetector.reloadModel()`.
5. TTS announce: "Your settings have been updated by [family member display name via TTS only]."

**Atomicity:** All in-memory updates are applied before the `AppConfig` write. If the write fails, in-memory changes are rolled back. The config is either fully applied or not applied at all.

---

### 7.4 Relay WebSocket Client

**Responsibility:** Maintain WebSocket connection to the Signal relay server. Receive and deliver config envelopes.

**Interface:**

```swift
protocol RelayWebSocketClient {
    func connect() async -> Result<Void, ConfigError>
    func disconnect()
    func send(envelope: CiphertextEnvelope, to deviceId: String) async -> Result<Void, ConfigError>
    var onEnvelopeReceived: ((CiphertextEnvelope, senderDeviceId: String) -> Void)? { get set }
    var connectionState: ConnectionState { get }
}
```

**Reconnection:** Exponential backoff (initial: 1 s, max: 60 s, jitter: ±20%). Reconnects automatically on network change. When offline, config updates are buffered in companion app and delivered on reconnection.

**Certificate pinning:** The relay server's TLS certificate (or its CA) is pinned in the app binary. Connection fails fast on pin mismatch — no fallback to system trust store.

---

## 8. Companion App

### 8.1 Architecture

The companion app (family / caregiver) is a separate app binary on iOS and Android. It shares the `SignalProtocolClient` library with the primary app.

**Core modules:**

| Module | Responsibility |
|--------|----------------|
| `CompanionAuthService` | Authenticate the family member (biometric / device PIN — OS-level). No custom auth — uses platform biometric. |
| `ConfigComposer` | Build a `ConfigPayload` from the edited schedule / thresholds / contacts. |
| `RemoteConfigPusher` | Calls `SignalProtocolClient.encrypt()` then `RelayWebSocketClient.send()`. |
| `MedicationScheduleEditor` | UI for adding/editing medication entries. Validates schedule logic (no duplicate times, ack window > 0). |
| `AlertThresholdEditor` | UI for editing health thresholds. Validates against minimum safety bounds (systolic ≥ 60, ≤ 300 mmHg etc.) before allowing save. |

### 8.2 Companion ↔ Primary Device Protocol

The companion sends `ConfigPayload` objects over the Signal-encrypted relay channel. The primary device applies them via `ConfigApplicator`. No direct app-to-app communication — all via relay.

---

## 9. Cross-Cutting: EncryptedLocalStorage

**Responsibility:** All on-device persistent data is stored via `EncryptedLocalStorage`. No unencrypted files are written by the app.

**Interface:**

```swift
protocol EncryptedLocalStorage {
    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError>
    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError>
    func delete(key: String) -> Result<Void, StorageError>
}
```

**Platform implementation:**
- iOS: Core Data with `NSFileProtectionComplete` (Data Protection class Complete) for entities. `SecureEnclave` for biometric keys (separate from storage interface).
- Android: Room database with `EncryptedSharedPreferences` for preferences; SQLCipher for Room database encryption.

**Error handling:** `EncryptedWriteFailed` / `EncryptedReadFailed` propagated to caller. Safety-critical reminder persistence failure blocks alarm scheduling (no silent drop).

---

## 10. Error Handling Strategy Summary

| Category | Strategy |
|----------|----------|
| LLM unavailable | Degrade gracefully: safety-critical services continue, voice session announces "loading" |
| Biometric failure | Locked out after 3 → PIN fallback → re-enrolment prompt |
| Health permissions revoked | Stop monitoring, voice + push alert to family, no silent failure |
| Emergency call failure | Retry once, then voice + manual instruction. Family notification proceeds independently |
| Config decryption failure | Reject payload entirely, no partial state change, notify companion app |
| Config schema invalid | Reject payload entirely, retain existing config |
| STT timeout | Return to IDLE, user re-activates with wake word |
| LLM inference timeout | "Still thinking" once, then IDLE |
| TTS render failure | Platform-native TTS fallback, required for emergency announcements |
| Reminder persistence failure | Block alarm scheduling, surface error — no silent drop |
| Network unavailable (relay) | Reconnect with exponential backoff, companion app buffers changes |

---

## 11. Observability Summary

All components emit events to `ObservabilityBus`. `LogSanitiser` is applied at emission.

**Metrics available for health dashboards (no PII):**
- LLM inference P50/P95/P99 latency
- STT transcription P50/P95 latency
- Wake word false positive rate (count of detections that did not result in a completed interaction)
- Authentication pass/fail rates (no user identifiers)
- Config application success/failure rates
- Emergency dispatcher activation count (no patient data)
- Medication adherence rate (%) — aggregate only, no per-entry data off-device

**No PII, health values, voice transcripts, contact names, or biometric data appear in any observability event.**

---

## 12. Performance Targets (from NFRs)

| Component | Target | Measurement |
|-----------|--------|-------------|
| STT transcription | ≤ 2000 ms (NFR-001) | `stt.completed.durationMs` P95 |
| LLM inference | ≤ 3500 ms (NFR-002) | `llm.infer_completed.durationMs` P95 |
| Wake word activation | ≤ 1000 ms (Gherkin) | `wake_word.detected` → `voice_session.listening_started` |
| Wake word CPU | ≤ 3% continuous | Platform profiler |
| Emergency dispatch start | ≤ 3000 ms from threshold breach | `health_monitor.threshold_breach_detected` → `emergency.announcement_started` |
| LLM RAM footprint | ≤ 2100 MB (Q4_K_M 3B) | `llm.load_completed.memoryUsageMB` |

---

## 13. Security Implementation Patterns

| Pattern | Component | Mechanism |
|---------|-----------|-----------|
| Input sanitisation (quarantine) | `InputSanitiser` | Blocklist of prompt injection patterns; max input length 2000 chars |
| Biometric data isolation | `VoiceBiometricAuth` | Embedding in Secure Enclave / Android Keystore; raw samples never persisted |
| PIN memory hardness | `PinFallbackAuth` | Argon2id (64 MB memory, 3 iterations) |
| Config E2E encryption | `SignalProtocolClient` | Signal Protocol double-ratchet; relay server zero-knowledge |
| TLS pinning | `RelayWebSocketClient`, `GoogleCalendarClient` | Certificate pinning in app binary; fail fast on mismatch |
| Encrypted-at-rest | `EncryptedLocalStorage` | iOS Data Protection Complete; Android SQLCipher + EncryptedSharedPreferences |
| PII-free logs | `LogSanitiser` | Wraps `ObservabilityBus` at emission; sanitises before any write |
| Emergency path LLM isolation | `EmergencyDispatcher`, `HealthMonitorService` | Separate OS service / process; no `LlamaInferenceEngine` import |
| Config atomicity | `ConfigApplicator` | All-or-nothing apply; rollback on storage write failure |

---

## 14. Technical Risks and Mitigations

| Risk | Component | Mitigation |
|------|-----------|------------|
| Argon2id not available on older Android (< API 29) | `PinFallbackAuth` | Use bouncy castle / libsodium JNI wrapper for Android < API 29 |
| openWakeWord model size > acceptable app binary delta | `WakeWordDetector` | Ship model as downloadable asset on first launch; fallback: manual mic activation |
| iOS Secure Enclave key migration on device restore | `VoiceBiometricAuth` | On SE key unavailability: delete profile and prompt re-enrolment; never fail silently |
| llama.cpp OOM on low-end Android (4 GB RAM) | `LlamaInferenceEngine` | Runtime memory check before load; decline load if available RAM < 2.5 GB; show in-app notice |
| Signal Protocol prekey exhaustion (companion offline for weeks) | `SignalProtocolClient` | Pre-generate 100 one-time prekeys; refresh when < 5 remain; companion app shows "low prekey" warning |
| Google Calendar OAuth token revoked | `GoogleCalendarClient` | Detect 401 response; prompt user to re-authenticate; disable calendar features until re-auth |
| FCM/APNs family notification delivery failure | `FamilyNotifier` | Log per-contact delivery failure; do not block emergency call on notification failure |
| BGTaskScheduler execution budget exceeded on iOS | `MedicationScheduler` | Use local notifications (always delivered) as primary mechanism; BGTask as supplemental |

---

## 15. Traceability

| Component | Requirements |
|-----------|-------------|
| `WakeWordDetector` | FR-004, NFR-006, NFR-007 |
| `STTEngine` + `AccentTuner` | FR-001, FR-002, FR-005, NFR-001 |
| `TTSEngine` | FR-002, FR-003, FR-006 |
| `AudioSessionManager` | FR-004, NFR-006, NFR-007 |
| `VoiceSessionCoordinator` | FR-001–FR-006, NFR-001–NFR-002 |
| `LlamaInferenceEngine` + `InputSanitiser` | FR-007, FR-008, FR-009, NFR-002, NFR-013 |
| `ContextWindowManager` | FR-010 |
| `HealthMonitorService` + `AlertEvaluator` | FR-031, FR-032, NFR-004, NFR-026 |
| `EmergencyDispatcher` | FR-033, FR-034, FR-035, FR-036, FR-009, NFR-026, NFR-028 |
| `MedicationScheduler` | FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027 |
| `FamilyNotifier` | FR-036, FR-042 |
| `VoiceBiometricAuth` | FR-011, FR-012, FR-013, NFR-011 |
| `PinFallbackAuth` + `AuthCoordinator` | FR-014, FR-015 |
| `SignalProtocolClient` + `ConfigPayloadDecryptor` | FR-038, FR-039, FR-040, NFR-012 |
| `ConfigSchemaValidator` + `ConfigApplicator` | FR-040, FR-041, FR-042 |
| `RelayWebSocketClient` | FR-038, FR-039 |
| `EncryptedLocalStorage` | NFR-015, NFR-016, NFR-011 |
| `LogSanitiser` + `ObservabilityBus` | NFR-015, NFR-016 |
| `CompanionApp` modules | FR-038–FR-042, FR-043–FR-046 |
