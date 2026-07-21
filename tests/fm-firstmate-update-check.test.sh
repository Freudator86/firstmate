#!/usr/bin/env bash
# Network-free behavior tests for the upstream firstmate update check.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-firstmate-update-check-tests

commit_file() {
  local repo=$1 path=$2 content=$3
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$content"
  git -C "$repo" rev-parse HEAD
}

run_check() {
  local repo=$1 state=$2 upstream=$3
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_FIRSTMATE_COMPARE_REPO="$repo" FM_FIRSTMATE_UPSTREAM_HEAD="$upstream" \
    "$ROOT/bin/fm-firstmate-update-check.sh"
}

test_relevant_update_found_and_cleared_when_current() {
  local repo state current upstream out
  repo="$TMP_ROOT/relevant"
  state="$TMP_ROOT/relevant-state"
  fm_git_init_commit "$repo"
  current=$(commit_file "$repo" AGENTS.md local)
  git -C "$repo" branch upstream-fixture
  upstream=$(commit_file "$repo" bin/new-check.sh upstream)
  git -C "$repo" branch -f upstream-fixture "$upstream"
  git -C "$repo" reset -q --hard "$current"

  out=$(run_check "$repo" "$state" "$upstream")
  assert_contains "$out" 'FIRSTMATE_UPDATE_AVAILABLE:' "relevant upstream update was not reported"
  assert_grep 'FIRSTMATE_UPDATE_AVAILABLE:' "$state/firstmate-update.available" "available signal was not persisted"

  git -C "$repo" merge --ff-only -q upstream-fixture
  out=$(run_check "$repo" "$state" "$upstream")
  [ -z "$out" ] || fail "up-to-date check emitted a diagnostic: $out"
  [ ! -f "$state/firstmate-update.available" ] || fail "up-to-date check did not clear the available signal"
  pass "relevant upstream updates are signaled and an up-to-date deployment is silent"
}

test_installer_only_update_is_not_relevant() {
  local repo state current upstream out
  repo="$TMP_ROOT/installer-only"
  state="$TMP_ROOT/installer-only-state"
  fm_git_init_commit "$repo"
  current=$(commit_file "$repo" AGENTS.md local)
  upstream=$(commit_file "$repo" skills/example/SKILL.md installer-only)
  git -C "$repo" reset -q --hard "$current"

  out=$(run_check "$repo" "$state" "$upstream")
  [ -z "$out" ] || fail "installer-only update was treated as relevant: $out"
  [ ! -f "$state/firstmate-update.available" ] || fail "installer-only update persisted an available signal"
  pass "public installer-skill-only changes do not trigger a running-vessel update"
}

test_relevant_update_found_and_cleared_when_current
test_installer_only_update_is_not_relevant
