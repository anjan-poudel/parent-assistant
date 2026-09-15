# T-069: Evidence Pack and Gap Register (every claim traceable to a measurement)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** `tools/train-intent/eval/evidence_pack.json` and its rendered view; the check that keeps the pack and the harness in step; the gap register for the dimensions the current corpus cannot measure
- **Agent:** dev (with reviewer sign-off on the rendered view)
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-065](T-065-harness-robustness-gates.md) (the gate ids, thresholds and fixture keys the pack records), [T-066](T-066-accent-noise-pass-extension.md) (the SNR levels and articulation cells), [T-067](T-067-gate-failure-verification.md) (the failing fixture ids — a claim of measurement is not complete without a fixture that proves the gate trips)
- **Blocks:** —
- **Requirements:** FR-008, FR-009, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §7.8 (the evidence-pack table, the gap register GAP-1…GAP-4, and the two failure modes it names); the standing rule that every robustness claim maps to a measured gate with a named revision, a justified threshold, a failing fixture and the exact rows

## Description

The design states a contract with the harness: **every robustness claim maps to a row of the evidence pack, and any claim that does not map is a gap or a defect** (§7.8). This task turns that sentence into an artifact and a check, because a table maintained by hand drifts the first time someone re-tunes a threshold, and the drift is invisible in exactly the direction that matters — the docs stay green while the harness stops enforcing.

**1. The pack.** A machine-generated `eval/evidence_pack.json` with one record per dimension:

| Field | Content | Source of truth |
|---|---|---|
| `dimension` | word order, dialect, additive noise, clipped tail, reduced articulation, accent | the design's five measured dimensions plus the gap |
| `mechanism` | what physically produced the rows (operator family, variant banks, noise mixed to a target SNR, elision, the rate/tempo/quality cell grid, multi-voice rendering) | T-064/T-066 records, the fixtures' own keys |
| `gate_id` | the key in `config.yaml:gates` | `config.yaml` |
| `threshold` | the value **and** its justification | `config.yaml`'s inline comment; the design §7 |
| `fixture_id` + `revision` | the fixture and its `fixture_id@<sha8>` tag | the fixture file, hashed at pack-build time |
| `row_counts` | authored rows, paired rows, scored rows, and excluded rows split by reason (`resolver_blocked`, `truncation`) | the harness manifest |
| `failing_fixture` | the sweep fixture that trips this gate in isolation | `eval/fixtures/`, T-067 |
| `measurable` | yes, or the `GAP-<n>` id it belongs to | T-062's determinations and the mechanism's existence |

**2. The gap register.** GAP-1…GAP-4 as first-class records, not prose: the dimension each bounds, why it cannot be measured today with the code or data citation that shows it, and **the data needed to close it**. A gap that is closed later (voices acquired, noise corpus licensed) moves out of the register and into the measured table in the same commit that wires its gate — closing a gap without wiring the gate is not a closure.

**3. The check.** The pack is only worth having if it is enforced:

- **no orphan claim:** every gate id present in `config.yaml:gates` has a pack record, and every pack record names a gate that exists. A gate added, renamed or removed without the pack moving fails the test.
- **no stale threshold:** the pack's `threshold` is read from `config.yaml` at build time, never transcribed, so a re-tune cannot leave the pack quoting the old number — and the *justification* is required to be non-empty, so a re-tune that drops the reasoning is visible as a diff.
- **no unproven claim:** `failing_fixture` must name a file that exists **and** is referenced by the sweep script. A dimension whose gate is wired but whose sweep fixture is absent cannot be recorded as measured — that is T-067's discipline, made a build-time property.
- **no false green:** a record whose `measurable` is a `GAP-<n>` is rendered as a gap with its data requirement, and the rendered view is checked to contain no line that presents it as a passing gate. Every gate line carries `fixture_id@<sha8>`, and a record whose fixture hash does not match the file on disk fails.
- **the numbers are the harness's:** `row_counts` comes from the run manifest, not from the design doc's targets. Where the achieved count is below the design's target (§7.6), the pack says so rather than quoting the target as though it were achieved.

**4. The rendered view.** A short human-readable rendering (a table produced from the JSON, checked in, regenerated rather than hand-edited) so a reader can see dimension → mechanism → gate → threshold → fixture → rows → failing fixture → measurable without opening six files. The two failure modes §7.8 names are carried into the rendering itself as standing notes: **a sweep fixture passing proves the gate works, not that the model is robust** (the number comes from the measurement fixture and nowhere else), and **an unwired gate is never rendered green.**

**The limits, stated in the artifact itself.** Every row's claim is bounded by its fixture and its revision: a gate measured on `order_permutation@<sha8>` says nothing about a fixture whose bytes have changed since, and the pack records the hash so the bound is checkable rather than rhetorical. The noise rows are limited to *stationary additive white noise* (GAP-1) and the slur rows are a *stress proxy*, never a dysarthria result (GAP-2); those qualifications are fields in the record, not footnotes, because a qualification that lives in prose beside a table is the first thing a summary drops.

**Explicitly out of scope.** No gate logic, threshold or fixture content ([T-065](T-065-harness-robustness-gates.md), [T-064](T-064-order-dialect-authoring.md), [T-066](T-066-accent-noise-pass-extension.md)); no sweep fixture ([T-067](T-067-gate-failure-verification.md)); no new measurement — this task **records** measurements the other tasks produce and fails when they do not exist. No user-facing or marketing copy, and no claim about the product's dialect or accent support beyond the per-slice, revision-bound statements the fixtures license.

## Acceptance criteria

```gherkin
Feature: Evidence pack and gap register

  Scenario: Every gate is represented and every record names a real gate
    Given config.yaml:gates after T-065 wires the robustness family
    When eval/evidence_pack.json is built
    Then every gate id in the config has exactly one record, and every record's gate_id exists in the config
    And adding, renaming, re-thresholding or removing a gate without the pack moving fails the check rather than passing silently

  Scenario: Thresholds are read from the config and carry their justification
    Given each gate's value and its inline justification comment in config.yaml
    When the pack is built
    Then each record's threshold is read from the config rather than transcribed, and a re-tuned value appears in the pack with no manual edit
    And a gate whose justification is empty or removed fails the check, so a threshold cannot be changed without the reasoning moving with it

  Scenario: A claimed measurement must carry a fixture that can fail and a revision
    Given the fixture files under eval/ and the sweep fixtures under eval/fixtures/
    When a record is written
    Then fixture_id and revision (fixture_id@<sha8>) are recorded and the hash matches the file on disk, and a mismatch fails
    And failing_fixture names a file that exists and is referenced by run_fixture_sweep.sh; a gate whose sweep fixture is missing cannot be recorded as measured

  Scenario: Unmeasurable dimensions are gaps with data requirements, never green
    Given GAP-1 (real-world noise), GAP-2 (real slurred/elder speech), GAP-3 (Nepali voices) and GAP-4 (dialect rows)
    When the pack and the rendered view are produced
    Then each gap names the dimension it bounds, why it cannot be measured today with its code or data citation, and the data needed to close it
    And the accent record renders as GAP-3 with its data requirement, and the rendered view contains no line presenting an unwired gate as passing
    And closing a gap requires wiring its gate in the same change; a gap removed without a wired gate fails the check

  Scenario: The numbers come from the harness, not from the design's targets
    Given the design's sizing targets (order, clipped tail and the moderate noise/articulation cells ≥800 paired rows; dialect and the remaining levels/cells ≥300)
    When row_counts are recorded
    Then authored, paired, scored and excluded counts come from the run manifest, with exclusions split by reason (resolver_blocked, truncation)
    And where an achieved count falls below its target the pack states the shortfall and the resolution it costs that gate, rather than quoting the target as achieved

  Scenario: The qualifications travel with the numbers
    Given that the noise mechanism is stationary additive white noise (GAP-1) and the slur grid is a synthetic proxy (GAP-2)
    When the record and the rendered view are written
    Then the noise record carries its white-noise limitation and the articulation record carries its proxy status as fields in the record
    And the rendered view carries the two standing notes: a sweep fixture passing proves the gate works and not that the model is robust, and an unwired gate is never rendered green
    And no record or rendering states or implies dialect or accent coverage beyond the slices and fixtures actually measured
```

## Implementation notes

- Read before building: `tools/train-intent/config.yaml:56-69` (the existing `gates` block and its inline-comment style — the pack's threshold source); `tools/train-intent/src/eval_golden.py:821-829` (the `gates` dict), `:840-846` (the append-only `results.csv` schema), `:848-893` (the manifest the row counts come from), `:895-898` (the exit); `tools/train-intent/eval/fixtures/run_fixture_sweep.sh` (the sweep fixtures the `failing_fixture` field must point at, and the contract that each exits 1 with exactly one gate); the design doc §7.6 (sizing targets), §7.8 (the pack, the gap register, the two failure modes); `specs/TG-11-notes.md` (the recorded decisions this pack formalises).
- Build the pack from the harness's own outputs. A pack that is assembled from prose is a second source of truth and will disagree with the first; the check that matters is `pack == f(config, fixtures, manifest)`, and it is only meaningful if every field is derived.
- Keep the JSON the artifact and the rendered view a projection of it. The rendering is regenerated, never edited, so a discrepancy between them is a build failure rather than a copy-editing question.
- `threshold` is read, `justification` is required. Those two rules together are what stop a silent re-tune: the number cannot go stale because it is not stored, and the reasoning cannot be dropped because an empty justification fails.
- Where a task in the group has not yet run, the pack records the dimension as **not yet measured** with the task that will measure it — never as passing and never by leaving the row out. An absent row is how a dimension disappears from review.
- The fixture hash recorded is a short prefix (`<sha8>`), consistent with the existing `label@<corpus sha8>` binding and with NFR-016; no full 40-character digest is written anywhere.
- This task produces no measurement of its own. If a record cannot be filled because the underlying task did not produce its artifact, that is a finding against that task, and the pack says which one.

## Definition of done
- [ ] `eval/evidence_pack.json` with one record per dimension carrying dimension, mechanism, gate_id, threshold with justification, fixture id and revision, row counts, failing fixture and measurability
- [ ] Gap register as records for GAP-1…GAP-4, each with its bounded dimension, the citation showing why it cannot be measured, and the data needed to close it
- [ ] Check fails when a gate is added, renamed, re-thresholded or removed without the pack moving
- [ ] Check fails on a stale fixture hash, a missing sweep fixture, an empty justification, or a gap closed without a wired gate
- [ ] Row counts taken from the manifest, exclusions split by reason, shortfalls against the §7.6 targets stated rather than hidden
- [ ] Qualifications (white noise only, slur proxy) carried as record fields; the two standing notes present in the rendered view
- [ ] Rendered view generated, never hand-edited; no line presents an unwired gate as passing
- [ ] No measurement invented by this task; any unfillable record traced to the task that owes it
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
