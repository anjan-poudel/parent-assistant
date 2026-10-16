# FR-LCT-020: Shared dictionary and translation cache with the appliance helper

## Metadata
- **Area:** Caching
- **Priority:** MUST
- **Source:** Design §0, §3, §5; feature constitution "Known integration surface"; user-task scope

## Description
The live translation feature **must** be a **new plugin** that shares the appliance helper's
label dictionary and translation cache rather than owning private copies:

- the tier-0 dictionary is the same `ApplianceLabelLocalizer` data set used by the appliance
  helper, extended (not forked);
- the persistent translation cache (FR-LCT-019) is a **single shared store** used by both the
  appliance helper and live translation, keyed `(normalizedText|targetLanguage)`;
- a translation resolved in one surface is available in the other without a new network call;
- sharing **must not** change or weaken the behaviour of the shipped appliance helper
  (`ApplianceLabelLocalizer`, `ApplianceOverlayMapper` are extended/reused, not modified).

## Acceptance criteria

```gherkin
Feature: Shared dictionary and translation cache

  Scenario: A translation cached in the appliance helper is reused by live translation
    Given the appliance helper has translated a label that is now in the shared cache
    When live translation recognizes the same label
    Then the cached translation is shown with no network request

  Scenario: A translation cached in live translation is reused by the appliance helper
    Given live translation has cached a label translation
    When the appliance helper presents the same label
    Then the same cached translation is used

  Scenario: There is exactly one cache store
    Given both features are installed
    When the app's storage is inspected
    Then a single translation cache exists, shared by both entry points
```

## Related
- FR: FR-LCT-019 (persistent cache), FR-LCT-007 (dictionary)
- NFR: NFR-LCT-012 (no regression to the appliance helper)
- Depends on: FR-LCT-019
