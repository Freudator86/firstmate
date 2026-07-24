#!/usr/bin/env bash
# Shared read-only Bridge inbox detection and durable wake publication.
#
# Source after bin/fm-wake-lib.sh.
# bridge_inbox_surface [fetch]
#   Serializes fetch, signature comparison, wake append, and surfaced-marker
#   publication across the slow watcher and the fast frequency monitor.
#   Pass 1 to fetch origin/main before scanning, or 0 to scan the already-fetched
#   ref.
#   Prints one actionable reason only when it durably appended a new wake.

FM_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BRIDGE_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_BRIDGE_LIB_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_BRIDGE_LIB_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
BRIDGE_CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}
BRIDGE_ROOT=${FM_BRIDGE_ROOT:-$FM_HOME/projects/coditan-bridge}
BRIDGE_URGENT_CHECK_INTERVAL=${FM_BRIDGE_URGENT_CHECK_INTERVAL:-30}
BRIDGE_INBOX_LOCK=${FM_BRIDGE_INBOX_LOCK:-$STATE/.bridge-inbox.lock}

if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
  BRIDGE_VESSEL_RAW=$FM_BRIDGE_VESSEL
elif [ -f "$FM_HOME/config/bridge-vessel" ]; then
  IFS= read -r BRIDGE_VESSEL_RAW < "$FM_HOME/config/bridge-vessel" || BRIDGE_VESSEL_RAW=
else
  BRIDGE_VESSEL_RAW=
fi

# BRIDGE_VESSEL keeps the historical first/primary value while the ordered
# array preserves the existing optional multi-vessel watcher behavior.
BRIDGE_VESSELS=()
read -r -a BRIDGE_VESSELS <<< "$BRIDGE_VESSEL_RAW"
BRIDGE_VESSEL=${BRIDGE_VESSELS[0]:-}

bridge_run_bounded() {
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  else
    # shellcheck disable=SC2016
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  fi
}

bridge_pending_priority_scan() {
  local inbox="inbox/$BRIDGE_VESSEL/new" f priority rank=-1
  while IFS= read -r -d '' f; do
    case "$f" in *.json) ;; *) continue ;; esac
    priority=$(git -C "$BRIDGE_ROOT" show "origin/main:$inbox/$f" 2>/dev/null | jq -r '.priority // "normal"' 2>/dev/null || echo normal)
    case "$priority" in
      immediate) rank=3 ;;
      high) [ "$rank" -lt 2 ] && rank=2 ;;
      normal) [ "$rank" -lt 1 ] && rank=1 ;;
      low) [ "$rank" -lt 0 ] && rank=0 ;;
      *) [ "$rank" -lt 1 ] && rank=1 ;;
    esac
  done < <(git -C "$BRIDGE_ROOT" ls-tree -z --name-only "origin/main:$inbox" 2>/dev/null)
  case "$rank" in 3) echo immediate ;; 2) echo high ;; 1) echo normal ;; 0) echo low ;; *) echo none ;; esac
}
export -f bridge_pending_priority_scan

bridge_inbox_signature_scan() {
  local inbox="inbox/$BRIDGE_VESSEL/new" sig
  sig=$(git -C "$BRIDGE_ROOT" rev-parse "origin/main:$inbox" 2>/dev/null || true)
  printf '%s' "${sig:-empty}"
}
export -f bridge_inbox_signature_scan

bridge_inbox_signature() {
  local vessel=${1:-$BRIDGE_VESSEL} out
  out=$(BRIDGE_ROOT="$BRIDGE_ROOT" BRIDGE_VESSEL="$vessel" bridge_run_bounded bash -c 'bridge_inbox_signature_scan')
  printf '%s' "${out:-timeout}"
}

# The primary vessel keeps the historical unsuffixed filenames.
bridge_state_suffix() {
  local vessel=$1
  [ "$vessel" = "$BRIDGE_VESSEL" ] && return 0
  printf -- '-%s' "$(printf '%s' "$vessel" | tr -c 'A-Za-z0-9_.-' '_')"
}

bridge_pending_priority() {
  local sig=${1:-} vessel=${2:-$BRIDGE_VESSEL} cache cached_sig="" cached_priority="" out
  [ -n "$vessel" ] || { printf '%s' none; return; }
  [ -d "$BRIDGE_ROOT/.git" ] || { printf '%s' none; return; }
  cache="$STATE/.bridge-priority-cache$(bridge_state_suffix "$vessel")"
  [ -n "$sig" ] || sig=$(bridge_inbox_signature "$vessel")
  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_sig cached_priority < "$cache" 2>/dev/null || true
  fi
  if [ "$sig" = timeout ]; then printf '%s' "${cached_priority:-none}"; return; fi
  if [ -n "$cached_sig" ] && [ "$sig" = "$cached_sig" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  out=$(BRIDGE_ROOT="$BRIDGE_ROOT" BRIDGE_VESSEL="$vessel" bridge_run_bounded bash -c 'bridge_pending_priority_scan')
  if [ -z "$out" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  printf '%s\t%s\n' "$sig" "$out" > "$cache" 2>/dev/null || true
  printf '%s' "$out"
}

bridge_check_interval() {
  local vessel
  for vessel in "${BRIDGE_VESSELS[@]}"; do
    case "$(bridge_pending_priority "" "$vessel")" in
      high|immediate) echo "$BRIDGE_URGENT_CHECK_INTERVAL"; return ;;
    esac
  done
  echo "${CHECK_INTERVAL:-300}"
}

bridge_inbox_check() {
  local vessel=$1 sig=${2:-}
  local inbox="inbox/$vessel/new" highest count
  highest=$(bridge_pending_priority "$sig" "$vessel")
  [ "$highest" != none ] || return 0
  count=$(bridge_run_bounded git -C "$BRIDGE_ROOT" ls-tree --name-only "origin/main:$inbox" | awk '/[.]json$/' | wc -l | tr -d '[:space:]')
  printf 'bridge-inbox %s pending=%s highest=%s\n' "$vessel" "${count:-0}" "$highest"
}

bridge_inbox_fetch() {
  bridge_run_bounded git -C "$BRIDGE_ROOT" fetch --quiet origin main >/dev/null
}

bridge_inbox_surface() {
  local fetch=${1:-0} vessel marker sig surfaced vessel_out out="" reason="" status=0 i
  local marker_paths=() marker_sigs=()

  [ "${#BRIDGE_VESSELS[@]}" -gt 0 ] || return 0
  [ -d "$BRIDGE_ROOT/.git" ] || return 0
  fm_lock_acquire_wait "$BRIDGE_INBOX_LOCK" || return "$?"

  case "$fetch" in 1|true|TRUE|yes|YES) bridge_inbox_fetch ;; esac
  for vessel in "${BRIDGE_VESSELS[@]}"; do
    marker="$STATE/.bridge-surfaced$(bridge_state_suffix "$vessel")"
    sig=$(bridge_inbox_signature "$vessel")
    surfaced=$(cat "$marker" 2>/dev/null || true)
    [ "$sig" != timeout ] || continue
    [ "$sig" != "$surfaced" ] || continue
    vessel_out=$(bridge_inbox_check "$vessel" "$sig")
    if [ -n "$vessel_out" ]; then
      out="${out:+$out; }$vessel_out"
      marker_paths[${#marker_paths[@]}]=$marker
      marker_sigs[${#marker_sigs[@]}]=$sig
    else
      rm -f "$marker" 2>/dev/null || true
    fi
  done

  if [ -n "$out" ]; then
    reason="check: bridge-inbox: $out"
    fm_wake_append check bridge-inbox "$reason" || status=$?
    if [ "$status" -eq 0 ]; then
      i=0
      while [ "$i" -lt "${#marker_paths[@]}" ]; do
        printf '%s' "${marker_sigs[$i]}" > "${marker_paths[$i]}" 2>/dev/null || true
        i=$((i + 1))
      done
    fi
  fi
  fm_lock_release "$BRIDGE_INBOX_LOCK"
  [ "$status" -eq 0 ] || return "$status"
  [ -z "$reason" ] || printf '%s\n' "$reason"
}
