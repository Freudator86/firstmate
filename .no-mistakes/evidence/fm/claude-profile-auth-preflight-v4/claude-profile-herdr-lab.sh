#!/usr/bin/env bash
# Live Herdr-lab validation of the named Claude profile preflight.
# Drives the real bin/fm-spawn.sh and bin/fm-control.sh against an isolated
# fm-lab-* Herdr session created through bin/fm-herdr-lab.sh. `claude auth
# status` / `claude --version` are answered by the REAL claude CLI, except a
# store listed in $LAB_AUTHED (a store we cannot log in without copying
# production credentials), which answers loggedIn:true. Any other claude
# invocation (the worker launch itself) prints the store it was given and
# sleeps, so the pane shows which account the worker would run on.
set -u
ROOT=${ROOT:?set ROOT to the worktree}
EVID=${EVID:?set EVID}
REAL_CLAUDE=$(command -v claude)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-profile-lab.XXXXXX")
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name claudeprof) || exit 1
export HERDR_SESSION=$SESSION
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
WORKTREES=()
CLEANED=0
RESULTS=()
cleanup() {
  [ "$CLEANED" = 0 ] || return 0; CLEANED=1
  local wt
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$LAB" teardown "$SESSION"; echo "teardown rc=$?"
  rm -rf "$TMP"
}
trap cleanup EXIT
"$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }
lab() { "$LAB" run "$SESSION" "$@"; }
LAB_SOCKET=$(lab session list --json | jq -r --arg s "$SESSION" '.sessions[] | select(.name==$s) | .socket_path')
echo "lab session=$SESSION"

res() { RESULTS+=("$1: $2"); echo "RESULT $1: $2"; }

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
AUTHLOG="$TMP/auth-calls.log"; : > "$AUTHLOG"
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "auth status")
    echo "auth-status CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR:-<unset>}" >> "$AUTHLOG"
    case " \${LAB_AUTHED:-} " in *" \${CLAUDE_CONFIG_DIR:-none} "*)
      printf '{"loggedIn": true, "authMethod": "claude.ai"}\n'; exit 0 ;; esac
    exec "$REAL_CLAUDE" "\$@" ;;
  "--version "*) exec "$REAL_CLAUDE" --version ;;
esac
echo "WORKER-CLAUDE running with CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR:-<unset>}"
printf '%s\n' '────────────────────────────────────────' '❯ ' '────────────────────────────────────────' '  ? for shortcuts'
while IFS= read -r line; do case "\$line" in */exit*) exit 0 ;; esac; done
exec sleep 600
SH
chmod +x "$FAKEBIN/claude"

PROJ="$TMP/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo '# scratch' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

H="$TMP/home"; mkdir -p "$H/state" "$H/config" "$H/data"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
FAKE_HOME="$TMP/userhome"; mkdir -p "$FAKE_HOME"
AMBIENT="$TMP/ambient-store"; mkdir -p "$AMBIENT"
POOL_A="$TMP/pool-a"; POOL_EMPTY="$TMP/pool-empty"; mkdir -p "$POOL_A" "$POOL_EMPTY"
printf '{"hasCompletedOnboarding":true}\n' > "$POOL_A/.claude.json"
printf '{"hasCompletedOnboarding":true}\n' > "$POOL_EMPTY/.claude.json"
cat > "$H/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$POOL_A"},{"id":"claude-max-empty","config_dir":"$POOL_EMPTY"}]}
EOF

brief() { mkdir -p "$H/data/$1"; printf '# Task\n## Captain'"'"'s intent\nlab %s\n\n## Firstmate spec\nnothing\n' "$1" > "$H/data/$1/brief.md"; }

spawn() { # <id> [args...]
  local id=$1; shift; brief "$id"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$AMBIENT" LAB_AUTHED="$POOL_A" \
    HERDR_SESSION="$SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" claude --mode local-only --yolo on --backend herdr "$@"
}
pane_of() { grep 2>/dev/null '^herdr_pane_id=' "$H/state/$1.meta" | cut -d= -f2-; }
screen() { lab pane read "$(pane_of "$1")" --source recent --lines 200 2>/dev/null; }
track() { local wt; wt=$(grep '^worktree=' "$H/state/$1.meta" 2>/dev/null | cut -d= -f2-); [ -z "$wt" ] || WORKTREES+=("$wt"); }
claude_procs() { # prints "pid CLAUDE_CONFIG_DIR" for live claude processes under the lab tmp
  local d pid cfg
  for d in /proc/[0-9]*; do pid=${d#/proc/}
    tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'claude' || continue
    cfg=$(tr '\0' '\n' < "$d/environ" 2>/dev/null | grep '^CLAUDE_CONFIG_DIR=' | head -1)
    case "$cfg" in *"$TMP"*) echo "$pid $cfg | $(tr '\0' ' ' < "$d/cmdline" | cut -c1-60)";; esac
  done
}
has_proc() { local i; for i in $(seq 1 30); do claude_procs | grep -q "CLAUDE_CONFIG_DIR=$1 " && return 0; sleep 1; done; return 1; }
wait_screen() { local i; for i in $(seq 1 30); do screen "$1" | grep -q "$2" && return 0; sleep 1; done; return 1; }

echo; echo "=== S1 default (no --claude-profile): ambient store kept, no preflight ==="
: > "$AUTHLOG"
spawn deflt-a1 > "$TMP/s1.out" 2>&1; rc=$?; track deflt-a1
cat "$TMP/s1.out" | tail -5; echo "spawn rc=$rc"
echo "--- meta ---"; grep -E '^(harness|claude_profile|herdr_pane_id)=' "$H/state/deflt-a1.meta"
has_proc "$AMBIENT"; echo "--- live claude processes (pid, env CLAUDE_CONFIG_DIR, argv) ---"; claude_procs
sleep 3; echo "--- pane screen (real claude in lab pane) ---"; screen deflt-a1 | grep -v '^\s*$' | head -12
echo "--- auth status calls ---"; cat "$AUTHLOG"
if [ $rc = 0 ] && claude_procs | grep -q "CLAUDE_CONFIG_DIR=$AMBIENT " && [ ! -s "$AUTHLOG" ] && ! grep -q '^claude_profile=' "$H/state/deflt-a1.meta"; then res S1 pass; else res S1 fail; fi

echo; echo "=== S2 named pool logged in + onboarded: worker pinned to pool store ==="
: > "$AUTHLOG"
spawn pool-a2 --claude-profile claude-max-a > "$TMP/s2.out" 2>&1; rc=$?; track pool-a2
tail -5 "$TMP/s2.out"; echo "spawn rc=$rc"
echo "--- meta ---"; grep -E '^(harness|claude_profile|herdr_pane_id)=' "$H/state/pool-a2.meta"
has_proc "$POOL_A"; echo "--- live claude processes (pid, env CLAUDE_CONFIG_DIR, argv) ---"; claude_procs
echo "--- auth status calls ---"; cat "$AUTHLOG"
echo "--- trust written to pool store ---"; jq -c '.projects | keys' "$POOL_A/.claude.json" 2>&1 | head -c 400; echo
if [ $rc = 0 ] && claude_procs | grep -q "CLAUDE_CONFIG_DIR=$POOL_A " && grep -q '^claude_profile=claude-max-a$' "$H/state/pool-a2.meta"; then res S2 pass; else res S2 fail; fi

echo; echo "=== S3 named pool NOT logged in (real claude on empty store): refused before launch ==="
before=$(lab pane list 2>/dev/null | jq '[.result.panes[]?] | length')
spawn empty-a3 --claude-profile claude-max-empty > "$TMP/s3.out" 2>&1; rc=$?
cat "$TMP/s3.out" | tail -3; echo "spawn rc=$rc"
after=$(lab pane list 2>/dev/null | jq '[.result.panes[]?] | length')
echo "lab panes before=$before after=$after; meta present: $([ -e "$H/state/empty-a3.meta" ] && echo yes || echo no)"
if [ $rc != 0 ] && grep -q 'unauthenticated:vendor-probe' "$TMP/s3.out" && [ ! -e "$H/state/empty-a3.meta" ] && [ "$before" = "$after" ]; then res S3 pass; else res S3 fail; fi

echo; echo "=== S4 unconfigured pool / non-claude harness / raw CLAUDE_CONFIG_DIR: refused ==="
spawn nope-a4 --claude-profile claude-max-zzz > "$TMP/s4a.out" 2>&1; rc1=$?; tail -1 "$TMP/s4a.out"
brief nope-b4
env -u HERDR_PANE_ID -u HERDR_ENV PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" nope-b4 "$PROJ" "sh -c 'echo hi; sleep 60'" --mode local-only --yolo on --backend herdr --claude-profile claude-max-a > "$TMP/s4b.out" 2>&1; rc2=$?; tail -1 "$TMP/s4b.out"
brief nope-c4
env -u HERDR_PANE_ID -u HERDR_ENV PATH="$FAKEBIN:$PATH" LAB_AUTHED="$POOL_A" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" nope-c4 "$PROJ" "CLAUDE_CONFIG_DIR=/tmp/other claude" --mode local-only --yolo on --backend herdr --claude-profile claude-max-a > "$TMP/s4c.out" 2>&1; rc3=$?; tail -1 "$TMP/s4c.out"
echo "rcs=$rc1 $rc2 $rc3; metas: $(ls "$H/state" | grep -c '^nope-' || true)"
if [ $rc1 != 0 ] && [ $rc2 != 0 ] && [ $rc3 != 0 ] && grep -q 'not configured in this home' "$TMP/s4a.out" && grep -q 'names a Claude capacity pool' "$TMP/s4b.out" && grep -q 'sets CLAUDE_CONFIG_DIR itself' "$TMP/s4c.out" && ! ls "$H/state" | grep -q '^nope-.*\.meta$'; then res S4 pass; else res S4 fail; fi

ctl() { env -u HERDR_PANE_ID -u HERDR_ENV PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$AMBIENT" LAB_AUTHED="${1}" HERDR_SESSION="$SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-control.sh" pool-a2 relaunch --note "herdr lab relaunch"; }
echo; echo "=== S6 relaunch when the recorded pool is logged out: refused before stopping the agent ==="
pane=$(pane_of pool-a2)
ctl "" > "$TMP/s6.out" 2>&1; rc=$?; tail -3 "$TMP/s6.out"; echo "relaunch rc=$rc"
echo "pane still=$(pane_of pool-a2) (was $pane)"; echo "--- live claude processes after refusal ---"; claude_procs
echo "--- journal ---"; ls "$H/state" | grep -i relaunch || echo "(no relaunch journal written)"
if [ $rc != 0 ] && grep -q 'not ready for the replacement worker' "$TMP/s6.out" && [ "$(pane_of pool-a2)" = "$pane" ] && claude_procs | grep -q "CLAUDE_CONFIG_DIR=$POOL_A "; then res S6 pass; else res S6 fail; fi

echo; echo "=== summary ==="; printf '%s\n' "${RESULTS[@]}"
for id in deflt-a1 pool-a2; do
  env HERDR_SESSION="$SESSION" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 || true
done
