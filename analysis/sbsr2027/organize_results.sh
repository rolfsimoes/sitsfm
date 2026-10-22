#!/bin/bash
# organize_results.sh -- move the outputs of the SBSR 2027 experiments from
# their first folders in data/results/ into data/results/sbsr2027/, the
# layout that analysis/sbsr2027/*.R read and write (see README.md):
#   split-70-30/  the 10-round experiment, its checks and logs
#   val-2018/     round 1 also scored on the 24,000 points of 2018
#
# Without --apply it prints the plan and changes nothing. With --apply it
# moves each file with mv on the same file system: a symbolic link moves
# as a link, never its target. A moved link whose target this run also
# moves is then re-pointed to the new path, as a relative link; the plan
# lists these links. Before moving it writes the sha256 of every
# file to data/results/sbsr2027/organize_manifest_<time>.tsv (link: the
# link text), and after moving it checks each one at its new path. It
# never deletes or overwrites a regular file, and it refuses to move anything if a
# target exists. It removes only the folders that the move left empty.
# Files it does not recognise are listed and stay where they are.
#
# Usage: analysis/sbsr2027/organize_results.sh [--apply]
#   --apply       move the files; without it, print the plan only
#   -h, --help    this help
#   --version     the version
#
# Run from the sitsfm root. Exit status: 0 on success; 1 if a target
# exists, the plan has two moves to one target, a source is on another
# file system, a check after the move fails or a link under
# data/results/sbsr2027 points to nothing; 2 on a wrong argument.
set -uo pipefail

VERSION=0.1.0
APPLY=0
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        --version) echo "organize_results.sh $VERSION"; exit 0 ;;
        --apply) APPLY=1; shift ;;
        *) echo "organize_results.sh: unknown argument '$1'; see --help" >&2; exit 2 ;;
    esac
done

if [ ! -f analysis/sbsr2027/organize_results.sh ] || [ ! -d data/results ]; then
    echo "organize_results.sh: run it from the sitsfm root" >&2
    exit 2
fi

RES=data/results
NEW=$RES/sbsr2027
SPLIT=$NEW/split-70-30
VAL=$NEW/val-2018

SRC=()
DST=()
UNKNOWN=()
ABSENT=()
EMPTY=()

add() { SRC+=("$1"); DST+=("$2"); }

# every file and link under a folder, moved to the same relative path
add_tree() {
    local from=$1 to=$2 f d
    [ -d "$from" ] || { ABSENT+=("$from"); return; }
    while IFS= read -r -d '' f; do
        add "$f" "$to/${f#"$from"/}"
    done < <(find "$from" -mindepth 1 \( -type f -o -type l \) -print0 | sort -z)
    while IFS= read -r -d '' d; do
        EMPTY+=("$d")
    done < <(find "$from" -mindepth 1 -type d -empty -print0 | sort -z)
}

add_file() {
    if [ -e "$1" ] || [ -L "$1" ]; then add "$1" "$2/${1##*/}"; else ABSENT+=("$1"); fi
}

# round_RR_<anything>: the round folder of an experiment
round_of() { [[ $1 =~ ^round_([0-9]{2})_ ]] && echo "round-${BASH_REMATCH[1]}"; }

# files of the round_RR_* kind inside a folder, by round
add_by_round() {
    local from=$1 exp=$2 sub=$3 re=$4 f name
    while IFS= read -r -d '' f; do
        name=${f##*/}
        if [[ ! -d $f || -L $f ]] && [[ $name =~ $re ]]; then
            add "$f" "$exp/$(round_of "$name")/$sub/$name"
        else
            UNKNOWN+=("$f")
        fi
    done < <(find "$from" -mindepth 1 -maxdepth 1 -print0 | sort -z)
}

TASK_RE='^round_[0-9]{2}_.+_f[0-9]{3}\.csv$'
MODEL_RE='^round_[0-9]{2}_.+_f[0-9]{3}\.(rds|json)$'

# an experiment folder written by accuracy_learning_curve.R before sbsr2027;
# a third argument says that check_learning_curve.R wrote comparison.csv there
add_experiment() {
    local from=$1 exp=$2 with_cmp=${3:-} f name
    [ -d "$from" ] || { ABSENT+=("$from"); return; }
    while IFS= read -r -d '' f; do
        name=${f##*/}
        if [ -d "$f" ] && [ ! -L "$f" ]; then
            case $name in
                # summaries made before sbsr2027 are of the internal test
                summary) add_tree "$f" "$exp/summary/split-70-30" ;;
                models) add_by_round "$f" "$exp" models "$MODEL_RE" ;;
                val2018) add_by_round "$f" "$exp" val-2018 '^round_[0-9]{2}_.+_f[0-9]{3}(_pred)?\.csv$' ;;
                *) UNKNOWN+=("$f/") ;;
            esac
            continue
        fi
        case $name in
            labelled_samples.rds|encoded_*.rds|val2018_series.rds|val2018_encoded_*.rds)
                add "$f" "$exp/inputs/$name" ;;
            comparison.csv)
                if [ -n "$with_cmp" ]; then add "$f" "$exp/round-01/$name"; else UNKNOWN+=("$f"); fi ;;
            *.log) add "$f" "$exp/logs/$name" ;;
            *)
                if [[ $name =~ ^round_[0-9]{2}_split\.rds$ ]]; then
                    add "$f" "$exp/$(round_of "$name")/$name"
                elif [[ $name =~ $TASK_RE ]]; then
                    add "$f" "$exp/$(round_of "$name")/split-70-30/$name"
                else
                    UNKNOWN+=("$f")
                fi ;;
        esac
    done < <(find "$from" -mindepth 1 -maxdepth 1 -print0 | sort -z)
}

#
# 1. The plan
#
add_experiment "$RES/learning_curve" "$SPLIT"
for name in learning_curve_check learning_curve_check_tempcnn tempcnn_repro_a tempcnn_repro_b; do
    add_tree "$RES/$name" "$SPLIT/checks/$name"
done
add_file "$RES/check_tempcnn.out" "$SPLIT/logs"
add_file "$RES/tempcnn_repro.log" "$SPLIT/logs"

add_file "$RES/validation_2018/validation_series_2018.rds" "$VAL/inputs"
# written by check_learning_curve.R of round 1, so its comparison.csv is round 1
add_experiment "$RES/validation_2018/learning_curve" "$VAL" comparison
add_tree "$RES/validation_2018/check" "$VAL/checks/check-400"
for name in run.log check_stage.log memstat.log; do
    add_file "$RES/validation_2018/$name" "$VAL/logs"
done
for name in check all memstat; do
    add_file "$RES/validation_series_$name.log" "$VAL/logs"
done
if [ -d "$RES/validation_2018" ]; then
    while IFS= read -r -d '' f; do
        case ${f##*/} in
            learning_curve|check|validation_series_2018.rds|run.log|check_stage.log|memstat.log) ;;
            *) UNKNOWN+=("$f") ;;
        esac
    done < <(find "$RES/validation_2018" -mindepth 1 -maxdepth 1 -print0 | sort -z)
fi
#
# 2. Checks of the plan: targets free and unique, same file system
#
ERRORS=()
declare -A SEEN
dev_new=$(stat -L -c %d "$RES")
[ -d "$NEW" ] && dev_new=$(stat -L -c %d "$NEW")
for i in "${!SRC[@]}"; do
    s=${SRC[$i]}
    t=${DST[$i]}
    if [ -e "$t" ] || [ -L "$t" ]; then ERRORS+=("target exists: $t"); fi
    if [ -n "${SEEN[$t]:-}" ]; then ERRORS+=("two sources for $t: ${SEEN[$t]} and $s"); fi
    SEEN[$t]=$s
    if [ "$(stat -c %d "$s")" != "$dev_new" ]; then ERRORS+=("other file system: $s"); fi
done

# links: a link whose target also moves points to the old path afterwards
key() { echo "$(realpath -m "$(dirname "$1")")/${1##*/}"; }
declare -A NEW_PATH
for i in "${!SRC[@]}"; do NEW_PATH[$(key "${SRC[$i]}")]=${DST[$i]}; done
LINKS=()
RELINK_LINK=()
RELINK_TEXT=()
HARD=0
for i in "${!SRC[@]}"; do
    s=${SRC[$i]}
    if [ -L "$s" ]; then
        text=$(readlink "$s")
        case $text in /*) abs=$text ;; *) abs=$(dirname "$s")/$text ;; esac
        moved=${NEW_PATH[$(key "$abs")]:-}
        if [ -n "$moved" ]; then
            LINKS+=("$s -> $text (target moves to $moved)")
            RELINK_LINK+=("${DST[$i]}")
            RELINK_TEXT+=("$(realpath -m -s --relative-to="$(dirname "${DST[$i]}")" "$moved")")
        else
            LINKS+=("$s -> $text")
        fi
    elif [ "$(stat -c %h "$s")" -gt 1 ]; then
        HARD=$((HARD + 1))
    fi
done

print_list() {
    local title=$1
    shift
    echo "$title: $#"
    for x in "$@"; do echo "  $x"; done
}

if [ "$APPLY" -eq 0 ]; then
    echo "plan (nothing moved; run with --apply to move)"
    echo "moves: ${#SRC[@]}"
    for i in "${!SRC[@]}"; do echo "  ${SRC[$i]} => ${DST[$i]}"; done
    print_list "symbolic links, moved as links" "${LINKS[@]}"
    echo "links to re-point after the move: ${#RELINK_LINK[@]}"
    for i in "${!RELINK_LINK[@]}"; do echo "  ${RELINK_LINK[$i]} -> ${RELINK_TEXT[$i]}"; done
    echo "files with more than one hard link, moved as they are: $HARD"
    print_list "not recognised, not moved" "${UNKNOWN[@]}"
    print_list "empty folders, not moved" "${EMPTY[@]}"
    print_list "sources not found" "${ABSENT[@]}"
    print_list "errors" "${ERRORS[@]}"
    [ ${#ERRORS[@]} -eq 0 ] || exit 1
    exit 0
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_list "errors, nothing moved" "${ERRORS[@]}"
    exit 1
fi
if [ ${#SRC[@]} -eq 0 ]; then
    exit 0
fi

#
# 3. Manifest, written under a temporary name and renamed when complete
#
mkdir -p "$NEW" || exit 1
manifest=$NEW/organize_manifest_$(date -u +%Y%m%dT%H%M%SZ).tsv
if [ -e "$manifest" ]; then echo "organize_results.sh: $manifest exists" >&2; exit 1; fi
for i in "${!SRC[@]}"; do
    s=${SRC[$i]}
    if [ -L "$s" ]; then
        sum="link:$(readlink "$s")"
    else
        sum=$(sha256sum < "$s" | cut -d ' ' -f 1) || { echo "cannot read $s" >&2; exit 1; }
    fi
    printf '%s\t%s\t%s\n' "$sum" "$s" "${DST[$i]}"
done > "$manifest.tmp" || exit 1
mv -n -T "$manifest.tmp" "$manifest" || exit 1

#
# 4. Move, then check every file at its new path
#
FAILED=0
for i in "${!SRC[@]}"; do
    s=${SRC[$i]}
    t=${DST[$i]}
    mkdir -p "$(dirname "$t")" && mv -n -T -- "$s" "$t"
    if [ -e "$s" ] || [ -L "$s" ]; then
        echo "not moved: $s"
        FAILED=1
    fi
done
while IFS=$'\t' read -r sum s t; do
    case $sum in
        link:*)
            if [ ! -L "$t" ] || [ "link:$(readlink "$t")" != "$sum" ]; then
                echo "link differs: $t"
                FAILED=1
            fi ;;
        *)
            if [ -L "$t" ] || [ "$(sha256sum < "$t" 2>/dev/null | cut -d ' ' -f 1)" != "$sum" ]; then
                echo "sha256 differs: $t"
                FAILED=1
            fi ;;
    esac
done < "$manifest"

# moved links whose target this run moved: only a path that is a link
for i in "${!RELINK_LINK[@]}"; do
    l=${RELINK_LINK[$i]}
    [ -L "$l" ] || { echo "not a link, not re-pointed: $l"; FAILED=1; continue; }
    ln -sfn -- "${RELINK_TEXT[$i]}" "$l" || FAILED=1
done
# links under data/results/sbsr2027 that still point to nothing
while IFS= read -r -d '' l; do
    echo "dangling link: $l -> $(readlink "$l")"
    FAILED=1
done < <(find "$NEW" -xtype l -print0)

# folders left empty by the move, up to data/results (kept)
for s in "${SRC[@]}"; do
    d=$(dirname "$s")
    while [ "$d" != "$RES" ] && [ "$d" != . ] && [ -d "$d" ] && [ ! -L "$d" ]; do
        rmdir "$d" 2>/dev/null || break
        d=$(dirname "$d")
    done
done
exit $FAILED
