# Phase 06 — Cutover

Take the initial FULL on each primary, let RichCopy ship to RESERV, seed
RESERV, then enable the minute-LOG job.

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

From this point, LOG backups run every 30 min (initial conservative cadence —
reduce after a week of observation). RichCopy ships them. SqlBackupTools
continuously applies them to RESERV. RPO target: ≤30 min initially.

### 7. Tighten LOG cadence after observing

After one week:
- Look at actual RichCopy lag + SqlBackupTools apply time
- If comfortably under target → reduce `LogIntervalMinutes` in
  `ops/config/shared.ps1`:
  - 30 → 15 → 5 → 1
- Re-run `ops/run.ps1 phases/04-wire-jobs/main-jobs.sql` on each primary
  (idempotent — only schedule changes)
