# NFR-MSR-007: Devanagari grapheme-cluster behaviour regression-pinned — do not "fix" it

## Metadata
- **Category:** Localisation / Regression
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" ("The Devanagari substring/grapheme-cluster behavior (regression-pinned — do not 'fix' it)") and "Feature Constraints" 6; project memory of the pinned behaviour (Character-cluster partial-word matching in Nepali search).

## Description
The shipped Devanagari substring and grapheme-cluster matching behaviour **must** be regression-pinned: the feature keeps the behaviour exactly as shipped and must not propose or apply a "correction" to it. Where the revamped surfaces use Nepali string matching (medication names, purpose chips, acknowledgement vocabulary), they must respect the pinned behaviour rather than "fixing" it.

Measurable form: the pinned regression tests for the grapheme-cluster behaviour pass unchanged; the feature's diff contains no change to the matching implementation.

## Acceptance criteria

```gherkin
Feature: The Devanagari matching behaviour stays pinned

  Scenario: The pinned behaviour is unchanged
    Given the shipped regression tests for Devanagari substring and grapheme-cluster matching
    When the revamped build runs them
    Then every pinned expectation passes unchanged
    And the matching implementation is untouched by the feature

  Scenario: A proposed "fix" is rejected (failure guard)
    Given a change that would "correct" the grapheme-cluster partial-word matching behaviour
    When it is reviewed against this requirement
    Then it is rejected
    And any such change requires an explicit owner decision recorded outside this feature
```

## Related
- FR: FR-MSR-004 (purpose chips), FR-MSR-007 (acknowledgement vocabulary matching), FR-MSR-008 (disambiguation)
- NFR: NFR-MSR-004 (localisation)
