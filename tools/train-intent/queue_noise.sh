#!/bin/zsh
# Chain: wait for teacher generation AND rung 6 GPU training to exit,
# then run the GPU noise stage (train venv = torch+cuda), then build
# the final dataset. Never overlaps another GPU stage (monitor rule).
while pgrep -f "src/gen_teacher.py" >/dev/null; do sleep 60; done
while pgrep -f "tools/train/.venv/bin/python src/train_finetune.py" >/dev/null \
   || pgrep -f "train_finetune.py --model kiranpantha" >/dev/null; do sleep 120; done
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
set -a; source .env; set +a
/mnt/nvme2/workspace/projects/parent-assistant/tools/train/.venv/bin/python src/stt_noise.py --backend hf > logs/stt_noise_$(date +%Y%m%d_%H%M%S).log 2>&1
.venv/bin/python src/build_dataset.py > logs/build_dataset_$(date +%Y%m%d_%H%M%S).log 2>&1
