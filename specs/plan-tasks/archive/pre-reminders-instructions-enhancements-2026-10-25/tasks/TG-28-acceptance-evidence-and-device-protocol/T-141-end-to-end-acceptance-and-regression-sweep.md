# T-141: End-to-end acceptance and no-regression sweep

## Metadata
- **Group:** [TG-28 — Acceptance, Evidence and Device Protocol](../index.md)
- **Component:** new test `ios/ElderlyAssistantTests/Services/` + `Voice/DialogueAcceptanceTests.swift`; sweep run record
- **Agent:** dev
- **Effort:** M (2.5 days)
- **Risk:** HIGH
- **Depends on:** [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md), [T-134](../TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md), [T-136](../TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md), [T-139](../TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md), [T-140](../TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md)
- **Blocks:** [T-142](T-142-security-evidence-index.md)
- **Requirements:** [FR-MTC-006](../../../../define-requirements/FR/FR-MTC-006-deterministic-frame-merge-and-execution.md), [FR-MTC-018](../../../../define-requirements/FR/FR-MTC-018-follow-up-nlu-fine-tune-v17.md), [FR-MTC-019](../../../../define-requirements/FR/FR-MTC-019-reminder-calendar-frame-rollover.md), [NFR-MTC-002](../../../../define-requirements/NFR/NFR-MTC-002-prompt-budget-and-token-ceiling.md), [NFR-MTC-011](../../../../define-requirements/NFR/NFR-MTC-011-kv-prefix-stability.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
The feature's closing acceptance: the bhajan anchor dialogue end to end at the
router seam (degenerate request, probe, alias answer, deterministic merge, real
execution), both Phase-1 guard pins (no prompt change; reminder/calendar
untouched), the pinned regression surfaces, and the end-of-feature full-suite
run recorded against the known baseline. This task produces the acceptance
evidence the T-142 index cites.

## Acceptance criteria

```gherkin
Feature: End-to-end acceptance and regression sweep

  Scenario: The anchor dialogue completes with no model available
    Given the router wired as in production and the interpreter double recording calls
    When the degenerate bhajan request is routed, the probe is spoken, the primary alias is answered and the merged command executes
    Then the executed music query is the catalog's canonical query
    And the interpreter was never called and no network egress occurred

  Scenario: Reminder and calendar turns never open a frame
    Given the reminder and calendar suites
    When each utterance is routed
    Then behaviour is identical to the shipped baseline and no frame opens (FR-MTC-019 Phase-1 guard)

  Scenario: The Phase 2 clause is absent from the shipped prompts
    Given the shipped prompt files and their digests
    When the prompt identity pins run
    Then zero prompt-file edits exist in the feature diff and every digest matches (FR-MTC-018 Phase-1 guard)
    And the rendered baseline and ceiling pins are green

  Scenario: The pinned regression surfaces stay green
    Given the golden music digest, the golden corpus suite, the provider suites and the confirmation suites
    When the sweep runs
    Then every surface is green with no behavioural diffs

  Scenario: The full-suite run records no new failures
    Given the recorded baseline of ~21 pre-existing failures on master (unrelated suites)
    When the full unit suite runs at the end of the feature
    Then the failure set is a subset of the baseline
    And the run record is attached for the final review
```

## Implementation notes
- The anchor is the constitution's end-to-end example: "भजन बजाऊ" →
  probe → "दुर्गा" → "durga bhajan" → playback request; drive it through the
  router seam with production-shaped wiring (non-nil seam), the catalog, and
  the existing playback helper double.
- **E7 second half (prompt pins):** assert the feature diff touches no prompt
  file, the prompt digests (`18003ddd…`, `bd47910d…`), the 2_506 baseline and
  the 3_000 ceiling pins all match — this is the Phase-1 guard for FR-MTC-018
  and the NFR-MTC-002/NFR-MTC-011 pin.
- **FR-MTC-019 Phase-1 guard:** reminder/calendar/medication utterances route
  exactly as shipped; no frame opens; no changed line in those suites.
- Regression pins to keep green: golden music digest `fb14012e…`,
  `GoldenCorpusTests`, the Spotify provider suites, the confirmation suites,
  the pinned-surface guard suite.
- Full-suite discipline: run the full unit suite ONCE at the end of the
  feature; compare against the baseline; the acceptance bar is "no new
  failures", never a fully green suite (the baseline is pre-existing and out
  of scope for this feature).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueAcceptanceTests` + pinned suites)
- [ ] Anchor dialogue green end to end with zero interpreter calls
- [ ] Phase-1 guards pinned: zero prompt-file edits and digests/ceiling green (FR-MTC-018); reminder/calendar unchanged (FR-MTC-019)
- [ ] Full-suite run executed once and recorded: failure set is a subset of the ~21 pre-existing baseline failures
- [ ] Sweep record attached for the T-142 evidence index
