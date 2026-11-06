#!/system/bin/sh
# Zaviya Installer job. Written by the app. Runs as root.
JOB_NAME=@JOB_NAME@
JOB_ID=@JOB_ID@
STATUS=@STATUS@
RUN_COPY=/data/local/tmp/zaviya-"$JOB_NAME".sh

# Move to /data/local/tmp and into the background, so the root tool returns at
# once and nothing keeps a file open on shared storage.
if [ "$0" != "$RUN_COPY" ]; then
  cp "$0" "$RUN_COPY" || exit 1
  chmod 700 "$RUN_COPY" || exit 1
  nohup sh "$RUN_COPY" >/dev/null 2>&1 &
  exit 0
fi

set -e
set -o pipefail

WAKE=zaviya-$JOB_NAME
STATE=started
EXTRA=
OWNER=$(stat -c %u:%g "$(dirname "$STATUS")" 2>/dev/null || :)

# status STATE [DONE] [TOTAL] [MESSAGE]: replaces the status file in one step.
status() {
  STATE=$1
  { printf 'job=%s\nstate=%s\ndone=%s\ntotal=%s\nmessage=%s\n' "$JOB_ID" "$1" "${2:-0}" "${3:-0}" "${4:-}"
    [ -z "$EXTRA" ] || printf '%s\n' "$EXTRA"
  } > "$STATUS.tmp" || return 0
  [ -z "$OWNER" ] || chown "$OWNER" "$STATUS.tmp" 2>/dev/null || :
  chmod 660 "$STATUS.tmp" 2>/dev/null || :
  mv -f "$STATUS.tmp" "$STATUS" || :
}
put() { EXTRA="${EXTRA:+$EXTRA
}$1=$2"; }
fail() { status failed 0 0 "$1"; exit 1; }
cleanup() {
  case $STATE in done|failed) ;; *) status failed 0 0 "The job stopped before it finished." ;; esac
  { echo "$WAKE" > /sys/power/wake_unlock; } 2>/dev/null || :
  rm -f "$RUN_COPY" 2>/dev/null || :
}
trap cleanup EXIT
# Keep the device awake until the job ends.
{ echo "$WAKE" > /sys/power/wake_lock; } 2>/dev/null || :

sha() { sha256sum "$1" | cut -d' ' -f1; }
# Whole-number comparison that works for any size: num_ge A B is true when A >= B.
num_ge() {
  if [ ${#1} -ne ${#2} ]; then [ ${#1} -gt ${#2} ]; return; fi
  [ "$1" = "$2" ] || [[ "$1" > "$2" ]]
}
# Bytes a process has read (rchar) or written (wchar) so far.
io_bytes() { sed -n "s/^$2: //p" "/proc/$1/io" 2>/dev/null || :; }
# The pid of the process whose command line contains $1.
find_proc() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" != "$$" ] || continue
    if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -qF -- "$1"; then echo "$p"; return 0; fi
  done
  return 0
}
# track PID NEEDLE STATE TOTAL FIELD: reports progress while PID runs.
track() {
  tp=$1; needle=$2; tst=$3; ttot=$4; tfld=$5; tproc=
  while kill -0 "$tp" 2>/dev/null; do
    [ -n "$tproc" ] || tproc=$(find_proc "$needle")
    tn=0
    [ -z "$tproc" ] || tn=$(io_bytes "$tproc" "$tfld")
    status "$tst" "${tn:-0}" "$ttot"
    sleep 2
  done
}
status started
[ "$(id -u)" = 0 ] || fail "This must run as root."
