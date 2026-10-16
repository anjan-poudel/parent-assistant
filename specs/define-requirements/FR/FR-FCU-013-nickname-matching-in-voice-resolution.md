# FR-FCU-013: Nickname matching in voice call resolution

## Metadata
- **Area:** Nicknames / Voice Resolution
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 3 ("matched by name OR any nickname/variation in … voice resolution"); feature constitution Nickname & Variation Contract binding properties 2, 5 ("In voice resolution, nickname hits follow the same conservative scoring discipline as the name path and are never upgraded to an exact-name match") and Feature Constraint 7; DV-2; workflow scope comment ("matched in BOTH in-app search and voice call resolution, reusing the existing name-matching semantics"). Integration surfaces: `ContactResolver` (relationship anchors :41, scoring :93, accept 0.6 / ambiguity margin 0.15 :61–62), `MethodResolver` (chain: explicit → family preference → confirmed history → global default `.phone`; `resolve(contactId:requestedApp:callType:)` :47 — also edited by call-dialer, sequence per NFR-FCU-008).

## Description
Voice call resolution **must** resolve a spoken name OR any nickname/variation (including Devanagari forms), reusing the existing deterministic resolution path:

- Same normalization/scoring discipline as the existing name path — `NepaliTextNormalizer` folding, honorific stripping (`strippingHonorifics`), the existing scoring bands — reuse, no fork.
- A nickname hit follows the existing conservative scoring discipline and is **never upgraded to an exact-name match**: a nickname is weaker identity evidence than the stored name, and the scoring must reflect that (design-l1 fixes the exact band; the no-upgrade rule binds).
- The existing accept threshold (0.6) and ambiguity margin (0.15) discipline is preserved — the values and the rivals rule are not weakened to accommodate nicknames.
- Relationship anchors/relationship tier behave exactly as today; the "LLM proposes, code disposes" determinism is preserved — no LLM anywhere near the decision of WHO gets called.
- Once the contact is resolved, `MethodResolver`'s method chain (explicit → family preference → confirmed history → global default) is unchanged; the nickname seam does not alter method selection.
- Cross-script is not bridged (FR-FCU-011): a Romanized utterance does not resolve a Devanagari-only nickname; the existing not-found/near-miss honesty applies.

## Acceptance criteria

```gherkin
Feature: Nickname matching in voice call resolution

  Scenario: "call <nickname>" reaches the right person
    Given a family contact with the nickname "sanu"
    When the user says "sanu लाई कल गर" / "call sanu"
    Then that contact is resolved and the standard confirmation names them

  Scenario: A Devanagari variation resolves
    Given a family contact with the Devanagari nickname "सानु"
    When the user says "सानुलाई फोन गर"
    Then that contact is resolved

  Scenario: A nickname is never upgraded to the exact-name band
    Given a contact whose nickname equals the spoken query
    And another contact whose stored name equals the same query
    When resolution runs
    Then the exact stored-name match outranks the nickname hit
    And the nickname is not treated as an exact-name match

  Scenario: Cross-script is not bridged (failure/edge)
    Given a contact whose only nickname is "सानु"
    When the user says "sanu"
    Then the contact is not resolved from that alone
    And the existing honest not-found/near-miss behavior applies
```

## Related
- FR: FR-FCU-011 (store-as-entered), FR-FCU-012 (search parity), FR-FCU-014 (ambiguity), FR-FCU-004 (one person in voice)
- NFR: NFR-FCU-001 (resolution latency), NFR-FCU-007 (grapheme pin), NFR-FCU-008 (call-dialer sequencing on `MethodResolver`)
