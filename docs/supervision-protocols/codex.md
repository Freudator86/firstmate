Mode: Codex foreground wake checkpoint.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Run one foreground delivery checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
3. If the command prints `wake: queued`, drain and handle queued wakes, then start the next checkpoint.
4. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
5. Because the checkpoint blocks reasoning, make it the next tool call after wake handling and do not compose an idle reply before it.
6. Never use shell `&` or Codex background tasks for firstmate wake delivery.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal delivery command.
   If it is ever shelled as a repair probe, a backgrounded, piped, or bundled shape is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls only and send no chat text.
   Any no-change wake turn that sends chat text is a protocol violation, not politeness.

The external service owns the long-running watcher loop.
Each checkpoint runs only the lightweight queue delivery stub with a bounded foreground wait.
