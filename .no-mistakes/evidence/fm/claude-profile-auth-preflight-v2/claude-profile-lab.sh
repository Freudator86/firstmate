#!/usr/bin/env bash
# Live lab driver: Claude profile auth preflight against the real claude CLI and
# a throwaway Herdr lab session. No real credentials are copied or written.
set -u
ROOT=$1
cd "$ROOT"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP=$(mktemp -d "$(cd /tmp && pwd -P)/fm-claude-prof-lab.XXXXXX")
SESSION=$(bin/fm-herdr-lab.sh name claudeprof)
export HERDR_SESSION="$SESSION"
cleanup() { herdr_safe_stop_and_delete "$SESSION"; rm -rf "$TMP"; }
trap cleanup EXIT
echo "## lab session: $SESSION"
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }
bin/fm-herdr-lab.sh provision "$SESSION" >/dev/null 2>&1 || true

HOME_FM="$TMP/fm-home"; mkdir -p "$HOME_FM"/{state,data,config,projects}
printf 'off\n' > "$HOME_FM/config/herdr-presentation-spaces"
POOL_B="$TMP/stores/claude-max-b"; mkdir -p "$POOL_B"      # empty store: never logged in
TOKEN="$TMP/secrets/claude-max-b.token"; mkdir -p "$(dirname "$TOKEN")"; printf 'placeholder-not-a-token\n' > "$TOKEN"
cat > "$HOME_FM/config/claude-profiles.json" <<J
{"profiles":[{"id":"claude-max-b","config_dir":"$POOL_B"},{"id":"claude-max-c","config_dir":"$TMP/stores/claude-max-c","setup_token_file":"$TOKEN"}]}
J
mkdir -p "$TMP/stores/claude-max-c"
for id in cm1 cm2 cm3 cm4 cm5 ba bb; do
  mkdir -p "$HOME_FM/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nlab %s\n\n## Firstmate spec\nlab\n' "$id" > "$HOME_FM/data/$id/brief.md"
done
PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo x > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

CLAUDE_BIN=$(command -v claude); echo "claude: $CLAUDE_BIN ($(claude --version))"
USERHOME="$TMP/user-home"; mkdir -p "$USERHOME"   # throwaway HOME so trust writes can never reach ~/.claude.json
run() { env -u CLAUDE_CONFIG_DIR HOME="$USERHOME" FM_HOME="$HOME_FM" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$@"; }
snapshot() { bin/fm-herdr-lab.sh run "$SESSION" pane list 2>/dev/null | jq -c '[.. | objects | select(has("pane_id")) | .pane_id] | length' 2>/dev/null || echo '?'; }

echo; echo "## S1 default profile on the operator's real ambient store (read-only claude auth status)"
env -u CLAUDE_CONFIG_DIR FM_HOME="$HOME_FM" bin/fm-claude-auth.sh check --profile default; echo "exit=$?"

echo; echo "## S2 named pool whose store was never logged in (real claude auth status)"
run bin/fm-claude-auth.sh check --profile claude-max-b; echo "exit=$?"
echo; echo "## S2b pool with setup-token material on the credential path"
run bin/fm-claude-auth.sh check --profile claude-max-c; echo "exit=$?"
echo; echo "## evidence rows (what routing consumes)"
run bin/fm-claude-auth.sh evidence

echo; echo "panes before spawns: $(snapshot)"
spawn_case() { # <label> <id> args...
  local label=$1 id=$2; shift 2
  echo; echo "## $label"
  echo "+ fm-spawn.sh $id <proj> $*"
  run bin/fm-spawn.sh "$id" "$PROJ" "$@" --mode local-only --yolo off --backend herdr 2>&1 | sed "s#$TMP#<lab>#g"
  echo "exit=${PIPESTATUS[0]}"
  echo "meta written: $([ -e "$HOME_FM/state/$id.meta" ] && echo yes || echo no); panes now: $(snapshot)"
}
spawn_case "S3 spawn claude worker on unauthenticated pool" cm1 --harness claude --claude-profile claude-max-b
spawn_case "S4 spawn claude worker, default profile, logged-out ambient HOME" cm2 --harness claude
spawn_case "S5 adversarial: raw claude command re-scoping CLAUDE_CONFIG_DIR" cm3 "CLAUDE_CONFIG_DIR=$USERHOME/.claude claude"
spawn_case "S6 adversarial: --claude-profile on a non-claude harness" cm4 --harness codex --claude-profile claude-max-b
spawn_case "S7 adversarial: unconfigured profile id" cm5 --harness claude --claude-profile claude-max-z
echo; echo "## S8 batch spawn forwards --claude-profile to every pair"
run bin/fm-spawn.sh ba="$PROJ" bb="$PROJ" --harness claude --claude-profile claude-max-b --mode local-only --yolo off --backend herdr 2>&1 | sed "s#$TMP#<lab>#g"
echo "exit=${PIPESTATUS[0]}"
echo "metas: $(ls "$HOME_FM/state" | grep -c '\.meta$'); panes now: $(snapshot)"
echo "treehouse worktrees created under lab project: $(git -C "$PROJ" worktree list | wc -l) (1 = main only)"
