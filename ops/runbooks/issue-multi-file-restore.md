---
audience: internal
---

# Draft: Multi-file DBs silently fail restore

> To file: `gh repo edit amphora-infohaldus/SqlBackupTools --enable-issues` (one-time, needs admin) → then `gh issue create --repo amphora-infohaldus/SqlBackupTools --title "Multi-file DBs silently fail restore: WITH MOVE only emitted for first D/L file" --body-file ops/runbooks/issue-multi-file-restore.md`

## Symptom

During initial seed of RESERV-2025 (152 DBs), 5 DBs were silently omitted from the restore set. No error logged, no `(1 full)` suffix in the per-DB runner output, and no `RESTORE DATABASE` statement visible in SQL traces for those DBs.

Missing DBs shared one property: **multiple data files and/or multiple log files**.

| DB | D files | L files |
|---|---|---|
| `amphorafw_raevv` | 1 | 2 |
| `amphorafw_kuusalu_pro` | 2 | 1 |
| `AmphoraInvoicePortal` | 3 (1 MDF + 2 NDFs) | 1 |
| `prosopos` | 2 (MDF + FT NDF) | 1 |
| `amphorafw_viljandivv` | 2 (MDF + NDF) | 1 |

All other DBs in the set have exactly 1 data file + 1 log file and restored fine.

## Root cause

`src/SqlBackupTools/Restore/Native/NativeRestoreMethod.cs:346-347`:

```csharp
logicalData = infos.Where(f => f.Type == 'D').Select(f => f.LogicalName).First();
logicalLog  = infos.Where(f => f.Type == 'L').Select(f => f.LogicalName).First();
```

`First()` grabs only the first D and first L logical name. The generated `RESTORE DATABASE` then emits `WITH MOVE` for exactly two files. SQL Server falls back to the backup's original physical paths for every other file — in our case `D:\Data\...` from SQL-2022 / PREMIUM-2022, which does not exist on RESERV (default data path is `C:\Data\`).

Result: `RESTORE` fails with `The path specified by 'D:\Data\xyz.ndf' is not in a valid directory.` The failure appears to be swallowed somewhere up the runner — we saw neither a fail count bump nor a log line. Needs confirmation whether it's eaten at `RestoreBackupAsync` or earlier.

## Expected

Iterate every row from `RESTORE FILELISTONLY` and emit one `MOVE` per logical file, retargeting each to `ServerInfos.DataPath` / `ServerInfos.LogPath` (preserving original filename, or rewriting to `<db>_<n>.ndf` / `<db>_<n>.ldf`).

## Workaround used for initial seed

Manual `RESTORE ... WITH MOVE` per logical file. Template committed at `ops/runbooks/seed-multi-file-restore.sql`.

## Impact

Blocks clean continuous-restore seeding for any tenant DB that has been split across multiple files (common for big DBs or FT-indexed DBs). Silent nature makes it dangerous — we only noticed because the final count was 5 short of expected.
