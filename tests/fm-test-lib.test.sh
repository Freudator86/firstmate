#!/usr/bin/env bash
# tests/fm-test-lib.test.sh - shared test-helper cleanup behavior.
# The shared temp-root helper must register cleanup in the caller shell and turn
# catchable interrupts into explicit exits through the current EXIT trap.
# SIGKILL is intentionally not covered because the kernel does not allow Bash to
# trap it; timeout wrappers must allow their initial HUP, INT, or TERM to run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-test-lib

PROBE="$TMP_ROOT/cleanup-probe.sh"
cat > "$PROBE" <<'PROBE'
#!/usr/bin/env bash
set -u
. "$1"
fm_test_tmproot scratch fm-test-lib-child

printf '%s\n' "$scratch" > "$2"
case "$3" in
  exit) exit 0 ;;
  term-custom-exit)
    marker=$4
    trap 'printf "custom-exit-ran\n" > "$marker"; fm_test_cleanup' EXIT
    while :; do sleep 1; done
    ;;
  *) exit 2 ;;
esac
PROBE
chmod +x "$PROBE"

wait_for_path() {
  local file=$1 pid=$2 i=0
  while [ "$i" -lt 50 ] && [ ! -s "$file" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$file" ]
}

test_normal_exit_cleans_registered_root() {
  local path_file="$TMP_ROOT/normal.path" scratch
  bash "$PROBE" "$ROOT/tests/lib.sh" "$path_file" exit || fail "normal cleanup probe failed"
  scratch=$(cat "$path_file")
  [ ! -e "$scratch" ] || {
    rm -rf "$scratch"
    fail "caller-shell temp root survived normal exit"
  }
  pass "caller-shell temp-root registration cleans on normal exit"
}

test_term_runs_custom_exit_and_cleans_registered_root() {
  local path_file="$TMP_ROOT/term.path" marker="$TMP_ROOT/custom-exit" pid rc scratch
  bash "$PROBE" "$ROOT/tests/lib.sh" "$path_file" term-custom-exit "$marker" &
  pid=$!
  wait_for_path "$path_file" "$pid" || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "TERM cleanup probe did not publish its scratch path"
  }
  kill -TERM "$pid" || fail "could not interrupt cleanup probe"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ] || fail "TERM cleanup probe returned $rc instead of 143"
  scratch=$(cat "$path_file")
  [ -f "$marker" ] || fail "test-owned EXIT trap did not run after TERM"
  [ ! -e "$scratch" ] || {
    rm -rf "$scratch"
    fail "registered temp root survived TERM"
  }
  pass "TERM preserves a test-owned EXIT trap and cleans its registered root"
}

test_output_var_named_root_is_assigned() {
  local root
  fm_test_tmproot root fm-test-lib-collide
  [ -n "${root:-}" ] || fail "output variable named 'root' was not assigned"
  [ -d "$root" ] || fail "output variable named 'root' does not point at a temp dir"
  pass "fm_test_tmproot assigns a caller variable named 'root' without collision"
}

test_normal_exit_cleans_registered_root
test_term_runs_custom_exit_and_cleans_registered_root
test_output_var_named_root_is_assigned
