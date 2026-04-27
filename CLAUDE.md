---
audience: internal
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo layout

Originally a fork of LuccaSA/SqlBackupTools, now a **hard fork** — Amphora is not planning to contribute back. `src/` can be rewritten and modified freely to match Amphora's requirements; don't hold back changes out of upstream-mergeability.

- **`src/` and `tests/`** — the .NET restore daemon. Fair game for Amphora-specific changes (multi-file DB handling, exclusion semantics, tenant-specific logic, etc.).
- **`ops/`** — Amphora's DR automation (Ola Hallengren jobs, SIMPLE→FULL conversion, claude readonly login, RichCopy360 specs, cutover runbooks, recovery runbooks). See `ops/README.md`.

When the user asks about "the DR plan", "log shipping", "backup scripts", they mean `ops/`. When they ask about "SqlBackupTools" the tool itself, they mean `src/`.

### Line endings

Repo has `core.autocrlf=false` and no `.gitattributes`. Some `src/` files are stored as LF in the index; the working copy may be CRLF on Windows. The `Write`/`Edit` tools save LF by default, which matches the index — but if you ever see a 400-line diff on a small change, check `git ls-files --eol <path>` and normalize to match `i/` (index) line endings before committing.

## Project

A .NET 8 Windows CLI (`SqlBackupTools.exe`) that parallelizes SQL Server `BACKUP`/`RESTORE` operations over an Ola Hallengren-style folder layout. Used at Lucca for log-shipping a database-per-tenant cluster (>1000 DBs) where AGs don't scale. Amphora uses it on **RESERV-2025** as the continuous-restore daemon that applies backups produced by the `ops/` pipeline.

`TreatWarningsAsErrors=true` is set in `Directory.Build.props`, so warnings fail the build.

## Build / test / run

```bash
# Build
dotnet build

# Run full test suite (integration tests require a reachable SQL instance)
dotnet test --configuration Release

# Run a single test
dotnet test --filter "FullyQualifiedName~RestoreSimpleCases"

# Publish single-file Windows exe (same shape as CI release job)
./publish.bat
# or manually:
dotnet publish src/SqlBackupTools/SqlBackupTools.csproj -c Release -o published -r win-x64 /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
```

### Integration test environment

`tests/SqlBackupTools.Tests/TestContext.cs` reads two env vars — defaults are usable locally but CI sets them:

- `TEST_SQL_INSTANCE` — SQL Server connection string. CI uses `(localdb)\MSSQLLocalDB`; default is `localhost`.
- `TEST_SQL_BACKUP_FOLDER` — folder where the fixture lays down test backups. Default: a fresh temp dir with `Everyone = FullControl` (Windows-only ACL code, tests won't run on non-Windows without changes).

The fixture (`DatabaseBackupsFixture`) actually spins up DBs on the target instance, produces real FULL+LOG backups, and the tests then run `RestoreCommand` against them end-to-end. Tests are Windows-only and platform-locked to `x64` in the test csproj.

## Architecture

### Command dispatch

`Program.Main` uses `CommandLineParser` to parse one of three verbs into a `GeneralCommandInfos` subclass, then `LaunchCommandAsync` switches on the concrete type and hands off to a runner:

| Verb | Command class | Runner |
|------|---------------|--------|
| `restore` | `RestoreCommand` | `Restore/RestoreRunner.cs` |
| `clean` | `CleanCommand` | `CleanRunner.cs` |
| `drop` | `DropDatabaseCommand` | `DropRunner.cs` |

Adding a new verb = new `[Verb]`-decorated class inheriting `GeneralCommandInfos`, register it in both `TryParseCommand` (parser generic args + `MapResult`) and the `switch` in `LaunchCommandAsync`, and the log-filename switch in `CreateLogger`.

### Restore pipeline (the core feature)

`RestoreRunner.RestoreAsync` is the interesting path:

1. `RestoreState` aggregates all mutable run state (SQL connection, logger, discovered items, error/ok collections, exclusions, report counters). Pass this — not the raw `RestoreCommand` — to anything that mutates progress.
2. Four things load in parallel: server info, current DB list, restore history from msdb, and `PrepareRestoreJobAsync` which crawls `--folder` roots for per-DB subdirectories and classifies `.bak`/`.trn` files (`BackupDiscoveryExtension` + `BackupExtensions` + `BackupFileType`).
3. The discovered directories are streamed through `ParallelizeAsync` (custom helper, see below) with `MaxDegreeOfParallelism = --threads`. Each item runs `RestoreBackupAsync`, which delegates actual T-SQL to an `IRestoreMethod`:
   - `Native/NativeRestoreMethod` — direct `RESTORE DATABASE`/`RESTORE LOG`, reads `RESTORE HEADERONLY`/`FILELISTONLY` to sequence LOGs, retries via `RetryStrategy`.
   - `Brentozar/BrentozarRestoreMethod` — shells out to BrentOzar's `sp_DatabaseRestore` stored proc. Selected by `-b/--brentozar`.
4. After successful FULL+LOG, optional post-steps (in order): `RESTORE WITH RECOVERY` (if `--runRecovery`) → user post-scripts split on `GO` (if `--postScripts`) → `DBCC CHECKDB` (if `--checkDb`) → move directory from `--unchecked` to `--checked` for the quarantine workflow.
5. `GetReportStateAsync` builds a `ReportState` with RPO outliers, missing FULLs, integrity errors, etc. The same report is fanned out to Slack (`Notification/SlackSend.cs`) and SMTP (`Notification/NotificationExtensions.cs`).

Non-zero exit code is set only when the final report has `ReportStatus.Error`.

### Parallelism (`src/SqlBackupTools/Parallel/`, namespace `ParallelAsync`)

Custom async-stream parallelization built on `Channel<T>`. The entry point is `AsyncStreamExtensions.ParallelizeAsync` — takes an `IEnumerable<T>`, an async worker, a `ParallelizeOption` (degree, `Fail.Fast`/`Fail.Smart`), and a `CancellationToken`; returns an `AsyncStream<T>` that the caller pumps with `ForEachAsync`. `ParallelizeCore` owns the linked cancellation + exception accumulation — on `Fail.Fast` the first exception cancels siblings; `Fail.Smart` lets remaining items finish. Don't replace this with `Parallel.ForEachAsync` casually; the downstream streaming API and failure modes are wired into the restore runner's accounting.

### Conventions

- Logging is Serilog with a background-worker sink wrapper (`SerilogAsync/BackgroundWorkerSink.cs`). Log file name is derived from the verb in `Program.CreateLogger`.
- SQL access uses `Microsoft.Data.SqlClient` + Dapper. `GeneralCommandInfos.CreateConnectionMars` opens a MARS-enabled connection; `--timeout` (default 5400s) is the command timeout.
- Backup folder layout assumes Ola Hallengren: one subfolder per database, `.bak` for FULL, `.trn` for LOG. See `BackupFileType` and `BackupDiscoveryExtension`.
- `AsyncStreamExtensions.Parallel.cs` is split from `AsyncStreamExtensions.cs` by partial concern, not by `partial` keyword — don't merge them.
