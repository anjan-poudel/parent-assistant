# NFR-MTC-003: No new network egress — probes and answers stay on-device

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 3 ("No new network egress; no new compliance regime; the on-device stance and existing encrypted stores are unchanged") and "Out of scope (must not change)" ("No new network egress"); workflow `security-design-review` focus ("No new egress: probes and answers stay on-device; the feature adds no provider calls (music-search egress is Spotify-feature owned)"); project constitution Architecture Constraint 1; feasibility study §5.4 (catalog recommendation: "consistent with the on-device stance").

## Description
The feature **must** add zero network egress:

- **Probes**: template text + curated on-device catalog → no request of any kind to produce a probe; works offline.
- **Answer capture and merge**: sanitisation, scaffolding strip, catalog canonicalisation and frame merge are all local (FR-MTC-006); no provider or cloud call.
- **Model path**: nothing in this feature sends dialogue content to any cloud/BYO-LLM service; any brain use stays the on-device brain (and the Phase 2 clause changes the local prompt only).
- **Music search unchanged**: the only network in a music dialogue remains the existing Spotify-feature search/play path (already covered by that feature's privacy disclosure and egress rules) — this feature adds no host, no endpoint, no widening.
- **Measurable**: an air-gapped run of probe → answer → merge completes with 0 outbound requests up to the point of the (already-permitted) music search itself; a code-surface audit of the feature's new files shows no URL/transport construction (NFR-MTC-012 evidence).

## Acceptance criteria

```gherkin
Feature: No new egress from the dialogue path

  Scenario: The full dialogue works with no network up to the permitted search
    Given the device is offline
    When the user says "भजन बजाऊ", hears the probe and answers "दुर्गा"
    Then the probe is spoken and the answer is merged with zero network requests
    And only the music-search step itself (already permitted) may attempt network

  Scenario: No new endpoint or transport exists in the feature's paths
    Given the feature's new and touched code paths
    When the egress surface is audited
    Then no new host, endpoint or transport construction is present
    And the on-device stance of Architecture Constraint 1 is unchanged
```

## Related
- FR: FR-MTC-015 (on-device catalog), FR-MTC-016 (template probes), FR-MTC-006 (local merge)
- NFR: NFR-MTC-012 (compliance gates), NFR-MTC-005 (no model dependency)
