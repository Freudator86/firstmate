#!/usr/bin/env bash
# Fast, non-agentic Bridge inbox monitor for one Firstmate home.
#
# Usage:
#   fm-frequency-monitor.sh
#   fm-frequency-monitor.sh --once
#
# The default service loop fetches and checks Bridge every
# FM_FREQUENCY_MONITOR_INTERVAL seconds (default 5).  --once performs one
# bounded fetch/check, which is useful for tests and manual diagnostics.
# New mail is published through the existing durable wake queue; a live
# delivery stub notices that queue immediately, while an offline session drains
# the same record at its next start.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
# shellcheck source=bin/fm-bridge-inbox-lib.sh
. "$SCRIPT_DIR/fm-bridge-inbox-lib.sh"

# The fast path is deliberately per-home and per-vessel, not a fleet-wide
# scanner.  The slower watcher retains its optional multi-vessel compatibility.
if [ -n "$BRIDGE_VESSEL" ]; then
  BRIDGE_VESSELS=("$BRIDGE_VESSEL")
fi

FREQUENCY_INTERVAL=${FM_FREQUENCY_MONITOR_INTERVAL:-5}
case "$FREQUENCY_INTERVAL" in
  ''|*[!0-9]*|0)
    printf 'fm-frequency-monitor: FM_FREQUENCY_MONITOR_INTERVAL must be a positive integer\n' >&2
    exit 2
    ;;
esac

frequency_monitor_once() {
  local reason
  reason=$(bridge_inbox_surface 1) || return "$?"
  [ -z "$reason" ] || printf '%s\n' "$reason"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

case "${1:-}" in
  --once)
    [ "$#" -eq 1 ] || { echo "usage: $(basename "$0") [--once]" >&2; exit 2; }
    frequency_monitor_once
    exit
    ;;
  '')
    ;;
  *)
    echo "usage: $(basename "$0") [--once]" >&2
    exit 2
    ;;
esac

while :; do
  frequency_monitor_once || exit 1
  sleep "$FREQUENCY_INTERVAL"
done
