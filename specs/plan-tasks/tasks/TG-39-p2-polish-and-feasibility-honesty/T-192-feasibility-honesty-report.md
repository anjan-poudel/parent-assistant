# T-192 — Feasibility honesty statement for the sign-off package

## Metadata
- **Group:** [TG-39 — P2 Polish and Feasibility Honesty](index.md)
- **Component:** Sign-off evidence (design-l1 section 20; FR-CNR-024)
- **Agent:** dev
- **Effort:** S (about 1 day)
- **Risk:** HIGH
- **Depends on**: T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md)), T-187 ([T-187](../TG-38-release-gate-acceptance-and-device-validation/T-187-dv-protocol-and-record.md)), T-188 ([T-188](T-188-p2-dpo-on-judge-preferences.md)), T-189 ([T-189](T-189-p2-romanized-nepali-chat.md)), T-190 ([T-190](T-190-p2-4b-tier-candidate-and-admission.md)), T-191 ([T-191](T-191-p2-consent-based-real-transcripts.md))
- **Blocks:** —
- **Requirements:** [FR-CNR-024](../../../define-requirements/FR/FR-CNR-024-feasibility-honesty-reporting.md), [FR-CNR-025](../../../define-requirements/FR/FR-CNR-025-dv-device-validation-completion-gate.md), [FR-CNR-003](../../../define-requirements/FR/FR-CNR-003-chat-turn-fixed-seed-temp.md)

## Description
Write the feasibility statement the final sign-off consumes: for every leg the design's feasibility record names — on-device chat sampling at the fixed seed and the recorded temperature, the GBNF/command-schema interplay, guard coverage limits, cloud-routing behaviour, the 1.7B chat quality on the reference tier, and the four P2 legs — state the measured outcome, the evidence pointer, and, where a leg under-delivered or was descoped, exactly that. No leg is omitted and none is reported as better than its measurement.

## Acceptance criteria

```gherkin
Feature: Every leg's verdict, measured and pointed at

  Scenario: Every named leg appears
    Given the design's feasibility record and the run's evidence
    When the statement is written
    Then each leg has a verdict: delivered with its measured value, under-delivered with its shortfall, not attempted, or descoped by the owner
    And each verdict carries a pointer to its evidence (run notes, gate report, device record, acceptance record)

  Scenario: The measured values are the recorded ones
    Given the gate reports, run notes and device record
    When a value is quoted
    Then it matches the recorded value exactly (no re-derivation, no rounding toward the threshold, no favourable subset)

  Scenario: The honest limits are stated
    Given the parts of the design whose coverage is deliberately bounded (the guard's lexicon-bounded honorific catch, its script-classification scope, the romanized unavailable-degradation, the cloud path's recorded transcription exception on a Gemini stack)
    When the statement is written
    Then each limit is stated in plain words so the owner reads the true shape of the delivered capability

  Scenario: The statement is usable at sign-off
    Given the final sign-off package
    When a signer reads the statement
    Then the P0/P1 delivered state, the device-validation state (executed or outstanding) and every open item are each stated explicitly, with nothing left for the reader to infer
```

## Acceptance criteria — failure paths

```gherkin
Feature: Statement failure behaviour

  Scenario: A missing leg
    Given a leg with no verdict in the statement
    When the statement is checked against the design's record
    Then the omission is a defect and the statement is not complete — a leg is never dropped silently

  Scenario: A red measured as green
    Given a measured value below its threshold or a blocked device item
    When the statement is checked against the recorded evidence
    Then the statement must state the shortfall; a favourable restatement is a defect of this unit

  Scenario: An unverifiable claim
    Given a verdict with no evidence pointer, or a pointer that does not contain the claim
    When the statement is checked
    Then the claim is removed or the evidence supplied
```

## Inputs and expected result

**Input:** the design's feasibility record (its section 20 verdicts and their status: measured at the run, unproven, likely not admissible, partially feasible); the v17 run notes and gate reports (T-183); the acceptance record (T-186); the device-validation record (T-187); the P2 legs' notes (T-188 to T-191).

**Output:** the feasibility honesty statement as `specs/CNR-feasibility-honesty-report.md`, structured leg by leg with verdicts, values and evidence pointers, ready to be cited by the final sign-off.

**Declared files:** `specs/CNR-feasibility-honesty-report.md`

## Implementation notes
- Structure it leg by leg, mirroring the design's feasibility table so a reader can diff the two: chat sampling reproducibility at the fixed seed and recorded temperature; the command schema and determinism untouched (with its evidence); guard coverage (what it catches and what it deliberately does not); cloud routing behaviour (per-turn decision, fallback, no leak); the 1.7B chat quality measured on the reference tier; the four P2 legs each with their own verdict.
- Quoting discipline: values come from the recorded evidence verbatim, with the evidence pointer (file and section); the statement adds interpretation only where the design defines the threshold.
- The device-validation state is part of the statement: executed with results, partially executed, or blocked with the reason — the reader must be able to see the completion gate's true state without opening another document.
- The statement is the input the sign-off's advisory security pass reads alongside the provenance manifest; keep those cross-references explicit (the manifest hash, the gate report identity, the DV record version).
- This unit produces no code and no other evidence: it composes, checks and points.

## Definition of done
- [ ] Statement written with a verdict per leg named in the design's feasibility record
- [ ] Every verdict carries an evidence pointer; every quoted value matches its recorded source
- [ ] Honest limits stated in plain words (lexicon-bounded guard, script scope, romanized degradation, the recorded transcription exception)
- [ ] Delivered state, device-validation state and open items each stated explicitly
- [ ] Checked against the recorded evidence: no omission, no favourable restatement, no unverifiable claim
