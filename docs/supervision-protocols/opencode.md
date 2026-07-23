Mode: OpenCode TUI plugin wake delivery.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Let `.opencode/plugins/fm-primary-watch-arm.js` arm delivery after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns and awaits `bin/fm-watch-arm.sh`, and calls `client.session.promptAsync` when the delivery stub exits with `wake: queued` or a failure.
4. `watcher: started ...` or `watcher: attached ...` means the external watcher service is healthy and the plugin's delivery wait is armed.
5. If the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
6. Never use shell `&` for wake delivery.
   The arm mechanism above is plugin-owned, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
7. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.
8. On a plugin wake, drain and handle queued wakes without composing an idle reply.
   The plugin re-arms after the session goes idle again.
9. If nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls only and send no chat text.
   Any no-change wake turn that sends chat text is a protocol violation, not politeness.

The service owns the long-running watcher loop.
The plugin owns only one lightweight, safely killable delivery wait.
