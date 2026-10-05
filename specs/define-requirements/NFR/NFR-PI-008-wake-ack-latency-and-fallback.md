# NFR-PI-008: Wake-acknowledgment latency and failure fallback

## Metadata
- **Category:** Performance / Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (wake acknowledgment; behaves exactly as today including any fallback path); project stakeholder brief NFR-003 (wake-word activation within 1 second); owner brief 2026-10-05

## Description
The personalized acknowledgment **must not** regress wake responsiveness:

- The acknowledgment speech **begins within 1 second** of wake-word detection (the existing activation budget of `requirements.md` NFR-003).
- The existing listening flow continues as today; the acknowledgment must not introduce an unbounded wait or block intent capture beyond the current pipeline's behaviour — the exact sequencing and mechanism are OD-F2 (architect).
- If the acknowledgment cannot be spoken (TTS engine unavailable or failed), the path **must** fall back to today's silent start: no crash, no blocking, no retry loop, and listening still begins.

## Acceptance criteria

```gherkin
Feature: Wake-acknowledgment responsiveness

  Scenario: The acknowledgment begins within the activation budget
    Given an address-as term is recorded
    When the wake word is detected
    Then the acknowledgment begins within 1 second
    And the existing listening flow continues as today

  Scenario: TTS failure falls back to today's silent start
    Given the acknowledgment cannot be spoken (TTS unavailable)
    When the wake word is detected
    Then the assistant starts listening as today, with no greeting
    And no crash, blocking wait or retry loop occurs
```

## Related
- FR: FR-PI-008 (wake ack), FR-PI-011 (today-behaviour)
- NFR: NFR-PI-010 (no regression)
- Open decision: OD-F2 (phrasing and mechanism)
