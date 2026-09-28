#!/usr/bin/env bash
# Inspect readiness for an explicitly configured named Claude profile.
#
# Usage:
#   fm-claude-auth.sh check --profile <id>
#   fm-claude-auth.sh run --profile <id> -- <command> [args...]
#
# Local config lives at config/claude-profiles.json in the active FM_HOME.
# Schema:
#   {"profiles":[{"id":"claude-max-a","config_dir":"/abs/path/to/.claude-a",
#     "setup_token_file":"/abs/private/setup-token"}]}
# setup_token_file is optional. It holds exactly CLAUDE_CODE_SETUP_TOKEN=<value>
# (not shell code), is owned by this uid, regular, non-symlink, and mode 0600.
# The value is mapped to Claude's CLAUDE_CODE_OAUTH_TOKEN only in the process
# environment; neither argv nor generated launch scripts contain it. check
# requires a real bounded model response under that token, not auth status.
# After success it prepares theme/onboarding in the selected private store.
# run reads the file afresh and execs the command; no credentials are cached.
# Both paths shed ambient credentials using the upstream worker-account owner.
# Named profiles refuse when config/claude-account is also present: a per-task
# choice must not override a declared home-wide account boundary.
#
# This helper is intentionally narrow.
# It is only for named capacity pools selected with --claude-profile.
# The default Claude profile remains ambient: fm-spawn does not call this helper
# for it, so ordinary Claude launches keep the caller's normal CLAUDE_CONFIG_DIR
# behavior.
set +x
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROFILE_FILE="$CONFIG/claude-profiles.json"
ID_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq required'; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

json_profiles() {
  local out
  need_jq
  [ -e "$PROFILE_FILE" ] || die 'Claude profile not configured in this home: config/claude-profiles.json is absent; named Claude pools are per-home configuration and are never inherited with dispatch rules'
  [ -r "$PROFILE_FILE" ] || die 'config/claude-profiles.json is not readable'
  out=$(jq -c --arg id_re "$ID_RE" '
    if type != "object" then error("top-level value must be an object")
    elif (.profiles | type) != "array" or (.profiles | length) == 0 then error("profiles must be a non-empty array")
    elif any(.profiles[]; type != "object") then error("each profile must be an object")
    elif any(.profiles[]; (.id | type) != "string" or (.id | length) == 0 or (.id | test($id_re) | not)) then error("each profile id must match " + $id_re)
    elif any(.profiles[]; .id == "default") then error("default is ambient and must not be configured as a named pool")
    elif ((.profiles | map(.id) | length) != (.profiles | map(.id) | unique | length)) then error("profile ids must be unique")
    elif any(.profiles[]; (has("config_dir") | not)) then error("named profile " + ([.profiles[] | select(has("config_dir") | not) | .id] | first) + " needs its own config_dir")
    elif any(.profiles[]; (.config_dir | type) != "string" or (.config_dir | length) == 0 or (.config_dir | startswith("/") | not)) then error("profile config_dir must be an absolute path")
    elif any(.profiles[]; has("setup_token_file") and ((.setup_token_file | type) != "string" or (.setup_token_file | startswith("/") | not))) then error("setup_token_file must be an absolute path")
    elif any(.profiles[]; [.config_dir, (.setup_token_file // "")] | any(.[]; explode | any(. < 32 or . == 127))) then error("profile paths must not contain control characters")
    else .profiles as $all
      | ([$all[] | {id, store: (.config_dir | sub("/+$"; ""))}]
         | group_by(.store) | map(select(length > 1)) | first) as $clash
      | if $clash != null
        then error("profiles " + ($clash | map(.id) | join(" and ")) + " name the same Claude store " + $clash[0].store)
        else $all end
    end' "$PROFILE_FILE" 2>&1) || {
    out=${out%%$'\n'*}
    die "config/claude-profiles.json is malformed: ${out#jq: error (at *): }"
  }
  printf '%s\n' "$out"
}

probe_line() {
  local dir=$1
  (
    shed_credentials
    CLAUDE_CONFIG_DIR="$dir" "$FM_ROOT/bin/fm-vendor-auth-probe.sh" claude 2>/dev/null
  )
}

probe_field() {
  local line=$1 key=$2 value
  case "$line" in
    *" $key="*) value=${line#* "$key"=}; printf '%s' "${value%% *}" ;;
    *) printf '' ;;
  esac
}

auth_state() {
  local line=$1 status
  [ -n "$line" ] || { printf 'indeterminate:probe-error'; return; }
  status=$(probe_field "$line" status)
  [ -n "$status" ] || status=indeterminate
  case "$status" in
    authenticated) printf 'authenticated' ;;
    unauthenticated) printf 'unauthenticated:vendor-probe' ;;
    timeout) printf 'indeterminate:probe-timeout' ;;
    unavailable) printf 'indeterminate:probe-unavailable' ;;
    *) printf 'indeterminate:vendor-probe' ;;
  esac
}

onboarding_state() {
  local dir=$1
  jq -e '.hasCompletedOnboarding == true' "$dir/.claude.json" >/dev/null 2>&1 \
    && { printf 'ready'; return; }
  printf 'unonboarded:first-run-onboarding-incomplete'
}

shed_credentials() {
  local var
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED CLAUDE_CODE_SETUP_TOKEN; do
    unset "$var"
  done
}

load_token() {
  # Never source a secret file, put a token on argv, or echo a vendor error.
  local token
  token=$(perl -MFcntl=:DEFAULT,:mode -e '
    my $p = shift;
    sysopen(my $fh, $p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
    my @s = stat($fh);
    S_ISREG($s[2]) && $s[4] == $< && ($s[2] & 0777) == 0600 or exit 1;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\ACLAUDE_CODE_SETUP_TOKEN=([A-Za-z0-9_-]+)\n?\z/ or exit 1;
    print $1;
  ' -- "$1" 2>/dev/null) || die 'setup_token_file must be an owned, non-symlink mode-0600 regular file holding one CLAUDE_CODE_SETUP_TOKEN assignment'
  export CLAUDE_CODE_OAUTH_TOKEN="$token"
}

prepare_onboarding() {
  # This is presentation setup, not credential storage or workspace trust.
  node - "$dir" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
const file = path.join(dir, '.claude.json');
let tmp;
try {
  const root = fs.lstatSync(dir);
  if (!root.isDirectory() || root.uid !== process.getuid()) throw Error();
  let data = {}, original = null;
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.uid !== process.getuid()) throw Error();
    original = fs.readFileSync(file, 'utf8');
    data = JSON.parse(original);
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw Error();
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (data.hasCompletedOnboarding === true && data.theme != null) process.exit(0);
  data.hasCompletedOnboarding = true;
  data.theme ??= 'dark';
  tmp = file + '.firstmate-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(data), {mode: 0o600, flag: 'wx'});
  let current = null;
  try { current = fs.readFileSync(file, 'utf8'); }
  catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (current !== original) throw Error();
  fs.renameSync(tmp, file);
} catch (_) {
  if (tmp) { try { fs.unlinkSync(tmp); } catch (_) {} }
  console.error('error: cannot prepare named Claude onboarding safely');
  process.exit(1);
}
JS
}

cmd=${1:-}; shift || true
profile=
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die '--profile needs a value'; profile=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  check|run)
    [ -n "$profile" ] || die 'check requires --profile <id>'
    [ "$profile" != default ] || die 'default Claude profile is ambient and is not preflighted here'
    [ ! -e "$CONFIG/claude-account" ] && [ ! -L "$CONFIG/claude-account" ] \
      || die 'named Claude profiles cannot be combined with config/claude-account; choose per-task pools or the home-wide pin'
    profiles=$(json_profiles) || exit $?
    p=$(jq -cer --arg id "$profile" 'map(select(.id == $id)) | first // empty' <<<"$profiles") \
      || die "Claude profile not configured in this home: $profile; install config/claude-profiles.json with a local absolute config_dir for that named pool"
    dir=$(jq -r '.config_dir' <<<"$p")
    token_file=$(jq -r '.setup_token_file // empty' <<<"$p")
    if [ -n "$token_file" ]; then
      [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || die 'token profile config_dir must be an existing readable directory'
      shed_credentials
      load_token "$token_file"
      export CLAUDE_CONFIG_DIR="$dir"
      if [ "$cmd" = check ]; then
        # auth status accepts an expired or fabricated environment token. Only
        # a successful model response proves the selected token works.
        if ! result=$(fm_run_timed "${FM_CLAUDE_TOKEN_CHECK_SECONDS:-90}" claude --safe-mode -p 'Reply with exactly AUTH_OK.' \
          --model haiku --output-format json --no-session-persistence --tools '' \
          --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources '' \
          --system-prompt 'Respond only to the authentication test.' 2>/dev/null </dev/null) ||
          ! jq -e '.is_error == false and .subtype == "success" and .result == "AUTH_OK"' >/dev/null 2>&1 <<<"$result"; then
          printf 'profile=%s auth=unverified:token-effect config_dir=%s\n' "$profile" "$dir"
          exit 1
        fi
        unset result CLAUDE_CODE_OAUTH_TOKEN
        prepare_onboarding || exit 1
        printf 'profile=%s auth=authenticated config_dir=%s\n' "$profile" "$dir"
        exit 0
      fi
    fi
    if [ "$cmd" = run ]; then
      [ "$#" -gt 0 ] || die 'run requires a command after --'
      if [ -z "$token_file" ]; then shed_credentials; fi
      export CLAUDE_CONFIG_DIR="$dir"
      exec "$@"
    fi
    line=$(probe_line "$dir")
    auth=$(auth_state "$line")
    if [ "$auth" = authenticated ]; then
      onboard=$(onboarding_state "$dir")
      if [ "$onboard" = ready ]; then
        printf 'profile=%s auth=authenticated config_dir=%s\n' "$profile" "$dir"
        exit 0
      fi
      printf 'profile=%s auth=%s config_dir=%s\n' "$profile" "$onboard" "$dir"
      printf 'setup: Claude profile %s is logged in, but its store (%s) has not completed Claude first-run onboarding (%s), so a named worker would open on an interactive setup screen. Run claude once with CLAUDE_CONFIG_DIR=%s and finish onboarding, then retry.\n' "$profile" "$dir" "$onboard" "$dir" >&2
      exit 1
    fi
    printf 'profile=%s auth=%s config_dir=%s\n' "$profile" "$auth" "$dir"
    case "$auth" in
      indeterminate:*) printf 'auth: Claude authentication for named profile %s could not be verified (%s); refusing this named pool rather than launching an unchecked account.\n' "$profile" "$auth" >&2 ;;
      *) printf 'auth: Claude named profile %s is not authenticated (%s); authenticate that store before launching it.\n' "$profile" "$auth" >&2 ;;
    esac
    exit 1
    ;;
  -h|--help) usage ;;
  *) die 'usage: fm-claude-auth.sh check --profile <id>' ;;
esac
