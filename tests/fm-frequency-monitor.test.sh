#!/usr/bin/env bash
# Fast Bridge frequency monitor and shared wake integration tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR="$ROOT/bin/fm-frequency-monitor.sh"
BRIDGE_LIB="$ROOT/bin/fm-bridge-inbox-lib.sh"
fm_test_tmproot TMP_ROOT fm-frequency-monitor

make_home() {
  local name=$1 home bridge origin
  shift
  home="$TMP_ROOT/$name"
  bridge="$home/projects/coditan-bridge"
  origin="$home/bridge-origin.git"
  mkdir -p "$home/state" "$home/config" "$bridge/inbox/coditan/new"
  for vessel in "$@"; do
    mkdir -p "$bridge/inbox/$vessel/new"
  done
  git init -q --bare "$origin"
  git -C "$bridge" init -q -b main
  git -C "$bridge" config user.name test
  git -C "$bridge" config user.email test@example.com
  touch "$bridge/inbox/coditan/new/.gitkeep"
  for vessel in "$@"; do
    touch "$bridge/inbox/$vessel/new/.gitkeep"
  done
  git -C "$bridge" add inbox
  git -C "$bridge" commit -qm init
  git -C "$bridge" remote add origin "$origin"
  git -C "$bridge" push -qu origin main
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  printf '%s\n' coditan > "$home/config/bridge-vessel"
  printf '%s\n' "$home"
}

write_envelope() {
  local home=$1 name=$2 priority=$3 vessel=${4:-coditan}
  printf '{"schema":"bridge-envelope.v1","id":"%s","priority":"%s","state":"new"}\n' \
    "$name" "$priority" > "$home/projects/coditan-bridge/inbox/$vessel/new/$name.json"
  git -C "$home/projects/coditan-bridge" add "inbox/$vessel/new/$name.json"
  git -C "$home/projects/coditan-bridge" commit -qm "add $name"
  git -C "$home/projects/coditan-bridge" push -qu origin main
}

test_once_appends_one_durable_wake() {
  local home out queue
  home=$(make_home once)
  write_envelope "$home" flash immediate

  out=$(FM_HOME="$home" "$MONITOR" --once)
  assert_contains "$out" "check: bridge-inbox: bridge-inbox coditan pending=1 highest=immediate" \
    "frequency monitor did not report the new envelope"
  queue=$(cat "$home/state/.wake-queue")
  assert_contains "$queue" $'\tcheck\tbridge-inbox\tcheck: bridge-inbox:' \
    "frequency monitor did not use the durable Bridge wake path"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || \
    fail "one frequency check appended more than one durable wake"

  out=$(FM_HOME="$home" "$MONITOR" --once)
  [ -z "$out" ] || fail "unchanged mail re-fired the frequency monitor: $out"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || \
    fail "unchanged mail appended another durable wake"
  pass "frequency monitor publishes one durable wake per new inbox signature"
}

test_monitor_uses_only_home_primary_vessel() {
  local home out
  home=$(make_home primary-only captain)
  printf '%s\n' "coditan captain" > "$home/config/bridge-vessel"
  write_envelope "$home" primary normal coditan
  write_envelope "$home" secondary high captain

  out=$(FM_HOME="$home" "$MONITOR" --once)
  assert_contains "$out" "bridge-inbox coditan pending=1" \
    "frequency monitor missed its home primary vessel"
  assert_not_contains "$out" "bridge-inbox captain" \
    "frequency monitor became a multi-vessel scanner"
  assert_absent "$home/state/.bridge-surfaced-captain" \
    "frequency monitor wrote a surfaced marker for a secondary vessel"
  pass "frequency monitor narrows an existing vessel list to this home's primary inbox"
}

test_concurrent_paths_share_dedup_lock() {
  local home rc1=0 rc2=0 lines
  home=$(make_home concurrent)
  write_envelope "$home" race high

  FM_HOME="$home" "$MONITOR" --once > "$home/one.out" &
  p1=$!
  FM_HOME="$home" "$MONITOR" --once > "$home/two.out" &
  p2=$!
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] || \
    fail "concurrent monitor checks failed: rc1=$rc1 rc2=$rc2"
  lines=$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')
  [ "$lines" -eq 1 ] || fail "concurrent checks appended $lines wakes instead of one"
  [ "$(grep -l 'bridge-inbox coditan pending=1' "$home/one.out" "$home/two.out" | wc -l | tr -d '[:space:]')" -eq 1 ] || \
    fail "concurrent checks did not surface the signature exactly once"
  pass "shared Bridge lock makes independent background processes deduplicate atomically"
}

test_slow_fallback_observes_fast_marker() {
  local home out
  home=$(make_home fallback)
  write_envelope "$home" shared normal
  FM_HOME="$home" "$MONITOR" --once > /dev/null
  out=$(
    FM_HOME="$home" bash -c \
      '. "$1"; . "$2"; bridge_inbox_surface 0' _ "$ROOT/bin/fm-wake-lib.sh" "$BRIDGE_LIB"
  )
  [ -z "$out" ] || fail "slow fallback re-surfaced a signature already handled by the fast path: $out"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || \
    fail "slow fallback duplicated the fast path's durable wake"
  pass "fast monitor and slow watcher fallback share one surfaced-marker contract"
}

test_unconfigured_home_stays_inert() {
  local home out
  home=$(make_home unconfigured)
  rm -f "$home/config/bridge-vessel"
  write_envelope "$home" ignored high
  out=$(FM_HOME="$home" "$MONITOR" --once)
  [ -z "$out" ] || fail "unconfigured frequency monitor produced output: $out"
  assert_absent "$home/state/.wake-queue" "unconfigured frequency monitor created a wake"
  pass "frequency monitor remains inert without a per-home Bridge vessel"
}

test_once_appends_one_durable_wake
test_monitor_uses_only_home_primary_vessel
test_concurrent_paths_share_dedup_lock
test_slow_fallback_observes_fast_marker
test_unconfigured_home_stays_inert
