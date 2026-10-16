# NFR-FCU-007: Devanagari substring / grapheme-cluster behavior regression-pinned

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution Out of scope ("The Devanagari substring/grapheme-cluster behavior (regression-pinned — do not "fix" it)"), Feature Constraint 3 ("The Devanagari substring / grapheme-cluster behavior is regression-pinned — do not "fix" it") and Nickname property 4 ("The grapheme-cluster / Devanagari substring behavior is regression-pinned: the existing Character-safe substring behavior must hold exactly"); workflow `security-test` focus ("Devanagari substring behavior regression-pinned (no grapheme "fixes")"); project memory: Swift Devanagari substring graphemes — pin as regression, do not "fix". Integration surfaces: `NepaliTextNormalizer`, the Character-safe substring matching in `UnifiedContactSearch.familyMatches` / `SystemContactSearch.matches` / `ContactResolver`; suites `NepaliTextNormalizerTests`, `UnifiedContactSearchTests`, `ContactResolverTests`.

## Description
The existing Character-safe substring / grapheme-cluster matching behavior is **frozen**:

- Nickname matching (search and voice) reuses the **exact** existing semantics — `Character`-safe `range(of:options:)` with `[.caseInsensitive, .diacriticInsensitive]` (optionally after `NepaliTextNormalizer` folding, exactly as the name path does today) — with no new options, no cluster normalization, and no attempt to "improve" partial-word Devanagari matching.
- The pin is **test-enforced**: existing expectation cases in `NepaliTextNormalizerTests`, `UnifiedContactSearchTests` and `ContactResolverTests` stay unchanged and green; the new nickname cases assert the identical semantics (same options, same outcomes) rather than new behavior.
- Any deviation in the pinned behavior is a regression and fails the suites — the pin is load-bearing, not documentation.

## Acceptance criteria

```gherkin
Feature: The grapheme/substring behavior stays pinned

  Scenario: Existing behavior holds exactly
    Given the existing normalizer and substring-matching test cases
    When the suites run after this feature
    Then every existing expectation passes with unchanged assertions
    And no grapheme-cluster behavior was modified or "fixed"

  Scenario: Nickname matching uses the identical semantics
    Given a nickname exercising the same grapheme edge cases as a name
    When search and voice matching run over it
    Then matching behaves exactly as the name path does
    And the same compare options and folding are used (reuse, not a fork)

  Scenario: A semantic deviation fails the pin (failure)
    Given the nickname path's matching options or folding are altered
    When the pinned suites run
    Then the regression tests fail
```

## Related
- FR: FR-FCU-012 (search matching semantics), FR-FCU-013 (voice semantics)
- NFR: NFR-FCU-001 (the index must not alter the pinned matching), NFR-FCU-009 (scoped suites)
