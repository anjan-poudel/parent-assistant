#!/usr/bin/env bash
# T-038 fixture sweep: run every committed eval_golden fixture and the
# unbound-legacy control, printing the failed-gate column of each run.
#
# Each failing fixture must exit 1 with EXACTLY the one gate it targets, so a
# future harness change cannot quietly stop enforcing a gate (the unit tests
# assert the same contracts; this script shows the operator-facing output).
#
# Usage: bash eval/fixtures/run_fixture_sweep.sh
set -u
cd "$(dirname "$0")/../.."   # tools/train-intent
FX=eval/fixtures

run() {
  local name="$1" corpus="$2" preds="$3" baseline="$4"
  local td out code
  td=$(mktemp -d)
  cp "$FX/$baseline" "$td/results.csv"
  out=$(python3 src/eval_golden.py --backend fixture --preds "$FX/$preds" \
        --corpus "$FX/$corpus" --nearmiss "$FX/nearmiss_min.jsonl" \
        --results-csv "$td/results.csv" --label "fx-$name" 2>&1)
  code=$?
  echo "=== $name EXIT=$code"
  echo "$out" | grep -E "GATES FAILED|calibration |gemini gap |EXCLUDED|all gates passed|OVER|UNEVALUATED" | head -6
  echo "  csv: $(tail -1 "$td/results.csv")"
  rm -rf "$td"
}

run control         corpus_min.jsonl      preds_min_allpass.jsonl               results_baseline_min_100.csv
run calibration     corpus_min.jsonl      preds_calibration_fail.jsonl          results_baseline_min_100.csv
run calibration_cov corpus_min.jsonl      preds_calibration_coverage_fail.jsonl results_baseline_min_100.csv
run abstention      corpus_min.jsonl      preds_abstention_fail.jsonl           results_baseline_min_100.csv
run nearmiss        corpus_min.jsonl      preds_nearmiss_miss.jsonl             results_baseline_min_100.csv
run gemini_gap      corpus_closed28.jsonl preds_gemini_gap_fail.jsonl           results_baseline_28_100.csv
run emergency_miss  corpus_closed28.jsonl preds_emergency_miss.jsonl            results_baseline_28_096.csv

# Negative control: a legacy UNTAGGED gemini baseline with the right numbers
# must still fail closed (the baseline is bound to the corpus revision).
td=$(mktemp -d)
printf 'label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\ngemini-legacy,1.000,1.000,1.000,1.000,1.000,none\n' > "$td/results.csv"
out=$(python3 src/eval_golden.py --backend fixture --preds "$FX/preds_min_allpass.jsonl" \
      --corpus "$FX/corpus_min.jsonl" --nearmiss "$FX/nearmiss_min.jsonl" \
      --results-csv "$td/results.csv" --label fx-unbound 2>&1)
code=$?
echo "=== unbound_legacy EXIT=$code"
echo "$out" | grep -E "GATES FAILED|gemini gap |UNEVALUATED" | head -4
echo "  csv: $(tail -1 "$td/results.csv")"
rm -rf "$td"
