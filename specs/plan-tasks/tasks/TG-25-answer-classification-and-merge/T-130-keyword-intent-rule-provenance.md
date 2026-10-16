# T-130: Keyword-rule provenance, near-matches and markers

## Metadata
- **Group:** [TG-25 — Answer Classification and Merge](../index.md)
- **Component:** C-MTC-06 — `Services/` + `Voice/KeywordIntentRule.swift`
- **Agent:** dev
- **Effort:** M (2.5 days)
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-131](T-131-dialogue-answer-path-classification.md), [T-132](T-132-dialogue-candidate-builder.md), [T-134](../TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md)
- **Requirements:** [FR-MTC-002](../../../../define-requirements/FR/FR-MTC-002-degenerate-music-query-detection.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Extend the keyword rule with the extractor outcomes the feature needs, per
design-l2 §10: a `musicQueryOutcome` that reports how a query was found
(content tokens, transcript fallback, marker fallback) and whether that makes it
degenerate; a bounded `nearMatches` reading for the did-you-mean builder; and
the scaffold/marker token accessors used to strip framing words. All existing
return values stay byte-identical via the unchanged `musicQuery` wrapper.

## Acceptance criteria

```gherkin
Feature: Keyword-rule provenance and near-match readings

  Scenario: A marker-only request is flagged degenerate with no query
    Given the utterance of a music verb plus the generic bhajan marker
    When the outcome is extracted
    Then the provenance is the marker fallback
    And the query is absent and the degenerate flag is set

  Scenario: A specific request keeps the content provenance
    Given an utterance naming a specific occasion and artist before the music verb
    When the outcome is extracted
    Then the provenance is the content tokens
    And the degenerate flag is clear and the query is the specific phrase

  Scenario: A canonical empty result falls back to the transcript without a query
    Given an utterance whose music verb is followed only by framing words
    When the outcome is extracted
    Then the provenance is the transcript fallback
    And the query is absent

  Scenario: The compatibility wrapper is byte-identical
    Given the full existing keyword-rule fixture corpus
    When the unchanged query wrapper is called on each fixture
    Then each returned value equals the shipped value byte-for-byte

  Scenario: Near-match readings are bounded and deduplicated
    Given utterances partially matching several rule families
    When near-matches are read
    Then at most one entry per domain is returned
    And only the four framable domains participate
    And medication-family rules are never returned

  Scenario: Scaffold and marker accessors split framing words from content
    Given an utterance mixing music verbs, markers and content tokens
    When the scaffold-token and marker-token checks run
    Then marker tokens are excluded from scaffold content
    And the existing drop-word behaviour is unchanged
```

## Implementation notes
- This is the critical-path head: both the classifier's vocabulary (T-131) and
  the degenerate trigger (T-134) derive from this task, so land it early and
  keep the wrapper untouched — every existing caller must keep byte-identical
  outputs (spotlight regression: the shipped `musicQuery` values).
- The near-match reading is restricted to {news, youtube, music, appLaunch}
  domains, one entry per domain, medication rules excluded (design-l2 §6/§10;
  safety: no probe may be framed around a medication command).
- Provenance markers are an internal closed vocabulary; no new egress or file
  reads (NFR-MTC-012 by construction).
- Keep the rule tables as the single vocabulary source; T-128's widenings and
  T-131's classifier must reference these surfaces, never copy phrase lists.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`KeywordIntentRuleTests` extended)
- [ ] Wrapper-parity test over the full fixture corpus is green (byte-identical returns)
- [ ] No existing caller behaviour change: full existing keyword-rule suite passes unmodified
- [ ] Focused suite green: `KeywordIntentRuleTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
