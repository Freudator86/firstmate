#!/usr/bin/env bash
# Watcher service backend selection, consent, fallback, and convergence tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-watcher-service.sh"
unset FM_TEST_SKIP_WATCHER_SERVICE
fm_test_tmproot TMP_ROOT fm-watcher-service

cleanup_process_file() {
  local file=$1 pid
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  cleanup_process_file "$TMP_ROOT/systemd-watcher.pid"
  cleanup_process_file "$TMP_ROOT/keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeper-home/state/.watch-keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeper-home/state/.watch.lock/pid"
  fm_test_cleanup
}
trap cleanup EXIT

make_fake_systemd() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SYSTEMCTL_LOG:?}"
case "$*" in
  '--user show-environment') exit 0 ;;
  '--user is-enabled --quiet '*) exit 0 ;;
  '--user is-active --quiet '*)
    pid=$(cat "${FM_TEST_SYSTEMD_PID_FILE:?}" 2>/dev/null || true)
    kill -0 "$pid" 2>/dev/null
    exit
    ;;
  '--user daemon-reload') exit 0 ;;
  '--user restart '*|'--user enable --now '*)
    pid=$(cat "${FM_TEST_SYSTEMD_PID_FILE:?}" 2>/dev/null || true)
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      i=0
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.01
        i=$((i + 1))
      done
    fi
    set -a
    # shellcheck disable=SC1090
    . "${FM_TEST_SERVICE_ENV:?}"
    set +a
    FM_WATCH_DAEMON=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      bash "$FM_WATCH_EXEC" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$FM_TEST_SYSTEMD_PID_FILE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/loginctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'show-user '*'-p Linger --value') printf '%s\n' no; exit 0 ;;
  'enable-linger '*) printf 'enabled\n' >> "${FM_TEST_LOGINCTL_LOG:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/systemctl" "$fakebin/loginctl"
}

make_fake_tmux_keeper() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_TMUX_LOG:?}"
case "${1:-}" in
  has-session)
    pid=$(cat "${FM_TEST_KEEPER_PID_FILE:?}" 2>/dev/null || true)
    kill -0 "$pid" 2>/dev/null
    ;;
  new-session)
    "$5" "$6" "$7" "$8" "$9" "${10}" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$FM_TEST_KEEPER_PID_FILE"
    ;;
  kill-session)
    pid=$(cat "${FM_TEST_KEEPER_PID_FILE:?}" 2>/dev/null || true)
    kill -TERM "$pid" 2>/dev/null || true
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

test_unusable_systemd_selects_tmux_keeper() {
  local fakebin home out
  fakebin="$TMP_ROOT/select-bin"
  home="$TMP_ROOT/select-home"
  mkdir -p "$fakebin" "$home/state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/systemctl" "$fakebin/tmux"
  out=$(FM_HOME="$home" FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_TMUX="$fakebin/tmux" "$SERVICE" select)
  [ "$out" = keeper ] || fail "unusable systemd should select keeper, got: $out"
  pass "systemd --user failure automatically selects the tmux keeper tier"
}

test_missing_systemd_unit_requires_separate_consent() {
  local fakebin home unitdir out
  fakebin="$TMP_ROOT/consent-bin"
  home="$TMP_ROOT/consent-home"
  unitdir="$TMP_ROOT/consent-units"
  mkdir -p "$home/state" "$unitdir"
  make_fake_systemd "$fakebin"
  : > "$TMP_ROOT/systemctl-consent.log"
  : > "$TMP_ROOT/loginctl-consent.log"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl-consent.log" \
    FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-consent.log" "$SERVICE" bootstrap)
  assert_contains "$out" "install watcher-unit" "missing unit did not surface unit-install consent"
  assert_contains "$out" "install watcher-linger" "disabled lingering did not surface separate consent"
  assert_absent "$unitdir/fm-watch@.service" "bootstrap silently installed the systemd unit"
  [ ! -s "$TMP_ROOT/loginctl-consent.log" ] || fail "bootstrap silently enabled lingering"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl-consent.log")" "enable --now" "bootstrap silently enabled the unit"
  pass "unit installation and lingering remain separate explicit-consent operations"
}

test_keeper_fallback_establishes_real_watcher() {
  local fakebin home log manager arm_pid old_watcher_pid new_watcher_pid i
  fakebin="$TMP_ROOT/keeper-bin"
  home="$TMP_ROOT/keeper-home"
  log="$TMP_ROOT/keeper-tmux.log"
  mkdir -p "$home/state" "$home/config"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "tmux keeper fallback did not establish a healthy watcher"
  manager=$(cat "$home/state/.watch.lock/manager")
  [ "$manager" = keeper ] || fail "fallback watcher recorded manager=$manager instead of keeper"
  assert_contains "$(cat "$log")" "new-session -d -s fm-watch-" "fallback did not start a detached home-scoped keeper"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_ARM_CONFIRM_TIMEOUT=5 FM_WAKE_WAIT_POLL=0.05 "$ROOT/bin/fm-watch-arm.sh" > "$TMP_ROOT/keeper-arm.out" &
  arm_pid=$!
  i=0
  while [ ! -e "$home/state/.wake-stub.lock/pid" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$home/state/.wake-stub.lock/pid" ] || fail "public arm did not establish the delivery stub"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" . "$ROOT/bin/fm-wake-lib.sh"
  fm_wake_append signal keeper "signal: keeper smoke"
  wait "$arm_pid" || fail "public arm did not exit cleanly after the queued wake"
  assert_contains "$(cat "$TMP_ROOT/keeper-arm.out")" "watcher: attached" "public arm did not honestly report attachment"
  assert_contains "$(cat "$TMP_ROOT/keeper-arm.out")" "wake: queued" "public arm did not await the delivery stub"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || fail "public arm drained or duplicated the fallback wake"
  old_watcher_pid=$(cat "$home/state/.watch.lock/pid")
  printf 'FM_CHECK_INTERVAL=7\n' > "$home/config/x-mode.env"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" bootstrap >/dev/null \
    || fail "tmux keeper did not converge the X-mode cadence change"
  new_watcher_pid=$(cat "$home/state/.watch.lock/pid")
  [ "$new_watcher_pid" != "$old_watcher_pid" ] || fail "X-mode cadence change did not restart the keeper watcher"
  [ "$(cat "$home/state/.watch.lock/x-mode-version")" != absent ] || fail "keeper watcher did not record the X-mode version"
  pass "keeper fallback establishes zero-loss delivery and converges X-mode cadence"
}

test_installed_unit_converges_source_and_x_mode() {
  local fakebin home unitdir log old_pid new_pid restarts env_text detect_out
  fakebin="$TMP_ROOT/converge-bin"
  home="$TMP_ROOT/converge-home"
  unitdir="$TMP_ROOT/converge-units"
  log="$TMP_ROOT/systemctl-converge.log"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  make_fake_systemd "$fakebin"
  cp "$ROOT/systemd/fm-watch@.service" "$unitdir/fm-watch@.service"
  : > "$log"
  : > "$TMP_ROOT/loginctl-converge.log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" ensure || fail "installed unit did not establish a healthy watcher"
  old_pid=$(cat "$home/state/.watch.lock/pid")
  printf '%s\n' pre-update-source > "$home/state/.watch.lock/source-version"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" bootstrap >/dev/null || fail "bootstrap did not converge stale watcher source identity"
  new_pid=$(cat "$home/state/.watch.lock/pid")
  [ "$new_pid" != "$old_pid" ] || fail "stale source identity did not restart the unit"
  printf 'FM_CHECK_INTERVAL=7\n' > "$home/config/x-mode.env"
  detect_out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SERVICE" bootstrap)
  assert_contains "$detect_out" "needs locked convergence" "read-only bootstrap missed stale X-mode service environment"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" bootstrap >/dev/null || fail "bootstrap did not converge X-mode environment"
  restarts=$(grep -c '^--user restart ' "$log")
  [ "$restarts" -eq 3 ] || fail "expected initial, source, and X-mode restarts; got $restarts"
  env_text=$(cat "$home/state/.watch-service.env")
  assert_not_contains "$env_text" 'FM_WATCH_X_MODE_VERSION="absent"' "X-mode hash stayed absent after convergence"
  pass "locked bootstrap restarts stale source and X-mode systemd instances"
}

test_unusable_systemd_selects_tmux_keeper
test_missing_systemd_unit_requires_separate_consent
test_keeper_fallback_establishes_real_watcher
test_installed_unit_converges_source_and_x_mode
