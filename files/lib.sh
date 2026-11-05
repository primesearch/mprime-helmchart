# Shared by init.sh and start.sh. Expects $dir to be mprime's working directory (with prime.txt in it).
#
# prime.txt is the settings file: top-level "Key=Value" lines, then optional "[Section]" blocks. The section
# name "-" stands for the top, before the first [section] header (it can't clash with a real section name).
# mprime compares setting and section names without regard to case, so everything here does too: setting
# memory=500 replaces an existing Memory=500 line (and the line is rewritten with the spelling we were given).

# Set key=value in [section] of prime.txt, replacing an existing line or adding one.
upsert() {
  local tmp k
  tmp=$(mktemp "$dir/.prime.txt.XXXXXX")
  SEC=$1 KEY=$2 VAL=$3 awk '
    function flush() { if (cur == sec && !done) { print key "=" val; done = 1 } }
    BEGIN { sec = tolower(ENVIRON["SEC"]); name = ENVIRON["SEC"]; key = ENVIRON["KEY"]; lkey = tolower(key)
            val = ENVIRON["VAL"]; cur = "-"; done = 0 }
    /^\[.*\][ \t]*$/ { flush(); cur = $0; sub(/^\[/, "", cur); sub(/\][ \t]*$/, "", cur); cur = tolower(cur); print; next }
    cur == sec && tolower(substr($0, 1, length(key) + 1)) == lkey "=" { if (!done) { print key "=" val; done = 1 } ; next }
    { print }
    END { flush(); if (!done) { print ""; print "[" name "]"; print key "=" val } }
  ' "$dir/prime.txt" > "$tmp"
  mv "$tmp" "$dir/prime.txt"
  # An older mprime keeps machine settings in local.txt, and a newer one merges that file over prime.txt when
  # it starts, so a stale value there would beat the one just set. Remove this key (and the old name of
  # NumWorkers) from local.txt; the rest of local.txt, such as the computer's GUID, is kept.
  if [ "$1" = - ] && [ -e "$dir/local.txt" ]; then
    for k in "$2" $([ "$2" = NumWorkers ] && echo WorkerThreads); do
      tmp=$(mktemp "$dir/.local.txt.XXXXXX")
      awk -v k="$k=" 'tolower(substr($0, 1, length(k))) != tolower(k)' "$dir/local.txt" > "$tmp"
      mv "$tmp" "$dir/local.txt"
    done
  fi
}

# Stop with a clear message unless each named variable holds a whole number. The chart sets these in the pod
# spec, so a missing or odd one is a bug there, and quietly using a default (for example no memory reserve) would
# get the pod OOM-killed.
require_int() {
  local v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || { echo "ERROR: $v is not set (the chart sets it in the pod spec)" >&2; exit 1; }
    [[ ${!v} =~ ^[0-9]+$ ]] || { echo "ERROR: $v must be a whole number, but is '${!v}'" >&2; exit 1; }
  done
}
