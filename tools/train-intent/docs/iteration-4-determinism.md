# Iteration-4 determinism engineering (bake-off 2026-09-09)

What iteration-3 proved (see commit 0f537cd) is that **single-run deltas
were lottery noise, not signal**:

1. `build_dataset.py` re-drew ~1,000 of 2,827 rows between consecutive
   builds. The rng(seed) whole-pool shuffle + slice made every draw a
   function of pool *length*: each `rng.shuffle` consumed a stream whose
   position depended on every earlier shuffle's size, so any pool growth
   (a new gen/noise run) silently swapped old rows for other old rows.
2. Same-data retrains did not reproduce (0.765/0.909/1.0 vs the original
   0.824/0.800/1.0 on identical bytes). Training ran on transformers'
   default seed 42, applied only at Trainer construction — **after** peft
   had drawn LoRA init from an *unseeded* torch RNG — and bf16/bnb
   matmuls added their own run-to-run flips of ±1-2 golden rows.

Iteration-4 fixes all three layers: an anchored dataset draw, a seeded +
deterministic trainer, and a best-of-3 gate driver.

## What changed

| File | Change |
|---|---|
| `config.yaml` | `training.seed: 42` (run-seed root), `training.deterministic: hard` |
| `src/build_dataset.py` | anchored, content-addressed draw (below) |
| `src/train_qlora.py` | seeds every RNG before any model/adapter init; `--seed-offset`; deterministic-mode enforcement with a startup probe; `TrainingArguments(seed, data_seed)` |
| `src/eval_golden_k.py` | NEW — standalone resumable k-run train→export→eval driver |
| `data/train.jsonl`, `data/valid.jsonl` | rebuilt by the new anchored draw (new canonical bytes over the committed pool) |

### Anchored dataset draw (`build_dataset.py`)

Every selection (dedupe winner, per-bucket mixture take, train/valid
split) now ranks rows by `draw_key(row, seed, namespace)` — a 64-bit
blake2b over `mixture.seed | namespace | full row JSON`. No RNG object
exists anywhere in the file.

- **Identical inputs → byte-identical outputs.** Verified: two builds of
  the committed pool hash identically (evidence below).
- **Append-only pool growth moves only the boundary.** A row's key is a
  pure function of its own bytes, so adding rows (the normal mode —
  gen_teacher/noise are append-only) can only push genuinely-new rows
  across the take boundary; old rows are never re-drawn out in favor of
  other old rows. Iteration-3 measured ~1000/2827 rows churned (~35%)
  when the pool grew between builds. Measured here under the identical
  growth scenario: the anchored draw churns 31/2827 rows (1.1%) vs the
  old draw's 958/2827 (33.9%) — and the 31 are exactly the new rows
  entering training, not lottery (evidence below).

### Seeded + deterministic trainer (`train_qlora.py`)

- Run seed = `training.seed + --seed-offset` (the k-run driver passes
  offsets 0..k-1 → seeds 42, 43, 44). `random`/`numpy`/`torch`/`cuda`
  are all seeded **before** tokenizer/model/peft init — closing the
  unseeded-LoRA-init gap — and `TrainingArguments(seed, data_seed)`
  makes dataloader shuffling (and transformers' internal re-seed at
  Trainer construction) a pure function of the run seed.
- `training.deterministic`:
  - `hard` (default): `torch.use_deterministic_algorithms(True)` plus
    `allow_{fp16,bf16}_reduced_precision_reduction=False`,
    `cudnn.deterministic=True`, `cudnn.benchmark=False`,
    `CUBLAS_WORKSPACE_CONFIG=":4096:8"`. Because deterministic mode
    raises at *op* time (which would abort a run hours in), a startup
    probe runs one bf16 matmul and one bitsandbytes 4-bit linear
    forward+backward right after the GPU-free gate. If the probe raises,
    the run **auto-downgrades to soft** with a loud log line rather than
    dying mid-run.
  - `soft`: cudnn flags + deterministic cublas reductions, nothing ever
    raises. Chosen if the probe shows bnb can't honor hard mode.
  - `off`: seeds only (legacy comparison; not recommended).
- The effective mode is printed as `[train] seed=42 determinism=hard`
  and picked up by the driver, so a bake-off table shows when runs used
  different modes.

## Residual nondeterminism (honest list)

1. **bitsandbytes kernels are outside torch's deterministic system.**
   `use_deterministic_algorithms` only governs ops torch implements;
   bnb's fused 4-bit matmul kernels neither raise nor guarantee
   reproducibility. The startup probe detects a *raise* (torch-op
   incompatibility) but cannot detect silent bnb kernel variance. Hard
   mode therefore bounds but does not eliminate run-to-run variance —
   this is exactly why gating is best-of-3, not single-run.
2. **bf16 GEMM choice in soft mode.** cublasLt may pick different
   algorithms run to run; disabling reduced-precision reductions removes
   one variance class but not all. (In hard mode torch takes the
   deterministic algorithm path.)
3. **Mid-run interruption.** transformers v5 does not reseed the sampler
   per epoch from a fixed generator, so a run that was interrupted and
   resumed continues its own trajectory but is not byte-equal to what an
   uninterrupted run of the same seed would have produced (epoch-boundary
   shuffles draw from process RNG state). Uninterrupted fresh runs of the
   same seed are reproducible; the driver's per-run dirs/artifacts keep
   runs isolated either way.
4. **CUDA-version drift.** Determinism holds per torch/cublas/bnb build;
   changing any of them can change results even at the same seed. Every
   run's env is the suite venv, and `export_history.tsv` records the
   llama.cpp SHA — record torch/bnb versions in the bake-off log too
   (trainer_state.json records args; add `pip freeze` output if you want
   full provenance).

5. **Hard mode has never actually engaged on this box** (found 2026-09-13,
   during the Phase-2 student run). `_probe_hard_determinism` sets
   `requires_grad` on a `Linear4bit` weight to prove a 4-bit linear can
   backprop under `use_deterministic_algorithms`; bnb stores that weight
   in an integer dtype, so the call raises *"only Tensors of floating
   point dtype can require gradients"* — a probe bug, not a determinism
   verdict — and the probe reports the op family as incompatible. Every
   training log to date (gemma s42; qwen s42/s43/s44; qwen4b
   s42/s43/s44; the Phase-2 student) reads `deterministic=soft`, so all
   published numbers are soft-mode numbers and stay mutually comparable.
   Fixing the probe would flip the effective mode mid-experiment, so the
   fix is deliberately deferred to a bake-off boundary; until then items
   1-2 are the governing variance model.

## Verified evidence (CPU-only, no GPU used)

Measured in a CPU sandbox (`/tmp/dtest`, copies of the committed pool;
no GPU touched):

```text
identical-input rebuild, both algorithms: byte-identical train+valid
  (old sha256 489e9214…, anchored 4d50b468… — equal across two runs each)

growth-stability test: +500 synthetic teacher rows appended (+2.8% pool
growth, ~1 future gen run):
  old rng-shuffle draw : 958 of 2827 rows changed (33.9%)
  anchored draw        :  31 of 2827 rows changed ( 1.1%)
```

The anchored 31 are exactly the genuinely-new rows admitted across the
two clean takes' boundaries plus the split rows their admission
displaced — zero old-for-old lottery churn. The old draw's 958 included
~927 previously-selected-old rows evicted in favor of *other* old rows
(only ~31 of the entrants were actually new data) — that is the
iteration-3 ~1000-row churn reproduced and eliminated.

Reproduce the test: `python /tmp/dtest/draw_test.py` after rebuilding
the sandbox, or simply rebuild twice over the committed pool and
`sha256sum data/train.jsonl data/valid.jsonl` both times — identical.

### One-time dataset rebase (read before comparing to iteration-3)

The new canonical bytes (this commit) replace iteration-3's canonical,
and the two differ by 2129/2827 rows (75.3%) — the rng-shuffle ordering
of the old draw selects a *different* subset of the same pool than the
content-addressed ordering does. This is a one-time, deliberate rebase
on the same 60/25/15 mixture over the same committed pool (no pool
file changed; stt_noise/gen_teacher outputs untouched), and it is the
last time dataset membership can change: from here on, builds of the
committed pool are byte-identical (evidence above) and pool growth
moves only the boundary rows. Compare iteration-4 k-run results to
future iterations on identical data bytes; do NOT compare them to the
iteration-2/3 single runs on the old canonical as if the data were
unchanged — the data changed once, now, on purpose.

## Running the k=3 bake-off (after ASR v6 frees the GPU)

One base at a time, ~6-7 h each (3 × ~90 min train + export + eval; the
driver waits for the GPU itself, so it can be launched immediately):

```bash
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
# qwen leg:
nohup .venv/bin/python src/eval_golden_k.py --base qwen --k 3 \
  > logs/krun_qwen_$(date +%Y%m%d_%H%M%S).log 2>&1 </dev/null &
# gemma leg (only after qwen's 3 runs finish — never co-run two GPU legs):
nohup .venv/bin/python src/eval_golden_k.py --base gemma --k 3 \
  > logs/krun_gemma_$(date +%Y%m%d_%H%M%S).log 2>&1 </dev/null &
```

The driver refuses to start a train leg while any foreign process holds
>500 MiB of GPU (same gate as `queue_bakeoff.sh`; `--no-wait` turns the
wait into an abort). Export and eval are CPU-only and never wait.

Kill and re-run freely — the driver resumes (state in
`eval/krun_state_<base>.json`; a half-finished train resumes from its
own checkpoint; export skips completed steps; only a run with no
recorded eval result re-evals). `--fresh` wipes a base's runs and starts
genuinely new trajectories. `--dry-run` prints the plan and touches
nothing.

Ship verdict (user decision): **PASS iff any of the k runs clears every
gate** — the driver exits 0 exactly then, prints the per-run table
(metrics + determinism mode), the mean row, and the best-of-k line, and
appends one `results.csv` row per run (`qwen-s42`, `qwen-s43`, …).

Compare across iterations on the best-of-3 column only; a single run's
row is still ±1-2 golden rows of noise.
