#!/usr/bin/env bash
# Safe, home-scoped arm of the optional direct Telegram receiver.
#
# `config/fm-tg-recv.sh` is local/private operational code.
# This tracked wrapper owns only the session-start arm shape: run it as its own
# harness-tracked background task, never bundled onto another command and never
# with shell `&`.
# It starts one receiver for this FM_HOME or attaches to an already running one.
# The receiver remains this wrapper's child when started here, so the harness
# gets notified when a Telegram message makes the receiver print its one
# CAPTAIN-TELEGRAM line and exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECV="$CONFIG/fm-tg-recv.sh"
ENV_FILE="$CONFIG/telegram.env"
RECV_LOCK="$STATE/.tg-recv.lock"
ATTACH_POLL=${FM_TG_RECV_ATTACH_POLL:-0.5}

usage() {
  printf 'usage: %s\n' "$(basename "$0")" >&2
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  printf 'telegram receiver: inactive (config/telegram.env absent)\n'
  exit 0
fi

if [ ! -x "$RECV" ]; then
  printf 'telegram receiver: FAILED - config/fm-tg-recv.sh missing or not executable\n'
  exit 1
fi

TG_HEALTHY_PID=
tg_receiver_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$RECV_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$RECV_LOCK/receiver-path" 2>/dev/null || true)
  lock_identity=$(cat "$RECV_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$RECV" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

healthy_receiver() {
  local pid
  TG_HEALTHY_PID=
  pid=$(cat "$RECV_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  tg_receiver_lock_matches_pid "$pid" || return 1
  TG_HEALTHY_PID=$pid
  return 0
}

clear_dead_recorded_receiver_lock() {
  local lock_home lock_path pid
  lock_home=$(cat "$RECV_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$RECV_LOCK/receiver-path" 2>/dev/null || true)
  pid=$(cat "$RECV_LOCK/pid" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$RECV" ] || return 0
  fm_pid_alive "$pid" && return 0
  fm_lock_remove_path "$RECV_LOCK" || true
}

attach_and_wait() {
  while :; do
    if healthy_receiver; then
      sleep "$ATTACH_POLL"
      continue
    fi
    exit 0
  done
}

if healthy_receiver; then
  printf 'telegram receiver: attached pid=%s\n' "$TG_HEALTHY_PID"
  attach_and_wait
fi

clear_dead_recorded_receiver_lock

ownerdir=
if ! fm_lock_try_create "$RECV_LOCK"; then
  if healthy_receiver; then
    printf 'telegram receiver: attached pid=%s\n' "$TG_HEALTHY_PID"
    attach_and_wait
  fi
  printf 'telegram receiver: FAILED - receiver lock is held but no live matching receiver was confirmed\n'
  exit 1
fi
ownerdir=$FM_LOCK_OWNER_DIR

child=
child_out=
cleanup() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  fm_lock_remove_path "$RECV_LOCK" 2>/dev/null || true
  [ -n "$child_out" ] && rm -f "$child_out" 2>/dev/null || true
}
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 143' TERM INT

child_out=$(mktemp "$STATE/.tg-recv-output.XXXXXX") || {
  cleanup
  printf 'telegram receiver: FAILED - could not create output capture\n'
  exit 1
}

"$RECV" >"$child_out" &
child=$!
identity=$(fm_pid_identity "$child" 2>/dev/null || true)
if [ -z "$identity" ]; then
  if [ -s "$child_out" ] || ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    [ -s "$child_out" ] && cat "$child_out"
    fm_lock_remove_path "$RECV_LOCK" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    trap - HUP TERM INT
    exit "$rc"
  fi
  cleanup
  printf 'telegram receiver: FAILED - could not identify receiver process\n'
  exit 1
fi

{
  printf '%s\n' "$child" > "$ownerdir/pid"
  printf '%s\n' "$FM_HOME" > "$ownerdir/fm-home"
  printf '%s\n' "$identity" > "$ownerdir/pid-identity"
  printf '%s\n' "$RECV" > "$ownerdir/receiver-path"
} 2>/dev/null || {
  cleanup
  printf 'telegram receiver: FAILED - could not record receiver lock metadata\n'
  exit 1
}

printf 'telegram receiver: started pid=%s\n' "$child"
wait "$child"
rc=$?
[ -s "$child_out" ] && cat "$child_out"
fm_lock_remove_path "$RECV_LOCK" 2>/dev/null || true
rm -f "$child_out" 2>/dev/null || true
trap - HUP TERM INT
exit "$rc"
