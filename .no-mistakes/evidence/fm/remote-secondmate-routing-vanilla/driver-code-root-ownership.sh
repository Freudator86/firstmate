#!/usr/bin/env bash
# Manual driver: provision / sync / update a remote secondmate home from a
# Firstmate code root this host's agent account does not own.
# Usage: fm-ownership-drive.sh <code-root-checkout> <label>
set -u
ROOT=$(cd "$1" && pwd -P); LABEL=$2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-own-drive.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
CODE_ROOT="$TMP/shared-checkout"; HOME_DIR="$TMP/remote-home"; ORIGIN="$TMP/firstmate-origin.git"
OWNED="$TMP/owned.gitconfig"; ID=route
say() { printf '\n== %s\n' "$*"; }

mkdir -p "$CODE_ROOT/bin"
printf 'firstmate code root on the build host\n' > "$CODE_ROOT/AGENTS.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CODE_ROOT/bin/fm-fixture.sh"
chmod +x "$CODE_ROOT/bin/fm-fixture.sh"
printf 'projects/\nstate/\ndata/\nconfig/\n.fm-secondmate-home\n.fm-secondmate-parent\n' > "$CODE_ROOT/.gitignore"
git -C "$CODE_ROOT" init -q -b main
git -C "$CODE_ROOT" config user.email ops@example.com
git -C "$CODE_ROOT" config user.name Ops
git -C "$CODE_ROOT" add . && git -C "$CODE_ROOT" commit -qm 'code root'
git init -q --bare "$ORIGIN"
git -C "$CODE_ROOT" remote add origin "$ORIGIN"
git -C "$CODE_ROOT" push -q -u origin main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
# everything this agent account owns - the code root deliberately excluded
printf '[safe]\n\tdirectory = %s\n\tdirectory = %s\n\tdirectory = %s\n' "$HOME_DIR" "$HOME_DIR/.git" "$ORIGIN" > "$OWNED"
as_agent() { env GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL="$OWNED" "$@"; }

printf '### %s\n' "$LABEL"
printf 'code root under test: %s\n' "$ROOT"

say "what plain git does with that code root as this agent account (the real refusal)"
as_agent git clone --quiet -- "$CODE_ROOT" "$TMP/plain-clone" 2>&1 | head -3 || true

say "operator provisions the remote secondmate home on this host"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
  "$(printf '%s' "$ID" | base64 | tr -d '\n')" \
  "$(printf 'Own delivery on the build host.\n' | base64 | tr -d '\n')" \
  "$(printf '%s' remote-host | base64 | tr -d '\n')" > "$TMP/manifest"
if as_agent env FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$TMP/manifest" 2>&1; then
  printf 'home exists: %s (HEAD %s)\n' "$HOME_DIR" "$(as_agent git -C "$HOME_DIR" rev-parse --short HEAD)"
else
  printf 'PROVISIONING FAILED - no remote secondmate home can exist on this host\n'
  exit 0
fi

say "the parent's code root advances, and the operator syncs the mate to it"
printf 'second revision\n' >> "$CODE_ROOT/AGENTS.md"
git -C "$CODE_ROOT" commit -qam 'code root advance'
git -C "$CODE_ROOT" push -q origin main
as_agent env FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" sync "$ID" 2>&1 | head -3
printf 'home HEAD now: %s / code root HEAD: %s\n' \
  "$(as_agent git -C "$HOME_DIR" rev-parse --short HEAD)" "$(git -C "$CODE_ROOT" rev-parse --short HEAD)"

say "the operator runs the remote update leg (code root refresh, then mate follows)"
PUB="$TMP/publisher"; git clone --quiet -- "$ORIGIN" "$PUB"
git -C "$PUB" config user.email ops@example.com; git -C "$PUB" config user.name Ops
printf 'published revision\n' >> "$PUB/AGENTS.md"; git -C "$PUB" commit -qam 'origin advance'; git -C "$PUB" push -q origin main
as_agent env FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" update "$ID" 2>&1 | head -5
printf 'code root HEAD after update: %s (origin tip %s)\n' \
  "$(git -C "$CODE_ROOT" rev-parse --short HEAD)" "$(git -C "$PUB" rev-parse --short HEAD)"

say "afterwards the code root is still refused - no durable exception was left behind"
as_agent git -C "$CODE_ROOT" rev-parse HEAD 2>&1 | head -2
