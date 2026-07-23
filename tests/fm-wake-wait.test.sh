#!/usr/bin/env bash
# External watcher daemon mode plus the session-owned wake delivery stub.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WAIT="$ROOT/bin/fm-wake-wait.sh"
fm_test_tmproot TMP_ROOT fm-wake-wait

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

record_fake_daemon() {
  local home=$1 state=$2 pid=$3 identity
  identity=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

test_daemon_enqueues_and_continues_without_arm_owner() {
  local dir state fakebin out pid lock_pid
  dir=$(make_case daemon-continues)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WATCH_DAEMON=1 \
    FM_WATCH_ARM_OWNER_PID=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  [ -e "$state/.last-watcher-beat" ] || fail "daemon watcher never established its beacon"
  printf 'done: synthetic daemon wake\n' > "$state/demo.status"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$state/.wake-queue" ] && break
    sleep 0.2
  done
  [ -s "$state/.wake-queue" ] || fail "daemon watcher did not enqueue the status wake"
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "daemon watcher exited after an actionable wake"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || fail "daemon watcher lost its singleton lock after the wake"
  [ "$(cat "$state/.watch.lock/daemon" 2>/dev/null || true)" = 1 ] || fail "daemon mode was not recorded in the watcher lock"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "FM_WATCH_DAEMON enqueues and continues while ignoring the obsolete arm-owner parent check"
}

test_killed_stub_loses_no_wake_and_costs_one_rearm() {
  local home state daemon first second out queued
  home="$TMP_ROOT/stub-kill"
  state="$home/state"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid" ] || fail "initial delivery stub did not publish its lock"
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  [ ! -e "$state/.wake-stub.lock/pid" ] || fail "SIGTERM delivery stub left its identity lock behind"

  append_wake "$state" signal demo.status "signal: demo.status"
  out="$home/rearm.out"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$out" & second=$!
  wait "$second" || fail "single replacement delivery stub did not observe the queued wake"
  queued=$(cat "$state/.wake-queue")
  assert_contains "$(cat "$out")" "wake: queued" "replacement stub did not deliver the queued-wake nudge"
  assert_contains "$queued" "signal: demo.status" "stub termination or replacement drained the durable wake"
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "SIGTERM of the delivery stub costs one re-arm and loses zero queued wakes"
}

test_stub_exits_loudly_on_stale_daemon_beacon() {
  local home state daemon out status
  home="$TMP_ROOT/stub-stale"
  state="$home/state"
  out="$home/stale.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$WAIT" > "$out" 2>&1 || status=$?
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "delivery stub succeeded with a stale daemon beacon"
  assert_contains "$(cat "$out")" "watcher beacon stale" "stale daemon failure was not loud"
  pass "delivery stub exits loudly when the daemon beacon exceeds guard grace"
}

test_daemon_enqueues_and_continues_without_arm_owner
test_killed_stub_loses_no_wake_and_costs_one_rearm
test_stub_exits_loudly_on_stale_daemon_beacon
