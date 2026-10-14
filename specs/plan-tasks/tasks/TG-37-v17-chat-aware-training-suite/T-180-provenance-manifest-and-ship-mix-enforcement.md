# T-180 — Provenance manifest and ship-mix enforcement

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Provenance manifest (design-l1 section 11.5)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** CRITICAL
- **Depends on**: T-179 ([T-179](T-179-four-layer-chat-corpus-pipeline.md))
- **Blocks:** T-182 ([T-182](T-182-chat-variant-config-and-full-harness.md)), T-183 ([T-183](T-183-v17-chat-aware-qlora-run.md))
- **Requirements:** [FR-CNR-018](../../../define-requirements/FR/FR-CNR-018-ship-mix-provenance-manifest.md), [NFR-CNR-011](../../../define-requirements/NFR/NFR-CNR-011-compliance-and-release-gates.md)

## Description
Make provenance a machine-checked property of the corpus: every source listed with its license, layer, ship-or-dev classification, counts used and derived artifacts, with the held-out set excluded — and a hard assertion that the SHIP mix contains only CC-BY, Apache, MIT, synthetic and own data, never a CC BY-NC research layer and never a research-gated transcript. A shipped artifact contaminated by a non-commercial source is a compliance event, so the check is code, not a note.

## Acceptance criteria

```gherkin
Feature: Ship-mix provenance is enforced, not asserted by hand

  Scenario: The manifest covers every source
    Given a completed corpus build
    When the manifest is emitted
    Then every source appears with license, layer, ship/dev classification, counts used and the derived artifacts it fed
    And the held-out chat set is recorded as excluded

  Scenario: The ship mix contains only admissible licenses
    Given the ship-mix sources (CC-BY, Apache, MIT, synthetic, own data)
    When the ship-mix check runs
    Then every ship-mix source passes and the assertion records the license registry it used

  Scenario: The manifest travels with the run
    Given a completed run
    When its evidence is assembled
    Then the manifest sits beside the gate results and its content hash is recorded with them

  Scenario: Tooling inputs are classified too
    Given the teacher tooling and other non-training inputs
    When the manifest is emitted
    Then they appear with their classification (they are not silently omitted)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Provenance failure behaviour

  Scenario: A research-gated source reaches the ship mix
    Given a CC BY-NC source (or a research-gated transcript) present in the ship mix
    When the check runs
    Then it fails and names the source and its license
    And the artifact is rejected — it does not enter the catalog, and the run cannot claim ship-mix eligibility

  Scenario: An unclassified source
    Given a source with no license classification
    When the manifest is emitted
    Then the build fails rather than defaulting the source into either mix
    And the missing classification is reported

  Scenario: A transcript source without consent
    Given a real-transcript source present without its consent record
    When the manifest is emitted
    Then it is refused from both mixes and the reason is recorded (no silent harvest, even into dev)
```

## Inputs and expected result

**Input:** the corpus builder and its per-layer source accounting (T-179); the license classification of every source (the tooling's existing license registry, extended where the new sources demand it); the held-out set identity (T-178).

**Output:** the manifest emission in the corpus builder, the ship-mix assertion with its license registry, and tests covering admissible ship mix, a contaminated mix, an unclassified source and an unconsented transcript.

**Declared files:** `tools/train-intent/src/build_chat_corpus.py`, `tools/train-intent/tests/test_provenance_manifest.py`

## Implementation notes
- The manifest is the compliance artifact for the feature: it is reviewed in the advisory security pass at final-sign-off and it is the evidence that no non-commercial research layer reached a shipped model.
- Known non-admissible ship sources (to be listed explicitly in the registry): the CC BY-NC research layers — IndicDialogue, DailyDialog, PersonaChat, EmpatheticDialogues — and the research-gated Nepali call-center transcripts. Their legitimate home is the dev mix; the check's job is to make that placement verifiable rather than remembered.
- Own data includes consented real transcripts once the P2 leg exists (T-191); until then, a transcript source without a consent record has no legal mix and is refused.
- The hash recorded with the gate results is what binds "these gates were run on the artifact built from this manifest" — keep it stable across re-emissions of the same corpus.
- The manifest is JSON beside the run artifacts (`build/<run-id>/provenance-manifest.json` per the design) and is written by the same builder that assembles the corpus, so it can never describe a build it did not perform.
- No user content in the manifest: counts, licenses, identifiers of sources and artifacts only.

## Definition of done
- [ ] Manifest emitted for every build, listing every source with license, layer, classification, counts and derived artifacts
- [ ] Ship-mix assertion runs in the build and fails on any non-admissible license or unconsented transcript
- [ ] Unclassified source fails the build (no default classification)
- [ ] Held-out chat set recorded as excluded
- [ ] Tooling inputs classified
- [ ] Content hash recorded for pairing with gate results; no user content in the artifact
- [ ] Tests cover admissible, contaminated, unclassified and unconsented cases
