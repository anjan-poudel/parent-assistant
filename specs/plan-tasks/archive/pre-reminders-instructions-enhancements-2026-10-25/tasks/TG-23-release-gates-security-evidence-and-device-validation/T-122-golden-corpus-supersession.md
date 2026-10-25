# T-122: Golden-corpus supersession mechanics and pinned-surface guard (C-3)

## Metadata
- **Group:** [TG-23 — Release Gates, Security Evidence and Device Validation](index.md)
- **Component:** C-SP-15 test surface: golden corpus supersession + pinned-surface guard
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md)
- **Blocks:** [T-123](T-123-security-evidence-bundle.md)
- **Requirements:** [NFR-SP-004](../../../../define-requirements/NFR/NFR-SP-004-prompt-budget-preserved.md), [NFR-SP-006](../../../../define-requirements/NFR/NFR-SP-006-no-regression.md), [NFR-SP-012](../../../../define-requirements/NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md)

## Description
Executes the dispatch-level supersession that the stub removal forces: the old stub expectation is deleted and the new music-path expectation is recorded alongside it in the music test suite, while the pinned surfaces stay untouched — the golden music block keeps its 15 entries unedited (C-3; the feature constitution's "16" is corrected by annotation, code wins), the `>= 15` floor test stays green, and the prompt digest and character baseline/ceiling pins keep their values.

## Acceptance criteria

```gherkin
Feature: Golden-corpus supersession and pinned-surface guard

  Scenario: The supersession replaces the stub expectation only
    Given the music test suite at baseline with its stub dispatch expectation
    When the supersession is recorded
    Then the stub expectation is deleted and the new music-path expectation is recorded alongside
    And the golden music block still holds exactly its 15 entries, byte-identical to baseline

  Scenario: The floor and prompt pins remain green and unchanged
    Given the floor test (at least 15 music entries) and the prompt digest and character pins
    When the full music and intent suites run after the change
    Then the floor test passes without editing the floor
    And every prompt digest and baseline/ceiling value is unchanged

  Scenario: An incidental edit to a pinned surface fails the guard
    Given the pinned-surface guard test
    When any entry of the 15-entry music block or any prompt pin value is modified
    Then the guard fails and names the modified surface
```

## Implementation notes
- Files: `ios/ElderlyAssistant/` + `Tests/` + `GoldenCorpus.swift` (read, not edited) and the music test suite; the supersession is recorded at dispatch level, not by rewriting corpus data.
- C-3: the block holds exactly 15 entries; the feature constitution's count wording is annotated to 15 (or corrected by a one-line doc note) — the code is authoritative and the block stays unedited.
- Guard test: hash or literal-pin the 15-entry block and the prompt pin values so future features cannot drift them silently; mirror the shipped `>= 15` floor test rather than replacing it.
- The IntentPrompt digest and baseline/ceiling pins belong to NFR-SP-004's tripwire set; list them explicitly in the guard's coverage comment.
- No log changes; nothing in this task writes user content anywhere.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (supersession + guard)
- [ ] 15-entry music block verified byte-identical to baseline
- [ ] Prompt digest and character pins verified unchanged and green
- [ ] C-3 count annotation recorded
- [ ] `ios/build.sh` passes for the touched targets
