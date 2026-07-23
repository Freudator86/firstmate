Mode: Claude background-notify wake delivery.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
3. Never bundle the arm command with other commands.
4. Never use shell `&` for wake delivery.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
5. Treat `watcher: started ...` and `watcher: attached ...` as proof that the watcher service is healthy and this session's delivery stub is armed.
6. Treat `watcher: FAILED ...` as an alarm and follow its daemon or delivery repair before ending the turn.
7. When the background task completes with `wake: queued`, drain queued wakes, handle them, then start exactly one fresh background task before composing any reply or beginning long work.
8. If a forced watcher-loop restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
9. Do not send idle progress while the delivery stub is waiting.
10. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls only and send no chat text.
    Any no-change wake turn that sends chat text is a protocol violation, not politeness.

Claude Code's background task completion delivers the wake to the model.
The external service owns `bin/fm-watch.sh`; the background task owns only `bin/fm-wake-wait.sh` through the verified `bin/fm-watch-arm.sh` wrapper.
Killing that background task loses no queued wake and requires only one re-arm.
