---
audience: internal
---

# RESERV continuous-restore automation

The daemon on RESERV applies LOG backups as they arrive from the primaries.
Today it's a one-shot invocation; tomorrow it's a Windows Scheduled Task.

## Current state (as of 2026-04-22 18:53)

- `C:\SqlBackupTools\SqlBackupTools.exe` — pre-security-hardening build.
  Rebuild from main (commits `daeab1b`, `e10f1c6`, `0d4352d`) to pick up
  the multi-file fix, identifier validation, TLS-by-default, Mailgun, and
  `--secrets-file` support.
- 151 DBs in RESTORING with their first LOG applied. `amphora_logs`
  excluded per policy.
- LOG-backup cadence on primaries: 30 min (`LogIntervalMinutes` in
  `ops/config/shared.ps1`).

## One-shot invocation that worked today

Each primary's folder needs a separate invocation — the CLI parser on the
current exe doesn't accept multiple `-f` / `--folder` flags cleanly.

```powershell
C:\SqlBackupTools\SqlBackupTools.exe restore `
  -h . `
  --folder C:\SqlBackup\PREMIUM-2022 `
  --continueLogs `
  --ignoreDatabases amphora_logs

C:\SqlBackupTools\SqlBackupTools.exe restore `
  -h . `
  --folder C:\SqlBackup\SQL-2022 `
  --continueLogs `
  --ignoreDatabases amphora_logs
```

Each invocation is idempotent. "Backup not found" warnings for DBs from
the *other* primary's folder are expected.

## Automation plan

### 1. Rebuild and drop in the hardened exe

```powershell
cd C:\Sources\SqlBackupTools
git pull
dotnet publish src/SqlBackupTools/SqlBackupTools.csproj `
  -c Release -o published -r win-x64 `
  /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
Copy-Item -Force published\SqlBackupTools.exe C:\SqlBackupTools\SqlBackupTools.exe
```

### 2. Wire up SOPS secrets on RESERV

Follow `ops/GETTING-STARTED.md` §"On EACH of the three servers" — generate
an age keypair, add its public key to `.sops.yaml`, run
`sops updatekeys ops/config/secrets.enc.yaml`, commit, `git pull` on RESERV.
Add Mailgun keys (pulled from AmphoraPro's `Web.config`) to the secrets
file:

```
mailgun_api_key:  "key-..."
mailgun_domain:   "mg.amphora.ee"
mailgun_from:     "SQL backup <sqlbackup@mg.amphora.ee>"
```

### 3. Wrapper script — one .ps1 that drives both folders

`ops/runbooks/reserv-restore-cycle.ps1` (to be written): runs the exe once
per primary folder, sequentially. Exits non-zero only if one of the child
invocations returned non-zero with an actual error (not the "not found"
cross-primary warnings, which always fire).

```powershell
$ErrorActionPreference = 'Stop'
$exe = 'C:\SqlBackupTools\SqlBackupTools.exe'
$secrets = 'C:\Sources\SqlBackupTools\ops\config\secrets.enc.yaml'
$common = @(
    'restore', '-h', '.',
    '--continueLogs',
    '--ignoreDatabases', 'amphora_logs',
    '--secrets-file', $secrets,
    '--email', 'ingmar@interinx.com',
    '--slackChannel', '#sql-dr',
    '--slackTitle', 'RESERV restore',
    '--slackOnlyOnError'
)
& $exe @common --folder 'C:\SqlBackup\PREMIUM-2022'
& $exe @common --folder 'C:\SqlBackup\SQL-2022'
```

### 4. Scheduled Task

Cadence: every 5 minutes (tighter than the 30-min LOG cadence, so every
LOG batch is picked up on the next tick — worst-case add-on latency ~5
min on top of the primary's 30-min cycle).

```powershell
$action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Sources\SqlBackupTools\ops\runbooks\reserv-restore-cycle.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
  -StartWhenAvailable
Register-ScheduledTask -TaskName 'SqlBackupTools-RestoreCycle' `
  -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

Key choices:
- **SYSTEM principal** — Integrated auth reaches local SQL, no
  credential-on-disk problem. NOTE: on RESERV the SQL hardening baseline
  removed the `BUILTIN\Administrators → sysadmin` login, so SYSTEM does
  NOT inherit sysadmin by default. `RESTORE LOG` requires sysadmin (or
  dbcreator + db-owner match) and fails with error 3110 without it. We
  added `NT AUTHORITY\SYSTEM` to sysadmin explicitly:
  `ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT AUTHORITY\SYSTEM];`
  Verify with `SELECT IS_SRVROLEMEMBER('sysadmin','NT AUTHORITY\SYSTEM')`.
- **MultipleInstances IgnoreNew** — if a run overlaps the next trigger
  (e.g. unusually large LOG batch), Windows skips the new instance
  instead of piling up.
- **ExecutionTimeLimit 20 min** — caps runaway runs.

### 5. Monitoring

After scheduled task is live:
- `Get-ScheduledTaskInfo -TaskName SqlBackupTools-RestoreCycle` for
  last-run / next-run / last-exit-code.
- `Get-ChildItem C:\SqlBackupTools\logs` for the rolling Serilog file.
- `msdb.dbo.restorehistory` for the DB-level view (restore_type='L' =
  LOG apply).
- Slack `#sql-dr` — on-error-only notifications via `--slackOnlyOnError`
  (won't spam on happy path).

### Open items (deferred)

- Tighten `LogIntervalMinutes` once a week of steady-state data is in
  (target 5 min first, then 1).
- Weekly `DBCC CHECKDB` on a rotation — either via `--checkDb` on a
  separate scheduled task (once/week), or let Ola handle integrity on the
  primaries and skip on RESERV.
- Failback runbook for when a primary is rebuilt.
