# T-190 — P2: the 4B tier candidate and its admission verdict

## Metadata
- **Group:** [TG-39 — P2 Polish and Feasibility Honesty](index.md)
- **Component:** Tier candidate (design-l1 sections 11.6 and 20)
- **Agent:** dev
- **Effort:** L (about 2.5 days, mostly box time)
- **Risk:** MEDIUM
- **Depends on**: T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-187 ([T-187](../TG-38-release-gate-acceptance-and-device-validation/T-187-dv-protocol-and-record.md))
- **Blocks:** T-192 ([T-192](T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-028](../../../define-requirements/FR/FR-CNR-028-p2-4b-tier-per-device-resolver.md), [NFR-CNR-002](../../../define-requirements/NFR/NFR-CNR-002-listening-turn-latency-envelope.md), [NFR-CNR-003](../../../define-requirements/NFR/NFR-CNR-003-memory-and-jetsam-device-tiers.md)

## Description
Produce the 4B chat variant the same way as the 1.7B candidate (same corpus and recipe, 4B base) and measure its admission on the reference tier: memory behaviour and the listening-turn latency envelope decide whether any tier may select it, and the reference 6 GB tier's expected verdict (not admissible) is either confirmed or overturned by measurement — never by preference. The candidate exists only as a gated, resolver-reachable, non-default entry.

## Acceptance criteria

```gherkin
Feature: A 4B candidate behind tier discipline

  Scenario: The candidate is built like its predecessor
    Given the same corpus, mixture and recipe as the 1.7B run
    When the 4B variant is trained and exported
    Then it carries its own artifact identity and a new catalog entry with real hash, size and tier fields
    And it is never the default on the reference tier

  Scenario: Admission is measured on the tier
    Given the 4B candidate running on the reference tier
    When memory behaviour and the listening-turn latency envelope are measured
    Then the measurements are recorded with the tier named and the method stated (the same method as the 1.7B measurements)
    And the verdict states whether the tier can hold it beside the rest of the app

  Scenario: Selection is resolver-only
    Given a tier that can hold the candidate
    When it is selected
    Then the selection happens through the per-device resolver, one resident model, and the app serves it through the unchanged seams

  Scenario: The verdict is honest either way
    Given the measured admission outcome on the reference tier
    When the notes are written
    Then the verdict is stated with its measurements (confirming the design's recorded expectation, or overturning it with evidence)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Tier admission failure behaviour

  Scenario: The tier cannot hold it
    Given measurements showing eviction or reload pressure (a jetsam risk) on the reference tier
    When the admission decision is made
    Then the candidate is not admitted on that tier, the measurements are recorded, and the 1.7B default stands

  Scenario: Two models resident
    Given a configuration where the 4B candidate loads beside another model
    When residency is measured
    Then it is reported as a defect; the entry is not admitted until exactly one model is resident

  Scenario: A candidate without its gates
    Given a 4B candidate with no full-harness report over its own artifact identity
    When the entry is created
    Then it is not offered for selection (a tier candidate is still a gated candidate)
```

## Inputs and expected result

**Input:** the v17 corpus, recipe and harness (T-179, T-182); the catalog entry pattern and resolver discipline (T-184); the reference-tier measurement method used for the 1.7B candidate; the design's recorded expectation for the reference tier (section 20).

**Output:** the 4B candidate artifact, its gated non-default catalog entry, the tier admission measurements (memory and latency) and the verdict notes.

**Declared files:** `specs/CNR-p2-4b-tier-notes.md`

## Implementation notes
- Same data, same recipe, bigger base: the 4B variant exists to test the tier hypothesis, not to open a second tuning dimension. Any recipe or mixture deviation makes the comparison meaningless — record the exact configuration used.
- The design's recorded expectation is that the reference 6 GB tier cannot hold the 4B model beside the rest of the app; a measurement that confirms it closes the leg honestly, and a measurement that overturns it must come with the memory and latency evidence that says so.
- A tier candidate is still gated: its own harness report over its own artifact identity is part of the entry's eligibility (the same rule the 1.7B entry obeys).
- One resident model on every tier: the resolver keeps tiers honest — no tier gets a model it cannot hold, and no configuration double-loads.
- The training run follows the box discipline of T-183 (detached runner, recorded restarts, elapsed time).

## Definition of done
- [ ] 4B candidate trained and exported from the recorded configuration; own artifact identity
- [ ] New catalog entry with real hash, size and tier fields; non-default
- [ ] Full harness report over the candidate's own identity attached to the entry's eligibility
- [ ] Memory and latency measured on the reference tier with the method named; verdict recorded
- [ ] Resolver-only selection; single residency verified
- [ ] Notes written with measurements and the honest verdict (confirming or overturning the recorded expectation)
