#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh's detect-only primary origin-drift check.
#
# The check compares only a primary checkout on its own default branch, reports
# quantified ahead/behind drift after a bounded fetch, and never duplicates the
# existing TANGLE diagnostic for an off-default branch.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-self-drift)
fm_git_identity

make_case() {
  local name=$1 seed remote primary writer
  seed="$TMP_ROOT/$name-seed"
  remote="$TMP_ROOT/$name-origin.git"
  primary="$TMP_ROOT/$name-primary"
  writer="$TMP_ROOT/$name-writer"
  git init -q -b main "$seed"
  printf '%s\n' initial > "$seed/tracked"
  git -C "$seed" add tracked
  git -C "$seed" commit -qm initial
  git clone -q --bare "$seed" "$remote"
  git clone -q "$remote" "$primary"
  git clone -q "$remote" "$writer"
  printf '%s|%s\n' "$primary" "$writer"
}

run_bootstrap() {
  local repo=$1
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT="${FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT:-3}" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

self_drift_line() {
  run_bootstrap "$1" | grep '^SELF_DRIFT:' || true
}

commit_file() {
  local repo=$1 content=$2
  printf '%s\n' "$content" >> "$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" commit -qm "$content"
}

test_clean_matching_is_silent() {
  local fixture primary out
  fixture=$(make_case clean)
  primary=${fixture%%|*}
  out=$(self_drift_line "$primary")
  [ -z "$out" ] || fail "matching primary emitted drift: $out"
  pass "self drift: matching default branch is silent"
}

test_ahead_only_is_quantified() {
  local fixture primary out
  fixture=$(make_case ahead)
  primary=${fixture%%|*}
  commit_file "$primary" local
  out=$(self_drift_line "$primary")
  assert_contains "$out" "is 1 ahead, 0 behind origin/main (ahead)" "ahead-only drift was not quantified"
  pass "self drift: ahead-only default branch is quantified"
}

test_behind_only_is_quantified() {
  local fixture primary writer out
  fixture=$(make_case behind)
  primary=${fixture%%|*}
  writer=${fixture#*|}
  commit_file "$writer" remote
  git -C "$writer" push -q origin main
  out=$(self_drift_line "$primary")
  assert_contains "$out" "is 0 ahead, 1 behind origin/main (behind)" "behind-only drift was not quantified"
  pass "self drift: behind-only default branch is quantified"
}

test_diverged_is_quantified() {
  local fixture primary writer out
  fixture=$(make_case diverged)
  primary=${fixture%%|*}
  writer=${fixture#*|}
  commit_file "$primary" local
  commit_file "$writer" remote
  git -C "$writer" push -q origin main
  out=$(self_drift_line "$primary")
  assert_contains "$out" "is 1 ahead, 1 behind origin/main (diverged)" "diverged drift was not quantified"
  pass "self drift: diverged default branch is quantified"
}

test_no_origin_is_silent() {
  local repo out
  repo="$TMP_ROOT/no-origin"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m initial
  out=$(self_drift_line "$repo")
  [ -z "$out" ] || fail "no-origin primary emitted drift: $out"
  pass "self drift: primary without origin is silent"
}

test_off_default_reports_only_tangle() {
  local fixture primary out
  fixture=$(make_case off-default)
  primary=${fixture%%|*}
  git -C "$primary" checkout -qb fm/feature
  commit_file "$primary" feature
  out=$(run_bootstrap "$primary")
  assert_contains "$out" "TANGLE: primary checkout on feature branch 'fm/feature'" "off-default primary did not report TANGLE"
  assert_not_contains "$out" "SELF_DRIFT:" "off-default primary double-reported SELF_DRIFT"
  pass "self drift: off-default primary leaves reporting to TANGLE"
}

test_detached_head_is_silent() {
  local fixture primary out
  fixture=$(make_case detached)
  primary=${fixture%%|*}
  git -C "$primary" checkout -q --detach
  out=$(run_bootstrap "$primary")
  assert_not_contains "$out" "SELF_DRIFT:" "detached-HEAD primary emitted drift"
  assert_not_contains "$out" "TANGLE:" "detached-HEAD primary emitted tangle"
  pass "self drift: detached-HEAD primary is silent"
}

test_fetch_failure_is_silent() {
  local fixture primary fakebin real_git out
  fixture=$(make_case fetch-fail)
  primary=${fixture%%|*}
  fakebin=$(fm_fakebin "$TMP_ROOT/fetch-fail-fake")
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "${FM_FAIL_GIT_ROOT:-}" ] && [ "${3:-}" = fetch ]; then
  exit 1
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" FM_REAL_GIT="$real_git" FM_FAIL_GIT_ROOT="$primary" \
    self_drift_line "$primary")
  [ -z "$out" ] || fail "fetch failure emitted drift instead of skipping: $out"
  pass "self drift: plain fetch failure is silently skipped"
}

test_slow_origin_is_bounded_and_silent() {
  local fixture primary fakebin real_git out start elapsed
  fixture=$(make_case slow)
  primary=${fixture%%|*}
  fakebin=$(fm_fakebin "$TMP_ROOT/slow-fake")
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "${FM_SLOW_GIT_ROOT:-}" ] && [ "${3:-}" = fetch ]; then
  sleep 300
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  start=$SECONDS
  out=$(PATH="$fakebin:$PATH" FM_REAL_GIT="$real_git" FM_SLOW_GIT_ROOT="$primary" \
    FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT=1 self_drift_line "$primary")
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 5 ] || fail "slow origin exceeded its bootstrap bound (${elapsed}s)"
  [ -z "$out" ] || fail "slow origin emitted drift instead of skipping: $out"
  pass "self drift: slow origin is bounded and silently skipped"
}

test_clean_matching_is_silent
test_ahead_only_is_quantified
test_behind_only_is_quantified
test_diverged_is_quantified
test_no_origin_is_silent
test_off_default_reports_only_tangle
test_detached_head_is_silent
test_fetch_failure_is_silent
test_slow_origin_is_bounded_and_silent
