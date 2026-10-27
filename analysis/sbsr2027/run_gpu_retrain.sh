#!/usr/bin/env bash
# run_gpu_retrain.sh -- replaces every CPU-trained task of the SBSR 2027
# experiments by a GPU-trained one, so the published code reproduces the
# published numbers. On 27 Oct 2026 run_repro_check.sh retrained 5
# recorded GPU tasks on the GPU and got every row equal; on the CPU 5 of 5
# differed from their recorded CPU tasks (0.4 to 1.8 pp), so a CPU task
# cannot be reproduced.
#
# The tasks are listed in cpu_trained_tasks.csv, next to this script
# (experiment, round, method, percent, action; one row per task). Action
# `train`: the task is trained again on the GPU. Action `copy`: TESSERA
# tasks of split-70-30, rounds 2 to 10, whose GPU-trained result already
# exists in val-2018/round-RR/split-70-30/ (same split, internal test);
# the split files of both experiments must hold the same ids, else
# nothing runs.
#
# Steps:
#   1. Check: the list, the files of each task (at their place or in the
#      archive), the splits, the inputs, no STOP file, no first-layout
#      table round_RR_METHOD.csv, every task of the runner arguments not
#      on the list done, and torch sees CUDA. Any problem: exit 1.
#   2. Move every file of a listed task (task CSV, CSV and predictions on
#      the 2018 points, model .rds and .json) to
#        EXPERIMENT/cpu-trained/<same path in EXPERIMENT>
#      with `mv`; nothing is deleted. The task CSV moves last; a task
#      whose task CSV is in the archive counts as moved and is not
#      touched again. A file whose task is not on the list is refused.
#   3. Copy the `copy` tasks (temporary name, then rename).
#   4. Run accuracy_learning_curve.R on each experiment with tasks to
#      train, with the GPU visible and the arguments of the runner that
#      wrote the experiment, 8 workers as the GPU runners used. Done tasks
#      are skipped, so only the moved tasks train:
#        split-70-30     10 rounds, tessera_y,tessera_unit_y, none
#                        (run_tessera.sh)
#        val-2018        10 rounds, 8 methods, all (run_val2018.sh)
#        split-year      4 rounds, tessera_y,tessera_unit_y, all
#                        (run_tessera.sh)
#        split-location  10 rounds, 8 methods, all (run_split_location.sh)
#        split-block     10 rounds, 8 methods, all (run_split_block.sh)
#      all with the 8 fractions 0.05 to 1 and the samples "hf".
#
# A rerun after an interruption resumes: moved files stay moved, copied
# files are compared with their source, done tasks are skipped.
# Not seen by the checks: the device that wrote the shared inputs
# (encoded_METHOD.rds, val2018_encoded_METHOD.rds; the dry run prints
# their times), and the device sits really uses (the check asks torch).
#
# Usage: analysis/sbsr2027/run_gpu_retrain.sh [--dry-run]
#   --dry-run     run step 1, print the files to move and to copy and the
#                 tasks to train, and exit; writes nothing
#   -h, --help    this help
#   --version     the version
#
# Run from any directory; it works from the sitsfm root. It prints
# `tether-progress: N/M` lines, M being the tasks to train. Exit status:
# 0 on success; 1 on a failed check, a refused move or a failed training;
# 2 on a wrong argument.
set -euo pipefail

VERSION=0.1.0
dry=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --version) echo "run_gpu_retrain.sh $VERSION"; exit 0 ;;
    --dry-run) dry=1; shift ;;
    *) echo "run_gpu_retrain.sh: unknown argument '$1'; see --help" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.."
export OPENBLAS_NUM_THREADS=1
res=data/results/sbsr2027
list=analysis/sbsr2027/cpu_trained_tasks.csv
archive=cpu-trained
workers=8
fracs=0.05,0.1,0.15,0.2,0.25,0.5,0.75,1
percents="5 10 15 20 25 50 75 100"
m8=btwins,vicreg,lejepa,ts_mlp6,ts_tempcnn6,ae_centre_y,tessera_y,tessera_unit_y
tess=tessera_y,tessera_unit_y
# experiment, rounds, methods, 2018 points: the arguments of its runner
experiments=(
  "split-70-30 10 $tess none"
  "val-2018 10 $m8 all"
  "split-year 4 $tess all"
  "split-location 10 $m8 all"
  "split-block 10 $m8 all"
)

rr() { printf '%02d' "$1"; }
# file of task (round $1, method $2, percent $3) relative to its experiment
# folder; kind: task, val, pred, model, meta
rel_file() {
  local name
  name="round_$(rr "$1")_$2_f$(printf '%03d' "$3")"
  case $4 in
    task) echo "round-$(rr "$1")/split-70-30/$name.csv" ;;
    val) echo "round-$(rr "$1")/val-2018/$name.csv" ;;
    pred) echo "round-$(rr "$1")/val-2018/${name}_pred.csv" ;;
    model) echo "round-$(rr "$1")/models/$name.rds" ;;
    meta) echo "round-$(rr "$1")/models/$name.json" ;;
  esac
}
split_file() { echo "$res/$1/round-$(rr "$2")/round_$(rr "$2")_split.rds"; }
# done: the file holds the accuracy row of the fraction, as task_done() of
# the R script asks
task_done() {
  [ -f "$1" ] && awk -F, -v p="$2" '$6 == "\"accuracy\"" && $3 == p / 100 { ok = 1 } END { exit !ok }' "$1"
}

problems=0
fail() {
  echo "$1" >&2
  problems=$((problems + 1))
}
need() { [ -e "$1" ] || fail "missing: $1"; }

# experiment settings by name
declare -A exp_rounds exp_methods exp_eval
for e in "${experiments[@]}"; do
  read -r name n methods ev <<<"$e"
  exp_rounds[$name]=$n
  exp_methods[$name]=$methods
  exp_eval[$name]=$ev
done

# the list: key "experiment round method percent" -> action
declare -A listed
tasks=()
read_list() {
  local header exp round method pct action
  if [ ! -f "$list" ]; then
    echo "run_gpu_retrain.sh: missing $list" >&2
    exit 1
  fi
  IFS= read -r header < "$list"
  if [ "$header" != "experiment,round,method,percent,action" ]; then
    echo "run_gpu_retrain.sh: $list has the header '$header'" >&2
    exit 1
  fi
  while IFS=, read -r exp round method pct action; do
    local key="$exp $round $method $pct"
    if [ -z "${exp_rounds[$exp]:-}" ] || [[ ! $round =~ ^[0-9]+$ ]] ||
      [ "$round" -lt 1 ] || [ "$round" -gt "${exp_rounds[$exp]}" ] ||
      [[ ",${exp_methods[$exp]}," != *",$method,"* ]] ||
      [[ " $percents " != *" $pct "* ]] ||
      { [ "$action" != train ] && [ "$action" != copy ]; } ||
      { [ "$action" = copy ] && [ "$exp" != split-70-30 ]; }; then
      fail "$list: row '$exp,$round,$method,$pct,$action' is not a task of the runner arguments"
      continue
    fi
    if [ -n "${listed[$key]:-}" ]; then
      fail "$list: task '$key' listed twice"
      continue
    fi
    listed[$key]=$action
    tasks+=("$key")
  done < <(tail -n +2 "$list"; [ -z "$(tail -c 1 "$list")" ] || echo)
}

# a task is moved when its task CSV is in the archive
is_moved() {
  local exp=$1 round=$2 method=$3 pct=$4
  task_done "$res/$exp/$archive/$(rel_file "$round" "$method" "$pct" task)" "$pct"
}
# a task is trained when its new task CSV (and the one on the 2018 points)
# is done
is_trained() {
  local exp=$1 round=$2 method=$3 pct=$4
  task_done "$res/$exp/$(rel_file "$round" "$method" "$pct" task)" "$pct" &&
    { [ "${exp_eval[$exp]}" = none ] ||
      task_done "$res/$exp/$(rel_file "$round" "$method" "$pct" val)" "$pct"; }
}
copy_source() { echo "$res/val-2018/$(rel_file "$2" "$3" "$4" task)"; }
copy_dest() { echo "$res/$1/$(rel_file "$2" "$3" "$4" task)"; }

# moves EXPERIMENT/REL to EXPERIMENT/cpu-trained/REL; refuses a file whose
# task is not on the list. Prints the move only in a dry run.
move_file() {
  local exp=$1 rel=$2 src dst key
  if [[ ! $rel =~ ^round-([0-9]{2})/(split-70-30|val-2018|models)/round_([0-9]{2})_(.+)_f([0-9]{3})(_pred)?\.(csv|rds|json)$ ]] ||
    [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]; then
    echo "run_gpu_retrain.sh: refused, not a task file: $exp/$rel" >&2
    exit 1
  fi
  key="$exp $((10#${BASH_REMATCH[1]})) ${BASH_REMATCH[4]} $((10#${BASH_REMATCH[5]}))"
  if [ -z "${listed[$key]:-}" ]; then
    echo "run_gpu_retrain.sh: refused, task not on the list: $exp/$rel" >&2
    exit 1
  fi
  src=$res/$exp/$rel
  dst=$res/$exp/$archive/$rel
  [ -e "$src" ] || return 0
  # both present: found by check(); a dry run lists it and goes on
  if [ -e "$dst" ] && [ "$dry" = 0 ]; then
    echo "run_gpu_retrain.sh: both $src and $dst exist" >&2
    exit 1
  fi
  n_move=$((n_move + 1))
  if [ "$dry" = 1 ]; then
    echo "move: $exp/$rel -> $exp/$archive/$rel"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
}

# split files $1 and $2 hold the same sets of ids in `valid` and in each
# fraction of `train` (as in run_repro_check.sh). Prints the parts that differ.
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

# 1. checks; nothing is written
check() {
  local key exp round method pct action rel kind n m p ev t in_file
  read_list
  # files of each listed task, at their place or in the archive
  for key in "${tasks[@]}"; do
    read -r exp round method pct <<<"$key"
    for kind in task val; do
      [ "$kind" = val ] && [ "${exp_eval[$exp]}" = none ] && continue
      rel=$(rel_file "$round" "$method" "$pct" "$kind")
      if ! task_done "$res/$exp/$rel" "$pct" && ! task_done "$res/$exp/$archive/$rel" "$pct"; then
        fail "missing or not done: $res/$exp/$rel"
      fi
    done
    for kind in task val pred model meta; do
      rel=$(rel_file "$round" "$method" "$pct" "$kind")
      if ! is_moved "$exp" "$round" "$method" "$pct" && [ -e "$res/$exp/$rel" ] &&
        [ -e "$res/$exp/$archive/$rel" ]; then
        fail "both $res/$exp/$rel and its archive copy exist"
      fi
    done
    if [ "${listed[$key]}" = copy ]; then
      task_done "$(copy_source "$exp" "$round" "$method" "$pct")" "$pct" ||
        fail "missing or not done: $(copy_source "$exp" "$round" "$method" "$pct")"
      t=$(copy_dest "$exp" "$round" "$method" "$pct")
      if is_moved "$exp" "$round" "$method" "$pct" && [ -e "$t" ] &&
        ! cmp -s "$t" "$(copy_source "$exp" "$round" "$method" "$pct")"; then
        fail "$t differs from its source, and its CPU file is in the archive"
      fi
    fi
  done
  # a copy needs the same split in both experiments, round by round
  for round in $(for key in "${tasks[@]}"; do
    [ "${listed[$key]}" = copy ] && echo "${key#* }" | cut -d' ' -f1; done | sort -un); do
    need "$(split_file split-70-30 "$round")"
    need "$(split_file val-2018 "$round")"
    if [ -e "$(split_file split-70-30 "$round")" ] && [ -e "$(split_file val-2018 "$round")" ]; then
      same_split "$(split_file split-70-30 "$round")" "$(split_file val-2018 "$round")" ||
        fail "split differs, no copy for round $round"
    fi
  done
  # each experiment run as its runner did: splits, inputs, no STOP file,
  # no first-layout table, and every task not on the list done
  for e in "${experiments[@]}"; do
    read -r exp n m ev <<<"$e"
    [ -e "$res/$exp/STOP" ] && fail "$res/$exp/STOP exists; the R script would stop"
    need "$res/$exp/inputs/labelled_samples.rds"
    [ "$ev" = all ] && need "$res/val-2018/inputs/validation_series_2018.rds"
    for method in ${m//,/ }; do
      # a missing input would be encoded again by the R script
      in_file=()
      case $method in ts_*) ;; *) in_file+=("$res/$exp/inputs/encoded_$method.rds") ;; esac
      if [ "$ev" = all ]; then
        case $method in
          ts_*) in_file+=("$res/$exp/inputs/val2018_series.rds") ;;
          *) in_file+=("$res/$exp/inputs/val2018_encoded_$method.rds") ;;
        esac
      fi
      for t in "${in_file[@]}"; do
        need "$t"
        if [ "$dry" = 1 ] && [ -e "$t" ]; then
          echo "input: $t, $(date -u -r "$t" +%FT%TZ)"
        fi
      done
    done
    for round in $(seq 1 "$n"); do
      need "$(split_file "$exp" "$round")"
      for method in ${m//,/ }; do
        t=$res/$exp/round-$(rr "$round")/split-70-30/round_$(rr "$round")_$method.csv
        [ -e "$t" ] && fail "first-layout table $t would recreate its tasks"
        for p in $percents; do
          [ -n "${listed[$exp $round $method $p]:-}" ] && continue
          is_trained "$exp" "$round" "$method" "$p" ||
            fail "not done and not on the list, the R script would train it: $exp round $round $method $p%"
        done
      done
    done
  done
  local cuda
  cuda=$(Rscript -e 'cat(torch::cuda_is_available())' 2>/dev/null) || cuda="an error"
  [ "$cuda" = TRUE ] || fail "torch::cuda_is_available() is $cuda; the GPU must be visible"
  if command -v nvidia-smi > /dev/null; then
    echo "processes on the GPU: $(nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -c . || true)"
  fi
}

# 2. moves; the task CSV last, so a task is moved only when all its files are
move_all() {
  local key exp round method pct kind
  for key in "${tasks[@]}"; do
    read -r exp round method pct <<<"$key"
    is_moved "$exp" "$round" "$method" "$pct" && continue
    for kind in model meta pred val task; do
      move_file "$exp" "$(rel_file "$round" "$method" "$pct" "$kind")"
    done
  done
}

# 3. copies of the GPU-trained val-2018 task CSVs
copy_all() {
  local key exp round method pct src dst
  for key in "${tasks[@]}"; do
    [ "${listed[$key]}" = copy ] || continue
    read -r exp round method pct <<<"$key"
    src=$(copy_source "$exp" "$round" "$method" "$pct")
    dst=$(copy_dest "$exp" "$round" "$method" "$pct")
    if [ -e "$dst" ] && is_moved "$exp" "$round" "$method" "$pct"; then
      continue
    fi
    n_copy=$((n_copy + 1))
    if [ "$dry" = 1 ]; then
      echo "copy: ${src#"$res"/} -> ${dst#"$res"/}"
      continue
    fi
    cp -p "$src" "$dst.tmp.$$"
    mv "$dst.tmp.$$" "$dst"
  done
}

train_keys() {
  local key
  for key in "${tasks[@]}"; do
    [ "${listed[$key]}" = train ] && echo "$key"
  done
  return 0
}
# a task trains unless it is moved and its new files are done; before the
# move its CPU files are done, so is_trained alone does not tell
to_train() { ! { is_moved "$@" && is_trained "$@"; }; }
count_trained() {
  local key n=0
  while read -r key; do
    # shellcheck disable=SC2086 # the key splits into its four fields
    to_train $key || n=$((n + 1))
  done < <(train_keys)
  echo "$n"
}

# 4. training, one experiment after another
train_all() {
  local e exp n m ev total key todo
  total=$(train_keys | wc -l)
  if [ "$dry" = 1 ]; then
    while read -r key; do
      # shellcheck disable=SC2086 # the key splits into its four fields
      to_train $key && echo "train: $key%"
    done < <(train_keys)
  else
    echo "tether-progress: $(count_trained)/$total"
  fi
  for e in "${experiments[@]}"; do
    read -r exp n m ev <<<"$e"
    todo=0
    while read -r key; do
      # shellcheck disable=SC2086 # the key splits into its four fields
      [[ $key == "$exp "* ]] && to_train $key && todo=$((todo + 1))
    done < <(train_keys)
    [ "$todo" -eq 0 ] && continue
    if [ "$dry" = 1 ]; then
      echo "run, $todo tasks: Rscript analysis/sbsr2027/accuracy_learning_curve.R $n $fracs $m hf $workers $res/$exp $ev"
      continue
    fi
    echo "training $exp: $todo tasks"
    # the R script counts the tasks of its own grid; this count replaces it
    if ! Rscript analysis/sbsr2027/accuracy_learning_curve.R "$n" "$fracs" "$m" hf \
      "$workers" "$res/$exp" "$ev" 2>&1 |
      while IFS= read -r line; do
        if [[ $line == tether-progress:* ]]; then
          echo "tether-progress: $(count_trained)/$total"
        else
          printf '%s\n' "$line"
        fi
      done; then
      echo "run_gpu_retrain.sh: accuracy_learning_curve.R failed on $exp" >&2
      exit 1
    fi
    while read -r key; do
      # shellcheck disable=SC2086 # the key splits into its four fields
      if [[ $key == "$exp "* ]] && ! is_trained $key; then
        echo "run_gpu_retrain.sh: not trained: $key%" >&2
        exit 1
      fi
    done < <(train_keys)
  done
  [ "$dry" = 1 ] || echo "tether-progress: $(count_trained)/$total"
}

n_move=0
n_copy=0
main() {
  check
  # a dry run lists what it would do even when a check failed
  if [ "$problems" -gt 0 ] && [ "$dry" = 0 ]; then
    echo "run_gpu_retrain.sh: $problems problems, see the lines above" >&2
    exit 1
  fi
  move_all
  copy_all
  train_all
  echo "listed tasks: ${#tasks[@]}; move: $n_move files; copy: $n_copy tasks; train: $(($(train_keys | wc -l) - $(count_trained))) of $(train_keys | wc -l) tasks"
  if [ "$problems" -gt 0 ]; then
    echo "run_gpu_retrain.sh: $problems problems, see the lines above" >&2
    exit 1
  fi
}
main "$@"
