#!/usr/bin/env bash
# Isolated gating tests for AXI-suite self-update behavior.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-axi-suite-tests

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_tool() {
  local bin=$1 tool=$2 version=$3
  cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '$tool $version'; fi
SH
  chmod +x "$bin/$tool"
}

make_hook_tool() {
  local bin=$1 tool=$2 version=$3 hook_log=$4
  cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '$tool $version'; exit 0; fi
if [ "\${1:-}" = setup ] && [ "\${2:-}" = hooks ]; then printf '%s\n' '$tool setup hooks' >> '$hook_log'; exit 0; fi
SH
  chmod +x "$bin/$tool"
}

make_npm() {
  local bin=$1 versions=$2 log=$3
  cat > "$bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then
  sed -n "s/^${2}=//p" "$FM_TEST_VERSIONS"
  exit 0
fi
if [ "${1:-}" = install ]; then
  printf '%s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
  exit 0
fi
exit 1
SH
  chmod +x "$bin/npm"
  : > "$log"
  : > "$versions"
}

run_case() {
  local root=$1 tools=$2
  PATH="$root/bin:$BASE_PATH" FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="$tools" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$root/versions" FM_TEST_INSTALL_LOG="$root/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force
}

test_patch_and_minor_auto_update() {
  local w out
  w="$TMP_ROOT/automatic"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" patch-axi 1.2.3
  make_tool "$w/bin" minor-axi 1.2.3
  sed -i "s/patch-axi 1.2.3/1.2.3/" "$w/bin/patch-axi"
  printf '%s\n' 'patch-axi=1.2.4' 'minor-axi=1.3.0' > "$w/versions"
  out=$(run_case "$w" "patch-axi minor-axi")
  assert_contains "$out" 'AXI_SUITE_UPDATED: patch-axi 1.2.3 -> 1.2.4' "patch update was not reported"
  assert_contains "$out" 'AXI_SUITE_UPDATED: minor-axi 1.2.3 -> 1.3.0' "minor update was not reported"
  assert_grep 'patch-axi@1.2.4' "$w/install.log" "patch update was not installed"
  assert_grep 'minor-axi@1.3.0' "$w/install.log" "minor update was not installed"
  pass "patch and minor AXI-suite releases auto-update"
}

test_major_and_missing_wait_for_review() {
  local w out
  w="$TMP_ROOT/review"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" major-axi 1.9.9
  printf '%s\n' 'major-axi=2.0.0' > "$w/versions"
  out=$(run_case "$w" "major-axi new-axi")
  assert_contains "$out" 'AXI_SUITE_REVIEW: major-axi major update 1.9.9 -> 2.0.0' "major update was not held"
  assert_contains "$out" 'AXI_SUITE_REVIEW: new-axi is not installed' "new tool was not held"
  [ ! -s "$w/install.log" ] || fail "review-only changes were installed"
  pass "major releases and new suite tools wait for review"
}

test_failed_update_persists_stuck_signal() {
  local w out
  w="$TMP_ROOT/stuck"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" stuck-axi 1.0.0
  printf '%s\n' 'stuck-axi=1.0.1' > "$w/versions"
  sed -i 's/if \[ "${1:-}" = install \]; then/if [ "${1:-}" = install ]; then exit 1; fi\nif false; then/' "$w/bin/npm"
  out=$(run_case "$w" "stuck-axi")
  assert_contains "$out" 'AXI_SUITE_STUCK: stuck-axi automatic update 1.0.0 -> 1.0.1 failed' "failed update was not surfaced"
  assert_grep 'AXI_SUITE_STUCK:' "$w/state/axi-suite-update.stuck" "stuck signal was not persisted"
  pass "failed updates persist a local stuck signal"
}

test_check_only_never_runs_hook_setup() {
  local w out
  w="$TMP_ROOT/check-only-hooks"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_hook_tool "$w/bin" gh-axi 2.0.0 "$w/hook.log"
  : > "$w/hook.log"
  printf '%s\n' 'gh-axi=2.0.0' > "$w/versions"
  printf 'AXI_SUITE_STUCK: gh-axi hook setup failed (already at 2.0.0)\n' > "$w/state/axi-suite-update.stuck"
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="gh-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force --check-only)
  [ ! -s "$w/hook.log" ] || fail "check-only ran the mutating hook setup command"
  assert_contains "$out" 'AXI_SUITE_STUCK: gh-axi hook setup retry pending' "check-only did not report the pending hook retry"
  assert_grep 'AXI_SUITE_STUCK:' "$w/state/axi-suite-update.stuck" "check-only cleared the stuck signal"
  pass "check-only never mutates hooks and keeps reporting the pending retry"
}

test_hook_retry_self_clears_stuck_signal() {
  local w out
  w="$TMP_ROOT/hook-retry"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_hook_tool "$w/bin" gh-axi 2.0.0 "$w/hook.log"
  : > "$w/hook.log"
  printf '%s\n' 'gh-axi=2.0.0' > "$w/versions"
  printf 'AXI_SUITE_STUCK: gh-axi hook setup failed (already at 2.0.0)\n' > "$w/state/axi-suite-update.stuck"
  run_case "$w" "gh-axi" >/dev/null
  assert_grep 'gh-axi setup hooks' "$w/hook.log" "a normal run did not retry hook setup"
  [ ! -f "$w/state/axi-suite-update.stuck" ] || fail "stuck signal was not self-cleared after a successful hook retry"
  pass "a successful hook retry self-clears the stuck signal on a normal run"
}

test_version_gt_without_sort_dash_v() {
  local w out
  w="$TMP_ROOT/no-sort-v"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" ahead-axi 2.1.0
  printf '%s\n' 'ahead-axi=2.0.5' > "$w/versions"
  cat > "$w/bin/sort" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -V) echo "sort: invalid option -- 'V'" >&2; exit 2 ;;
  esac
done
exec /usr/bin/sort "$@"
SH
  chmod +x "$w/bin/sort"
  run_case "$w" "ahead-axi" >/dev/null
  [ ! -s "$w/install.log" ] || fail "a locally-ahead tool was downgraded when sort -V is unavailable"
  pass "version comparison does not depend on GNU sort -V (locally-ahead tool is left alone)"
}

test_bounded_kills_hung_call_without_timeout_binary() {
  local w out minbin f name start end elapsed
  w="$TMP_ROOT/no-timeout-binary"
  minbin="$w/minbin"
  mkdir -p "$w/bin" "$w/home" "$w/state" "$minbin"
  for f in /usr/bin/* /bin/*; do
    name=$(basename "$f")
    case "$name" in timeout|gtimeout) continue ;; esac
    ln -sf "$f" "$minbin/$name" 2>/dev/null
  done
  cat > "$w/bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then sleep 30; exit 0; fi
exit 1
SH
  chmod +x "$w/bin/npm"
  make_tool "$w/bin" hang-axi 1.0.0
  start=$(date +%s)
  out=$(PATH="$w/bin:$minbin" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="hang-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_AXI_SUITE_NETWORK_TIMEOUT=1 \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 15 ] || fail "bounded() did not enforce the timeout without timeout/gtimeout on PATH (took ${elapsed}s)"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-axi latest version lookup failed' "hung lookup was not reported as stuck"
  pass "bounded() enforces the network timeout even without timeout/gtimeout on PATH"
}

test_cumulative_timeout_across_tools() {
  local w out start end elapsed
  w="$TMP_ROOT/cumulative-timeout"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  cat > "$w/bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then sleep 5; exit 0; fi
exit 1
SH
  chmod +x "$w/bin/npm"
  make_tool "$w/bin" hang-one-axi 1.0.0
  make_tool "$w/bin" hang-two-axi 1.0.0
  make_tool "$w/bin" hang-three-axi 1.0.0
  make_tool "$w/bin" hang-four-axi 1.0.0
  start=$(date +%s)
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="hang-one-axi hang-two-axi hang-three-axi hang-four-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_AXI_SUITE_NETWORK_TIMEOUT=2 \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 8 ] || fail "registry checks for 4 tools took ${elapsed}s, exceeding the cumulative FM_AXI_SUITE_NETWORK_TIMEOUT=2 budget (per-tool multiplication would take ~8s+)"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-one-axi latest version lookup failed' "first hung tool was not reported as stuck"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-four-axi latest version lookup failed' "last hung tool was not reported as stuck"
  pass "an unreachable registry cannot multiply the timeout across every tool in the suite"
}

test_patch_and_minor_auto_update
test_major_and_missing_wait_for_review
test_failed_update_persists_stuck_signal
test_check_only_never_runs_hook_setup
test_hook_retry_self_clears_stuck_signal
test_version_gt_without_sort_dash_v
test_bounded_kills_hung_call_without_timeout_binary
test_cumulative_timeout_across_tools
