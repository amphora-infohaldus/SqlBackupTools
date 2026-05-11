---
audience: internal
---

# Phase 06 — Cutover

> **STATUS: HISTORICAL.** Cutover has already happened on both primaries; this
> doc remains as the as-built reference for the sequence. Current state lives
> in `ops/runbooks/observability-handoff.md` (what's running) and `ops/README.md`
> (transport). Anything below described as "future" or "after one week" is
> already done.

Take the initial FULL on each primary, ship to RESERV (direct UNC in current
deployment), seed RESERV, then enable the LOG job.

## Sequence

### 1. Kill the old backup pipeline

On each primary, disable the legacy backup scheduler so it doesn't compete:

**PREMIUM-2022** — disable the maintenance plan:
```sql
EXEC msdb.dbo.sp_update_job @job_name = N'MaintenancePlan.FULL backup', @enabled = 0;
-- Optional: delete after a week of clean Ola runs:
-- EXEC msdb.dbo.sp_delete_job @job_name = N'MaintenancePlan.FULL backup';
```

**SQL-2022** — find and disable whatever drives `W:\DAILY\` backups today
(external orchestrator, not a SQL Agent job). Task Scheduler? PowerShell on another box?

**PREMIUM-2022** — also tear down any legacy SQL native log-shipping setups
(e.g. the one that shipped `amphorafw_infohaldus` to SQL-2022's `\LogShipping`
share, decommissioned 2026-05-11). Look for `LSBackup_*` SQL Agent jobs +
entries in `msdb.dbo.log_shipping_primary_databases`. `sp_delete_log_shipping_primary_database` removes them.

### 2. Kick off initial FULL on each primary

```powershell
cd C:\Sources\SqlBackupTools
.\ops\run.ps1 phases\06-cutover\kickoff-initial-full.sql
```

This just does `EXEC msdb.dbo.sp_start_job 'DatabaseBackup - USER_DATABASES - FULL'`.
Job runs async; watch `master.dbo.CommandLog` for progress.

Expect ~1 hour on PREMIUM-2022 (~26 DBs) and ~3-6 hours on SQL-2022 (~128 DBs) at 470 MB/sec compressed. Can run on both primaries in parallel.

### 3. Verify all FULLs succeeded

```sql
SELECT
    SUM(CASE WHEN ErrorNumber = 0 THEN 1 ELSE 0 END) AS Successes,
    SUM(CASE WHEN ErrorNumber <> 0 THEN 1 ELSE 0 END) AS Errors
FROM master.dbo.CommandLog
WHERE CommandType = 'BACKUP_DATABASE'
  AND StartTime > DATEADD(HOUR, -24, GETDATE());
```

`Errors = 0` → proceed. Otherwise investigate:
```sql
SELECT TOP 20 DatabaseName, StartTime, LEFT(ErrorMessage, 300) AS Err
FROM master.dbo.CommandLog
WHERE ErrorNumber <> 0
ORDER BY StartTime DESC;
```

### 4. Verify files landed on RESERV

On RESERV (elevated PowerShell):
```powershell
Get-ChildItem C:\SqlBackup -Recurse -Include *.bak |
    Group-Object { $_.Directory.Parent.Parent.Name } |
    Select-Object Name, Count
```

Counts should roughly match the per-server DB counts (`SQL-2022` ≈ 126 = 128 - wdimport_ekis - wdimport_cache; `PREMIUM-2022` ≈ 25 = 28 - AmphoraFT - AmphoraFT_13 - amphora_logs).

### 5. Seed RESERV

Continuous restore — done via SqlBackupTools. See `ops/monitoring/seed-reserv.md` (TODO) for the exact invocation. Outline:

```
SqlBackupTools.exe restore -h . -f C:\SqlBackup\SQL-2022 --threads 16 --noRecovery
SqlBackupTools.exe restore -h .\PREMIUM -f C:\SqlBackup\PREMIUM-2022 --threads 8 --noRecovery
```

(second command assumes the `\PREMIUM` named instance is installed per Phase 01.)

### 6. Enable the LOG job on each primary

```powershell
cd C:\Sources\SqlBackupTools
.\ops\run.ps1 phases\06-cutover\enable-log-job.sql
```

From this point, LOG backups run on the configured `LogIntervalMinutes`
cadence (currently 15 min — see `ops/config/shared.ps1`). Ola writes them
straight to RESERV's UNC share. SqlBackupTools sweeps every 5 min and applies
new LOGs. RPO target: ≤15 min.

### 7. Tighten LOG cadence further (optional)

Measure LOG-job duration on each primary (`msdb.dbo.sysjobhistory` for
`DatabaseBackup - USER_DATABASES - LOG`, `step_id = 0`). If durations are
well under half the interval, the cadence can be tightened (15 → 5 → 1).
Edit `LogIntervalMinutes` in `ops/config/shared.ps1`, commit, pull, re-run
`ops/run.ps1 phases/04-wire-jobs/main-jobs.sql` on each primary (idempotent —
only schedule changes). Or for a one-off in-place flip without re-running
the whole script:

```sql
USE msdb;
EXEC sp_update_schedule
     @name = N'Sched_Minutely_Log',
     @freq_subday_interval = <new minutes>;
```
