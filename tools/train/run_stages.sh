#!/usr/bin/env bash
# Run every stage in order. Each stage is resumable — after a shutdown
# (or any failure), just re-run this script: completed work is skipped,
# training resumes from the latest checkpoint.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d ".venv" ]; then
    echo "no .venv — run: python3.11 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi
PY=".venv/bin/python"

echo "== stage 1: data prep =="
"$PY" src/data_prep.py

echo "== stage 2: student init =="
"$PY" src/student_init.py

echo "== stage 3a: pseudo-labels =="
"$PY" src/train_distill.py --pseudolabel-only

echo "== stage 3b: distillation =="
"$PY" src/train_distill.py

echo "== stage 4: fine-tune =="
"$PY" src/train_finetune.py

echo "== stage 5: eval =="
"$PY" src/eval_checkpoint.py --model checkpoints/finetune-final --test-set fleurs

echo "== stage 6: export (needs WHISPER_CPP_DIR) =="
if [ -n "${WHISPER_CPP_DIR:-}" ]; then
    "$PY" src/export_ggml.py --model checkpoints/finetune-final
else
    echo "skipping export — set WHISPER_CPP_DIR to enable"
fi

echo "ALL STAGES COMPLETE"
