# T-186 — End-to-end acceptance, scoped sweep and the one full-suite run

## Metadata
- **Group:** [TG-38 — Release Gate, Acceptance and Device Validation](index.md)
- **Component:** Acceptance sweep (join point of P0 and P1)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** HIGH
- **Depends on**: T-170 ([T-170](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-170-prompt-mirror-discipline.md)), T-171 ([T-171](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-171-localisation-consent-and-safe-template-copy.md)), T-177 ([T-177](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-177-indicator-revocation-and-coordinator-wiring.md)), T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-185 ([T-185](T-185-release-log-safety-gate-coverage.md))
- **Blocks:** T-187 ([T-187](T-187-dv-protocol-and-record.md)), T-192 ([T-192](../TG-39-p2-polish-and-feasibility-honesty/T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-013](../../../define-requirements/FR/FR-CNR-013-single-decode-schema-unchanged.md), [FR-CNR-014](../../../define-requirements/FR/FR-CNR-014-router-ladder-emergency-gate-unchanged.md), [FR-CNR-015](../../../define-requirements/FR/FR-CNR-015-stt-permissions-data-collection-unchanged.md), [NFR-CNR-011](../../../define-requirements/NFR/NFR-CNR-011-compliance-and-release-gates.md)

## Description
The join point: walk the feature end to end against the acceptance criteria of the record, sweep the scoped suites over the integrated tree, run the full suite once with the pre-existing red baseline named (not hidden), confirm the release log gate exits zero, and audit the preservation surfaces the feature promised not to touch — the single-decode schema, the router ladder and emergency gate, the STT path and the absence of any new permission. Findings found here are fixed, not deferred.

## Acceptance criteria

```gherkin
Feature: The integrated feature accepts as specified

  Scenario: The chat journeys run end to end
    Given the integrated tree
    When a local chat turn, a consented cloud chat turn, an offline chat turn and a guard-flagged turn (with and without cloud) are exercised through the real seams
    Then each journey meets its acceptance criteria: an answer every time, the consent and indicator rules honoured, the flagged text never spoken, the fallback honest

  Scenario: The scoped suites pass
    Given the scoped unit suites for every unit in this plan
    When they run over the integrated tree
    Then all are green (each unit's own gate having been run in its wave)

  Scenario: The full suite runs once, with the baseline named
    Given the full test suite runs
    When results are compared with the pre-existing baseline
    Then the baseline failures are named as pre-existing (the recorded set) and no new failure appears
    And a new failure is fixed here, never deferred

  Scenario: The release log gate exits zero
    Given the extended release log gate (T-185)
    When it runs over the integrated tree
    Then it exits zero and its result is part of the acceptance record

  Scenario: Preservation audit
    Given the surfaces the feature promised to leave alone (single-decode schema, router ladder, emergency gate, STT path, permissions)
    When the audit walks the diff against those surfaces
    Then each is unchanged except where the design explicitly changes it (chat lane insertion, dispatch chat case), and no new permission or Info.plist key exists
```

## Acceptance criteria — failure paths

```gherkin
Feature: Acceptance failure behaviour

  Scenario: A journey fails
    Given a journey that does not meet its criteria
    When it is recorded
    Then the failure is captured with reproduction detail and the acceptance record is not signed off until it is fixed or explicitly reported to the owner as an open item

  Scenario: A regression appears in an earlier suite
    Given a suite green in its own wave and red after a later unit
    When the sweep runs
    Then the regression is attributed to the later unit and fixed — it is not absorbed into the baseline

  Scenario: The baseline is misreported
    Given a failure claimed as pre-existing
    When it is checked against the recorded baseline set
    Then a failure not in that set is treated as new (baseline honesty is part of the acceptance record)
```

## Inputs and expected result

**Input:** every unit of this plan (the acceptance sweep joins them); the scoped-suite gate convention and the recorded pre-existing baseline set; the release log gate; the design's preservation claims (sections 19 and 21).

**Output:** the acceptance record (`specs/CNR-acceptance-notes.md`): the journey results, the scoped sweep results, the full-suite result with the baseline named, the release-gate result and the preservation audit — each with the command that produced it.

**Declared files:** `specs/CNR-acceptance-notes.md`

## Implementation notes
- The full suite runs once, here, per the house rule (focused tests and typecheck per unit; the full suite at integration). Its known pre-existing failures are named from the recorded baseline — the sweep's value is the attribution, not the raw count.
- The journeys exercise the real seams (router, dispatch, coordinator), not isolated classes: the point of this unit is the integration the per-unit tests could not see.
- The release gate is wired ahead of the test scopes in the build; its exit zero over the integrated tree is recorded verbatim.
- The preservation audit is a diff walk, not a claim: name the files, show the intended changes, and confirm nothing else moved (single-decode schema, ladder, emergency gate, STT, permissions).
- This unit owns no other artifact: it audits, runs and records. Any fix it triggers belongs to the unit that owns the file.
- If a red gate from T-183 left the v17 entry unpromoted, the acceptance record states the delivered state honestly (P0 accepting, P1 gated) rather than treating the run as failed.

## Definition of done
- [ ] End-to-end journeys run and recorded per journey with the command that produced them
- [ ] Scoped suites green over the integrated tree
- [ ] Full suite run once; pre-existing failures named from the recorded baseline; no new failure left unfixed
- [ ] Release log gate exit zero recorded
- [ ] Preservation audit recorded (schema, ladder, emergency, STT, permissions unchanged as designed)
- [ ] Acceptance record written with per-journey results and open items stated honestly
