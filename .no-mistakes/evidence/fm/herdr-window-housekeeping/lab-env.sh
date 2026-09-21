# Shared env for the live housekeeping lab driver (sourced).
ROOT=/home/quartermaster/.no-mistakes/worktrees/d629afe4b711/01M30W3TX52G0HT7KG668T1CNS
EV=/home/quartermaster/.no-mistakes/evidence/01M30W3TX52G0HT7KG668T1CNS
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1
S=$(cat $EV/lab-session.txt)
W=/tmp/fm-housekeep-live
H=$W/home
FAKEBIN=$W/fakebin
ORIG_PATH=${ORIG_PATH:-$PATH}
export HERDR_LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh HERDR_LAB_SESSION=$S HERDR_ORIGINAL_PATH=$ORIG_PATH
lab() { env PATH="$ORIG_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
fmenv() { env PATH="$FAKEBIN:$ORIG_PATH" FM_ROOT_OVERRIDE="$W/root" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$@"; }
scan() { fmenv "$ROOT/bin/fm-inactive-reconcile.sh" scan "$@"; }
crewstate() { fmenv FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$1"; }
agestamp() { touch -d "@$(( $(date +%s) - $1 ))" "${@:2}"; }
pane_exists() { lab pane get "$1" >/dev/null 2>&1; }
mktask() { # <id> <status-line> <age-secs> [extra meta...]
  local id=$1 status=$2 agesecs=$3 tab pane; shift 3
  tab=$(lab tab create --workspace "$WS" --cwd "$W/project" --label "fm-$id" --no-focus)
  pane=$(printf '%s' "$tab" | jq -r '.result.root_pane.pane_id // .result.pane.pane_id')
  mkdir -p "$H/projects/$id"
  git -C "$H/projects/$id" init -q -b "fm/$id" && git -C "$H/projects/$id" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unlanded work for $id"
  { printf 'window=%s:%s\nendpoint_task_id=%s\nbackend=herdr\nworktree=%s\nproject=alpha\nharness=pi\nkind=ship\nspawn_gen=g-%s\n' "$S" "$pane" "$id" "$H/projects/$id" "$id"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$H/state/$id.meta"
  printf '%s\n' "$status" > "$H/state/$id.status"; : > "$H/state/$id.turn-ended"
  agestamp "$agesecs" "$H/state/$id.meta" "$H/state/$id.status" "$H/state/$id.turn-ended"
  echo "$id=$pane" >> "$W/panes"
}
paneof() { sed -n "s/^$1=//p" "$W/panes"; }
turnend() { # <id>: what spawn + a Pi crew's agent_end hook leave behind
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$H/state" "$1")
  "$ROOT/bin/fm-busy-event.sh" apply "$H/state" "$1" idle --gen "$gen" --source pi-ext --event agent-end >/dev/null
}
snapshot() { # <label>
  echo "== $1 =="
  for id in done-dead failed-offline working-dead decision fresh-done busy-running mate live-agent late-done; do
    p=$(paneof $id); [ -n "$p" ] || continue
    printf '%-15s pane=%-6s %-7s meta=%s worktree_head=%s\n' $id $p "$(pane_exists $p && echo OPEN || echo CLOSED)" \
      "$([ -f $H/state/$id.meta ] && echo kept || echo GONE)" "$(git -C $H/projects/$id log -1 --format=%s 2>/dev/null || echo GONE)"
  done
  echo "outcome records: $(ls $H/state/terminal-outcomes 2>/dev/null | sed 's/^[0-9a-f]\{12\}[0-9a-f]*\./*./' | sort | uniq -c | tr '\n' ' ')"
  echo "housekeeping marker: $(cat $H/state/.finished-window-housekeeping 2>/dev/null || echo none)"
}
