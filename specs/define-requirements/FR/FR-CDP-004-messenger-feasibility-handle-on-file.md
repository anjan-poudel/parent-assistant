# FR-CDP-004: Messenger feasibility — handle on file only

## Metadata
- **Area:** Channel Feasibility / Messenger
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`messenger` — handle on file for the target contact — **NOT** gated on the app being installed — the m.me web chat still connects, and shipped tap behavior is preserved") and Decision 3; feature constitution "Channel Resolution & Feasibility Contract" and Feature Constraint 2; DV-2.

## Description
For a given target (family contact or address-book row), the `messenger` channel **must** be treated as feasible if and only if a usable handle is on file for that target — decided by the same normalization the opener uses (`CallLinks.messengerHandle`), so the feasibility gate and the opener can never disagree. The feasibility check **must not** consult whether the Messenger app is installed.

Binding consequences:
- With a usable handle, `messenger` stays feasible even when the app is absent — shipped tap behaviour is preserved and the existing open-time web-chat fallback (`fb-messenger://user-thread/` absent-app chain → `https://m.me/<handle>`, `fellBackToWeb`) still applies and is disclosed out loud.
- Without a usable handle, `messenger` is infeasible and the chain (FR-CDP-007) skips it. Today's single hard rule ("a `.messenger` result without a handle drops to `.phone`") becomes one case of the chain rather than a special rule.

## Acceptance criteria

```gherkin
Feature: Messenger feasibility

  Scenario: A handle on file makes Messenger feasible
    Given the target contact has a usable Messenger handle on file
    When the channel chain resolves against this target
    Then messenger is treated as feasible
    And the chain's preferred channel is returned without a Messenger skip

  Scenario: No handle makes Messenger infeasible and the chain skips it
    Given the target contact has no usable Messenger handle
    When the channel chain resolves with messenger as the preferred channel
    Then messenger is not resolved as the routed channel
    And the chain attempts its next step (the fallback, then GSM)

  Scenario: An absent Messenger app does not make the channel infeasible
    Given the target contact has a usable handle on file
    And the Messenger app is not installed
    When the chain resolves
    Then messenger is still treated as feasible
    And a tap opening this channel keeps the shipped behaviour (the https://m.me web-chat fallback, disclosed out loud)
```

## Related
- FR: FR-CDP-005 (WhatsApp probe), FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-010 (tap paths)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-002 (local-only feasibility)
