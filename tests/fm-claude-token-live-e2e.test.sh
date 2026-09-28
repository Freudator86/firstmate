#!/usr/bin/env bash
# Opt-in live effect/onboarding guard for named Claude setup-token pools.
# FM_CLAUDE_TOKEN_LIVE_CONFIG names an existing claude-profiles.json whose
# profiles all use setup_token_file. Only file paths are reused; every store,
# HOME, and working directory is fresh scratch. No token value is copied or
# printed. Submits a bounded auth prompt and an interactive worker prompt per
# pool. The latter uses the already-selected bypass mode's launch-local consent.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_TOKEN_LIVE_E2E claude python3 node perl jq
[ -n "${FM_CLAUDE_TOKEN_LIVE_CONFIG:-}" ] || fail 'FM_CLAUDE_TOKEN_LIVE_CONFIG must name a token-profile configuration'
TMP_ROOT=$(fm_test_tmproot fm-claude-token-live)
python3 - "$ROOT" "$TMP_ROOT" "$FM_CLAUDE_TOKEN_LIVE_CONFIG" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

root, scratch, source = map(Path, sys.argv[1:])
auth = root / 'bin/fm-claude-auth.sh'
version = subprocess.check_output(['claude', '--version'], text=True).strip()
profiles = json.loads(source.read_text())['profiles']
assert profiles, 'live guard cannot pass without profiles'
config = scratch / 'config'
config.mkdir()
home = scratch / 'home'
home.mkdir()
items = []
for index, profile in enumerate(profiles):
    assert profile.get('setup_token_file'), 'live guard requires token-backed profiles'
    store = scratch / f'store-{index}'
    store.mkdir()
    items.append(dict(id=f'pool-{index}', config_dir=str(store),
                      setup_token_file=profile['setup_token_file']))
(config / 'claude-profiles.json').write_text(json.dumps(dict(profiles=items)))
env = dict(HOME=str(home), PATH=os.environ['PATH'], TERM='xterm-256color',
           FM_CONFIG_OVERRIDE=str(config), FM_ROOT_OVERRIDE=str(root),
           ANTHROPIC_API_KEY='synthetic-wrong-ambient-key',
           CLAUDE_CODE_OAUTH_TOKEN='synthetic-wrong-ambient-token')
for index, profile in enumerate(items):
    result = subprocess.run([str(auth), 'check', '--profile', profile['id']],
                            env=env, capture_output=True, timeout=110)
    assert result.returncode == 0, f'{version}: pool {index} failed the real auth effect check (output suppressed)'
    store = Path(profile['config_dir'])
    work = scratch / f'work-{index}'
    work.mkdir()
    pref = store / '.claude.json'
    data = json.loads(pref.read_text())
    assert data['hasCompletedOnboarding'] is True, f'{version}: onboarding was not prepared'
    # Trust only this empty scratch directory, as fm-claude-trust does for an
    # authorized real worktree. No external-import or global consent is copied.
    data['projects'] = {str(work): dict(hasTrustDialogAccepted=True)}
    pref.write_text(json.dumps(data))
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    command = [str(auth), 'run', '--profile', profile['id'], '--', 'claude',
               '--dangerously-skip-permissions', '--model', 'haiku', '--tools', '',
               '--setting-sources', 'project,local', '--strict-mcp-config',
               '--mcp-config', '{"mcpServers":{}}', '--settings',
               '{"feedbackDrafts":"off","skipDangerousModePermissionPrompt":true}',
               '--system-prompt', 'Answer only the test question.',
               'Write the concatenation of TOKEN, underscore and READY only.']
    child = subprocess.Popen(command, cwd=work, env=env, stdin=slave,
                             stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = b''
    deadline = time.monotonic() + 90
    try:
        while time.monotonic() < deadline and child.poll() is None:
            ready, _, _ = select.select([master], [], [], 1)
            if ready:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break
            if b'TOKEN_READY' in output:
                break
        assert b'TOKEN_READY' in output, f'{version}: pool {index} did not reach an unattended interactive model response (output suppressed)'
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        os.close(master)
    print(f'ok - {version}: pool {index} real token effect and fresh-store interactive bypass response')
print(f'# live token guard checked {len(items)} pools')
PY
