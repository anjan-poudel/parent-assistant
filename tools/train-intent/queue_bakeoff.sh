#!/bin/zsh
# Bake-off stage-4 chain (open item #6): wait for the stage-2 STT-noise run
# to exit, rebuild the dataset so the final mixture includes its rows, then
# QLoRA-train gemma-3-1b-it first and qwen3-1.7b second (spec §9.5 order).
# Same shape as queue_noise.sh: wait-loops + timestamped logs + resumable
# stages — re-run this script to continue after any interruption (train
# resumes from its latest checkpoint, build_dataset is a deterministic
# full rebuild, downloads are cached).
# GPU rule (monitor): never overlaps another GPU stage — the chain waits for
# the noise stage AND rung-6 (tools/train) GPU jobs before building, and the
# gpu_free gate below re-checks right before each train leg so a whisper
# stage fired by another session can never make a leg launch into an OOM.
while pgrep -f "src/stt_noise.py" >/dev/null; do sleep 60; done
while pgrep -f "tools/train/.venv/bin/python src/train_finetune.py" >/dev/null \
   || pgrep -f "train_finetune.py --model kiranpantha" >/dev/null \
   || pgrep -f "eval_checkpoint.py" >/dev/null; do sleep 120; done
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
set -a; source .env; set +a
PY=.venv/bin/python

# GPU-free gate: wait until no OTHER compute process holds >500 MiB before a
# leg starts (we hold nothing yet, so any resident process is a stranger).
gpu_free() {
  while :; do
    BUSY=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null \
           | awk -F', ' '$2+0 > 500 {print}' | wc -l | tr -d ' ')
    if [ "$BUSY" = "0" ]; then return 0; fi
    echo "[bakeoff] $(date +%H:%M:%S) GPU busy with other compute — sleeping 120s"
    sleep 120
  done
}

$PY src/build_dataset.py > logs/build_dataset_$(date +%Y%m%d_%H%M%S).log 2>&1 \
  || { echo "build_dataset failed — aborting chain (see newest build_dataset_*.log)"; exit 1; }

gpu_free
$PY src/train_qlora.py --base gemma > logs/train_gemma_$(date +%Y%m%d_%H%M%S).log 2>&1
gpu_free
$PY src/train_qlora.py --base qwen  > logs/train_qwen_$(date +%Y%m%d_%H%M%S).log 2>&1
