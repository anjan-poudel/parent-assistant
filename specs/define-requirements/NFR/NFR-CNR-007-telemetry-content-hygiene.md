# NFR-CNR-007: Telemetry content hygiene — every new event carries classification only

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution "Grammar guard (P0)" property 4 ("a `reply_grammar_flag` event carrying NO user content (no transcript, no reply text) — observability-bus policy (PII-free), log discipline per B2/T-050"); project constitution Standards Privacy ("No personal data (voice, health, contacts, conversations) transmitted to cloud for AI processing, except under the recorded exceptions"); project constitution Open Decision 12 (visible indicator, revocable, no content beyond scope); workflow `security-design-review` focus (the flag event carries no user content).

## Description
Every telemetry/observability event introduced by this feature **must** carry classification fields only. Measurable properties:

- **Content field count = 0** for each new event: `reply_grammar_flag` (FR-CNR-007), the cloud-chat routing/consent decisions (granted, declined, revoked, active indicator state), the degradation/fallback outcome, and any DPO/training-run event. Forbidden: utterance text, reply text, transcript text, user identity, health values, contacts, profile content, provider key material.
- **Permitted fields only**: event kind, path (on-device/cloud), failed-check class, outcome enum, counters, reason codes, timestamps, model/catalog identifiers.
- **Egress discipline**: events travel on the existing observability channel and are not a new egress surface for user content; nothing in the telemetry payload can reconstruct the conversation.
- **Reviewable schema**: the event schemas are fixed at security design; adding a content-bearing field is a defect (a schema change, not a configuration change) and is caught by the same review that covers NFR-CNR-006.
- **Consistency with the consent exception**: the telemetry does not widen the consent grant — the consent covers cloud chat content, not content in telemetry.

## Acceptance criteria

```gherkin
Feature: New telemetry events are content-free

  Scenario: Each new event schema is classification-only
    Given the event schemas introduced by this feature
    When each is inspected field by field
    Then every field is a classification, counter, identifier or reason code
    And no field can carry utterance text, reply text, transcript text or identity

  Scenario: Events emitted during a Release exercise contain no content
    Given a Release build exercising chat, guard flags, consent changes and fallbacks
    When the emitted events are inspected
    Then none contains conversation content or key material
    And the payloads cannot reconstruct a conversation

  Scenario: A content-bearing field is added (failure)
    Given a telemetry schema change that adds a content field
    When the change is reviewed
    Then it is rejected as a defect against this requirement
    And the field is removed before ship
```

## Related
- FR: FR-CNR-007 (the flag event), FR-CNR-009 (consent/indicator states), FR-CNR-010 (egress scope), FR-CNR-012 (hygiene)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-011 (release gates)
