#!/usr/bin/env bash
# Inspect Claude profile authentication without printing credential values.
#
# Usage:
#   fm-claude-auth.sh check [--profile <id>]
#   fm-claude-auth.sh evidence
#
# Local config lives at config/claude-profiles.json in the active FM_HOME.
# Schema:
#   {"profiles":[{"id":"claude-max-a","config_dir":"/abs/path/to/.claude-a","setup_token_file":"/secret/path"}]}
# All fields except id are optional. config_dir defaults to this process's
# CLAUDE_CONFIG_DIR; when that is unset the profile is ambient, reported as an
# empty config_dir, probed with the variable unset, and launched without one,
# which is exactly the store an ordinary claude launch uses. A `default` profile
# naming that ambient store is synthesized whenever the file does not list one,
# so a pools-only file still answers a spawn that names no profile; an explicit
# `default` entry overrides the synthesized one.
# setup_token_file is a presence probe; its value is never read into output.
#
# A named (non-default) profile is a per-account capacity pool, which rests on
# CLAUDE_CONFIG_DIR deciding which Anthropic account answers. That separation is
# verified first-hand only on Linux (docs/verification/dispatch-auth.md), so a
# named profile reports `unsupported:pool-separation-unverified` on every other
# platform instead of a probe verdict that a shared credential keychain could
# answer from the wrong account. The `default` profile is unaffected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROFILE_FILE="$CONFIG/claude-profiles.json"
ID_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
POOL_SEPARATION_VERIFIED_PLATFORM=Linux

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq required'; }

json_profiles() {
  local dir="${CLAUDE_CONFIG_DIR:-}"
  need_jq
  if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ]; then
    [ -r "$PROFILE_FILE" ] || die "config/claude-profiles.json is not readable"
    jq -c --arg id_re "$ID_RE" --arg dir "$dir" '
      if type != "object" then error("top-level value must be an object")
      elif (.profiles | type) != "array" or (.profiles | length) == 0 then error("profiles must be a non-empty array")
      elif any(.profiles[]; type != "object") then error("each profile must be an object")
      elif any(.profiles[]; (.id | type) != "string" or (.id | length) == 0 or (.id | test($id_re) | not)) then error("each profile id must match " + $id_re)
      elif ((.profiles | map(.id) | length) != (.profiles | map(.id) | unique | length)) then error("profile ids must be unique")
      elif any(.profiles[]; has("config_dir") and ((.config_dir | type) != "string" or (.config_dir | length) == 0 or (.config_dir | startswith("/") | not))) then error("profile config_dir must be an absolute path")
      elif any(.profiles[]; has("setup_token_file") and ((.setup_token_file | type) != "string" or (.setup_token_file | length) == 0 or (.setup_token_file | startswith("/") | not))) then error("profile setup_token_file must be an absolute path")
      elif any(.profiles[]; .id == "default") then .profiles
      else .profiles + [{id: "default"} + (if $dir == "" then {} else {config_dir: $dir} end)] end' "$PROFILE_FILE" 2>/dev/null || die "config/claude-profiles.json is malformed"
  else
    jq -cn --arg dir "$dir" '[{id: "default"} + (if $dir == "" then {} else {config_dir: $dir} end)]'
  fi
}

setup_state() {
  local file=$1
  if [ -n "$file" ] && [ -s "$file" ]; then printf 'available:file'; return; fi
  printf 'absent'
}

auth_state() {
  local dir=$1 line status
  local -a scope=(env -u CLAUDE_CONFIG_DIR)
  [ -z "$dir" ] || scope=(env CLAUDE_CONFIG_DIR="$dir")
  line=$("${scope[@]}" "$FM_ROOT/bin/fm-vendor-auth-probe.sh" claude 2>/dev/null) || {
    printf 'indeterminate:probe-error'
    return
  }
  case "$line" in
    *' status='*) status=${line#* status=}; status=${status%% *} ;;
    *) status=indeterminate ;;
  esac
  case "$status" in
    authenticated) printf 'authenticated' ;;
    unauthenticated) printf 'unauthenticated:vendor-probe' ;;
    timeout) printf 'indeterminate:probe-timeout' ;;
    unavailable) printf 'indeterminate:probe-unavailable' ;;
    *) printf 'indeterminate:vendor-probe' ;;
  esac
}

pool_separation_verified() {
  [ "$(uname -s 2>/dev/null)" = "$POOL_SEPARATION_VERIFIED_PLATFORM" ]
}

render_one() {
  local p=$1 id dir setup_file auth setup
  id=$(jq -r '.id' <<<"$p")
  dir=$(jq -r '.config_dir // empty' <<<"$p")
  setup_file=$(jq -r '.setup_token_file // empty' <<<"$p")
  [ -n "$dir" ] || dir="${CLAUDE_CONFIG_DIR:-}"
  if [ "$id" != default ] && ! pool_separation_verified; then
    auth=unsupported:pool-separation-unverified
  else
    auth=$(auth_state "$dir")
  fi
  setup=$(setup_state "$setup_file")
  printf 'profile=%s auth=%s setup=%s config_dir=%s\n' "$id" "$auth" "$setup" "$dir"
}

cmd=${1:-}; shift || true
profile=default
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die '--profile needs a value'; profile=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  check)
    profiles=$(json_profiles) || exit $?
    p=$(jq -cer --arg id "$profile" 'map(select(.id == $id)) | first // empty' <<<"$profiles") || die "Claude profile not configured in this home: $profile; config/claude-profiles.json is per-home and is never inherited between firstmate homes, so install this home's own file listing $profile with locally valid paths through the authorized credential path"
    line=$(render_one "$p")
    printf '%s\n' "$line"
    case "$line" in *' auth=authenticated '*) exit 0 ;; esac
    state=${line#* auth=}; state=${state%% *}
    case "$state" in
      unsupported:*)
        printf 'auth: Claude profile %s is a named capacity pool, and separating accounts by CLAUDE_CONFIG_DIR is verified first-hand only on %s (docs/verification/dispatch-auth.md). On this platform a shared credential store can answer for a different account than the pool names, so named pools are refused rather than silently spending the wrong account. Use the default profile here, or record a first-hand measurement for this platform before enabling named pools on it.\n' "$profile" "$POOL_SEPARATION_VERIFIED_PLATFORM" >&2
        ;;
      indeterminate:*)
        printf 'auth: Claude authentication for profile %s could not be verified (%s); the bounded vendor probe established nothing, so this launch is refused rather than assumed. Check that the claude CLI is installed and answers %s for this profile before retrying.\n' "$profile" "$state" "\`claude auth status\`" >&2
        ;;
      *)
        case "$line" in *' setup=available:'*) printf 'setup: Claude setup-token material is available for profile %s; run the credential installer before launching this profile.\n' "$profile" >&2 ;;
          *) printf 'setup: Claude setup-token material is absent for profile %s; add setup_token_file in config/claude-profiles.json or authenticate Claude interactively.\n' "$profile" >&2 ;;
        esac
        ;;
    esac
    exit 1
    ;;
  evidence)
    profiles=$(json_profiles) || exit $?
    while IFS= read -r p; do render_one "$p"; done <<EOF
$(jq -c '.[]' <<<"$profiles")
EOF
    ;;
  *) die 'usage: fm-claude-auth.sh check|evidence [--profile <id>]' ;;
esac
