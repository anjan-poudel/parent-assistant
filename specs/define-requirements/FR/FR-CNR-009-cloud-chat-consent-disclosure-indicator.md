# FR-CNR-009: Cloud chat consent, plain-language disclosure, visible indicator and revocation (the OD-12 shape)

## Metadata
- **Area:** Cloud Chat Consent & Disclosure
- **Priority:** MUST
- **Source:** Proposal §5.3 ("explicit consent + plain-language disclosure + visible indicator, revocable, never blocks chat — the OD-12 shape"); feature constitution "Cloud-first chat routing toggle (P0)" properties 2, 5 and 6, and Safety & Compliance Delta 2 ("NEW cloud egress surface: chat conversation content … recorded in the OD-12 shape as an explicit exception/amendment — not a silent divergence from Architecture Constraint 1"); project constitution Architecture Constraint 1 recorded exceptions, Open Decisions 12 and 13 (the consent/disclosure pattern), and Standards Privacy ("each of which requires explicit user consent and plain-language disclosure"). Surface: the router's cloud-readiness/consent state, the existing consent UX seams.

## Description
The cloud chat path is a **consent-gated exception** to Architecture Constraint 1 and **must** carry the Open Decision 12 treatment, exactly:

- **Explicit consent at first cloud chat use**, with **plain-language disclosure** of what leaves the device (the chat conversation content), to whom, and what stays local. Consent is the user's (the elderly person's) explicit act; no default-on egress before consent, no consent buried in a general terms screen.
- **A visible indicator while conversation content is going to the cloud** — perceivable in the user's configured language, present for the whole time the cloud path is active, not a one-time toast.
- **Revocable at any time**; revoking returns subsequent turns to the on-device brain **without losing assistant functionality** — chat keeps working, no feature is held hostage to consent.
- **The grammar-guard escalation obeys the same rules** (FR-CNR-006): it is a second, smaller cloud egress surface and is consent-gated exactly like routing — a flag never silently opens an unconsented egress.
- **Conversation content is going to the cloud only when the exception is active**: consent state gates the route, and a declined/revoked state is enforced at the routing decision, not merely in the UI (NFR-CNR-011 evidence).
- **Consent/disclosure copy and the indicator UX are reviewed before the first App Store submission**, consistent with the Open Decision 12/13 review clause; the feature-level exception is recorded so the root constitution's recorded-exceptions list can be amended at final sign-off.

## Acceptance criteria

```gherkin
Feature: Cloud chat egress is consented, disclosed, indicated and revocable

  Scenario: First cloud chat use requires explicit consent
    Given a device that has never used cloud chat
    When a chat turn would route to the cloud
    Then plain-language disclosure is shown before any chat content is sent
    And no chat content leaves the device until the user consents

  Scenario: A visible indicator is present while cloud chat is active
    Given cloud chat consent has been granted and the cloud path is active
    When chat turns are handled
    Then a visible indicator is shown while conversation content is going to the cloud
    And it is rendered in the user's configured language

  Scenario: Revocation returns to the on-device brain without losing chat
    Given cloud chat consent is revoked
    When the user speaks a chat turn
    Then the turn is answered on-device
    And the assistant loses no chat functionality

  Scenario: The grammar-guard escalation is consent-gated too (failure)
    Given consent has been declined or revoked
    When the grammar guard flags a local reply and would escalate
    Then no chat content is sent to the cloud
    And the turn resolves through the safe-template path
```

## Related
- FR: FR-CNR-006 (escalation shares these rules), FR-CNR-008 (routing), FR-CNR-010 (egress scope), FR-CNR-025 (DV-2 records consent/indicator/toggle-off)
- NFR: NFR-CNR-007 (telemetry content hygiene), NFR-CNR-009 (accessibility of the consent/indicator surfaces), NFR-CNR-010 (localisation), NFR-CNR-011 (release gates)
