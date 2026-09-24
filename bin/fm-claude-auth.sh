#!/usr/bin/env bash
# Inspect readiness for an explicitly configured named Claude profile.
#
# Usage:
#   fm-claude-auth.sh check --profile <id>
#
# Local config lives at config/claude-profiles.json in the active FM_HOME.
# Schema:
#   {"profiles":[{"id":"claude-max-a","config_dir":"/abs/path/to/.claude-a"}]}
#
# This helper is intentionally narrow.
# It is only for named capacity pools selected with --claude-profile.
# The default Claude profile remains ambient: fm-spawn does not call this helper
# for it, so ordinary Claude launches keep the caller's normal CLAUDE_CONFIG_DIR
# behavior.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROFILE_FILE="$CONFIG/claude-profiles.json"
ID_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

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
  env CLAUDE_CONFIG_DIR="$dir" "$FM_ROOT/bin/fm-vendor-auth-probe.sh" claude 2>/dev/null
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

cmd=${1:-}; shift || true
profile=
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die '--profile needs a value'; profile=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  check)
    [ -n "$profile" ] || die 'check requires --profile <id>'
    [ "$profile" != default ] || die 'default Claude profile is ambient and is not preflighted here'
    profiles=$(json_profiles) || exit $?
    p=$(jq -cer --arg id "$profile" 'map(select(.id == $id)) | first // empty' <<<"$profiles") \
      || die "Claude profile not configured in this home: $profile; install config/claude-profiles.json with a local absolute config_dir for that named pool"
    dir=$(jq -r '.config_dir' <<<"$p")
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
