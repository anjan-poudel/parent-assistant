# Nepali Whisper distillation + fine-tune — training suite

Trains a **whisper-small-class (~250 M) Devanagari Nepali model** for
on-device STT, distilling from `kiranpantha/whisper-large-v3-nepali`
(the only popular Nepali fine-tune that keeps the standard multilingual
tokenizer). Full plan: `docs/whisper-small-nepali-integration-plan.md` §8.

**Everything here is durable and resumable.** The machine can be shut
down at any point (e.g. overnight). Re-running the same command picks up
where it left off.

---

## RTX 4090 box — setup (one time)

Machine assumed per `docs/nepali-voice-stt-research.md` §12:
RTX 4090 24 GB, Ubuntu 22.04, 32 cores, 128 GB RAM, NVIDIA driver ≥ 550.

```bash
# 1. Get the code (on the 4090 box)
git clone <your-repo-url> && cd elderly-ai-assistant/tools/train

# 2. Python env
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip

# 3. CUDA deps (torch 2.4 + cu121, pinned — matches research doc §12.3)
pip install -r requirements.txt --extra-index-url https://download.pytorch.org/whl/cu121

# 4. Verify CUDA
python -c "import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))"
# → NVIDIA GeForce RTX 4090

# 5. Optional but recommended: whisper.cpp for stage 6 (GGML export only)
git clone https://github.com/ggml-org/whisper.cpp ~/whisper.cpp
cd ~/whisper.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8
export WHISPER_CPP_DIR=~/whisper.cpp     # add to ~/.bashrc
```

Tunables live in `config.yaml` (batch sizes there are sized for 24 GB;
the Whisper-small training peaks ~16 GB VRAM per the research doc).

## The pipeline

```bash
./run_stages.sh
```

Stages in order (each is individually re-runnable and resumable):

| Stage | Command | Output | Resume behaviour |
|---|---|---|---|
| 1. Data prep | `python src/data_prep.py` | `data/*.jsonl` manifests | downloads resume (`curl -C -`), extraction skip-if-exists, manifests deduped by id |
| 2. Student init | `python src/student_init.py` | `checkpoints/student-init/` | skipped if the dir exists (`--force` to rebuild) |
| 3a. Pseudo-labels | `python src/train_distill.py --pseudolabel-only` | `data/pseudolabels.jsonl` | appends; ids already labeled are skipped |
| 3b. Distillation | `python src/train_distill.py` | `checkpoints/distill/checkpoint-*` | resumes from the latest `checkpoint-N` |
| 4. Fine-tune | `python src/train_finetune.py` | `checkpoints/finetune/checkpoint-*` | same |
| 5. Eval | `python src/eval_checkpoint.py --model checkpoints/finetune-final --test-set fleurs` | `eval_results.csv` | append-only; already-scored (model, set) pairs skipped (`--force` to redo) |
| 6. Export | `python src/export_ggml.py --model checkpoints/finetune-final` | `models/*-q5_1.bin` + sha256 | skipped if the output exists |

## Running it unattended (survives SSH drops)

```bash
./run_detached.sh            # start — nohup + setsid, detached from the terminal
./run_detached.sh status     # pid + log path
./run_detached.sh stop       # kill the whole stage group (safe anytime)
./run_detached.sh restart    # stop + start with a fresh log file
```

Each start writes stdout+stderr to `logs/run_stages_<timestamp>.log`.
Closing the SSH session does not affect the run. Stopping is safe at any
time — stages resume from the latest checkpoint on the next start.

## Shutdown & resume (the important bit)

**Kill anything at any time** (Ctrl-C, power loss, nightly shutdown).
Nothing is lost:

- Training checkpoints are written every `save_steps` (default 500) and
  the newest 3 are kept (`save_total_limit: 3`). Restart = re-run the
  same command; it prints `resuming from: checkpoints/.../checkpoint-N`.
- Data prep and pseudo-labeling are append/dedupe-based — re-running
  skips finished work.
- If you want a clean start from scratch: delete `checkpoints/` and/or
  `data/pseudolabels.jsonl`.

## Watching it run

```bash
watch -n 2 nvidia-smi                  # GPU util / VRAM / temp
tail -f checkpoints/distill/training.log
```

## Data sources

- **SLR54** (~154 h read speech, Devanagari) — auto-downloaded from
  OpenSLR (5 zips, ~2 GB; slow server, resumes on interrupt).
- **FLEURS ne_np** (~10 h; test split is the held-out eval set).
- **Custom folder** — set `custom_data` in `config.yaml` to a folder of
  `audio.wav` + `audio.txt` pairs. This is where your dialect/elderly
  recordings go; VAD-segment long files first (fine-tuning guide §2.2).
- Common Voice 17 (parquet-only) is out of scope for v1.

## Expected cost on the 4090

| Stage | Wall time |
|---|---|
| 1. Data prep | ~1 h (mostly SLR54 download) |
| 2. Student init | ~10 min |
| 3a. Pseudo-labels | ~2–4 h for 160 h audio |
| 3b. Distillation (20 k steps, batch 8) | ~15–30 h |
| 4. Fine-tune (3 epochs, 160 h) | ~12–20 h |
| 5. Eval | ~1 h per checkpoint |
| 6. Export | ~30 min |

Total ≈ 2–4 days of run time; because every stage resumes, you can run
it across nights without babysitting.

## Smoke test (any machine, no GPU needed)

```bash
python src/data_prep.py --smoke --smoke-pairs data/smoke-pairs.tsv
./smoke_test.sh      # sets PY to your python; uses a local teacher dir
```

`smoke_test.sh` runs pseudo-labels + 2 training steps + a resume-to-4
run to prove the durability loop.
