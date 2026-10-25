# T-112: KeywordIntentRule music domain, markers and extractor

## Metadata
- **Group:** [TG-20 — Music Intent Intake and Contact Veto](index.md)
- **Component:** C-SP-07 `KeywordIntentRule` (music domain rule + extractor)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-113](T-113-contact-search-music-veto.md), [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md)
- **Requirements:** [FR-SP-013](../../../../define-requirements/FR/FR-SP-013-keyword-intent-rule-music-domain.md), [FR-SP-005](../../../../define-requirements/FR/FR-SP-005-explicit-youtube-requests-unchanged.md), [NFR-SP-006](../../../../define-requirements/NFR/NFR-SP-006-no-regression.md)

## Description
Extends the deterministic keyword intent rule with the music domain: Nepali-first markers and play-verbs that classify an utterance as a general music request, an exclusion list that keeps explicit-YouTube phrases and non-music homonyms out, and the query extractor that strips marker/verb scaffolding down to the song query. Fixture-driven per §14; explicit-YouTube phrases must classify exactly as before.

## Acceptance criteria

```gherkin
Feature: Music intent keyword rule

  Scenario: A Nepali music request classifies as music with an extracted query
    Given utterances built from the music marker and play-verb fixture tables
    When the keyword rule evaluates them
    Then each classifies as the music domain
    And the extractor returns the song query with marker and verb scaffolding removed

  Scenario: Explicit YouTube phrases are untouched
    Given the shipped explicit-YouTube utterance fixtures
    When the keyword rule evaluates them
    Then every utterance classifies exactly as it did before this change
    And no YouTube utterance is re-classified to music

  Scenario: Excluded forms do not classify as music
    Given utterances on the exclusion table (homonyms, contact-name-like phrases, non-music verb uses)
    When the keyword rule evaluates them
    Then none classifies as the music domain
    And behaviour for those utterances is unchanged from baseline
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Voice/KeywordIntentRule.swift`; extractor in the same component; mirror the shipped youtube keyword family shape (domain set, rule table, extractor) — no new matching machinery.
- Rule-level YouTube exclusion (ADR-SP-06): explicit-YouTube wording wins before any music classification can act; this is what keeps FR-SP-005 byte-identical together with the ladder order in T-116.
- Grapheme-cluster matching semantics of the existing rule are preserved; do not introduce character-count shortcuts (the Swift Devanagari substring behaviour is a pinned regression).
- Fixtures: extend `KeywordIntentRuleTests` with music-domain tables (happy fixtures, exclusion fixtures, YouTube no-regression fixtures). The golden-corpus prompt digest and baseline pins are untouched here.
- Log discipline: classification results only where a classifier already logs; no utterance text added to any log (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (KeywordIntentRuleTests additions)
- [ ] YouTube fixtures pass byte-identical against baseline
- [ ] No PII in logs — no utterance text added to any log or event
- [ ] `ios/build.sh` passes for the touched targets
