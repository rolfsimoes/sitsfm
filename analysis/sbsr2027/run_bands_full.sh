#!/usr/bin/env bash
# Runs ts_mlp6 and ts_tempcnn6 in every experiment folder: the encoders saw
# 6 bands, so the raw time series methods run again on the same 6.
# tether runs scripts with bash; main() is parsed whole before it runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
fracs=0.05,0.1,0.15,0.2,0.25,0.5,0.75,1
methods=ts_mlp6,ts_tempcnn6
res=data/results/sbsr2027
curve() {
  Rscript analysis/sbsr2027/accuracy_learning_curve.R "$@"
}
main() {
  # no make_splits.R: these methods read the labelled samples and the 2018
  # series already in each inputs/; done tasks, as those of the check, are skipped
  curve 10 "$fracs" "$methods" hf 8 "$res/split-70-30" none
  curve 1 "$fracs" "$methods" hf 8 "$res/val-2018" all
  curve 4 "$fracs" "$methods" hf 8 "$res/split-year" all
  curve 1 "$fracs" "$methods" hf 8 "$res/split-location" all
  curve 1 "$fracs" "$methods" hf 8 "$res/split-block" all
}
main "$@"
