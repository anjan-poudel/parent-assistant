# FR-PI-008: Personalized wake acknowledgment

## Metadata
- **Area:** Wake Acknowledgment / Address-as
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (wake acknowledgment; `VoicePipeline.handleWakeDetected`) and "Integration Surfaces"; workflow scope comment ("hajur <address-as>")

## Description
When the wake word is detected and an address-as term is recorded, `VoicePipeline.handleWakeDetected` **must** speak a wake acknowledgment that includes the term, following the form `हजुर <address-as>` (exact phrasing and the mechanism — TTS of a template vs pre-rendered `AckFastLane` variants — are OD-F2, the architect's call). The term is spoken verbatim (FR-PI-010).

Wake-word recognition itself is untouched and out of scope. When no term is recorded, or the profile read fails, the path **must** behave exactly as today — today it starts listening with no spoken greeting; no neutral placeholder is invented (FR-PI-011, FR-PI-015).

## Acceptance criteria

```gherkin
Feature: Personalized wake acknowledgment

  Scenario: Term recorded — the acknowledgment speaks it
    Given an address-as term is recorded
    When the wake word is detected
    Then the assistant speaks the wake acknowledgment containing the term exactly as recorded (for example "हजुर <address-as>")
    And the existing listening flow continues as today

  Scenario: No term recorded — behaves exactly as today
    Given no address-as term is recorded
    When the wake word is detected
    Then no new spoken greeting is introduced
    And the assistant starts listening exactly as today, with no placeholder term

  Scenario: Speech failure does not block listening
    Given the acknowledgment cannot be spoken (TTS unavailable)
    When the wake word is detected
    Then the assistant proceeds to listen without the greeting
    And no crash or retry loop occurs
```

## Related
- FR: FR-PI-010 (verbatim), FR-PI-011 (un-personalized path), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-008 (latency and fallback)
- Open decision: OD-F2 (phrasing and locale handling)
- Depends on: FR-PI-003 (term recorded)
