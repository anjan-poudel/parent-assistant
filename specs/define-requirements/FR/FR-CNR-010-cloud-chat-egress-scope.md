# FR-CNR-010: Cloud chat egress scope — the chat turn's user content and nothing else

## Metadata
- **Area:** Cloud Chat Egress Scope
- **Priority:** MUST
- **Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 3 ("Scope of egress: the chat turn's user content only. No health data, contacts, or profile content beyond what the user's own utterance contains. Emergency and command content flows through the existing (unchanged) paths, not this toggle") and Safety & Compliance Delta 2; project constitution Architecture Constraint 1 and Standards Privacy; project rule that no new data collection is introduced by this feature.

## Description
The only content that may leave the device through this feature **must** be the chat turn's user content — the spoken utterance and the conversational context needed to answer that turn — and nothing else. Binding properties:

- **No adjacent payload.** Health data (HealthKit values, medication state), contacts, family data, profile content, device identifiers and voice recordings are not added to a cloud chat request beyond what the user's own utterance contains.
- **Emergency and command content are out of this path.** Emergency phrasing and command turns flow through the existing (unchanged) routing and emergency paths; the chat toggle never carries them and never re-routes them (FR-CNR-014).
- **The escalation path has the same scope** as the routing path — a guard-triggered escalation sends the chat turn's content, not a broader context (FR-CNR-006).
- **No new data collection.** The feature introduces no telemetry, analytics or storage collection beyond the classification-only events this set defines (FR-CNR-007) and the recorded cloud-chat egress itself.

## Acceptance criteria

```gherkin
Feature: Cloud chat egress is bounded to the chat turn

  Scenario: A cloud chat request contains the chat content only
    Given cloud chat is consented and online
    When a chat turn is sent to the cloud
    Then the request carries the turn's user content and the contextual turns needed to answer it
    And it carries no health data, contacts, or profile payload beyond the utterance

  Scenario: Emergency and command turns never travel this path
    Given a device with cloud chat enabled
    When an emergency utterance or a command turn is spoken
    Then it is handled through the existing (unchanged) path
    And the chat routing toggle does not carry or re-route it

  Scenario: An adjacent payload is attached (failure)
    Given a cloud chat request under inspection
    When it contains health values, contact data or profile content beyond the utterance
    Then the request is reported as an Architecture Constraint 1 violation
    And the feature does not ship in that state
```

## Related
- FR: FR-CNR-008 (routing), FR-CNR-009 (consent), FR-CNR-012 (hygiene), FR-CNR-014 (command/emergency paths untouched), FR-CNR-015 (no new data collection)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-007 (telemetry hygiene)
