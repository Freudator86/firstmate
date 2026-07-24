#!/usr/bin/env bash
# Frequency monitor systemd template consent and convergence tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-frequency-monitor-service.sh"
fm_test_tmproot TMP_ROOT fm-frequency-monitor-service

make_fake_systemd() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SYSTEMCTL_LOG:?}"
case "$*" in
  '--user show-environment'|'--user daemon-reload') exit 0 ;;
  '--user is-enabled --quiet '*)
    [ -e "${FM_TEST_SYSTEMD_ENABLED:?}" ]
    ;;
  '--user is-active --quiet '*)
    [ -e "${FM_TEST_SYSTEMD_ACTIVE:?}" ]
    ;;
  '--user enable --now '*)
    touch "$FM_TEST_SYSTEMD_ENABLED" "$FM_TEST_SYSTEMD_ACTIVE"
    ;;
  '--user restart '*)
    touch "$FM_TEST_SYSTEMD_ACTIVE"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/systemd-escape" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --path ] || exit 1
printf '%s\n' "${2#/}" | tr '/' '-'
SH
  chmod +x "$fakebin/systemctl" "$fakebin/systemd-escape"
}

service_env() {
  local fakebin=$1 home=$2 unitdir=$3
  shift 3
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY="${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
    FM_FREQUENCY_MONITOR_SYSTEMCTL="$fakebin/systemctl" \
    FM_FREQUENCY_MONITOR_SYSTEMD_ESCAPE="$fakebin/systemd-escape" \
    FM_FREQUENCY_MONITOR_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log" \
    FM_TEST_SYSTEMD_ENABLED="$TMP_ROOT/systemd.enabled" \
    FM_TEST_SYSTEMD_ACTIVE="$TMP_ROOT/systemd.active" \
    "$@"
}

test_unconfigured_home_is_silent() {
  local fakebin home unitdir out
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/unconfigured"
  unitdir="$TMP_ROOT/units"
  mkdir -p "$home/state" "$unitdir"
  make_fake_systemd "$fakebin"
  : > "$TMP_ROOT/systemctl.log"
  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  [ -z "$out" ] || fail "unconfigured home produced a frequency monitor diagnostic: $out"
  assert_absent "$unitdir/fm-frequency-monitor@.service" \
    "unconfigured bootstrap installed a frequency monitor unit"
  pass "frequency monitor bootstrap is silent until a home configures Bridge"
}

test_install_requires_consent_and_converges() {
  local fakebin home unitdir out detect_out restarts env_mode
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/configured"
  unitdir="$TMP_ROOT/units"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  printf '%s\n' coditan > "$home/config/bridge-vessel"
  rm -f "$TMP_ROOT/systemd.enabled" "$TMP_ROOT/systemd.active"
  : > "$TMP_ROOT/systemctl.log"

  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$out" "install frequency-monitor-unit" \
    "missing frequency monitor unit did not request explicit consent"
  assert_absent "$unitdir/fm-frequency-monitor@.service" \
    "bootstrap silently installed the frequency monitor unit"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now" \
    "bootstrap silently enabled the frequency monitor unit"

  service_env "$fakebin" "$home" "$unitdir" \
    "$ROOT/bin/fm-bootstrap.sh" install frequency-monitor-unit > "$home/install.out"
  assert_contains "$(cat "$home/install.out")" "installing frequency-monitor-unit" \
    "bootstrap install did not announce the approved frequency monitor action"
  [ -f "$unitdir/fm-frequency-monitor@.service" ] || \
    fail "approved installer did not copy the tracked unit"
  assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now fm-frequency-monitor@" \
    "approved installer did not enable and start the home-scoped instance"
  env_mode=$(stat -c %a "$home/state/.frequency-monitor-service.env")
  [ "$env_mode" = 600 ] || fail "private service environment mode was $env_mode instead of 600"
  assert_contains "$(cat "$home/state/.frequency-monitor-service.env")" 'FM_BRIDGE_VESSEL="coditan"' \
    "service environment did not preserve the resolved per-home vessel"

  printf '%s\n' stale > "$unitdir/fm-frequency-monitor@.service"
  detect_out=$(FM_BOOTSTRAP_DETECT_ONLY=1 \
    service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$detect_out" "needs locked convergence" \
    "detect-only bootstrap missed stale frequency monitor unit bytes"
  restarts=$(grep -c '^--user restart ' "$TMP_ROOT/systemctl.log" || true)
  [ "$restarts" -eq 0 ] || fail "detect-only bootstrap restarted the frequency monitor"

  service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap > /dev/null
  cmp -s "$ROOT/systemd/fm-frequency-monitor@.service" "$unitdir/fm-frequency-monitor@.service" || \
    fail "locked bootstrap did not converge tracked frequency monitor unit bytes"
  assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart fm-frequency-monitor@" \
    "locked bootstrap did not restart the stale frequency monitor instance"
  pass "frequency monitor unit installation is consent-gated and later convergence is scoped"
}

test_unconfigured_home_is_silent
test_install_requires_consent_and_converges
