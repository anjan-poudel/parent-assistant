# FR-MSR-016: Caregiver notification channels and honest per-contact delivery

## Metadata
- **Area:** Caregiver Notification / Delivery Honesty
- **Priority:** MUST
- **Source:** Owner's brief scope point 6 (2026-10-15); feature constitution "Caregiver Notification Contract" binding properties 3, 5, 6 and Open Decision 3 (RESOLVED 2026-10-15); Open Decision 7 (OPEN — carried to the design chain); `requirements.md` FR-038 (companion-app configuration, read-only input).

## Description
Significant medication events (FR-MSR-015) **must** be delivered across the caregiver channels as paths, and delivery status **must** be honest:

- **Channels.** The caregiver app push path, the consent-gated family calendar channel, and the text channels derived from each contact's calling preference all remain available paths for significant events.
- **Per-contact honest results.** Every delivery attempt produces a per-contact result carrying success or the concrete failure (channel and error code). Partial delivery is acceptable; it must be reported as partial — never as success.
- **Transport scope honesty.** The in-app triggers and the calendar channel are this feature's scope; the end-to-end push transport remains inherited, tracked work. Delivery claims are made only for what actually fires; where delivery cannot happen, it is reported as not delivered (FR-MSR-018), never described as "notified".
- **Consent gate respected.** The calendar channel only operates for households that granted calendar sharing consent.
- **Open Decision 7 is carried to the design chain**: which mechanism the "calendar events" channel uses (the existing schedule mirror that caregivers follow, significant events written as calendar entries, or another shape) is design-level — bounded by the consent gate, the honest-result rule, and FR-MSR-017 (no new PII on any channel).

## Rationale
"Always notified" is only meaningful if the system never lies about it. The app-side triggers already fire; the push transport is a stub. This requirement couples the notification mandate to an equal and opposite honesty mandate so the feature cannot present a stub as a delivered notification.

## Acceptance criteria

```gherkin
Feature: Significant events reach caregivers with honest delivery status

  Scenario: Partial delivery is reported as partial
    Given two family contacts with different channels
    When a missed-medication notification succeeds for one contact and fails for the other
    Then the successful contact's result records success with its channel
    And the failed contact's result records the failure with its channel and error code
    And the overall outcome is reported as partial, not as success

  Scenario: A notification that could not be delivered is not reported as delivered
    Given the push transport is not implemented for a contact
    When a significant-event notification is attempted for that contact
    Then the outcome is recorded as not delivered
    And no surface describes the caregiver as notified

  Scenario: The calendar channel respects its consent gate (edge)
    Given a household that has not granted family calendar sharing
    When a significant event occurs
    Then no event is written to the family calendar for that household
```

## Related
- FR: FR-MSR-015 (significant-event set), FR-MSR-017 (PII-free wire), FR-MSR-018 (honest degradation)
- NFR: NFR-MSR-002 (metadata-free observability)
