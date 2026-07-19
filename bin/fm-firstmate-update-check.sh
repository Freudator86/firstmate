#!/usr/bin/env bash
# Check whether kunchenguid/firstmate has instruction-surface updates that are
# not present in this deployment.
#
# This is read-only with respect to the deployment checkout: comparison objects
# are fetched into a temporary repository, and the only persistent writes are
# local diagnostics under FM_HOME/state. It never updates firstmate and never
# contacts Bridge. A supervising firstmate relays FIRSTMATE_UPDATE_AVAILABLE
# through the normal crewmate-dispatch path.
#
# "Relevant" means an upstream-only commit changes AGENTS.md, bin/, or
# .agents/skills/. These are the running instruction surfaces named by
# AGENTS.md section 12. Public skills/ are installer-facing and do not trigger
# a fleet-wide running-vessel update by themselves.
#
# This script is not invoked by bootstrap or any other firstmate flow; it
# only reads and writes local state. Schedule it externally per firstmate
# home, at a cadence around twice daily, with cron or a systemd timer - see
# docs/configuration.md "Upstream firstmate update check" for the recipe.
#
# Usage: fm-firstmate-update-check.sh
# Environment:
#   FM_FIRSTMATE_UPSTREAM_URL overrides the canonical upstream URL.
#   FM_FIRSTMATE_UPSTREAM_HEAD skips network discovery and uses the named
#     commit already present in FM_FIRSTMATE_COMPARE_REPO (tests only).
#   FM_FIRSTMATE_COMPARE_REPO overrides the comparison repository (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
UPSTREAM_URL="${FM_FIRSTMATE_UPSTREAM_URL:-https://github.com/kunchenguid/firstmate.git}"
AVAILABLE="$STATE/firstmate-update.available"
STUCK="$STATE/firstmate-update.stuck"

mkdir -p "$STATE" 2>/dev/null || {
  echo "FIRSTMATE_UPDATE_STUCK: cannot create state directory $STATE"
  exit 0
}

record_stuck() {
  printf 'FIRSTMATE_UPDATE_STUCK: %s\n' "$1" > "$STUCK"
  cat "$STUCK"
  exit 0
}

# Match fm-update.sh: compare from the deployment's local default-branch ref,
# not a possibly detached or feature-branch HEAD.
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
current=$(primary_head_commit "$FM_ROOT") || record_stuck "local default-branch commit cannot be resolved"

tmp=""
compare_repo=${FM_FIRSTMATE_COMPARE_REPO:-}
if [ -z "$compare_repo" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-firstmate-update.XXXXXX") || record_stuck "temporary comparison repository cannot be created"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init --bare -q || record_stuck "temporary comparison repository cannot be initialized"
  git -C "$tmp" fetch -q --no-tags "$FM_ROOT" "$current:refs/heads/local" || record_stuck "local default-branch commit cannot be copied for comparison"
  if ! git -C "$tmp" fetch -q --no-tags "$UPSTREAM_URL" HEAD:refs/heads/upstream; then
    record_stuck "upstream default-branch lookup failed ($UPSTREAM_URL)"
  fi
  compare_repo=$tmp
  upstream=$(git -C "$tmp" rev-parse --verify refs/heads/upstream)
else
  upstream=${FM_FIRSTMATE_UPSTREAM_HEAD:-}
  [ -n "$upstream" ] || record_stuck "test comparison repository requires FM_FIRSTMATE_UPSTREAM_HEAD"
fi

git -C "$compare_repo" cat-file -e "$current^{commit}" 2>/dev/null || record_stuck "local comparison commit is unavailable"
git -C "$compare_repo" cat-file -e "$upstream^{commit}" 2>/dev/null || record_stuck "upstream comparison commit is unavailable"

if git -C "$compare_repo" merge-base --is-ancestor "$upstream" "$current" 2>/dev/null; then
  rm -f "$AVAILABLE" "$STUCK"
  exit 0
fi

base=$(git -C "$compare_repo" merge-base "$current" "$upstream" 2>/dev/null) || record_stuck "local and upstream histories have no merge base"
if git -C "$compare_repo" diff --quiet "$base" "$upstream" -- AGENTS.md bin .agents/skills; then
  rm -f "$AVAILABLE" "$STUCK"
  exit 0
fi

printf 'FIRSTMATE_UPDATE_AVAILABLE: upstream instruction update %s -> %s; dispatch a crewmate to broadcast via Bridge All-Ships\n' \
  "$current" "$upstream" > "$AVAILABLE"
rm -f "$STUCK"
cat "$AVAILABLE"
