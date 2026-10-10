# T-142: Security evidence index (E1..E8, V-1..V-4, R1..R5)

## Metadata
- **Group:** [TG-28 — Acceptance, Evidence and Device Protocol](../index.md)
- **Component:** deliverable `specs/MTC-security-evidence-index.md` (new document)
- **Agent:** dev
- **Effort:** S (1.5 days)
- **Risk:** HIGH
- **Depends on:** [T-138](../TG-27-observability-release-gate-and-security-evidence/T-138-release-log-gate-dialogue-roots.md), [T-139](../TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md), [T-140](../TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md), [T-141](T-141-end-to-end-acceptance-and-regression-sweep.md)
- **Blocks:** — (feeds the `security-test` workflow step)
- **Requirements:** [NFR-MTC-004](../../../../define-requirements/NFR/NFR-MTC-004-log-safety.md), [NFR-MTC-008](../../../../define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Close the security record: one index document tying each security-design-review
evidence obligation E1..E8 to its producer task, its test or command and its
observed result, plus the recorded dispositions of the verification ledger
V-1..V-4, the fix mappings M-1..M-5 and the accepted residuals R1..R5. This is
the artifact the workflow's `security-test` step consumes; it must be honest —
a row without a reproducible pointer is incomplete, not assumed.

## Acceptance criteria

```gherkin
Feature: Security evidence index

  Scenario: Every evidence row names its producer and result
    Given the completed suites and the captured gate outputs
    When the index is written
    Then each of E1..E8 rows carries the producer task, the test or command and the observed result
    And no row claims completion without a reproducible pointer

  Scenario: Verifications, fixes and residuals are recorded
    Given the security-design-review ledger in this worktree
    When the index is read
    Then V-1..V-4 each record their disposition and where it was verified
    And M-1..M-5 each point at the pinning task and DoD line
    And R1..R5 each record their accepted disposition

  Scenario: A row without a producer result fails the record
    Given an obligation row with no recorded run
    When the index is validated before the security-test step
    Then the row is marked incomplete and the record does not claim closure
```

## Implementation notes
- Producers by design: E1/E2/E3 → T-139 suites; E4 → T-138 gate output plus
  T-140 capture; E5 → T-137 allow-list plus T-140 diff; E6/E8 → T-140 suites;
  E7 → T-131 determinism plus T-141 prompt pins; the V-3 re-verification → T-140.
- Record exact commands (or scoped test invocations) so the reviewer can
  reproduce; no result without a command.
- The document must contain no verbatim user content, no secrets, no raw
  transcripts — it is a pointer index, not a data dump (NFR-MTC-004).
- Keep it short: one table per section, one row per item; the workflow's
  `security-test` step reads it directly.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by the index structure check (validation of rows)
- [ ] `specs/MTC-security-evidence-index.md` exists with every E/V/M/R row populated (V-1..V-4, M-1..M-5, R1..R5 recorded)
- [ ] Each E-row records producer task, test or command and result — no assumed rows
- [ ] No content, PII or secrets embedded in the document
