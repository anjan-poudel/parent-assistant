# T-191 — P2: consent-based real transcripts for future mixes

## Metadata
- **Group:** [TG-39 — P2 Polish and Feasibility Honesty](index.md)
- **Component:** Transcript intake (design-l1 section 11.7)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: T-180 ([T-180](../TG-37-v17-chat-aware-training-suite/T-180-provenance-manifest-and-ship-mix-enforcement.md)), T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-187 ([T-187](../TG-38-release-gate-acceptance-and-device-validation/T-187-dv-protocol-and-record.md))
- **Blocks:** T-192 ([T-192](T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-029](../../../define-requirements/FR/FR-CNR-029-p2-consent-based-real-transcripts.md), [FR-CNR-018](../../../define-requirements/FR/FR-CNR-018-ship-mix-provenance-manifest.md)

## Description
Build the intake regime for real conversational transcripts — UAT and test-device sessions first — around explicit, informed, revocable consent: a consent record per source, withdrawal that removes the source from future mixes, classification as own data in the provenance manifest, and a hard refusal of any transcript that has no consent record. There is no path by which a recording enters a mix silently, and a transcript that lands in a mix is gated like any other candidate.

## Acceptance criteria

```gherkin
Feature: Transcripts enter only through recorded consent

  Scenario: Consent precedes collection
    Given a session whose transcript might be collected
    When intake runs
    Then the source's consent record exists before any turn is stored (informed and revocable, recorded with what was agreed)
    And a source without a record is refused outright

  Scenario: Withdrawal removes the source from future mixes
    Given a consented source included in a mix
    When the source withdraws
    Then subsequent mixes exclude it (recorded with the withdrawal), and the record shows what the withdrawal removed

  Scenario: The manifest classifies the source honestly
    Given consented transcript sources
    When the manifest is emitted
    Then they appear as own data with their consent record referenced
    And a transcript without a consent record fails the manifest emission (never defaulted into any mix)

  Scenario: A mix built from transcripts is still gated
    Given a candidate trained with transcript data
    When it is prepared for shipment
    Then it goes through the full harness like any candidate and is filed as a new gated entry, never an in-place mutation
```

## Acceptance criteria — failure paths

```gherkin
Feature: Transcript intake failure behaviour

  Scenario: A silent harvest attempt
    Given any code path that stores a transcript without consulting the consent record
    When the intake tests run
    Then the path is refused and reported (no silent harvest, not even into a dev mix)

  Scenario: A withdrawal after training
    Given a source withdrawn after a mix was built
    When future mixes are assembled
    Then the source is excluded and the exclusion is recorded; the released artifact's provenance is not rewritten retroactively (the record states what it was built from)

  Scenario: Consent narrower than the use
    Given a consent record that does not cover the intended use (for example a narrower purpose or scope)
    When intake runs
    Then the use is refused and the mismatch is recorded
```

## Inputs and expected result

**Input:** the manifest and its ship/dev enforcement (T-180) as the classification target; the candidate/entry discipline (T-184); the design's regime (explicit informed revocable consent, UAT sessions first, withdrawal removes future mixes, own-data classification, no silent harvest).

**Output:** the intake tooling with its per-source consent records and refusal paths, its manifest integration, and the notes recording the regime and any collected sources.

**Declared files:** `tools/train-intent/src/transcript_intake.py`, `specs/CNR-p2-transcripts-notes.md`

## Implementation notes
- Consent shape: per source, recorded (who consented, when, to what use, how it can be withdrawn), stored beside the intake tooling's registry — the record and the refusal are the same mechanism, so a missing record cannot be worked around.
- Withdrawal semantics: future mixtures only. The provenance manifest is a build-time fact, so withdrawal removes the source going forward and the released artifacts keep their honest record of what they were built from.
- Collection convenience is not a reason: the regime applies to the researcher's own UAT sessions as much as to anyone else's device; test-device sessions are the first permitted source precisely so the regime is exercised before any broader use.
- Refusal is loud: the intake tool reports a refused source with the reason (missing record, out-of-scope consent) — never a silent skip that later reads as "no data collected".
- Nothing in this unit touches the app: the feature ships no recording or upload change (FR-CNR-015's boundary stands — the STT and collection paths are untouched).
- The notes record the regime's state at sign-off (exercised with a UAT session, or not yet used — with that stated honestly).

## Definition of done
- [ ] Per-source consent record required before any storage; sources without a record refused
- [ ] Withdrawal removes the source from future mixes and is recorded
- [ ] Manifest integration classifies consented sources as own data and fails on unconsented ones
- [ ] Any mix built with transcripts still passes the full harness and ships only as a new gated entry
- [ ] No silent-harvest path exists (tested); no app-side recording or upload change
- [ ] Notes record the regime's state honestly
