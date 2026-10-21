#!/bin/bash
# memstat.sh -- run on the server next to a learning-curve run: sample RAM,
# GPU, CPU and read rate of the run's processes every STEP seconds and
# append the min, max and mean of each WINDOW as one line to LOG.
#
# RAM is `anon` of the cgroup memory.stat: memory.current also counts page
# cache, which the kernel reclaims before it kills a process. CPU and read
# rate come from /proc/<pid>/stat and /proc/<pid>/io over the processes
# of the run's session (the main R process and its PSOCK workers), so
# start the run and this script each with its own setsid. Exits when the
# run is gone. Reads only /proc, memory.stat, nvidia-smi and the results
# folder; writes only LOG.
#
# Usage: server/memstat.sh [options] LOG
#   --pattern P   pgrep -f pattern of the run's main process
#                 (default '[-]-file=analysis/accuracy_learning_curve')
#   --tasks DIR G count the files of DIR matching grep -E G (finished tasks)
#   --step S      seconds between samples (default 5)
#   --window W    seconds per line (default 300)
#   -h, --help    this help
#   --version     the version
#
# Start it detached, from the repository root, for example:
#   setsid nohup server/memstat.sh --tasks data/results/learning_curve \
#     'ae_centre_y_f[0-9]{3}[.]csv$' data/results/learning_curve/memstat.log \
#     > /dev/null 2>&1 < /dev/null &
set -uo pipefail

VERSION=0.1.2
PATTERN='[-]-file=analysis/accuracy_learning_curve'
TASK_DIR=
TASK_RE=
STEP=5
WINDOW=300
LOG=
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        --version) echo "memstat.sh $VERSION"; exit 0 ;;
        --pattern) PATTERN=$2; shift 2 ;;
        --tasks) TASK_DIR=$2; TASK_RE=$3; shift 3 ;;
        --step) STEP=$2; shift 2 ;;
        --window) WINDOW=$2; shift 2 ;;
        -?*) echo "memstat.sh: unknown option $1" >&2; exit 2 ;;
        *) [ -z "$LOG" ] || { echo "memstat.sh: one LOG only" >&2; exit 2; }
           LOG=$1; shift ;;
    esac
done
[ -n "$LOG" ] || { echo "usage: memstat.sh [options] LOG" >&2; exit 2; }
STAT=${MEMSTAT_CGROUP_STAT:-/sys/fs/cgroup/memory.stat}
SAMPLES="$LOG.samples"
TCK=$(getconf CLK_TCK)

root() { pgrep -o -f "$PATTERN"; }
# R starts the PSOCK workers through `sh -c "... &"`, so they are not
# children of the main process; they keep its session, started by setsid
session_pids() {
    ps -eo pid=,sid= | awk -v sid="$(ps -o sid= -p "$1" | tr -d ' ')" '$2 == sid {print $1}'
}

# Sets DELTA_READ (bytes) and DELTA_CPU (clock ticks) since the previous
# call over the tree; called without $( ), so that `seen` survives. A pid
# first seen counts in full; on the first call nothing counts.
# /proc/<pid>/io needs ptrace rights (Yama ptrace_scope 1 on the server
# hides it from a non-ancestor), so DELTA_READ is NA if no pid shows it.
declare -A seen_r=() seen_c=()
first=1
deltas() {
    local pid r c n_io=0
    declare -A cur_r=() cur_c=()
    DELTA_READ=0; DELTA_CPU=0
    for pid in $(session_pids "$1"); do
        c=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) || continue
        [ -n "$c" ] || continue
        cur_c[$pid]=$c
        [ "$first" = 0 ] && DELTA_CPU=$(( DELTA_CPU + c - ${seen_c[$pid]:-0} ))
        r=$(awk '$1 == "rchar:" {print $2}' "/proc/$pid/io" 2>/dev/null) || continue
        [ -n "$r" ] || continue
        cur_r[$pid]=$r; n_io=$(( n_io + 1 ))
        [ "$first" = 0 ] && DELTA_READ=$(( DELTA_READ + r - ${seen_r[$pid]:-0} ))
    done
    [ "$n_io" -gt 0 ] || DELTA_READ=NA
    seen_r=(); seen_c=()
    for pid in "${!cur_r[@]}"; do seen_r[$pid]=${cur_r[$pid]}; done
    for pid in "${!cur_c[@]}"; do seen_c[$pid]=${cur_c[$pid]}; done
    first=0
}
tasks() {
    [ -n "$TASK_DIR" ] || { echo NA; return; }
    ls "$TASK_DIR" 2>/dev/null | grep -cE "$TASK_RE"
}

main=$(root) || { echo "memstat.sh: no process matches $PATTERN" >&2; exit 1; }
[ -s "$LOG" ] || echo "time samples tasks ram_gb(min max mean) gpu_mem_gb(min max mean) gpu_util_pct(min max mean) read_mb_s(min max mean) cpu_cores(min max mean)" > "$LOG"
: > "$SAMPLES"
start=$(date +%s)
deltas "$main"
prev=$(date +%s.%N)
while kill -0 "$main" 2>/dev/null; do
    sleep "$STEP"
    deltas "$main"
    now=$(date +%s.%N)
    dt=$(awk -v a="$now" -v p="$prev" 'BEGIN {print a - p}')
    prev=$now
    # columns: RAM GB, GPU memory GB, GPU utilization %, read MB/s, CPU cores
    ram=$(awk '$1 == "anon" {printf "%.1f", $2 / 1e9}' "$STAT")
    gpu=$(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
        awk -F', *' 'NR == 1 {printf "%.1f %d", $1 * 1048576 / 1e9, $2}')
    rate=$(awk -v b="$DELTA_READ" -v t="$dt" 'BEGIN {if (b == "NA") print "NA"; else printf "%.1f", b / 1e6 / t}')
    cores=$(awk -v c="$DELTA_CPU" -v k="$TCK" -v t="$dt" 'BEGIN {printf "%.1f", c / k / t}')
    echo "${ram:-NA} ${gpu:-NA NA} $rate $cores" >> "$SAMPLES"
    if [ $(( $(date +%s) - start )) -ge "$WINDOW" ] || ! kill -0 "$main" 2>/dev/null; then
        awk -v t="$(date -u '+%Y-%m-%dT%H:%M:%S')" -v d="$(tasks)" '
            function upd(i, v) { if (v == "NA") return; n[i]++; s[i] += v
                if (n[i] == 1 || v < lo[i]) lo[i] = v; if (n[i] == 1 || v > hi[i]) hi[i] = v }
            function cell(i) { if (n[i]) return sprintf(" %.1f %.1f %.1f", lo[i], hi[i], s[i] / n[i])
                               return " NA NA NA" }
            { upd(1, $1); upd(2, $2); upd(3, $3); upd(4, $4); upd(5, $5) }
            END { print t " " NR " " d cell(1) cell(2) cell(3) cell(4) cell(5) }' "$SAMPLES" >> "$LOG"
        : > "$SAMPLES"
        start=$(date +%s)
    fi
done
rm -f "$SAMPLES"
