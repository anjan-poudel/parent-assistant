# T-081: Condition Matrix & Measurement Protocol Design

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/env/protocol.md` (new — the operational protocol, in the shape of `eval/device/device-eval-protocol.md`), `tools/train-intent/eval/env/matrix.yaml` (new — the declared cells), `tools/train-intent/config.yaml` (additive `env_bench:` block: ladders, bands, gate keys)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-080](T-080-corpus-acquisition-licence-evidence.md)
- **Blocks:** [T-082](T-082-acoustic-transport-harness.md), [T-084](T-084-condition-scoring-scorecard.md), [T-086](T-086-device-tier-audio-replay.md)
- **Requirements:** FR-005, FR-008, NFR-001, NFR-002, NFR-013, NFR-015
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §3 (condition matrix), §6 (protocol), §7 (thresholds); `docs/research-sections/noise-filter.md:375-406` (the eval set and metrics this group builds and never got built)

## Description

Turn the design doc's matrix into a *testable declaration*: every cell, its parameter tuple, its sample size, its metric, its threshold, and the fixture that proves the gate trips. Nothing here is measured — this task's deliverable is the protocol a reviewer can falsify before any render exists.

**The matrix is a declaration, not a table of adjectives.** A cell is a filename-safe id plus a parameter tuple that fully determines what is rendered:

- **noise type × SNR** — the ladder crosses the noise types from T-080's ledger with {+15, +5, 0, −5} dB. The bands are assigned by the *training* band, not by taste: the STT augmentation is white noise at a uniformly random SNR in [3, 15] dB (`tools/train/src/dataset.py:26-29`, `:38-44`), so **+15 dB carries the 3-point band** (the project's equivalence band — `max_gap_vs_gemini: 0.03`, `config.yaml:63`), **+5 dB carries the 5-point band** (the categorical-perturbation band, TG-11 §7.2/§7.3), and **0 and −5 dB carry no accuracy band at all** — the fail-safe clause binds there (abstention rises, confident errors do not), for exactly the reason TG-11 states at its own 3 dB floor: gating accuracy below the training distribution measures the fixture. A real noise type at +15 dB is not white noise at +15 dB, which is why the +15 cells are the design's most informative cross-check against TG-11's gate 3 and are reported paired with it.
- **far-field / mic distance** — room impulse responses convolution at {0.3 m, 1.0 m, 3.0 m} × RT60 {0.3 s, 0.6 s, 0.9 s}, noise-free, so the axis is attributable. The clean reference is the same text without convolution.
- **channel** — handset (band-limited, telephony-shaped) and speakerphone at 1.0 m, as declared filters. The handset cell is the one TG-11 GAP-2 hands over.
- **competing speech** — one background talker at +5 dB and two overlapping talkers, from T-080's speech source where a usable one exists. This is the cell the shipped `SpectralGateDenoiser` cannot help with (stationary-noise gate only — `docs/research-sections/noise-filter.md:408-433`) and the reason the cell exists: an untested denoiser limitation is a product claim waiting to be wrong.
- **reduced articulation** — the moderate/severe cells TG-11's [T-066](../../TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md) declares as a parameter table. **TG-13 consumes that table; it does not declare a second one.**
- **text-side conditions** — the code-switched register (real supply today: 814 of 8,000 pinned rows carry `script: code_switched`) and the clipped-tail fixture, which TG-11 owns (`eval/clipped_holdout.jsonl`). TG-13 renders and scores them in the acoustic path; it authors none of them.
- **accent / voices** — the voice bank holds exactly one voice (`config.yaml:23`, `hi_IN-pratham-medium`), so per-voice scoring is **vacuous today** and the design says so instead of writing a cell that cannot fail. It becomes a cell the moment the bank holds ≥ 2 Nepali-capable voices, which is TG-11 GAP-3's condition, and the protocol records the condition rather than a placeholder.

**Crossed cells are chosen by design corners, not exhaustively, and no claim is made outside them.** A full crossing of the axes is thousands of cells and buys nothing; the protocol declares a small crossed set at the corners of the design space (e.g. the noise type with the worst axis-isolated delta × the far-field distance × the mid SNR) and states in the scorecard that non-corner combinations are **NOT CLAIMED**.

**Sample sizes come from the paired statistic, not from a round number.** For a paired difference with discordance π_d ≈ 0.10, the 95% CI half-width is ≈ 1.96·√(π_d/n): **n = 800 → 2.2 points** (adequate for a 3-point band) and **n = 300 → 3.6 points** (adequate for a 5-point band). Both figures are the ones TG-11 derives in its §7.1/§7.2, reused deliberately so the two groups' gates are comparable. A cell that cannot afford its n is demoted to a **diagnostic** (reported, not gated) and its scorecard row says `DIAGNOSTIC — not gated`; the design does not print a gate it cannot resolve.

**Metrics, defined once.** `command_correct` (action **and** resolved slot values equal gold) is the primary end-to-end metric; `stt_wer` (jiwer `wer` over the canonicalized reference and hypothesis — the canonicalization of `tools/train/src/eval_checkpoint.py:110` and its `norm()`), `closed_intent_accuracy`, per-slot F1, `abstention_precision`, `side_effect_precision`, `emergency_recall`, `confident_error_rate` and `latency_p95_ms` are the component and safety metrics. Two definitions must be pinned in the protocol because a later reader cannot recover them from the numbers: **what a "word" is** for WER in Devanagari (whitespace token after the shared canonicalization — the same convention the STT eval already uses) and **how a command is compared** (resolved slot values, not spans; the code-disposes principle from `plan.md` Risk 11).

**The scorecard and the usable-environment set are computed, not narrated.** Each gated cell emits a row; a cell is `USABLE` iff every core gate passes in it. The published claim is the matrix of `USABLE` cells with its row counts; every other cell is `NOT CLAIMED` or `FAILED`, and the three states are distinct in the output.

**The multiple-comparison hazard is handled explicitly.** With ~46 cells and a 95% per-cell interval, ~2 spurious failures are expected by chance. The protocol therefore states: the **ship verdict is a pooled gate** over the gated cells at a stated corrected level, per-cell failures are **findings** requiring one investigation and not a re-run loop, and a cell may not be dropped from the matrix because it failed.

**Delivery shape.** `eval/env/protocol.md` carries the exact commands, the tier definitions (CI / full / device), the evidence-file paths and the exit-code contract; `eval/env/matrix.yaml` carries the cells and their parameters as data, so T-082 renders from a file and T-084 gates from the same file. The exit codes continue the harness's existing contract (`0` pass, `1` gate failed, `2` input/validation error) and the two new ones the benchmark needs are spelled out rather than invented ad hoc: **`3` = SKIPPED — a required corpus or model is absent** (the tier did not score, and a skipped tier is never a pass).

## Acceptance criteria

```gherkin
Feature: Environment condition matrix and measurement protocol

  Scenario: Every cell is a declared parameter tuple with a stated band
    Given the design doc's §3 condition matrix
    When eval/env/matrix.yaml is written
    Then each cell carries an id, its axis values (noise type, SNR, distance, RT60, channel, talkers, articulation cell, script register or voice), its sample size and its gate band
    And every cell's band follows the training-band rule: 3 points at +15 dB, 5 points at +5 dB, fail-safe only at 0 and -5 dB, and the file states the rule once next to the ladder

  Scenario: Sample sizes are derived from the paired statistic
    Given a paired difference with discordance pi_d ~ 0.10 and the 95% interval half-width 1.96 * sqrt(pi_d / n)
    When a cell is assigned n = 800 or n = 300
    Then the protocol prints the resulting half-width (2.2 points and 3.6 points) beside the band it must resolve
    And a cell whose n is too small for its band is marked DIAGNOSTIC — not gated rather than gated at an unresolvable threshold

  Scenario: The below-band cells fail-safe instead of scoring accuracy
    Given the STT augmentation band is white noise at SNR 3-15 dB (tools/train/src/dataset.py:26-29)
    When the 0 dB and -5 dB cells are scored
    Then they carry the fail-safe clause (confident errors must not exceed abstentions) and no accuracy band
    And the scorecard prints their confident-error and abstention rates as numbers, not as a pass

  Scenario: The metric definitions are pinned and shared, not re-implemented
    Given STT WER is scored by tools/train/src/eval_checkpoint.py:110 over its norm() canonicalization
    When the benchmark scores WER on rendered audio
    Then the protocol names that canonicalization as the single definition, and the word-segmentation convention for Devanagari is stated in the protocol
    And command correctness is defined over resolved slot values (code-disposes), not over spans, and the definition appears verbatim in the scorecard's header

  Scenario: The accent cell is either real or declared absent
    Given the shipped voice bank holds exactly one piper voice (config.yaml:23)
    When the matrix is written
    Then no per-voice accent cell exists at this base, and the matrix records the condition that would create one (>= 2 Nepali-capable voices, TG-11 GAP-3)
    And the protocol states plainly that a one-voice per-voice gate is vacuous rather than printing a cell that cannot fail

  Scenario: The exit-code contract and the NOT CLAIMED states are declared before implementation
    Given the harness convention 0 = pass, 1 = gate failed, 2 = input error
    When the protocol defines the tier behaviour
    Then it adds 3 = SKIPPED (required corpus or model absent) and states that a skipped tier is never a pass
    And every cell is print-able in exactly one of USABLE, FAILED, DIAGNOSTIC, SKIPPED or NOT CLAIMED, with the five states distinguishable in the scorecard output, so that a cell that did not run is never read as a cell that passed
```

## Implementation notes

- Read `eval/device/device-eval-protocol.md` first and mirror its shape: status header (what is UNMEASURED and why), protocol, exact commands, tables to fill, verdict block. That document's discipline — *"Do not fill a cell from a simulator, a desktop mock, or an estimate"* (`:7-9`) — is the tone this protocol inherits.
- Gate keys go in `config.yaml` beside the existing ones (`:58-71`), read with `cfg[...]` like every other gate. Do not duplicate a threshold that already exists: the safety gates reuse `side_effect_precision: 0.97`, `emergency_recall: 1.00`, `abstention_precision: 0.90` verbatim.
- `matrix.yaml` is data. If a cell's parameters cannot be expressed as values in that file, the cell is not ready to be rendered and belongs in the design doc's open questions instead.
- The ladder choice is a reconciliation, so state it: `docs/research-sections/noise-filter.md:381-388` proposes 0/5/10/15/20 dB and the brief proposes +15/+5/0/−5 dB. The protocol adopts the brief's ladder for the gate cells and records the other as the same axis at different sample points, so the two documents do not read as a contradiction.
- Fail-closed on a missing fixture, mirroring `eval_golden.py`'s Gemini-baseline behaviour (`specs/T-038-notes.md`: *"unbound legacy rows are reported UNEVALUATED and the gate fails closed"*).
- **Do not fork TG-11's declarations.** The articulation cells, the clipped-tail fixture and the voice-bank condition are read from TG-11's paths; if they are not there yet, the cell is `SKIPPED` with the missing path printed, never a locally invented substitute.
- No render is produced by this task, no model is run, no corpus is downloaded. The deliverable is a protocol plus a data file, reviewable line by line.

## Definition of done
- [ ] `eval/env/matrix.yaml` committed: every cell with id, axis values, sample size, band and gate list
- [ ] `eval/env/protocol.md` committed: tier definitions, exact commands, metric definitions (including the Devanagari word convention and the resolved-slot command comparison), the exit-code contract including `3 = SKIPPED`, and the report/scorecard tables
- [ ] The training-band rule is stated once beside the ladder and every cell's band follows it
- [ ] Sample sizes and their CI half-widths are printed per cell, and every under-powered cell is `DIAGNOSTIC`
- [ ] The accent cell is recorded as absent with its enabling condition, not printed as a vacuous pass
- [ ] `config.yaml` carries the new gate keys additively; no existing key or threshold is changed
- [ ] No claim in the protocol names a condition without naming its corpus source, row count, metric and threshold
