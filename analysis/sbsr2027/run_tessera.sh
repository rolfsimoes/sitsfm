#!/usr/bin/env bash
# Runs the TESSERA arm (tessera_y, then tessera_unit_y) on the existing
# experiment folders, one Rscript after another; done tasks are skipped.
# tether runs scripts with bash; main() is parsed whole before it runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
# CPU only, to run beside a job on the GPU: with no CUDA device visible,
# sits trains and classifies on the CPU (threads: task_threads() in R)
export CUDA_VISIBLE_DEVICES=
export OPENBLAS_NUM_THREADS=1
fracs=0.05,0.1,0.15,0.2,0.25,0.5,0.75,1
res=data/results/sbsr2027
curve() {
  Rscript analysis/sbsr2027/accuracy_learning_curve.R "$@"
}
main() {
  # split-70-30 writes inputs/encoded_METHOD.rds; the other folders link it
  for m in tessera_y tessera_unit_y; do
    curve 10 "$fracs" "$m" hf 8 "$res/split-70-30" none
  done
  # the splits exist and are kept; make_splits.R only adds the links
  Rscript analysis/sbsr2027/make_splits.R random "$res/val-2018" 10
  Rscript analysis/sbsr2027/make_splits.R year "$res/split-year" 4
  Rscript analysis/sbsr2027/make_splits.R location "$res/split-location" 10
  Rscript analysis/sbsr2027/make_splits.R block "$res/split-block" 10
  for m in tessera_y tessera_unit_y; do
    curve 1 "$fracs" "$m" hf 8 "$res/val-2018" all
  done
  for m in tessera_y tessera_unit_y; do
    curve 4 "$fracs" "$m" hf 8 "$res/split-year" all
  done
  for exp in split-location split-block; do
    for m in tessera_y tessera_unit_y; do
      curve 1 "$fracs" "$m" hf 8 "$res/$exp" all
    done
  done
}
main "$@"
