#!/bin/bash
# Starts mprime. Runs every time the mprime container starts, including after a crash or an OOM kill
# (an init container would not run then), so the settings that depend on the node are always current:
# the thread count and the memory mprime may use.
set -euo pipefail

dir=${MPRIME_DIR:?not set (the chart sets it in the pod spec)}
scripts=${SCRIPTS:?not set (the chart sets it in the pod spec)}
managed=$scripts/managed.tsv
cd "$dir"
source "$scripts/lib.sh"

# Everything below comes from the pod spec (statefulset.yaml); stop if any of it is missing or not a number.
require_int CORES_PER_TEST CPU_LIMIT_CORES MEMORY_MB MEMORY_LIMIT_MB MEMORY_RESERVE_MB MEMORY_RESERVE_PERCENT MEMORY_MIN_MB JOB_MAX_WAIT_SECONDS
[[ ${JOB_MODE:-} == [01] ]] || { echo "ERROR: JOB_MODE must be 0 or 1" >&2; exit 1; }
[[ ${MEMORY_LIMIT_SET:-} == [01] ]] || { echo "ERROR: MEMORY_LIMIT_SET must be 0 or 1" >&2; exit 1; }

# A setting the user put in config.prime wins over what is worked out here.
user_set() { grep -q -i -P "^-\t$1\t" "$managed"; }

# Number of physical cores among the CPUs this container may run on. The kernel exports each CPU's
# hyperthread siblings (e.g. "0,8"), also inside containers, so CPUs with the same sibling list are one core.
physical_cores() {
  local list part cpu f key
  declare -A seen=()
  list=$(awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status)
  for part in ${list//,/ }; do
    for cpu in $(if [[ $part == *-* ]]; then seq "${part%-*}" "${part#*-}"; else echo "$part"; fi); do
      f=/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list
      # A CPU that is switched off has no use (and may have no topology files): don't count it.
      [ "$(cat "/sys/devices/system/cpu/cpu$cpu/online" 2>/dev/null || echo 1)" = 0 ] && continue
      if [ -r "$f" ]; then key=$(<"$f"); else key=$cpu; fi
      seen[$key]=1
    done
  done
  echo "${#seen[@]}"
}

# One worker per pod, using all the cores it is allowed: the CPU limit rounded up (CPU_LIMIT_CORES; with no
# limit, Kubernetes reports the node's CPUs), but never more than the physical cores. mprime does not gain
# from hyperthreads, and without affinity the kernel spreads the threads over the cores by itself.
# CORES_PER_TEST sets a fixed number instead.
if ! user_set CoresPerTest; then
  if [ "$CORES_PER_TEST" -gt 0 ]; then
    threads=$CORES_PER_TEST
  else
    cores=$(physical_cores)
    threads=$CPU_LIMIT_CORES
    [ "$threads" -gt 0 ] || threads=$cores
    [ "$threads" -le "$cores" ] || threads=$cores
    [ "$threads" -ge 1 ] || threads=1
    echo "CPU limit $CPU_LIMIT_CORES, $cores physical cores available: running $threads thread(s)"
  fi
  upsert - CoresPerTest "$threads"
fi

# Memory mprime may use. mprime defaults to nearly all of the NODE's RAM, ignoring the pod's limit, and its
# Memory setting is a target rather than a ceiling, so leave a reserve. MEMORY_MB sets a fixed number.
# Otherwise: the memory limit (MEMORY_LIMIT_MB) less the reserve. With no limit Kubernetes reports the node's
# allocatable memory instead (MEMORY_LIMIT_SET=0), and then what is free right now (MemAvailable) is used if
# that is smaller, so mprime does not grab memory other pods on the node are already using.
if ! user_set Memory; then
  if [ "$MEMORY_MB" -gt 0 ]; then
    mem=$MEMORY_MB
  elif [ "$MEMORY_LIMIT_MB" -gt 0 ]; then
    limit=$MEMORY_LIMIT_MB
    if [ "$MEMORY_LIMIT_SET" = 0 ]; then
      avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
      if [ -n "$avail" ] && [ "$avail" -gt 0 ] && [ "$avail" -lt "$limit" ]; then
        echo "No memory limit: node allocatable ${limit}MB, available now ${avail}MB"
        limit=$avail
      else
        echo "No memory limit: using the node's allocatable memory, ${limit}MB"
      fi
    fi
    mem=$(( limit - $MEMORY_RESERVE_MB - limit * $MEMORY_RESERVE_PERCENT / 100 ))
    # With a small limit the reserve could swallow everything, so never go below half of the limit (which is why
    # a limit of about 2 GiB is enough to get past the memoryMinMB check below).
    [ "$mem" -ge $(( limit / 2 )) ] || mem=$(( limit / 2 ))
    # mprime needs a real minimum to do useful work. Stop with a clear message rather than start and be killed
    # or crawl; the pod is retried with a back-off, so it picks up memory that frees up on the node.
    if [ "$mem" -lt "$MEMORY_MIN_MB" ]; then
      echo "ERROR: only ${mem}MB would be left for mprime (from a ${limit}MB limit), below the ${MEMORY_MIN_MB}MB minimum" >&2
      echo "       (config.memoryMinMB). Give the pod a bigger memory limit, or lower config.memoryReserveMB." >&2
      exit 1
    fi
    echo "Giving mprime ${mem}MB of memory"
  else
    echo "WARNING: no memory limit or setting found; mprime will use most of the node's RAM" >&2
    mem=
  fi
  [ -z "$mem" ] || upsert - Memory "$mem"
fi

mprime=${MPRIME:-/opt/mprime/mprime}

if [ "$JOB_MODE" != 1 ]; then
  # exec, so mprime is the container's main process and gets SIGTERM (it writes a checkpoint and exits).
  exec "$mprime" -d "-w$dir"
fi

# ---- Job mode: run until the assignments are finished and everything is sent, then stop.
#
# mprime itself never finishes: with an empty queue it waits for more work. So this script watches the files:
# the work is done when worktodo.txt has no assignment left, and everything is sent when no results are
# spooled (prime.spl), no proof files are waiting (*.proof, unless ProofUploads=0) and no staged P-1 residue is
# waiting (p1send.*, only counted once a proxy has said it accepts them: AcceptsP1Uploads=1, and not P1Uploads=0).
# These are the rules mprime itself uses for "is anything left to send". Then it stops mprime and exits 0.
# Exit codes matter to Kubernetes: a Job treats 0 as "the work is finished". mprime itself exits 0 when it is
# stopped by SIGTERM, which a pre-empted or drained pod gets, so this script runs mprime as a child and exits
# 143 when it is told to stop. Only a finished job exits 0, and only if the files check out.

queue_empty() {
  [ ! -e "$dir/worktodo.txt" ] || ! grep -q -v -E '^[[:space:]]*($|#|//|\[.*\][[:space:]]*$)' "$dir/worktodo.txt"
}
primenet_on() { grep -q -i -P '^UsePrimenet=1\s*$' "$dir/prime.txt"; }
# Names of the files that are still waiting to be sent.
pending_files() {
  local f
  for f in "$dir"/prime.spl; do [ ! -e "$f" ] || echo "${f##*/}"; done
  if ! grep -q -i -P '^ProofUploads=0\s*$' "$dir/prime.txt"; then
    for f in "$dir"/*.proof; do [ ! -e "$f" ] || echo "${f##*/}"; done
  fi
  if grep -q -i -P '^AcceptsP1Uploads=1\s*$' "$dir/prime.txt" && ! grep -q -i -P '^P1Uploads=0\s*$' "$dir/prime.txt"; then
    for f in "$dir"/p1send.*; do [ ! -e "$f" ] || echo "${f##*/}"; done
  fi
}

stopping=0 finished=0 failed=0 idle_since=-1
"$mprime" -d "-w$dir" &
pid=$!
trap 'stopping=1; kill -TERM "$pid" 2>/dev/null || true' TERM INT

while kill -0 "$pid" 2>/dev/null; do
  sleep 5 & wait $! || true
  [ "$stopping" = 0 ] && [ "$finished" = 0 ] && [ "$failed" = 0 ] || continue
  if ! queue_empty; then idle_since=-1; continue; fi
  pending=$(pending_files)
  if [ -z "$pending" ]; then
    echo "Job: the assignments are finished and everything has been sent."
    finished=1; kill -TERM "$pid" 2>/dev/null || true
  elif ! primenet_on; then
    # QuitGIMPS (NoMoreWork) switches PrimeNet off once the queue is empty, and nothing is sent after that.
    echo "ERROR: the assignments are finished but PrimeNet is switched off, so these will never be sent: $(echo $pending)" >&2
    echo "       Older mprime builds do this with staged P-1 residues (p1send files). Use an mprime where QuitGIMPS waits" >&2
    echo "       for them (the markrose/mprime p1-proxy build from commit e30a471), or set job.noMoreWork=false and" >&2
    echo "       DaysOfWork=0 in config.prime." >&2
    failed=1; kill -TERM "$pid" 2>/dev/null || true
  else
    [ "$idle_since" -ge 0 ] || { idle_since=$SECONDS; echo "Job: the assignments are finished; waiting for: $(echo $pending)"; }
    if [ $(( SECONDS - idle_since )) -ge "$JOB_MAX_WAIT_SECONDS" ]; then
      echo "ERROR: still waiting to send $(echo $pending) after ${JOB_MAX_WAIT_SECONDS}s (job.maxWaitSeconds); giving up." >&2
      failed=1; kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
done

rc=0; wait "$pid" || rc=$?
trap - TERM INT
if [ "$stopping" = 1 ]; then
  echo "Job: told to stop before it was finished; the pod will be replaced and carry on from its checkpoint."
  exit 143
fi
[ "$failed" = 0 ] || exit 1
if [ "$finished" = 0 ]; then
  # mprime ended by itself. That is only fine if there is nothing left to do.
  if [ "$rc" != 0 ] || ! queue_empty || [ -n "$(pending_files)" ]; then
    echo "ERROR: mprime stopped (status $rc) before the job was finished." >&2
    exit 1
  fi
fi
exit 0
