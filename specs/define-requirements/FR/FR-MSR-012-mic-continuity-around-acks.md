# FR-MSR-012: Mic continuity around acknowledgements — no gap between acknowledgement and listening

## Metadata
- **Area:** Voice Pipeline / Ack Fast Lane
- **Priority:** MUST
- **Source:** Feature constitution "Safety & Compliance Delta" verified risk note "Mic-continuity invariant around acks" (the ack fast lane plays acknowledgements so the mic never closes; `[ACK-MIC-CONTINUITY]`); workflow scope comment (owner brief, 2026-10-15 — voice acknowledgement path).

## Description
Acknowledgement playback around the medication flows **must** preserve microphone continuity: the acknowledgement (including the new ack-with-slot and clarification utterances) is spoken through the ack fast lane so the microphone never closes, and there is **no gap** between the acknowledgement being played and listening resuming. The new utterance shapes enter the same turn pipeline and must not reintroduce a gap.

Binding properties:

- **No mic-closing acknowledgement.** An acknowledgement must not stop the audio session or otherwise require the elder to re-activate listening.
- **No gap.** After the acknowledgement audio completes, the system is listening again without a silent window in which a follow-up answer (for example the challenge answer) could be missed.
- **Covered by the fast-lane tests.** The acknowledgement fast-lane suite extends to cover the new shapes; a regression that closes the mic is a failing test, not a tuning note.

## Rationale
The elderly user's flow is: reminder fires, elder speaks, system acknowledges, elder answers the challenge. If the acknowledgement closes the mic, the elder's next words are lost and the challenge times out — a direct safety-relevant failure. The fast lane exists precisely to prevent this; the requirement keeps it binding on the new utterances.

## Acceptance criteria

```gherkin
Feature: Acknowledgements never close the microphone

  Scenario: The acknowledgement plays without closing the mic
    Given a medication reminder just fired and the elder acknowledged with the new utterance shape
    When the acknowledgement is played through the ack fast lane
    Then the microphone remains open during and after playback
    And the system is listening again with no gap after the acknowledgement

  Scenario: The challenge answer spoken immediately after the acknowledgement is heard (edge)
    Given the elder speaks the challenge answer immediately after the acknowledgement audio
    When the turn pipeline processes it
    Then the answer is captured
    And the challenge resolves on that answer

  Scenario: A regression that closes the mic is a failure (failure)
    Given an acknowledgement path that stops the audio session or leaves a listening gap
    When the fast-lane suite runs against it
    Then the suite fails
    And the path must not ship
```

## Related
- FR: FR-MSR-007 (voice acknowledgement), FR-MSR-008 (clarification), FR-MSR-009 (challenge sequence)
- NFR: NFR-MSR-008 (test rigor)
