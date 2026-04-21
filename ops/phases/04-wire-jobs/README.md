# Phase 04 — Wire SQL Agent jobs

Two scripts, run in order on **each primary**:

1. `main-jobs.sql` — 5 main jobs: Weekly FULL, Daily DIFF, LOG (disabled), MONTHLY, YEARLY. All backups write to LOCAL disk (`ShipLocalPath`, `MonthlyLocalPath`, `YearlyLocalPath` from per-server config); RichCopy360 RTA then mirrors to RESERV.

2. `amphora-logs-local-jobs.sql` — the `amphora_logs` carve-out: reverts to SIMPLE recovery + creates dedicated local-only weekly FULL + daily DIFF. `amphora_logs` is excluded from the main ship stream (name collides between SQL-2022 and PREMIUM-2022) but still gets local retention.

## Run

```powershell
cd C:\Sources\SqlBackupTools
.\ops\run.ps1 phases\04-wire-jobs\main-jobs.sql
.\ops\run.ps1 phases\04-wire-jobs\amphora-logs-local-jobs.sql
```

Both idempotent — re-run safely after config changes (e.g., when tightening LOG cadence from 30 min → 15 min).

## What gets created

After both scripts, each primary has these Agent jobs:

| Job | Subsystem | Schedule | Destination | Enabled |
|---|---|---|---|---|
| `DatabaseBackup - USER_DATABASES - FULL` | TSQL | Weekly Sun | `ShipLocalPath` | yes |
| `DatabaseBackup - USER_DATABASES - DIFF` | TSQL | Mon-Sat | `ShipLocalPath` | yes |
| `DatabaseBackup - USER_DATABASES - LOG` | TSQL | Every N min | `ShipLocalPath` | **no** (Phase 06) |
| `DatabaseBackup - USER_DATABASES - FULL - MONTHLY` | TSQL | 1st of month | `MonthlyLocalPath` | yes |
| `DatabaseBackup - USER_DATABASES - FULL - YEARLY` | TSQL | Jan 1 | `YearlyLocalPath` | yes |
| `DatabaseBackup - amphora_logs - FULL` | TSQL | Weekly Sun | `AmphoraLogsLocalPath` | yes |
| `DatabaseBackup - amphora_logs - DIFF` | TSQL | Mon-Sat | `AmphoraLogsLocalPath` | yes |

## Verifying

```sql
SELECT j.name, j.enabled, js.subsystem, LEFT(js.command, 100) AS CmdStart
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name LIKE 'DatabaseBackup%'
ORDER BY j.name;
```

Every row should show `subsystem = TSQL` and a command starting with `EXECUTE [dbo].[DatabaseBackup]`. If any shows `CmdExec` with `sqlcmd -E ...` that's a pre-fix-version artifact — re-run the script.
