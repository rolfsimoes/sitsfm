#!/usr/bin/env bash
# Runs the MLP methods of split-block rounds 1 to 10 on the CPU, beside a GPU
# job; run_split_block.sh later skips them and trains only the TempCNN. End or
# stop it before the GPU queue reaches split-block, or both may run a task twice.
# tether runs scripts with bash; main() is parsed whole before it runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
# CPU only: with no CUDA device visible, sits trains and classifies on the CPU
export CUDA_VISIBLE_DEVICES=
export OPENBLAS_NUM_THREADS=1
workers=${1:-2}
if [[ ! $workers =~ ^[1-9][0-9]*$ ]]; then
  echo "workers must be a positive integer: $workers" >&2
  exit 2
fi
fracs=0.05,0.1,0.15,0.2,0.25,0.5,0.75,1
methods=btwins,vicreg,lejepa,ae_centre_y,ts_mlp6,tessera_y,tessera_unit_y
res=data/results/sbsr2027
main() {
  Rscript analysis/sbsr2027/accuracy_learning_curve.R 10 "$fracs" "$methods" \
    hf "$workers" "$res/split-block" all
}
main "$@"
