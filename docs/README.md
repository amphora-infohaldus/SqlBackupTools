---
audience: internal
---

# SqlBackupTools — developer documentation index

This is a hard fork of LuccaSA/SqlBackupTools. The .NET CLI in `src/` is
upstream-shaped; everything Amphora-specific (DR pipeline, RESERV-2025
deployment, runbooks) lives under `ops/`.

## Where to look

| Topic | File |
|---|---|
| Repo layout, build/test, command dispatch, restore-pipeline architecture, parallelism design | [`../CLAUDE.md`](../CLAUDE.md) |
| Tool description, CLI flags, original Lucca usage notes | [`../README.md`](../README.md) |
| DR automation overview (Amphora) | [`../ops/README.md`](../ops/README.md) |
| Phased deployment from scratch (01 → 06) | [`../ops/GETTING-STARTED.md`](../ops/GETTING-STARTED.md) and [`../ops/phases/`](../ops/phases/) |
| RESERV continuous-restore daemon | [`../ops/runbooks/reserv-continuous-restore.md`](../ops/runbooks/reserv-continuous-restore.md) |
| Observability stack (Alloy → OTel → Grafana) state and gotchas | [`../ops/runbooks/observability-handoff.md`](../ops/runbooks/observability-handoff.md) |
| Day-2 monitoring | [`../ops/monitoring/README.md`](../ops/monitoring/README.md) |
| Failover (stub — fill after first dry-run) | [`../ops/runbooks/failover.md`](../ops/runbooks/failover.md) |
| Workstation dev-clone of `amphorafw_infohaldus` (finances bot) | [`../ops/runbooks/dev-clone-on-workstation.md`](../ops/runbooks/dev-clone-on-workstation.md) |
| Known-issue draft: multi-file DBs | [`../ops/runbooks/issue-multi-file-restore.md`](../ops/runbooks/issue-multi-file-restore.md) |
| Grafana dashboard JSON | [`../ops/dashboards/sqlbackuptools.json`](../ops/dashboards/sqlbackuptools.json) |

## Why an index instead of duplicated content

Per `C:\Sources\.github\CLAUDE.md` every repo must have a `/docs/` tree
that the support-bot indexer (`repo_docs_v1`) can walk. This repo's
substantive docs are already split between `CLAUDE.md` (architecture,
conventions) and `ops/` (operational specifics). Duplicating them here
would create drift; pointers stay current.

When new dev-oriented documentation doesn't fit either of those two
homes, add it under `docs/` directly and link it from this index.
