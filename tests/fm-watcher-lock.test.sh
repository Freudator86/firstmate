#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

fm_test_tmproot TMP_ROOT fm-watcher-lock-tests

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mark_pr_check_migration_complete "$state"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is re-arm-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  #   (3) a fresh watcher but no identity-matched delivery stub armed: a
  #       targeted wake-delivery warning, without the daemon-down banner.
  local dir state err first banner_line queue_line live identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DAEMON DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'Daemon repair:' "$err" >/dev/null || fail "guard banner missing the home-scoped daemon repair command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DAEMON DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  ! grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line still made the session own X-mode cadence"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live")
  mkdir -p "$state/.watch.lock" "$state/.wake-stub.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$live" > "$state/.wake-stub.lock/pid"
  printf '%s\n' "$dir" > "$state/.wake-stub.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-wake-wait.sh" > "$state/.wake-stub.lock/stub-path"
  printf '\n' > "$state/.wake-stub.lock/session-lock-pid"
  printf '%s\n' "$identity" > "$state/.wake-stub.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"

  # (3) fresh watcher, in-flight task, but no delivery stub armed -> a targeted
  # wake-delivery warning, not the daemon-down banner.
  dir=$(make_case guard-stub-missing)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live")
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  grep -F 'wake delivery stub missing' "$err" >/dev/null \
    || fail "guard did not warn about a missing delivery stub with a healthy daemon: $(cat "$err")"
  ! grep -F 'WATCHER DAEMON DOWN' "$err" >/dev/null \
    || fail "guard printed the daemon-down banner despite a healthy watcher: $(cat "$err")"

  pass "guard banner leads when down with pending wakes (re-arm-after-drain), stays silent when fresh, and warns on a missing delivery stub with a healthy daemon"
}

test_lock_create_filesystem_failure_returns_without_steal_recursion() {
  local dir state fakebin lockdir out err pid rc steal_paths
  dir=$(make_case lock-create-filesystem-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  lockdir="$state/.contend.lock"
  out="$dir/acquire.out"
  err="$dir/acquire.err"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
exit 74
SH
  chmod +x "$fakebin/ln"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" > "$out" 2> "$err" &
  pid=$!
  rc=0
  wait_for_exit "$pid" 20 || rc=$?
  [ "$rc" -eq 2 ] || fail "failed lock publication returned $rc instead of filesystem error 2"
  grep -F "could not publish lock $lockdir" "$err" >/dev/null \
    || fail "failed lock publication did not report its filesystem error: $(cat "$err")"
  steal_paths=$(find "$state" -name '*.steal*' -print)
  [ -z "$steal_paths" ] || fail "failed lock publication created steal-chain paths: $steal_paths"
  pass "lock publication failure returns promptly without entering steal recursion"
}

test_lock_steal_recursion_has_a_hard_depth_bound() {
  local dir state lockdir out err rc
  dir=$(make_case lock-steal-depth-bound)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out="$dir/acquire.out"
  err="$dir/acquire.err"
  rc=0
  FM_LOCK_STEAL_MAX_DEPTH=3 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_create() { return 1; }
    fm_lock_mid_acquire_is_fresh() { return 1; }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" > "$out" 2> "$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "steal recursion depth bound returned $rc instead of 2"
  grep -F 'steal depth exceeded 3' "$err" >/dev/null \
    || fail "steal recursion did not report its configured depth bound: $(cat "$err")"
  pass "lock steal recursion stops at its configured hard depth bound"
}

test_lock_wait_has_a_total_time_bound() {
  local dir state lockdir err rc=0 start elapsed
  dir=$(make_case lock-wait-timeout)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  err="$dir/acquire.err"
  mkdir "$lockdir"
  printf '%s\n' "$$" > "$lockdir/pid"

  start=$(date +%s)
  FM_LOCK_WAIT_TIMEOUT=1 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
  ' _ "$LIB" "$lockdir" 2> "$err" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 2 ] || fail "bounded lock wait returned $rc instead of timeout error 2"
  [ "$elapsed" -le 4 ] || fail "bounded lock wait took ${elapsed}s instead of returning promptly"
  grep -F "timed out after 1s waiting for $lockdir" "$err" >/dev/null \
    || fail "bounded lock wait did not report its timeout: $(cat "$err")"
  pass "lock wait returns a clear error at its configured total-time bound"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_watcher_survives_failed_ps_parent_read() {
  # watch_arm_owner_is_parent() is still live production code for the legacy
  # one-shot path (FM_WATCH_DAEMON=0, the default), exercised whenever a caller
  # sets FM_WATCH_ARM_OWNER_PID and forks fm-watch.sh directly rather than going
  # through the daemon-owned systemd/tmux service. Exercise fm-watch.sh directly
  # here (fm-watch-arm.sh itself no longer forks a watcher child at all).
  local dir state fakebin out pid i fail_hits
  dir=$(make_case watcher-ps-fail-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  fail_hits="$dir/ps-fail-hits"
  : > "$fail_hits"
  mark_pr_check_migration_complete "$state"
  # Fail only fm-watch.sh's own arm-owner ppid lookup each poll; other ps
  # callers (fm-lock.sh's steal-ancestry walk, pid identity, active-check
  # pgid) are identified by caller, via the portable `ps -o args=` idiom
  # fm-lock.sh's own ancestry walk uses, and still hit the real ps. Each
  # injected failure is recorded so the test can prove it actually fired.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' -o ppid='*)
    caller=$(command -p ps -o args= -p "$PPID" 2>/dev/null || true)
    case " $caller " in
      *'/fm-watch.sh '*|*' fm-watch.sh '*)
        printf '.' >> "$FM_TEST_PS_FAIL_HITS"
        exit 1
        ;;
    esac
    ;;
esac
command -p ps "$@"
SH
  chmod +x "$fakebin/ps"

  # FM_WATCH_ARM_OWNER_PID=$$ names this test process as the arm owner, which is
  # this watcher's real parent since it is forked directly below - matching the
  # legacy one-shot invocation contract.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_TEST_PS_FAIL_HITS="$fail_hits" \
    FM_WATCH_ARM_OWNER_PID=$$ FM_POLL=0.1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"

  i=0
  while [ "$i" -lt 80 ] && [ ! -s "$fail_hits" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$fail_hits" ] || fail "fault injection never fired; test proves nothing"

  sleep 1
  is_live_non_zombie "$pid" \
    || fail "watcher self-terminated on an inconclusive (failed) ps parent read"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    || fail "singleton lock changed hands despite the same watcher staying alive"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "watcher stays owned across a failed/empty ps parent-pid read"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_create_filesystem_failure_returns_without_steal_recursion
test_lock_steal_recursion_has_a_hard_depth_bound
test_lock_wait_has_a_total_time_bound
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watcher_self_evicts_on_lock_takeover
test_watcher_survives_failed_ps_parent_read
