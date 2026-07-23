#!/usr/bin/env bash
# Portable tmux-hosted keeper for a home whose systemd user manager is unusable.
# Usage: fm-watch-keeper.sh <fm-home> <code-root> <state-dir> <source-version> <x-mode-version>
#
# fm-watcher-service.sh owns selection and launch of this process.
# The keeper records its pid in state/.watch-keeper.pid and respawns only its
# home-scoped FM_WATCH_DAEMON=1 watcher child after an unexpected exit.
set -u

[ "$#" -eq 5 ] || { echo "usage: $(basename "$0") <fm-home> <code-root> <state-dir> <source-version> <x-mode-version>" >&2; exit 2; }
FM_HOME=$1
FM_ROOT_OVERRIDE=$2
FM_STATE_OVERRIDE=$3
FM_WATCH_SOURCE_VERSION=$4
FM_WATCH_X_MODE_VERSION=$5
export FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_WATCH_SOURCE_VERSION FM_WATCH_X_MODE_VERSION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/fm-watch.sh"
PIDFILE="$FM_STATE_OVERRIDE/.watch-keeper.pid"
CHILD=

if [ -f "$FM_HOME/config/x-mode.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091 # Per-home generated cadence file.
  . "$FM_HOME/config/x-mode.env"
  set +a
fi

mkdir -p "$FM_STATE_OVERRIDE"
printf '%s\n' "${BASHPID:-$$}" > "$PIDFILE" || exit 1

cleanup() {
  trap - HUP INT TERM
  if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
    rm -f "$PIDFILE"
  fi
  exit 0
}
trap cleanup HUP INT TERM

while :; do
  FM_WATCH_DAEMON=1 FM_WATCH_MANAGER=keeper "$WATCH" &
  CHILD=$!
  wait "$CHILD"
  CHILD=
  sleep "${FM_WATCH_RESTART_SEC:-2}"
done
