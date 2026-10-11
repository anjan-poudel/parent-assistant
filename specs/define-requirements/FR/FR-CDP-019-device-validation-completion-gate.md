# FR-CDP-019: DV-1..7 device validation recorded and passed (completion gate)

## Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Feature constitution "Success Criteria & Completion Gate" (DV-1 … DV-7 on the reference device, the DV pattern of prior shipped features, recorded with the feature spec); frozen design §9 ("Completion gate: DV-1..7 device validation on Anzaan"); workflow `final-sign-off` comment ("DV-* device validation on Anzaan is part of the completion gate ...").

## Description
The feature **must not** be considered complete until the DV-1..7 checklist from the feature constitution is executed on the reference device (Anzaan), recorded with this feature set, and passed:

- **DV-1** — Settings: Primary + Fallback pickers persist across relaunch (`secondaryCallApp` next to `defaultCallApp`).
- **DV-2** — Primary infeasible (Messenger, no handle on file) → the call completes via the fallback with the spoken announcement naming the routed channel.
- **DV-3** — WhatsApp not installed (`canOpenURL` false) → the chain lands on the fallback/GSM with the announcement; a launch failure is announced via the existing spoken-outcome lane (no silent failure).
- **DV-4** — `secondary == primary` dedupes; both primary and secondary infeasible → `phone` is attempted; zero dead ends.
- **DV-5** — Override preserved: "होइन, फोन नै गर" still switches to a phone call.
- **DV-6** — All call paths route the chain: address-book row, family-contact, missed-call dial-back, voice-initiated call (MethodResolver global default).
- **DV-7** — ne/en copy: pickers, confirmation and announcement strings localised; spoken language matches the session.

Any unresolved or failed DV item **must** block sign-off (the `final-sign-off` task is T2 + HIL); a partial pass is not a completion. The release log-safety gate (`ios/tools/check-release-log-safety.sh`) must also exit 0 as part of the same closure (NFR-CDP-003, NFR-CDP-010).

## Acceptance criteria

```gherkin
Feature: Device-validation completion gate

  Scenario: The DV checklist is recorded and passed
    Given the feature build is installed on the reference device (Anzaan)
    When DV-1 through DV-7 are executed per the constitution's checklist
    Then each item passes and its evidence is recorded with the feature spec
    And the completion gate is satisfied for sign-off

  Scenario: An unresolved DV item blocks completion
    Given any DV item is unresolved or fails on the device
    When final sign-off is considered
    Then the feature is not signed off
    And the item is reworked and re-validated (no partial pass)
```

## Related
- FR: FR-CDP-001/002/003 (DV-1), FR-CDP-013 (DV-2), FR-CDP-005 (DV-3), FR-CDP-007 (DV-4), FR-CDP-014 (DV-5), FR-CDP-010/011/012 (DV-6), FR-CDP-017 (DV-7)
- NFR: NFR-CDP-010 (release/compliance gates the closure runs), NFR-CDP-003 (release log gate)
