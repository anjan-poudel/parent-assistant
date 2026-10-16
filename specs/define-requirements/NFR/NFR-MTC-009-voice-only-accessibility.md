# NFR-MTC-009: Voice-only accessibility of probes and answer capture

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Project constitution Standards ("Voice-first UI — every function accessible by voice command without requiring any touch"; TTS in the configured language) and Target Users (60+, cognitive/motor challenges); feature constitution "Primary user: the elderly parent (60+, Nepali-first, voice-only)"; feasibility study §6.2 ("the user picks by voice") and §6.5; FR-MTC-005's single-word requirement.

## Description
The entire dialogue — hearing the probe and answering it — **must** be completable by voice alone, with no touch interaction of any kind:

- **Answerable by every capture form, hands-free**: option name, index word, repetition or free-form; single-word answers must work (e.g. "दुर्गा" alone; "पहिलो" alone); the default ("just play anything") one phrase.
- **Spoken in the user's configured language** at the existing elder-facing TTS register; probe lines are short and the option count bounded (≤3–4 slot-fill, ≤2–3 did-you-mean; FR-MTC-003/004) so the spoken list stays memorable for elderly users.
- **No new gesture or tap requirement**: the probe appears in the existing spoken/visible surfaces (chat history like any reply); nothing in the flow requires the user to touch the screen (parity with the product's voice-first standard).
- **Verifiable end-to-end**: the bhajan dialogue (trigger → probe → answer → playback) can be completed in a hands-free test with no UI interaction.

## Acceptance criteria

```gherkin
Feature: Voice-only dialogue accessibility

  Scenario: The whole dialogue completes hands-free
    Given the user never touches the device
    When the bhajan flow runs: "भजन बजाऊ" → probe → "दुर्गा"
    Then the dialogue completes and playback starts
    And no touch interaction was required at any point

  Scenario: Single-word answers work
    Given the probe is outstanding
    When the user answers with one word ("दुर्गा", "पहिलो", or the default phrase)
    Then the answer is captured and the frame resolves

  Scenario: Option lists stay within the elderly-friendly bounds
    Given any probe of either kind
    When the spoken option list is inspected
    Then slot-fill probes name at most 3–4 options plus the default
    And did-you-mean probes name at most 2–3 candidates
```

## Related
- FR: FR-MTC-005 (capture forms), FR-MTC-003/FR-MTC-004 (probe bounds), FR-MTC-007 (no probe fatigue)
- NFR: NFR-MTC-006 (localisation of the spoken lines)
