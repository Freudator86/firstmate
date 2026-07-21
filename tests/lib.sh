#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bootstrap's production AXI-suite check performs registry reads and package
# updates. Behavior tests opt out globally; fm-axi-suite.test.sh explicitly
# re-enables it against its isolated fake npm registry.
export FM_AXI_SUITE_DISABLE=1

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <output-var> [prefix] assigns a fresh temp dir to output-var
# and registers it for removal on EXIT. Assignment must happen in the calling
# shell: command substitution runs the function in a subshell and loses both
# the cleanup registration and its traps. The first call installs the cleanup
# traps. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call fm_test_cleanup from inside it so registered
# dirs are still removed.
#
# HUP, INT, and TERM are converted to explicit exits so the current EXIT trap
# runs on those interrupt paths. SIGKILL cannot be trapped by Bash, so a wrapper
# that escalates to SIGKILL can only be cleaned up if its earlier signal reaches
# this shell and is not deliberately ignored.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

# shellcheck disable=SC2317,SC2329 # Invoked by the signal traps below.
fm_test_signal_exit() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

fm_test_install_cleanup_traps() {
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
    trap 'fm_test_signal_exit 129' HUP
    trap 'fm_test_signal_exit 130' INT
    trap 'fm_test_signal_exit 143' TERM
  fi
}

fm_test_tmproot() {
  local output_var=${1:-} prefix=${2:-fm-test} root
  case "$output_var" in
    ''|[0-9]*|*[!a-zA-Z0-9_]*)
      printf 'fm_test_tmproot: first argument must be an output variable name\n' >&2
      return 2
      ;;
  esac
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") \
    || fail "could not create test temp root under ${TMPDIR:-/tmp}"
  fm_test_install_cleanup_traps
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf -v "$output_var" '%s' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# --- runtime capability probes -----------------------------------------------

# fm_node_supports_ts_import: true if this `node` can import a .ts file
# directly (native type-stripping, Node 22.6+ behind a flag or 23.6+ by
# default). Pi extension tests exec plugins by importing the tracked .ts
# source at runtime; on an older Node that support is simply absent, so those
# tests skip rather than fail, the same as this suite's other missing-tool
# skips (herdr, cmux, zellij, tsc). Cached per process since the probe spawns
# node.
FM_NODE_TS_IMPORT_OK=
fm_node_supports_ts_import() {
  if [ -z "$FM_NODE_TS_IMPORT_OK" ]; then
    local probe
    probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-node-ts-probe.XXXXXX")
    printf 'export default 1;\n' > "$probe/probe.ts"
    if PROBE_TS="$probe/probe.ts" node --input-type=module -e \
      'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.env.PROBE_TS).href);' \
      >/dev/null 2>&1; then
      FM_NODE_TS_IMPORT_OK=1
    else
      FM_NODE_TS_IMPORT_OK=0
    fi
    rm -rf "$probe"
  fi
  [ "$FM_NODE_TS_IMPORT_OK" = 1 ]
}
