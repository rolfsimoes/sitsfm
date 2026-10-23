#!/usr/bin/env bash
# Writes the summary of every experiment folder and evaluation set, one
# Rscript after another; split-70-30 has no scoring on the 2018 points.
# The paired differences are against the MLP on the 6 bands of the encoders.
# tether runs scripts with bash; main() is parsed whole before it runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
res=data/results/sbsr2027
main() {
  local runs=(
    "split-70-30 split-70-30"
    "val-2018 split-70-30" "val-2018 val-2018"
    "split-year split-70-30" "split-year val-2018"
    "split-location split-70-30" "split-location val-2018"
    "split-block split-70-30" "split-block val-2018"
  )
  local i=0 exp eval
  for run in "${runs[@]}"; do
    read -r exp eval <<<"$run"
    Rscript analysis/sbsr2027/summary_learning_curve.R "$res/$exp" "$eval" ts_mlp6
    i=$((i + 1))
    echo "tether-progress: $i/${#runs[@]}"
  done
}
main "$@"
