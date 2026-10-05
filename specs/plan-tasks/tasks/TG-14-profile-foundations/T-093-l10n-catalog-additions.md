# T-093: L10n Catalogue Additions (C09)

## Metadata
- **Group:** [TG-14 — Profile Foundations: Store, Guard, Seams, Strings](index.md)
- **Component:** C09 — `Resources/Localizable.xcstrings` (en + ne)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-098](../TG-16-interview-wizard-and-startup-routing/T-098-address-as-field.md), [T-099](../TG-16-interview-wizard-and-startup-routing/T-099-about-you-step.md), [T-100](../TG-16-interview-wizard-and-startup-routing/T-100-emergency-contacts-step.md), [T-101](../TG-16-interview-wizard-and-startup-routing/T-101-voice-fingerprint-step.md), [T-102](../TG-16-interview-wizard-and-startup-routing/T-102-step-enum-and-cold-start-routing.md), [T-103](../TG-17-settings-release-and-evidence/T-103-profile-settings-editor.md), [T-096](../TG-15-personalization-paths/T-096-wake-acknowledgment-service.md)
- **Requirements:** NFR-PI-006, FR-PI-010 · OD-A2

## Description

Every new user-visible string is keyed in the string catalogue in both languages (`en`, `ne`), so the wizard steps, the acknowledgement templates and the Settings editor never hard-code copy. The name and the address-as term are data and are never catalogued. Delivered as one catalogue-only change: the ack template key `wakeAck.personalized` (ne `हजुर %@`, en `Yes, %@`) plus the new key families listed under C09. Button keys reuse the existing `onboarding.next` / `onboarding.skip` / `common.back` keys; the emergency inline add form reuses the existing `onboarding.stepFamily.*` field keys.

## Acceptance criteria

```gherkin
Feature: L10n catalogue additions

  Scenario: The acknowledgement template resolves in both languages
    Given the key wakeAck.personalized is present with a %@ placeholder in en and ne
    When it is resolved for a term and formatted
    Then en yields "Yes, <term>" and ne yields "हजुर <term>"
    And the term is filled as data and never catalogued (FR-PI-010)

  Scenario: Step, editor and emergency families are complete in both languages
    Given the new key families (onboarding.aboutYou.*, onboarding.emergency.*, onboarding.stepVoiceFingerprint.*, onboarding.voiceFingerprint.*, settings.profile.title, profile.field.*, profile.kin.note, profile.save, profile.saved, profile.error.saveFailed)
    When the catalogue is validated in a test
    Then every key resolves in en and in ne with non-empty copy
    And no step, editor or acknowledgement string is hard-coded in Swift

  Scenario: A missing template key degrades loudly, never silently
    Given a build where wakeAck.personalized has no value
    When the acknowledgement service tries to render it
    Then the ack speaks nothing and the event wake_ack_failed with error_code template_missing is emitted (C05)
    And the UI degrades to the key string exactly as the app does today

  Scenario: Settings L10n resolution is available before the row ships
    Given the Settings editor row keys are catalogued here
    When the Settings tab mapping test runs after the editor task lands
    Then settings.profile.title resolves in en and ne and the row's key check passes (NFR-PI-006)
```

## Implementation notes

- Catalogue-only: no Swift, no tests other than the validation test this task adds (`L10nCatalogCoverageTests` or the existing L10n test target extended) that iterates the new keys in both languages.
- `%d` / `%@` placeholders follow the existing `L10n.fmt` conventions; keep positional formatting intact so the ne template renders the term in its own word order.
- OD-A2: the en copy for the ack template (`Yes, %@`) is an owner eyeball item — surface it in the PR description; the owner confirms wording at review time. Record the owner action in `plan.md` (not an agent task).
- Do not add keys for anything outside the C09 list; do not catalogue the term, the name, or any profile value.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (catalogue validation test)
- [ ] Every new key present in en and ne; no unused or duplicate keys added
- [ ] OD-A2 note present in the PR description for the owner's copy review
- [ ] `ios/build.sh` passes
