# FR-CDP-005: WhatsApp feasibility — local installed-app probe via injected closure

## Metadata
- **Area:** Channel Feasibility / WhatsApp
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`whatsApp` — app installed — `canOpenURL("whatsapp://")`, injected as a closure for tests — local probe only") and §3 (closure-injected feasibility); feature constitution "Channel Resolution & Feasibility Contract" and Feature Constraint 3 ("WhatsApp feasibility is the `canOpenURL` probe, injected as a closure so tests stub it deterministically"); DV-3.

## Description
The `whatsApp` channel **must** be treated as feasible if and only if WhatsApp can be opened on this device, probed as `canOpenURL("whatsapp://")`. The scheme is already declared in `Info.plist` `LSApplicationQueriesSchemes`, so no plist change is required.

Binding rules:
- **Local probe only**: the check runs on-device at call time and performs no network I/O and launches no app.
- **Injected seam**: the probe **must** be supplied through injection (a closure/config seam) so tests stub it deterministically and the resolver stays free of platform calls (NFR-CDP-008).
- **Staleness accepted**: iOS may cache scheme availability; this is an accepted residual risk (design Risks) — the probe still runs at call time, user-paced, and the launch-fail hop (FR-CDP-015) covers the residual case.
- **Skip when infeasible**: when the probe is false, `whatsApp` is infeasible and the chain skips it (DV-3: WhatsApp not installed → the chain lands on the fallback/GSM with the announcement).

## Acceptance criteria

```gherkin
Feature: WhatsApp feasibility

  Scenario: The probe reporting installed makes WhatsApp feasible
    Given the injected probe reports whatsapp:// can be opened
    When the channel chain resolves with whatsApp as the preferred channel
    Then whatsApp is treated as feasible
    And it can be returned as the routed channel

  Scenario: The probe reporting not installed makes WhatsApp infeasible and the chain skips it
    Given the injected probe reports whatsapp:// cannot be opened
    When the channel chain resolves with whatsApp preferred
    Then whatsApp is not resolved as the routed channel
    And the chain attempts its next step (the fallback, then GSM)

  Scenario: Probing is local — no network and no app launch
    Given a build exercising the feasibility probe
    When the chain resolves any target
    Then the probe performs no network request
    And the probe opens no app
```

## Related
- FR: FR-CDP-004 (Messenger feasibility), FR-CDP-007 (the chain), FR-CDP-015 (launch-fail hop covering probe staleness)
- NFR: NFR-CDP-002 (no new egress), NFR-CDP-008 (deterministic testability)
