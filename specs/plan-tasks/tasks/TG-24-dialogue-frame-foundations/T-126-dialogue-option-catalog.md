# T-126: Curated option catalog and bundled resource

## Metadata
- **Group:** [TG-24 — Dialogue Frame Foundations](../index.md)
- **Component:** C-MTC-04 — new file `ios/ElderlyAssistant/Services/` + `Voice/DialogueOptionCatalog.swift` plus `ios/ElderlyAssistant/Resources/` + `DialogueOptionCatalog.json`
- **Agent:** dev
- **Effort:** M (2 days)
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md), [T-132](../TG-25-answer-classification-and-merge/T-132-dialogue-candidate-builder.md), [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md)
- **Requirements:** [FR-MTC-015](../../../../define-requirements/FR/FR-MTC-015-curated-on-device-catalog.md), [FR-MTC-003](../../../../define-requirements/FR/FR-MTC-003-slot-fill-probe.md), [NFR-MTC-003](../../../../define-requirements/NFR/NFR-MTC-003-no-new-network-egress.md), [NFR-MTC-006](../../../../define-requirements/NFR/NFR-MTC-006-localisation.md)

## Description
Ship the curated on-device option catalog: a versioned JSON resource with the
bhajan group (label / canonical query / alias lists) and the group lookup by
whole-value or whole-token match with the script-split idiom. Wire the resource
into `ios/project.yml` following the existing single-file resources pattern,
then regenerate with `xcodegen generate`. Entirely local: no network, no
telemetry (NFR-MTC-003).

## Acceptance criteria

```gherkin
Feature: Curated on-device dialogue option catalog

  Scenario: The bundled catalog parses and preserves group order
    Given the bundled catalog resource version 1
    When it is loaded from the app bundle
    Then the groups parse into ordered entries with the bhajan group present
    And label keys, canonical queries and alias lists are intact

  Scenario: Lookup is whole-value or whole-token and script-exact
    Given a music query containing only a bounded alias
    When the group lookup runs
    Then the matching group is returned
    And the Devanagari near-pair is not matched across its shared script prefix

  Scenario: Malformed catalog data fails closed
    Given a catalog payload that does not parse against the version 1 shape
    When the load runs
    Then it throws the closed catalog-unavailable error
    And no partially parsed groups are returned

  Scenario: Canonical queries resolve through the catalog
    Given the bhajan group with the canonical query for its primary option
    When a free-text answer matches that option's aliases
    Then the resolved canonical query is the group's canonical query string

  Scenario: The resource ships in the app bundle
    Given a generated project from the project manifest
    When the app target's resources are enumerated
    Then the catalog resource is present exactly once
```

## Implementation notes
- Resource entry in `ios/project.yml` mirrors the existing single-file lexicon
  resource (explicit resources entry, resources build phase); run
  `xcodegen generate` after the edit. The Swift file is picked up by the
  existing source glob, no manifest change needed for it.
- Alias lists are data, extendable without code (design-l2 §6 gap 3); ship the
  v1 schema plus the curated bhajan group.
- Matching uses the script-split/whole-token idiom shared with the keyword rule
  (design-l2 §11); the "गीता" vs "गीत" pair is a pinned test (Swift substring
  grapheme lesson: cluster-aware, never naive prefix matching).
- Load failure is a first-class path: the caller (T-134) opens the any-option
  free-text probe line; this task only defines the error.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueOptionCatalogTests`)
- [ ] `ios/project.yml` resource entry added and `xcodegen generate` re-run; bundle-presence test green
- [ ] No network client, URL session or telemetry code in the new files (NFR-MTC-003)
- [ ] Focused suite green: `DialogueOptionCatalogTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
