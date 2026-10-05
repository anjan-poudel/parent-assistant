# Scaffold Report — profile-interview

**Mode:** brownfield-feature
**Date:** 2026-10-05
**Owner request:** Onboarding interview steps (name, address-as, DOB, next of kin,
emergency GP, local hospital, family members, voice fingerprint) + the voice
assistant addresses the user by their chosen "address-as" term in spoken replies.

## Files Created

- `specs/profile-interview/workflow.yaml` — canonical feature workflow, hardened
  to the project's safety-critical baseline (design-l1 → design-l2 → review-l2 →
  security-design-review (STRIDE) → plan-tasks → implement (paired review,
  confidence 0.85, max rework 5) → review-implementation → security-test →
  final-sign-off (T2 + HIL)).
- `.ai-sdd/workflows/profile-interview.yaml` — byte-identical mirror (the path
  `ai-sdd run --workflow profile-interview` loads).
- `specs/profile-interview/constitution.md` — feature constitution supplement.

## Inputs

- Owner brief (2026-10-05, conversation): the interview steps and address-as
  behavior; name + address-as mandatory, everything else optional for now.
- `requirements.md`, `requirements-dementia-supplement.md` (project briefs)
- Root `constitution.md` (project constitution — architecture constraints,
  standards, release gates apply unchanged)

## Key integration surfaces (from codebase probe)

- `ios/ElderlyAssistant/App/OnboardingState.swift` + `OnboardingWizardView.swift`
  — 4 existing skippable steps (language, permissions, familyContact, models)
- `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` — single shared
  prompt builder for Gemini + LLaMA brains; templates pinned by
  `IntentPromptTests` (1,024-token budget) and byte-mirrored by
  `tools/train-intent/seeds/prompt_template.txt`
- `ios/ElderlyAssistant/Services/Voice/VoicePipeline.swift` `handleWakeDetected`
  — wake word ("ये कान्छी") currently starts listening with NO spoken greeting
- `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` — existing
  family members + `isEmergencyContact` flag
- `ios/ElderlyAssistant/Services/Voice/SpeakerBiometricService.swift` +
  `VoiceEnrollmentRecorder.swift` + `App/VoiceSettingsView.swift` — existing
  voice fingerprint enrollment flow

## Next Steps

1. Review `specs/profile-interview/constitution.md` — resolve any Open Decisions
2. Run `ai-sdd validate-config` to verify configuration
3. Type `/sdd-run` to start the feature workflow
