#!/usr/bin/env bash
# run_repro_check.sh -- retrains recorded tasks of the SBSR 2027
# experiments and compares each new task file with the recorded one, to
# test if the published code reproduces the published numbers. Without
# --tasks it retrains 11 chosen tasks on the CPU or the GPU, to test if
# the device (CPU against GPU) is why the TESSERA results of split-70-30
# and val-2018 differ. With --tasks it retrains the tasks of a list on
# the GPU (see "Task list" below).
#
# Criterion. A rerun on the device of the recorded run must equal the
# recorded CSV exactly in every metric row (accuracy, kappa, F1 per
# class, n_train, n_valid; values as write.csv wrote them, 15 significant
# digits). A rerun on the other device is expected to differ. Seconds are
# listed, not compared.
#
# The 11 trainings, all at 5% (the fastest) except group 2:
#   1. split-block, recorded on the CPU by run_split_block_cpu.sh: btwins
#      round 5 (224 s, above the GPU range of 5% tasks), ts_mlp6 round 2
#      (115 s; every CPU ts_mlp6 task is in the GPU range) and ae_centre_y
#      round 2 (206 s, between the ranges); each on the GPU and the CPU.
#   2. Device unknown (written before tether jobs), methods of the paper,
#      three experiments, at 10% (no such task at 5%): ae_centre_y
#      split-70-30 round 1, btwins split-year round 1, vicreg
#      split-location round 1; on the GPU. Equal means trained on the GPU.
#   3. TESSERA: tessera_y, split-70-30 round 2, on the CPU and on the GPU.
#      Recorded on the CPU in split-70-30 (accuracy 0.937342903001121) and
#      on the GPU in val-2018 (0.914842070197753); the two split files
#      must hold the same validation and training ids. It runs first.
#
# Task list (--tasks FILE): a CSV with the header
# experiment,round,method,percent, one task per row, such as
# repro_sample_tasks.csv (drawn by repro_sample.R). Each task is trained
# on the GPU and compared with its file in the current results (recorded
# device `final`; every rerun is expected equal). Experiments other than
# split-70-30 are also scored on the 2018 points, as their runners did
# (run_gpu_retrain.sh), and both task files are compared. TempCNN methods
# are refused: they do not reproduce on the GPU. A list may not hold one
# experiment, method and fraction twice (the rounds would share links).
#
# Each training runs accuracy_learning_curve.R (one worker) with
# CUDA_VISIBLE_DEVICES empty for the CPU and as inherited for the GPU, as
# the run_*.sh runners do, in a scratch experiment folder
#   data/results/sbsr2027/repro-check/DEVICE/EXPERIMENT/
#   data/results/sbsr2027/repro-check/LIST/gpu/EXPERIMENT/  (--tasks;
#     LIST is the file name without .csv)
# that links the inputs and the splits of rounds 1 to R of the recorded
# experiment, and the recorded task files of rounds 1 to R-1, so that
# the learning-curve script skips those rounds and trains round R only.
# Models are not linked, so the script trains and does not read a saved
# model. Nothing is written in a recorded experiment folder. A task file
# already in the scratch folder is not trained again. At the end it writes
#   data/results/sbsr2027/repro-check/comparison.csv
#   data/results/sbsr2027/repro-check/LIST/comparison.csv  (--tasks)
# (task, device, recorded_device, metric, class, recorded, rerun, equal)
# and prints one line per comparison; with --tasks also the count of
# tasks equal in every row.
# Not controlled: the torch threads of the recorded runs (the task lines
# of their logs print them); one worker here, 8 in the GPU runners.
#
# Usage: analysis/sbsr2027/run_repro_check.sh [--dry-run] [--results DIR]
#          [--tasks FILE]
#   --dry-run       check the tasks, inputs, splits, recorded files and
#                   devices, print the trainings and exit; writes nothing
#   --results DIR   the results folder (default data/results/sbsr2027)
#   --tasks FILE    retrain the tasks of FILE on the GPU instead of the 11
#   -h, --help      this help
#   --version       the version
# DIR and FILE are relative to the sitsfm root, or absolute.
#
# Run from any directory; it works from the sitsfm root. It prints
# `tether-progress: N/M` lines, M being the trainings. Exit status: 0 on
# success (whatever the comparison shows); 1 if a file is missing, the
# task list is wrong, a link in the scratch folder points elsewhere, a
# device is not the one asked for, or a training fails; 2 on a wrong
# argument.
set -euo pipefail

VERSION=0.2.0
dry=0
res=data/results/sbsr2027
list=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --version) echo "run_repro_check.sh $VERSION"; exit 0 ;;
    --dry-run) dry=1; shift ;;
    --results|--tasks)
      if [ $# -lt 2 ]; then
        echo "run_repro_check.sh: $1 needs a value; see --help" >&2
        exit 2
      fi
      if [ "$1" = --results ]; then res=$2; else list=$2; fi
      shift 2 ;;
    *) echo "run_repro_check.sh: unknown argument '$1'; see --help" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
if [ -z "$list" ]; then
  scratch=$res/repro-check
  devices="cpu gpu"
else
  scratch=$res/repro-check/$(basename "$list" .csv)
  devices=gpu
  case $(basename "$list" .csv) in
    cpu|gpu|"")
      echo "run_repro_check.sh: the task list may not be named cpu.csv or gpu.csv" >&2
      exit 2 ;;
  esac
fi
out=$scratch/comparison.csv
tmp=$scratch/.comparison.csv.$$

# training: device, experiment, round, method, fraction in percent
trainings=(
  "cpu split-70-30 2 tessera_y 5"
  "gpu split-70-30 2 tessera_y 5"
  "gpu split-block 5 btwins 5"
  "cpu split-block 5 btwins 5"
  "gpu split-block 2 ts_mlp6 5"
  "cpu split-block 2 ts_mlp6 5"
  "gpu split-block 2 ae_centre_y 5"
  "cpu split-block 2 ae_centre_y 5"
  "gpu split-70-30 1 ae_centre_y 10"
  "gpu split-year 1 btwins 10"
  "gpu split-location 1 vicreg 10"
)
# recorded result: experiment, round, method, fraction of the task, then
# the device of the recorded run (device-inventory of 26 Oct 2026) and
# the experiment folder that holds its task file
records=(
  "split-70-30 2 tessera_y 5 cpu split-70-30"
  "split-70-30 2 tessera_y 5 gpu val-2018"
  "split-block 5 btwins 5 cpu split-block"
  "split-block 2 ts_mlp6 5 cpu split-block"
  "split-block 2 ae_centre_y 5 cpu split-block"
  "split-70-30 1 ae_centre_y 10 unknown split-70-30"
  "split-year 1 btwins 10 unknown split-year"
  "split-location 1 vicreg 10 unknown split-location"
)

rr() { printf '%02d' "$1"; }
# task file of round $1, method $2, fraction $3 (percent), in experiment
# folder $4, evaluation set $5 (default split-70-30)
task_file() {
  echo "$4/round-$(rr "$1")/${5:-split-70-30}/round_$(rr "$1")_$2_f$(printf '%03d' "$3").csv"
}
split_file() { echo "$1/round-$(rr "$2")/round_$(rr "$2")_split.rds"; }
# 2018 points argument of the R script for experiment $1: with a task
# list, that of the runner of the experiment; the 11 trainings, none
val_arg() {
  if [ -n "$list" ] && [ "$1" != split-70-30 ]; then echo all; else echo none; fi
}
# evaluation sets written and compared for experiment $1
eval_sets() {
  if [ "$(val_arg "$1")" = all ]; then echo "split-70-30 val-2018"; else echo split-70-30; fi
}
# files the learning-curve script reads for method $2 in experiment $1
input_files() {
  echo "inputs/labelled_samples.rds"
  case $2 in ts_*) ;; *) echo "inputs/encoded_$2.rds" ;; esac
  if [ "$(val_arg "$1")" = all ]; then
    case $2 in
      ts_*) echo "inputs/val2018_series.rds" ;;
      *) echo "inputs/val2018_encoded_$2.rds" ;;
    esac
  fi
}
# done: the file holds the accuracy row, as task_done() of the R script asks
task_done() { [ -f "$1" ] && grep -q '^[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,"accuracy",' "$1"; }
# a training is done when its file of every evaluation set is
rerun_done() {
  local dev=$1 exp=$2 round=$3 method=$4 pct=$5 ev
  for ev in $(eval_sets "$exp"); do
    task_done "$(task_file "$round" "$method" "$pct" "$scratch/$dev/$exp" "$ev")" || return 1
  done
}

missing=0
declare -A told
# a problem found before training, printed once
fail() {
  if [ -z "${told[$1]:-}" ]; then
    echo "$1" >&2
    told[$1]=1
  fi
  missing=1
}
need() { [ -e "$1" ] || fail "missing: $1"; }

# the task list replaces the 11 trainings: on the GPU, each compared with
# its file in its own experiment
read_list() {
  local header exp round method pct key
  local -A seen
  if [ ! -f "$list" ]; then
    echo "run_repro_check.sh: missing $list" >&2
    exit 1
  fi
  IFS= read -r header < "$list"
  if [ "$header" != "experiment,round,method,percent" ]; then
    echo "run_repro_check.sh: $list has the header '$header'" >&2
    exit 1
  fi
  trainings=()
  records=()
  while IFS=, read -r exp round method pct; do
    if [[ " split-70-30 val-2018 split-year split-location split-block " != *" $exp "* ]] ||
      [[ ! $round =~ ^[1-9][0-9]*$ ]] || [[ ! $method =~ ^[a-z0-9_]+$ ]] ||
      [[ " 5 10 15 20 25 50 75 100 " != *" $pct "* ]]; then
      fail "$list: row '$exp,$round,$method,$pct' is not a task"
      continue
    fi
    case $method in
      ts_tempcnn|ts_tempcnn6)
        fail "$list: $method does not reproduce on the GPU; not a task of this check"
        continue ;;
    esac
    key="$exp $method $pct"
    if [ -n "${seen[$key]:-}" ]; then
      fail "$list: $exp $method $pct% listed twice"
      continue
    fi
    seen[$key]=1
    trainings+=("gpu $exp $round $method $pct")
    records+=("$exp $round $method $pct final $exp")
  done < <(tail -n +2 "$list"; [ -z "$(tail -c 1 "$list")" ] || echo)
}
# relative link $2 -> $1; a link already there must point to the same file
link() {
  if [ -L "$2" ] || [ -e "$2" ]; then
    if [ "$(readlink -f "$2")" != "$(readlink -f "$1")" ]; then
      echo "run_repro_check.sh: $2 exists and is not a link to $1" >&2
      exit 1
    fi
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  ln -sr "$1" "$2"
}
# runs a command on device $1: no CUDA device visible for the CPU, the
# inherited CUDA_VISIBLE_DEVICES for the GPU
device_env() {
  local dev=$1
  shift
  if [ "$dev" = cpu ]; then
    CUDA_VISIBLE_DEVICES='' "$@"
  else
    "$@"
  fi
}
# split files $1 and $2 hold the same sets of ids in `valid` and in each
# fraction of `train`; training selects rows with %in%, so order and the
# other fields do not matter. Prints the parts that differ.
same_split() {
  local diff
  # shellcheck disable=SC2016 # the $ belong to R, not to the shell
  diff=$(Rscript -e '
    f <- commandArgs(TRUE); a <- readRDS(f[1]); b <- readRDS(f[2])
    ids <- function(x) sort(as.integer(x))
    fr <- union(names(a$train), names(b$train))
    d <- c(valid = !identical(ids(a$valid), ids(b$valid)),
      setNames(vapply(fr, function(k) !identical(ids(a$train[[k]]), ids(b$train[[k]])), logical(1)), paste0("train ", fr)))
    cat(if (any(d)) paste(names(d)[d], collapse = ", ") else "same")' "$1" "$2" 2>&1) || true
  [ "$diff" = same ] && return 0
  echo "split $2 against $1: differs in $diff" >&2
  return 1
}
# torch must see CUDA on the GPU and not on the CPU
check_device() {
  local dev=$1 cuda
  cuda=$(device_env "$dev" Rscript -e 'cat(torch::cuda_is_available())') || cuda="an error"
  if { [ "$dev" = cpu ] && [ "$cuda" != FALSE ]; } || { [ "$dev" = gpu ] && [ "$cuda" != TRUE ]; }; then
    fail "device $dev: torch::cuda_is_available() is $cuda"
  fi
}

# compare rerun $1 with recorded $2; rows: task, device, recorded_device,
# metric, class, recorded, rerun, equal
compare() {
  awk -F, -v task="$3" -v dev="$4" -v rdev="$5" '
    function key(m, c) { gsub(/"/, "", m); gsub(/"/, "", c); return m "," c }
    FNR == 1 { next }
    {
      k = key($6, $7)
      if (FILENAME == ARGV[1]) { rec[k] = $8; order[++n] = k; rtrain = $4; rvalid = $5 }
      else { new[k] = $8; ntrain = $4; nvalid = $5; seen[k] = 1 }
    }
    END {
      rec["n_train,NA"] = rtrain; new["n_train,NA"] = ntrain; order[++n] = "n_train,NA"
      rec["n_valid,NA"] = rvalid; new["n_valid,NA"] = nvalid; order[++n] = "n_valid,NA"
      seen["n_train,NA"] = seen["n_valid,NA"] = 1
      for (k in seen) if (!(k in rec)) order[++n] = k
      for (i = 1; i <= n; i++) {
        k = order[i]
        r = (k in rec) ? rec[k] : "NA"
        v = (k in new) ? new[k] : "NA"
        # a row missing on one side is not equal; NA equals NA
        eq = (k ~ /^seconds,/) ? "NA" : ((k in rec && k in new && r == v) ? "TRUE" : "FALSE")
        print task "," dev "," rdev "," k "," r "," v "," eq
      }
    }' "$2" "$1"
}

main() {
  local t dev exp round method pct r input key rkey rdev rexp ev
  local rerun recorded name expect n_eq n_cmp acc_r acc_n total
  local all_eq n_task_eq=0
  [ -n "$list" ] && read_list
  total=${#trainings[@]}
  # 1. every task resolved: inputs, splits, earlier rounds, recorded files
  for t in "${trainings[@]}"; do
    read -r dev exp round method pct <<<"$t"
    for input in $(input_files "$exp" "$method"); do
      need "$res/$exp/$input"
    done
    # the R script reads the 2018 series at this path, whatever --results
    [ "$(val_arg "$exp")" = all ] && need data/results/sbsr2027/val-2018/inputs/validation_series_2018.rds
    for r in $(seq 1 "$round"); do
      need "$(split_file "$res/$exp" "$r")"
    done
    for r in $(seq 1 $((round - 1))); do
      for ev in $(eval_sets "$exp"); do
        need "$(task_file "$r" "$method" "$pct" "$res/$exp" "$ev")"
      done
    done
    key="$exp $round $method $pct"
    n_cmp=0
    for rkey in "${records[@]}"; do
      read -r _ _ _ _ rdev rexp <<<"$rkey"
      [ "${rkey% * *}" = "$key" ] || continue
      n_cmp=$((n_cmp + 1))
      for ev in $(eval_sets "$exp"); do
        need "$(task_file "$round" "$method" "$pct" "$res/$rexp" "$ev")"
      done
      # a record of another experiment folder must come from the same split
      if [ "$rexp" != "$exp" ] && ! same_split "$(split_file "$res/$exp" "$round")" "$(split_file "$res/$rexp" "$round")"; then
        fail "split differs: $(split_file "$res/$rexp" "$round")"
      fi
    done
    if [ "$n_cmp" -eq 0 ]; then
      fail "no recorded result for: $key"
    fi
  done
  for dev in $devices; do
    check_device "$dev"
  done
  echo "trainings: $total, in $scratch"
  for t in "${trainings[@]}"; do
    read -r dev exp round method pct <<<"$t"
    rerun_done "$dev" "$exp" "$round" "$method" "$pct" && echo "  $dev $exp round $round $method $pct%: done" ||
      echo "  $dev $exp round $round $method $pct%"
  done
  if [ "$missing" = 1 ]; then
    echo "run_repro_check.sh: see the lines above" >&2
    exit 1
  fi
  [ "$dry" = 1 ] && exit 0

  # 2. trainings, one after another
  echo "tether-progress: 0/$total"
  local i=0
  for t in "${trainings[@]}"; do
    read -r dev exp round method pct <<<"$t"
    local dir=$scratch/$dev/$exp
    rerun=$(task_file "$round" "$method" "$pct" "$dir")
    if ! rerun_done "$dev" "$exp" "$round" "$method" "$pct"; then
      for input in $(input_files "$exp" "$method"); do
        link "$res/$exp/$input" "$dir/$input"
      done
      for r in $(seq 1 "$round"); do
        link "$(split_file "$res/$exp" "$r")" "$(split_file "$dir" "$r")"
      done
      # recorded files of the earlier rounds: the R script skips them
      for r in $(seq 1 $((round - 1))); do
        for ev in $(eval_sets "$exp"); do
          link "$(task_file "$r" "$method" "$pct" "$res/$exp" "$ev")" "$(task_file "$r" "$method" "$pct" "$dir" "$ev")"
        done
      done
      echo "training $((i + 1))/$total: $dev $exp round $round $method $pct%"
      # the R script prints its own progress lines, which count its rounds
      if ! device_env "$dev" Rscript analysis/sbsr2027/accuracy_learning_curve.R "$round" \
        "$(awk -v p="$pct" 'BEGIN { print p / 100 }')" "$method" hf 1 "$dir" "$(val_arg "$exp")" 2>&1 |
        sed '/^tether-progress:/d' || ! rerun_done "$dev" "$exp" "$round" "$method" "$pct"; then
        echo "run_repro_check.sh: training failed, no task file $rerun" >&2
        exit 1
      fi
    fi
    i=$((i + 1))
    echo "tether-progress: $i/$total"
  done

  # 3. comparison of each rerun with each recorded file of its task
  trap 'rm -f "$tmp" "$tmp.one"' EXIT
  echo "task,device,recorded_device,metric,class,recorded,rerun,equal" > "$tmp"
  for t in "${trainings[@]}"; do
    read -r dev exp round method pct <<<"$t"
    key="$exp $round $method $pct"
    all_eq=1
    for ev in $(eval_sets "$exp"); do
      rerun=$(task_file "$round" "$method" "$pct" "$scratch/$dev/$exp" "$ev")
      name=$exp/$(basename "$rerun" .csv)
      [ "$ev" = split-70-30 ] || name=$exp/$ev/$(basename "$rerun" .csv)
      for rkey in "${records[@]}"; do
        read -r _ _ _ _ rdev rexp <<<"$rkey"
        [ "${rkey% * *}" = "$key" ] || continue
        recorded=$(task_file "$round" "$method" "$pct" "$res/$rexp" "$ev")
        compare "$rerun" "$recorded" "$name" "$dev" "$rdev" > "$tmp.one"
        cat "$tmp.one" >> "$tmp"
        n_cmp=$(awk -F, '$8 != "NA"' "$tmp.one" | wc -l)
        n_eq=$(awk -F, '$8 == "TRUE"' "$tmp.one" | wc -l)
        [ "$n_eq" -eq "$n_cmp" ] || all_eq=0
        acc_r=$(awk -F, '$4 == "accuracy" { print $6 }' "$tmp.one")
        acc_n=$(awk -F, '$4 == "accuracy" { print $7 }' "$tmp.one")
        if [ "$rdev" = unknown ]; then
          expect="recorded device unknown"
        elif [ "$rdev" = "$dev" ] || [ "$rdev" = final ]; then
          expect="expected equal"
        else
          expect="expected to differ"
        fi
        echo "$name rerun $dev, recorded $rdev ($rexp): $n_eq of $n_cmp rows equal, accuracy $acc_r recorded, $acc_n rerun; $expect"
        rm -f "$tmp.one"
      done
    done
    n_task_eq=$((n_task_eq + all_eq))
  done
  mv "$tmp" "$out"
  [ -n "$list" ] && echo "tasks equal in every row: $n_task_eq of $total"
  echo "comparison: $out"
}
main "$@"
