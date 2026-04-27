---
audience: internal
---

# Failover runbook (STUB — fill in after Phase 6 cutover and a dry-run)

## When to invoke
- Primary unreachable / destroyed / data-loss event
- Planned maintenance drill (quarterly)

## Pre-requisites
- RESERV-2025 is caught up (SqlBackupTools lag < threshold — see `ops/monitoring/`)
- `SqlBackupCert` is restored on RESERV with matching thumbprint
- claude login + admin access on RESERV confirmed

## High-level sequence
1. Freeze writes on primary (if primary still reachable):
   ```sql
   ALTER DATABASE <db> SET READ_ONLY WITH ROLLBACK IMMEDIATE;
   -- or take OFFLINE if the box itself is the problem
   ```
2. Take the tail-log backup on primary (if reachable), ship to RESERV.
3. Apply final LOGs on RESERV via SqlBackupTools.
4. Run `RESTORE DATABASE <db> WITH RECOVERY` on RESERV for each DB
   (SqlBackupTools has a `--runRecovery` flag that does this in bulk).
5. Fix `@@SERVERNAME` anomalies if any (`sp_dropserver` / `sp_addserver`).
6. Repoint applications:
   - DNS / connection-string flip to RESERV-2025
   - If second instance `\PREMIUM` is live: flip PREMIUM-originating apps to `RESERV-2025\PREMIUM`
7. Validate: sample queries against key DBs, smoke-test app logins.
8. Announce cutover complete.

## Failback (when primaries are rebuilt)
- Reverse direction: backup from RESERV, restore to primary, apply logs during a quiet window, cut over.
- Full runbook: TODO.

## Known risks / gotchas
- `amphora_logs` is NOT on RESERV — Amphora will auto-create an empty one.
  Alloy must still be wired for log forwarding (see `memory/project_amphora_logs_placeholder.md`).
- TDE / encrypted DBs: none in current fleet (confirmed by edition audit).
- SQL Agent jobs on RESERV are not the same as on primaries — any required
  jobs (not in our Ola set) must be recreated manually.
