# NFR-CNR-005: Prompt-template byte-mirror discipline — seed and code cannot drift

## Metadata
- **Category:** Reliability / Build Discipline
- **Priority:** MUST
- **Source:** Proposal §4 ("Add `seeds/chat_prompt_template.txt` byte-mirrored to `IntentPrompt.buildChat`, same discipline as the intent prompt"); feature constitution "Prompt/seed discipline" property 1 ("the mirror lands in the SAME change as any `buildChat` edit") and "Nepali Conversation Style-Spec Contract" property 1 (the style spec follows "the byte-pinned `seeds/prompt_template.txt` discipline"); workflow `security-design-review` / `security-test` focus ("the seed mirror is byte-identical"); project precedent: the pinned, byte-mirrored intent prompt guarded by `IntentPromptTests`.

## Description
The prompt artifacts **must** be mechanically locked so no drift can ship. Measurable properties:

- **Byte-identical mirror**: `tools/train-intent/seeds/chat_prompt_template.txt` is **byte-identical** (sha256 equal) to the chat template text produced by `IntentPrompt.buildChat` at every revision that ships.
- **Same-change rule**: a revision that edits `IntentPrompt.buildChat` without updating the mirror in the same change fails the check — a mismatch count of **0** is required, verified mechanically rather than by review.
- **The intent prompt is untouched**: `IntentPrompt.build`'s text and its `seeds/prompt_template.txt` mirror are byte-identical to their pre-change content (sha256 equal), and the existing pin test remains green.
- **The style spec's discipline is equivalent**: the new `seeds/nepali-chat-style-spec` (FR-CNR-001) is a single-source artifact with the same no-fork property — its consumers derive from it rather than holding copies (verifiable as "no consumer contains an independently authored rule text").

## Acceptance criteria

```gherkin
Feature: Prompt artifacts are byte-locked to their sources

  Scenario: The chat seed mirrors the code byte-for-byte
    Given a shipped revision
    When tools/train-intent/seeds/chat_prompt_template.txt is hashed and compared with the text IntentPrompt.buildChat produces
    Then the two hashes are equal

  Scenario: The locked intent prompt is unchanged
    Given the pre-change intent prompt text and its seed mirror
    When the post-change artifacts are hashed
    Then both hashes equal their pre-change values
    And the intent-prompt pin test stays green

  Scenario: A template edit ships without its seed update (failure)
    Given a revision that edits IntentPrompt.buildChat and leaves the seed mirror stale
    When the check runs
    Then the revision fails with an explicit mismatch
    And the change cannot land in that state
```

## Related
- FR: FR-CNR-023 (template discipline), FR-CNR-002 (personas), FR-CNR-001 (the spec's single-source discipline)
- NFR: NFR-CNR-004 (token budget), NFR-CNR-011 (release gates)
