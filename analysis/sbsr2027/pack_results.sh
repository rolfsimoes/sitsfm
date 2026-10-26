#!/usr/bin/env bash
# pack_results.sh -- packs the CSV results of the SBSR 2027 experiments
# into one archive, so that one `tether fetch` brings them to the
# local machine. Only *.csv under data/results/sbsr2027 are packed (task
# files, per-point predictions *_pred.csv and summaries), with their
# relative paths; models, .rds files and logs are not. The folder export/
# is skipped. The archive and the sha256 manifest of the packed files
# (paths relative to data/results/sbsr2027, for `sha256sum -c`) are
# written under a temporary name and renamed at the end:
#   data/results/sbsr2027/export/sbsr2027_csv.tar.gz
#   data/results/sbsr2027/export/sbsr2027_csv.sha256
#
# Usage: analysis/sbsr2027/pack_results.sh [--no-pred]
#   --no-pred     leave out the *_pred.csv files (the largest ones); the
#                 files are then sbsr2027_csv_nopred.tar.gz and .sha256
#   -h, --help    this help
#   --version     the version
#
# Run from any directory; it works from the sitsfm root. It prints
# `tether-progress: N/M` lines, M being the number of files. Files that
# change while it runs are not detected; run it when no job writes them
# or check the manifest after the copy. Exit status: 0 on success; 1 if
# there is no CSV or the archive does not hold the files listed; 2 on a
# wrong argument.
set -euo pipefail

VERSION=0.1.0
nopred=0
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        --version) echo "pack_results.sh $VERSION"; exit 0 ;;
        --no-pred) nopred=1; shift ;;
        *) echo "pack_results.sh: unknown argument '$1'; see --help" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/../.."
res=data/results/sbsr2027
name=sbsr2027_csv
[ "$nopred" = 1 ] && name=sbsr2027_csv_nopred
out=$res/export
tmp=$out/.$name.$$

main() {
  mkdir -p "$out"
  trap 'rm -f "$tmp".*' EXIT
  skip=(-true)
  [ "$nopred" = 1 ] && skip=(! -name '*_pred.csv')
  # relative paths, sorted, NUL separated
  ( cd "$res" && find . -path ./export -prune -o -type f -name '*.csv' \
      "${skip[@]}" -print0 ) | sed -z 's,^\./,,' | LC_ALL=C sort -z > "$tmp.list"
  total=$(tr -cd '\0' < "$tmp.list" | wc -c)
  if [ "$total" -eq 0 ]; then
    echo "pack_results.sh: no CSV under $res" >&2
    exit 1
  fi
  echo "files: $total"
  echo "tether-progress: 0/$total"
  # hash in chunks of 500 files, so that progress is visible
  : > "$tmp.sha"
  chunk=()
  n=0
  while IFS= read -r -d '' f; do
    chunk+=("$f")
    if [ ${#chunk[@]} -eq 500 ]; then
      ( cd "$res" && sha256sum -- "${chunk[@]}" ) >> "$tmp.sha"
      n=$((n + 500))
      chunk=()
      echo "tether-progress: $n/$total"
    fi
  done < "$tmp.list"
  if [ ${#chunk[@]} -gt 0 ]; then
    ( cd "$res" && sha256sum -- "${chunk[@]}" ) >> "$tmp.sha"
  fi
  tar -C "$res" --null -T "$tmp.list" -czf "$tmp.tar.gz"
  # the archive must hold exactly the files listed
  got=$(tar -tzf "$tmp.tar.gz" | wc -l)
  if [ "$got" -ne "$total" ]; then
    echo "pack_results.sh: archive holds $got files, expected $total" >&2
    exit 1
  fi
  mv "$tmp.tar.gz" "$out/$name.tar.gz"
  mv "$tmp.sha" "$out/$name.sha256"
  echo "tether-progress: $total/$total"
  ls -l "$out/$name.tar.gz" "$out/$name.sha256" | awk '{print $5, $9}'
}
main "$@"
