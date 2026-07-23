#!/usr/bin/env bash
# Block until this home's durable wake queue is non-empty.
#
# This is the lightweight, session-owned delivery half of supervision.
# It never drains state/.wake-queue; bin/fm-wake-drain.sh remains the sole
# model-invoked atomic drain.  The stub owns state/.wake-stub.lock while waiting
# and exits loudly if the external watcher beacon ages past FM_GUARD_GRACE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STUB_PATH="$SCRIPT_DIR/fm-wake-wait.sh"
STUB_LOCK="$STATE/.wake-stub.lock"
WATCH="$SCRIPT_DIR/fm-watch.sh"
GRACE=${FM_GUARD_GRACE:-300}
POLL=${FM_WAKE_WAIT_POLL:-1}
LOCK_OWNED=0

cleanup() {
  trap - HUP INT TERM
  [ "$LOCK_OWNED" -eq 0 ] || fm_lock_release "$STUB_LOCK"
}
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

lock_rc=0
fm_lock_try_acquire "$STUB_LOCK" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  if [ "$lock_rc" -eq 2 ]; then
    echo "wake delivery: FAILED - lock acquisition failed for $STUB_LOCK" >&2
    exit 1
  fi
  echo "wake delivery: FAILED - another delivery stub already holds $STUB_LOCK" >&2
  exit 1
fi
LOCK_OWNED=1
STUB_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$STUB_LOCK/fm-home" || exit 1
printf '%s\n' "$STUB_PATH" > "$STUB_LOCK/stub-path" || exit 1
printf '%s\n' "$(cat "$STATE/.lock" 2>/dev/null || true)" > "$STUB_LOCK/session-lock-pid" || exit 1
fm_pid_identity "$STUB_PID" > "$STUB_LOCK/pid-identity" 2>/dev/null || {
  echo "wake delivery: FAILED - could not record stub identity" >&2
  exit 1
}

while :; do
  if [ -s "$FM_WAKE_QUEUE" ]; then
    echo "wake: queued"
    exit 0
  fi
  if ! fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    age=$(fm_path_age "$STATE/.last-watcher-beat")
    if [ "$age" -ge "$GRACE" ]; then
      echo "wake delivery: FAILED - watcher beacon stale for ${age}s (grace ${GRACE}s)" >&2
      exit 1
    fi
  fi
  sleep "$POLL"
done
