#!/usr/bin/env bash
# Set the parent-home lifecycle state for one persistent secondmate.
# Usage: fm-secondmate-state.sh <active|resting> <absolute-parent-meta-file>
#
# The parent meta remains present in both states because the secondmate stays
# registered and may stay alive. state=resting only says that it has completed
# its own recovery/reconciliation and currently has no assigned or in-flight
# work, open escalation, or fresh result requiring supervision. Any routed text
# send switches it back to state=active before delivery; the secondmate switches
# itself to resting only at the charter's quiet idle boundary.
set -eu

usage() {
  cat <<'EOF'
Usage: fm-secondmate-state.sh <active|resting> <absolute-parent-meta-file>

Set a persistent secondmate's parent-home metadata state atomically.
Only kind=secondmate metadata is accepted.
EOF
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
NEXT=$1
META=$2

case "$NEXT" in
  active|resting) : ;;
  *) echo "error: secondmate state must be active or resting" >&2; exit 2 ;;
esac
case "$META" in
  /*.meta) : ;;
  *) echo "error: parent meta path must be an absolute .meta path" >&2; exit 2 ;;
esac
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: parent meta is missing, nonordinary, or symlinked: $META" >&2
  exit 1
}
grep -qx 'kind=secondmate' "$META" 2>/dev/null || {
  echo "error: parent meta is not kind=secondmate: $META" >&2
  exit 1
}

CURRENT=$(grep '^state=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ "$CURRENT" = "$NEXT" ] && exit 0

DIR=$(dirname "$META")
BASE=$(basename "$META")
TMP=$(mktemp "$DIR/.${BASE}.state.XXXXXX") || exit 1
# shellcheck disable=SC2329 # Invoked indirectly by the traps below.
cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT HUP INT TERM

awk -v next_state="$NEXT" '
  BEGIN { wrote = 0 }
  /^state=/ {
    if (!wrote) {
      print "state=" next_state
      wrote = 1
    }
    next
  }
  { print }
  END {
    if (!wrote) print "state=" next_state
  }
' "$META" > "$TMP"
chmod 600 "$TMP"
mv -f "$TMP" "$META"
trap - EXIT HUP INT TERM
exit 0
