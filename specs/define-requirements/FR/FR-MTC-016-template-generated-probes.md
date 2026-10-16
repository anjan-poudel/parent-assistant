# FR-MTC-016: Template-generated probes, localized ne/en — never model-generated

## Metadata
- **Area:** Probe Generation / Localisation
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 2 ("Template-generated probes only (localized ne/en). Never model-generated. The model never writes probe text.") and "Probe Kinds & Answer-Capture Contract" ("both are template-driven"); feasibility study §5.2 ("**Probes must therefore be template-generated, never model-generated. The model's job in multi-turn is narrow: classify the *answer* utterance against the active frame*") and §6.2; project constitution Standards (localisation; voice-first accessibility).

## Description
Every spoken element of the dialogue mechanics **must** be a static, localized template — never model-generated:

- **Covered text**: the probe questions (both kinds), the option lists and their spoken forms, the default offer, the honest not-understood line, the cancel acknowledgement, the escape acknowledgement, and the index words — all static strings with ne/en entries (FR-MTC-015 supplies option *data*; this requirement binds its spoken rendering).
- **Never model-generated**: no probe line may be produced by the brain or any generative model, in any phase. The model's only multi-turn job is classifying the answer against the active frame (Phase 2, FR-MTC-018) — never writing what the user hears.
- **Deterministic with a degraded or absent brain**: with the brain absent, downloading, or pressure-evicted, the spoken probe text is byte-identical to the template (NFR-MTC-005); no dialogue element degrades to silence or improvisation.
- **Elderly-appropriate and short**: probes are short spoken lines; option counts stay within the bounds (≤3–4 slot-fill, ≤2–3 did-you-mean) so the spoken list is memorable (NFR-MTC-009).
- **Localized at the string catalog**: new keys exist in both ne and en (NFR-MTC-006), following the project's externalised-string discipline (`spotify.*`-style key families).

## Acceptance criteria

```gherkin
Feature: Template-generated probes

  Scenario: The probe text is byte-identical to the template regardless of brain state
    Given the probe is triggered while the brain is absent (or evicted)
    When the probe is spoken
    Then the spoken text equals the localized template string for that probe
    And no model call produced any part of it

  Scenario: Each language hears its own templates
    Given the active language is Nepali
    When any probe, honest line, default offer or acknowledgement is spoken
    Then it is the Nepali template
    And with English active, it is the English template

  Scenario: No generative call is made to produce dialogue text
    Given any probe or dialogue line is about to be spoken
    When the turn is traced
    Then no interpreter/model invocation exists on the path that produces that text
```

## Related
- FR: FR-MTC-003/FR-MTC-004 (the probes), FR-MTC-008 (escape line), FR-MTC-010 (cancel line), FR-MTC-018 (the model's Phase 2 role: answer classification only)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-005 (degraded-brain determinism), NFR-MTC-009 (voice-only accessibility)
