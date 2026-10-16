# FR-MSR-017: PII-free wire — significant events extend the existing taxonomy with no new PII

## Metadata
- **Area:** Wire Discipline / Safety
- **Priority:** MUST
- **Source:** Owner's brief scope point 6 (2026-10-15); feature constitution "Caregiver Notification Contract" binding property 2 and "Safety & Compliance Delta" (d); Open Decision 3 (RESOLVED 2026-10-15 — "the wire stays PII-free"); project constitution Privacy standards.

## Description
Significant-event notifications **must** extend the existing PII-free alert taxonomy; **no new PII may travel on the wire** (safety_delta (d)). The versioned envelope carrying the alert type and a timestamp is the wire contract; the missed-medication alert carries the hashed entry reference only — no medication name, no dose, no household content.

Binding properties:

- **Taxonomy extension, not a parallel wire.** New significant events (intake recorded, escalation started) are added to the existing alert-type taxonomy and use the same versioned envelope shape.
- **No names or titles on the wire.** Putting caregiver-useful content such as medication names or notification titles on the wire is an owner-level decision under the existing in-memory-title rule; if the design wants such content, it is raised explicitly — never smuggled in.
- **Hash reference only.** Medication-level correlation travels as the one-way entry hash, consistent with NFR-MSR-002; the hash must not be reversible to a name through any shipped mapping.

## Rationale
The PII-free wire is a standing discipline in this codebase with an explicit escalation rule (title-on-wire requires an owner decision). The revamp multiplies notification volume and types; without this requirement, "always notified" would quietly become "more PII in transit".

## Acceptance criteria

```gherkin
Feature: Significant-event notifications carry no PII

  Scenario: Every new significant event uses the versioned, type-only envelope
    Given each new significant event type (intake recorded, escalation started) and the existing ones (missed dose, possible double dose)
    When a notification payload is constructed
    Then it carries the version, the alert type and the timestamp
    And it carries the hashed entry reference where a medication-level correlation is needed
    And it carries no medication name, dose or other household content

  Scenario: Medication names do not reach the wire (failure guard)
    Given a design proposal that would include the medication name or a human-readable title in the payload
    When the payload is reviewed against this requirement
    Then it is rejected as introducing new PII on the wire
    And any such content requires an explicit owner-level decision recorded before it ships

  Scenario: The entry hash is not reversible on-device
    Given the hashed entry reference used in notifications
    When the mapping is inspected
    Then no shipped path maps the hash back to a medication name for wire purposes
```

## Related
- FR: FR-MSR-015 (significant-event set), FR-MSR-016 (channels and honest delivery)
- NFR: NFR-MSR-002 (PII-free observability)
