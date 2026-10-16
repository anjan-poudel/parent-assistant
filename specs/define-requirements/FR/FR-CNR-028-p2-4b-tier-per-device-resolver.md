# FR-CNR-028: P2 polish — the 4B chat tier, admitted only through the per-device resolver

## Metadata
- **Area:** P2 Polish / Device Tiers
- **Priority:** COULD
- **Source:** Proposal §4 ("Base: Qwen3-1.7B (device default, 5–8 s/turn) and Qwen3-4B for newer devices; prefer the Nepali extended-tokenizer base (`qwen4BNepali` …) — fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling") and §7 phasing table ("P2 — polish | … 4B tier …") and risks ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Single-decode integrity and catalog swap" property 3 and Success Criteria ("The v17 catalog swap is live behind the per-device resolver, versioned and reversible"); workflow scope comment.

## Description
After P1 ships the 1.7B chat variant as the device default, the feature **may** admit a **4B chat variant** for newer device tiers — but only through the **per-device resolver**, never as a global default. Binding properties:

- **The 1.7B tier stays the default**; the 4B variant is opted into by the resolver based on the device's measured capability, exactly as the existing brain selection works.
- **Residency is single-model**: the resolver serves exactly one tier at a time on a device (no both-models-resident configuration), preserving the memory/jetsam requirement (NFR-CNR-003).
- **The envelope binds**: a tier is admitted only if it stays within the listening-turn latency envelope (NFR-CNR-002) and the memory/jetsam requirement on that tier; a tier that misses the envelope is not admitted, even if newer devices *can* load it.
- **Gated like every other artifact**: the 4B variant is a versioned, reversible catalog candidate behind the full harness (FR-CNR-021, FR-CNR-022) with its own gate evidence; the extended-tokenizer base is preferred (FR-CNR-022).
- **If a tier cannot be admitted, that is reported** (FR-CNR-024), not silently shipped with worse behaviour.

## Acceptance criteria

```gherkin
Feature: The 4B tier is resolver-gated, never a global default

  Scenario: A capable device receives the 4B tier through the resolver
    Given a device tier the resolver classes as capable of the 4B variant
    When the brain model is resolved
    Then the 4B chat variant is served on that device
    And it stays within the latency and memory envelope

  Scenario: The default tier remains the 1.7B variant
    Given a device that the resolver does not class as 4B-capable
    When the brain model is resolved
    Then the 1.7B chat variant is served
    And no device is forced onto the larger variant

  Scenario: A tier misses its envelope (failure)
    Given a device tier on which the 4B variant exceeds the latency or memory requirement
    When admission is considered
    Then the tier is not admitted
    And the shortfall is reported rather than shipped with degraded behaviour
```

## Related
- FR: FR-CNR-016 (1.7B default), FR-CNR-021 (gates), FR-CNR-022 (catalog + versioning), FR-CNR-024 (reporting), FR-CNR-025 (DV on the reference device)
- NFR: NFR-CNR-002 (latency envelope), NFR-CNR-003 (memory/jetsam)
