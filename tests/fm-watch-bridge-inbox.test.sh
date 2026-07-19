#!/usr/bin/env bash
# Tests for the watcher's read-only Bridge inbox wake and priority cadence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-bridge-inbox)

make_home() {
  local name=$1 home bridge origin
  home="$TMP_ROOT/$name"
  bridge="$home/projects/coditan-bridge"
  origin="$home/bridge-origin.git"
  mkdir -p "$home/state" "$bridge/inbox/coditan/new"
  git init -q --bare "$origin"
  git -C "$bridge" init -q -b main
  git -C "$bridge" config user.name test
  git -C "$bridge" config user.email test@example.com
  touch "$bridge/inbox/coditan/new/.gitkeep"
  git -C "$bridge" add inbox
  git -C "$bridge" commit -qm init
  git -C "$bridge" remote add origin "$origin"
  git -C "$bridge" push -qu origin main
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$home"
}

write_envelope() {
  local home=$1 name=$2 priority=$3
  printf '{"schema":"bridge-envelope.v1","id":"%s","priority":"%s","state":"new"}\n' \
    "$name" "$priority" > "$home/projects/coditan-bridge/inbox/coditan/new/$name.json"
  git -C "$home/projects/coditan-bridge" add "inbox/coditan/new/$name.json"
  git -C "$home/projects/coditan-bridge" commit -qm "add $name"
  git -C "$home/projects/coditan-bridge" push -qu origin main
}

# Existing Bridge fixtures explicitly opt into the historical vessel name.
export FM_BRIDGE_VESSEL=coditan

test_vessel_resolution_precedence() {
  local home resolved
  home=$(make_home vessel-resolution)
  mkdir -p "$home/config"
  printf '%s\n' tugboat > "$home/config/bridge-vessel"

  resolved=$(
    FM_HOME="$home" FM_BRIDGE_VESSEL=override \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = override ] || fail "FM_BRIDGE_VESSEL did not override config/bridge-vessel: $resolved"

  resolved=$(
    # shellcheck disable=SC2016  # $1/$BRIDGE_VESSEL belong to the inner bash -c process.
    env -u FM_BRIDGE_VESSEL FM_HOME="$home" \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = tugboat ] || fail "config/bridge-vessel was not used without an env override: $resolved"

  resolved=$(
    FM_HOME="$home" FM_BRIDGE_VESSEL='' \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = tugboat ] || fail "an empty FM_BRIDGE_VESSEL shadowed config/bridge-vessel: $resolved"
  pass "Bridge vessel resolution prefers a non-empty env value and falls back to per-home config"
}

test_unconfigured_home_skips_bridge_scan() {
  local home fakebin counter out pid
  home=$(make_home unconfigured)
  fakebin="$TMP_ROOT/fakebin-unconfigured"
  mkdir -p "$fakebin"
  counter="$home/timeout-calls"
  : > "$counter"
  cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
echo x >> "$COUNTER_FILE"
exec /usr/bin/timeout "$@"
EOF
  chmod +x "$fakebin/timeout"
  out="$home/watch.out"
  env -u FM_BRIDGE_VESSEL COUNTER_FILE="$counter" PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "unconfigured Bridge watcher did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "unconfigured Bridge watcher created a wake"
  [ "$(wc -l < "$counter" | tr -d '[:space:]')" = 0 ] || \
    fail "unconfigured Bridge watcher still spawned a bounded scan"
  pass "unconfigured home performs no Bridge scan and emits no wake"
}

test_bridge_inbox_surfaces_each_signature_once() {
  local home bridge out pid first_marker second_marker
  home=$(make_home pending)
  bridge="$home/projects/coditan-bridge"
  out="$home/watch.out"
  write_envelope "$home" urgent high
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait "$pid" || fail "watcher failed while checking a pending Bridge envelope"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=1 highest=high" \
    "pending Bridge envelope did not produce an actionable check wake"
  assert_contains "$(cat "$home/state/.wake-queue")" $'\tcheck\tbridge-inbox\t' \
    "Bridge check wake was not queued durably"
  first_marker=$(cat "$home/state/.bridge-surfaced")
  [ -n "$first_marker" ] || fail "first surfaced inbox signature was not recorded"

  : > "$out"
  rm -f "$home/state/.wake-queue"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "unchanged Bridge inbox signature re-fired a wake: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "unchanged Bridge inbox signature created a wake"
  [ "$(cat "$home/state/.bridge-surfaced")" = "$first_marker" ] || \
    fail "absorbing an unchanged inbox altered the surfaced marker"

  write_envelope "$home" second normal
  : > "$out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait "$pid" || fail "watcher failed after the Bridge inbox signature changed"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=2 highest=high" \
    "changed Bridge inbox signature did not produce a new wake"
  second_marker=$(cat "$home/state/.bridge-surfaced")
  [ "$second_marker" != "$first_marker" ] || fail "changed inbox did not advance the surfaced marker"

  git -C "$bridge" rm -q inbox/coditan/new/urgent.json inbox/coditan/new/second.json
  git -C "$bridge" commit -qm "ack envelopes"
  git -C "$bridge" push -qu origin main
  : > "$out"
  rm -f "$home/state/.wake-queue"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "acked Bridge inbox did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "acked Bridge inbox created a wake"
  [ ! -e "$home/state/.bridge-surfaced" ] || \
    fail "acked inbox did not clear the surfaced marker"

  write_envelope "$home" urgent high
  write_envelope "$home" second normal
  : > "$out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait "$pid" || fail "watcher failed after a byte-identical Bridge re-delivery"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=2 highest=high" \
    "byte-identical re-delivered inbox did not produce a new wake"
  [ "$(cat "$home/state/.bridge-surfaced")" = "$second_marker" ] || \
    fail "re-delivered inbox did not record its surfaced signature"
  pass "Bridge inbox wakes once per pending signature, clears on ack, and re-fires on re-delivery"
}

test_empty_inbox_is_silent() {
  local home out pid
  home=$(make_home empty)
  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "empty Bridge inbox did not stay silent"
  assert_absent "$home/state/.wake-queue" "empty Bridge inbox created a wake"
  pass "empty Bridge inbox is absorbed silently"
}

test_priority_tightens_only_bridge_cadence() {
  local home normal_interval urgent_interval
  home=$(make_home cadence)
  normal_interval=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  write_envelope "$home" routine normal
  [ "$normal_interval" = 300 ] || fail "routine Bridge cadence was $normal_interval, expected 300"
  normal_interval=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$normal_interval" = 300 ] || fail "normal envelope cadence was $normal_interval, expected 300"
  write_envelope "$home" flash immediate
  urgent_interval=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$urgent_interval" = 30 ] || fail "immediate envelope cadence was $urgent_interval, expected 30"
  pass "high-priority Bridge traffic tightens only its poll interval"
}

test_cache_skips_rescan_when_unchanged() {
  local home fakebin counter out1 out2 out3 calls
  home=$(make_home cache)
  fakebin="$TMP_ROOT/fakebin-cache"
  mkdir -p "$fakebin"
  counter="$home/jq-calls"
  : > "$counter"
  cat > "$fakebin/jq" <<EOF
#!/usr/bin/env bash
echo x >> "$counter"
priority=\$(grep -o '"priority":"[a-z]*"' | head -1 | cut -d'"' -f4)
printf '%s\n' "\${priority:-normal}"
EOF
  chmod +x "$fakebin/jq"
  write_envelope "$home" first normal
  out1=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out1" = normal ] || fail "first priority read was $out1, expected normal"
  out2=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out2" = normal ] || fail "cached priority read was $out2, expected normal"
  calls=$(wc -l < "$counter" | tr -d '[:space:]')
  [ "$calls" = 1 ] || fail "unchanged inbox re-ran the priority scan ($calls jq calls, expected 1)"
  write_envelope "$home" second immediate
  out3=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out3" = immediate ] || fail "priority after new arrival was $out3, expected immediate"
  calls=$(wc -l < "$counter" | tr -d '[:space:]')
  [ "$calls" = 3 ] || fail "new arrival did not trigger a rescan (1 old + 2 new jq calls: got $calls, expected 3)"
  pass "unchanged Bridge inbox reuses the cached priority; new arrivals trigger a rescan"
}

test_inplace_edit_invalidates_cache() {
  local home fakebin counter out1 out2 calls
  home=$(make_home inplace)
  fakebin="$TMP_ROOT/fakebin-inplace"
  mkdir -p "$fakebin"
  counter="$home/jq-calls"
  : > "$counter"
  cat > "$fakebin/jq" <<EOF
#!/usr/bin/env bash
echo x >> "$counter"
priority=\$(grep -o '"priority":"[a-z]*"' | head -1 | cut -d'"' -f4)
printf '%s\n' "\${priority:-normal}"
EOF
  chmod +x "$fakebin/jq"
  write_envelope "$home" first normal
  out1=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out1" = normal ] || fail "first priority read was $out1, expected normal"
  write_envelope "$home" first immediate
  out2=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out2" = immediate ] || fail "priority after in-place edit was $out2, expected immediate (cache did not invalidate)"
  calls=$(wc -l < "$counter" | tr -d '[:space:]')
  [ "$calls" = 2 ] || fail "in-place edit under an unchanged filename did not trigger a rescan ($calls jq calls, expected 2)"
  pass "an in-place envelope edit under an unchanged filename invalidates the cached priority"
}

test_changed_inbox_failed_scan_does_not_reuse_stale_priority() {
  local home fakebin out1 out2 out3 new_sig
  home=$(make_home failed-rescan)
  fakebin="$TMP_ROOT/fakebin-failed-rescan"
  mkdir -p "$fakebin"
  cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *bridge_pending_priority_scan*) exit 124 ;;
esac
exec /usr/bin/timeout "$@"
EOF
  chmod +x "$fakebin/timeout"
  write_envelope "$home" first normal
  out1=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority' _ "$WATCH"
  )
  [ "$out1" = normal ] || fail "first priority read was $out1, expected normal"
  write_envelope "$home" second immediate
  new_sig=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_inbox_signature' _ "$WATCH"
  )
  out2=$(
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority "$2"' _ "$WATCH" "$new_sig"
  )
  [ "$out2" = none ] || fail "failed changed-signature priority scan reused stale priority $out2"
  out3=$(
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_pending_priority "$2"' _ "$WATCH" "$new_sig"
  )
  [ "$out3" = immediate ] || fail "priority after retry was $out3, expected immediate"
  pass "failed priority scans for changed Bridge inboxes do not reuse stale cache"
}

test_missing_inbox_short_circuits_without_scan() {
  local home fakebin counter out pid
  home="$TMP_ROOT/missing"
  mkdir -p "$home/state"
  fakebin="$TMP_ROOT/fakebin-missing"
  mkdir -p "$fakebin"
  counter="$home/timeout-calls"
  : > "$counter"
  cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
echo x >> "$COUNTER_FILE"
exec /usr/bin/timeout "$@"
EOF
  chmod +x "$fakebin/timeout"
  out="$home/watch.out"
  COUNTER_FILE="$counter" PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  sleep 3
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "missing Bridge inbox directory did not stay silent: $(cat "$out")"
  [ "$(wc -l < "$counter" | tr -d '[:space:]')" = 0 ] || \
    fail "missing Bridge inbox directory still spawned a bounded scan"
  pass "missing Bridge inbox directory short-circuits without spawning a scan"
}

test_discovery_gated_by_urgent_interval() {
  local home fakebin counter out pid calls
  home=$(make_home discovery)
  write_envelope "$home" routine normal
  fakebin="$TMP_ROOT/fakebin-discovery"
  mkdir -p "$fakebin"
  counter="$home/timeout-calls"
  : > "$counter"
  cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
echo x >> "$COUNTER_FILE"
exec /usr/bin/timeout "$@"
EOF
  chmod +x "$fakebin/timeout"
  out="$home/watch.out"
  COUNTER_FILE="$counter" PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  calls=$(wc -l < "$counter" | tr -d '[:space:]')
  [ "$calls" -le 5 ] || \
    fail "repeated unchanged loop checks kept spawning bounded scans ($calls calls across several ticks)"
  [ -e "$home/state/.last-bridge-discovery" ] || fail "Bridge discovery cadence marker was never written"
  pass "repeated unchanged loop checks do not keep spawning Bridge scans within the urgent window"
}

test_acked_on_origin_ignores_stale_working_tree() {
  local home bridge peer out pid
  home=$(make_home stale-working-tree)
  bridge="$home/projects/coditan-bridge"
  peer="$home/bridge-peer"
  write_envelope "$home" acked normal
  git clone -q "$home/bridge-origin.git" "$peer"
  git -C "$peer" config user.name test
  git -C "$peer" config user.email test@example.com
  git -C "$peer" rm -q inbox/coditan/new/acked.json
  git -C "$peer" commit -qm "ack envelope"
  git -C "$peer" push -qu origin main
  [ -f "$bridge/inbox/coditan/new/acked.json" ] || \
    fail "stale-working-tree fixture did not retain the locally pending envelope"

  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 3
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$out" ] || fail "origin-acked envelope in a stale working tree caused a false wake: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" \
    "origin-acked envelope in a stale working tree created a wake"
  [ -f "$bridge/inbox/coditan/new/acked.json" ] || \
    fail "watcher fetch mutated the stale Bridge working tree"
  pass "origin ack clears the check without mutating a stale local working tree"
}

test_vessel_resolution_precedence
test_unconfigured_home_skips_bridge_scan
test_bridge_inbox_surfaces_each_signature_once
test_empty_inbox_is_silent
test_priority_tightens_only_bridge_cadence
test_cache_skips_rescan_when_unchanged
test_inplace_edit_invalidates_cache
test_changed_inbox_failed_scan_does_not_reuse_stale_priority
test_missing_inbox_short_circuits_without_scan
test_discovery_gated_by_urgent_interval
test_acked_on_origin_ignores_stale_working_tree
