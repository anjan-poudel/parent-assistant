#!/usr/bin/env bash
# Smoke test of the full distillation chain on a tiny local manifest,
# including the kill/resume proof (2 steps, then resume to 4).
# Uses an existing venv's python: pass it as $PY.
#
# NOTE: this is a CPU/MPS-limited smoke run. On the 4090 the Trainer uses
# fp16 + 24 GB VRAM and none of these env tweaks apply.
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONPATH="$PWD/src"
# Let MPS spill into unified memory on small-GPU Macs (teacher fp32 is
# 5.8 GB alone) — irrelevant on CUDA boxes.
export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
P="${PY:-python3}"

"$P" -c "from dataset import DataCollatorSpeechSeq2SeqWithPadding; print('collator import OK')"
echo "== 3a pseudolabel =="
"$P" src/train_distill.py --smoke --pseudolabel-only \
    --teacher "${TEACHER:-/tmp/whisper-conv/kiranpantha-large-v3}"
echo "== 3b distill 2 steps =="
"$P" src/train_distill.py --smoke --max-steps 2 \
    --teacher "${TEACHER:-/tmp/whisper-conv/kiranpantha-large-v3}"
echo "== 3b resume to 4 =="
"$P" src/train_distill.py --smoke --max-steps 4 \
    --teacher "${TEACHER:-/tmp/whisper-conv/kiranpantha-large-v3}"
echo SMOKE_CHAIN_OK
