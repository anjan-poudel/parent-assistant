# NFR-CNR-001: Chat reply reproducibility — fixed seed, same input, same reply

## Metadata
- **Category:** Reliability / Determinism
- **Priority:** MUST
- **Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 2 ("Deterministic and reproducible: same transcript and state → same reply. The gibberish bug was a RANDOM seed; a fixed seed at 0.3 stays fully reproducible") and Safety & Compliance Delta 4 ("Determinism invariants preserved … the NO-GIBBERISH class stays closed"); proposal §5.1 and §7 risks; workflow `security-test` focus ("chat turns are reproducible at fixed-seed temp ~0.3").

## Description
Chat decoding **must** be reproducible at the fixed seed. Measurable properties:

- **Repeat-run identity**: for the same transcript and the same assistant state on the same device tier and build, repeated chat decodes produce **byte-identical** replies — 100% of trials (no sampling variance run to run).
- **Seed is fixed and recorded**: the chat decode uses a fixed seed (the project's `OnDeviceSampling.fixedSeed` value, 20_260_907, or a documented fixed value chosen at design time); a random or time-derived seed is a defect.
- **Guard verdicts are reproducible** over the same reply (100% identical verdicts across repeats) — FR-CNR-005's idempotence in measurable form.
- **Cross-session stability**: the same turn in a fresh session with the same state yields the same reply; reproducibility is not an artefact of an in-process cache.
- **The cloud path is deterministic in configuration**: the cloud chat request carries its fixed, recorded sampling configuration (FR-CNR-011) so a repeat request is issued under identical parameters.

## Acceptance criteria

```gherkin
Feature: Reproducible chat replies

  Scenario: Repeated local chat decodes are byte-identical
    Given a fixed transcript and assistant state
    When the same chat turn is decoded 20 times on the same device tier and build
    Then every resulting reply is byte-identical
    And no run differs from another

  Scenario: Reproducibility holds across sessions
    Given the same transcript and state in a fresh app session
    When the chat turn is decoded
    Then the reply matches the earlier session's reply

  Scenario: A non-fixed seed is introduced (failure)
    Given a chat decode configuration whose seed is random, time-derived or unrecorded
    When the configuration is inspected
    Then it is reported as a NO-GIBBERISH-class defect
    And the chat path does not ship in that state
```

## Related
- FR: FR-CNR-003 (chat sampling), FR-CNR-004 (command determinism), FR-CNR-005 (guard idempotence), FR-CNR-011 (cloud sampling config)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-011 (release gates)
