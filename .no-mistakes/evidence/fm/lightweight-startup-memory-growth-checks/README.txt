Live validation of the daily startup growth check
=================================================

Everything here was driven against the real product in a disposable lab:

  LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
  bin/fm-lab-home.sh create "$LAB"          # marked throwaway FM_HOME
  $LAB/root                                  # byte copy of the tracked repo = disposable install
  $LAB/root/bin/fm-startup-growth-check.sh arm   # arms state/startup-growth.check.sh
  $LAB/root/bin/fm-watch.sh                  # the real watcher, FM_POLL=1 FM_CHECK_INTERVAL=0
  $LAB/root/bin/fm-wake-drain.sh             # the agent-facing wake view

No operator home, fleet state, tmux server, or credential was touched; the lab was
removed in the same turn.

Reading the sweep lines
-----------------------
Each sweep is one real `bin/fm-watch.sh` run under `timeout`:

  rc=0   ... wake=check: ...   the watcher surfaced an actionable wake and exited
  rc=124 ... wake=<silent>     the watcher kept polling for the whole window and
                               never woke. "Terminated" on such a line is only
                               timeout(1)'s own message for killing the watcher.

The daily gate is advanced with the script's own FM_STARTUP_GROWTH_NOW hook
(now=<epoch> on each line) instead of waiting real days.

Files
-----
armed-baseline-silence.txt        first daily evaluation: silent, record published
watcher-growth-wake.txt           the watcher surfacing instruction+memory growth
wake-queue-record.txt             the durable wake queue row for that finding
wake-drain-agent-view.txt         what the supervising agent sees on its next turn
same-day-silence.txt              three same-day sweeps: no wake, no re-read
next-day-report-and-dedupe.txt    next due day reports; standing finding then quiet
cumulative-subthreshold-growth.txt  700 bytes/day under the 2048 threshold, caught at +2100
budget-overrun.txt                bulk learnings file blows the 7500-token budget
metadata-only-strace.txt          raw strace lines for the watched paths
metadata-only-no-content-reads.txt  zero content bytes read from the watched files
reference-only-no-merge.txt       the check never writes/merges the memory files
secondmate-suppression.txt        secondmate quiet about primary-owned shared file
tampered-shim-refused.txt         tampered shim refused unexecuted, then restored
interrupt-fuzz.txt                200 TERM-interrupted evaluations
disarm.txt                        disarm removes shim, trust, record; watcher quiet
