#!/bin/zsh
# Post-bake-off sequencer (replaces the dead GPU-queue driver, 2026-09-07).
# Waits for the Qwen training leg to exit, then:
#   1. launches ASR fine-tune v5 on the GPU immediately (no idle GPU);
#   2. runs the resumable GGUF export chain on CPU in parallel;
#   3. runs the Qwen gate eval on CPU.
set -e
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
while pgrep -f "src/train_qlora.py" >/dev/null; do sleep 120; done
echo "[seq] qwen leg exited $(date)"

# 1) GPU: ASR v5 (expanded 162k-row manifest, fleurs upweighted)
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train
PYTORCH_NVML_BASED_CUDA_DEVICE_CAP=0 CUDA_LAUNCH_BLOCKING=1 nohup setsid \
  .venv/bin/python src/train_finetune.py --model checkpoints/finetune-medium-final \
  --processor medium --out finetune-medium-v5 --batch-size 16 --grad-accum 2 \
  --epochs 3 --fleurs-weight 25 \
  > logs/run_finetune_medium_v5_$(date +%Y%m%d_%H%M%S).log 2>&1 </dev/null &
echo "[seq] ASR v5 launched pid $!"

# 2) CPU: export chain (resumable — skips already-exported arms)
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
zsh queue_export.sh
echo "[seq] export chain done $(date)"

# 3) CPU: Qwen gate eval (Gemma already scored)
.venv/bin/python src/eval_golden.py --backend gguf \
  --model-path models/intent-ne-qwen-q4_k_m.gguf --label qwen-q4_k_m \
  > logs/eval_golden_qwen_$(date +%Y%m%d_%H%M%S).log 2>&1
echo "[seq] qwen gate eval done $(date)"
