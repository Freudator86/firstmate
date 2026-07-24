#!/usr/bin/env bash
# Own the external firstmate watcher loop for one FM_HOME.
#
# Usage:
#   fm-watcher-service.sh select
#   fm-watcher-service.sh bootstrap
#   fm-watcher-service.sh ensure
#   fm-watcher-service.sh restart
#   fm-watcher-service.sh install-unit
#   fm-watcher-service.sh enable-linger
#   fm-watcher-service.sh repair-command
#
# A working systemd user manager selects the tracked fm-watch@.service template.
# First installation and enablement happen only through install-unit after the
# captain approves the WATCHER_UNIT bootstrap diagnostic.  An already-installed
# unit converges its tracked bytes, per-home environment, source version, and
# running process automatically at a locked bootstrap boundary.  If systemd is
# unusable, a detached home-scoped tmux keeper is selected automatically.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-watch@.service"
SYSTEMCTL=${FM_WATCH_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_WATCH_SYSTEMD_ESCAPE:-systemd-escape}
TMUX=${FM_WATCH_TMUX:-tmux}
USER_UNIT_DIR=${FM_WATCH_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-watch@.service"
SERVICE_ENV="$STATE/.watch-service.env"
GRACE=${FM_GUARD_GRACE:-300}
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
STOP_TIMEOUT=${FM_WATCH_STOP_TIMEOUT:-20}
case "$STOP_TIMEOUT" in ''|*[!0-9]*|0) STOP_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

watch_source_version() {
  local file sum size
  local -a files=(
    "$WATCH"
    "$SCRIPT_DIR/fm-wake-lib.sh"
    "$SCRIPT_DIR/fm-bridge-inbox-lib.sh"
    "$SCRIPT_DIR/fm-classify-lib.sh"
    "$SCRIPT_DIR/fm-backend.sh"
    "$SCRIPT_DIR/fm-transition-lib.sh"
    "$SCRIPT_DIR/fm-pr-lib.sh"
    "$SCRIPT_DIR/fm-x-lib.sh"
    "$SCRIPT_DIR/fm-check-lib.sh"
    "$SCRIPT_DIR"/backends/*.sh
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

x_mode_version() {
  local file="$FM_HOME/config/x-mode.env" sum size
  [ -f "$file" ] || { echo absent; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  read -r sum size _ <<EOF
$(cksum "$file" 2>/dev/null)
EOF
  [ -n "$sum" ] && [ -n "$size" ] || return 1
  printf 'cksum:%s:%s\n' "$sum" "$size"
}

systemd_usable() {
  [ "${FM_WATCH_SERVICE_FORCE_BACKEND:-}" = keeper ] && return 1
  [ "${FM_WATCH_SERVICE_FORCE_BACKEND:-}" = systemd ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

keeper_usable() {
  command -v "$TMUX" >/dev/null 2>&1
}

select_backend() {
  if systemd_usable; then
    echo systemd
  elif keeper_usable; then
    echo keeper
  else
    echo none
  fi
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-watch@%s.service\n' "$escaped"
}

keeper_name() {
  local base sum
  base=$(basename "$FM_HOME" | tr -c 'A-Za-z0-9_-' '_')
  sum=$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')
  printf 'fm-watch-%s-%s\n' "$base" "$sum"
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

write_service_env() {
  local version x_version tmp changed=0
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.watch-service.env.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_WATCH_EXEC=%s\n' "$(systemd_env_quote "$WATCH")"
    printf 'FM_WATCH_MANAGER=systemd\n'
    printf 'FM_WATCH_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
    printf 'FM_WATCH_X_MODE_VERSION=%s\n' "$(systemd_env_quote "$x_version")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_WATCH_ENV_CHANGED=$changed
}

service_env_matches() {
  local version x_version
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  grep -Fx "FM_HOME=$(systemd_env_quote "$FM_HOME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_ROOT_OVERRIDE=$(systemd_env_quote "$FM_ROOT")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_STATE_OVERRIDE=$(systemd_env_quote "$STATE")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_EXEC=$(systemd_env_quote "$WATCH")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx 'FM_WATCH_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_X_MODE_VERSION=$(systemd_env_quote "$x_version")" "$SERVICE_ENV" >/dev/null 2>&1
}

watcher_record_matches() {
  local manager=$1 expected_version expected_x_version actual_manager actual_version actual_x_version
  expected_version=$(watch_source_version) || return 1
  expected_x_version=$(x_mode_version) || return 1
  actual_manager=$(cat "$STATE/.watch.lock/manager" 2>/dev/null || true)
  actual_version=$(cat "$STATE/.watch.lock/source-version" 2>/dev/null || true)
  actual_x_version=$(cat "$STATE/.watch.lock/x-mode-version" 2>/dev/null || true)
  [ "$actual_manager" = "$manager" ] \
    && [ "$actual_version" = "$expected_version" ] \
    && [ "$actual_x_version" = "$expected_x_version" ]
}

healthy_watcher() {
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"
}

wait_for_healthy() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy_watcher && return 0
    sleep 0.2
  done
  healthy_watcher
}

stop_recorded_watcher() {
  local pid i max_attempts
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 0
  fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$pid" "$FM_HOME" || return 0
  kill -TERM "$pid" 2>/dev/null || return 1
  max_attempts=$((STOP_TIMEOUT * 10))
  i=0
  while [ "$i" -lt "$max_attempts" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! fm_pid_alive "$pid"
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

ensure_systemd() {
  local unit changed=0
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "WATCHER_UNIT: missing - approve: bin/fm-bootstrap.sh install watcher-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "WATCHER_UNIT: disabled - approve: bin/fm-bootstrap.sh install watcher-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  FM_WATCH_ENV_CHANGED=0
  write_service_env || return 1
  [ "$FM_WATCH_ENV_CHANGED" -eq 0 ] || changed=1

  if healthy_watcher && ! watcher_record_matches systemd; then
    stop_recorded_watcher || return 1
    changed=1
  fi
  if [ "$changed" -eq 1 ] || ! systemd_active || ! healthy_watcher; then
    "$SYSTEMCTL" --user restart "$unit" || return 1
  fi
  wait_for_healthy
}

install_systemd() {
  local unit
  systemd_usable || { echo "error: systemd --user is unavailable; the tmux keeper fallback needs no install" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable --now "$unit" || return 1
  wait_for_healthy || {
    echo "error: $unit did not establish a healthy watcher" >&2
    return 1
  }
}

stop_keeper() {
  local name
  name=$(keeper_name)
  "$TMUX" has-session -t "$name" 2>/dev/null || return 0
  "$TMUX" kill-session -t "$name"
}

start_keeper() {
  local name version x_version
  name=$(keeper_name)
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  mkdir -p "$STATE" || return 1
  "$TMUX" new-session -d -s "$name" "$SCRIPT_DIR/fm-watch-keeper.sh" "$FM_HOME" "$FM_ROOT" "$STATE" "$version" "$x_version"
}

ensure_keeper() {
  local name
  name=$(keeper_name)
  if healthy_watcher && watcher_record_matches keeper; then
    return 0
  fi
  if "$TMUX" has-session -t "$name" 2>/dev/null; then
    stop_keeper || return 1
  fi
  if healthy_watcher; then
    stop_recorded_watcher || return 1
  fi
  start_keeper || return 1
  wait_for_healthy
}

restart_keeper() {
  stop_keeper || return 1
  stop_recorded_watcher || return 1
  start_keeper || return 1
  wait_for_healthy
}

linger_enabled() {
  command -v loginctl >/dev/null 2>&1 || return 1
  [ "$(loginctl show-user "${FM_WATCH_USER_NAME:-$(id -un)}" -p Linger --value 2>/dev/null || true)" = yes ]
}

bootstrap_check() {
  local backend unit changed=0
  backend=$(select_backend)
  case "$backend" in
    systemd)
      unit=$(unit_instance) || { echo "WATCHER_UNIT: failed to encode FM_HOME $FM_HOME"; return 0; }
      if ! systemd_installed; then
        echo "WATCHER_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install watcher-unit"
      elif ! systemd_enabled; then
        echo "WATCHER_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install watcher-unit"
      elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches \
          || ! systemd_active || ! healthy_watcher || ! watcher_record_matches systemd; then
          echo "WATCHER_UNIT: $unit needs locked convergence from the session holding the fleet lock"
        fi
      elif ! ensure_systemd >/dev/null; then
        echo "WATCHER_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
      fi
      if ! linger_enabled; then
        echo "WATCHER_UNIT: user lingering is disabled - approve: bin/fm-bootstrap.sh install watcher-linger"
      fi
      ;;
    keeper)
      if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        healthy_watcher && watcher_record_matches keeper \
          || echo "WATCHER_UNIT: systemd --user unavailable; the lock-holding session will start the tmux keeper fallback"
      elif ! ensure_keeper; then
        echo "WATCHER_UNIT: systemd --user unavailable and the tmux keeper fallback failed"
      fi
      ;;
    *)
      echo "WATCHER_UNIT: systemd --user is unavailable and tmux is not installed; no watcher keeper is available"
      ;;
  esac
}

ensure_selected() {
  case "$(select_backend)" in
    systemd) ensure_systemd ;;
    keeper) ensure_keeper ;;
    *) echo "error: no watcher service backend available" >&2; return 1 ;;
  esac
}

restart_selected() {
  local unit
  case "$(select_backend)" in
    systemd)
      if ! systemd_installed || ! systemd_enabled; then
        echo "WATCHER_UNIT: install or enable requires approval through bin/fm-bootstrap.sh install watcher-unit" >&2
        return 2
      fi
      write_service_env || return 1
      stop_keeper 2>/dev/null || true
      unit=$(unit_instance) || return 1
      "$SYSTEMCTL" --user restart "$unit" || return 1
      wait_for_healthy
      ;;
    keeper) restart_keeper ;;
    *) echo "error: no watcher service backend available" >&2; return 1 ;;
  esac
}

repair_command() {
  local unit
  if [ "$(select_backend)" = systemd ] && unit=$(unit_instance); then
    printf 'systemctl --user restart %s\n' "$unit"
  else
    printf 'bin/fm-watcher-service.sh restart\n'
  fi
}

case "${1:-}" in
  select) select_backend ;;
  bootstrap) bootstrap_check ;;
  ensure) ensure_selected ;;
  restart) restart_selected ;;
  install-unit) install_systemd ;;
  enable-linger)
    command -v loginctl >/dev/null 2>&1 || { echo "error: loginctl is unavailable" >&2; exit 1; }
    loginctl enable-linger "${FM_WATCH_USER_NAME:-$(id -un)}"
    ;;
  repair-command) repair_command ;;
  *)
    echo "usage: $(basename "$0") {select|bootstrap|ensure|restart|install-unit|enable-linger|repair-command}" >&2
    exit 2
    ;;
esac
