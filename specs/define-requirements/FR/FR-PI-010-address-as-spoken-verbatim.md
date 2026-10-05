# FR-PI-010: Address-as spoken verbatim (never translated)

## Metadata
- **Area:** Address-as Data Handling
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (stored and spoken verbatim; never translated; never routed through the L10n string catalogs) and Feature Constraint 3; "Field Contract" (Address-as term)

## Description
The address-as term is user data. It **must** be stored and spoken exactly as entered, in every surface where it is used (the wake acknowledgment, FR-PI-008, and brain replies, FR-PI-009). It **must not** be translated, transliterated, substituted for, or routed through the L10n string catalogs. The surrounding acknowledgment/reply copy may be localized in the active app language — the term itself is emitted verbatim. The name follows the same rule wherever it is spoken.

Script/language mixing between the term and the active app language is handled by the localized surrounding copy; the acknowledgment phrasing and per-language templates are OD-F2 (architect).

## Acceptance criteria

```gherkin
Feature: Address-as spoken verbatim

  Scenario: Verbatim in both surfaces
    Given the term is recorded as entered
    When the wake acknowledgment is spoken and when a reply uses the term
    Then each utterance/text contains exactly the recorded string, with no translation or transliteration

  Scenario: The term is data, not a catalog string
    Given the L10n string catalogs and the personalization code paths
    When they are inspected
    Then the term does not appear as a catalog entry
    And no code path passes the term through a localization lookup
```

## Related
- NFR: NFR-PI-006 (localisation of UI strings)
- Open decision: OD-F2 (acknowledgment phrasing and locale handling)
- Depends on: FR-PI-003 (profile store)
