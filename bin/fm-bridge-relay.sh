#!/usr/bin/env bash
# Relay envelope-only Bridge traffic through one of the four publishing scripts
# already owned by the coditan-bridge checkout.
# Usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]
# The checkout is always $FM_HOME/projects/coditan-bridge, or
# $FM_PROJECTS_OVERRIDE/coditan-bridge when that override is set.
# Before dispatch, this guard requires a clean checkout on its default branch
# with an upstream; it performs only read-only Git inspection and never accepts
# an arbitrary command or performs a Git mutation itself.
# Only the selected whitelisted Bridge script receives the remaining arguments,
# unchanged and from inside the Bridge checkout, and owns any resulting publish.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BRIDGE_ROOT="$PROJECTS/coditan-bridge"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

usage() {
  echo "usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]" >&2
}

[ "$#" -ge 1 ] || { usage; exit 1; }
subcommand=$1
shift

case "$subcommand" in
  send) bridge_script=bridge-send.sh ;;
  inbox) bridge_script=bridge-inbox.sh ;;
  status) bridge_script=bridge-status.sh ;;
  broadcast) bridge_script=bridge-broadcast.sh ;;
  *)
    echo "fm-bridge-relay: unknown subcommand '$subcommand'" >&2
    usage
    exit 1
    ;;
esac

[ -d "$BRIDGE_ROOT" ] || {
  echo "fm-bridge-relay: Bridge checkout not found: $BRIDGE_ROOT" >&2
  exit 1
}

git_root=$(git -C "$BRIDGE_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
  echo "fm-bridge-relay: target is not a Git checkout: $BRIDGE_ROOT" >&2
  exit 1
}
bridge_root=$(cd "$BRIDGE_ROOT" && pwd -P)
git_root=$(cd "$git_root" && pwd -P)
[ "$git_root" = "$bridge_root" ] || {
  echo "fm-bridge-relay: target is not the root of its Git checkout: $BRIDGE_ROOT" >&2
  exit 1
}

default=$(fm_default_branch "$BRIDGE_ROOT") || {
  echo "fm-bridge-relay: cannot determine the default branch for $BRIDGE_ROOT" >&2
  exit 1
}
current=$(git -C "$BRIDGE_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$current" = "$default" ] || {
  current=${current:-detached HEAD}
  echo "fm-bridge-relay: Bridge checkout must be on default branch '$default' (found '$current')" >&2
  exit 1
}

upstream=$(git -C "$BRIDGE_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
[ -n "$upstream" ] || {
  echo "fm-bridge-relay: default branch '$default' is not tracking an upstream" >&2
  exit 1
}

if ! dirty=$(git -C "$BRIDGE_ROOT" status --porcelain 2>/dev/null); then
  echo "fm-bridge-relay: cannot inspect Bridge checkout cleanliness: $BRIDGE_ROOT" >&2
  exit 1
fi
[ -z "$dirty" ] || {
  echo "fm-bridge-relay: Bridge checkout has uncommitted changes: $BRIDGE_ROOT" >&2
  exit 1
}

target="$BRIDGE_ROOT/bin/$bridge_script"
[ -x "$target" ] || {
  echo "fm-bridge-relay: Bridge script is missing or not executable: $target" >&2
  exit 1
}

cd "$BRIDGE_ROOT"
exec "$target" "$@"
