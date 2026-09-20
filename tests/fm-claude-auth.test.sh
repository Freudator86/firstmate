#!/usr/bin/env bash
# Behavior tests for Claude profile auth preflight.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-auth)
AUTH="$ROOT/bin/fm-claude-auth.sh"

write_creds() {
  local dir=$1 secret=${2:-secret-value}
  mkdir -p "$dir"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"refresh-secret"}}\n' "$secret" > "$dir/.credentials.json"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/config"
}

case_dir="$TMP_ROOT/authenticated"
make_home "$case_dir/home"
write_creds "$case_dir/a" "top-secret-token"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a","provider":"claude-max-a"}]}
EOF
out=$(FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 0 "$status" "authenticated profile should pass: $out"
assert_contains "$out" 'profile=claude-max-a provider=claude-max-a auth=authenticated setup=absent' "auth evidence missing"
assert_not_contains "$out" 'top-secret-token' "secret access token leaked"
assert_not_contains "$out" 'refresh-secret' "secret refresh token leaked"
pass "fm-claude-auth: authenticated Claude profile proceeds without printing secrets"

case_dir="$TMP_ROOT/unauthenticated"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a","provider":"claude-max-a","setup_token_file":"$case_dir/setup-token"}]}
EOF
printf 'setup-token-secret\n' > "$case_dir/setup-token"
out=$(FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unauthenticated profile should fail"
assert_contains "$out" 'auth=unauthenticated:missing-credentials setup=available:file' "setup availability should be reported"
assert_contains "$out" 'run the credential installer' "available setup material should be actionable"
assert_not_contains "$out" 'setup-token-secret' "setup token value leaked"
pass "fm-claude-auth: unauthenticated profile is rejected and setup material is value-redacted"

case_dir="$TMP_ROOT/two-pools"
make_home "$case_dir/home"
write_creds "$case_dir/a"
mkdir -p "$case_dir/b"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a","provider":"claude-max-a"},{"id":"claude-max-b","config_dir":"$case_dir/b","provider":"claude-max-b"}]}
EOF
out=$(FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1) || fail "evidence failed: $out"
assert_contains "$out" 'profile=claude-max-a provider=claude-max-a auth=authenticated' "pool a missing"
assert_contains "$out" 'profile=claude-max-b provider=claude-max-b auth=unauthenticated:missing-credentials' "pool b missing"
pass "fm-claude-auth: both Claude pools are represented in auth evidence"

case_dir="$TMP_ROOT/no-setup"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a","provider":"claude-max-a"}]}
EOF
out=$(FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unauthenticated profile without setup should fail"
assert_contains "$out" 'setup=absent' "absent setup should be reported"
assert_contains "$out" 'add setup_token_file or setup_token_env' "absent setup should be actionable"
pass "fm-claude-auth: absent setup-token material reports an actionable setup need"

echo '# all Claude auth preflight tests passed'
