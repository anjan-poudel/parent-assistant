#!/bin/zsh
# Stage-6 GGUF export chain (open item #6 tail): after BOTH bake-off train
# legs exit, export every finished arm (<base>-final) to the Q4_K_M GGUF
# artifact the ship gates run against.
# CPU-only by design — export_gguf.py clears CUDA_VISIBLE_DEVICES, so this
# may safely run (or be rerun) while any other stage holds the GPU.
# Resumable: export_gguf.py skips any step whose output already exists —
# re-run this script to continue after an interruption.
# Per arm the equivalent one-liner is:
#   .venv/bin/python src/export_gguf.py --model checkpoints/<base>-final --tag <base>
# followed by the gate eval:
#   .venv/bin/python src/eval_golden.py --backend gguf \
#     --model-path models/intent-ne-<base>-q4_k_m.gguf --label <base>-q4_k_m
while pgrep -f "src/train_qlora.py" >/dev/null; do sleep 120; done
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent
PY=.venv/bin/python
for TAG in gemma qwen; do
  FINAL="checkpoints/${TAG}-final"
  if [ ! -d "$FINAL" ]; then
    echo "[export] $FINAL not found — no finished ${TAG} arm to export (skipping)"
    continue
  fi
  $PY src/export_gguf.py --model "$FINAL" --tag "$TAG" \
    || { echo "[export] ${TAG} export failed — aborting chain"; exit 1; }
done
