# T-077: Canonicalization-Losslessness & Safety-Regression Verification

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The pinned losslessness fixture set, both clauses of the equality gate, the negative arm that proves the gate can fail, and the authoring-time `negationMarkerTouched` check
- **Agent:** qa-engineer
- **Effort:** M
- **Risk:** HIGH (SAFETY)
- **Depends on:** [T-075](T-075-canonicalizer-implementation.md), [T-074](T-074-variant-table-authoring.md)
- **Blocks:** [T-078](T-078-latency-residency-default-flip-verification.md)
- **Requirements:** FR-009, NFR-013, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §4.7, §4.3, evidence rows E-3/E-4 (gap G-5); `CommandRouter.swift:1439`, `:1448`, `:1468-1473`, `:1508-1534`

## Description

This is the safety gate. Design D-1 says the keyword net reads the original transcript, always — but D-1 is a property of *the current call graph*, and call graphs change under refactoring. This task pins it as an executable invariant, and it is the one task in the group whose failure is a safety failure rather than a quality one.

**The gate, verbatim from design §4.7.** For every row in a pinned fixture set, call the net's **own** matchers — `containsPhrase` over the 17 emergency phrases, `containsToken` over the med-ack and denial token lists — identically on `original` and on `canonical`:

- **(a)** `matches(canonical) ⊇ matches(original)` — a rule may never remove a match the net would have found.
- **(b)** `matches(canonical) ⊆ matches(original)` — a rule may never introduce a match the net would not have found.

Together, `matches(canonical) == matches(original)` **exactly**, on 100 % of rows.

Clause (b) is the `नखाए` → `खाए` catcher. `खाए` sits *inside* `नखाए` — the shipped code says so and matches whole tokens rather than substrings precisely because of it (`CommandRouter.swift:1443-1452`, doc: *"a containment match turns a refusal into a medication acknowledgement"*). Clause (a) catches a rule that eats a distress phrase. Both are computed by calling the shipped matchers, **not a re-implementation** — a re-implemented matcher would pass while the net it protects fails, which is the only failure mode a safety gate must not have.

**The negative arm is required, not optional.** E-4: a gate that has never been observed failing is not known to be a gate. This task must add a deliberately unsafe rule (`नखाए` → `खाए`) to a test-only table, run the gate, and demonstrate it **fails, non-zero, naming the row**. Only then is the passing result on the real tables meaningful. Design §4.7 states this as requirement 3.

**The fixture set is new and this task authors it.** It must cover: every one of the 17 emergency phrases; the med-ack phrases and tokens; the denial tokens; the negation class (`न`, `न-` prefixed forms, `नखाए`, `होइन`, `भएन`, `छैन`, `पर्दैन`); and — critically — rows where those appear **adjacent to or overlapping an attested variant**, because the interesting case is not a clean emergency phrase, it is a distress phrase with a dialectal word next to it. Rows are synthetic; no real utterance appears (NFR-016).

**The invariant is two-sided across the whole group, not only this fixture.** T-078 re-runs it on the end-to-end path, and T-079 registers the tables so a table change that breaks it is caught by the promotion gate rather than at runtime.

**`negationMarkerTouched` is the authoring-time half.** A table entry whose `variant` or `canonical` contains a frozen member is a structural error and the **whole table is refused** (design §4.3, D-4). This task verifies that check exists and fires, so the failure mode is caught when a table is written rather than when it runs.

**What this task does not do.** It does not modify the net, the tables, or the canonicalizer to make the gate pass. If the gate fails, the table entry is wrong and is removed — design §5 and §4.7 are unambiguous that widening the frozen set or relaxing a clause is not a remedy.

## Acceptance criteria

```gherkin
Feature: Canonicalization preserves the safety net's matches exactly

  Scenario: Both clauses of the equality gate hold on the pinned fixture set
    Given a pinned losslessness fixture covering the 17 emergency phrases, med-ack phrases and tokens, denial tokens and negation markers
    And rows placing those markers adjacent to attested variants
    When the net's own containsPhrase and containsToken matchers run over original and canonical for every row
    Then matches(canonical) is a superset of matches(original) for every row
    And matches(canonical) is a subset of matches(original) for every row
    And the run reports 100 percent agreement, with every failing row named if it is not

  Scenario: The gate can fail, demonstrated before it is trusted to pass
    Given a test-only table containing the unsafe rule नखाए -> खाए
    When the gate runs against it
    Then the run exits non-zero and names the offending row and rule
    And the unsafe rule is refused by the negationMarkerTouched validator before it can be applied
    And the passing result on the real tables is reported only after this negative arm has been observed

  Scenario: The gate calls the shipped matchers, not a copy
    Given containsPhrase at CommandRouter.swift:1439 and containsToken at :1448
    And the 17 emergency phrases at :1468-1473 and the med-ack and denial lists at :1508-1534
    When the harness computes matches
    Then it invokes the shipped matchers
    And the phrase and token lists are extracted as data from their single shipped source rather than duplicated in the harness
    And a change to a shipped list changes the gate's input without a harness edit

  Scenario: The fixture set is pinned and covers the marked classes
    Given the frozen set of design §4.7
    When the fixture is written
    Then it contains at least one row per emergency phrase, per med-ack and denial token, and per negation marker
    And it contains rows where a frozen marker is adjacent to or overlapping a table variant
    And it is committed as a pinned file whose rows are addressed by id in the report
    And it contains no real utterance or contact name

  Scenario: A failure is a table defect, never a gate defect
    Given a failing row
    When the failure is diagnosed
    Then the remedy applied is to remove or rewrite the table entry
    And no clause of the gate is relaxed and no member is removed from the frozen set
    And the removal is recorded with the row id that caught it

  Scenario: No surface form is written to any evidence artifact
    Given the fixture contains marker-bearing utterances
    When the harness writes its report
    Then the report contains row ids, rule ids, counts and pass or fail
    And it contains no transcript, no variant surface and no canonical surface
    And the assertion is checked by a test, not by convention
```

## Implementation notes

- Read first: design §4.7 in full (the invariant and the three reasons it exists); `CommandRouter.swift:582-620` (where the net is called and how the transcript is whitespace-canonicalised for it), `:1439`, `:1448`, `:1468-1473`, `:1494`, `:1508-1534`; `T-061-order-robustness-baseline.md:37` (TG-11's freeze list).
- The `खाए` ⊂ `नखाए` hazard is the canonical example and should be the first fixture row written. It is the reason the net matches whole tokens, and it is the defect a naive variant rule produces.
- Extract the phrase and token lists as **data from their single shipped source**. A harness copy of the 17 phrases is a second source of truth and will silently diverge — the gate would then certify a net that no longer exists. If extraction is not possible without touching `CommandRouter`, prefer a test that reads the lists through whatever accessor exists over a duplicated literal, and record the constraint.
- Line numbers here are the values at the time of writing; the encoder design carries a stale citation for this exact list (it names `1403-1408`). Verify against the file before citing, and correct any citation copied from another document.
- The fixture is a safety artifact, not a benchmark: it stays small, pinned and hand-checked. Do not grow it from generated corpus rows, whose markers are template-derived.
- Report shape follows the T-033 evidence-pack precedent: machine-readable under `tools/train-intent/docs/tg12-evidence/`, with a run manifest that pins the fixture revision, the table revision and the canonicalizer revision — a passing run against an unknown table revision is not evidence.
- This gate must run in the debug path from the moment the canonicalizer is reachable at all. Design §14's closing note is explicit: G-5 must close **before canonicalization ships in any debug path**, because R-3 is a safety failure rather than an accuracy one. If T-075 lands first and this cannot, the policy default is `Policy.enabled = false` until it does.
- Do not "fix" a failure by adding the failing row to a skip list. A skipped safety row is an untested safety row.

## Definition of done
- [ ] Pinned losslessness fixture committed, covering every emergency phrase, med-ack and denial token, and negation marker, plus marker-adjacent-to-variant rows
- [ ] Both clauses executed against the shipped `containsPhrase` and `containsToken`, with the lists sourced from their single shipped origin
- [ ] 100 % agreement reported on 100 % of rows, or every failing row named
- [ ] The negative arm (`नखाए` → `खाए`) observed failing the gate non-zero and naming the row, before the passing result is reported
- [ ] `negationMarkerTouched` verified to refuse the whole table on such an entry
- [ ] Any failure remediated by a table change, with the catching row id recorded; no gate or frozen-set weakening
- [ ] Evidence written under `tools/train-intent/docs/tg12-evidence/` with a run manifest pinning fixture, table and canonicalizer revisions
- [ ] A test asserts the report contains no transcript or surface form
- [ ] Gate wired into the debug-path test run before the canonicalizer is reachable without `Policy.enabled = false`
