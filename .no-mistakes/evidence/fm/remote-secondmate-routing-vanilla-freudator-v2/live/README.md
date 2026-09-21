# Live proof at ad500bf on ak-secondmate (option B, fresh probe root)

Host `ak-secondmate` (account `fmremote`), driven over real SSH through the supported
`fm-remote-home-seed.sh` / `fm-spawn.sh` / `fm-send.sh` / `fm-teardown.sh` entrypoints.
Parent home: throwaway `FM_HOME=/tmp/fm-live-probe-01M31/parent`, removed afterwards; the
real parent home was not written to. Only the probe route ids `probe-oldseed` and
`probe-ak-fresh` were used. The ordinary `throwaway-ak-vanilla` route, home, charter and
pane `w1:p2` were not touched.

| # | File | Shows |
|---|------|-------|
| 00 | 00-entrypoint-original.txt | original symlink target recorded; vanilla root at 4612388, clean |
| 01 | 01-probe-root-created.txt | probe root /home/fmremote/firstmate-probe-ad500bf at ad500bf (from a git bundle) |
| 02 | 02-entrypoint-repointed.txt | symlink repointed to the probe root for the bounded test |
| 03-04 | base seed + charter | **Scenario 3 (adversarial), LIVE:** base dee119b seed publishes the parent's `/tmp/.../state/probe-oldseed.inbox`, which does not exist on the host |
| 05-06 | reseed + charter | **Scenario 4, LIVE:** reseeding the same home with ad500bf republishes `/home/fmremote/fm-home-probe-old/state/parent-route/probe-oldseed.inbox`, with 0 parent paths left and no hand edits. Attempt 1 failed because a worker from the ordinary route's root replaced the probe worker; attempt 2 succeeded. |
| 07-08 | fresh seed + charter | **Scenario 1, LIVE:** a brand-new home's charter names `state/parent-route/probe-ak-fresh.inbox` |
| 09-11 | spawn, arm | real Claude pane w3:p2 launched. Arming failed first because the sandbox state dir was 0775 (setup mistake); `arm` succeeded after chmod 700 |
| 12-14 | send + record | **Scenario 2, LIVE:** fm-send exit 0; the record corr=609fd3ad172c8aeb landed in exactly the charter's inbox |
| 14-15 | handled + pane | **Scenario 5, LIVE:** the mate moved 001.msg to handled/ and appended `done [corr=609fd3ad172c8aeb] ...: LIVEPROOF-01M31` |
| 16 | parent mirror | reply ingested into the parent status stream; pending-reply phase=resolved |
| 17 | teardown | probe-ak-fresh retired via fm-teardown (probe-oldseed was never launched and had no task record, so its home was removed after checking its marker) |
| 18-19 | restore + cleanup | symlink restored to /home/fmremote/firstmate-routing-vanilla/bin/fm-remote-entrypoint.sh; probe root and homes removed; vanilla root at 4612388, clean; ordinary home intact |
| 20 | ordinary readiness | read-only doctor through the ordinary route: `ok: remote second-mate readiness confirmed`; worker running from firstmate-routing-vanilla |
