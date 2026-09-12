#!/bin/bash
# Phase-2 chain 4: arm D (schema x repaired distill) -> export -> evals ->
# arm comparison -> k=3 policy.
#
# k=3 policy (deliberate, not automatic): a k=3 set costs ~4.5 GPU-hours
# (three fresh trains), and its purpose is to CONFIRM a passing candidate
# against the v14 baseline (0.941 best / 0.863 mean) — not to characterise a
# checkpoint that already fails 3-4 of the 5 gates at k=1. So the k=3 runs
# only for an arm whose k=1 gbnf gate table is clean; otherwise the exact
# candidate command is printed and left for a human decision. Candidates are
# arm C (pre-distill data, rebuildable from config) and arm D (repaired
# distill data, on disk now); arm B's data is not reproducible without
# reverting the repair, so it is reported but never re-run.
set -u
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent || exit 2
D_OUT=qwen-student-schema-repaired
C_OUT=qwen-student-schema-nodistill
D_LOG=logs/armD_schema_repaired_train.log
KR_PREFIX_REPAIRED=qwen-kr-repaired
KR_PREFIX_NODISTILL=qwen-kr-nodistill

echo "[chain4] $(date -Is) waiting for arm D to exit"
while pgrep -f "train_qlora.py --base qwen --out $D_OUT" > /dev/null; do sleep 60; done
if ! grep -aq "\[train\] done →" "$D_LOG"; then
  echo "[chain4] ABORT: arm D did not print '[train] done' — not exporting"
  exit 1
fi

echo "[chain4] $(date -Is) arm D exited cleanly; exporting"
if ! .venv/bin/python src/export_gguf.py --model checkpoints/$D_OUT-final \
        --tag $D_OUT --base qwen > logs/export_$D_OUT.log 2>&1; then
  echo "[chain4] ABORT: arm D export failed"; exit 1
fi
ls -l models/intent-ne-$D_OUT-q4_k_m.gguf || { echo "[chain4] ABORT: no gguf"; exit 1; }

for mode in gbnf off; do
  echo "[chain4] $(date -Is) evaluating arm D: $mode"
  .venv/bin/python src/eval_golden.py --backend gguf \
      --model-path models/intent-ne-$D_OUT-q4_k_m.gguf \
      --grammar $mode --label $D_OUT-s42-$mode --diag \
      > logs/eval_$D_OUT-s42-$mode.log 2>&1
  echo "[chain4] arm D $mode rc=$?"
done

echo
echo "[chain4] $(date -Is) arm comparison, gbnf (k=1, seed 42)"
printf '  %-34s %-42s\n' "arm" "gate table (closed/contact/time/emergency/side-effect)"
for spec in "v14 canonical+pre:logs/gbnf_qwen-s42.log" \
            "A canonical+distill:logs/eval_qwen-student-s42-gbnf.log" \
            "B schema+distill:logs/eval_qwen-student-schema-s42-gbnf.log" \
            "C schema+pre:logs/eval_$C_OUT-s42-gbnf.log" \
            "D schema+repaired:logs/eval_$D_OUT-s42-gbnf.log"; do
  name=${spec%%:*}; log=${spec#*:}
  if [ -f "$log" ]; then
    vals=$(grep -aE "^(closed-intent accuracy|contact slot F1|time slot F1|EMERGENCY RECALL|side-effect precision)" "$log" \
           | awk '{printf "%s ", $(NF-2)}')
    verdict=$(grep -aq "GATES FAILED" "$log" && echo FAIL || echo PASS)
    printf '  %-34s %-42s %s\n' "$name" "$vals" "$verdict"
  else
    printf '  %-34s %s\n' "$name" "(no log: $log)"
  fi
done

passes() { [ -f "$1" ] && ! grep -aq "GATES FAILED" "$1"; }

if passes logs/eval_$D_OUT-s42-gbnf.log; then
  echo "[chain4] arm D passes all five gates at k=1 — running the k=3 set"
  KR_PREFIX=$KR_PREFIX_REPAIRED
elif passes logs/eval_$C_OUT-s42-gbnf.log; then
  echo "[chain4] arm C passes all five gates at k=1 — rebuilding pre-distill data for its k=3 set"
  sed -i 's/^  distill_target: .*/  distill_target: 0/' config.yaml
  .venv/bin/python src/build_dataset.py > logs/build_dataset_kr_nodistill.log 2>&1 || exit 1
  rows=$(wc -l < data/train.jsonl)
  [ "$rows" = "2686" ] || { echo "[chain4] ABORT: expected 2686 pre-distill rows, got $rows"; exit 1; }
  KR_PREFIX=$KR_PREFIX_NODISTILL
else
  echo "[chain4] no arm has a clean k=1 gate table; k=3 NOT launched (~4.5 GPU-hours)."
  echo "[chain4] candidate commands, run deliberately once a config is chosen:"
  echo "[chain4]   .venv/bin/python src/eval_golden_k.py --base qwen --tag-prefix $KR_PREFIX_REPAIRED --k 3 --label-order schema   # repaired distill data (on disk)"
  echo "[chain4]   .venv/bin/python src/eval_golden_k.py --base qwen --tag-prefix $KR_PREFIX_NODISTILL --k 3 --label-order schema  # after distill_target: 0 + build_dataset"
  echo "[chain4] $(date -Is) DONE (no k=3)"
  exit 0
fi

echo "[chain4] $(date -Is) k=3 dry run"
.venv/bin/python src/eval_golden_k.py --base qwen --tag-prefix $KR_PREFIX --k 3 \
    --label-order schema --dry-run > logs/krun_${KR_PREFIX}_dryrun.log 2>&1
cat logs/krun_${KR_PREFIX}_dryrun.log

echo "[chain4] $(date -Is) launching k=3 (serial trains, GPU-gated; resumes via eval/krun_state_$KR_PREFIX.json)"
.venv/bin/python src/eval_golden_k.py --base qwen --tag-prefix $KR_PREFIX --k 3 \
    --label-order schema > logs/krun_${KR_PREFIX}.log 2>&1
echo "[chain4] k=3 rc=$?"
echo "[chain4] $(date -Is) DONE"
