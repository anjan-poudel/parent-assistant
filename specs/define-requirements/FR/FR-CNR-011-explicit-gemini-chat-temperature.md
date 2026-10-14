# FR-CNR-011: Explicit Gemini chat temperature — a stated, reviewed value instead of a provider default

## Metadata
- **Area:** Cloud Chat Sampling Config
- **Priority:** MUST
- **Source:** Proposal §5.3 ("Gemini's `GenerationConfig` currently sends no sampling params (`GeminiClient.swift:658-680`); set an explicit temperature for chat there"); feature constitution "Persona seams and Gemini chat temperature" property 3 ("`GeminiRequest.GenerationConfig` (`GeminiClient.swift:659-661`) gains an EXPLICIT chat temperature — today it sends no sampling params, so the value is a provider default; it becomes a stated, reviewed value. (Exact value: Open Decision 5.)"); feature constitution OD-5. Surface: `Services/Gemini/GeminiClient.swift` `GenerationConfig`.

## Description
The cloud chat request **must** carry an explicit chat temperature in `GenerationConfig` — today the request sends no sampling parameters, so the effective value is a provider default nobody chose. The exact value is design-l1's to propose with a rationale (feature OD-5) and is reviewed like the on-device value (temperature ~0.3, FR-CNR-003). Binding properties:

- The explicit value is **visible in the code and in the design record** — a stated, reviewed decision, not an inherited provider default.
- The change is **chat-scoped**: other Gemini call sites (voice transcription, the translation tier, teacher tooling) keep today's behaviour; no sampling parameter is silently added to them by this feature.
- The cloud and on-device chat behaviour are described by the same style contract (FR-CNR-002), so an explicit cloud temperature is part of keeping the two paths from drifting in perceived register.

## Acceptance criteria

```gherkin
Feature: The cloud chat request carries an explicit temperature

  Scenario: A cloud chat request states its sampling value
    Given cloud chat is consented and online
    When the chat request is built
    Then its GenerationConfig carries an explicit temperature
    And the value matches the reviewed design decision

  Scenario: Other Gemini call sites are unchanged
    Given the pre-change behaviour of the transcription and translation call sites
    When the feature's change set is inspected
    Then those call sites send the same request shape as before
    And the chat temperature is not applied to them

  Scenario: The value is a provider default again (failure)
    Given a build in which the chat request omits its sampling value
    When the request is inspected
    Then the omission is reported as a regression against this requirement
    And the documented value is restored
```

## Related
- FR: FR-CNR-002 (persona contract), FR-CNR-008 (routing), FR-CNR-003 (the on-device counterpart value)
- NFR: NFR-CNR-008 (gate thresholds)
