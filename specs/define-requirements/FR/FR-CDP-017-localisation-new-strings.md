# FR-CDP-017: Localisation — new ne/en strings; spoken language matches the session

## Metadata
- **Area:** Localisation
- **Priority:** MUST
- **Source:** Frozen design §7 ("New ne/en keys in `Localizable.xcstrings`: settings section titles (`settings.calling.primaryTitle`, `settings.calling.secondaryTitle`), confirmation fallback disclosure template (`router.call.fallbackDisclosure`), routed-channel announcement (`call.announce.fallbackRouted`), launch-fail announcement (`call.announce.launchFailedFallback`)"); feature constitution Feature Constraint 9 ("Localization discipline"); project Standards (Localisation); DV-7.

## Description
All new user-visible strings of this feature **must** be externalised in `ios/ElderlyAssistant/Resources/Localizable.xcstrings` with Nepali **and** English values:

| Key | Surface |
|---|---|
| `settings.calling.primaryTitle` | Primary dialer section title |
| `settings.calling.secondaryTitle` | Fallback dialer section title |
| `router.call.fallbackDisclosure` | Spoken-confirmation fallback disclosure template (contact name + routed channel + skipped channel) |
| `call.announce.fallbackRouted` | Routed-channel announcement on tap/dial-back paths |
| `call.announce.launchFailedFallback` | Launch-fail announcement via the spoken-outcome lane |

Binding rules:
- No hard-coded user-visible string may be introduced; templates take their contact/channel parameters through the existing `L10n.fmt` discipline.
- Spoken output **must** use the session's active language (`activeLocale`), matching the rest of the call flow.
- Channel names **must** reuse the existing `app.name.*` catalog keys, so the picker labels, the confirmation and the announcements agree in both scripts.
- A missing or unknown key **must never** be spoken raw (NFR-CDP-007 pins the completeness check).

## Acceptance criteria

```gherkin
Feature: Localisation of the new strings

  Scenario: A Nepali session hears and sees Nepali
    Given the session's active language is Nepali
    When the user opens the dialer settings and a fallback/launch-fail occurs on a call
    Then the two section titles render in Nepali
    And the confirmation disclosure and both announcements are spoken in Nepali
    And the channel names match the picker labels

  Scenario: An English session hears and sees English
    Given the session's active language is English
    When the same surfaces are exercised
    Then every new string renders and is spoken in English
    And the channel names still match the picker labels

  Scenario: No user-visible surface falls back to a raw key
    Given both language resources are present
    When the new surfaces are exercised in either language
    Then no raw catalog key or untranslated fallback string is shown or spoken
```

## Related
- FR: FR-CDP-001/002 (section titles), FR-CDP-013 (disclosure), FR-CDP-015/016 (announcements)
- NFR: NFR-CDP-007 (completeness/parity check)
