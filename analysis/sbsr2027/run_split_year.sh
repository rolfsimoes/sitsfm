#!/usr/bin/env bash
# Runs the split-year learning curve (4 rounds, one per label year); tether runs scripts with bash.
set -euo pipefail
cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
exec Rscript analysis/sbsr2027/accuracy_learning_curve.R 4 0.05,0.1,0.15,0.2,0.25,0.5,0.75,1 \
  btwins,vicreg,lejepa,ts_mlp,ts_tempcnn,ae_centre_y hf 8 data/results/sbsr2027/split-year all
