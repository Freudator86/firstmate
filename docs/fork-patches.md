# Curated fork patch registry

Each fork-only, non-merge commit has one row recording its current verdict against the named real-upstream tip.
Use `absorbed` when upstream fully replaces the patch, `keep` while fork-specific behavior remains necessary, and `upstream-candidate` when the patch should be proposed upstream.
Re-review a row when the upstream tip moves.

| Commit | Summary | Verdict | Rationale | Last reviewed upstream |
| --- | --- | --- | --- | --- |
| `e623032` | feat: add AXI-suite self-update and primary safety seatbelts (#1) | keep | The true merge absorbed most of this squash-import's upstream-derived bulk, but the merged tree still needs its fork-only AXI-suite updater, lint pinning, and primary pre-tool safety guards. | `ad9f3a7` |
| `4939c5b` | feat(watch): wake on Bridge inbox traffic (#2) | keep | Real upstream has no Bridge inbox concept; the merged watcher retains the fork's bounded fetch, priority cadence, and wake logic. | `ad9f3a7` |
| `df159d2` | feat(bootstrap): add upstream firstmate update check (#3) | keep | The curated fork still needs the read-only upstream instruction-surface sentinel and bootstrap diagnostics; upstream does not provide it. | `ad9f3a7` |
| `8f3190b` | fix(watch): read Bridge inbox state from fetched origin/main (#4) | keep | The remote-tracking-tree fix remains required so Bridge wakes reflect fetched shared state rather than a potentially stale local checkout. | `ad9f3a7` |
