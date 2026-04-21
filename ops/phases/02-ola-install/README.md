# Phase 02 — Install Ola Hallengren

Downloads the latest `MaintenanceSolution.sql`, patches the 3 header variables
that matter to us (backup root, retention, output log dir), and runs it against
`master` on the current server.

## Run

On **each primary** (SQL-2022, PREMIUM-2022), elevated PowerShell:

```powershell
cd C:\Sources\SqlBackupTools
.\ops\phases\02-ola-install\install-ola.ps1
```

The script resolves config from `ops/config/shared.ps1` + `ops/config/$env:COMPUTERNAME.ps1` for the backup root (Ship path) and output log dir.

Expected result:

- 4 Ola procs created in `master`: `DatabaseBackup`, `DatabaseIntegrityCheck`, `IndexOptimize`, `CommandExecute`
- `master.dbo.CommandLog` table
- 11 SQL Agent jobs (all disabled until Phase 4 wires them)

## Verify

```sql
SELECT name FROM master.sys.procedures
 WHERE name IN ('DatabaseBackup','DatabaseIntegrityCheck','IndexOptimize','CommandExecute');

SELECT name, enabled FROM msdb.dbo.sysjobs
 WHERE name LIKE 'DatabaseBackup%' OR name LIKE 'DatabaseIntegrityCheck%' OR name LIKE 'IndexOptimize%'
 ORDER BY name;
```

4 procs + 11 jobs → good.
