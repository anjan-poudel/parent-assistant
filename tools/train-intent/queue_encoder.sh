#!/bin/zsh
# T-036 encoder pipeline — FULL RUN ONLY. Waits for the GPU to be free, then
# runs build -> train -> calibrate -> harness -> publish-gate with no overlap.
#
# DO NOT run this as a "quick check": the full encoder fine-tune is the
# long-pole job (hours) and this script will sit on the card for the whole of
# it. For a wiring check use the CPU smoke instead:
#
#   python src/run_encoder_pipeline.py --sources tests/data/encoder_rows_sample.jsonl \
#     --work-dir /tmp/t036-smoke --device cpu --max-steps 2 --smoke
#
# Same shape as queue_bakeoff.sh: wait-loops + timestamped logs + resumable
# stages. Re-run this script to continue after an interruption (train resumes
# from state.pt; a drifted config/dataset is REFUSED rather than silently
# restarted — see train_encoder.py resume_mismatch()).
#
# GPU rule (tools/train-intent discipline): this chain waits for every stranger
# compute process AND re-checks immediately before the train leg, so a job
# fired by another session can never make this leg launch into an OOM.
#
# Run this ON THE TRAINING BOX, from tools/train-intent/, with the venv that
# has torch+transformers. The publish gate additionally requires
# encoder.artifact.version to be set in config.yaml (null today by design).
set -u
cd "${0:a:h}" || exit 1

PY="${T036_PY:-.venv/bin/python}"     # venv with torch (e.g. the T-033 venv)
SOURCES=("$@")                        # teacher/noised JSONL built by stages 1-3
if [ ${#SOURCES[@]} -eq 0 ]; then
  SOURCES=("data/teacher.jsonl" "data/noised.jsonl" "data/clean.jsonl")
fi
WORK_DIR="${T036_WORK_DIR:-artifacts/encoder-run-$(date +%Y%m%d-%H%M%S)}"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

# --- GPU-free gate: wait until no OTHER compute process holds >500 MiB ------
gpu_free() {
  while :; do
    BUSY=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null \
           | awk -F', ' '$2+0 > 500 {print}' | wc -l | tr -d ' ')
    if [ "$BUSY" = "0" ]; then return 0; fi
    echo "[encoder] $(date +%H:%M:%S) GPU busy with other compute — sleeping 120s"
    sleep 120
  done
}

# --- wait for the known long jobs of the other sessions ---------------------
while pgrep -f "src/stt_noise.py" >/dev/null; do sleep 60; done
while pgrep -f "train_finetune.py" >/dev/null \
   || pgrep -f "train_qlora.py" >/dev/null \
   || pgrep -f "eval_checkpoint.py" >/dev/null; do sleep 120; done

gpu_free
echo "[encoder] $(date +%Y%m%d-%H%M%S) GPU free — starting full T-036 run -> $WORK_DIR"
# The pipeline itself re-checks the card before the train leg (encoder.gpu.*)
# and runs every stage in one supervised chain, so an interruption leaves a
# resumable state.pt plus a partially-written run_manifest.json.
"$PY" -u src/run_encoder_pipeline.py \
  --sources "${SOURCES[@]}" \
  --work-dir "$WORK_DIR" \
  --device cuda \
  --publish-dir "${T036_PUBLISH_DIR:-}" \
  > "$LOG_DIR/pipeline_$(date +%Y%m%d_%H%M%S).log" 2>&1
RC=$?
echo "[encoder] pipeline exit=$RC (0=published/clean, 5=publish gate withheld, "\
"1=stage failed, 3=refused input) — see $LOG_DIR"
exit $RC
