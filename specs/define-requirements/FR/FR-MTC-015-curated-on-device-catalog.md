# FR-MTC-015: Curated on-device option catalog

## Metadata
- **Area:** Option Catalog
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Integration Surfaces ("**NEW** curated on-device music option catalog — Bhajan deity → canonical search query; zero latency; consistent with the on-device stance (study §5.4)") and the Probe Kinds table ("Candidate source: the curated on-device catalog (bhajan deity → canonical search query)"); feasibility study §5.4 (option 1, recommended MVP) and §6.2 ("Options come from the curated catalog (5.4), never the model"); OD-M2 (OPEN — curated catalog vs live Spotify playlist search; the study recommends the curated on-device catalog for the MVP).

## Description
The probe options and the canonicalisation input **must** come from a curated, on-device catalog:

- **Structure**: a small local mapping (bhajan deity → canonical search query, e.g. दुर्गा → "durga bhajan") covering the launch option list(s); the exact contents are data, not code, and are refined at design time (OD-M2 may extend the sourcing later — the Phase 1 binding is the on-device curated catalog).
- **On-device stance**: zero network, zero latency, works offline; no new egress (NFR-MTC-003); consistent with Architecture Constraint 1 and the Spotify feature's privacy disclosure (music-query egress remains only the existing search path).
- **Localizable ne/en**: option names and their spoken forms exist in both languages (NFR-MTC-006); the canonical query values are the deterministic strings the music search consumes.
- **Informational, not restrictive**: the catalog shapes the probe's options and canonicalises matching answers (FR-MTC-006); it never limits what the user may say — free-form answers always flow (FR-MTC-005).
- **Deterministic**: catalog lookup is a pure, model-free function of the answer text (NFR-MTC-005).

## Acceptance criteria

```gherkin
Feature: Curated on-device option catalog

  Scenario: The bhajan probe's options come from the catalog in the active language
    Given the slot-fill probe is triggered for a bhajan request
    When the probe is spoken
    Then the named options are the catalog entries rendered in the user's active language
    And a catalog default option is available

  Scenario: A catalog-matching answer canonicalises to the canonical query
    Given the user answers "दुर्गा"
    When the deterministic merge runs
    Then the merged search query is the catalog's canonical value for that entry ("durga bhajan")

  Scenario: The catalog works with no network
    Given the device is offline
    When the probe is spoken and answered with a catalog option
    Then the probe and the canonicalisation both work with zero network access
```

## Related
- FR: FR-MTC-003 (the probe that uses it), FR-MTC-005 (free text overrides any list), FR-MTC-006 (canonicalisation in the merge)
- NFR: NFR-MTC-003 (no new egress), NFR-MTC-006 (localisation), NFR-MTC-005 (deterministic), NFR-MTC-001 (zero added latency)
