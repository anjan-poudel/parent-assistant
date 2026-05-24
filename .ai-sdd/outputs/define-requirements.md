# Requirements

**Project:** Elderly AI Assistant
**Version:** 1.0 (MVP)
**Status:** Approved — ready for architecture design
**Date:** 2026-03-03

---

## 1. Functional Requirements

### 1.1 Voice Interface — STT / TTS / Wake Word

**FR-001**
The system must perform Speech-to-Text (STT) recognition entirely on-device with no audio data transmitted to any cloud service.

**FR-002**
The system must perform Text-to-Speech (TTS) synthesis entirely on-device, producing spoken audio output in the user's configured language (Nepali or English).

**FR-003**
The system must support bilingual operation: Nepali as the primary language and English as the secondary/fallback language. Language selection is configured during onboarding and may be updated remotely by a family member.

**FR-004**
The system must support always-on wake-word detection. When the wake word is detected the assistant must activate and begin listening for a voice command without requiring any screen tap. Wake-word detection must remain active when the screen is locked.

**FR-005**
The system must support accent and regional dialect personalisation for Nepali speakers. During onboarding the user provides voice samples; the STT model fine-tunes to the individual's accent. Accent tuning data is stored on-device only.

**FR-006**
The TTS output must use the user's configured language for all spoken responses. Where the primary language is Nepali, all assistant responses must be spoken in Nepali unless the user explicitly switches language mid-session.

---

### 1.2 On-Device AI — LLaMA, NLU, Personalisation

**FR-007**
The system must use an on-device LLaMA model (specific variant to be selected by the architect — see Open Decisions) for natural language understanding (NLU) and response generation. No cloud LLM API must be called at any time.

**FR-008**
The on-device LLM must be capable of intent classification, entity extraction (names, dates, times, medications, contacts), and conversational response generation within the latency targets defined in NFR-001.

**FR-009**
The on-device LLM must not be a dependency for safety-critical execution paths. Emergency call dispatch and medication reminder re-fire must operate even if the LLM process is busy or unavailable.

**FR-010**
The system must maintain a per-user context window that includes: enrolled voice model reference, contact list, medication schedule, calendar appointments, health thresholds, and user preferences. This context must be loaded into the LLM prompt at session start.

---

### 1.3 Authentication — Voice Biometric and PIN Fallback

**FR-011**
The system must enrol a voice biometric profile for the primary user during onboarding by collecting a minimum set of voice samples. The enrolled voice model must be stored exclusively in the device's secure storage (iOS Secure Enclave / Android Keystore).

**FR-012**
The system must verify the speaker's voice biometric before executing sensitive commands including: initiating calls, accessing health data, modifying configuration, and any action marked as requiring authentication.

**FR-013**
Voice biometric authentication is the primary authentication mechanism. PIN authentication is the fallback only. The system must not present PIN as the default or preferred path.

**FR-014**
The system must provide a PIN fallback mechanism. If voice biometric verification fails three consecutive times, the system must offer PIN entry. The PIN must be stored as a salted hash (bcrypt or Argon2) and must never be stored in plaintext.

**FR-015**
Following a PIN-based authentication, the system must prompt the user to re-enrol voice biometrics to restore the primary authentication path.

---

### 1.4 Messenger Integration — Voice and Video Calls (MVP)

**FR-016**
The system must allow the user to initiate a Facebook Messenger voice call by voice command (e.g. "Call [name] on Messenger"). Contact name resolution must use the user's configured contact list.

**FR-017**
The system must allow the user to initiate a Facebook Messenger video call by voice command (e.g. "Video call [name] on Messenger").

**FR-018**
The system must allow the user to answer an incoming Facebook Messenger call by voice command (e.g. "Answer call").

**FR-019**
Messenger call initiation must be implemented via deep link or OS-level integration. The assistant must not require screen interaction from the user to complete a call.

**FR-020**
If a requested contact is not found in the configured contact list, the system must inform the user by voice and must not attempt to call an unresolved number or contact.

---

### 1.5 Calendar and General Reminders

**FR-021**
The system must integrate with Google Calendar (read and write) using the user's authenticated Google account. Calendar access is read/write: the user may query upcoming events and add new events by voice.

**FR-022**
The system must allow the user to query their calendar by voice (e.g. "What do I have today?", "When is my doctor's appointment?") and receive spoken responses.

**FR-023**
The system must allow the user to add a new calendar event by voice (e.g. "Add a doctor's appointment on Friday at 3pm"). The system must confirm the event details by voice before saving.

**FR-024**
The system must deliver general reminders (exercise, meals, appointments, wake-up) at scheduled times configured by the family companion app or by the user. Reminders are delivered as voice announcements.

**FR-025**
Reminder schedules must persist across app restarts. If the app is killed and restarted, all pending reminders for the current day must be re-queued.

---

### 1.6 Medication Management

**FR-026**
The system must deliver medication reminders at scheduled times as configured in the user's medication schedule. Each reminder must be announced by voice, naming the specific medication.

**FR-027**
If the user does not acknowledge a medication reminder within a configurable acknowledgement window (default: 5 minutes), the system must re-fire the reminder. The system must re-fire up to 5 times within a 60-minute window (i.e. reminders re-fire at approximately 0, 12, 24, 36, 48, and 60 minutes from the scheduled time).

**FR-028**
If the user does not acknowledge a medication reminder after all 5 re-fires within the 60-minute escalation window, the system must:
  (a) Send an alert notification to all pre-nominated family members via the remote notification channel; and
  (b) Log the missed dose with a timestamp to the user's on-device medication log.

**FR-029**
Medication reminder acknowledgement state must be persisted to durable storage immediately upon acknowledgement. If the app is killed before acknowledgement is recorded, the reminder must re-fire on next app launch if the 60-minute escalation window has not yet expired.

**FR-030**
The system must allow a family member to view the medication adherence log (acknowledged doses and missed doses with timestamps) via the companion app.

---

### 1.7 Health Monitoring and Emergency Response

**FR-031**
The system must integrate with Apple HealthKit (iOS) and Android Health Connect (Android) to monitor blood pressure (systolic and diastolic) and heart rate. Additional health data types are post-MVP.

**FR-032**
The system must evaluate health metric readings against configurable alert thresholds. Default clinical baseline thresholds are to be proposed by the architect (e.g. systolic BP > 180 mmHg) and are overridable per user via remote configuration.

**FR-033**
When a health metric reading exceeds its configured threshold, the system must initiate the emergency response sequence:
  (a) Announce an alert to the user by voice (e.g. "Your blood pressure is high. I am going to call emergency services in 30 seconds. Say 'Cancel' to stop.");
  (b) Start a 30-second countdown during which the user may cancel by voice command;
  (c) If the user does not cancel within 30 seconds, automatically call the local emergency services number (configured per locale) AND simultaneously send an emergency notification to all pre-nominated family members.

**FR-034**
The emergency call dispatch module must be isolated from the on-device LLM. Emergency dispatch must not be blocked by the LLM being busy, unavailable, or in a rework state.

**FR-035**
If the health monitoring service loses connection to HealthKit or Health Connect (e.g. permissions revoked, service crash), the system must:
  (a) Alert the user by voice that health monitoring is unavailable; and
  (b) Send a notification to the pre-nominated family members indicating that health monitoring has been interrupted.

**FR-036**
The system must allow the user to cancel the emergency call sequence by voice command during the 30-second countdown. Cancellation must be confirmed to the user by voice.

**FR-037**
Emergency contact data and health alert thresholds must be stored in encrypted app storage (iOS Data Protection class Complete / Android EncryptedSharedPreferences).

---

### 1.8 Remote Configuration

**FR-038**
The system must provide a family companion mobile app (iOS and Android) that allows a family member or caregiver to configure the following settings for the primary user's device:
  - Medication schedules (name, dose, time, frequency);
  - General reminder schedules (type, time, recurrence);
  - Emergency contacts and pre-nominated family notification list;
  - Health alert thresholds (per metric);
  - Google Calendar account linking;
  - Contact list for Messenger calls;
  - Language and accent preference.

**FR-039**
All configuration payloads pushed from the companion app to the primary user's device must be end-to-end encrypted. No intermediate server must be able to read the configuration payload in plaintext. The encryption keys must be held only on the two devices.

**FR-040**
When a new remote configuration payload is received and decrypted successfully, the system must apply the updated configuration immediately (without requiring an app restart) and confirm the update to the user by voice.

**FR-041**
The system must apply a configuration change only after successful decryption and schema validation. A malformed or unverifiable configuration payload must be rejected and must not partially overwrite the existing configuration.

**FR-042**
Configuration must also be editable in-app on the primary user's device by an authenticated administrator (family member present at the device). In-app configuration requires voice biometric or PIN authentication.

---

### 1.9 User Profile and Personalisation

**FR-043**
Each device installation must maintain a single primary user profile containing: enrolled voice biometric model, accent/dialect tuning data, contact list, medication schedule, health thresholds, Google Calendar account reference, emergency contacts, language preference, and app preferences.

**FR-044**
The voice model and accent tuning data within the user profile must be updatable by the user providing additional voice samples on request. Re-enrolment must not require a full app reset.

**FR-045**
The system must support per-user preference configuration for reminder delivery style (voice only vs. voice + visual notification) and TTS voice characteristics (speed, pitch — within platform constraints).

**FR-046**
The user profile must be stored entirely on-device. No profile data (voice model, health data, contacts, conversation history) must be transmitted to any cloud service except as explicitly required by third-party integrations (e.g. Google Calendar tokens).

---

## 2. Non-Functional Requirements

### 2.1 Performance

**NFR-001**
STT processing latency: the system must produce a transcription result within 2 seconds of the user finishing speaking (measured from end-of-utterance detection to text output) on a mid-range reference device (iPhone 12 / Android device with 6 GB RAM).

**NFR-002**
LLM response latency: the system must produce a complete NLU intent classification result and begin TTS playback within 4 seconds of receiving the transcription on the reference device.

**NFR-003**
Wake-word detection latency: the system must activate within 1 second of the user speaking the configured wake word.

**NFR-004**
Emergency response initiation latency: from threshold breach detection to first voice alert, the system must respond within 3 seconds.

**NFR-005**
Medication reminder delivery latency: a scheduled reminder must fire within 30 seconds of its scheduled time.

---

### 2.2 Availability

**NFR-006**
The assistant must remain responsive to wake-word detection 24 hours a day, 7 days a week, including when the device screen is locked.

**NFR-007**
The background service must comply with iOS Background Modes policies (specifically Background Audio or VoIP modes as determined by architect) and Android Foreground Service requirements, ensuring the service is not killed by the OS under normal battery conditions.

**NFR-008**
Safety-critical services (health monitoring, medication reminder scheduler, emergency dispatch) must restart automatically if crashed, using platform service restart policies (iOS background task re-registration, Android service START_STICKY).

---

### 2.3 Security

**NFR-009**
Voice biometric enrolment data and verification models must be stored exclusively in platform secure storage (iOS Secure Enclave / Android Keystore). They must not be written to the app's general file storage or transmitted off-device.

**NFR-010**
The PIN must be stored as a salted hash using bcrypt or Argon2. Plaintext PIN must never be persisted to any storage medium, written to logs, or included in any network payload.

**NFR-011**
All outbound network connections (Google Calendar API, Facebook Messenger deep link, remote config channel) must use TLS 1.2 or higher. Connections failing certificate validation must be rejected.

**NFR-012**
Remote configuration payloads must be end-to-end encrypted. The encryption scheme must be selected by the architect and must provide forward secrecy.

**NFR-013**
Input sanitisation must be applied at `quarantine` level to all externally sourced data (voice transcriptions, remote config payloads, calendar data) before processing by the LLM or any business logic module.

**NFR-014**
A STRIDE threat model must be produced during the security design review task and must be approved before implementation begins.

---

### 2.4 Privacy

**NFR-015**
No personal data — including voice audio, transcriptions, health metric readings, contact information, medication schedules, or conversation history — must be transmitted to any cloud service for AI processing.

**NFR-016**
Application logs must not contain PII. A log sanitiser must strip names, health values, contact details, and biometric identifiers from all log output before writing.

**NFR-017**
Health data accessed via HealthKit or Health Connect must be limited to the specific data types required for the MVP feature set (blood pressure, heart rate). The app must not request access to health data types it does not use.

**NFR-018**
The app must not request OS permissions that are not required for its declared feature set. Permissions must be requested at the point of use with plain-language justification visible to the user.

---

### 2.5 Accessibility

**NFR-019**
Every application function must be accessible by voice command without requiring any touch interaction. No feature may be voice-inaccessible.

**NFR-020**
Touch UI elements (buttons, inputs, list items) must meet minimum size requirements: 44 x 44 pt on iOS, 48 x 48 dp on Android.

**NFR-021**
Body text in the touch UI must use a minimum font size of 18pt / 18sp. The app must not override the user's system font size scaling setting in a way that reduces text below this minimum.

**NFR-022**
High-contrast display mode must be supported. UI colours must meet WCAG AA contrast ratios (minimum 4.5:1 for body text, 3:1 for large text and UI components).

---

### 2.6 Localisation

**NFR-023**
All UI strings, TTS prompts, and voice response templates must be externalised into locale resource files. Hard-coded strings in application logic are not permitted.

**NFR-024**
The application must support Nepali (primary) and English (secondary/fallback) at launch. The STT and TTS engines must handle both languages.

**NFR-025**
The architecture must support adding additional language packs (STT model, TTS voice, locale resource file) without requiring code changes, by adding a new language plugin package.

---

### 2.7 Reliability — Safety-Critical Paths

**NFR-026**
Safety-critical execution paths (emergency call dispatch, health alert notification, medication reminder re-fire) must achieve 100% unit test coverage and must have integration tests executed against stubbed platform health APIs (HealthKit / Health Connect).

**NFR-027**
The medication reminder persistence mechanism must be tested for correct behaviour under abnormal termination: if the app process is killed while a reminder is outstanding, the test must verify the reminder re-fires on next launch within the 60-minute escalation window.

**NFR-028**
The emergency response sequence (threshold detection → voice alert → 30-second countdown → auto-call) must be tested end-to-end with automated tests for both the happy path (no cancellation) and the cancellation path (user cancels within 30 seconds).

**NFR-029**
The implementation confidence threshold for all tasks involving safety-critical code is 0.85. Tasks that do not reach this threshold must be reworked. Maximum rework iterations: 5.

---

### 2.8 App Store and Play Store Compliance

**NFR-030**
The app must comply with Apple App Store Guideline 5.1.1 (Data Collection and Storage) and Guideline 5.1.3 (Health and Health Research). Health data must not be used for advertising or shared with third parties.

**NFR-031**
The app must comply with Google Play Store Sensitive App Permissions policy for Body Sensors and Contacts permissions. A prominent disclosure must be displayed before these permissions are requested.

**NFR-032**
The app must provide an in-app privacy policy that accurately describes all data collected, how it is stored (on-device), and what is transmitted to third-party services (Google Calendar, Facebook Messenger). The privacy policy must be accessible without requiring the user to authenticate.

---

## 3. Gherkin Acceptance Criteria

### Feature: Wake Word Activation (FR-004)

```gherkin
Feature: Always-on wake word activation
  As an elderly user
  I want the assistant to respond when I say the wake word
  So that I can interact without touching the phone

  Scenario: Wake word activates assistant while screen is locked
    Given the device screen is locked
    And the assistant background service is running
    When the user speaks the configured wake word
    Then the assistant must activate within 1 second
    And the assistant must announce readiness using TTS in the user's configured language
    And the user must not be required to unlock the screen

  Scenario: Wake word detection resumes after a completed interaction
    Given the assistant has just completed a voice interaction
    When the assistant returns to idle state
    Then wake word detection must be re-enabled within 2 seconds
    And the assistant must respond to the next wake word occurrence
```

---

### Feature: On-Device STT (FR-001)

```gherkin
Feature: On-device speech-to-text processing
  As an elderly user
  I want my voice to be processed locally
  So that my conversations are private

  Scenario: STT transcription produced within latency target
    Given the user has spoken a voice command
    And the end-of-utterance has been detected
    When the STT engine processes the audio
    Then a transcription result must be produced within 2 seconds
    And no audio data must have been transmitted to any remote server

  Scenario: STT handles Nepali accent correctly
    Given the user's accent tuning profile has been enrolled
    When the user speaks a Nepali voice command
    Then the transcription must correctly identify the intent with an accuracy consistent with the enrolled profile
    And the result must be produced on-device
```

---

### Feature: Voice Biometric Authentication (FR-011, FR-012, FR-013)

```gherkin
Feature: Voice biometric authentication
  As an elderly user
  I want the assistant to recognise my voice as my identity
  So that sensitive actions are protected without requiring a PIN

  Scenario: Successful voice biometric authentication for a sensitive command
    Given the user's voice biometric profile is enrolled
    When the user speaks a sensitive command (e.g. "Call my son on Messenger")
    Then the system must verify the speaker's voice biometric before executing the command
    And the command must be executed only after successful verification
    And no PIN prompt must be displayed

  Scenario: Voice biometric fails three times — PIN fallback offered
    Given the user's voice biometric profile is enrolled
    When voice biometric verification fails three consecutive times
    Then the system must offer PIN entry by voice prompt and on-screen input
    And the system must not execute the sensitive command until authentication succeeds
    And PIN must be offered as the fallback, not the default

  Scenario: PIN fallback succeeds — re-enrolment prompted
    Given the user has authenticated via PIN after biometric failure
    When the PIN is validated successfully
    Then the system must execute the requested command
    And the system must prompt the user to re-enrol voice biometrics to restore the primary authentication path
```

---

### Feature: Messenger Call Initiation (FR-016, FR-017, FR-018)

```gherkin
Feature: Facebook Messenger call initiation by voice
  As an elderly user
  I want to call family members on Messenger using only my voice
  So that I do not need to navigate the phone interface

  Scenario: Successful voice call to a known contact
    Given the user's contact list contains "Aarav" with a Messenger account
    And the user's voice biometric has been verified
    When the user says "Call Aarav on Messenger"
    Then the system must initiate a Messenger voice call to Aarav via deep link
    And the call must be initiated without requiring any touch interaction

  Scenario: Call requested for unknown contact
    Given the user's contact list does not contain "Ramesh"
    When the user says "Call Ramesh on Messenger"
    Then the system must not attempt to place a call
    And the system must announce by voice that Ramesh was not found in the contact list
    And the system must suggest the user ask a family member to add the contact

  Scenario: Answering an incoming Messenger call by voice
    Given an incoming Messenger call is alerting on the device
    When the user says "Answer call"
    Then the system must accept the Messenger call via OS integration
    And the call must be connected without requiring a screen tap
```

---

### Feature: Medication Reminder Escalation (FR-026, FR-027, FR-028, FR-029)

```gherkin
Feature: Medication reminder with escalation
  As an elderly user with a medication schedule
  I want the assistant to remind me to take my medication and alert family if I miss it
  So that my medication adherence is maintained and family are informed

  Scenario: User acknowledges medication reminder on first delivery
    Given the medication schedule has "Amlodipine" due at 08:00
    And the current time is 08:00
    When the reminder fires
    Then the assistant must announce the reminder by voice naming "Amlodipine"
    And when the user says "Done" or "Taken"
    Then the system must record the acknowledged dose with a timestamp
    And must not re-fire the reminder

  Scenario: Reminder re-fires up to 5 times within 60-minute window
    Given the medication schedule has "Amlodipine" due at 08:00
    And the user does not acknowledge the first reminder
    When 12 minutes have elapsed since the first reminder
    Then the system must re-fire the reminder
    And this escalation must occur up to 5 additional times within 60 minutes of the original scheduled time

  Scenario: Missed dose triggers family alert and log entry after full escalation
    Given the medication schedule has "Amlodipine" due at 08:00
    And the user has not acknowledged any of the 5 re-fires within the 60-minute window
    When the 60-minute escalation window expires
    Then the system must send an alert to all pre-nominated family members indicating a missed dose
    And the system must write a missed dose entry with timestamp to the on-device medication log
    And the system must confirm the family alert has been sent by voice

  Scenario: App killed before acknowledgement — reminder re-fires on next launch
    Given a medication reminder for "Metformin" is outstanding and unacknowledged
    And the 60-minute escalation window has not yet expired
    When the app process is killed and then relaunched
    Then the system must re-fire the reminder immediately on launch
    And must resume the escalation countdown from the remaining window time
```

---

### Feature: Emergency Response Sequence (FR-033, FR-034, FR-035, FR-036)

```gherkin
Feature: Health threshold emergency response
  As a family member
  I want the assistant to call emergency services and notify me when health thresholds are exceeded
  So that my elderly relative receives help immediately

  Scenario: Blood pressure threshold exceeded — full emergency response with no user cancellation
    Given the user's systolic BP alert threshold is configured as 180 mmHg
    And the health monitoring service is connected to HealthKit / Health Connect
    When a blood pressure reading of 185 mmHg systolic is received
    Then within 3 seconds the assistant must announce by voice that blood pressure is high and that emergency services will be called in 30 seconds
    And the assistant must start a 30-second countdown
    And if the user does not say "Cancel" within 30 seconds
    Then the system must call the configured emergency services number
    And simultaneously send an emergency notification to all pre-nominated family members
    And this must complete even if the on-device LLM is busy or unavailable

  Scenario: User cancels emergency call within 30-second countdown
    Given the emergency response countdown is active with 15 seconds remaining
    When the user says "Cancel"
    Then the system must stop the countdown immediately
    And must not place the emergency call
    And must confirm cancellation to the user by voice
    And must log the threshold breach and manual cancellation with a timestamp

  Scenario: Health monitoring service loses connectivity
    Given the health monitoring service is running
    When the HealthKit / Health Connect connection is lost (e.g. permissions revoked)
    Then the system must announce by voice that health monitoring is unavailable
    And must send a notification to pre-nominated family members that health monitoring has been interrupted
    And must not silently fail

  Scenario: Emergency dispatch not blocked by LLM unavailability
    Given a blood pressure threshold breach has been detected
    And the on-device LLM is in a processing state and unavailable
    When the 30-second countdown expires
    Then the system must still call emergency services
    And must still send family notifications
    And no dependency on LLM availability must prevent the call
```

---

### Feature: Remote Configuration (FR-038, FR-039, FR-040, FR-041)

```gherkin
Feature: Encrypted remote configuration from companion app
  As a family member
  I want to configure my relative's assistant remotely
  So that I can manage their schedule, reminders, and health thresholds without being present

  Scenario: Family member pushes a new medication schedule
    Given the family member is authenticated in the companion app
    And the primary user's device is online
    When the family member saves a new medication schedule entry in the companion app
    Then the configuration payload must be encrypted before transmission
    And the payload must be decrypted only on the primary user's device
    And the new medication schedule must take effect immediately without an app restart
    And the assistant must announce the configuration update to the primary user by voice

  Scenario: Malformed configuration payload is rejected
    Given a configuration payload is received from the remote channel
    When decryption succeeds but schema validation fails
    Then the system must reject the payload in full
    And must not partially apply any fields from the malformed payload
    And must retain the existing configuration unchanged
    And must notify the family member of the rejection via the companion app

  Scenario: Configuration payload with failed decryption is rejected
    Given a configuration payload is received from the remote channel
    When decryption fails (e.g. wrong key or tampered payload)
    Then the system must reject the payload
    And must not process or store any portion of the payload
    And must log the rejected attempt without logging the raw payload content
```

---

### Feature: Accent Personalisation (FR-005)

```gherkin
Feature: Nepali accent and dialect personalisation
  As an elderly Nepali-speaking user
  I want the assistant to understand my specific accent and dialect
  So that my voice commands are recognised accurately

  Scenario: Accent tuning from voice samples during onboarding
    Given the user is in the onboarding flow
    When the user provides the required number of voice samples
    Then the STT model must be fine-tuned or adapted to the user's accent
    And the tuning data must be stored on-device only
    And no voice samples must be transmitted to any cloud service

  Scenario: Re-enrolment of accent model with additional samples
    Given the user's accent model is already enrolled
    When the user provides additional voice samples for re-enrolment
    Then the system must update the accent model
    And must not require a full app reset
    And the updated model must be applied to subsequent STT sessions
```

---

### Feature: Calendar Voice Interaction (FR-021, FR-022, FR-023)

```gherkin
Feature: Google Calendar voice interaction
  As an elderly user
  I want to ask about and add calendar events using my voice
  So that I can manage my schedule without using the phone's touch interface

  Scenario: User queries upcoming events by voice
    Given the user's Google Calendar is linked and accessible
    When the user says "What do I have today?"
    Then the system must retrieve today's events from Google Calendar
    And must read them aloud in the user's configured language
    And must complete the response within the LLM latency target (NFR-002)

  Scenario: User adds a new calendar event by voice
    Given the user's Google Calendar is linked and writable
    When the user says "Add a doctor's appointment on Friday at 3pm"
    Then the system must extract the event details (type, date, time)
    And must read back the interpreted event details to the user for confirmation
    And only after the user confirms by voice must the event be saved to Google Calendar
```

---

### Feature: Always-On Background Service (NFR-006, NFR-007, NFR-008)

```gherkin
Feature: 24/7 background service availability
  As an elderly user
  I want the assistant to always be ready to help
  So that it is available in an emergency at any time of day

  Scenario: Service remains active after screen lock
    Given the app has been running in the foreground
    When the device screen locks
    Then the wake-word detection service must remain active
    And health monitoring must continue reading from HealthKit / Health Connect
    And pending medication reminders must still fire at their scheduled times

  Scenario: Safety-critical service restarts after crash
    Given the health monitoring service is running
    When the health monitoring service process crashes
    Then the OS service restart policy must restart the service automatically
    And within 60 seconds of the crash the service must be running again
    And the assistant must announce by voice that monitoring was temporarily interrupted and has resumed
```

---

### Feature: Health Monitoring Integration (FR-031, FR-032)

```gherkin
Feature: Health metric monitoring via HealthKit and Health Connect
  As a family member
  I want the assistant to monitor my relative's blood pressure and heart rate
  So that we are alerted if readings become dangerous

  Scenario: Normal health metric reading — no alert
    Given the user's systolic BP threshold is 180 mmHg
    When a blood pressure reading of 130 mmHg systolic is received
    Then no alert must be triggered
    And the reading must be available in the health log

  Scenario: Alert threshold configurable via remote config
    Given the family member pushes a new threshold of 170 mmHg systolic via the companion app
    When the remote configuration is applied
    Then subsequent blood pressure readings must be evaluated against the new threshold of 170 mmHg
    And readings at or above 170 mmHg must trigger the emergency response sequence (FR-033)
```

---

## 4. Out of Scope — Post-MVP

The following features are explicitly excluded from the MVP and must not be implemented in the initial release.

| Item | Notes |
|------|-------|
| WhatsApp integration (calls and messages) | Feasibility to be evaluated post-MVP |
| Facebook Messenger text message read/write | Voice calls only in MVP |
| YouTube video playback | Post-MVP |
| Music and bhajan playback | Post-MVP |
| News reading | Post-MVP |
| Facebook social feed browsing | Post-MVP |
| Additional languages beyond Nepali and English | Architecture must support addition without code changes |
| HIPAA compliance | Deferred — architecture must not block future compliance |
| GDPR compliance | Deferred — architecture must not block future compliance |
| WhatsApp Business API integration | Post-MVP |

---

## 5. Open Decisions

The following decisions are unresolved and must be resolved before or during the architecture design task.

| ID | Decision | Assumption / Default | Owner |
|----|----------|---------------------|-------|
| OD-001 | Wake word / hotword keyword selection and on-device hotword detection approach | Architect to propose an on-device hotword detection model and default keyword | Architect |
| OD-002 | LLaMA model variant (e.g. LLaMA 3.2 3B vs 8B) | Architect to benchmark on reference device (iPhone 12 / Android 6 GB RAM) and select variant meeting NFR-001 and NFR-002 latency targets | Architect |
| OD-003 | Remote configuration push channel mechanism (Signal Protocol relay, APNs/FCM with payload encryption, P2P) | Architect to propose a mechanism providing E2E encryption with forward secrecy. Channel must not allow the relay server to read payload plaintext | Architect |
| OD-004 | iOS Background Mode strategy for always-on audio (VoIP mode vs Background Audio vs alternative) | Architect to determine which iOS Background Mode satisfies NFR-006 and NFR-007 without violating App Store guidelines | Architect |
| OD-005 | HIPAA applicability | Assumed not applicable for initial release (personal-use app, no covered entity relationship). Architecture must not block future HIPAA compliance | Product owner to confirm |
| OD-006 | GDPR applicability | Assumed deferred. Architecture must not block data export or right-to-erasure features | Product owner to confirm |
| OD-007 | Data residency for remote config relay server | No specific requirement beyond on-device AI processing. If a relay server is used, its jurisdiction must be documented | Product owner to confirm |
| OD-008 | Clinical default thresholds for health alerts | Architect / medical adviser to propose safe default values (e.g. systolic BP > 180 mmHg) as the out-of-box baseline for FR-032 | Architect + product owner |
| OD-009 | Emergency services phone number configuration per locale | System must support configuring the emergency number per locale (e.g. 911, 999, 112, 100). Default locale and number must be set during onboarding | Architect |
| OD-010 | Minimum number of voice samples required for biometric enrolment and accent tuning | Architect / ML engineer to determine minimum sample count balancing accuracy and onboarding friction | Architect |
