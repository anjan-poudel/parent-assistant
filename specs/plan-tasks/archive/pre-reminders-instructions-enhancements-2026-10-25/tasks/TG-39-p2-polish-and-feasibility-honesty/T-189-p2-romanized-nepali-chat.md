# T-189 — P2: romanized Nepali chat, additive and measured

## Metadata
- **Group:** [TG-39 — P2 Polish and Feasibility Honesty](index.md)
- **Component:** Romanized chat leg (design-l1 sections 11.7 and 20)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** MEDIUM
- **Depends on**: T-182 ([T-182](../TG-37-v17-chat-aware-training-suite/T-182-chat-variant-config-and-full-harness.md)), T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-187 ([T-187](../TG-38-release-gate-acceptance-and-device-validation/T-187-dv-protocol-and-record.md))
- **Blocks:** T-192 ([T-192](T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-027](../../../define-requirements/FR/FR-CNR-027-p2-romanized-nepali-chat.md), [FR-CNR-024](../../../define-requirements/FR/FR-CNR-024-feasibility-honesty-reporting.md)

## Description
Evaluate and, only where the evidence supports it, additively support romanized Nepali chat: measure how the shipped v17 candidate and personas respond to romanized input across the held-out coverage classes, decide from that evidence whether a bounded handling change is safe, and — whether the outcome is positive or negative — record the measured verdict for the sign-off statement. Devanagari behaviour and every gate are unchanged by construction; an unreliable result is reported, never hidden.

## Acceptance criteria

```gherkin
Feature: Romanized chat, measured before it is claimed

  Scenario: The evaluation measures the shipped behaviour first
    Given the v17 candidate and the shipped personas
    When romanized turns across the held-out coverage classes are run
    Then the response quality and consistency per class are recorded with the same evidence discipline the chat gates use
    And the Devanagari behaviour is measured in the same pass as the control

  Scenario: A handling change is bounded and additive
    Given the evaluation shows a specific failure class a bounded handling change can address
    When the change lands
    Then it is confined to the spec/style input handling and the persona text (no router, no classifier widening, no gate change)
    And the full harness re-runs unchanged and stays green

  Scenario: The verdict is recorded either way
    Given a completed evaluation (change landed, or no change supportable)
    When the outcome is written
    Then it states the measured result per coverage class, whether romanized chat is delivered or reported not-delivered, and the evidence behind the verdict
```

## Acceptance criteria — failure paths

```gherkin
Feature: Romanized leg failure behaviour

  Scenario: Devanagari behaviour must not move
    Given a change that alters Devanagari reply behaviour (quality, gates or prompts)
    When the regression pass runs
    Then it fails and the change is rejected — this leg is additive or it does not land

  Scenario: An unreliable result claimed as delivered
    Given romanized class results below the standard the Devanagari path meets
    When the outcome is written
    Then it is reported as not delivered with the measured shortfall, never as delivered on a favourable subset of classes

  Scenario: The guard meets romanized input
    Given a romanized reply reaching the guard
    When it returns its verdict
    Then it degrades to unavailable (honest not-verified) rather than false-flagging — and this leg does not change that contract without its own evidence
```

## Inputs and expected result

**Input:** the shipped v17 candidate (T-184) and the recorded gate configuration (T-181, T-182); the romanized-coverage question from the design's feasibility record (section 20 marks it unproven); the spec's register rules as the standard the Devanagari path meets.

**Output:** the romanized evaluation (per-class measurements with the Devanagari control), any bounded additive change the evidence supports, the re-run harness result, and the leg's notes recording the verdict.

**Declared files:** `specs/CNR-p2-romanized-notes.md`, `tools/train-intent/seeds/nepali-chat-style-spec`

## Implementation notes
- Start from measurement, not from a fix: the shipped personas and candidate define today's behaviour, and the leg's first deliverable is that behaviour's per-class record.
- Additive boundary: the only files this leg may change are the spec/style input handling and the persona text, and only with the mirror discipline (T-170) kept green. Router, classifier table, gates and guard contract are out of scope — a change needing any of them is a redesign, not this leg.
- The guard's behaviour on romanized input is already the honest one (unavailable → the caller's degraded path); do not "fix" it here.
- Evidence class: measure with the same discipline the gates use (fixed judging configuration, recorded fixture, recorded denominators) so the numbers are comparable with the chat gates rather than a bespoke benchmark.
- A not-delivered verdict is a successful completion of this unit when it is what the evidence shows, and it is the input the sign-off statement needs (FR-CNR-024).
- No user content: the evaluation uses the synthetic coverage classes, not real utterances.

## Definition of done
- [ ] Per-class romanized measurements recorded, with the Devanagari control in the same pass
- [ ] Any landed change confined to the spec/style input handling and persona text; mirror checks green
- [ ] Full harness re-run unchanged over the same candidate; all gates still green
- [ ] Verdict recorded as delivered or not-delivered with evidence and shortfalls
- [ ] No router, classifier, gate or guard-contract change
- [ ] Notes written for the feasibility statement
