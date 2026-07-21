---
name: secrets-handling
description: >-
  Agent-only playbook for keeping secrets out of transcripts and containing agent-local exposures.
  Use before reading, sourcing, injecting, inspecting, or transporting secrets or credentials, and whenever one is exposed in agent or tool output.
user-invocable: false
metadata:
  internal: true
---

# secrets-handling

`AGENTS.md` section 1 "Secrets" owns the always-loaded safety invariant and must be obeyed before this playbook.
This skill owns the conditional mechanics, examples, and exposure response without relaxing that invariant.

## Handle secrets without displaying them

Treat command stdout, stderr, shell tracing, tool results, prompts, briefs, reports, commits, and status messages as transcript-visible output.
Keep real values out of all of them.
Use a trusted local secret file only inside the same shell call that consumes it, because `source` executes the file as shell code and a separately sourced environment may not survive into the consuming call.
Disable shell tracing with `set +x` before sourcing or using a credential, and do not enable tracing again until the secret-bearing command is complete.

For example, verify an API credential by the authenticated request's exit status without printing the token or response body:

```sh
set +x; source /path/to/secrets.env && curl -fsS -o /dev/null -H "Authorization: Bearer $TOKEN" https://api.example.test/health
```

An existence test such as `test -n "${TOKEN:-}"` is safe but proves only that a value is present.
The authenticated operation remains the proof that the credential works.

## Replace dangerous inspection commands

- Do not run `cat`, `head`, `tail`, `sed`, `awk`, or `rg` against a secrets file to discover a value.
  Source the trusted file and use the named variable in the consuming operation instead.
- Do not run `echo "$TOKEN"`, `printf '%s\n' "$TOKEN"`, `env`, or `printenv` to check a credential.
  Use `test -n "${TOKEN:-}"` for presence and a real authenticated operation for validity.
- Do not run `docker inspect <container> --format '{{json .Config.Env}}'` or `docker exec <container> env` when credentials may be present.
  Query non-secret state directly, such as `docker inspect <container> --format '{{.State.Status}}'`, or test one credential without output using `docker exec <container> sh -c 'test -n "${API_TOKEN:-}"'` before verifying its effect.
- Do not run `ps eww` because it appends the process environment to the listing.
  Inspect non-environment identity with `ps -o pid=,ppid=,user=,comm= -p <pid>` and verify configuration through the process's behavior.

Filter at the producer whenever inspection is unavoidable so the full environment never reaches agent-visible output.
Prefer a targeted no-value test or a non-secret field over a pipeline that first emits every value.
Safe transcript handling does not grant authority to transport a secret through chat, Bridge, Git, or another shared channel; follow the destination's existing transport owner and keep shared coordination metadata-only.

## Respond to an exposed value

Stow-and-clear is sufficient only when the value appeared in an authorized agent or tool transcript, remained session-local and ephemeral, and there is no evidence that it reached a durable artifact, shared log, message, repository, remote service, public output, or untrusted reader.
For that contained case:

1. Stop the command or inspection that exposed the value and do not repeat it.
2. Flag the exposure plainly through Firstmate every time, naming the affected credential only by a safe label and never reproducing the value.
3. Load `stow` and preserve only sanitized task context or reusable doctrine, with no secret value or copied transcript content.
4. Clear or replace the exposed agent session so the value is no longer carried in model context.
   Load `harness-adapters` before Firstmate drives another agent's interrupt, exit, or replacement lifecycle.
5. Confirm that no durable or shared copy was created.

Do not rotate automatically for a contained, session-local, ephemeral exposure.
Escalate immediately when the exposure reached or may have reached durable storage, a shared or remote channel, source control, an untrusted audience, or an unknown boundary, or when suspicious use means containment is uncertain.
Report the credential label, exposure location, audience, persistence, and known effect without including the value.
Treat revocation, rotation, durable-log cleanup, and evidence preservation as security-sensitive response decisions unless an existing incident-response owner already grants exact authority.
