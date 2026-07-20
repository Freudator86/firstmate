Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. If the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
   Because the checkpoint blocks reasoning, make it the next tool call after wake handling and do not compose an idle reply before it.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, including a review-ready PR, findings, a needed decision, a real blocker or failure, or a needed credential, end the turn with tool calls only and send no chat text.
   Any no-change wake turn that sends chat text is a protocol violation, not politeness.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
