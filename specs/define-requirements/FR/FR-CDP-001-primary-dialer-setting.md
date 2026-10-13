# FR-CDP-001: Primary dialer setting — four channels, persisted

## Metadata
- **Area:** Settings / Primary Dialer
- **Priority:** MUST
- **Source:** Frozen design §1 ("`CallingSettingsView` renders two sections: **Primary dialer** and **Fallback dialer**, each the existing four-channel row pattern") and Goal 1; feature constitution "In scope" bullet 1 and "Integration Surfaces" (`CallingSettingsView.swift` — "New Primary dialer + Fallback dialer sections/pickers"); workflow scope comment ("two settings sections (Primary dialer, Fallback dialer) over the 4 channels ... `defaultCallApp` = primary"); DV-1.

## Description
Calling Settings (the existing `CallingSettingsView`, reached under `settings.calling.title`) **must** present a **Primary dialer** section letting the user choose exactly one of the four channels — FaceTime, phone (GSM), Messenger, WhatsApp — using the existing selectable-row pattern (app-name label + selected-state checkmark; the existing `app.name.*` catalog keys are reused so the option labels agree with every other surface in both scripts).

Selecting a channel **must** bind the coordinator's existing `defaultCallApp` preference (the existing `@Published` + UserDefaults seam, key `defaultCallApp`; `didSet` persists, the single init-time restore assigns directly, and an absent/unknown stored value resolves to `.phone`). The selection **must** persist across relaunch. The section title **must** come from the new catalog key `settings.calling.primaryTitle` (ne/en — FR-CDP-017).

This pick is the chain's preferred input whenever a call target has no explicit per-contact/family pick (FR-CDP-009).

## Acceptance criteria

```gherkin
Feature: Primary dialer setting

  Scenario: The Primary dialer section renders the four channels with the current pick selected
    Given the user opens Settings, Calling
    Then a "Primary dialer" section is shown with the four channels: FaceTime, phone, Messenger, WhatsApp
    And each row shows the channel's app-name label
    And the row matching the current defaultCallApp shows the selected state

  Scenario: Selecting a primary channel persists across relaunch
    Given the Primary dialer is FaceTime
    When the user selects WhatsApp
    Then the coordinator's defaultCallApp is whatsApp
    And after the app is relaunched the WhatsApp row still shows the selected state
    And the preference is the global default used by call resolution
```

## Related
- FR: FR-CDP-002 (fallback picker), FR-CDP-003 (secondary persistence seam), FR-CDP-009 (preferred input), FR-CDP-012 (voice-path mapping)
- NFR: NFR-CDP-005 (persistence round-trip), NFR-CDP-006 (picker accessibility), NFR-CDP-007 (localisation completeness)
