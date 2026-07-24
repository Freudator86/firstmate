#!/usr/bin/env bash
# Own the systemd user service for one home's Bridge frequency monitor.
#
# Usage:
#   fm-frequency-monitor-service.sh bootstrap
#   fm-frequency-monitor-service.sh ensure
#   fm-frequency-monitor-service.sh install-unit
#
# A non-empty FM_BRIDGE_VESSEL or config/bridge-vessel opts the home into
# detection.  First installation and enablement happen only through
# install-unit after the captain approves the FREQUENCY_MONITOR_UNIT bootstrap
# diagnostic.  An already-installed unit converges at locked bootstrap
# boundaries.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MONITOR="$SCRIPT_DIR/fm-frequency-monitor.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-frequency-monitor@.service"
SYSTEMCTL=${FM_FREQUENCY_MONITOR_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_FREQUENCY_MONITOR_SYSTEMD_ESCAPE:-systemd-escape}
USER_UNIT_DIR=${FM_FREQUENCY_MONITOR_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-frequency-monitor@.service"
SERVICE_ENV="$STATE/.frequency-monitor-service.env"
CONFIRM_TIMEOUT=${FM_FREQUENCY_MONITOR_CONFIRM_TIMEOUT:-10}
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=10 ;; esac

frequency_monitor_vessel() {
  local vessel
  if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
    printf '%s\n' "$FM_BRIDGE_VESSEL"
    return
  fi
  [ -f "$FM_HOME/config/bridge-vessel" ] || return 0
  IFS= read -r vessel < "$FM_HOME/config/bridge-vessel" || vessel=
  [ -z "$vessel" ] || printf '%s\n' "$vessel"
}

frequency_monitor_configured() {
  [ -n "$(frequency_monitor_vessel)" ]
}

systemd_usable() {
  [ "${FM_FREQUENCY_MONITOR_FORCE_SYSTEMD:-0}" = 1 ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-frequency-monitor@%s.service\n' "$escaped"
}

systemd_env_quote() {
  local value=$1
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

monitor_source_version() {
  local file sum size
  local files=(
    "$MONITOR"
    "$SCRIPT_DIR/fm-bridge-inbox-lib.sh"
    "$SCRIPT_DIR/fm-wake-lib.sh"
  )
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(
      for file in "${files[@]}"; do
        printf '%s\0' "${file#"$SCRIPT_DIR"/}"
        sha256sum < "$file" || exit 1
      done | sha256sum | awk '{print $1}'
    ) || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    sum=$(
      for file in "${files[@]}"; do
        printf '%s\0' "${file#"$SCRIPT_DIR"/}"
        shasum -a 256 < "$file" || exit 1
      done | shasum -a 256 | awk '{print $1}'
    ) || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  read -r sum size _ <<EOF
$({
  for file in "${files[@]}"; do
    printf '%s\0' "${file#"$SCRIPT_DIR"/}"
    cksum < "$file" || exit 1
  done
} | cksum)
EOF
  [ -n "$sum" ] && [ -n "$size" ] || return 1
  printf 'cksum:%s:%s\n' "$sum" "$size"
}

write_service_env() {
  local version vessel bridge_root interval timeout tmp changed=0
  version=$(monitor_source_version) || return 1
  vessel=$(frequency_monitor_vessel)
  bridge_root=${FM_BRIDGE_ROOT:-$FM_HOME/projects/coditan-bridge}
  interval=${FM_FREQUENCY_MONITOR_INTERVAL:-5}
  timeout=${FM_CHECK_TIMEOUT:-30}
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.frequency-monitor-service.env.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_FREQUENCY_MONITOR_EXEC=%s\n' "$(systemd_env_quote "$MONITOR")"
    printf 'FM_FREQUENCY_MONITOR_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
    printf 'FM_BRIDGE_VESSEL=%s\n' "$(systemd_env_quote "$vessel")"
    printf 'FM_BRIDGE_ROOT=%s\n' "$(systemd_env_quote "$bridge_root")"
    printf 'FM_FREQUENCY_MONITOR_INTERVAL=%s\n' "$(systemd_env_quote "$interval")"
    printf 'FM_CHECK_TIMEOUT=%s\n' "$(systemd_env_quote "$timeout")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_FREQUENCY_MONITOR_ENV_CHANGED=$changed
}

service_env_matches() {
  local version vessel bridge_root interval timeout
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  version=$(monitor_source_version) || return 1
  vessel=$(frequency_monitor_vessel)
  bridge_root=${FM_BRIDGE_ROOT:-$FM_HOME/projects/coditan-bridge}
  interval=${FM_FREQUENCY_MONITOR_INTERVAL:-5}
  timeout=${FM_CHECK_TIMEOUT:-30}
  grep -Fx "FM_HOME=$(systemd_env_quote "$FM_HOME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_ROOT_OVERRIDE=$(systemd_env_quote "$FM_ROOT")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_STATE_OVERRIDE=$(systemd_env_quote "$STATE")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_FREQUENCY_MONITOR_EXEC=$(systemd_env_quote "$MONITOR")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_FREQUENCY_MONITOR_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_BRIDGE_VESSEL=$(systemd_env_quote "$vessel")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_BRIDGE_ROOT=$(systemd_env_quote "$bridge_root")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_FREQUENCY_MONITOR_INTERVAL=$(systemd_env_quote "$interval")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_CHECK_TIMEOUT=$(systemd_env_quote "$timeout")" "$SERVICE_ENV" >/dev/null 2>&1
}

systemd_installed() {
  [ -f "$UNIT_DEST" ] && [ ! -L "$UNIT_DEST" ]
}

systemd_enabled() {
  local unit
  unit=$(unit_instance) || return 1
  "$SYSTEMCTL" --user is-enabled --quiet "$unit"
}

systemd_active() {
  local unit
  unit=$(unit_instance) || return 1
  "$SYSTEMCTL" --user is-active --quiet "$unit"
}

install_unit_bytes() {
  [ -f "$UNIT_SOURCE" ] && [ ! -L "$UNIT_SOURCE" ] || return 1
  mkdir -p "$USER_UNIT_DIR" || return 1
  install -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
}

wait_for_active() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    systemd_active && return 0
    sleep 0.2
  done
  systemd_active
}

ensure_systemd() {
  local unit changed=0
  frequency_monitor_configured || return 0
  systemd_usable || {
    echo "FREQUENCY_MONITOR_UNIT: systemd --user is unavailable; fast Bridge delivery remains on the slow watcher fallback" >&2
    return 2
  }
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "FREQUENCY_MONITOR_UNIT: missing - approve: bin/fm-bootstrap.sh install frequency-monitor-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "FREQUENCY_MONITOR_UNIT: disabled - approve: bin/fm-bootstrap.sh install frequency-monitor-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  FM_FREQUENCY_MONITOR_ENV_CHANGED=0
  write_service_env || return 1
  [ "$FM_FREQUENCY_MONITOR_ENV_CHANGED" -eq 0 ] || changed=1
  if [ "$changed" -eq 1 ] || ! systemd_active; then
    "$SYSTEMCTL" --user restart "$unit" || return 1
  fi
  wait_for_active
}

install_systemd() {
  local unit
  frequency_monitor_configured || {
    echo "error: configure this home's Bridge vessel before installing the frequency monitor" >&2
    return 1
  }
  systemd_usable || { echo "error: systemd --user is unavailable" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable --now "$unit" || return 1
  wait_for_active || {
    echo "error: $unit did not become active" >&2
    return 1
  }
}

bootstrap_check() {
  local unit
  frequency_monitor_configured || return 0
  if ! systemd_usable; then
    echo "FREQUENCY_MONITOR_UNIT: systemd --user is unavailable; fast Bridge delivery remains on the slow watcher fallback"
    return 0
  fi
  unit=$(unit_instance) || {
    echo "FREQUENCY_MONITOR_UNIT: failed to encode FM_HOME $FM_HOME"
    return 0
  }
  if ! systemd_installed; then
    echo "FREQUENCY_MONITOR_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install frequency-monitor-unit"
  elif ! systemd_enabled; then
    echo "FREQUENCY_MONITOR_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install frequency-monitor-unit"
  elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches || ! systemd_active; then
      echo "FREQUENCY_MONITOR_UNIT: $unit needs locked convergence from the session holding the fleet lock"
    fi
  elif ! ensure_systemd >/dev/null; then
    echo "FREQUENCY_MONITOR_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
  fi
}

case "${1:-}" in
  bootstrap) bootstrap_check ;;
  ensure) ensure_systemd ;;
  install-unit) install_systemd ;;
  *)
    echo "usage: $(basename "$0") {bootstrap|ensure|install-unit}" >&2
    exit 2
    ;;
esac
