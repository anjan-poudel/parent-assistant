# FR-CDP-002: Fallback dialer setting — four channels, equal picks legal

## Metadata
- **Area:** Settings / Fallback Dialer
- **Priority:** MUST
- **Source:** Frozen design §1 ("`CallingSettingsView` renders two sections ... **Fallback dialer** ... `secondary == primary` is legal and dedupes at routing time") and Goal 1; feature constitution "In scope" bullet 1 and Feature Constraint 4 ("`secondary == primary` is allowed and routes with dedupe"); workflow scope comment; DV-1, DV-4.

## Description
Calling Settings **must** present a **Fallback dialer** section beside the Primary dialer section, using the same four-channel selectable-row pattern, letting the user choose exactly one fallback channel. Selecting a channel **must** bind a new coordinator preference `secondaryCallApp` (FR-CDP-003 carries its persistence contract).

Rules:
- Choosing the same channel as the primary is legal: both sections may show the same selection and the app **must not** block, warn against, or silently alter an equal pick — routing dedupes instead (FR-CDP-007; each channel attempted at most once).
- Selecting in one section **must not** change the other section's selection (`defaultCallApp` and `secondaryCallApp` are independent).
- The section title **must** come from the new catalog key `settings.calling.secondaryTitle` (ne/en — FR-CDP-017), and the option labels reuse the existing `app.name.*` keys.

## Acceptance criteria

```gherkin
Feature: Fallback dialer setting

  Scenario: The Fallback dialer section renders and persists a selection
    Given the user opens Settings, Calling
    Then a "Fallback dialer" section is shown with the four channels
    When the user selects phone as the fallback
    Then secondaryCallApp is phone
    And after the app is relaunched the phone row still shows the selected state

  Scenario: An equal primary and fallback pick is accepted
    Given the user selects Messenger as the primary
    When the user selects Messenger as the fallback
    Then both sections show Messenger as selected
    And no error, warning or auto-correction is shown
    And call resolution dedupes the equal channels at routing time

  Scenario: The two pickers are independent
    Given the primary is FaceTime and the fallback is phone
    When the user changes the fallback to WhatsApp
    Then secondaryCallApp is whatsApp
    And defaultCallApp is still faceTime
```

## Related
- FR: FR-CDP-001 (primary picker), FR-CDP-003 (persistence), FR-CDP-007 (dedupe in the chain)
- NFR: NFR-CDP-005 (persistence round-trip), NFR-CDP-006 (picker accessibility), NFR-CDP-007 (localisation completeness)
