# FR-MTC-004: `.candidateChoice` (didYouMean) probe — honest not-understood line plus narrowing candidates

## Metadata
- **Area:** Probes / Did-You-Mean
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds table (`.candidateChoice`: "the utterance was not understood ... an honest 'did not understand' line **plus** a narrowing probe with ≤2–3 candidate options the user picks by voice") and "The owner requirement (2026-10-10): two probe kinds ... this is a first-class requirement, not an optional extra"; feasibility study §6.2 ("No-understanding probe (owner requirement, 2026-10-10)") — candidates from the rephrase band (confidence 0.4–0.7), relaxed keyword near-matches (`KeywordIntentRule.match`, called at `CommandRouter.swift:1207-1234`), and the active frame; upgrades the honest-but-dead-end `routeKeywordRemainder` lines (`CommandRouter.swift:1968-2030`).

## Description
When Pip does not understand an utterance, it **must** (1) honestly say that it did not understand, and (2) offer a narrowing probe with candidate interpretations the user picks by voice — instead of today's honest-but-dead-end re-prompt. Binding properties:

- **Both parts are required**: honesty first ("I didn't understand"), then the narrowing candidates. Neither alone satisfies this requirement.
- **`probeKind` is `.candidateChoice`** on the frame (FR-MTC-001).
- **≤2–3 candidate options**, spoken by name; the user picks by option name, index word, repetition, or free-form correction (FR-MTC-005).
- **Candidate sources** (deterministic first): the rephrase band's low-confidence hypothesis (confidence < 0.7 tier-`.free`; `CommandRouter.swift:1493-1519`, music is tier `.free` per `ConfirmationTier`), relaxed keyword near-matches, and the active dialogue frame when one exists.
- **Never fabricate candidates**: when the pipeline has no candidate to offer, the honest not-understood line stands alone (today's behaviour, no invented options).
- **Same constraints as `.slotFill`**: template text ne/en (never model-generated), 45 s deadline, free text always accepted, the "no — let me say it again" escape (FR-MTC-008), the same pre-ladder interception (FR-MTC-009) and frame-merge execution path (FR-MTC-006).
- This upgrades the `routeKeywordRemainder` honest-failure lines (`CommandRouter.swift:1968-2030`) into a narrowing dialogue; the honest no-brain states (download/setup) keep their truthful lines (NFR-MTC-012).

## Acceptance criteria

```gherkin
Feature: The did-you-mean candidate probe

  Scenario: A not-understood utterance hears honesty plus narrowing candidates
    Given the user says something the pipeline cannot resolve
    When the fallback path is reached
    Then Pip first says it did not understand, in the active language
    And Pip offers at most 2–3 candidate interpretations by voice
    And the user can pick one by voice

  Scenario: Picking a candidate executes the interpretation
    Given the did-you-mean probe is outstanding with candidates
    When the user picks a candidate by name (or index word)
    Then the chosen interpretation is executed exactly as if it had been understood as that command

  Scenario: No candidates available — honest line, nothing invented
    Given no deterministic candidate interpretation exists for the utterance
    When the fallback path is reached
    Then the honest not-understood line is spoken
    And no candidate option is fabricated and no frame is opened
```

## Related
- FR: FR-MTC-008 (the say-it-again escape), FR-MTC-009 (interception), FR-MTC-005 (picking), FR-MTC-016 (template text)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-012 (no regression for the no-brain honest lines)
