# FR-MSR-004: Purpose at entry — a brief purpose description on every medication

## Metadata
- **Area:** Purpose
- **Priority:** MUST
- **Source:** Owner's brief scope point 2 (2026-10-15); feature constitution "Feature Purpose & Scope" ("Purpose-at-entry (owner point 2), building on the shipped purpose field, chips, and lookup — not a new mechanism") and "Entry Model & Slot-to-Clock Mapping Contract" binding property 4.

## Description
Each medication **must** be able to carry a brief purpose description set at entry (owner point 2), built on the shipped machinery — the existing purpose field, the purpose chips, the medication voice vocabulary and the purpose lookup service — not a new mechanism.

Binding properties:

- **Purpose is carried at entry.** The medication editor exposes purpose as part of the entry surface so the family can state what the medication is for in a few words.
- **Required or optional at entry is design-level.** Whether the design makes purpose mandatory on new entries is left to design-l1/l2; either way, medication function and safety must never depend on the purpose text being present, and pre-purpose payloads keep loading (NFR-MSR-006).
- **The lookup path is the shipped, gated path.** Where the assistant helps resolve a purpose, it uses the shipped purpose lookup under its existing disclosure; that lookup's medicine-name egress through the search stack is the shipped stack's egress, not a new one this feature introduces (NFR-MSR-003).

## Rationale
Owner point 2: a forgetful elder and a remote caregiver both benefit from the "why" of each medication. The constitution pins this onto shipped machinery — chips, vocabulary, lookup — so the feature adds the entry-surface obligation without reinventing the mechanism.

## Acceptance criteria

```gherkin
Feature: Purpose description at entry

  Scenario: Family sets a purpose for a medication
    Given the medication editor for a household
    When the family selects a purpose from the shipped purpose chips and saves
    Then the entry carries that purpose
    And the shipped surfaces that render purpose (for example the spoken medication summary) render it

  Scenario: An entry without a purpose still works (edge)
    Given an entry saved without any purpose text
    When the schedule runs, the reminder fires and the elder acknowledges
    Then the acknowledgement, challenge and recording flow complete normally
    And no behaviour depends on the purpose being present

  Scenario: A pre-purpose payload loads (migration edge)
    Given a stored medication payload created before the revamp, carrying no purpose
    When the payload is loaded in the revamped build
    Then it loads successfully
    And its medication remains fully functional
```

## Related
- FR: FR-MSR-001 (entry model), FR-MSR-005 (scan-to-fill — purpose is not scannable)
- NFR: NFR-MSR-006 (migration compatibility), NFR-MSR-003 (no new egress)
