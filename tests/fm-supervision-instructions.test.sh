#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-supervision-instructions

RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground wake checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude background-notify supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension wake delivery." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: Codex foreground wake checkpoint.' "codex snippet missing"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "Claude Code background task" "claude repair line missing background-task mechanism"
  assert_contains "$out" "end this forced continuation silently" "claude repair line omitted silent maintenance handling"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_not_contains "$out" "source '$home/config/x-mode.env' first" "x-mode delivery repair still sourced daemon-owned cadence"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify wake delivery." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  assert_contains "$out" "end this forced continuation silently" "grok repair line omitted silent maintenance handling"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_no_change_wakes_are_explicitly_silent() {
  local harness out
  for harness in claude codex grok opencode pi; do
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "tool calls only and send no chat text" "$harness snippet omitted tool-only no-change turns"
    assert_contains "$out" "protocol violation, not politeness" "$harness snippet did not make no-change chat a violation"
  done
  pass "every supported harness makes no-change wake turns explicitly silent"
}

test_re_arm_before_reply_ordering() {
  local out

  out=$("$RENDER" --harness claude)
  assert_contains "$out" "start exactly one fresh background task before composing any reply or beginning long work" \
    "claude snippet lost the re-arm-before-reply ordering"

  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Re-arm exactly one delivery wait with the same background \`bin/fm-watch-arm.sh\` call before composing any reply or beginning long work" \
    "grok snippet lost the re-arm-before-reply ordering"

  out=$("$RENDER" --harness codex)
  assert_contains "$out" "make it the next tool call after wake handling and do not compose an idle reply before it" \
    "codex snippet lost the checkpoint-next-tool-call ordering"

  out=$("$RENDER" --harness pi)
  assert_contains "$out" "call \`fm_watch_arm_pi\` before composing a reply or beginning long work" \
    "pi snippet lost the re-arm-before-reply ordering"

  out=$("$RENDER" --harness opencode)
  assert_contains "$out" "drain and handle queued wakes without composing an idle reply" \
    "opencode snippet lost the no-idle-reply-before-rearm ordering"

  pass "each harness re-arms or checkpoints before composing a reply, using its own mechanism's shape"
}

test_agents_md_resume_protocol_ordering() {
  local agents
  agents=$(cat "$ROOT/AGENTS.md")
  assert_contains "$agents" "After every actionable wake, resume the emitted protocol at the earliest harness-safe point before composing any reply or beginning unrelated long work." \
    "AGENTS.md dropped the re-arm-before-reply resume-protocol line"
  assert_contains "$agents" "Background-notify harnesses re-arm immediately after draining, while a blocking foreground checkpoint follows wake handling as its next tool call." \
    "AGENTS.md dropped the background-notify vs foreground-checkpoint re-arm distinction"
  pass "AGENTS.md states the re-arm-before-reply ordering for both harness mechanisms"
}

test_grok_command_leaves_cadence_to_service() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "exec bin/fm-watch-arm.sh" "grok arm command lost the delivery wrapper"
  assert_not_contains "$out" "source '$config/x-mode.env'" "grok delivery command still sources the service-owned x-mode config"
  pass "grok rendered command leaves x-mode cadence to the watcher service"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_repair_lines
test_grok_is_background_notify
test_no_change_wakes_are_explicitly_silent
test_re_arm_before_reply_ordering
test_agents_md_resume_protocol_ordering
test_grok_command_leaves_cadence_to_service
test_pi_snippet_uses_effective_extension_path
