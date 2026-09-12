#!/bin/bash
# Phase-2 chain (arm A -> arm B). Runs detached on the training box.
#
#   1. wait for arm A (qwen-student, --label-order canonical) to exit cleanly
#   2. export its merged Q4_K_M GGUF (CPU only)
#   3. start arm B (qwen-student-schema, --label-order schema) on the GPU —
#      never co-run two trainings; arm A is provably gone first
#   4. evaluate arm A under BOTH decode modes on CPU while arm B trains
#      (CPU evals may run whenever; they touch no VRAM)
#
# The export step is gated on the trainer's own "[train] done" line so a
# crashed run can never be exported as if it were a real checkpoint.
set -u
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent || exit 2
A_LOG=logs/distill_armA_s42_train.log
A_PAT="train_qlora.py --base qwen --out qwen-student"

echo "[chain] $(date -Is) waiting for arm A to exit"
while pgrep -f "$A_PAT" > /dev/null; do sleep 60; done

if ! grep -aq "\[train\] done →" "$A_LOG"; then
  echo "[chain] ABORT: arm A did not print '[train] done' — not exporting"
  exit 1
fi
echo "[chain] $(date -Is) arm A exited cleanly; exporting"
if ! .venv/bin/python src/export_gguf.py --model checkpoints/qwen-student-final \
        --tag qwen-student --base qwen > logs/export_qwen-student.log 2>&1; then
  echo "[chain] ABORT: export failed (see logs/export_qwen-student.log)"
  exit 1
fi
ls -l models/intent-ne-qwen-student-q4_k_m.gguf || { echo "[chain] ABORT: no gguf"; exit 1; }

echo "[chain] $(date -Is) launching arm B (schema label order)"
nohup .venv/bin/python src/train_qlora.py --base qwen --out qwen-student-schema \
      --label-order schema > logs/distill_armB_s42_train.log 2>&1 &
echo "[chain] arm B pid $!"

echo "[chain] $(date -Is) evaluating arm A: gbnf"
.venv/bin/python src/eval_golden.py --backend gguf \
    --model-path models/intent-ne-qwen-student-q4_k_m.gguf \
    --grammar gbnf --label qwen-student-s42-gbnf --diag \
    > logs/eval_qwen-student-s42-gbnf.log 2>&1
echo "[chain] gbnf rc=$?"

echo "[chain] $(date -Is) evaluating arm A: off"
.venv/bin/python src/eval_golden.py --backend gguf \
    --model-path models/intent-ne-qwen-student-q4_k_m.gguf \
    --grammar off --label qwen-student-s42-off --diag \
    > logs/eval_qwen-student-s42-off.log 2>&1
echo "[chain] off rc=$?"

echo "[chain] $(date -Is) DONE (arm A evaluated; arm B training in background)"
