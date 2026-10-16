# NFR-CDP-002: Feasibility probes are local — no new network, data, identity or privacy surface

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Frozen design non-goals ("No new network, data, identity, or privacy surface — feasibility probes are local") and §2 ("local probe only"); feature constitution "Safety & Compliance Delta" ("no new data, network, identity, or privacy surface — the feasibility probes are local (`canOpenURL`, address-book handle check)") and Feature Constraint 8; workflow `security-design-review` focus ("Feasibility probes are local-only: canOpenURL + address-book handle check; no new egress, no new data collection (handles/numbers are PII)").

## Description
The feature **must** add no network, data, identity or privacy surface. Measurable properties:

- **Zero new egress**: neither the Messenger handle check nor the WhatsApp probe performs network I/O — **0** socket/HTTP operations on the resolution path (the probe is a local `canOpenURL` scheme check; the handle check reads the existing on-device store).
- **Zero new hosts/endpoints/permissions**: no new URL host, no new `Info.plist` permission or query-scheme entry (the schemes are already declared), no new entitlement.
- **Zero new data stores**: the only new persisted datum is the `secondaryCallApp` preference string; numbers/handles remain in their existing stores under the existing policy; no new telemetry or analytics event carries target content.
- **PII stays local**: no phone number, handle or contact name leaves the device through any new path; the existing egress surfaces and their disclosures are untouched.

## Acceptance criteria

```gherkin
Feature: Local-only feasibility

  Scenario: Resolution performs no network I/O
    Given a build exercising the feasibility probe and handle check
    When any target is resolved through the chain
    Then zero network requests are made by the resolution path
    And the probe only queries the local scheme availability

  Scenario: No new permission, store or host is introduced
    Given the feature's build diff
    When permissions, Info.plist declarations, stored data and network hosts are inspected
    Then zero additions exist beyond the secondaryCallApp preference string
    And the existing privacy surfaces and disclosures are unchanged
```

## Related
- FR: FR-CDP-004/005 (the two probes), FR-CDP-018 (no new surface)
- NFR: NFR-CDP-003 (log surface), NFR-CDP-010 (compliance gates)
