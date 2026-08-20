---
name: vessel-file-relay
description: >-
  Agent-only procedure for moving a file from the captain's own machine onto a fleet vessel's host and telling that vessel about it.
  Use whenever the captain hands over a local file path and asks that it be sent to, or made available to, a vessel, and whenever a secret or credential has to move from his machine into a vessel's host-scoped store.
  Covers the plain-document push, the stricter secret staging and structural verification, the Bridge notice that goes with each, and the Auto Mode classifier refusal that blocks the secret step.
user-invocable: false
metadata:
  internal: true
---

# vessel-file-relay

Bridge carries markdown and JSON, and it cannot carry a file's bytes.
So a file never travels through Bridge.
It is pushed directly onto the target vessel's own host over SSH, verified there, and then described to that vessel in a Bridge notice.
Those are two separate acts, and the notice is only ever a description of something that already landed.

A plain document and a secret are not the same job.
The document procedure is section 1.
A secret or credential uses section 2 instead, which is stricter in every step and does not inherit section 1's shortcuts.
`AGENTS.md` section 1 "Secrets" and the `secrets-handling` skill are the standing invariant over all of this, and nothing here relaxes either.

## 1. Plain documents

**Push over SSH, never through Bridge.**
Use `scp` or `sftp` from the local path to the target vessel's host, reached through the SSH config entries already set up for known vessels such as `hlr` and `tugboat`.
In a WSL session the captain's own files live on his Windows machine, so the local path is typically under `/mnt/c/...`.

**Find the destination convention before inventing one.**
Look on the target host for a directory that already holds this class of file.
A relay on 2026-08-20 found `/opt/docs/` already present on `hlr-web-1` and reused it, rather than creating a second place documents live.
If no convention is visible, ask the target vessel over Bridge where it wants the file.
Guessing a path is not a neutral default: it creates a second source of truth that nobody later knows to look in.

**Verify by size, not by exit status.**
Compare the byte size of the local file against the remote copy with `ls -la` on both sides.
A clean `scp` exit status is not evidence the right bytes arrived, and a truncated or wrong-source copy exits clean.

**Then notify over Bridge.**
Send `kind: status`, or `kind: reply` if this answers a request that vessel made.
Name the exact filename, its size, and the exact path it landed at.
Never attach or embed the file's bytes in the envelope.

**A direct push supersedes a pending question about where to send it.**
If the recipient was asked where to put something, and the captain then says to push it directly instead of waiting, that answer is moot.
Push it and tell them where it landed.
Do not hold the file waiting on a reply the captain has already overtaken.

## 2. Secrets and credentials

Everything in this section is in addition to `secrets-handling`, which owns the general mechanics, and to `fleet/doctrine/credential-store-boundary.md`, which owns what a vessel may do with a credential at all.
Read the boundary doctrine before staging anything: being able to reach a store is not permission to write to it.

### Capture and place in one shell call that never prints the value

Run `set +x` first.
The value is captured, transported, and written inside a single call, and it never reaches any output stream.
For a value the captain has put on his Windows clipboard, from a WSL session:

```sh
set +x; SECRET=$(powershell.exe -Command 'Get-Clipboard -Raw') \
  && ssh <vessel> 'umask 077; cat > <path> && chmod 600 <path>' <<< "$SECRET"; unset SECRET
```

No `echo` of the variable, no `cat` of the staged file, nothing that puts the raw value into a tool's visible output at any point.

### Stage it root-owned, mode 600, on the vessel's own host

The staging path is root-owned and mode 600, under a name that says plainly what it is.
The 2026-08-20 relay used `/root/.pending-secrets/<descriptive-name>.txt` on the target vessel's own host.
Staging on the host the receiving vessel already holds admin on is what keeps the value from having to cross a second machine at all.

### Verify structurally, without ever reading the value - every time

Check three things, none of which reveals the secret:

- the file's size,
- its line count,
- if the expected shape is known, that the non-secret field **labels** are present, with `grep -q "^label:"` - match or no-match only, never printing what follows a label.

**Run this even when every earlier step reported success.**
On 2026-08-20 a first clipboard capture staged entirely the wrong content: one line, and none of the expected field labels present, because the captain's clipboard held something else at that moment.
Every command in that chain succeeded.
The structural check is the only thing that caught it, and it caught it before the wrong notice went out.

### Notify with the dedicated envelope kind, never `status` or `directive`

Send `kind: secret-request`, or `kind: secret-ready` if this vessel is the one confirming the value has already moved.
`coditan-bridge`'s `docs/envelope-format.md` owns the schema and `bin/bridge-send.sh` enforces it; use `--help` for exact flags rather than memory.
What matters at the moment of writing:

- `--credential-name` and `--target-vessel` identify what is being talked about, and the target must be a rostered vessel.
- `--coordination-note` carries where it was staged, as a plain path, never a value and never anything that narrows one.
  Bridge history is permanent and fleet-readable, so this note is written for the whole fleet, forever.
- `--fingerprint sha256:<hex>` is optional and is a confirmation aid only.
  `fleet/doctrine/credential-store-boundary.md` section 7 owns the recipe and the trailing-newline trap; compute it by that recipe or leave it off.
  Leave it off entirely for a human-chosen password: 16 hex characters is a checkable guess against a password and a harmless mistake-detector only against a machine-issued credential.
- `body_md` stays empty, and the CLI structurally refuses free text there.
  That refusal is the design: the envelope carries metadata, and the value travels only over the target vessel's own admin channel.

### Correct a mistake explicitly, before re-staging

If the wrong content was staged or the wrong vessel targeted, send a `secret-request` correction first.
Name exactly what was wrong and state that the receiving vessel must not use the earlier staged file.
Then re-stage.
A silent overwrite leaves the recipient with no way to know which copy they read.

## 3. Expected obstacle: Claude Code's Auto Mode classifier

The SSH-write step in section 2 can be refused outright by Claude Code's Auto Mode semantic safety classifier, because the command writes secret-shaped content to a remote host.
Recognise this immediately rather than treating it as a hard blocker.

Three facts about it, all measured on 2026-08-20 when it refused the same step twice:

- **Explicit chat approval from the captain does not clear it.**
  Neither does an existing broad `Bash(ssh *)` rule in `permissions.allow`.
  The classifier is a distinct layer from ordinary Bash permission rules and is not satisfied by them.
- **The agent cannot edit `.claude/settings.local.json` to add the documented `autoMode.allow` override.**
  That edit is blocked by the same classifier, and that is correct.
  An agent must not be able to grant itself expanded secret-handling permission.
  Do not look for a way around this.
- **The only way through is the captain's own mode switch.**
  He takes the session out of Auto Mode with Shift+Tab or `/permissions`, into manual or default mode, so the action reaches him as a direct approval prompt instead of the classifier's silent judgement.

So when it fires: say what happened, say that chat approval alone does not lift it, and ask the captain to switch the session out of Auto Mode.
Then retry the same command unchanged.
