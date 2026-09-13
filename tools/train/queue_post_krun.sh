#!/bin/zsh
# Post-4B-k-run evaluation queue. GPU owner. Absolute paths everywhere.
set -e
ROOT=/mnt/nvme2/workspace/projects/parent-assistant
TI=$ROOT/tools/train-intent
TR=$ROOT/tools/train
echo "[post-krun] started $(date)"
(cd $TR && $TI/.venv/bin/python src/eval_qwen3asr.py --batch-size 8 \
  > $TR/logs/run_eval_qwen3asr_$(date +%Y%m%d_%H%M%S).log 2>&1)
echo "[post-krun] qwen3-asr eval done $(date)"
BRAIN_GGUF=$TI/models/intent-ne-qwen3-4b-nepali-q4_k_m.gguf
if [ -f "$BRAIN_GGUF" ]; then
  (cd $TI && .venv/bin/python src/eval_golden.py --backend gguf \
    --model-path "$BRAIN_GGUF" --label qwen4b-nepali \
    > $TI/logs/eval_golden_qwen4bne_$(date +%Y%m%d_%H%M%S).log 2>&1)
  echo "[post-krun] brain gate eval done $(date)"
else
  echo "[post-krun] brain GGUF not assembled — skipping"
fi
echo "[post-krun] DONE $(date)"
