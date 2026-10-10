# FR-MTC-003: `.slotFill` probe — a short kind-of-request question with options and a default

## Metadata
- **Area:** Probes / Slot-Fill
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds table (`.slotFill`: "a short template probe (e.g. 'कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्'), ≤3–4 named options, one default always offered ('just play anything')") and the owner's example ("'play bhajans' makes Pip ask 'WHAT KIND OF BHAJANS? shiva, durga, bishnu, devi...'"); feasibility study §6.2 (the probe text) and §6.5 (spoken like any reply; appears in chat history; no new UI). OD-M1 (probe policy — OPEN) and OD-M2 (option source — OPEN) affect the exact wording and option sourcing; the requirements bind the shape below.

## Description
For a degenerate music query (FR-MTC-002), the system **must** speak a short, template-generated probe asking what kind of music the user wants, and enter the answer-capture window. Binding properties:

- **Template text, ne/en** — static localized strings, never model-generated (FR-MTC-016). The owner's example probe: 'कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्' / "What kind of bhajan? shiva, durga, bishnu, devi … or say it yourself."
- **≤3–4 named options**, spoken by name, sourced from the curated on-device catalog (FR-MTC-015).
- **One default option is always offered** on the probe ("just play anything" — the OD-M1 default-play wording, e.g. 'जे पनि बजाऊ'). The default is a valid answer that executes the pending command with the default query (FR-MTC-007).
- **Free text always accepted** — the user may answer with anything, not only the named options (FR-MTC-005).
- **`probeKind` is `.slotFill`** on the frame (FR-MTC-001), and the frame records the missing slot the probe asked for.
- Spoken through the existing reply lane (`speak` → `ReplySpeakLane`), appears in the chat history like any reply — **no new UI** (study §6.5).
- The probe does not execute anything; it only asks and opens the 45 s window (FR-MTC-014).

## Acceptance criteria

```gherkin
Feature: The slot-fill probe

  Scenario: The owner's example — "play bhajans" hears the kind-of-bhajan probe
    Given the user says "play bhajans"
    And the resolved music query is degenerate
    When the probe is triggered
    Then Pip asks what kind of bhajans, naming the catalog options and inviting a free-spoken answer
    And a default option ("just play anything") is offered
    And the probe appears in the chat history like any reply

  Scenario: The probe is bounded — at most four named options plus the default
    Given any slot-fill probe is constructed
    When its spoken option list is inspected
    Then at most 3–4 named options are named
    And exactly one default option is always offered
    And the free-spoken path is always offered

  Scenario: The English utterance receives the English probe
    Given the active language is English
    When the slot-fill probe is spoken
    Then every part of the probe (question, options, default, free-text invitation) is the English template
```

## Related
- FR: FR-MTC-002 (the trigger), FR-MTC-015 (option source), FR-MTC-005 (answer capture), FR-MTC-016 (template generation), FR-MTC-007 (default execution)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-009 (voice-only accessibility)
