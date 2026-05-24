# Constitution

## Project Purpose

Build an AI-powered, highly personalizable, personal assistant app for elderly users — particularly those from non-English-speaking backgrounds — that runs as a 24/7 always-on service on iOS and Android smartphones.
The assistant bridges the digital divide by replacing complex smartphone UI interactions with natural voice conversation.
It manages daily routines (medications, reminders, calendar), enables social connectivity (WhatsApp messaging and calls, Facebook), provides entertainment (YouTube, music, bhajan), reads news and notifications aloud, and acts as an emergency safety net by monitoring health metrics and alerting family or emergency services when thresholds are exceeded.

Family members (adult children, caregivers) are the secondary users who remotely configure the assistant's schedule, reminders, contacts, and health thresholds for their parents or relatives.

## Target Users

Primary users: elderly individuals (60+), many with cognitive or motor challenges (e.g. tremors, difficulty remembering gestures), who speak a non-English first language and find smartphone UIs overwhelming.

Secondary users: adult family members and caregivers who configure the assistant remotely — setting medication schedules, emergency contacts, calendar events, and health alert thresholds on behalf of the primary user.

Affected parties: emergency services and pre-nominated family contacts who receive automated calls or notifications when health alerts are triggered.

## Platform & Tech Stack

Platforms: iOS (iPhone) and Android smartphones. The app must run as a 24/7 always-on background service on both platforms.

Technology constraints (fixed — see Architecture Constraints):
- All AI inference must run on-device. No cloud LLM calls.
- Cross-platform framework: **React Native** (iOS + Android from a single codebase)
- On-device LLM: **LLaMA** (specific variant — e.g. LLaMA 3.2 3B/8B — to be selected by architect based on device RAM constraints)

Required integrations:
- Google Calendar API (calendar and scheduling)
- Apple HealthKit (iOS) and Android Health Connect (Android) — blood pressure, medication tracking, activity data
- WhatsApp (messaging and voice/video calls via supported API or deep link)
- YouTube (video playback)
- Facebook (social feed and messaging)
- On-device LLaMA model (variant to be confirmed by architect — must run on mid-range smartphones, e.g. iPhone 12 / Android 6GB RAM)
- On-device voice recognition with accent and regional dialect support (Nepali at launch)
- Voice biometric authentication (primary)
- PIN authentication (fallback)
- Remote configuration push channel (end-to-end encrypted)

## Architecture Constraints

The following constraints are non-negotiable. They must be enforced in all design and implementation decisions.

1. All AI inference on-device only. No cloud LLM API calls. User voice, conversations, health data, and personal profiles must never leave the device for AI processing. Network access is permitted only for third-party integrations (Calendar API, WhatsApp, YouTube, Facebook) and encrypted remote configuration push.

2. Remote configuration must be end-to-end encrypted. Family members push config (schedules, contacts, reminders, thresholds) to the parent's phone. The remote config channel must use end-to-end encryption so that no intermediate server can read the configuration payload.

3. Voice biometric is the primary authentication mechanism. The system must enroll a voice profile from voice samples during setup and verify speaker identity before executing sensitive commands (calls, health data access, config changes). PIN is the fallback only — it must not be the default path.

4. 24/7 always-on background service on both iOS and Android. The assistant must remain active and responsive to voice activation even when the screen is locked. This requires compliance with iOS Background Modes and Android foreground service / battery optimisation policies.

5. Highly personalised per-user profiles. Each installation maintains a profile: enrolled voice model, accent/dialect tuning, family contact list, medication schedule, appointment calendar, entertainment preferences, therapy routines, and health alert thresholds.

6. Non-English and regional dialect support. The voice recognition system must support **Nepali** as the primary non-English language at launch, including regional dialect and accent variation. Architecture must support adding further languages via model plugins. Language and accent selection are configured during onboarding and can be updated remotely.

Safety-critical constraints (derived from Answer 4):
- Health metric monitoring must be implemented with fail-safe behaviour: if the monitoring service crashes or loses connectivity to HealthKit/Health Connect, it must alert the user and family, not silently fail.
- Emergency calling logic must be isolated in a hardened module. It must not be blocked by the on-device LLM being busy or unavailable.
- Medication reminder acknowledgement must be persisted. If the app is killed before acknowledgement is received, the reminder must re-fire on next app launch.

Compliance constraints (derived from Answer 5):
- The app must comply with Apple App Store Guidelines, specifically the health and medical data policies (Guideline 5.1.1 — Data Collection and Storage, Guideline 5.1.3 — Health and Health Research).
- The app must comply with Google Play Store policies for health apps, including Sensitive App Permissions policy for Body Sensors and Contacts.
- Permissions must be requested at the point of use with clear plain-language explanation visible to elderly users.

## Standards

Accessibility:
- Voice-first UI — every function accessible by voice command without requiring any touch.
- Touch UI (where present) must use large tap targets (minimum 44x44 pt iOS / 48x48 dp Android), high-contrast text, and minimum 18pt font size for body text.
- Localisation: all UI strings must be externalised for translation. At minimum, support the primary user's configured language for all TTS (text-to-speech) output.

Privacy:
- No personal data (voice, health, contacts, conversations) transmitted to cloud for AI processing.
- Health data accessed via HealthKit/Health Connect must follow platform data minimisation principles — request only the specific data types required.
- Remote config payloads must be end-to-end encrypted (key held only on the two devices).
- Logs must not contain PII (names, health values, contacts). Log sanitiser required.

Security:
- Voice biometric enrolment and verification must be stored on-device only (Secure Enclave / Android Keystore).
- PIN stored as a salted hash using a platform-approved algorithm (e.g. bcrypt or Argon2). Never stored in plaintext.
- Emergency contact data and health thresholds stored in encrypted app storage (iOS Data Protection class Complete / Android EncryptedSharedPreferences).
- All outbound network connections (Calendar API, WhatsApp, YouTube, Facebook) must use TLS 1.2+.
- Injection detection enabled at `quarantine` level (due to App Store/Play Store compliance requirement).
- STRIDE threat model must be produced during security design review.

Quality:
- Safety-critical paths (emergency call, health alert notification, medication reminder) must have 100% unit test coverage and integration tests against real (stubbed) platform health APIs.
- Confidence threshold for implementation tasks: 0.85 (elevated above default due to safety-critical features).
- All paired review enabled on implementation tasks (safety-critical project).
- Max rework iterations on implement: 5 (sufficient for complex multi-platform code).

## Open Decisions

The following decisions could not be determined from the provided brief. They must be resolved before running `/sdd-run`.

1. **HIPAA applicability.** The app collects, processes, and acts on health data (blood pressure, medications). Depending on distribution market and whether any data is shared with covered entities, HIPAA may apply. Assumed: HIPAA does not apply for the initial release (personal-use app, no covered entity relationship). Confirm or correct before running /sdd-run.

2. **GDPR applicability.** If the app is distributed to users in the EU or UK, GDPR applies to health and biometric data. Assumed: GDPR compliance is deferred to a future release. The architecture must not make decisions that would block future GDPR compliance (e.g. data export, right to erasure). Confirm or correct before running /sdd-run.

3. ~~**On-device LLM model selection.**~~ **RESOLVED:** LLaMA. Architect to select specific variant (e.g. LLaMA 3.2 3B or 8B) based on device RAM and performance benchmarks.

4. ~~**Cross-platform framework vs. native.**~~ **RESOLVED:** React Native (single codebase for iOS + Android).

5. **Remote configuration push channel mechanism.** The brief requires end-to-end encrypted remote config push but does not specify the channel (e.g. Signal Protocol over a relay server, direct device-to-device via Apple Push Notification / FCM with payload encryption, peer-to-peer). Assumed: architect will propose. Confirm or correct before running /sdd-run.

6. **WhatsApp integration method.** WhatsApp does not provide a public API for third-party apps to send messages or make calls on behalf of a user. Integration likely requires Accessibility Services (Android) or Share Extension (iOS), or use of the WhatsApp Business API (requires business account). Assumed: architect will evaluate feasibility and propose an approach. Confirm or correct before running /sdd-run.

7. ~~**Emergency call trigger thresholds.**~~ **RESOLVED:** Thresholds are configurable per user via remote config. Architect to define safe clinical defaults (e.g. systolic BP > 180 mmHg) as the out-of-box baseline.

8. ~~**Supported languages and dialects at launch.**~~ **RESOLVED:** Nepali at launch. Architecture must support adding further languages via model plugins.

9. **Data residency.** The brief does not specify a country of distribution or data residency requirement. The on-device AI constraint addresses the core concern, but the remote config relay server (if used) has a location. Assumed: no specific data residency requirement beyond on-device AI processing. Confirm or correct before running /sdd-run.

10. **Voice activation keyword.** An always-on assistant requires a wake-word or hotword detection model (e.g. "Hey [Name]"). No keyword was specified. Assumed: architect will propose an on-device hotword detection approach. Confirm or correct before running /sdd-run.

## Agent Principles

Binding for all agents in this workflow. Enforced via `standards/SddAgentPrinciples.md`.

- `complete-task` is the only valid completion mechanism — never use `ai-sdd run --task`
- Output paths are contracts — `--output-path` must exactly match the file written
- Scope is enforced by the agent — do not produce output outside the task specification
- Verify preconditions — confirm inputs exist before proceeding; halt with a specific error if not
- Progress must be visible — emit `[step]` status lines; never go silent for more than a minute
- No silent stubs — deferred work throws explicit errors, never silently returns success

Design agents additionally:
- Every interface method must declare explicit error return types — not `any` or `unknown`
- Every async operation must specify its failure mode and whether it is retryable
- Timeouts are configurable parameters, not hardcoded constants

## Artifact Manifest

<!-- AUTO-GENERATED by ai-sdd engine after each task — do not edit this section -->
