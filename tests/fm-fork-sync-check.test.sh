#!/usr/bin/env bash
# Network-free behavior tests for curated-fork synchronization detection.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-sync-check-tests)

commit_file() {
  local repo=$1 path=$2 content=$3
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$content"
  git -C "$repo" rev-parse HEAD
}

run_check() {
  local repo=$1 state=$2 fork=$3 upstream=$4 now=$5
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_FORK_SYNC_COMPARE_REPO="$repo" FM_FORK_SYNC_FORK_HEAD="$fork" \
    FM_FORK_SYNC_UPSTREAM_HEAD="$upstream" FM_FORK_SYNC_NOW="$now" \
    "$ROOT/bin/fm-fork-sync-check.sh"
}

test_pending_lists_and_cadence_gate() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/pending"
  state="$TMP_ROOT/pending-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" fork.txt fork-only)
  git -C "$repo" reset -q --hard "$base"
  upstream=$(commit_file "$repo" upstream.txt upstream-only)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 1000000)
  assert_contains "$out" 'FORK_SYNC:' "divergence was not reported"
  assert_contains "$out" '1 upstream-only commits' "upstream count was wrong"
  assert_contains "$out" '1 local patches to re-evaluate (0 provably absorbed)' "fork review count was wrong"
  assert_grep '  needs-review ' "$state/fork-sync.pending" "fork patch was not classified"
  [ "$(cat "$state/fork-sync.last-run")" = 1000000 ] || fail "completed check did not stamp last-run"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 1000001)
  [ -z "$out" ] || fail "three-day cadence gate emitted output: $out"
  pass "divergence is persisted with bounded review detail and gated for three days"
}

test_content_convergence_prefilters_absorbed_patch() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/absorbed"
  state="$TMP_ROOT/absorbed-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" reset -q --hard "$base"
  upstream=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -m upstream-summary
  upstream=$(git -C "$repo" rev-parse HEAD)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2000000)
  assert_contains "$out" '1 provably absorbed' "content-converged patch was not prefiltered"
  assert_grep '  absorbed ' "$state/fork-sync.pending" "absorbed detail was not persisted"
  pass "tip content convergence mechanically prefilters an absorbed fork patch"
}

test_up_to_date_clears_diagnostics() {
  local repo state upstream fork out
  repo="$TMP_ROOT/current"
  state="$TMP_ROOT/current-state"
  fm_git_init_commit "$repo"
  upstream=$(commit_file "$repo" upstream.txt upstream)
  fork=$(commit_file "$repo" fork.txt fork)
  mkdir -p "$state"
  printf 'old\n' > "$state/fork-sync.pending"
  printf 'old\n' > "$state/fork-sync.stuck"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 3000000)
  [ -z "$out" ] || fail "up-to-date fork emitted a diagnostic: $out"
  [ ! -f "$state/fork-sync.pending" ] || fail "up-to-date check did not clear pending"
  [ ! -f "$state/fork-sync.stuck" ] || fail "up-to-date check did not clear stuck"
  pass "a fork containing upstream clears persisted diagnostics"
}

test_pending_lists_and_cadence_gate
test_content_convergence_prefilters_absorbed_patch
test_up_to_date_clears_diagnostics
