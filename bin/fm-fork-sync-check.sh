#!/usr/bin/env bash
# Detect whether the curated fork needs its next upstream merge and bound the
# fork-only patch review with mechanical absorption hints.
#
# This script never changes the checkout or merges history. It fetches into a
# temporary bare repository and writes only FM_HOME/state/fork-sync.*. Run it
# daily from the curator vessel's external scheduler; fork-sync.last-run gates
# completed checks to one every three days.
#
# State contract:
#   fork-sync.last-run  epoch of the last completed comparison
#   fork-sync.pending   FORK_SYNC diagnostic and commit review lists
#   fork-sync.stuck     FORK_SYNC_STUCK diagnostic for an incomplete check
#
# Usage: fm-fork-sync-check.sh
# Environment:
#   FM_FIRSTMATE_UPSTREAM_URL overrides the canonical upstream URL.
#   FM_FIRSTMATE_FORK_URL overrides the fork URL (default: origin of FM_ROOT).
#   FM_FORK_SYNC_COMPARE_REPO uses an existing repository (tests only).
#   FM_FORK_SYNC_UPSTREAM_HEAD and FM_FORK_SYNC_FORK_HEAD name commits already
#     present in that repository (tests only).
#   FM_FORK_SYNC_NOW overrides the current epoch (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
UPSTREAM_URL="${FM_FIRSTMATE_UPSTREAM_URL:-https://github.com/kunchenguid/firstmate.git}"
PENDING="$STATE/fork-sync.pending"
STUCK="$STATE/fork-sync.stuck"
LAST_RUN="$STATE/fork-sync.last-run"
INTERVAL=$((3 * 24 * 60 * 60))
NOW=${FM_FORK_SYNC_NOW:-$(date +%s)}

mkdir -p "$STATE" 2>/dev/null || {
  echo "FORK_SYNC_STUCK: cannot create state directory $STATE"
  exit 0
}

record_stuck() {
  printf 'FORK_SYNC_STUCK: %s\n' "$1" > "$STUCK"
  cat "$STUCK"
  exit 0
}

case $NOW in *[!0-9]*|'') record_stuck "current epoch is invalid" ;; esac
if [ -f "$LAST_RUN" ]; then
  last=$(cat "$LAST_RUN" 2>/dev/null || true)
  case $last in
    *[!0-9]*|'') ;;
    *) [ $((NOW - last)) -ge "$INTERVAL" ] || exit 0 ;;
  esac
fi

# Match fm-update.sh when discovering the deployment's default-branch commit.
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"

tmp=""
compare_repo=${FM_FORK_SYNC_COMPARE_REPO:-}
if [ -z "$compare_repo" ]; then
  current=$(primary_head_commit "$FM_ROOT") || record_stuck "local default-branch commit cannot be resolved"
  fork_url=${FM_FIRSTMATE_FORK_URL:-$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null)}
  [ -n "$fork_url" ] || record_stuck "fork origin URL cannot be resolved"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-sync.XXXXXX") || record_stuck "temporary comparison repository cannot be created"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init --bare -q || record_stuck "temporary comparison repository cannot be initialized"
  git -C "$tmp" fetch -q --no-tags "$FM_ROOT" "$current:refs/heads/local" || record_stuck "local default-branch commit cannot be copied for comparison"
  git -C "$tmp" fetch -q --no-tags "$fork_url" HEAD:refs/heads/fork || record_stuck "fork default-branch lookup failed ($fork_url)"
  git -C "$tmp" fetch -q --no-tags "$UPSTREAM_URL" HEAD:refs/heads/upstream || record_stuck "upstream default-branch lookup failed ($UPSTREAM_URL)"
  compare_repo=$tmp
  fork=$(git -C "$tmp" rev-parse --verify refs/heads/fork)
  upstream=$(git -C "$tmp" rev-parse --verify refs/heads/upstream)
else
  fork=${FM_FORK_SYNC_FORK_HEAD:-}
  upstream=${FM_FORK_SYNC_UPSTREAM_HEAD:-}
  [ -n "$fork" ] && [ -n "$upstream" ] || record_stuck "test comparison repository requires fork and upstream heads"
fi

git -C "$compare_repo" cat-file -e "$fork^{commit}" 2>/dev/null || record_stuck "fork comparison commit is unavailable"
git -C "$compare_repo" cat-file -e "$upstream^{commit}" 2>/dev/null || record_stuck "upstream comparison commit is unavailable"

if git -C "$compare_repo" merge-base --is-ancestor "$upstream" "$fork" 2>/dev/null; then
  rm -f "$PENDING" "$STUCK"
  printf '%s\n' "$NOW" > "$LAST_RUN"
  exit 0
fi
git -C "$compare_repo" merge-base "$fork" "$upstream" >/dev/null 2>&1 || record_stuck "fork and upstream histories have no merge base"

upstream_list=$(git -C "$compare_repo" rev-list --oneline "$fork..$upstream") || record_stuck "upstream-only commit list cannot be computed"
fork_list=$(git -C "$compare_repo" rev-list --oneline --no-merges "$upstream..$fork") || record_stuck "fork-only commit list cannot be computed"
cherry=$(git -C "$compare_repo" cherry "$upstream" "$fork") || record_stuck "patch equivalence cannot be computed"
upstream_count=$(printf '%s\n' "$upstream_list" | awk 'NF { count++ } END { print count+0 }')
fork_count=$(printf '%s\n' "$fork_list" | awk 'NF { count++ } END { print count+0 }')
absorbed_count=0
review_detail=""

while IFS=' ' read -r commit summary; do
  [ -n "$commit" ] || continue
  verdict=needs-review
  if printf '%s\n' "$cherry" | grep -q "^- $commit"; then
    verdict=absorbed
  else
    mapfile -t files < <(git -C "$compare_repo" diff-tree --no-commit-id --name-only -r "$commit")
    if [ "${#files[@]}" -gt 0 ] && git -C "$compare_repo" diff --quiet "$upstream" "$fork" -- "${files[@]}"; then
      verdict=absorbed
    fi
  fi
  [ "$verdict" != absorbed ] || absorbed_count=$((absorbed_count + 1))
  review_detail="${review_detail}  $verdict $commit $summary
"
done <<EOF
$fork_list
EOF

{
  printf 'FORK_SYNC: upstream %.7s not merged into fork (%s upstream-only commits); %s local patches to re-evaluate (%s provably absorbed): dispatch a fork-sync crewmate\n' "$upstream" "$upstream_count" "$fork_count" "$absorbed_count"
  printf '  upstream-only commits:\n'
  printf '%s\n' "$upstream_list" | sed '/^$/d; s/^/    /'
  printf '  fork-only patches:\n'
  printf '%s' "$review_detail"
} > "$PENDING"
printf '%s\n' "$NOW" > "$LAST_RUN"
rm -f "$STUCK"
cat "$PENDING"
