#!/bin/sh
# tether-remote.sh: the server helper of agent-tether (design 9, 6.6).
# shellcheck disable=SC2015,SC2045,SC1007  # A && B || C is intended; ids are validated
# POSIX sh and POSIX tools only; awk may be mawk. Run from the root of the
# project repository: `sh .tether/tether-remote.sh SUBCOMMAND ARGS`.
# It writes only under .tether/jobs/ (git-ignored). Output is key=value.
HELPER_VERSION=2
JOBS=.tether/jobs
ROOT=$(pwd)
export GIT_OPTIONAL_LOCKS=0
GIT_PAGER=cat PAGER=cat LESS=
export GIT_PAGER PAGER LESS
umask 077

NL='
'

refuse() { # PREFIX WHY
    printf '%s.refused=%s\n' "$1" "$2"
    exit 4
}

utc() { date -u +%Y%m%dT%H%M%SZ; }
nap() { sleep 0.2 2>/dev/null || sleep 1; }

valid_id() {
    case "$1" in
    '' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

is_num() {
    case "$1" in
    '' | *[!0-9]*) return 1 ;;
    esac
    return 0
}

# stat_field PID N: field N of /proc/PID/stat counted after the command.
stat_field() {
    [ -r "/proc/$1/stat" ] || return 1
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk -v n="$2" '{print $n}'
}
# Field 22 of /proc/PID/stat is the 20th after "pid (comm) ".
stat_start() { stat_field "$1" 20; }

is_leader() {
    [ "$(stat_field "$1" 3)" = "$1" ] && [ "$(stat_field "$1" 4)" = "$1" ]
}

# Percentages are rounded up: "above 85" means 85.01 waits.
mem_used_pct() {
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        END { if (t > 0 && a != "") { p = (t - a) * 100 / t; i = int(p); if (p > i) i++; printf "%d\n", i } }' \
        "${TETHER_MEMINFO:-/proc/meminfo}" 2>/dev/null
}

gpu_used_pct() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi --query-gpu=memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null |
        awk -F, '{ if ($2 > 0) { p = $1 * 100 / $2; n++; if (p > m) m = p } }
            END { if (n > 0) { i = int(m); if (m > i) i++; printf "%d\n", i } }'
}

# cg_scan: reads the job's cgroup (v2 only; hooks TETHER_PROC_CGROUP and
# TETHER_CGROUP_ROOT). Sets cg_mlev (nearest level, leaf upwards,
# whose memory.max is a number) with cg_mmax cg_cur cg_ina, and cg_clev
# (nearest level whose cpu.max quota is a number) with cg_quota cg_period.
# All empty without cgroup v2 or without a limit.
cg_scan() {
    cg_mlev= cg_mmax= cg_cur= cg_ina= cg_clev= cg_quota= cg_period=
    cg_root=${TETHER_CGROUP_ROOT:-/sys/fs/cgroup}
    cg_p=$(sed -n 's/^0:://p' "${TETHER_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null | head -n1)
    case "$cg_p" in /*) ;; *) return 0 ;; esac
    cg_p=${cg_p#/}
    case "$cg_p" in *[!A-Za-z0-9._/@:\\-]* | *..*) return 0 ;; esac
    # Levels from the leaf up to and including the root ('.'): a private
    # cgroup namespace shows the leaf as '/', and a limit may sit at the
    # root of a deeper path.
    [ -n "$cg_p" ] || cg_p=.
    while :; do
        if [ -z "$cg_mlev" ]; then
            cg_v=$(head -n1 "$cg_root/$cg_p/memory.max" 2>/dev/null)
            if is_num "$cg_v" && [ "$cg_v" != 0 ]; then
                cg_mlev=$cg_p cg_mmax=$cg_v
                cg_cur=$(head -n1 "$cg_root/$cg_p/memory.current" 2>/dev/null)
                cg_ina=$(awk '$1 == "inactive_file" { print $2; exit }' "$cg_root/$cg_p/memory.stat" 2>/dev/null)
                is_num "$cg_cur" || cg_mlev=
                is_num "$cg_ina" || cg_ina=0
            fi
        fi
        if [ -z "$cg_clev" ]; then
            cg_q= cg_r=
            [ -r "$cg_root/$cg_p/cpu.max" ] && read -r cg_q cg_r _ <"$cg_root/$cg_p/cpu.max"
            if is_num "$cg_q" && is_num "$cg_r" && [ "$cg_q" != 0 ] && [ "$cg_r" != 0 ]; then
                cg_clev=$cg_p cg_quota=$cg_q cg_period=$cg_r
            fi
        fi
        case "$cg_p" in .) break ;; */*) cg_p=${cg_p%/*} ;; *) cg_p=. ;; esac
    done
    return 0
}

# mem_read: sets MEM_PCT (rounded up) and MEM_SRC (cgroup | host): the job
# cgroup's memory.current - inactive_file over memory.max when a level has a
# limit, else the host's meminfo.
mem_read() {
    cg_scan
    MEM_PCT= MEM_SRC=host
    if [ -n "$cg_mlev" ]; then
        MEM_PCT=$(awk -v c="$cg_cur" -v i="$cg_ina" -v m="$cg_mmax" 'BEGIN {
            u = c - i; if (u < 0) u = 0; p = u * 100 / m; k = int(p); if (p > k) k++
            printf "%d\n", k }')
        MEM_SRC=cgroup
    fi
    if [ -z "$MEM_PCT" ]; then
        MEM_PCT=$(mem_used_pct)
        MEM_SRC=host
    fi
}

# res_snap: one raw reading, one line of 17 fields ('-' = absent): uptime,
# cgroup usage_usec, cgroup read bytes, host busy jiffies, RAM used bytes,
# RAM limit bytes, CPU limit cores, limit source, host RAM used and total
# bytes, host cores, GPU util %, GPU used and total MiB, memory percent
# (rounded up) and its source, the fullest GPU's memory percent (rounded up).
res_snap() {
    cg_scan
    rs_up=$(awk '{ print $1; exit }' /proc/uptime 2>/dev/null)
    rs_ulev=${cg_clev:-$cg_mlev}
    rs_usec= rs_rb=
    if [ -n "$rs_ulev" ]; then
        rs_usec=$(awk '$1 == "usage_usec" { print $2; exit }' "$cg_root/$rs_ulev/cpu.stat" 2>/dev/null)
        rs_rb=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^rbytes=[0-9]+$/) { s += substr($i, 8); f = 1 } }
            END { if (f) printf "%.0f\n", s }' "$cg_root/$rs_ulev/io.stat" 2>/dev/null)
    fi
    rs_busy=$(awk '$1 == "cpu" { printf "%.0f\n", $2 + $3 + $4 + $7 + $8 + $9; exit }' \
        "${TETHER_PROC_STAT:-/proc/stat}" 2>/dev/null)
    rs_hc=$(grep -c '^cpu[0-9]' "${TETHER_PROC_STAT:-/proc/stat}" 2>/dev/null)
    rs_gpu=$(command -v nvidia-smi >/dev/null 2>&1 &&
        nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null |
        awk -F', *' '$2 > 0 { n++; u += $1; t += $2; if ($3 + 0 > m) m = $3 + 0
            if ($1 * 100 / $2 > f) f = $1 * 100 / $2 }
            END { if (n > 0) { i = int(f); if (f > i) i++; printf "%.0f %.0f %.0f %d\n", m, u, t, i } }')
    [ -n "$rs_gpu" ] || rs_gpu="- - - -"
    awk -v up="$rs_up" -v usec="$rs_usec" -v rb="$rs_rb" -v busy="$rs_busy" -v hc="$rs_hc" \
        -v mlev="$cg_mlev" -v cur="$cg_cur" -v ina="$cg_ina" -v mmax="$cg_mmax" \
        -v clev="$cg_clev" -v q="$cg_quota" -v per="$cg_period" -v gpu="$rs_gpu" '
        function nz(v) { return (v == "" ? "-" : v) }
        /^MemTotal:/ { t = $2 }
        /^MemAvailable:/ { a = $2 }
        END {
            ht = "-"; hu = "-"; pct = "-"
            if (t > 0) ht = t * 1024
            if (t > 0 && a != "") {
                hu = (t - a) * 1024; p = (t - a) * 100 / t; k = int(p); if (p > k) k++; pct = k
            }
            src = "host"; used = hu; lim = ht; msrc = "host"
            if (mlev != "") {
                u = cur - ina; if (u < 0) u = 0
                used = u; lim = mmax; src = "cgroup"; msrc = "cgroup"
                p = u * 100 / mmax; k = int(p); if (p > k) k++; pct = k
            }
            cl = (hc > 0 ? hc : "-")
            if (clev != "") { cl = q / per; src = "cgroup" }
            split(gpu, g, " ")
            printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", nz(up), nz(usec), nz(rb),
                nz(busy), nz(used), nz(lim), cl, src, hu, ht, nz(hc), g[1], g[2], g[3], pct, msrc, nz(g[4])
        }' "${TETHER_MEMINFO:-/proc/meminfo}" 2>/dev/null
}

# res_rec PREV CUR: one window record from two readings (rates over the
# time between them): uptime, CPU cores, RAM GiB, GPU %, GPU GiB, read MB/s,
# host cores, host RAM GiB, then the limits (CPU cores, RAM GiB, GPU GiB,
# host cores, host RAM GiB) and the source. '-' = absent.
res_rec() {
    awk -v p="$1" -v c="$2" 'BEGIN {
        split(p, a, " "); split(c, b, " ")
        dt = b[1] - a[1]
        cpu = "-"; rd = "-"; hcpu = "-"
        if (b[1] != "-" && a[1] != "-" && dt > 0) {
            if (a[2] != "-" && b[2] != "-") cpu = (b[2] - a[2]) / 1e6 / dt
            if (a[3] != "-" && b[3] != "-") rd = (b[3] - a[3]) / 1e6 / dt
            if (a[4] != "-" && b[4] != "-") hcpu = (b[4] - a[4]) / 100 / dt
        } else if (a[2] != "-" && b[2] != "-") cpu = 0
        if (cpu == "-" && hcpu != "-") cpu = hcpu
        if (cpu != "-" && cpu < 0) cpu = 0
        if (rd != "-" && rd < 0) rd = 0
        if (hcpu != "-" && hcpu < 0) hcpu = 0
        G = 1073741824
        printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", b[1], cpu,
            (b[5] == "-" ? "-" : b[5] / G), b[12], (b[13] == "-" ? "-" : b[13] / 1024), rd, hcpu,
            (b[9] == "-" ? "-" : b[9] / G), b[7], (b[6] == "-" ? "-" : b[6] / G),
            (b[14] == "-" ? "-" : b[14] / 1024), b[11], (b[10] == "-" ? "-" : b[10] / G), b[8]
    }'
}

# res_stats MODE: the window (records on stdin) as stats key=value lines:
# mean, min, max of every reading that is present, limits of the last record.
res_stats() {
    awk -v mode="$1" '
        function fmt(x,   s) { if (x < 0) x = 0; s = sprintf("%.1f", x); sub(/\.0$/, "", s); return s }
        function num(v) { return v != "-" && v != "" }
        function lim(k, v) { if (num(v)) printf "%s.limit=%s\n", k, fmt(v) }
        function emit(k, col, isint,   i, n, s, lo, hi, v) {
            n = 0
            for (i = 1; i <= NR; i++) {
                v = r[i, col]
                if (!num(v)) continue
                v += 0
                if (n == 0 || v < lo) lo = v
                if (n == 0 || v > hi) hi = v
                s += v; n++
            }
            if (n == 0) return 0
            if (isint) {
                printf "%s.mean=%d\n%s.min=%d\n%s.max=%d\n", k, int(s / n + 0.5), k, int(lo + 0.5), k, int(hi + 0.5)
            } else {
                printf "%s.mean=%s\n%s.min=%s\n%s.max=%s\n", k, fmt(s / n), k, fmt(lo), k, fmt(hi)
            }
            return 1
        }
        { for (i = 1; i <= 14; i++) r[NR, i] = $i }
        END {
            if (NR == 0) exit
            span = r[NR, 1] - r[1, 1]; if (span < 0 || r[NR, 1] == "-") span = 0
            printf "window.mode=%s\nwindow.n=%d\nwindow.span_s=%d\nlimit.source=%s\n", mode, NR, span, r[NR, 14]
            emit("cpu_cores", 2, 0); lim("cpu_cores", r[NR, 9])
            emit("ram_gib", 3, 0); lim("ram_gib", r[NR, 10])
            emit("gpu_pct", 4, 1)
            emit("gpu_mem_gib", 5, 0); lim("gpu_mem_gib", r[NR, 11])
            emit("read_mbs", 6, 0)
            emit("host_cores", 7, 0); lim("host_cores", r[NR, 12])
            emit("host_ram_gib", 8, 0); lim("host_ram_gib", r[NR, 13])
        }'
}

# card_keys: keeps the stats lines the card uses (mean, max and limit of CPU,
# RAM and GPU memory; mean and max of GPU %); the stats file keeps them all.
card_keys() {
    grep -E '^stats\.((cpu_cores|ram_gib|gpu_mem_gib)\.(mean|max|limit)|gpu_pct\.(mean|max))='
}

# res_instant: one reading as stats lines: two reads one second apart.
res_instant() {
    ri_a=$(res_snap)
    sleep 1
    ri_b=$(res_snap)
    res_rec "$ri_a" "$ri_b" | res_stats instant | sed 's/^/stats./' | card_keys
}

# job_state DIR: running | ended | starting | dead (no exit file, no process)
job_state() {
    d=$1
    if [ -f "$d/exit" ]; then
        echo ended
        return
    fi
    if [ ! -s "$d/pid" ]; then
        echo starting
        return
    fi
    jp=$(cat "$d/pid")
    jst=$(cat "$d/starttime" 2>/dev/null)
    if is_num "$jp" && kill -0 "$jp" 2>/dev/null &&
        [ "$(stat_start "$jp")" = "$jst" ]; then
        echo running
    else
        echo dead
    fi
}

cmd_version() { printf 'helper.version=%s\n' "$HELPER_VERSION"; }

# check_script PREFIX SCRIPT: refuses (exit 4) unless SCRIPT is a relative,
# tracked, unmodified regular file of this repository.
check_script() {
    p=$1 script=$2
    case "$script" in '' | /* | -*) refuse "$p" bad_script ;; esac
    case "/$script/" in */../* | */./* | *//*) refuse "$p" bad_script ;; esac
    case "$script" in *[!A-Za-z0-9._/-]*) refuse "$p" bad_script ;; esac
    [ -f "$script" ] && [ ! -L "$script" ] || refuse "$p" script_missing
    git cat-file -e "HEAD:$script" 2>/dev/null || refuse "$p" script_untracked
    [ -z "$(git status --porcelain -- "$script" 2>/dev/null)" ] ||
        refuse "$p" script_modified
}

cmd_script() {
    if [ -L .tether ] || [ -L "$JOBS" ]; then refuse script tether_dir_is_a_link; fi
    check_script script "$1"
    printf 'script.ok=yes\n'
}

cmd_start() {
    [ "$#" -ge 4 ] || refuse start bad_call
    id=$1 needs=$2
    shift 2
    [ "$1" = "--" ] || refuse start bad_call
    shift
    script=$1
    shift
    valid_id "$id" || refuse start bad_id
    case "$needs" in gpu | cpu) ;; *) refuse start bad_needs ;; esac
    for a in "$@"; do
        case "$a" in
        *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'$'* | *'`'* | *"$NL"*)
            refuse start unsafe_arg
            ;;
        esac
    done
    check_script start "$script"
    command -v setsid >/dev/null 2>&1 || refuse start no_setsid
    if [ -L .tether ] || [ -L "$JOBS" ]; then refuse start tether_dir_is_a_link; fi
    if [ -e "$JOBS" ] && [ ! -d "$JOBS" ]; then refuse start jobs_not_a_directory; fi
    mkdir -p "$JOBS" || refuse start no_jobs_dir
    d=$JOBS/$id
    mkdir "$d" 2>/dev/null || refuse start id_exists
    commit=$(git rev-parse HEAD)
    printf '%s\n' "$commit" >"$d/commit"
    printf '%s\n' "$needs" >"$d/needs"
    { printf '%s\n' "$script"; for a in "$@"; do printf '%s\n' "$a"; done; } >"$d/cmd"
    : >"$d/log"
    setsid sh "$ROOT/.tether/tether-remote.sh" _wrap "$id" >>"$d/log" 2>&1 </dev/null &
    i=0
    while [ "$i" -lt 15 ] && [ ! -s "$d/pid" ]; do
        nap
        i=$((i + 1))
    done
    printf 'start.id=%s\n' "$id"
    printf 'start.launched=yes\n'
}

cmd__wrap() {
    id=$1
    valid_id "$id" || exit 2
    d=$JOBS/$id
    trap ':' TERM INT
    trap '' HUP
    printf '%s\n' "$(stat_start $$)" >"$d/starttime"
    printf '%s\n' "$$" >"$d/pid.tmp"
    mv -f "$d/pid.tmp" "$d/pid"
    commit=$(cat "$d/commit")
    set --
    while IFS= read -r line; do set -- "$@" "$line"; done <"$d/cmd"
    script=$1
    shift
    printf '=== %s start id=%s commit=%s script=%s\n' "$(utc)" "$id" "$commit" "$script"
    sh "$ROOT/.tether/tether-remote.sh" sentinel "$id" &
    if command -v bash >/dev/null 2>&1; then
        bash "$script" "$@"
    else
        sh "$script" "$@"
    fi
    rc=$?
    printf '=== %s end exit=%s\n' "$(utc)" "$rc"
    printf '%s\n' "$rc" >"$d/exit.tmp"
    mv -f "$d/exit.tmp" "$d/exit"
    exit "$rc"
}

cmd_sentinel() {
    id=$1
    valid_id "$id" || exit 2
    d=$JOBS/$id
    every=${SENTINEL_EVERY:-5}
    win=${SENTINEL_WINDOW_S:-300}
    kpct=${SENTINEL_KILL_PCT:-95}
    is_num "$every" && [ "$every" -ge 1 ] || every=5
    is_num "$win" && [ "$win" -ge 1 ] || win=300
    is_num "$kpct" || kpct=95
    cap=$((win / every))
    [ "$cap" -le 720 ] || cap=720
    [ "$cap" -ge 1 ] || cap=1
    trap ':' TERM INT
    trap '' HUP
    [ -s "$d/pid" ] || exit 0
    pid=$(cat "$d/pid")
    st=$(cat "$d/starttime" 2>/dev/null)
    # The window lives in this shell only: one record per sample, the last
    # $cap kept, statistics recomputed and the stats file overwritten.
    W=
    prev=$(res_snap)
    sleep 1
    waited=$every
    # One-second slices: the sentinel notices the end of the job within a
    # second and needs no signal (a signal can be lost between samples).
    while :; do
        [ -f "$d/exit" ] && exit 0
        kill -0 "$pid" 2>/dev/null || exit 0
        if [ "$waited" -ge "$every" ]; then
            waited=0
            cur=$(res_snap)
            rec=$(res_rec "$prev" "$cur")
            prev=$cur
            W=$(printf '%s\n%s\n' "$W" "$rec" | sed '/^$/d' | tail -n "$cap")
            # shellcheck disable=SC2086
            set -- $cur
            pct=${15} psrc=${16}
            is_num "$pct" || pct=
            gpu=${17}
            is_num "$gpu" || gpu=
            state=ok
            if is_num "$pct" && [ "$pct" -gt "$kpct" ] &&
                [ "$(stat_start "$pid")" = "$st" ]; then
                state=killed
                if [ "$psrc" = cgroup ]; then
                    printf '=== %s sentinel kill mem_used_pct=%s threshold=%s source=cgroup\n' \
                        "$(utc)" "$pct" "$kpct" >>"$d/log"
                else
                    printf '=== %s sentinel kill mem_used_pct=%s threshold=%s\n' \
                        "$(utc)" "$pct" "$kpct" >>"$d/log"
                fi
            fi
            printf '%s\n' "$W" | res_stats rolling >"$d/stats.new"
            mv -f "$d/stats.new" "$d/stats"
            {
                printf 'sampled_utc=%s\n' "$(utc)"
                printf 'mem_used_pct=%s\n' "$pct"
                [ -n "$gpu" ] && printf 'gpu_used_pct=%s\n' "$gpu"
                printf 'state=%s\n' "$state"
            } >"$d/sentinel.new"
            mv -f "$d/sentinel.new" "$d/sentinel"
            if [ "$state" = killed ]; then
                kill -s TERM -- "-$pid" 2>/dev/null
                sleep 10
                if [ ! -f "$d/exit" ] && [ "$(stat_start "$pid")" = "$st" ]; then
                    kill -s KILL -- "-$pid" 2>/dev/null
                fi
                exit 0
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

cmd_confirm() {
    id=$1
    if ! valid_id "$id" || [ ! -d "$JOBS/$id" ] || [ -L "$JOBS/$id" ] ||
        [ ! -s "$JOBS/$id/pid" ]; then
        printf 'confirm.confirmed=no\nconfirm.state=no_pid\n'
        exit 1
    fi
    d=$JOBS/$id
    pid=$(cat "$d/pid")
    st=$(cat "$d/starttime" 2>/dev/null)
    first=$(head -n1 "$d/log" 2>/dev/null)
    hdr=no
    case "$first" in
    "=== "*" start id=$id commit="*) hdr=yes ;;
    esac
    state=$(job_state "$d")
    printf 'confirm.pid=%s\nconfirm.starttime=%s\n' "$pid" "$st"
    case "$state" in
    running) cstate=running ;;
    ended) cstate=ended ;;
    *) cstate=not_running ;;
    esac
    printf 'confirm.state=%s\n' "$cstate"
    if [ "$cstate" = ended ]; then
        printf 'confirm.exit=%s\n' "$(cat "$d/exit")"
    fi
    if [ "$hdr" = yes ] && [ "$cstate" != not_running ]; then
        printf 'confirm.confirmed=yes\n'
        exit 0
    fi
    printf 'confirm.confirmed=no\n'
    exit 1
}

cmd_jobs() {
    for d in $(ls -r "$JOBS" 2>/dev/null); do
        valid_id "$d" || continue
        dir=$JOBS/$d
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        state=$(job_state "$dir")
        commit=$(head -n1 "$dir/commit" 2>/dev/null)
        script=$(head -n1 "$dir/cmd" 2>/dev/null)
        [ -n "$commit" ] || commit=-
        [ -n "$script" ] || script=-
        case "$state" in
        running | starting) printf 'job.%s=%s commit=%s script=%s\n' "$d" "$state" "$commit" "$script" ;;
        ended) printf 'job.%s=ended exit=%s commit=%s script=%s\n' "$d" "$(cat "$dir/exit")" "$commit" "$script" ;;
        *) printf 'job.%s=ended exit=unknown commit=%s script=%s\n' "$d" "$commit" "$script" ;;
        esac
    done
}

cmd_log() {
    id=$1
    valid_id "$id" || refuse log bad_id
    d=$JOBS/$id
    [ -d "$d" ] && [ ! -L "$d" ] || refuse log unknown_job
    l=$d/log
    [ -f "$l" ] && [ ! -L "$l" ] || refuse log no_log
    case "$2" in
    count)
        [ -n "$3" ] || refuse log bad_pattern
        n=$(grep -c -E -e "$3" "$l" 2>/dev/null)
        [ "$?" -le 1 ] || refuse log bad_pattern
        printf 'log.count=%s\n' "${n:-0}"
        ;;
    grep)
        is_num "$3" && [ -n "$4" ] || refuse log bad_call
        grep -E -e "$4" "$l" 2>/dev/null | tail -n "$3"
        ;;
    *)
        is_num "$2" && [ "$2" -ge 1 ] && [ "$2" -le 1000 ] || refuse log bad_call
        tail -n "$2" "$l"
        ;;
    esac
    exit 0
}

cmd_stop() {
    id=$1 given=$2 mode=$3
    valid_id "$id" || refuse stop invalid_id
    d=$JOBS/$id
    [ -d "$d" ] && [ ! -L "$d" ] || refuse stop unknown_job
    [ -s "$d/pid" ] && [ -s "$d/starttime" ] || refuse stop no_pid
    pid=$(cat "$d/pid")
    rec=$(cat "$d/starttime")
    is_num "$pid" && [ "$pid" -gt 1 ] || refuse stop bad_pid
    is_num "$given" || refuse stop bad_starttime
    [ "$given" = "$rec" ] || refuse stop starttime_mismatch
    if [ -f "$d/exit" ] || ! kill -0 "$pid" 2>/dev/null; then
        printf 'stop.sent=none\nstop.state=ended\n'
        exit 0
    fi
    [ "$(stat_start "$pid")" = "$rec" ] || refuse stop starttime_changed
    is_leader "$pid" || refuse stop not_session_leader
    kill -s TERM -- "-$pid" 2>/dev/null
    sent=TERM
    i=0
    while [ "$i" -lt 50 ]; do
        [ -f "$d/exit" ] && break
        kill -0 "$pid" 2>/dev/null || break
        nap
        i=$((i + 1))
    done
    if [ "$mode" = kill ] && [ ! -f "$d/exit" ] && kill -0 "$pid" 2>/dev/null; then
        sleep 10
        if [ ! -f "$d/exit" ] && kill -0 "$pid" 2>/dev/null &&
            [ "$(stat_start "$pid")" = "$rec" ]; then
            kill -s KILL -- "-$pid" 2>/dev/null
            sent=KILL
            sleep 1
        fi
    fi
    if [ -f "$d/exit" ] || ! kill -0 "$pid" 2>/dev/null; then
        printf 'stop.sent=%s\nstop.state=ended\n' "$sent"
        exit 0
    fi
    printf 'stop.sent=%s\nstop.state=running\n' "$sent"
    exit 1
}

# cmd_fetch PATH MAXBYTES: verifies on the server, then prints size, sha256,
# commit and the content as one base64 line. Refusals: fetch.refused=<why>.
cmd_fetch() {
    p=$1 max=$2
    is_num "$max" || refuse fetch bad_call
    case "$p" in '' | /* | -*) refuse fetch bad_path ;; esac
    case "/$p/" in */../* | */./* | *//*) refuse fetch bad_path ;; esac
    case "$p" in *[!A-Za-z0-9._/-]*) refuse fetch bad_path ;; esac
    acc=
    oldifs=$IFS
    IFS=/
    for part in $p; do
        acc=${acc:+$acc/}$part
        if [ -L "$acc" ]; then IFS=$oldifs; refuse fetch symlink; fi
    done
    IFS=$oldifs
    [ -e "$p" ] || refuse fetch not_found
    [ -f "$p" ] || refuse fetch not_a_regular_file
    size=$(wc -c <"$p" | tr -d ' ')
    [ "$size" -le "$max" ] || refuse fetch too_large
    sum=$(sha256sum "$p" | awk '{print $1}')
    commit=untracked
    case "$p" in
    .tether/jobs/*/*)
        jid=${p#.tether/jobs/}
        jid=${jid%%/*}
        if valid_id "$jid" && [ -f "$JOBS/$jid/commit" ]; then
            commit=$(head -n1 "$JOBS/$jid/commit")
        fi
        ;;
    *)
        if git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
            commit=$(git log -1 --format=%H -- "$p" 2>/dev/null)
            [ -n "$commit" ] || commit=untracked
        fi
        ;;
    esac
    printf 'fetch.bytes=%s\nfetch.sha256=%s\nfetch.commit=%s\n' "$size" "$sum" "$commit"
    printf 'fetch.data=%s\n' "$(base64 "$p" | tr -d '\n')"
}

cmd_guard() {
    needs=$1 memmax=$2 gpumax=$3 only=$4
    case "$needs" in gpu | cpu) ;; *) refuse guard bad_needs ;; esac
    is_num "$memmax" || memmax=85
    is_num "$gpumax" || gpumax=85
    mem_read
    mem=$MEM_PCT
    gpu=$(gpu_used_pct)
    [ -n "$mem" ] && printf 'mem.used_pct=%s\nmem.source=%s\n' "$mem" "$MEM_SRC"
    [ -n "$gpu" ] && printf 'gpu.used_pct=%s\n' "$gpu"
    reason=
    if is_num "$mem" && [ "$mem" -gt "$memmax" ]; then
        reason=mem_high
    elif [ "$needs" = gpu ] && is_num "$gpu" && [ "$gpu" -gt "$gpumax" ]; then
        reason=gpu_mem_high
    elif [ "$only" != resources ]; then
        for dd in "$JOBS"/*; do
            [ -d "$dd" ] || continue
            if [ "$(cat "$dd/needs" 2>/dev/null)" = "$needs" ] &&
                [ "$(job_state "$dd")" = running ]; then
                reason=own_job_running
            fi
        done
    fi
    if [ -n "$reason" ]; then
        printf 'guard=wait\nreason=%s\n' "$reason"
        exit 1
    fi
    printf 'guard=go\n'
}

# job_progress DIR: run.elapsed_s from the pid file's mtime (written when the
# job starts) and the last strict `tether-progress: N/M` line of the log.
job_progress() {
    jp_t=$(date -r "$1/pid" +%s 2>/dev/null || stat -c %Y "$1/pid" 2>/dev/null)
    if is_num "$jp_t"; then
        jp_e=$(($(date +%s) - jp_t))
        [ "$jp_e" -ge 0 ] || jp_e=0
        printf 'run.elapsed_s=%s\n' "$jp_e"
    fi
    [ -f "$1/log" ] && [ ! -L "$1/log" ] || return 0
    grep -E '^tether-progress: [0-9]{1,9}/[0-9]{1,9}$' "$1/log" 2>/dev/null |
        awk '{ split($2, a, "/"); if (a[2] + 0 >= 1 && a[1] + 0 <= a[2] + 0) { d = a[1] + 0; t = a[2] + 0; ok = 1 } }
            END { if (ok) printf "progress.done=%d\nprogress.total=%d\n", d, t }'
}

cmd_status() {
    printf 'helper.version=%s\n' "$HELPER_VERSION"
    printf 'server.time_utc=%s\n' "$(utc)"
    printf 'repo.head=%s\n' "$(git rev-parse HEAD 2>/dev/null)"
    printf 'repo.branch=%s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        printf 'repo.dirty=yes\n'
    else
        printf 'repo.dirty=no\n'
    fi
    run=0 end=0 listed=0 newest= live=
    for d in $(ls -r "$JOBS" 2>/dev/null); do
        valid_id "$d" || continue
        dir=$JOBS/$d
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        [ -n "$newest" ] || newest=$d
        js=$(job_state "$dir")
        [ "$js" = running ] && [ -z "$live" ] && live=$d
        case "$js" in
        running | starting) run=$((run + 1)); state=running ;;
        *) end=$((end + 1)); state=ended ;;
        esac
        if [ "$listed" -lt 5 ]; then
            listed=$((listed + 1))
            if [ "$state" = ended ] && [ -f "$dir/exit" ]; then
                printf 'job.%s=ended exit=%s\n' "$d" "$(cat "$dir/exit")"
            else
                printf 'job.%s=%s\n' "$d" "$state"
            fi
        fi
    done
    printf 'jobs.running=%s\njobs.ended=%s\n' "$run" "$end"
    if [ -n "$newest" ] && [ -f "$JOBS/$newest/sentinel" ]; then
        s=$(sed -n 's/^state=//p' "$JOBS/$newest/sentinel" | head -n1)
        p=$(sed -n 's/^mem_used_pct=//p' "$JOBS/$newest/sentinel" | head -n1)
        t=$(sed -n 's/^sampled_utc=//p' "$JOBS/$newest/sentinel" | head -n1)
        printf 'sentinel.%s=%s mem_used_pct=%s sampled=%s\n' "$newest" "$s" "$p" "$t"
    fi
    mem_read
    [ -n "$MEM_PCT" ] && printf 'mem.used_pct=%s\nmem.source=%s\n' "$MEM_PCT" "$MEM_SRC"
    # The newest running job's window; else one instant reading.
    if [ -n "$live" ] && [ -f "$JOBS/$live/stats" ] && [ ! -L "$JOBS/$live/stats" ] &&
        grep -q '^window\.n=' "$JOBS/$live/stats" 2>/dev/null; then
        grep -E '^[a-z_]+(\.[a-z_]+)?=[a-z0-9.]+$' "$JOBS/$live/stats" | sed 's/^/stats./' | card_keys
    else
        res_instant
    fi
    [ -z "$live" ] || job_progress "$JOBS/$live"
    g=$(gpu_used_pct)
    [ -n "$g" ] && printf 'gpu.used_pct=%s\n' "$g"
    cmd_guard "${1:-gpu}" "${2:-85}" "${3:-85}" | grep -v 'used_pct=' | awk '
        /^guard=/ { g = $0 } /^reason=/ { r = $0 }
        END { if (r != "") print g " " r; else if (g != "") print g }'
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        printf 'server.agent_forwarding=yes\n'
    else
        printf 'server.agent_forwarding=no\n'
    fi
}

sub=$1
[ "$#" -gt 0 ] && shift
case "$sub" in
version) cmd_version ;;
status) cmd_status "$1" "$2" "$3" ;;
guard) cmd_guard "$1" "$2" "$3" "$4" ;;
start) cmd_start "$@" ;;
_wrap) cmd__wrap "$1" ;;
sentinel) cmd_sentinel "$1" ;;
confirm) cmd_confirm "$1" ;;
jobs) cmd_jobs ;;
log) cmd_log "$1" "$2" "$3" "$4" ;;
stop) cmd_stop "$1" "$2" "$3" ;;
script) cmd_script "$1" ;;
fetch) cmd_fetch "$1" "$2" ;;
*)
    echo "usage: tether-remote.sh version|status|guard|script|fetch|start|confirm|jobs|log|stop" >&2
    exit 2
    ;;
esac
