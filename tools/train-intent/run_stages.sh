#!/bin/bash
# Intent model training pipeline — stages 1-3 + eval.
# Every stage resumes; kill and re-run freely (see README).
set -euo pipefail
cd "$(dirname "$0")"

PY="${PY:-python3}"

echo "== stage 1: teacher generation =="
$PY src/gen_teacher.py

echo "== stage 2: STT-noise injection =="
$PY src/stt_noise.py

echo "== stage 3: dataset build =="
$PY src/build_dataset.py

echo ""
echo "Stages 1-3 done. Next (external): QLoRA train with config.yaml:training,"
echo "then: $PY src/eval_golden.py --backend gguf --model-path <model>.gguf"
