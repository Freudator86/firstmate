#!/usr/bin/env bash
# Manual end-to-end driver: does a remote secondmate get told to read the same
# steering inbox the parent actually delivers into?
#
# Usage: fm-steer-drive.sh <code-root-checkout> <label>
# Stands up a parent home and a simulated remote host (fake ssh that runs the
# real remote entrypoint, the suite's stateful herdr CLI fixture as the remote
# backend), then drives the operator's own commands:
#   fm-remote-home-seed.sh  -> provision + seed the remote home
#   fm-spawn.sh --secondmate -> launch the mate on that host
#   fm-send.sh fm-<id>      -> route a captain request to it
# and finally follows the launched agent's own instructions to fetch the request.
set -u
ROOT=$(cd "$1" && pwd -P); LABEL=$2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-steer-drive.XXXXXX")
PARENT="$TMP/parent"; REMOTE_ROOT="$TMP/remote-root"; REMOTE_HOME="$TMP/remote-home"
FAKEBIN="$TMP/fakebin"; HERDR_LOG="$TMP/remote-herdr.log"; HERDR_STATE="$TMP/remote-herdr.state"
ID=ios
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$FAKEBIN" "$TMP/claims"
chmod 700 "$TMP" "$PARENT" "$PARENT/state" "$TMP/claims"
cleanup() { [ "${FM_KEEP:-0}" = 1 ] || rm -rf -- "$TMP"; [ -z "${STAGED_DIR:-}" ] || rm -rf -- "$STAGED_DIR"; }
trap cleanup EXIT

say() { printf '\n== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }

# --- the remote host's own Firstmate code root -------------------------------
( cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - . ) \
  | ( cd "$REMOTE_ROOT" && tar -xf - )
# shellcheck source=/dev/null
. "$ROOT/tests/remote-herdr-fixture.sh"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" "$TMP/herdr-send-fail" "$TMP/herdr.sock"
cat > "$REMOTE_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote host code root'
git init -q --bare "$TMP/firstmate-origin.git"
git -C "$REMOTE_ROOT" remote add origin "file://$TMP/firstmate-origin.git"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$TMP/firstmate-origin.git" symbolic-ref HEAD refs/heads/main

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"

# --- the SSH boundary: runs the real remote entrypoint on this machine -------
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
host=$1; entry=$2; shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
name=$(perl -MMIME::Base64=decode_base64 -e 'my @a=split(/\0/,decode_base64($ARGV[0])); print $a[0];' "$argv_b64")
if [ "$name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\nok: remote second-mate readiness confirmed on this host\n'; exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_PROCEVENT_CLAIM_ROOT="$TMP/claims" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 "$@"
}

printf '### %s\n' "$LABEL"
printf 'code root under test: %s (%s)\n' "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo detached)"
printf 'parent home: %s\nremote home (other host): %s\n' "$PARENT" "$REMOTE_HOME"

say "captain seeds a remote secondmate onto the build host"
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$ID" remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects \
  || { echo "SEED FAILED"; exit 1; }

say "the steering inbox the seeded charter tells the mate to read"
grep -n "$ID\.inbox" "$REMOTE_HOME/data/charter.md" | sed -n '1,4p'

if [ "${FM_STALE_CHARTER:-0}" = 1 ]; then
  say "ADVERSARIAL: this home was seeded by the OLD code, so its standing charter still names the parent's own inbox"
  sed -i "s|$REMOTE_HOME/state/parent-route/$ID.inbox|$PARENT/state/$ID.inbox|g" "$REMOTE_HOME/data/charter.md"
  grep -n "$ID\.inbox" "$REMOTE_HOME/data/charter.md" | sed -n '1p'
fi

case "${FM_ROUTE_TAMPER:-}" in
  local) say "ADVERSARIAL: the home's durable parent record is tampered to route=local"
    sed -i 's/^route=remote$/route=local/' "$REMOTE_HOME/.fm-secondmate-parent"; cat "$REMOTE_HOME/.fm-secondmate-parent" ;;
  corrupt) say "ADVERSARIAL: the home's durable parent record is corrupt"
    printf 'not-a-record\x00\n' > "$REMOTE_HOME/.fm-secondmate-parent"; cat -v "$REMOTE_HOME/.fm-secondmate-parent" ;;
  absent) say "ADVERSARIAL: the home has no durable parent record at all"
    rm -f "$REMOTE_HOME/.fm-secondmate-parent"; ls "$REMOTE_HOME/.fm-secondmate-parent" 2>&1 ;;
esac

say "captain launches the mate on that host"
remote_env "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate || { echo "SPAWN FAILED"; exit 1; }

say "the command the remote agent pane was actually launched with"
STAGED=$(grep -m1 'pane send-text .* \. ' "$HERDR_LOG" | grep -o "'/[^']*launch\.[^']*\.sh'" | tr -d "'")
if [ -n "${STAGED:-}" ] && [ -f "$STAGED" ]; then
  fold -w 160 "$STAGED"
  STAGED_DIR=$(dirname "$STAGED")
else
  echo "(no staged launch script found in the pane log)"
fi

DELIVERED=$(grep -o "[^']*/launch-brief\.md" <<<"$(cat "${STAGED:-/dev/null}" 2>/dev/null)" | head -1)
if [ -z "${DELIVERED:-}" ]; then
  DELIVERED=$(grep -o "[^']*/charter\.md" <<<"$(cat "${STAGED:-/dev/null}" 2>/dev/null)" | head -1)
fi
say "the prompt file that launch command feeds the agent: ${DELIVERED:-<none>}"
[ -n "${DELIVERED:-}" ] && [ -f "$DELIVERED" ] && sed -n '1,4p' "$DELIVERED"

TOLD=$(grep -o "[^ ']*$ID\.inbox" "${DELIVERED:-/dev/null}" 2>/dev/null | head -1)
say "inbox path the launched agent is told to read: ${TOLD:-<none found>}"

say "captain routes a request to the mate"
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" 'Run the alpha smoke check and report the result.' || echo "(send reported non-zero)"

say "the doorbell the mate's pane received"
grep -o 'Firstmate instruction waiting[^"]*' "$HERDR_LOG" | tail -1

say "where the durable record actually landed"
find "$REMOTE_HOME/state" "$PARENT/state" -name '*.msg' -path "*$ID.inbox*" 2>/dev/null

say "launch overlay files present in the remote home"
find "$REMOTE_HOME/data" -name 'launch-brief.md' 2>/dev/null | sed 's/^/  /' ; [ -n "$(find "$REMOTE_HOME/data" -name 'launch-brief.md' 2>/dev/null)" ] || echo "  (none - the standing charter was delivered unchanged)"

say "the mate now follows its launch instructions literally"
if [ -n "${TOLD:-}" ] && [ -d "$TOLD" ] && ls "$TOLD"/*.msg >/dev/null 2>&1; then
  for msg in "$TOLD"/*.msg; do
    printf 'read %s:\n' "$msg"; sed -n '1,8p' "$msg"
    mkdir -p "$TOLD/handled" && mv "$msg" "$TOLD/handled/" && printf 'acknowledged -> %s/handled/%s\n' "$TOLD" "$(basename "$msg")"
  done
  printf '\nRESULT: the mate found and acknowledged the captain request at the path it was told to read.\n'
else
  printf 'ls %s ->\n' "${TOLD:-<none>}"; ls -la "${TOLD:-/nonexistent}" 2>&1 | head -3
  printf '\nRESULT: the mate was pointed at %s, which holds no request; the delivered record is elsewhere.\n' "${TOLD:-<none>}"
fi
