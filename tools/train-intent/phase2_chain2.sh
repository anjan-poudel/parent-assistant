#!/bin/bash
# Phase-2 chain 2: arm B finish -> export -> arm C (factorial control) -> arm B evals.
#
# 2x2 design the two chains so far build:
#   canonical order x pre-distill data = v14 baseline (already trained 09-12)
#   canonical order x +1619 distill    = arm A   (fails; slots vanish under off)
#   schema order    x pre-distill data = arm C   <- THIS script
#   schema order    x +1619 distill    = arm B   (training now)
# so arm B vs arm C isolates the distilled rows, arm C vs v14 isolates the
# label order — one factor per comparison, nothing confounded.
#
# Arm C trains on the pre-distill mixture: mixture.distill_target is set to 0
# for the build, which the phase-2 verification showed reproduces the 2686-row
# pre-distill set. The config edit is checked, and the row count is asserted,
# so a silently-still-distilled dataset cannot be trained by accident.
set -u
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent || exit 2
B_LOG=logs/distill_armB_s42_train.log

echo "[chain2] $(date -Is) waiting for arm B to exit"
while pgrep -f "train_qlora.py --base qwen --out qwen-student-schema" > /dev/null; do sleep 60; done
if ! grep -aq "\[train\] done →" "$B_LOG"; then
  echo "[chain2] ABORT: arm B did not print '[train] done' — not exporting"
  exit 1
fi

echo "[chain2] $(date -Is) arm B exited cleanly; exporting"
if ! .venv/bin/python src/export_gguf.py --model checkpoints/qwen-student-schema-final \
        --tag qwen-student-schema --base qwen > logs/export_qwen-student-schema.log 2>&1; then
  echo "[chain2] ABORT: arm B export failed"; exit 1
fi
ls -l models/intent-ne-qwen-student-schema-q4_k_m.gguf || { echo "[chain2] ABORT: no gguf"; exit 1; }

echo "[chain2] $(date -Is) rebuilding dataset for arm C (distill_target 0)"
cp config.yaml /tmp/config_with_distill.yaml
sed -i 's/^  distill_target: 2600/  distill_target: 0/' config.yaml
grep -q "^  distill_target: 0" config.yaml || { echo "[chain2] ABORT: config edit failed"; exit 1; }
.venv/bin/python src/build_dataset.py > logs/build_dataset_armC_nodistill.log 2>&1 || {
  echo "[chain2] ABORT: dataset rebuild failed"; cp /tmp/config_with_distill.yaml config.yaml; exit 1; }
rows=$(wc -l < data/train.jsonl)
echo "[chain2] arm C dataset rows=$rows"
if [ "$rows" != "2686" ]; then
  echo "[chain2] ABORT: expected the 2686-row pre-distill set, got $rows"
  cp /tmp/config_with_distill.yaml config.yaml
  exit 1
fi
cmp data/train.jsonl data/backup-pre-distill/train.jsonl \
  && echo "[chain2] arm C data is byte-identical to the pre-distill backup" \
  || echo "[chain2] WARNING: arm C data differs from the backup (same row count)"

echo "[chain2] $(date -Is) launching arm C (schema order, pre-distill data)"
nohup .venv/bin/python src/train_qlora.py --base qwen --out qwen-student-schema-nodistill \
      --label-order schema > logs/armC_schema_nodistill_train.log 2>&1 &
echo "[chain2] arm C pid $!"

echo "[chain2] $(date -Is) evaluating arm B: gbnf"
.venv/bin/python src/eval_golden.py --backend gguf \
    --model-path models/intent-ne-qwen-student-schema-q4_k_m.gguf \
    --grammar gbnf --label qwen-student-schema-s42-gbnf --diag \
    > logs/eval_qwen-student-schema-s42-gbnf.log 2>&1
echo "[chain2] gbnf rc=$?"

echo "[chain2] $(date -Is) evaluating arm B: off"
.venv/bin/python src/eval_golden.py --backend gguf \
    --model-path models/intent-ne-qwen-student-schema-q4_k_m.gguf \
    --grammar off --label qwen-student-schema-s42-off --diag \
    > logs/eval_qwen-student-schema-s42-off.log 2>&1
echo "[chain2] off rc=$?"

echo "[chain2] $(date -Is) DONE (arm B evaluated; arm C training in background)"
