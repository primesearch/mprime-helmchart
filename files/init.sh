#!/bin/bash
# Init container: prepare mprime's working directory before mprime starts.
#
# The directory is a persistent volume, and mprime itself rewrites prime.txt (it adds the
# computer's GUID and its own bookkeeping), so this script never recreates the file. It creates
# prime.txt once, and on every start it only sets the keys the chart manages. Everything else
# in the file is left as mprime wrote it, so a restarted pod is still the same PrimeNet computer.
# Settings that depend on the node (threads and memory) are set by start.sh, every time mprime starts.
set -euo pipefail

dir=${MPRIME_DIR:?not set (the chart sets it in the pod spec)}
scripts=${SCRIPTS:?not set (the chart sets it in the pod spec)}
managed=$scripts/managed.tsv
cd "$dir"
source "$scripts/lib.sh"

if [ ! -e prime.txt ]; then
  echo "Creating prime.txt"
  printf 'V24OptionsConverted=1\nStressTester=0\n' > prime.txt
fi

while IFS=$'\t' read -r section key value || [ -n "${key:-}" ]; do
  [ -n "$key" ] || continue
  upsert "$section" "$key" "$value"
done < "$managed"

: "${USE_PRIMENET:?not set (the chart sets it in the pod spec)}"
: "${JOB_MODE:?not set (the chart sets it in the pod spec)}"
# A stable name. In a StatefulSet that is <prefix>-<the pod's number>, in a job it is the name of its slot. A
# ComputerID in config.prime is used instead of either.
if [ "$USE_PRIMENET" = 1 ] && ! grep -q -i -P '^-\tComputerID\t' "$managed"; then
  if [ "$JOB_MODE" = 1 ]; then
    upsert - ComputerID "${COMPUTER_ID:?}"
  else
    upsert - ComputerID "${COMPUTER_ID_PREFIX:?}-${POD_NAME##*-}"
  fi
fi

# A job's assignments are added to the worktodo once per Job. A pod that replaces a pre-empted one belongs to the
# same Job and must not add them again (the finished ones would run twice); the next Job that uses this slot
# has a new UID and adds its own.
if [ "$JOB_MODE" = 1 ]; then
  marker=.job-applied-${JOB_UID:?not set (the chart sets it in the pod spec)}
  if [ ! -e "$marker" ]; then
    echo "Adding this job's assignments to worktodo.txt"
    [ ! -s worktodo.txt ] || [ -z "$(tail -c 1 worktodo.txt)" ] || echo >> worktodo.txt
    cat "$scripts/job-worktodo.txt" >> worktodo.txt
    rm -f .job-applied-*
    touch "$marker"
  fi
fi

echo "---- prime.txt ----"
cat prime.txt
