# FR-MTC-019: Phase 3 — reminder/calendar missing-slot re-prompts on the frame path

## Metadata
- **Area:** Rollout (Phase 3)
- **Priority:** SHOULD (Phase 3 — rides the release only if the owner resolves OD-M4 to include it)
- **Phase:** Phase 3 (later phase — after the frame mechanics are proven on music; Phase 1 leaves reminder/calendar turns unchanged)
- **Source:** Feature constitution "In scope" Phase 3 ("roll the same frame path over the existing stateless reminder/calendar missing-slot re-prompts; `RepetitionGuard` interplay; DV-* device validation") and "Out of scope (must not change)" ("Reminder/calendar turns are unchanged in Phase 1 (Phase 3 is where they move onto the frame path)"); feasibility study §4 (missing-slot ask-lines as today's stateless re-prompts), §6.2 (the same mechanism upgrades them) and §7 Phase 3; OD-M4 (OPEN — scope).

## Description
Phase 3 extends the same dialogue-frame mechanism to the existing **stateless** missing-slot re-prompts in the reminder and calendar paths — reminder without a time and calendar event without a title/time currently speak a missing-slot question, but the follow-up utterance is routed as a fresh command (no frame). The Phase 3 behaviour:

- **Same frame mechanics**: the missing-slot question becomes a `.slotFill` frame on the same `DialogueManager`/`DialogueFrame` path, with the same interception (FR-MTC-009), capture (FR-MTC-005), deterministic merge (FR-MTC-006), cancel/barge-in/timeout rules (FR-MTC-010/012/013) and probe budget (FR-MTC-007).
- **The follow-up fills the slot**: e.g. the reminder "what time?" answer ("बेलुका आठ बजे") merges into the pending reminder command instead of being misrouted as a fresh command.
- **`RepetitionGuard` interplay**: the existing cross-turn memory of recent confirmed actions (dementia-loop protection) must keep working with the frame path — repetition protection is not weakened by dialogue frames.
- **Phase-gated**: this requirement is not built or shipped in Phase 1 — reminder/calendar behaviour stays exactly as today until the owner resolves OD-M4 (and the phase sequencing per OD-M3); NFR-MTC-012 binds the Phase 1 no-change.
- **Same safety rules**: the reminder/calendar answer path inherits every safety constraint (emergency precedence absolute, log safety, sanitisation).

## Acceptance criteria

```gherkin
Feature: Phase 3 reminder/calendar frame rollover

  Scenario: (Phase 3) A reminder missing its time becomes an answer-capture frame
    Given Phase 3 is shipped
    When the user asks for a reminder without a time and the missing-slot question is asked
    Then the session enters the frame path (awaitingSlotAnswer)
    And the user's next answer ("बेलुका आठ बजे") merges into the pending reminder
    And the reminder is created with the spoken time confirmation as usual

  Scenario: (Phase 3) RepetitionGuard still protects against loops on the frame path
    Given Phase 3 is shipped and the user repeats the same confirmed action in a loop
    When the frame path is involved
    Then RepetitionGuard's existing protection behaves exactly as today

  Scenario: (Phase 1 guard) Reminder/calendar turns are unchanged until Phase 3 ships
    Given a Phase 1 build (this feature's deterministic MVP)
    When a reminder lacks a time or a calendar event lacks a title
    Then today's stateless re-prompt behaviour is byte-for-byte unchanged
    And no awaitingSlotAnswer frame is opened by those paths
```

## Related
- FR: FR-MTC-006 (the merge it reuses), FR-MTC-020 (device validation), FR-MTC-002 (the music-path precedent)
- NFR: NFR-MTC-012 (Phase 1 no-change), NFR-MTC-010 (trap resistance for the reminder flow)
