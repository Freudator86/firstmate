#!/usr/bin/env bash
# Behavior tests for named Claude profile auth preflight.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-auth)
AUTH="$ROOT/bin/fm-claude-auth.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --safe-mode ] || shift
case "${1:-}" in
  --version)
    printf '%s (Claude Code)\n' "${FM_FAKE_CLAUDE_VERSION:-2.1.276}"
    exit 0
    ;;
  -p)
    # Only these synthetic tokens are accepted; auth status below still says
    # logged in, deliberately separating presence from network effect.
    [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_USE_BEDROCK:-}" ] || exit 9
    case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in
      fixture-token-a|fixture-token-b) printf '{"is_error":false,"subtype":"success","result":"AUTH_OK"}\n' ;;
      *) printf '{"is_error":true,"result":"secret-echo-%s"}\n' "${CLAUDE_CODE_OAUTH_TOKEN:-missing}"; exit 1 ;;
    esac
    exit 0
    ;;
  auth)
    if [ "${2:-}" = status ]; then
      [ -z "${FM_FAKE_CLAUDE_ENV_LOG:-}" ] || printf '%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" >> "$FM_FAKE_CLAUDE_ENV_LOG"
      status=${FM_FAKE_CLAUDE_STATUS:-}
      if [ -z "$status" ]; then
        case "${CLAUDE_CONFIG_DIR:-}" in */b|*/a-empty) status=unauthenticated ;; *) status=authenticated ;; esac
      fi
      case "$status" in
        authenticated) printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'; exit 0 ;;
        unauthenticated) printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'; exit 1 ;;
        garbage) printf 'session maybe\n' ;;
      esac
      exit 0
    fi
    ;;
esac
exit 2
SH
chmod +x "$FAKEBIN/claude"

make_home() {
  local dir=$1
  mkdir -p "$dir/config"
}

write_store() {
  local dir=$1 secret=${2:-secret-value}
  mkdir -p "$dir"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"refresh-secret"}}\n' "$secret" > "$dir/.credentials.json"
  fm_test_onboard_claude_store "$dir"
}

case_dir="$TMP_ROOT/authenticated"
make_home "$case_dir/home"
write_store "$case_dir/a" "top-secret-token"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 0 "$status" "authenticated named profile should pass: $out"
assert_contains "$out" "profile=claude-max-a auth=authenticated config_dir=$case_dir/a" "auth evidence missing"
assert_not_contains "$out" 'top-secret-token' "secret access token leaked"
assert_not_contains "$out" 'refresh-secret' "secret refresh token leaked"
pass "fm-claude-auth: authenticated named Claude profile proceeds without printing secrets"

case_dir="$TMP_ROOT/unauthenticated"
make_home "$case_dir/home"
mkdir -p "$case_dir/a-empty"
fm_test_onboard_claude_store "$case_dir/a-empty"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a-empty"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unauthenticated named profile should fail"
assert_contains "$out" 'auth=unauthenticated:vendor-probe' "auth failure should be reported"
assert_contains "$out" 'not authenticated' "unauthenticated profile should be actionable"
pass "fm-claude-auth: unauthenticated named profile is rejected"

case_dir="$TMP_ROOT/onboarding"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
printf '%s\n' '{"hasCompletedOnboarding":null}' > "$case_dir/a/.claude.json"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "logged-in named profile without onboarding should fail"
assert_contains "$out" 'auth=unonboarded:first-run-onboarding-incomplete' "onboarding verdict missing"
assert_contains "$out" 'first-run onboarding' "onboarding refusal should be actionable"
pass "fm-claude-auth: named profile that has not finished first-run onboarding is rejected"

case_dir="$TMP_ROOT/indeterminate"
make_home "$case_dir/home"
fm_test_onboard_claude_store "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLAUDE_STATUS=garbage FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unclassifiable probe result should fail"
assert_contains "$out" 'auth=indeterminate:vendor-probe' "indeterminate state should be reported"
assert_contains "$out" 'could not be verified' "indeterminate probe should not claim logged out"
pass "fm-claude-auth: indeterminate probe refuses without claiming the profile is logged out"

case_dir="$TMP_ROOT/no-default"
make_home "$case_dir/home"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 2 "$status" "default profile should not be checked by this helper"
assert_contains "$out" 'default Claude profile is ambient' "default refusal should preserve ambient behavior"
pass "fm-claude-auth: default profile remains outside named-pool preflight"

case_dir="$TMP_ROOT/named-without-config-dir"
make_home "$case_dir/home"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 2 "$status" "named pool without config_dir should be invalid"
assert_contains "$out" 'named profile claude-max-a needs its own config_dir' "diagnostic should name offending pool"
pass "fm-claude-auth: named pool without config_dir is rejected"

case_dir="$TMP_ROOT/aliased-stores"
make_home "$case_dir/home"
fm_test_onboard_claude_store "$case_dir/shared"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/shared"},{"id":"claude-max-b","config_dir":"$case_dir/shared/"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-b 2>&1); status=$?
expect_code 2 "$status" "two pools naming one store should be invalid"
assert_contains "$out" 'profiles claude-max-a and claude-max-b name the same Claude store' "diagnostic should name both offending pools"
pass "fm-claude-auth: two named profiles may not share one Claude store"

case_dir="$TMP_ROOT/help"
out=$(PATH="$FAKEBIN:$PATH" "$AUTH" check --help 2>&1); status=$?
expect_code 0 "$status" "check --help should succeed"
assert_contains "$out" 'fm-claude-auth.sh check --profile <id>' "help should advertise the check command"
assert_not_contains "$out" 'attest' "help should not advertise removed attestation commands"
assert_not_contains "$out" 'set -u' "help should stop at the end of the header"
pass "fm-claude-auth: --help documents the slim named-pool contract"

case_dir="$TMP_ROOT/malformed"
make_home "$case_dir/home"
printf '%s\n' '{"profiles":[{"id":"claude-max-a",}]}' > "$case_dir/home/config/claude-profiles.json"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 2 "$status" "malformed profile config should fail closed"
assert_contains "$out" 'config/claude-profiles.json is malformed' "malformed config should name its cause"
assert_not_contains "$out" 'auth=' "malformed config must not invent an auth verdict"
pass "fm-claude-auth: malformed profile config fails instead of inventing verdicts"

case_dir="$TMP_ROOT/setup-tokens"
make_home "$case_dir/home"
mkdir -p "$case_dir/a" "$case_dir/b"
printf '%s\n' '{"unrelated":"preserved"}' > "$case_dir/a/.claude.json"
fm_test_onboard_claude_store "$case_dir/c"
printf 'CLAUDE_CODE_SETUP_TOKEN=fixture-token-a\n' > "$case_dir/token-c"
chmod 600 "$case_dir/token-c"
for pool in a b; do
  printf 'CLAUDE_CODE_SETUP_TOKEN=fixture-token-%s\n' "$pool" > "$case_dir/token-$pool"
  chmod 600 "$case_dir/token-$pool"
done
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"pool-a","config_dir":"$case_dir/a","setup_token_file":"$case_dir/token-a"},{"id":"pool-b","config_dir":"$case_dir/b","setup_token_file":"$case_dir/token-b"},{"id":"pool-c","config_dir":"$case_dir/c","setup_token_file":"$case_dir/token-c"}]}
EOF
for pool in a b; do
  out=$(PATH="$FAKEBIN:$PATH" ANTHROPIC_API_KEY=ambient-wrong CLAUDE_CODE_OAUTH_TOKEN=ambient-wrong \
    FM_HOME="$case_dir/home" "$AUTH" check --profile "pool-$pool" 2>&1); status=$?
  expect_code 0 "$status" "setup token should authenticate by effect: $out"
  assert_not_contains "$out" fixture-token 'token must not appear in diagnostics'
  jq -e '.hasCompletedOnboarding == true and (has("theme") | not)' "$case_dir/$pool/.claude.json" >/dev/null || fail 'token profile onboarding not prepared without touching presentation state'
  # shellcheck disable=SC2016 # The launched shell, not this test, reads credentials.
  out=$(PATH="$FAKEBIN:$PATH" ANTHROPIC_API_KEY=ambient-wrong FM_HOME="$case_dir/home" \
    "$AUTH" run --profile "pool-$pool" -- bash -c \
    'test "$CLAUDE_CODE_OAUTH_TOKEN" = "fixture-token-$1" && test -z "${ANTHROPIC_API_KEY:-}" && test "$CLAUDE_CONFIG_DIR" = "$2" && echo selected' bash "$pool" "$case_dir/$pool" 2>&1); status=$?
  expect_code 0 "$status" "run must use exactly selected token and store: $out"
  assert_contains "$out" selected 'selected pool not used'
done
jq -e '.unrelated == "preserved"' "$case_dir/a/.claude.json" >/dev/null || fail 'onboarding erased unrelated config'
pass 'fm-claude-auth: setup tokens authenticate by effect, prepare onboarding and launch without ambient credentials'

before=$(cat "$case_dir/c/.claude.json")
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-c 2>&1); status=$?
expect_code 0 "$status" "already-onboarded token store should pass: $out"
[ "$(cat "$case_dir/c/.claude.json")" = "$before" ] || fail 'already-onboarded store was rewritten'
pass 'fm-claude-auth: an already-onboarded store is left untouched'

printf 'CLAUDE_CODE_SETUP_TOKEN=rejected-token\n' > "$case_dir/token-a"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-a 2>&1); status=$?
expect_code 1 "$status" 'auth status success cannot rescue rejected token'
assert_contains "$out" unverified:token-effect 'missing effect refusal'
assert_not_contains "$out" rejected-token 'vendor error leaked token'
# shellcheck disable=SC2016 # The launched shell verifies rotation without printing it.
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" run --profile pool-a -- bash -c 'test "$CLAUDE_CODE_OAUTH_TOKEN" = rejected-token && echo fresh' 2>&1); status=$?
expect_code 0 "$status" 'run should read the rotated file, not cache old token'
assert_contains "$out" fresh 'rotation was not read'
pass 'fm-claude-auth: rejected token is not rescued by ambient login; run rereads rotation'

for mode in 644 660; do
  chmod "$mode" "$case_dir/token-a"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-a 2>&1); status=$?
  expect_code 2 "$status" 'insecure token file must refuse'
  assert_not_contains "$out" rejected-token 'insecure file error leaked token'
done
chmod 600 "$case_dir/token-a"
# shellcheck disable=SC2016 # Deliberately literal malicious input, never execute it.
printf 'CLAUDE_CODE_SETUP_TOKEN=$(touch %s/executed)\n' "$case_dir" > "$case_dir/token-a"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-a 2>&1); status=$?
expect_code 2 "$status" 'shell code in token file must refuse'
[ ! -e "$case_dir/executed" ] || fail 'token file was sourced'
mv "$case_dir/token-a" "$case_dir/token-real"
ln -s "$case_dir/token-real" "$case_dir/token-a"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-a 2>&1); status=$?
expect_code 2 "$status" 'symlink token must refuse'
pass 'fm-claude-auth: token files require private permissions, literal assignment, and no symlink'

printf '%s\n' ordinary > "$case_dir/home/config/claude-account"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile pool-b 2>&1); status=$?
expect_code 2 "$status" 'home pin and named pool must not silently override each other'
assert_contains "$out" 'cannot be combined' 'missing account boundary diagnostic'
pass 'fm-claude-auth: named pools cannot override a declared home-wide pin'

echo '# all Claude auth preflight tests passed'
