# FR-CDP-003: `secondaryCallApp` persistence seam with GSM default

## Metadata
- **Area:** Settings / Persistence
- **Priority:** MUST
- **Source:** Frozen design §1 ("`AppCoordinator` gains `secondaryCallApp: CallApp` next to `defaultCallApp` — same `@Published` + UserDefaults pattern, key `secondaryCallApp`, **default `.phone`**"); feature constitution "In scope" bullet 1 and Feature Constraint 4; workflow `design-l1` scope ("persistence for existing installs (secondaryCallApp absent → GSM)"); DV-1.

## Description
`AppCoordinator` **must** expose `secondaryCallApp: CallApp` next to `defaultCallApp`, using the same persistence pattern the primary preference uses (the existing house seam: a `@Published` property whose `didSet` writes to `UserDefaults` under key `secondaryCallApp`, with the single init-time restore assigning directly so `didSet` does not fire there — `AppCoordinator.swift:330-335, 2851-2853`).

Binding rules:
- **Default is GSM**: a fresh install — and an existing install upgrading where the key is absent — **must** resolve the fallback to `.phone` with no user action. An unrecognised stored raw value **must** also resolve to `.phone`, mirroring the existing `defaultCallApp` restore rule (`.flatMap(CallApp.init(rawValue:)) ?? .phone`).
- **Round-trip**: each of the four channels written through the Fallback dialer picker **must** read back identically after relaunch (NFR-CDP-005 carries the measurable target).
- **No cross-talk**: writing `secondaryCallApp` **must never** mutate `defaultCallApp`, and vice versa.

## Acceptance criteria

```gherkin
Feature: Fallback dialer persistence

  Scenario: An install without a stored fallback resolves to GSM
    Given no value has ever been stored for secondaryCallApp (fresh install or an existing install upgrading)
    When the app launches
    Then secondaryCallApp is phone
    And call resolution treats GSM as the fallback channel

  Scenario: The fallback selection round-trips across relaunch for every channel
    Given the user selects a fallback channel in Calling Settings
    When the app is relaunched
    Then secondaryCallApp equals the selected channel
    And this holds for each of FaceTime, phone, Messenger and WhatsApp

  Scenario: An unrecognised stored value falls back to GSM
    Given the stored secondaryCallApp raw value is unrecognised
    When the app launches
    Then secondaryCallApp is phone
```

## Related
- FR: FR-CDP-002 (the picker that writes this seam), FR-CDP-007 (the chain that reads it)
- NFR: NFR-CDP-005 (round-trip reliability target)
