#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep, handle_push_transition in
# bin/fm-watch.sh). The watcher's source guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP fm-supervision-events

STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$STATE_DIR"/.parked-* \
    "$STATE_DIR"/.parkedmeta-* "$STATE_DIR"/.parkedresurfaced-* \
    "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
(
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- handle_push_transition: parked terminal waits use the bounded cadence ---

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'done: PR ready and relayed\n' > "$STATE_DIR/tk2.status"
: > "$STATE_DIR/.parked-default_wG_pQ"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a fresh parked terminal wait must not be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a fresh parked terminal wait woke the supervisor from the event fast-path"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "parked push absorb did not commit backend dedupe"
grep -q 'parked terminal wait' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "parked push absorb was not logged"
pass "handle_push_transition: a fresh parked terminal wait is absorbed and backend-deduped"

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'done: PR ready and relayed\n' > "$STATE_DIR/tk2.status"
: > "$STATE_DIR/.parked-default_wG_pQ"
reconcile_parked_markers
back=$(( $(date +%s) - 500 ))
if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$STATE_DIR/.parked-default_wG_pQ"
else touch -m -d "@$back" "$STATE_DIR/.parked-default_wG_pQ"; fi
old_pause_resurface=$PAUSE_RESURFACE_SECS
PAUSE_RESURFACE_SECS=240
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
PAUSE_RESURFACE_SECS=$old_pause_resurface
grep -q 'awaiting external human action' "$STATE_DIR/.wake-queue" \
  || fail "parked push past the bounded cadence did not enqueue a recheck"
[ -s "$WAKE_LOG" ] || fail "parked push past the bounded cadence did not wake the supervisor"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "parked push recheck did not commit backend dedupe before waking"
[ -e "$STATE_DIR/.parkedresurfaced-default_wG_pQ" ] || fail "parked push recheck did not advance its cadence throttle"
pass "handle_push_transition: a parked terminal wait re-surfaces after the bounded cadence"

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'done: PR ready and relayed\n' > "$STATE_DIR/tk2.status"
: > "$STATE_DIR/.parked-default_wG_pQ"
: > "$STATE_DIR/.afk"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
rm -f "$STATE_DIR/.afk"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" \
  || fail "away mode let a parked marker absorb the backend transition"
[ -s "$WAKE_LOG" ] || fail "away mode parked transition did not preserve one-shot wake behavior"
pass "handle_push_transition: away mode keeps one-shot wake behavior despite a parked marker"

# --- mark_parked: firstmate's entry point for declaring a parked marker ------

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
mark_parked "default:wG:pQ" || fail "mark_parked refused a window matching a recorded task"
[ -e "$STATE_DIR/.parked-default_wG_pQ" ] || fail "mark_parked did not create the expected marker key"
pass "mark_parked: a window matching a recorded task creates the correctly-substituted marker"

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
if mark_parked "default:wG:pX" 2>/dev/null; then
  fail "mark_parked accepted a window naming no recorded task"
fi
for f in "$STATE_DIR"/.parked-*; do
  [ -e "$f" ] || continue
  fail "mark_parked left a marker behind for an unrecognized window: $f"
done
pass "mark_parked: a window naming no recorded task is refused and creates no marker"

reset_state
if mark_parked "" 2>/dev/null; then
  fail "mark_parked accepted an empty window argument"
fi
pass "mark_parked: an empty window argument is refused"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
EVENT_CAP_FAIL_MAX=2
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"

echo "# fm-supervision-events.test.sh: all assertions passed"
