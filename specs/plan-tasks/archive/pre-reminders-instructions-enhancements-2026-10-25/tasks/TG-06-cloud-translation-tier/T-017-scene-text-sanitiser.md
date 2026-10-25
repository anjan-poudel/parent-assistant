# T-017: `SceneTextSanitiser`

## Metadata
- **Group:** [TG-06 — Consent-Gated Cloud Translation Tier](index.md)
- **Component:** C07 — `SceneTextSanitiser`
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-004](../TG-01-foundations/T-004-input-sanitiser-detect-only-seam.md)
- **Blocks:** T-018, T-019, T-029
- **Requirements:** FR-LCT-014, FR-LCT-016, NFR-LCT-009 · **AM-3** · **CL-6**

## Description

Recognized scene text is attacker-influenceable input that will be handed to a language model: anyone
can print a sign whose text is shaped like a directive. Sanitise it at the boundary and return an
explicit **verdict** — sendable, truncated or quarantined — never a bare string, so the caller cannot
accidentally treat a quarantined string as trusted. Quarantined text is never sent and never spoken; it
is shown as-is with a neutral note.

Source: `Services/LiveTranslate/` `SceneTextSanitiser.swift` using the detect-only seam from T-004
under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Scene text sanitisation verdicts

  Scenario: Ordinary scene text is verdict-sendable
    Given ordinary sign text, including Devanagari text and punctuation
    When it is sanitised for egress
    Then the verdict is sendable with the same text
    And nothing is marked quarantined or truncated

  Scenario: Marker-shaped text is stripped before it can reach a prompt
    Given recognized text carrying a marker shape from the project's configured marker table
    When it is sanitised for egress
    Then the marker shape is removed from the outgoing text
    And the remaining text is what would be sent (NFR-LCT-009)

  Scenario: Text that still carries a marker shape is quarantined, not sent
    Given text that still carries a marker shape after sanitisation
    When the verdict is read
    Then it is quarantined with a reason
    And the payload is not sent and the string is not spoken
    And the region shows its original text with a neutral note rather than a blank bubble (FR-LCT-014)

  Scenario: Quarantine is decided by the shipped table, not a local copy
    Given the detect-only seam from the shared sanitiser (T-004)
    When the scene-text path evaluates a marker-shaped string
    Then it uses the shared verdict
    And no second marker list exists in the feature's sources (CL-6, AM-3)

  Scenario: Over-long text is truncated, and truncation is not quarantine
    Given recognized text longer than the configured scene-text bound
    When it is sanitised for egress
    Then the verdict is truncated with the bound applied by grapheme cluster, so no Devanagari conjunct is split
    And the truncated text is still sent, because truncation is not a quarantine (FR-LCT-016)

  Scenario: The verdict is a total function with no error path
    Given any input string, including an empty one
    When it is sanitised for egress
    Then exactly one verdict is returned
    And no error is thrown, because quarantine is a verdict, not a failure (failure table row 21)

  Scenario: Quarantine is recorded without the offending text
    Given a quarantined string
    When the event is emitted
    Then the quarantine is recorded with a count only
    And no part of the offending text appears in the record
```

## Implementation notes

- Verdict shape per C07: `.sendable(text)` / `.truncated(text)` / `.quarantined(reason)`. The reason
  is a closed-vocabulary token that maps to `TranslationUnavailableReason.textQuarantined`.
- Order is **strip, then detect, then quarantine**: the shared detect-only seam (T-004) reports a
  residual marker shape after stripping, and that residual is the quarantine trigger.
- Bounds come from `LiveTranslateConfig` (T-001): `sceneTextMaxLength` (120) per string, and the batch
  bounds `cloudBatchMaxStrings` (12) / `cloudBatchMaxCharacters` (1200) are enforced by the tier when
  it assembles a request (T-019). When a scene exceeds the batch bounds, the request set is **split
  into sequential batches** rather than silently dropping strings, and the pending state covers the
  whole set until each batch terminates.
- Truncation uses `String.prefix(_:)`, which counts extended grapheme clusters, so it cannot split a
  Devanagari cluster or conjunct. Pin that with a test — it is the same class of regression the
  project already pinned for Nepali substring handling.
- Describe marker shapes by family in comments, never by quoting a literal payload. The table lives in
  the shared sanitiser and is referenced, not restated.
- Quarantined text is still displayed to the elder (their own camera saw it); it is simply never sent
  off-device and never spoken.
- Emit `text_quarantined` with `count` only (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the shared detect-only seam is the quarantine authority and no local list exists
- [ ] A test asserts quarantined text reaches neither the request builder nor the speaker
- [ ] A test asserts truncation happens on grapheme clusters and does not mark the text quarantined
- [ ] A test asserts ordinary English and Devanagari text passes through byte-identical
- [ ] No quarantined text in any log or event, asserted by test
- [ ] `ios/build.sh` passes
