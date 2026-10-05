# Constitution — profile-interview (feature supplement)

Applies to the `profile-interview` workflow only (`specs/profile-interview/workflow.yaml`,
mirrored at `.ai-sdd/workflows/profile-interview.yaml`). The project constitution
(`/constitution.md`) is inherited unchanged — Architecture Constraints 1–6, Standards,
release gates, and Agent Principles all bind this feature. This supplement does not
restate them; it records only what the feature adds, what it must not change, and the
decisions left open. See `specs/profile-interview/init-report.md` for the scaffold probe.

## Feature Purpose & Scope

Purpose: a first-run personal interview that records who the user is and how the
assistant should address them, so that from then on the voice assistant speaks to them
by their chosen term of address ("address-as"). The core experience: wake word
`ये कान्छी` ("aye kanchhi") is answered `हजुर <address-as>` ("hajur aama"), and
brain-generated replies say "yes mum" instead of "yes". The elderly person is the
primary user; a helping family member may fill the interview in on their behalf.

In scope:

- New steps in the existing first-run wizard (`OnboardingWizardView`), ordered:
  language, permissions, **about-you** (name + address-as required, DOB optional),
  family & friends (extends the existing step + `FamilyContactStore`),
  **emergency contacts** (next of kin, emergency doctor/GP, local hospital),
  **voice fingerprint** (optional enrollment), models.
- A new profile store under `ios/ElderlyAssistant/Services/Storage/` following the
  `EncryptedFileStorage` pattern, holding name, address-as, DOB, GP, hospital
  (next of kin per OD-F1).
- Address-as injected into (a) the spoken wake acknowledgment on wake-word detection
  and (b) the brain reply-style rules across `IntentPrompt.build/buildChat/
  buildUnderstanding` plus the interpreter context, so both cloud (Gemini) and
  on-device (LLaMA) replies use it. The term is spoken verbatim.
- A Settings editor plus the wizard's reminder-card reopen path, so users who already
  completed onboarding can reach the new steps (new step IDs are pending by definition
  for them — absent from the persisted status map).
- All new UI strings externalized to the L10n string catalogs.

Out of scope (must not change):

- Wake-word recognition itself (the wake word and its detection are untouched).
- Any new cloud processing (no new network egress).
- Emergency-call logic. Collected profile/emergency data becomes available to the
  existing safety paths (emergency contact selection, family notification), but those
  paths' behaviour is unchanged.
- Forcing address-as into every sentence — it is used only where it fits naturally.
- New permissions, HealthKit use, or changes to the existing voice-biometric
  enrollment/verification mechanisms (the fingerprint step reuses them as-is).

## Field Contract (mandatory vs optional)

| Field | Step | Required | Storage |
|---|---|---|---|
| Name | about-you | Required — gates Next | New profile store |
| Address-as term | about-you | Required — gates Next | New profile store; spoken verbatim |
| Date of birth | about-you | Optional | New profile store |
| Next of kin (emergency) | emergency contacts | Optional | See OD-F1 |
| Emergency doctor / GP | emergency contacts | Optional | New profile store |
| Local hospital contact | emergency contacts | Optional | New profile store |
| Family members | family & friends (extends existing step) | Optional | Existing `FamilyContactStore` |
| Voice fingerprint | voice fingerprint | Optional | Existing `SpeakerBiometricService` / `VoiceEnrollmentRecorder` flow |

Rules:

- Mandatory means the About-you step's Next button stays disabled until both name and
  address-as are filled. Whether the step's header Skip affordance also changes is
  OD-F3.
- Every other new field is optional and follows the existing skippable-step + Home
  reminder-card pattern (`OnboardingState` per-step status; `pendingSteps` drives the
  reminder card and the reopen position). No hard gate on those steps.
- Existing users are not force-migrated: they reach the new steps via the wizard
  reopen and the Settings editor.

## Address-as Behaviour Contract

- The term is user-entered data: stored and spoken verbatim, never translated, never
  routed through the L10n string catalogs.
- Wake acknowledgment: `VoicePipeline.handleWakeDetected` speaks the acknowledgment on
  wake-word detection (today it starts listening with no spoken greeting). Example:
  `हजुर <address-as>`. Wake-word recognition itself is unchanged.
- Brain replies: the reply-style rules in `IntentPrompt.build/buildChat/
  buildUnderstanding` plus the interpreter context receive the term, so replies can say
  "yes <address-as>" instead of "yes". This applies to both the cloud (Gemini) and
  on-device (LLaMA) reply paths.
- Natural use only: "hajur <address-as>", "yes <address-as>" — never forced into every
  sentence. Exact phrasing is the architect's call; the term itself must be spoken
  verbatim.
- Until a term is recorded (step skipped, or existing user not yet re-interviewed,
  including any fallback path), the assistant behaves exactly as today — no neutral
  placeholder is invented; the feature adds personalization, it does not regress the
  un-personalized path.

## Integration Surfaces (from the scaffold probe and brief)

| Surface | Change |
|---|---|
| `ios/ElderlyAssistant/App/OnboardingState.swift` | New `Step` cases inserted in the brief's order; `pendingSteps`/`firstPendingStep` ordering (wizard position) feeds the Home reminder card. Note the existing "every step is skippable" doc contract vs the About-you Next gate (OD-F3). |
| `ios/ElderlyAssistant/App/OnboardingWizardView.swift` | New step views; About-you gates Next on name + address-as; all other steps keep the existing skippable pattern. |
| `ios/ElderlyAssistant/Services/Storage/` (new profile store) | New store following the `EncryptedFileStorage` pattern (project Security standard: Keychain, Data Protection Complete). |
| `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` | Family-members list grows via the existing model; `isEmergencyContact` already exists (next-of-kin designation option, OD-F1). |
| `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` + `InterpreterContext` | Reply-style rules in `build/buildChat/buildUnderstanding` use address-as; pinned by `IntentPromptTests` token budget; byte-mirrored by `tools/train-intent/seeds/prompt_template.txt`. |
| `ios/ElderlyAssistant/Services/Voice/VoicePipeline.swift` (`handleWakeDetected`) | Speaks the wake acknowledgment with address-as. |
| `ios/ElderlyAssistant/Services/Voice/AckFastLane.swift` | Personalized ack variants, if the design routes the ack through it (OD-F2). |
| `ios/ElderlyAssistant/App/VoiceSettingsView.swift`, `Services/Voice/VoiceEnrollmentRecorder.swift`, `SpeakerBiometricService.swift` | Voice fingerprint step reuses the existing enrollment flow; Secure Enclave storage and verification unchanged. |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | Wiring: profile store into the wake path and prompt builders, wizard step wiring. `start()` timing (voice engages after the wizard) is unchanged. |
| L10n string catalogs | All new UI strings externalized; the address-as term is data, not a catalog string. |

## Feature Constraints

1. Prompt token budget: the IntentPrompt templates run in a 1,024-token on-device
   context and are pinned by `IntentPromptTests`' character ceiling. Any prompt edit
   must preserve the budget and keep the tests passing.
2. Seed mirror: `tools/train-intent/seeds/prompt_template.txt` must be updated
   byte-identically in the same change as any `IntentPrompt` template edit.
3. L10n externalization: all new UI strings go into the string catalogs (project
   Standards); the address-as term is user data spoken verbatim and is never
   localized.
4. Security-design-review focus — prompt injection: the user-entered address-as is
   composed into brain prompts, making it an untrusted input path into the prompt.
   The feature's security-design-review (STRIDE) task must treat this as a focus area
   and the design must apply the project's existing `InputSanitiser` discipline before
   the term enters any prompt. The term must not be able to alter reply-style rules,
   tool/intent routing, or safety behaviour.
5. Data handling: DOB and emergency contacts are personal data stored in the existing
   encrypted local storage (Keychain, Data Protection Complete). No new network
   egress, no HealthKit, no new permissions. Logs must not contain the new PII
   (project Privacy standard — log sanitiser).
6. Voice biometrics: the fingerprint step is a reuse of the existing on-device
   enrollment governed by the existing voice-biometric rules (Secure Enclave); no
   change to that mechanism.
7. Safety delta: none beyond the existing profile baseline. Emergency/profile data is
   made available to the safety paths; their logic is untouched.

## Open Decisions

### OD-F1 — Next-of-kin data shape (OPEN — architect)

Standalone next-of-kin field in the new profile store, or a designation on an existing
`FamilyContact` via the existing `isEmergencyContact` flag? Both data paths already
exist. Architect decides in design-l1/design-l2; the choice must be reflected in the
field table above and the emergency-contacts step design.

### OD-F2 — Wake-acknowledgment phrasing and locale handling (OPEN — architect)

Exact phrasing and mechanism of the spoken wake acknowledgment (TTS of a
`हजुर <address-as>` template vs. pre-rendered `AckFastLane` variants), and locale
handling: how the surrounding acknowledgment copy is localized when the user's term
(user data, spoken verbatim) is in a different script/language from the active app
language, and how the per-language acknowledgment templates are managed. The term
itself must always be spoken verbatim; exact phrasing is the architect's call.

### OD-F3 — About-you skip affordance vs. the wizard's "no hard gate" contract (OPEN — architect)

The existing wizard is documented as "every step is skippable — there is no hard gate
anywhere" (`OnboardingState`), while the brief makes name + address-as mandatory with
Next disabled until both are filled. Does the About-you step keep the header Skip on
first run (soft gate — deferral via the Home reminder card) or is Skip disabled
(hard gate)? Either way the reminder-card reopen + Settings editor path applies to
already-onboarded users. Architect decides so implementation and tests agree.
