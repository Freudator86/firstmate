#!/usr/bin/env python3
"""Start interactive claude in a 40x120 pty against a scratch CLAUDE_CONFIG_DIR,
read the first screen for a few seconds, then kill it. Sends no keys."""
import os, pty, sys, time, select, fcntl, termios, struct, signal, re
store, cwd = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
env.update(CLAUDE_CONFIG_DIR=store, TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvpe("claude", ["claude"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
os.kill(pid, signal.SIGWINCH)
buf = b""; end = time.time() + 12
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try: buf += os.read(fd, 65536)
        except OSError: break
os.kill(pid, signal.SIGKILL)
text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]", b" ", buf).decode("utf-8", "replace")
text = re.sub(r"[ \t]+", " ", text)
print("\n".join(l for l in text.splitlines() if l.strip())[-3000:])
