# T-072: Canonicalizer Rules Schema & Composition Design

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The `DialectCanonicalizer` contract, the variant-table schema and its `issues()` validator, the ordered rule stages, the provenance/offset model, and the composition seams with `InputSanitiser`, `NepaliTextNormalizer`, `IntentCommandCache` and the picker brain
- **Agent:** architect
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-070](T-070-variant-coverage-measurement.md), [T-062](../../TG-11-linguistic-robustness/T-062-dialect-inventory-review.md)
- **Blocks:** [T-074](T-074-variant-table-authoring.md), [T-075](T-075-canonicalizer-implementation.md)
- **Requirements:** FR-005, FR-007, FR-008, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §4.2–§4.7; the shipped resource pattern at `DialectBiasComposer.swift:113-170`

## Description

The design doc fixes the shape; this task fixes the details an implementer needs and settles the four questions the design leaves open. It is a **design task**: it produces a specification and the table schema's skeleton, not an implementation.

**1. The rule schema, finalised and validated.** The table file follows the shipped `DialectLexicon` / `DialectCentroidTable` shape — `formatVersion`, a `generation` block (`status`, `path`, `date`), the data, and an `issues()` structural validator — because that pattern already exists, is already bundled-resource-tested, and is explicitly documented as *"Content, not code: the … pipeline replaces the JSON without an app change"* (`DialectBiasComposer.swift:104-105`). This task specifies the concrete `Issue` cases (design §4.3) and, critically, the **fail-closed** behaviour: a table with any issue canonicalizes **nothing** and the transcript passes through byte-identical (`DialectBiasComposer.swift:111-112`: *"a structurally corrupt lexicon must not bias at all"*).

**2. The rule-authoring admission rule, made mechanical.** Design §4.3.1 requires every entry to carry either corpus frequency evidence (`source: "corpus"`, `occurrences ≥ 1`) or an authored fixture with a cited example set (`fixtureExamples ≥ 2`). This task turns that into the validator's checks, so an unsourced entry **cannot be written** rather than being caught in review. T-070 supplies the numbers; the schema is what makes them mandatory.

**3. Offset semantics, finalised.** The design specifies UTF-16-indexed half-open ranges to match the encoder's span contract (`annotation_rules.yaml:96-104`). This task specifies:
   - the exact behaviour when a rule fires over a region another rule already rewrote (stage composition, design §4.2's ordering);
   - the translation of `originalRange`/`canonicalRange` forward through later stages;
   - the widening rule and the **abstain rule** for required spans — when a `contact` span for `call`/`send_message` or a `time` span for `set_reminder` maps with widening, the interpreter abstains rather than resolves (design §4.5). This is the "calls the wrong person" hazard that `NepaliTextNormalizer` already refuses transliteration to avoid (`NepaliTextNormalizer.swift:17-23`), and it needs a precise rule, not a principle.

**4. The four open questions from design §15.** Each is decided here, with the reasoning recorded:
   - **Q4 — what happens when the enrolment dialect label is wrong.** Design §4.3 guarantees a wrong label can only *fail to fire* a rule, never fire another region's. Whether the failure is silent or surfaced (via the provenance's low-confidence marking) is a UX decision this task makes.
   - **Q3 (part) — the sub-band's home.** Whether the cascade's `subBandConfidence` escalations should instead enter the existing confirmation flow is decided by T-071's agreement-rate measurement, but the *schema* for expressing either policy is this task's.
   - **The clipped-form stage's scope.** Design §4.4 lists O-7 (`Kind.clippedForm`) last. `annotation_rules.yaml:216` already carries an `elder_fragmented` register, and TG-11's `T-062:24` explicitly asks whether its proposed `clipped` style duplicates it. This task decides whether O-7 is authored at all in v1, given that TG-11 may already model it on the data side.
   - **The dialect-selection fallback's precision.** Design §4.3 defines three selection cases. This task specifies the fourth: what the canonicalizer does when the centroid table is `SEED-CENTROIDS` with **empty `promptTokenIds`** (its shipped state) so that the acoustic label is effectively absent and only the enrolment preference is available.

**What this task must not do.** It does not author table content (T-074), implement the engine (T-075), or touch `IntentRouter`, `CommandRouter`, the keyword net or the cache. It does not add a learned component: design D-2 fixes the layer as data-driven and auditable, and any proposal to relax that is a different design, not a detail of this one.

## Acceptance criteria

```gherkin
Feature: The canonicalizer's rules schema and composition seams are specified

  Scenario: The table schema is specified with its fail-closed validator
    Given the shipped DialectLexicon / DialectCentroidTable resource pattern
    And the design's required entry fields and Issue cases
    When the schema is written
    Then it specifies formatVersion, the generation block, the per-entry fields, and every Issue case
    And it states that a table with any Issue canonicalizes nothing, leaving the transcript byte-identical
    And a skeleton table file is committed that fails validation until T-070's evidence is filled in

  Scenario: An unsourced rule cannot be written
    Given the admission rule: every entry is sourced from corpus frequency evidence or a cited authored example set
    When an entry carries neither, or carries occurrences < 1 with source "corpus", or fewer than 2 fixture examples otherwise
    Then the validator reports it as an Issue and the table is refused
    And no path exists by which an unsourced entry is applied

  Scenario: Offset semantics and the abstain rule are specified exactly
    Given the encoder's half-open UTF-16 span contract
    And the requirement that a decoded span maps back to the original transcript
    When a rule fires over a region another rule already rewrote
    Then the schema specifies how originalRange and canonicalRange are translated through later stages
    And when a required span (contact for call/send_message, time for set_reminder) maps with widening, the specified behaviour is abstention, not resolution
    And the document states which rule kinds can change length and what the abstain cost is

  Scenario: The dialect-section fallback is specified for the shipped seed state
    Given DialectCentroids.json is SEED-CENTROIDS with empty promptTokenIds and confidenceGate 0.6
    And DialectLabel is eastern | doteli | default
    When the dialect for a turn is unknown, unavailable, or low-confidence
    Then the specification states which rule sets apply
    And it states that a rule from another region is never substituted
    And it states what provenance marking accompanies a low-confidence selection

  Scenario: The composition seams are fixed and the safety boundary is restated
    Given InputSanitiser.sanitise(.quarantine) runs first, and the keyword net reads the original transcript
    When the composition is specified
    Then the order is declared: sanitiser, then canonicalizer, then tokenizer
    And the cache key is unchanged and still uses NepaliTextNormalizer
    And the picker brain receives the original sanitised transcript, not the canonical one
    And no specified seam places the canonicalizer on the keyword net's path
```

## Implementation notes

- Read first: design §4.2–§4.7; `DialectBiasComposer.swift:101-170` (the lexicon's `Entry`, `Generation`, `bundled(in:)`, `entry(for:)`, `issues()`); `DialectIdentifier.swift:43-53` (`DialectLabel`), `:189-239` (`DialectCentroidTable.Issue`); `NepaliTextNormalizer.swift` in full; `InputSanitiser.swift:22`, `:42-44`; `annotation_rules.yaml:96-104` (offset contract), `:216` (`elder_fragmented`).
- The validator's most valuable checks are the two that are not about structure: `variantEqualsCanonical` (a no-op rule would inflate T-070's coverage figure) and `negationMarkerTouched` (design §4.7 — the machine-checkable form of the safety boundary). Both refuse the table, not the entry.
- Specify the abstain rule as a **policy with a cost**, and record that cost: substitutions are preferred in authoring because a same-length substitution never triggers abstention. T-070's evidence must record how often a length-changing rule fires on rows carrying a `contact`/`time` span, so the abstain cost is visible before authoring rather than after.
- Do not merge the canonicalizer into `NepaliTextNormalizer`. The two have different contracts (lossy key vs faithful model input); design §4.6 records the reasoning and the shared concepts (NFC, digit folding) without a shared-code requirement.
- Keep the design honest about Q4: a wrong enrolment dialect that silently fails to fire a rule is a *quality* outcome, not a safety one. Say so, and specify the provenance marking rather than inventing a safety control.
- This is a design task — no production code. A skeleton table file plus the specification is the deliverable.

## Definition of done
- [ ] The table schema specified: `formatVersion`, `generation`, entry fields, and every `Issue` case, with fail-closed semantics stated
- [ ] The admission rule expressed as validator checks, so an unsourced entry cannot be written
- [ ] Offset semantics specified end to end: stage ordering, forward translation of ranges, widening, and the required-span abstain rule with its cost
- [ ] The dialect-selection fallback specified for the shipped SEED state, including the "never substitute another region's table" rule
- [ ] Composition seams fixed: sanitiser → canonicalizer → tokenizer; cache key unchanged; picker brain receives the original sanitised transcript
- [ ] The four open questions of design §15 addressed, each with its decision and reasoning recorded
- [ ] A skeleton table file committed that fails validation until T-070's evidence fills it
- [ ] No production code, no `IntentRouter`/`CommandRouter` change, no learned component proposed
