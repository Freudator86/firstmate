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
# CLAUDE_CONFIG_DIR, then $HOME/.claude for a profile named default.
# setup_token_file is a presence probe; its value is never read into output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROFILE_FILE="$CONFIG/claude-profiles.json"
ID_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq required'; }

json_profiles() {
  need_jq
  if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ]; then
    [ -r "$PROFILE_FILE" ] || die "config/claude-profiles.json is not readable"
    jq -c --arg id_re "$ID_RE" '
      if type != "object" then error("top-level value must be an object")
      elif (.profiles | type) != "array" or (.profiles | length) == 0 then error("profiles must be a non-empty array")
      elif any(.profiles[]; type != "object") then error("each profile must be an object")
      elif any(.profiles[]; (.id | type) != "string" or (.id | length) == 0 or (.id | test($id_re) | not)) then error("each profile id must match " + $id_re)
      elif ((.profiles | map(.id) | length) != (.profiles | map(.id) | unique | length)) then error("profile ids must be unique")
      elif any(.profiles[]; has("config_dir") and ((.config_dir | type) != "string" or (.config_dir | length) == 0 or (.config_dir | startswith("/") | not))) then error("profile config_dir must be an absolute path")
      elif any(.profiles[]; has("setup_token_file") and ((.setup_token_file | type) != "string" or (.setup_token_file | length) == 0 or (.setup_token_file | startswith("/") | not))) then error("profile setup_token_file must be an absolute path")
      else .profiles end' "$PROFILE_FILE" 2>/dev/null || die "config/claude-profiles.json is malformed"
  else
    jq -cn --arg dir "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}" '[{id:"default",config_dir:$dir}]'
  fi
}

setup_state() {
  local file=$1
  if [ -n "$file" ] && [ -s "$file" ]; then printf 'available:file'; return; fi
  printf 'absent'
}

auth_state() {
  local dir=$1 line status
  [ -d "$dir" ] || { printf 'unauthenticated:missing-config-dir'; return; }
  line=$(CLAUDE_CONFIG_DIR="$dir" "$FM_ROOT/bin/fm-vendor-auth-probe.sh" claude 2>/dev/null) || {
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

render_one() {
  local p=$1 id dir setup_file auth setup
  id=$(jq -r '.id' <<<"$p")
  dir=$(jq -r '.config_dir // empty' <<<"$p")
  setup_file=$(jq -r '.setup_token_file // empty' <<<"$p")
  [ -n "$dir" ] || dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  auth=$(auth_state "$dir")
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
    p=$(jq -cer --arg id "$profile" 'map(select(.id == $id)) | first // empty' <<<"$profiles") || die "Claude profile not configured: $profile"
    line=$(render_one "$p")
    printf '%s\n' "$line"
    case "$line" in *' auth=authenticated '*) exit 0 ;; esac
    case "$line" in *' setup=available:'*) printf 'setup: Claude setup-token material is available for profile %s; run the credential installer before launching this profile.\n' "$profile" >&2 ;;
      *) printf 'setup: Claude setup-token material is absent for profile %s; add setup_token_file in config/claude-profiles.json or authenticate Claude interactively.\n' "$profile" >&2 ;;
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
