# On-device interpret-latency protocol + report template (spec §10)

**Status: UNMEASURED.** No phone is attached to this repo's dev/CI box.
Device builds are T-037's; this document is the protocol that fills the
template below. Every latency/accuracy cell stays `UNMEASURED` until a
measurements file collected on real hardware is scored by
`tools/train-intent/src/measure_device.py`. Do not fill a cell from a
simulator, a desktop mock, or an estimate — the §10 gate is
*oldest supported device*, real STT text, real build.

Gate (spec §10): interpret latency **p50 ≤ 1000 ms, p95 ≤ 2000 ms** on the
oldest supported device. RAM is recorded for observability only; §10 has no
RAM gate.

Harness contract: `src/measure_device.py` appends one evidence row per run to
`eval/device/measurements.csv`. Percentiles are nearest-rank over all
replayed rows. Exit codes: **0** = gates passed on a complete run (or on an
explicit `--allow-partial` run, recorded as `partial=true`), **1** = latency
gate failed, **2** = input/validation error (no/bad data, incomplete
coverage, unknown ids, no mode selected).

A §10 verdict requires `--prompts eval/device/prompts.jsonl` and **every
prompt in both passes**; a partial run is an input error unless
`--allow-partial` is passed explicitly, and such a run is never a ship
verdict. The evidence CSV persists the coverage and per-pass numbers
(`partial`, `prompt_count`, `cold_*`, `warm_*`), not just the aggregate.

---

## 1. Protocol

- Device: **oldest supported iPhone** (record model + OS below) — the gate's
  device, not the newest phone in the drawer.
- Build: the release-shaped build under review (record git SHA + build number).
- Prompt set: `eval/device/prompts.jsonl`, emitted deterministically from the
  held-out corpus (default: first 100 utterances, id + utterance, no gold
  labels):
  `python3 src/measure_device.py --emit-prompts eval/device/prompts.jsonl`
- Passes:
  - **cold** — first interpret after app launch (model load included)
  - **warm** — steady-state interprets with the model resident
  - one row per utterance per pass; a pass is valid only if all prompts ran
- Thermal/battery: record whether the device was charging and cool; a hot
  device throttles and inflates p95.
- Repeat the whole collection on 3 separate launches; score each run and keep
  all three evidence rows (run-to-run spread is part of the report).

## 2. Exact commands (iOS)

```bash
# --- once: emit the prompt set (repo checkout, no device needed) -----------
cd tools/train-intent
python3 src/measure_device.py --emit-prompts eval/device/prompts.jsonl

# --- build + install + launch on the connected iPhone ---------------------
# (builds are T-037's; canonical CLI path, no Xcode GUI needed)
cd ../../ios
./device-install.sh                     # or: ./device-install.sh console

# --- push the prompts into the app's container ----------------------------
DEVICE_ID="$(xcrun devicectl list devices | awk '/available \(paired\)|connected/ {print $3; exit}')"
xcrun devicectl device copy to --device "$DEVICE_ID" \
  --source ../tools/train-intent/eval/device/prompts.jsonl \
  --destination Documents/device-eval/prompts.jsonl \
  --domain-type appDataContainer --domain-identifier com.elderlyassistant.app

# --- run the on-device eval (app debug harness) and stream its console -----
# Each completed interpret must print ONE line:
#   {"id": "<prompt id>", "pass": "cold|warm", "latency_ms": <float>,
#    "peak_rss_mb": <float|null>}
xcrun devicectl device process launch --console --device "$DEVICE_ID" \
  com.elderlyassistant.app | tee /tmp/device-console.log

# --- pull the measurements file the app wrote ------------------------------
xcrun devicectl device copy from --device "$DEVICE_ID" \
  --source Documents/device-eval/measurements_ios.jsonl \
  --destination eval/device/measurements_ios.jsonl \
  --domain-type appDataContainer --domain-identifier com.elderlyassistant.app

# --- score + append evidence (exit 0 = gate passed) ------------------------
cd ../tools/train-intent
python3 src/measure_device.py --replay eval/device/measurements_ios.jsonl \
  --prompts eval/device/prompts.jsonl \
  --platform ios --device-model "iPhone <model>" --os "iOS <version>" \
  --build "<git sha> (<build>)"      # exit 0 = §10 verdict; 1 = gate failed; 2 = bad input
```

The prompt set is the committed 100-utterance file (`--min-prompts 100`
default); collecting fewer prompts, or missing any prompt in either pass,
exits 2 rather than passing on a partial sample.

Android: no Android client exists in this repository — mark Android rows
`N/A (no client)` rather than UNMEASURED.

## 3. Latency table (fill per run)

Every row below needs `partial=false` in `measurements.csv` (a `partial=true`
row is an explicit override and cannot support a §10 verdict).

| Run | Device | OS | Build | n | cold p50/p95 (ms) | warm p50/p95 (ms) | all p50/p95 (ms) | peak RSS (MB) | Gate |
|---|---|---|---|---|---|---|---|---|---|
| 1 | UNMEASURED | UNMEASURED | UNMEASURED | 0 | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | NOT RUN |
| 2 | UNMEASURED | UNMEASURED | UNMEASURED | 0 | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | NOT RUN |
| 3 | UNMEASURED | UNMEASURED | UNMEASURED | 0 | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | NOT RUN |

Evidence rows live in `eval/device/measurements.csv` (header only until a
device runs this protocol).

## 4. Accuracy regression table (same corpus revision, same run)

Fill every row with a real harness run at the **same corpus revision** (the
sha256 in the `--manifest-out` sidecar is the revision marker). Encoder rows
need the ONNX/GGUF artifact; until it exists they stay UNMEASURED.

| Metric | Gate (§10) | Encoder (this ship) | Incumbent GGUF brain | Gemini baseline | Source |
|---|---|---|---|---|---|
| Closed-intent accuracy | ≥ 0.95 | UNMEASURED | UNMEASURED | UNMEASURED | `eval_golden.py` stdout |
| Contact slot F1 | ≥ 0.90 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Time slot F1 | ≥ 0.90 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Emergency recall (corpus) | = 1.00 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Emergency recall (near-miss) | ≥ 0.98 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Side-effect precision | ≥ 0.97 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Abstention precision | ≥ 0.90 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Calibration (max Δ per bucket) | ≤ 0.10 | UNMEASURED | UNMEASURED | UNMEASURED | " |
| Δ vs Gemini (closed intents) | ≥ −0.03 | UNMEASURED | UNMEASURED | (baseline) | `--gemini-label` |
| Interpret latency p50/p95 | ≤ 1000 / 2000 ms | UNMEASURED | UNMEASURED | n/a (network) | §3 above |

Commands that fill the non-device rows (run from `tools/train-intent/`; the
Gemini run must land in `eval/results.csv` first so the gap gate has a
baseline):

```bash
python3 src/eval_golden.py --backend gemini --label gemini-<rev>
python3 src/eval_golden.py --backend gguf  --model-path <incumbent.gguf> --label gguf-<rev>
python3 src/eval_golden.py --backend onnx  --model-path <encoder dir> --onnx-path <encoder/model_int8.onnx> --label encoder-<rev>
```

## 5. Verdict block

- [ ] All accuracy gates pass at this corpus revision (`gates_failed` column
      of the run's `results.csv` row reads `none`).
- [ ] Latency gates pass on the oldest supported device (3 runs).
- [ ] No row above is UNMEASURED.
- [ ] Reviewer sign-off recorded.

**GO / NO-GO: NO-GO — UNMEASURED** (harness ready; no device data yet).

---
Notes for the device-build owner (T-037):

- `src/measure_device.py --replay` is the only scoring path — hand-timed
  numbers pasted into this table carry no evidence row and are not accepted.
- `eval/device/prompts.jsonl` is derived from the held-out corpus; it is
  refused as training input by `build_dataset.py`'s leak guard (same
  normalized utterances), so pushing it to a device is safe.
- If the on-device harness cannot emit `peak_rss_mb`, omit the field; it is
  not a gate.
