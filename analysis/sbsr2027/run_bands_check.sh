#!/usr/bin/env bash
# Bands check: the encoders saw 6 bands, the raw time series methods 10.
# Prints the encoder bands, then runs ts_mlp6 and ts_tempcnn6 on round 1 of
# split-70-30 at 5% and 100% (internal test only, 4 tasks); tether runs
# scripts with bash, and the curve stops if the encoder bands are not the 6.
set -euo pipefail
cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
Rscript analysis/sbsr2027/encoder_bands.R
exec Rscript analysis/sbsr2027/accuracy_learning_curve.R 1 0.05,1 ts_mlp6,ts_tempcnn6 \
  hf 4 data/results/sbsr2027/split-70-30 none
