#!/usr/bin/env bash
# Inspect Claude profile authentication without printing credential values.
#
# Usage:
#   fm-claude-auth.sh check [--profile <id>]
#   fm-claude-auth.sh evidence
#   fm-claude-auth.sh attest --profile <id> --confirm-setup-complete
#
# Local config lives at config/claude-profiles.json in the active FM_HOME.
# Schema:
#   {"profiles":[{"id":"claude-max-a","config_dir":"/abs/path/to/.claude-a","setup_token_file":"/secret/path"}]}
# Every named (non-default) profile must declare config_dir, since a named pool
# that fell back to the ambient store would alias the default account. Only the
# `default` profile may omit it; it then defaults to this process's
# CLAUDE_CONFIG_DIR, and when that is unset it is ambient, reported as an empty
# config_dir, probed with the variable unset, and launched without one, which
# is exactly the store an ordinary claude launch uses. A `default` profile
# naming that ambient store is synthesized whenever the file does not list one,
# so a pools-only file still answers a spawn that names no profile; an explicit
# `default` entry overrides the synthesized one.
# setup_token_file is a presence probe; its value is never read into output.
#
# The auth= field is the launch-readiness verdict for a profile, not only its
# login state: a named pool that is logged in but whose one-time interactive
# first-run setup has not been attested reports `unattested:...`, because
# Claude's Bypass Permissions and external-CLAUDE.md-import consents live in
# the pool's own store and firstmate's key plane cannot answer either dialog.
# `attest` records that the operator completed the documented setup for that
# store; it is refused unless the pool probes authenticated, and it is read back
# as stale when the store path or the running claude version no longer matches.
# docs/configuration.md "Claude profiles" owns the operator procedure.
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
POOL_READY_FILE=.fm-pool-ready

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq required'; }

json_profiles() {
  local dir="${CLAUDE_CONFIG_DIR:-}" out
  need_jq
  if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ]; then
    [ -r "$PROFILE_FILE" ] || die "config/claude-profiles.json is not readable"
    out=$(jq -c --arg id_re "$ID_RE" --arg dir "$dir" '
      if type != "object" then error("top-level value must be an object")
      elif (.profiles | type) != "array" or (.profiles | length) == 0 then error("profiles must be a non-empty array")
      elif any(.profiles[]; type != "object") then error("each profile must be an object")
      elif any(.profiles[]; (.id | type) != "string" or (.id | length) == 0 or (.id | test($id_re) | not)) then error("each profile id must match " + $id_re)
      elif ((.profiles | map(.id) | length) != (.profiles | map(.id) | unique | length)) then error("profile ids must be unique")
      elif any(.profiles[]; .id != "default" and (has("config_dir") | not)) then error("named profile " + ([.profiles[] | select(.id != "default" and (has("config_dir") | not)) | .id] | first) + " needs its own config_dir, because a named capacity pool must never fall back to the ambient default store")
      elif any(.profiles[]; has("config_dir") and ((.config_dir | type) != "string" or (.config_dir | length) == 0 or (.config_dir | startswith("/") | not))) then error("profile config_dir must be an absolute path")
      elif any(.profiles[]; has("setup_token_file") and ((.setup_token_file | type) != "string" or (.setup_token_file | length) == 0 or (.setup_token_file | startswith("/") | not))) then error("profile setup_token_file must be an absolute path")
      elif any(.profiles[]; .id == "default") then .profiles
      else .profiles + [{id: "default"} + (if $dir == "" then {} else {config_dir: $dir} end)] end' "$PROFILE_FILE" 2>&1) || {
      out=${out%%$'\n'*}
      die "config/claude-profiles.json is malformed: ${out#jq: error (at *): }"
    }
    printf '%s\n' "$out"
  else
    jq -cn --arg dir "$dir" '[{id: "default"} + (if $dir == "" then {} else {config_dir: $dir} end)]'
  fi
}

setup_state() {
  local file=$1
  if [ -n "$file" ] && [ -s "$file" ]; then printf 'available:file'; return; fi
  printf 'absent'
}

probe_line() {
  local dir=$1
  local -a scope=(env -u CLAUDE_CONFIG_DIR)
  [ -z "$dir" ] || scope=(env CLAUDE_CONFIG_DIR="$dir")
  "${scope[@]}" "$FM_ROOT/bin/fm-vendor-auth-probe.sh" claude 2>/dev/null
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

pool_separation_verified() {
  [ "$(uname -s 2>/dev/null)" = "$POOL_SEPARATION_VERIFIED_PLATFORM" ]
}

pool_ready_state() {
  local dir=$1 version=$2 file attested_dir attested_version
  file="$dir/$POOL_READY_FILE"
  [ -e "$file" ] || { printf 'unattested:setup-not-attested'; return; }
  [ -r "$file" ] || { printf 'unattested:attestation-unreadable'; return; }
  attested_dir=$(sed -n 's/^config_dir=//p' "$file" | head -n 1)
  attested_version=$(sed -n 's/^claude_version=//p' "$file" | head -n 1)
  [ -n "$attested_dir" ] && [ -n "$attested_version" ] \
    || { printf 'unattested:attestation-malformed'; return; }
  [ "$attested_dir" = "$dir" ] || { printf 'unattested:attested-for-another-store'; return; }
  [ -n "$version" ] && [ "$version" != none ] \
    || { printf 'unattested:claude-version-unknown'; return; }
  [ "$attested_version" = "$version" ] || { printf 'unattested:attested-on-claude-%s' "$attested_version"; return; }
  printf 'ready'
}

render_one() {
  local p=$1 id dir setup_file auth setup line ready
  id=$(jq -r '.id' <<<"$p")
  dir=$(jq -r '.config_dir // empty' <<<"$p")
  setup_file=$(jq -r '.setup_token_file // empty' <<<"$p")
  [ -n "$dir" ] || dir="${CLAUDE_CONFIG_DIR:-}"
  if [ "$id" != default ] && ! pool_separation_verified; then
    auth=unsupported:pool-separation-unverified
  else
    line=$(probe_line "$dir")
    auth=$(auth_state "$line")
    if [ "$id" != default ] && [ "$auth" = authenticated ]; then
      ready=$(pool_ready_state "$dir" "$(probe_field "$line" version)")
      [ "$ready" = ready ] || auth=$ready
    fi
  fi
  setup=$(setup_state "$setup_file")
  printf 'profile=%s auth=%s setup=%s config_dir=%s\n' "$id" "$auth" "$setup" "$dir"
}

cmd=${1:-}; shift || true
profile=default
confirm_setup=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die '--profile needs a value'; profile=$2; shift 2 ;;
    --confirm-setup-complete) confirm_setup=1; shift ;;
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
    dir_of_line=${line##* config_dir=}
    case "$state" in
      unsupported:*)
        printf 'auth: Claude profile %s is a named capacity pool, and separating accounts by CLAUDE_CONFIG_DIR is verified first-hand only on %s (docs/verification/dispatch-auth.md). On this platform a shared credential store can answer for a different account than the pool names, so named pools are refused rather than silently spending the wrong account. Use the default profile here, or record a first-hand measurement for this platform before enabling named pools on it.\n' "$profile" "$POOL_SEPARATION_VERIFIED_PLATFORM" >&2
        ;;
      unattested:*)
        printf 'setup: Claude profile %s is logged in, but its one-time interactive first-run setup for %s has not been attested (%s). Claude records the Bypass Permissions disclaimer and the external-CLAUDE.md-import consent in that store, and firstmate cannot answer either dialog, so the launch is refused rather than wedged. Complete the per-pool setup in docs/configuration.md "Claude profiles", then run: %s attest --profile %s --confirm-setup-complete\n' "$profile" "$dir_of_line" "$state" "$0" "$profile" >&2
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
  attest)
    [ "$confirm_setup" -eq 1 ] || die "attest records that you completed the one-time interactive setup for this pool; re-run with --confirm-setup-complete once docs/configuration.md \"Claude profiles\" has been followed for it"
    [ "$profile" != default ] || die "the default profile names the ambient store an ordinary claude launch already uses, so it carries no per-pool attestation"
    profiles=$(json_profiles) || exit $?
    p=$(jq -cer --arg id "$profile" 'map(select(.id == $id)) | first // empty' <<<"$profiles") || die "Claude profile not configured in this home: $profile"
    dir=$(jq -r '.config_dir // empty' <<<"$p")
    [ -n "$dir" ] || die "profile $profile names no config_dir, so there is no pool store to attest"
    pool_separation_verified || die "named pools are only honored on $POOL_SEPARATION_VERIFIED_PLATFORM (docs/verification/dispatch-auth.md), so $profile cannot be attested on this platform"
    line=$(probe_line "$dir")
    state=$(auth_state "$line")
    [ "$state" = authenticated ] \
      || die "profile $profile does not probe as authenticated ($state), so its interactive setup cannot have been completed; log that pool in first"
    version=$(probe_field "$line" version)
    [ -n "$version" ] && [ "$version" != none ] \
      || die "the running claude version could not be read, so an attestation could not be scoped to it"
    [ -d "$dir" ] || die "pool store $dir does not exist"
    umask 077
    {
      printf 'v1\n'
      printf 'config_dir=%s\n' "$dir"
      printf 'claude_version=%s\n' "$version"
      printf 'attested_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$dir/$POOL_READY_FILE" || die "could not record the attestation at $dir/$POOL_READY_FILE"
    printf 'attested profile=%s config_dir=%s claude_version=%s\n' "$profile" "$dir" "$version"
    ;;
  evidence)
    profiles=$(json_profiles) || exit $?
    while IFS= read -r p; do render_one "$p"; done <<EOF
$(jq -c '.[]' <<<"$profiles")
EOF
    ;;
  *) die 'usage: fm-claude-auth.sh check|evidence|attest [--profile <id>] [--confirm-setup-complete]' ;;
esac
