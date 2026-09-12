#!/bin/bash
# Phase-2 chain 3: arm C (schema x pre-distill) -> export -> evals ->
# repaired-distill rebuild -> arm D (schema x repaired distill).
#
# arm C is the pivotal control: the SAME 2686-row pre-distill mixture every
# published 1.7B baseline trained on, with `--label-order schema` matching
# the app's decode grammar, so arm C vs the v14 baseline (canonical x
# pre-distill) isolates the label-order factor and arm B vs arm C isolates
# the distilled rows. arm A (canonical x +distill) already failed 4 gates in
# BOTH decode modes, so its two factors are now measured separately.
#
# arm D is the repair arm: the 105 time labels that contradict the
# utterance's own qualifier and the 11 contact mislabels are fixed in
# data/distill.jsonl (commit "[DISTILL] repair the teacher's mislabels"),
# everything else identical to arm B.
#
# NOTE on the rebuild: draw_key hashes the FULL row JSON, so repairing a
# label re-draws that row's key — the written file order changes (same 4307
# rows) and 5 repaired rows cross the 5% train/valid boundary. The rebuild
# is deterministic (verified byte-identical on re-run) and the row count and
# md5 are asserted below, so arm D differs from arm B only by the repaired
# labels, the row order, and those 5 rows.
set -u
cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent || exit 2
C_OUT=qwen-student-schema-nodistill
C_LOG=logs/armC_schema_nodistill_train.log
D_OUT=qwen-student-schema-repaired
MD5_REPAIRED_TRAIN=c9b107e7f0811db74ac7cd7c84e610eb

echo "[chain3] $(date -Is) waiting for arm C to appear"
# chain2 launches arm C only after arm B exits AND its export succeeds, so
# this budget must outlast the rest of arm B (~40 min at the 07:28 check)
# plus that export — 2 h before calling it a chain2 abort.
for i in $(seq 1 120); do
  pgrep -f "train_qlora.py --base qwen --out $C_OUT" > /dev/null && break
  sleep 60
done
pgrep -f "train_qlora.py --base qwen --out $C_OUT" > /dev/null || {
  echo "[chain3] ABORT: arm C never started (did chain2 abort?)"; exit 1; }

echo "[chain3] $(date -Is) waiting for arm C to exit"
while pgrep -f "train_qlora.py --base qwen --out $C_OUT" > /dev/null; do sleep 60; done
if ! grep -aq "\[train\] done →" "$C_LOG"; then
  echo "[chain3] ABORT: arm C did not print '[train] done' — not exporting"
  exit 1
fi

echo "[chain3] $(date -Is) arm C exited cleanly; exporting"
if ! .venv/bin/python src/export_gguf.py --model checkpoints/$C_OUT-final \
        --tag $C_OUT --base qwen > logs/export_$C_OUT.log 2>&1; then
  echo "[chain3] ABORT: arm C export failed"; exit 1
fi
ls -l models/intent-ne-$C_OUT-q4_k_m.gguf || { echo "[chain3] ABORT: no gguf"; exit 1; }

for mode in gbnf off; do
  echo "[chain3] $(date -Is) evaluating arm C: $mode"
  .venv/bin/python src/eval_golden.py --backend gguf \
      --model-path models/intent-ne-$C_OUT-q4_k_m.gguf \
      --grammar $mode --label $C_OUT-s42-$mode --diag \
      > logs/eval_$C_OUT-s42-$mode.log 2>&1
  echo "[chain3] arm C $mode rc=$?"
done

echo "[chain3] $(date -Is) rebuilding the repaired-distill dataset for arm D"
sed -i 's/^  distill_target: .*/  distill_target: 2600/' config.yaml
grep -q "^  distill_target: 2600" config.yaml || {
  echo "[chain3] ABORT: config restore failed"; exit 1; }
.venv/bin/python src/build_dataset.py > logs/build_dataset_armD_repaired.log 2>&1 || {
  echo "[chain3] ABORT: dataset rebuild failed"; exit 1; }
rows=$(wc -l < data/train.jsonl)
got=$(md5sum data/train.jsonl | cut -d" " -f1)
echo "[chain3] arm D dataset rows=$rows md5=$got"
if [ "$rows" != "4307" ] || [ "$got" != "$MD5_REPAIRED_TRAIN" ]; then
  echo "[chain3] ABORT: expected 4307 rows md5 $MD5_REPAIRED_TRAIN — not training on this"
  exit 1
fi

echo "[chain3] $(date -Is) launching arm D (schema order, repaired distill)"
nohup .venv/bin/python src/train_qlora.py --base qwen --out $D_OUT \
      --label-order schema > logs/armD_schema_repaired_train.log 2>&1 &
echo "[chain3] arm D pid $!"
nohup bash phase2_chain4.sh > logs/phase2_chain4.log 2>&1 &
echo "[chain3] chain4 pid $!"
echo "[chain3] $(date -Is) DONE (arm D training; chain4 will evaluate it)"
