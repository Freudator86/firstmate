#!/usr/bin/env bash
# Ensure this home's external watcher loop is healthy, then become its delivery
# wait.  The long-lived loop belongs to systemd --user, with a detached tmux
# keeper selected automatically when the user manager is unusable.
#
# First-time systemd installation and enablement are deliberately not implicit:
# fm-bootstrap.sh prints WATCHER_UNIT consent diagnostics and performs either
# action only through `fm-bootstrap.sh install watcher-unit` after approval.
# Once installed, this wrapper converges and verifies the existing service.
#
# Output contract before the blocking stub begins:
#   watcher: started pid=<N> (beacon fresh)
#   watcher: attached pid=<N> (beacon <age>s)
#   watcher: FAILED - no live watcher with a fresh beacon
#
# `--restart` scopes the restart to this FM_HOME's systemd template instance or
# tmux keeper, verifies the unchanged fm_watcher_healthy predicate, then waits in
# bin/fm-wake-wait.sh exactly like a normal arm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WAIT="$SCRIPT_DIR/fm-wake-wait.sh"
SERVICE="$SCRIPT_DIR/fm-watcher-service.sh"
BEAT="$STATE/.last-watcher-beat"
GRACE=${FM_GUARD_GRACE:-300}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

healthy_before=0
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && healthy_before=1

if [ "$mode" = restart ]; then
  if ! "$SERVICE" restart; then
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
  fi
elif ! "$SERVICE" ensure; then
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
fi

if ! fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
fi

watcher_pid=$FM_WATCHER_HEALTHY_PID
if [ "$mode" = arm ] && [ "$healthy_before" -eq 1 ]; then
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$watcher_pid (beacon ${age}s)"
else
  echo "watcher: started pid=$watcher_pid (beacon fresh)"
fi

exec "$WAIT"
