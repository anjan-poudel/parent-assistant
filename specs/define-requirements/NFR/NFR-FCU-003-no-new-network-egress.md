# NFR-FCU-003: No new network egress — contacts, links, nicknames and photos stay on-device

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution Out of scope ("Any new network surface; any new data collection; anything leaving the device") and Feature Constraint 8 ("No new network surface; no new data collection; PII discipline"); Safety & Compliance Delta ("No new egress: nothing leaves the device; no new network surface"); workflow scope comment non-goals ("any new network surface"); project constitution Architecture Constraint 1 (personal data never leaves the device except recorded, consent-gated exceptions — none of which this feature touches).

## Description
The feature **must** add no network surface and no data collection:

- The link reference, nickname entries, system-contact reads (names/numbers/photos) and the photo write all stay **on-device**; the feature transmits nothing anywhere and collects no new data.
- No new analytics/telemetry of the new paths' content; NFR-FCU-002's classification-only observability is local logging discipline, not an upload.
- No new permission keys: the feature reuses the existing Contacts authorization (its disclosure copy updated per FR-FCU-009); no new `Info.plist` privacy usage keys are added.
- Measurable: the feature diff introduces **zero** new outbound hosts/APIs; a full Release-build exercise of the LINK/PHOTO/NICKNAME flows (link, photo set/fallback, nickname match, ambiguity) makes **zero** network requests attributable to the feature, and completes fully with networking unavailable.

## Acceptance criteria

```gherkin
Feature: No new network egress

  Scenario: The feature diff adds no network surface
    Given the complete feature change set
    When it is inspected for outbound calls, endpoints and new permission keys
    Then zero new outbound hosts/APIs exist
    And no new Info.plist privacy usage keys are added

  Scenario: The flows work offline and transmit nothing
    Given a Release build with networking unavailable
    When linking, photo set/fallback, nickname search/voice match and ambiguity are exercised
    Then every flow completes on-device
    And no network request attributable to the feature is made
```

## Related
- FR: FR-FCU-001..015 (all on-device flows), FR-FCU-009 (the only permission touch — an updated disclosure string)
- NFR: NFR-FCU-002 (log discipline, distinct from egress), NFR-FCU-009 (release gates)
