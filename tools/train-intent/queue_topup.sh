#!/bin/zsh
# Wait for the running gen_teacher to exit, then top up to targets
# (edges + under-covered core intents — the script computes shortfalls
# against teacher.jsonl itself).
while pgrep -f "src/gen_teacher.py" >/dev/null; do sleep 60; done
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
set -a; source .env; set +a
.venv/bin/python src/gen_teacher.py > logs/gen_teacher_topup_$(date +%Y%m%d_%H%M%S).log 2>&1
