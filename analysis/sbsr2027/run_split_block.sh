#!/usr/bin/env bash
# Runs rounds 1 to 10 of split-block for every method, also scored on the
# 2018 points; done tasks are skipped, so it adds rounds 2 to 10.
# tether runs scripts with bash; main() is parsed whole before it runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
fracs=0.05,0.1,0.15,0.2,0.25,0.5,0.75,1
methods=btwins,vicreg,lejepa,ts_mlp,ts_tempcnn,ae_centre_y,tessera_y,tessera_unit_y
res=data/results/sbsr2027
main() {
  # the splits exist and are kept; make_splits.R only adds new input links
  Rscript analysis/sbsr2027/make_splits.R block "$res/split-block" 10
  Rscript analysis/sbsr2027/accuracy_learning_curve.R 10 "$fracs" "$methods" \
    hf 8 "$res/split-block" all
}
main "$@"
