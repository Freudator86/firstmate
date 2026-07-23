#!/usr/bin/env bash
# Opt-in real systemd --user smoke for the external watcher and delivery stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SYSTEMD_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SYSTEMD_LIVE=1 for the transient real-systemd watcher smoke"
  exit 0
fi

systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "skip: systemd --user is unavailable"; exit 0; }

fm_test_tmproot TMP_ROOT fm-watcher-systemd-live
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config"
printf 'FM_CHECK_INTERVAL=999999\n' > "$HOME_DIR/config/x-mode.env"
WATCH="$ROOT/bin/fm-watch.sh"
STUB="$ROOT/bin/fm-wake-wait.sh"
VERSION=$(sha256sum "$WATCH" | awk '{print "sha256:" $1}')
INSTANCE=$(systemd-escape --path "$HOME_DIR")
UNIT="fm-watch@${INSTANCE}.service"
STUB_PID=

cleanup() {
  [ -z "$STUB_PID" ] || kill -TERM "$STUB_PID" 2>/dev/null || true
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

systemd-run --user --unit "$UNIT" --collect \
  --property=Restart=always --property=RestartSec=1 \
  --property="EnvironmentFile=$HOME_DIR/config/x-mode.env" \
  --setenv="FM_HOME=$HOME_DIR" --setenv="FM_ROOT_OVERRIDE=$ROOT" \
  --setenv="FM_STATE_OVERRIDE=$STATE" --setenv=FM_WATCH_DAEMON=1 \
  --setenv=FM_WATCH_MANAGER=systemd --setenv="FM_WATCH_SOURCE_VERSION=$VERSION" \
  --setenv=FM_POLL=1 --setenv=FM_HEARTBEAT=999999 \
  /usr/bin/env bash "$WATCH" >/dev/null

# shellcheck source=bin/fm-wake-lib.sh
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-wake-lib.sh"
i=0
while ! fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR" && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR" || fail "real systemd unit did not establish the watcher health predicate"
old_pid=$FM_WATCHER_HEALTHY_PID
[ "$(cat "$STATE/.watch.lock/manager")" = systemd ] || fail "real unit did not publish manager=systemd"
systemctl --user show "$UNIT" -p EnvironmentFiles --value | grep -F "$HOME_DIR/config/x-mode.env" >/dev/null \
  || fail "real unit did not load the X-mode EnvironmentFile"

printf '%s\n' "$$" > "$STATE/.lock"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_GUARD_GRACE=5 FM_WAKE_WAIT_POLL=0.05 \
  "$STUB" > "$TMP_ROOT/stub-first.out" 2> "$TMP_ROOT/stub-first.err" &
STUB_PID=$!
i=0
while ! fm_wake_stub_armed "$STATE" "$STUB" "$HOME_DIR" && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
fm_wake_stub_armed "$STATE" "$STUB" "$HOME_DIR" || fail "real-systemd delivery stub did not publish its identity lock"
kill -TERM "$STUB_PID"
wait "$STUB_PID" 2>/dev/null || true
STUB_PID=
[ ! -s "$STATE/.wake-queue" ] || fail "killing an idle stub created or lost queue data"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_GUARD_GRACE=5 FM_WAKE_WAIT_POLL=0.05 \
  "$STUB" > "$TMP_ROOT/stub-second.out" 2> "$TMP_ROOT/stub-second.err" &
STUB_PID=$!
i=0
while ! fm_wake_stub_armed "$STATE" "$STUB" "$HOME_DIR" && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
fm_wake_append signal smoke "signal: systemd smoke"
wait "$STUB_PID"
STUB_PID=
grep -Fx 'wake: queued' "$TMP_ROOT/stub-second.out" >/dev/null || fail "re-armed stub did not deliver the queued wake"
[ "$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || fail "stub drained or duplicated the queued wake"

kill -TERM "$old_pid"
i=0
new_pid=$old_pid
while [ "$new_pid" = "$old_pid" ] && [ "$i" -lt 160 ]; do
  sleep 0.05
  if fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR"; then
    new_pid=$FM_WATCHER_HEALTHY_PID
  fi
  i=$((i + 1))
done
[ "$new_pid" != "$old_pid" ] || fail "systemd Restart=always did not replace the terminated daemon"
systemctl --user is-active --quiet "$UNIT" || fail "transient watcher unit is not active after daemon restart"

pass "real systemd user unit keeps the daemon external while stub loss costs one re-arm and zero wakes"
