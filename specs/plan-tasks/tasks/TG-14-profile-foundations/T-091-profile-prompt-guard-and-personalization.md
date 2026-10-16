# T-091: `ProfilePromptTextGuard` + `ProfilePersonalization` (C07, AM-1, AM-2)

## Metadata
- **Group:** [TG-14 — Profile Foundations: Store, Guard, Seams, Strings](index.md)
- **Component:** C07 — `ProfilePromptTextGuard`, `ProfileText`, `ProfilePersonalizationReading`, `ProfilePersonalization`
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-090](T-090-user-profile-store.md)
- **Blocks:** [T-092](T-092-coordinator-profile-seams.md), [T-098](../TG-16-interview-wizard-and-startup-routing/T-098-address-as-field.md), [T-104](../TG-17-settings-release-and-evidence/T-104-log-safety-coverage.md)
- **Requirements:** FR-PI-010, FR-PI-011 · NFR-PI-002, NFR-PI-004 · Feature Constraint 4 · AM-1, AM-2 · SD-1, SD-2 · evidence obligations 1, 2, 3

## Description

The injection discipline for the one profile string that may enter a prompt, plus the read seam both interpreters and the ack service consume. Guard pipeline, in fixed order: quarantine via the shared `InputSanitiser` → strip-then-detect against its single-sourced marker table → `Character`-boundary clamp to `maxPromptTermGraphemes` (default 24, equal to the entry bound) → quote-slot neutralisation → nil on any residual. `ProfilePersonalization` exposes the guarded accessor (prompt side) and the verbatim accessor (ack side) over `UserProfileStoring`; it never writes. Files: new `Services/Voice/ProfilePromptTextGuard.swift`, new `Services/Voice/ProfilePersonalization.swift`.

## Acceptance criteria

```gherkin
Feature: Profile string hardening and read seam

  Scenario: An in-table marker term is quarantined and the turn runs un-personalized
    Given a term that matches an entry in the shared marker table
    When the guarded accessor is read
    Then the result is nil
    And the event profile_prompt_text_quarantined is emitted with no metadata
    And the composition for that turn uses the no-term clause

  Scenario: A benign term passes and the quoted slot cannot be closed
    Given a benign term such as "Mum"
    When the guarded accessor is read
    Then the term is returned unchanged
    Given a term containing U+0022, U+2018, U+2019, U+201C, U+201D or a backtick
    When the guarded accessor is read
    Then every one of those characters is replaced in the prompt-side value
    And the stored and spoken term is never altered (AM-2, SD-2)

  Scenario: Out-of-table instruction-shaped input is contained as quoted data
    Given the requirement's own example payload and a Nepali instruction-shaped term
    When the guarded accessor is read
    Then the value passes as bounded, neutralised data rather than being silently transformed
    And the containment statement in the guard's documentation names the quoted slot and the absent capability (no action, no routing change, no profile write) as the load-bearing controls (AM-1, SD-1)
    And the A/B routing assertion for these fixtures is carried by the clause tests (T-094)

  Scenario: Grapheme-boundary clamping never splits a cluster
    Given a 30-grapheme Latin term and a Devanagari term whose conjuncts are single Characters
    When the guarded accessor is read
    Then the value is the first 24 whole Characters of the input
    And no grapheme cluster is broken (R10)

  Scenario: Empty, whitespace and unrecorded values stay un-personalized
    Given an empty or whitespace-only stored value, or an absent or unreadable store
    When either accessor is read
    Then the guarded accessor returns nil with no event for the benign cases
    And the verbatim accessor returns nil
    And no placeholder value is ever substituted (FR-PI-011)

  Scenario: The verbatim accessor is guard-free
    Given a stored term that the guard would quarantine
    When the verbatim accessor is read
    Then the stored term is returned exactly as recorded
    And the acknowledgement path can speak it while the prompt path stays un-personalized (ADR-09 asymmetry)
```

## Implementation notes

- The shared `InputSanitiser` marker table is single-sourced project-wide. Do not edit it and do not duplicate it — SD-1 records that its coverage is bounded by the English/transliterated phrase list, and extending it is a project-level decision outside this feature.
- AM-1: the guard's documentation must state the containment explicitly — the quarantine action applies to input that trips the shared table; out-of-table instruction shapes (including non-English) are contained as quoted data by the fixed clause framing, the 24-grapheme bound, and the structural absence of capability. The fixture set splits in-table (obligation 1) from out-of-table (obligation 2) cases.
- AM-2: extend the slot neutralisation beyond U+0022 to the quote family (U+2018, U+2019, U+201C, U+201D) and the backtick, replacing with a plain apostrophe in the prompt-side value only — the stored/spoken term stays untouched.
- The quarantine event fires once per read of a non-nil input that yields nil; benign reads emit nothing. No retry path anywhere.
- `ProfileText.clamped(_:maxGraphemes:)` is the shared clamp helper and is reused by the entry UI (T-098) — keep it public and tested here.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`ProfilePromptTextGuardTests`, `ProfilePersonalizationTests` over the store fake)
- [ ] No PII in logs — the quarantine event carries `outcome` only, no metadata, no term
- [ ] Evidence (obligation 1): in-table marker fixture shows quarantine firing, the un-personalized turn, and the byte-identity assertion shared with T-094's digest test
- [ ] Evidence (obligation 2): out-of-table fixtures (the requirement's own example; a Nepali instruction-shaped term) pass as quoted data; the A/B routing assertion lives with the clause tests (T-094) and is cited by T-105
- [ ] Evidence (obligation 3, guard half): quote-family neutralisation covered for all six characters; 24-grapheme clamping covered on Latin and Devanagari conjunct fixtures
- [ ] AM-1 containment statement present in the guard's documentation; AM-2 implemented and recorded (quote family + backtick)
- [ ] `ios/build.sh` passes
