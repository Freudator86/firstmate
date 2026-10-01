#!/usr/bin/env bash
# fm-startup-growth-check.sh - daily cheap growth check for startup memory and instruction surfaces.
#
# Usage:
#   fm-startup-growth-check.sh [check]
#   fm-startup-growth-check.sh arm
#   fm-startup-growth-check.sh disarm
#   fm-startup-growth-check.sh --help
#
# `check` evaluates at most once every 86400 seconds, one daily evaluation.
# Polls inside that interval only read this check's small state record and stay
# silent.
#
# A due evaluation uses metadata only: regular-file safety checks plus stat(1)
# byte sizes and mtimes.  It does not run the startup digest, bootstrap, network
# checks, model calls, repository refreshes, /stow, or full preference/learning
# rereads.  Only data/captain.md, data/captain-shared.md, and data/learnings.md
# count toward config/startup-memory-budget, whose total and verdict
# bin/fm-startup-memory-budget.sh owns.  data/projects.md and
# data/secondmates.md are printed in full by every session start too, so they
# are watched for prompt growth without entering that budget total.  Tracked
# startup scripts and instructions are reported as code/instruction bytes, not
# as LLM prompt cost.
#
# Growth is measured against a retained per-file baseline rather than only
# against the previous evaluation, so accumulation that stays under one day's
# threshold is still caught.  Reporting a file rebases its baseline to the
# reported size, so accepted growth then stays silent.  The thresholds are
# fixed:
#   2048 bytes for tracked startup/instruction files
#   250 estimated tokens, ceil(bytes / 3), for printed startup memory files
# Budget overrun is always meaningful.
#
# `arm` writes state/startup-growth.check.sh and binds its bytes with
# fm-check-register.sh so the existing watcher slow-check cadence invokes the
# daily gate.  `disarm` removes the shim, trust binding, and report records.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CHECK_ID=startup-growth
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.startup-growth-check"
REPORTED="$STATE/.startup-growth-check.reported"
RECORD_SCHEMA=fm-startup-growth-check-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,36{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'fm-startup-growth-check: %s\n' "$1" >&2
  exit 1
}

now_epoch() {
  case "${FM_STARTUP_GROWTH_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_STARTUP_GROWTH_NOW" ;;
  esac
}

INTERVAL=86400
BYTE_THRESHOLD=2048
TOKEN_THRESHOLD=250

file_size() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

append_finding() {
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$1
  else
    FINDINGS="$FINDINGS; $1"
  fi
}

stat_surface() {  # <kind> <display-path> <absolute-path> <absence-ok>
  local kind=$1 display=$2 path=$3 absence_ok=$4 bytes mtime tokens prev_baseline baseline delta presence=present
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    bytes=0
    mtime=0
    presence=absent
    [ "$absence_ok" = yes ] || append_finding "missing $kind $display"
  elif [ -L "$path" ] || [ ! -f "$path" ]; then
    bytes=0
    mtime=0
    presence=unsafe
    append_finding "unsafe $kind $display"
  else
    bytes=$(file_size "$path") || { append_finding "unreadable $kind $display"; bytes=0; }
    mtime=$(file_mtime "$path") || { append_finding "unreadable $kind $display"; mtime=0; }
    case "$bytes:$mtime" in
      *[!0-9:]*|:*|*:) append_finding "unreadable $kind $display"; bytes=0; mtime=0 ;;
    esac
  fi

  prev_baseline=$(awk -F '\t' -v p="$display" '$1 == p { print $6; found=1; exit } END { if (!found) print "" }' "$OLD_RECORD" 2>/dev/null || true)
  case "$prev_baseline" in
    ''|*[!0-9]*) prev_baseline= ;;
  esac

  if [ "$presence" != present ]; then
    baseline=${prev_baseline:-0}
  elif [ -z "$prev_baseline" ] || [ "$bytes" -le "$prev_baseline" ]; then
    baseline=$bytes
  else
    baseline=$prev_baseline
    delta=$((bytes - baseline))
    case "$kind" in
      memory|printed-memory)
        tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$delta") || tokens=0
        if [ "$tokens" -ge "$TOKEN_THRESHOLD" ]; then
          append_finding "$kind growth $display +${tokens} estimated_tokens (+${delta} bytes, total ${bytes} bytes)"
          baseline=$bytes
        fi
        ;;
      tracked)
        if [ "$delta" -ge "$BYTE_THRESHOLD" ]; then
          append_finding "tracked startup surface growth $display +${delta} bytes (total ${bytes} bytes)"
          baseline=$bytes
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$display" "$kind" "$presence" "$bytes" "$mtime" "$baseline" >> "$NEW_RECORD"
}

write_record_atomically() {
  local tmp=$1 dest=$2 state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$state_device" || return 1
  mv -f -- "$tmp" "$dest"
}

read_last_eval() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$RECORD" 2>/dev/null || true
}

check_due() {
  local now last age
  now=$(now_epoch)
  last=$(read_last_eval)
  case "$last" in
    ''|*[!0-9]*) printf '%s\n' "$now"; return 0 ;;
  esac
  age=$((now - last))
  if [ "$age" -lt 0 ] || [ "$age" -ge "$INTERVAL" ]; then
    printf '%s\n' "$now"
    return 0
  fi
  return 1
}

run_check() {
  local now tmp budget memory_total=0 memory_tokens memory_bytes status display kind _mtime _baseline reported_previous
  if ! now=$(check_due); then
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  OLD_RECORD=$RECORD
  [ -f "$OLD_RECORD" ] && [ ! -L "$OLD_RECORD" ] || OLD_RECORD=/dev/null
  NEW_RECORD=$(mktemp "$STATE/.startup-growth-check.XXXXXX") || exit 1
  trap 'rm -f -- "${NEW_RECORD:-}"' EXIT HUP INT TERM
  FINDINGS=
  printf '%s\t%s\n' schema "$RECORD_SCHEMA" > "$NEW_RECORD" || exit 1
  printf '%s\t%s\n' last_eval "$now" >> "$NEW_RECORD" || exit 1

  stat_surface tracked AGENTS.md "$FM_ROOT/AGENTS.md" no
  stat_surface tracked CLAUDE.md "$FM_ROOT/CLAUDE.md" yes
  stat_surface tracked bin/fm-session-start.sh "$FM_ROOT/bin/fm-session-start.sh" no
  stat_surface tracked bin/fm-bootstrap.sh "$FM_ROOT/bin/fm-bootstrap.sh" no
  stat_surface tracked bin/fm-startup-memory-budget-lib.sh "$FM_ROOT/bin/fm-startup-memory-budget-lib.sh" no
  stat_surface tracked bin/fm-supervision-instructions.sh "$FM_ROOT/bin/fm-supervision-instructions.sh" no
  stat_surface printed-memory data/projects.md "$DATA_DIR/projects.md" yes
  stat_surface printed-memory data/secondmates.md "$DATA_DIR/secondmates.md" yes
  stat_surface memory data/captain.md "$DATA_DIR/captain.md" yes
  stat_surface memory data/captain-shared.md "$DATA_DIR/captain-shared.md" yes
  stat_surface memory data/learnings.md "$DATA_DIR/learnings.md" yes

  if fm_startup_memory_budget_read "$CONFIG_DIR" >/dev/null; then
    budget=$FM_STARTUP_MEMORY_BUDGET_VALUE
    while IFS=$'\t' read -r display kind status memory_bytes _mtime _baseline; do
      [ "$kind" = memory ] && [ "$status" = present ] || continue
      memory_tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$memory_bytes") || memory_tokens=0
      memory_total=$((memory_total + memory_tokens))
    done < "$NEW_RECORD"
    printf '%s\t%s\t%s\n' memory_budget "$budget" "$memory_total" >> "$NEW_RECORD"
    if ! fm_startup_memory_decimal_le "$memory_total" "$budget"; then
      append_finding "startup memory budget overrun total_estimated_tokens=$memory_total budget=$budget owner=bin/fm-startup-memory-budget.sh"
    fi
  else
    append_finding "invalid startup memory budget owner=config/startup-memory-budget reason=$FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi

  write_record_atomically "$NEW_RECORD" "$RECORD" || fail "could not publish report record"
  NEW_RECORD=
  if [ -z "$FINDINGS" ]; then
    rm -f -- "$REPORTED"
    return 0
  fi
  reported_previous=
  [ ! -f "$REPORTED" ] || reported_previous=$(cat "$REPORTED" 2>/dev/null || true)
  if [ "$reported_previous" = "$FINDINGS" ]; then
    return 0
  fi
  tmp=$(mktemp "$STATE/.startup-growth-reported.XXXXXX") || exit 1
  printf '%s\n' "$FINDINGS" > "$tmp" || exit 1
  write_record_atomically "$tmp" "$REPORTED" || fail "could not publish dedupe record"
  printf '%s\n' "startup-growth: $FINDINGS"
}

arm() {
  local tmp state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$state_device" || fail "check shim path is unavailable"
  tmp=$(mktemp "$STATE/.startup-growth-check-shim.XXXXXX") || exit 1
  trap 'rm -f -- "${tmp:-}"' EXIT HUP INT TERM
  cat > "$tmp" <<SH
#!/usr/bin/env bash
exec "$(printf '%s' "$SCRIPT_DIR")/fm-startup-growth-check.sh" check
SH
  chmod 0700 "$tmp" || exit 1
  mv -f -- "$tmp" "$CHECK_SHIM" || exit 1
  tmp=
  "$REGISTER_BIN" "$CHECK_ID" >/dev/null || { rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"; exit 1; }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD" "$REPORTED"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    run_check
    ;;
  arm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
