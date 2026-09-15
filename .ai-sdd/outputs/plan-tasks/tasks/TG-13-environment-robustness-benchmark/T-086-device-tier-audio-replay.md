# T-086: Device Tier — Audio Replay Extension of the T-038 Harness

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/src/measure_device.py` (extended — audio-replay mode), `tools/train-intent/eval/env/device-protocol.md` (new — the collection protocol), `tools/train-intent/eval/env/device/` (new — the pushed manifest and the pulled results), the iOS debug replay harness (new, in the app's benchmark/debug build path)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-082](T-082-acoustic-transport-harness.md), [T-037-a](../../TG-08-nepali-intent-encoder/T-037-runtime-integration/T-037-a-ios.md)
- **Blocks:** [T-088](T-088-full-benchmark-run.md)
- **Requirements:** FR-005, FR-008, FR-009, NFR-001, NFR-002, NFR-015, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §6.7 (device tier); `tools/train-intent/eval/device/device-eval-protocol.md` (the protocol this extends), `src/measure_device.py:96-129`, `:166-194` (the contract and ledger it extends)

## Description

Measure the same cells on the real device, through the real recognizer, so the benchmark's CPU-chain numbers are not the whole claim.

**Why this tier exists and cannot be replaced by the CPU chain.** The CPU chain uses whisper.cpp's GGML model (`stt_noise.py:50-63`); a device may run a different recognizer entirely — WhisperKit on the ANE is preferred on device and whisper.cpp is the fallback (`ios/ElderlyAssistant/Services/Voice/OnDeviceSTTSelection.swift:20-42`), the capture path may pass through the default-OFF spectral-gate denoiser (`NoiseSuppressor.swift:92-97`; `SpectralGateDenoiser.swift:26`), and the router applies its own bands (`IntentRouter.swift:49-57`, `:316-319`). A benchmark that skipped the device would be measuring a pipeline nobody ships.

**The shipped device half does not exist yet, and this task builds it.** The T-038 protocol documents the whole collection procedure — push the prompt set with `devicectl`, launch with `--console`, pull `measurements_ios.jsonl`, score with `measure_device.py --replay` (`device-eval-protocol.md:52-93`) — and the iOS tree contains no implementation of the app-side harness that writes that file. `eval/device/measurements.csv` is header-only for the same reason (`:106-107`). So this task is not "wire up an existing harness"; it builds the app-side replay loop **and** extends the scorer, and its notes must say which parts ran on hardware and which did not.

**Audio replay, not synthesized prompts.** The device harness reads wav files from its container (rendered by T-082 for the device cells, pushed alongside a manifest), feeds each through the *capture* path — the same `VoicePipeline.feedCapture` choke point the denoiser sits behind (`docs/research-sections/noise-filter.md:408-433`) — and records one row per utterance: the id, the condition, the interpreted command (action and slots), the confidence, and the latency. The scorer then evaluates `command_correct` per cell exactly as the CPU tier does, so the two tiers are comparable row-for-row.

**Only fixture audio, never user audio.** The harness refuses to start unless it was launched with a benchmark manifest whose every id resolves in the pushed set, and the container it reads from is the benchmark directory, not the app's capture store. The pulled file carries ids, conditions, the interpreted command and confidence — **no raw transcript text and no user audio** (NFR-015/NFR-016). That is stated as a hard rule in the protocol, and the pull step's destination is a benchmark directory, not a general export path.

**The denoiser is a declared axis, not a hidden variable.** Each run records whether the noise suppressor was enabled, since the shipped default is OFF and the ablation is genuinely informative (the cell the gate cannot help with is competing speech). A run that does not state it cannot be compared with one that does.

**Latency is measured on the same rows, under the existing contract.** The T-038 latency gate (p50 ≤ 1000 ms, p95 ≤ 2000 ms, coverage rules, `partial` semantics, exit codes) is unchanged and applies to the device rows this tier produces; the environment tier adds per-cell reporting on top, it does not relax the protocol.

**Out of scope.** No change to the T-038 device protocol's existing gates, prompt-set semantics or CSV schema (additive columns only); no model training; no iOS production behaviour change — the replay harness lives in the benchmark/debug path; no Android (there is no client — the protocol already says `N/A (no client)`, `device-eval-protocol.md:92-93`).

## Acceptance criteria

```gherkin
Feature: Device audio-replay tier

  Scenario: The app-side replay harness runs the pushed fixture audio through the shipped capture path
    Given T-082's rendered device cells and their manifest are pushed into the app's benchmark directory
    When the debug harness replays them
    Then each wav enters the capture path at the same choke point the shipped pipeline uses, and one row is written per utterance carrying id, condition, action, slots, confidence and latency
    And the run records whether the noise suppressor was enabled, and rows carry that flag

  Scenario: The harness refuses anything that is not a benchmark fixture
    Given NFR-015 (no personal data for cloud AI processing) and NFR-016 (no PII in logs)
    When the harness launches
    Then it refuses to start unless every id in the launch manifest resolves in the pushed fixture set
    And the pulled results carry ids, conditions, interpreted commands, confidences and timings only — no raw transcript text and no user audio — and the benchmark directory is the only container path read

  Scenario: Scoring reuses the existing device contract, additively
    Given measure_device.py validates rows, enforces coverage policy, computes nearest-rank percentiles and appends one evidence row per run (measure_device.py:96-129, :166-194)
    When the environment device rows are scored
    Then the existing latency gates, coverage rules, partial semantics and exit codes are unchanged
    And the environment columns (condition, per-cell command correctness) are additive to the CSV and the ledger refuses to append under a mismatched header

  Scenario: The device tier measures a pipeline the CPU tier does not
    Given the device may run WhisperKit on the ANE rather than whisper.cpp (OnDeviceSTTSelection.swift:20-42), through the capture path with the spectral-gate denoiser available (NoiseSuppressor.swift:92-97)
    When a device run is reported
    Then the report names the recognizer path actually exercised and the denoiser state
    And CPU-tier and device-tier numbers are never merged into one figure, and a divergence between them is reported as a finding

  Scenario: The report distinguishes what ran on hardware from what did not
    Given no app-side device harness existed at this base and eval/device/measurements.csv is header-only
    When the device tier's notes are written
    Then every number is labelled measured-on-device or UNMEASURED, and any part of the chain that was not exercised on hardware is named as such
    And a device cell with no hardware run is SKIPPED, never inferred from the CPU tier
```

## Implementation notes

- Read `eval/device/device-eval-protocol.md` end to end before writing anything; the push/pull commands, the app container domain (`--domain-type appDataContainer --domain-identifier com.elderlyassistant.app`) and the console contract are already specified there and must be reused verbatim rather than re-derived.
- The prompt-set privacy argument in that document (`:148-155`) — the prompt file is derived from the held-out corpus and is refused as training input by the leak guard — is the same argument that licenses pushing *audio* here, and it is stronger for audio only if the harness refuses non-fixture ids. That refusal is the load-bearing check; make it a test, not a comment.
- Keep the row contract a superset of the device contract (`device-eval-protocol.md:18-24`): `id`, `pass` is not meaningful for the environment tier, so a row carries `condition` instead; if both are needed for backward compatibility, the scorer must accept the old shape unchanged.
- Water the pipeline where it is observable: `NoiseSuppressor` already emits per-utterance observability under component `noise_suppressor` (in/out RMS dBFS, suppression dB, engine name, model — `docs/research-sections/noise-filter.md:415-430`). Consume that rather than adding new instrumentation.
- The tier's cost is device time; keep the device cell list small (a handful of cells, a few hundred rows) and let the CPU tier carry breadth. State the device row count in the protocol's report table, and mark unfilled cells UNMEASURED rather than estimating them.
- This task is gated on T-037-a's build and on a physical device. If neither is available, the honest outcome is a protocol plus an UNMEASURED report — the T-038 precedent, and the scorecard must be able to say so without failing the group.

## Definition of done
- [ ] App-side replay harness implemented in the benchmark/debug path, refusing non-fixture ids, with a test for the refusal
- [ ] `measure_device.py` extended additively: environment rows scored per cell, existing gates/coverage/exit codes unchanged, ledger header refusals intact
- [ ] `eval/env/device-protocol.md` committed with exact commands, the device cell list, the denoiser-state requirement and the report tables
- [ ] A device run's pulled file contains no raw transcript and no user audio; the check is stated in the protocol and enforced in code
- [ ] The recognizer path and denoiser state are recorded per run, and CPU vs device divergences are reported rather than merged
- [ ] Every device number is labelled measured or UNMEASURED; no cell is inferred from the CPU tier
