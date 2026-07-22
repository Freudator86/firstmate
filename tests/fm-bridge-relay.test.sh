#!/usr/bin/env bash
# Behavior tests for the guarded envelope-only Bridge relay dispatcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAY="$ROOT/bin/fm-bridge-relay.sh"
fm_test_tmproot TMP_ROOT fm-bridge-relay-tests
fm_git_identity fmtest fmtest@example.invalid

make_bridge() {
  local name=$1 home seed origin bridge origin_abs script
  home="$TMP_ROOT/$name/home"
  seed="$TMP_ROOT/$name/seed"
  origin="$TMP_ROOT/$name/origin.git"
  bridge="$home/projects/coditan-bridge"
  mkdir -p "$seed/bin" "$home/projects"

  cat > "$seed/bin/bridge-stub.sh" <<'SH'
#!/usr/bin/env bash
{
  printf 'script=%s\n' "$(basename "$0")"
  printf 'cwd=%s\n' "$PWD"
  printf 'argc=%s\n' "$#"
  index=0
  for arg in "$@"; do
    printf 'arg%s=<%s>\n' "$index" "$arg"
    index=$(( index + 1 ))
  done
} > "${BRIDGE_RELAY_CAPTURE:?}"
SH
  for script in send inbox status broadcast; do
    cp "$seed/bin/bridge-stub.sh" "$seed/bin/bridge-$script.sh"
    chmod +x "$seed/bin/bridge-$script.sh"
  done
  rm "$seed/bin/bridge-stub.sh"

  git -C "$seed" init -q -b main
  git -C "$seed" add bin
  git -C "$seed" commit -qm initial
  git clone -q --bare "$seed" "$origin"
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  origin_abs=$(cd "$origin" && pwd -P)
  git clone -q "file://$origin_abs" "$bridge"
  printf '%s\n' "$home"
}

run_relay() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" BRIDGE_RELAY_CAPTURE="$home/capture" \
    "$RELAY" "$@" 2>&1
}

test_unknown_subcommand_is_rejected() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/missing" FM_ROOT_OVERRIDE="$ROOT" "$RELAY" fetch 2>&1); rc=$?
  expect_code 1 "$rc" "unknown subcommand"
  assert_contains "$out" "unknown subcommand 'fetch'" "unknown subcommand was not identified"
  assert_contains "$out" 'usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]' \
    "unknown subcommand did not print usage"
  pass "Bridge relay rejects every unlisted subcommand before checkout inspection"
}

test_dirty_checkout_is_rejected() {
  local home bridge out rc
  home=$(make_bridge dirty)
  bridge="$home/projects/coditan-bridge"
  printf 'uncommitted\n' > "$bridge/dirty.txt"

  out=$(run_relay "$home" send vessel payload); rc=$?
  expect_code 1 "$rc" "dirty checkout"
  assert_contains "$out" 'has uncommitted changes' "dirty checkout refusal was unclear"
  assert_absent "$home/capture" "dirty checkout still invoked the Bridge script"
  pass "Bridge relay refuses a dirty target checkout without dispatching"
}

test_non_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge off-default)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" checkout -qb feature

  out=$(run_relay "$home" status vessel busy); rc=$?
  expect_code 1 "$rc" "non-default branch"
  assert_contains "$out" "must be on default branch 'main' (found 'feature')" \
    "non-default branch refusal was unclear"
  assert_absent "$home/capture" "non-default branch still invoked the Bridge script"
  pass "Bridge relay refuses a checkout that is not on its default branch"
}

test_untracked_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge no-upstream)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" branch --unset-upstream

  out=$(run_relay "$home" inbox list); rc=$?
  expect_code 1 "$rc" "untracked default branch"
  assert_contains "$out" "default branch 'main' is not tracking an upstream" \
    "missing-upstream refusal was unclear"
  assert_absent "$home/capture" "untracked default branch still invoked the Bridge script"
  pass "Bridge relay refuses a default branch without an upstream"
}

test_valid_calls_dispatch_verbatim() {
  local home bridge subcommand capture out
  home=$(make_bridge valid)
  bridge="$home/projects/coditan-bridge"

  for subcommand in send inbox status broadcast; do
    capture="$home/capture"
    rm -f "$capture"
    out=$(run_relay "$home" "$subcommand" 'argument with spaces' '--literal=*' '')
    [ -z "$out" ] || fail "$subcommand dispatch produced unexpected output: $out"
    assert_grep "script=bridge-$subcommand.sh" "$capture" \
      "$subcommand did not select its matching Bridge script"
    assert_grep "cwd=$bridge" "$capture" "$subcommand did not run inside the Bridge checkout"
    assert_grep 'argc=3' "$capture" "$subcommand did not preserve the argument count"
    assert_grep 'arg0=<argument with spaces>' "$capture" "$subcommand changed a spaced argument"
    assert_grep 'arg1=<--literal=*>' "$capture" "$subcommand expanded a literal argument"
    assert_grep 'arg2=<>' "$capture" "$subcommand dropped an empty argument"
  done
  pass "Bridge relay maps all four commands and forwards arguments verbatim from the checkout"
}

test_unknown_subcommand_is_rejected
test_dirty_checkout_is_rejected
test_non_default_branch_is_rejected
test_untracked_default_branch_is_rejected
test_valid_calls_dispatch_verbatim
